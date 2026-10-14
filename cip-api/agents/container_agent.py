"""
Package & Container Agent (one per component lane).

Packages the component (its package command + artifacts), then for deployable components builds the image
through the Docker MCP server – with the repo's Dockerfile, or one the agent writes (LLM) / a template (no LLM) –
and scans it with Trivy through the Scanner MCP server. The container gate is a fixed threshold check.
"""

import glob
import re
import shutil
import time
from pathlib import Path

from langchain_core.runnables import RunnableConfig
from pydantic import BaseModel, Field

from agent_states.pipeline_state import LaneState
from agent_tools.workspace_tools import WorkspaceTools
from agents.tool_loop import tool_loop
from llmapi.llm_provider import LLMProvider
from llmapi.structured_llm import ask_structured
from mcp_services.mcp_clients.mcp_tool_client import docker_client, scanner_client
from services.stream_event_writer import StreamStatus
from utils.agent_events import emit, step_record
from utils.quality_gates import container_gate

TEMPLATES = {                                     # {app} = the backend sub-folder when the component is a parent folder
    "Python": "FROM python:3.12-slim\nWORKDIR /app\nCOPY . .\nRUN pip install --no-cache-dir -r {app}requirements.txt\n"
              "RUN useradd -m app\nUSER app\nWORKDIR /app/{app}\nEXPOSE {port}\n"
              "CMD [\"python\", \"-m\", \"uvicorn\", \"main:app\", \"--host\", \"0.0.0.0\", \"--port\", \"{port}\"]\n",
    "JavaScript": "FROM nginxinc/nginx-unprivileged:1.27-alpine\nCOPY {app}dist/ /usr/share/nginx/html/\nEXPOSE 8080\n",
    "Java": "FROM eclipse-temurin:17-jre-alpine\nWORKDIR /app\nCOPY {app}target/*.jar app.jar\nRUN adduser -D app\nUSER app\n"
            "EXPOSE 8080\nCMD [\"java\", \"-jar\", \"app.jar\"]\n",
    "Go": "FROM golang:1.22 AS build\nWORKDIR /src\nCOPY . .\nWORKDIR /src/{app}\nRUN CGO_ENABLED=0 go build -o /app .\n"
          "FROM gcr.io/distroless/static-debian12:nonroot\nCOPY --from=build /app /app\nEXPOSE 8080\nENTRYPOINT [\"/app\"]\n",
}
TEMPLATES["TypeScript"] = TEMPLATES["JavaScript"]
TEMPLATES["HTML"] = "FROM nginxinc/nginx-unprivileged:1.27-alpine\nCOPY . /usr/share/nginx/html/\nEXPOSE 8080\n"   # static site


def exposed_port(folder: Path, default: int) -> int:
    """The port the Dockerfile EXPOSEs (the agent may have rewritten it), else `default`."""
    df = folder / "Dockerfile"
    found = re.findall(r"^EXPOSE\s+(\d+)", df.read_text(errors="replace"), re.M) if df.is_file() else []
    return int(found[-1]) if found else default


class Dockerfile(BaseModel):
    content: str = Field(description="complete Dockerfile: small base image, non-root USER, EXPOSE, start command")
    port: int
    reasoning: str = ""


class ContainerAgent:
    def __init__(self) -> None:
        self.node_name = "container_agent"

    async def _package(self, state: LaneState, tools: WorkspaceTools, comp: dict, out: Path) -> dict:
        if comp.get("package_command"):
            await tools.run(comp["package_command"], comp["path"])
        folder = Path(state["workspace"]) / comp["path"]
        files = [Path(f) for pat in comp.get("artifacts", []) for f in glob.glob(str(folder / pat), recursive=True) if Path(f).is_file()]
        out.mkdir(parents=True, exist_ok=True)
        for f in files[:200]:
            shutil.copy2(f, out / f.name)
        return {"artifacts": [f.name for f in files[:200]]}

    async def run(self, state: LaneState, config: RunnableConfig) -> LaneState:
        task_id, comp, t0 = state["task_id"], state["component"], time.time()
        result, name = dict(state.get("result", {})), comp["name"]
        if result.get("build", {}).get("status") != "passed":
            why = f"BLOCKED – the build of {name} failed"
            result["container_gate"] = container_gate({}, [], False, blocked=why) if comp["deployable"] else None
            return {"result": result, "steps": {f"package.{name}": step_record(f"package.{name}", "Package", "package", "blocked", why, name)}}
        tools = WorkspaceTools(state["workspace"], task_id, f"package.{name}")
        tools.extra_path, tools.extra_env = result["build"].get("path", []), result["build"].get("env", {})
        pkg = await self._package(state, tools, comp, Path(state["run_dir"]) / "artifacts" / name)
        steps = {f"package.{name}": step_record(f"package.{name}", "Package", "package", "passed",
                                                ", ".join(pkg["artifacts"][:10]) or "no artifact files", name,
                                                commands=tools.commands, started=t0)}
        result["package"] = pkg
        await emit(task_id, f"package.{name}", StreamStatus.END, steps[f"package.{name}"]["message"], parent="component_lanes")
        opts = state.get("options") or {}
        if not comp["deployable"] or not opts.get("containerize", True):
            return {"result": result, "steps": steps}

        node, t1 = f"image.{name}", time.time()
        tools.node = node                                 # the agent's Dockerfile fixes belong to the image step
        await emit(task_id, node, StreamStatus.START, f"Containerising {name}", parent="component_lanes")
        docker = docker_client()
        if not (await docker.call_tool("docker_status", {}))["running"]:
            msg = "Docker is not running – start Docker Desktop to build, scan and deploy the image"
            result["image"] = {"built": False, "message": msg}
            result["container_gate"] = container_gate({}, [], False, blocked=msg)
            await emit(task_id, node, StreamStatus.SKIPPED, msg, parent="component_lanes")
            steps[node] = step_record(node, "Docker image", "containerize", "skipped", msg, name, started=t1)
            result["execution_failed"] = True
            return {"result": result, "steps": steps}
        folder = Path(state["workspace"]) / comp["path"]
        source, port = "repository", comp.get("port") or 8080
        if not (folder / "Dockerfile").is_file():
            is_static_frontend = comp.get("kind") == "web-frontend"
            llm = await LLMProvider().get_llm(state.get("provider"))
            if is_static_frontend:
                # Static SPAs (React/Vue/Angular + Vite/Webpack) produce only HTML/JS/CSS – always use
                # nginx to serve them. The LLM often gets this wrong (uses node to serve static files,
                # which exits immediately), so we use the proven template and skip the LLM for this case.
                df = None
            else:
                df = await ask_structured(llm, Dockerfile, "You write production Dockerfiles for CI. The build output already exists "
                                          "in the folder (it was built by the pipeline).",
                                          f"Component {name}: {comp['language']} {comp['framework']}, artifacts {pkg['artifacts'][:10]}, "
                                          f"port {port}.\nFiles:\n{await tools.list_files(comp['path'], 2)}") if llm else None
            content = df.content if df else TEMPLATES.get(comp["language"], "").format(
                port=port, app=f"{comp['app_dir']}/" if comp.get("app_dir") else "")
            port, source = (df.port if df else port), ("written by the agent" if df else "DevOps template")
            if not content:
                msg = f"no Dockerfile and no template for {comp['language']} – add a Dockerfile to the repository"
                result["container_gate"] = container_gate({}, [], False, blocked=msg)
                result["execution_failed"] = True
                steps[node] = step_record(node, "Docker image", "containerize", "skipped", msg, name, started=t1)
                return {"result": result, "steps": steps}
            (folder / "Dockerfile").write_text(content, encoding="utf-8")
        else:
            port = int((re.findall(r"^EXPOSE\s+(\d+)", (folder / "Dockerfile").read_text(errors="replace"), re.M) or [port])[0])
        tag = f"cip-{re.sub(r'[^a-z0-9-]', '-', name.lower())}:{re.sub(r'[^a-z0-9]', '', task_id.lower())[-16:]}"
        await emit(task_id, node, StreamStatus.COMMAND, f"$ docker build -t {tag} . (Dockerfile: {source})")
        image = await docker.call_tool("docker_build", {"context": str(folder), "tag": tag})
        tries, attempt, heal = int(opts.get("self_heal_attempts", 1)), 0, ""
        llm = await LLMProvider().get_llm(state.get("provider")) if not image["built"] or opts.get("heal_cves") else None
        while not image["built"] and llm and attempt < tries:      # self-healing loop: read the build log → fix → rebuild
            attempt += 1
            await emit(task_id, node, StreamStatus.PROGRESS, f"docker build failed – self-healing attempt {attempt}/{tries}: "
                                                             "the agent is reading the build log and fixing the Dockerfile")
            heal += f"\n--- self-healing attempt {attempt} (docker build) ---\n" + await tool_loop(
                llm, tools.tools,
                "You are a release engineer. `docker build` failed for this component in a throw-away copy of the repository. "
                "Read the Dockerfile and the files it copies, find the root cause in the build log and fix the Dockerfile "
                "(or a missing .dockerignore / build file). Do not change application code. Finish with: ROOT CAUSE: … FIX: …",
                f"Component {name} in folder {comp['path']} (Dockerfile: {source}).\nBuild log (end):\n{image.get('log', '')[-6000:]}"
                + (f"\n\nEarlier attempts (did not fix it):\n{heal[-2500:]}" if attempt > 1 else ""),
                task_id, node, max_steps=16)
            image = await docker.call_tool("docker_build", {"context": str(folder), "tag": tag})
        port = exposed_port(folder, port)            # the Dockerfile may have been rewritten – use its EXPOSE
        image.update(port=port, dockerfile_source=source, dockerfile=(folder / "Dockerfile").read_text(errors="replace"))
        scan = await scanner_client().call_tool("trivy_image_scan", {"image": tag}) if image["built"] else {"status": "skipped", "findings": []}
        gate = container_gate(image, scan.get("findings", []), scan.get("status") == "ok")
        cve_try = 0
        while opts.get("heal_cves") and llm and image["built"] and not gate["passed"] and cve_try < tries:
            serious = [f for f in scan.get("findings", []) if f["severity"] in ("CRITICAL", "HIGH") and f.get("fixed_version")]
            if not serious:
                break
            cve_try += 1
            before = f"{sum(f['severity'] == 'CRITICAL' for f in scan['findings'])} critical / {sum(f['severity'] == 'HIGH' for f in scan['findings'])} high"
            await emit(task_id, node, StreamStatus.PROGRESS, f"image has {before} CVEs with fixes available – self-healing attempt "
                                                             f"{cve_try}/{tries}: the agent is hardening the Dockerfile")
            backup = (folder / "Dockerfile").read_text(errors="replace")
            listing = "\n".join(sorted({f"{f['severity']} {f.get('package')} {f.get('installed_version')} → {f.get('fixed_version')}"
                                         for f in serious})[:40])
            heal += f"\n--- self-healing attempt {cve_try} (image CVEs, {before}) ---\n" + await tool_loop(
                llm, tools.tools,
                "You are a release engineer. The container image builds, but its vulnerability scan finds critical / high CVEs "
                "in OS or runtime packages that already have fixed versions. Change ONLY the Dockerfile so the final image "
                "contains the fixed versions: move the base images to a newer patch / minor tag of the same family (e.g. a "
                "newer alpine / slim / nginx tag) and/or upgrade OS packages in the final stage (apk upgrade --no-cache, or "
                "apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*). Keep the same EXPOSE port, user and "
                "start command. Do not change application code. Finish with: ROOT CAUSE: … FIX: …",
                f"Component {name} in folder {comp['path']}.\nDockerfile:\n{backup}\n\nFixable CVEs (package installed → fixed):\n{listing}",
                task_id, node, max_steps=12)
            rebuilt = await docker.call_tool("docker_build", {"context": str(folder), "tag": tag})
            if not rebuilt["built"]:                 # never leave a broken image behind – undo this attempt
                (folder / "Dockerfile").write_text(backup, encoding="utf-8")
                image = await docker.call_tool("docker_build", {"context": str(folder), "tag": tag})
                # keep what the later stages (deploy, release, report) read from the image record
                image.update(port=port, dockerfile_source=source, dockerfile=backup)
                heal += "\n(the hardened Dockerfile did not build – reverted to the previous one)"
                continue
            port = exposed_port(folder, port)
            image = {**rebuilt, "port": port, "dockerfile_source": source + " + CVE hardening by the agent",
                     "dockerfile": (folder / "Dockerfile").read_text(errors="replace")}
            scan = await scanner_client().call_tool("trivy_image_scan", {"image": tag})
            gate = container_gate(image, scan.get("findings", []), scan.get("status") == "ok")
            after = f"{sum(f['severity'] == 'CRITICAL' for f in scan.get('findings', []))} critical / {sum(f['severity'] == 'HIGH' for f in scan.get('findings', []))} high"
            heal += f"\nRESULT: {before} → {after} CVEs after the rebuild"
            await emit(task_id, node, StreamStatus.PROGRESS, f"rebuilt and re-scanned: {before} → {after}")
        attempt += cve_try
        if not image["built"]:
            result["execution_failed"] = True
        result.update(image=image, image_scan=scan, container_gate=gate)
        msg = (f"{tag} ({image.get('size_mb')} MB) · Dockerfile {source} · scan: {scan.get('message', scan['status'])}"
               if image["built"] else f"docker build failed: {image.get('log', '')[-500:]}")
        await emit(task_id, node, StreamStatus.END if image["built"] else StreamStatus.ERROR, msg, parent="component_lanes")
        steps[node] = step_record(node, "Docker image + scan", "containerize", "passed" if image["built"] else "failed", msg, name,
                                  summary={"image": tag, "dockerfile": source, "via": docker.last_transport,
                                           **({"self-heal attempts": attempt} if attempt else {})}, explanation=heal.strip(),
                                  items=scan.get("findings", []), item_type="findings", started=t1)
        steps[f"container_gate.{name}"] = step_record(f"container_gate.{name}", "Container gate", "containerize",
                                                      "passed" if gate["passed"] else "failed",
                                                      "; ".join(f"{c['name']} = {c['actual']}" for c in gate["checks"] if not c["passed"])
                                                      or "all checks passed", name, items=gate["checks"], item_type="checks")
        return {"result": result, "steps": steps}
