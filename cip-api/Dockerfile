# CIP API – FastAPI + LangGraph + MCP servers (started by the API itself)
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive

# git (clone repos), Node (npm audit / builds of scanned repos), Docker CLI (talks to the host daemon through the
# mounted socket), Chrome (headless Selenium UI tests)
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg wget unzip \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin nodejs \
    && wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && apt-get install -y ./google-chrome-stable_current_amd64.deb && rm google-chrome-stable_current_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt requirements-scanners.txt ./
RUN pip install -r requirements.txt

# Scanners (own venv + binaries in /app/.scanners). Pass --build-arg GITHUB_TOKEN=... if GitHub rate-limits the downloads.
COPY scripts ./scripts
ARG GITHUB_TOKEN=""
RUN GITHUB_TOKEN=$GITHUB_TOKEN python scripts/install_scanners.py

COPY . .
EXPOSE 8000
# One worker only: runs, the SSE stream and the JSON/SQLite state are local to this process.
CMD ["uvicorn", "main:app", "--host", "127.0.0.1", "--port", "8000"]
