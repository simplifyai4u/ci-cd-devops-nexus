#!/usr/bin/env bash
# CIP DevSecOps platform – NATIVE installer (no Docker for the app itself) for a fresh Ubuntu 24.04 x86_64 host.
#
#   API  : Python venv + uvicorn, run by systemd (cip-api.service) on 127.0.0.1:8000, as the unprivileged user "cip"
#   Web  : React build (cip-app/dist) served by nginx on port 80, /api/ proxied to the API (same as cip-app/nginx.conf)
#   Also : Node 20, Google Chrome (Selenium UI tests), the security scanners, and Docker Engine – the PIPELINES
#          build / scan / run the scanned apps' images with Docker, so the host needs it even though CIP does not run in it.
#
#   sudo ./deploy/install-native.sh              install / repair everything and start the services (default)
#   sudo ./deploy/install-native.sh update       sync / pull the code, reinstall dependencies, rebuild the UI, restart
#   sudo ./deploy/install-native.sh status       service state + health check
#   sudo ./deploy/install-native.sh logs         follow the API log
#   sudo ./deploy/install-native.sh restart|stop|start
#
# Run it from a clone of the repo (that code is copied to APP_DIR) or set REPO_URL to clone it. Safe to re-run.
#
# Optional environment variables:
#   APP_DIR          install location                                   (default: /opt/cip)
#   REPO_URL/BRANCH  used when the script is not run from a clone       (default: the project's GitHub repo / main)
#   GITHUB_TOKEN     private repo clone, and avoids GitHub rate limits when downloading the scanners
#   INSTALL_DOCKER   1|0  Docker Engine for the pipelines' image stages (default 1; 0 = container stages unavailable)
#   INSTALL_CHROME   1|0  Chrome for the UI-test stage                  (default 1)
#   INSTALL_SCANNERS 1|0  semgrep, trivy, gitleaks, ... into .scanners  (default 1)
#   ALLOWED_CIDR     e.g. 203.0.113.7/32 – the only network ufw lets reach port 80. The app has NO server-side login
#                    and executes the code of the repos it scans: do not expose it to the internet. Unset = port 80
#                    stays closed (use the SSH tunnel printed at the end).
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/simplifyai4u/ci-cd-devops-nexus.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/cip}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
INSTALL_CHROME="${INSTALL_CHROME:-1}"
INSTALL_SCANNERS="${INSTALL_SCANNERS:-1}"
SVC_USER=cip
SVC_HOME=/var/lib/cip
CMD="${1:-install}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR=""; [ -f "$SCRIPT_DIR/../cip-api/main.py" ] && SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGIN_USER="${SUDO_USER:-root}"
cd /   # commands run as the service user must not start in a directory it cannot read (e.g. /home/ubuntu)

as_svc() { runuser -u "$SVC_USER" -- env HOME="$SVC_HOME" "$@"; }
run_git() {   # the token goes into a header for this one command – never into .git/config
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    git -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)" "$@"
  else git "$@"; fi
}

check_platform() {
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || warn "Tested on Ubuntu 24.04 only (found: ${PRETTY_NAME:-unknown})."
  [ "$(uname -m)" = x86_64 ] || die "x86_64 only (found $(uname -m)): the UI tests need the amd64 Chrome package."
  local ram_mb free_gb
  ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "$ram_mb" -ge 7000 ] || warn "Only ${ram_mb} MB RAM – builds, Chrome and scanners want 8 GB or more."
  [ "$free_gb" -ge 30 ]  || warn "Only ${free_gb} GB free on / – pipelines fill the disk fast; use 50-100 GB."
}

install_packages() {
  log "System packages (python3, git, nginx, build tools, ufw)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl wget git gnupg openssl unzip rsync \
    python3 python3-venv python3-pip build-essential nginx ufw unattended-upgrades
  python3 --version | grep -q '^Python 3\.12' || warn "Python $(python3 -V) – the project is built for 3.12 (Ubuntu 24.04's default)."
}

install_node() {
  if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; then
    log "Node $(node -v) already installed"; return
  fi
  log "Node.js 20 (NodeSource apt repo)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y && apt-get install -y nodejs
}

install_docker() {
  [ "$INSTALL_DOCKER" = 1 ] || { warn "INSTALL_DOCKER=0: image build / deploy / Trivy-image stages will not work."; return; }
  if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker already installed ($(docker --version))"
  else
    log "Docker Engine (official apt repo) – used by the pipelines, not to run CIP"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if [ ! -f /etc/docker/daemon.json ]; then   # rotate container logs so they cannot fill the disk
    echo '{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" } }' > /etc/docker/daemon.json
    systemctl restart docker
  fi
  systemctl enable --now docker
}

install_chrome() {
  [ "$INSTALL_CHROME" = 1 ] || { warn "INSTALL_CHROME=0: the UI-test stage will not work."; return; }
  if command -v google-chrome >/dev/null; then log "Chrome already installed"; return; fi
  log "Google Chrome (headless Selenium UI tests)"
  local deb; deb="$(mktemp --suffix=.deb)"
  wget -q -O "$deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y "$deb"; rm -f "$deb"
}

create_user() {
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    log "Service user '$SVC_USER'"
    useradd --system --create-home --home-dir "$SVC_HOME" --shell /usr/sbin/nologin "$SVC_USER"
  fi
  # The pipelines talk to the Docker daemon. Note: docker-group membership is root-equivalent on this host.
  if [ "$INSTALL_DOCKER" = 1 ] && getent group docker >/dev/null; then usermod -aG docker "$SVC_USER"; fi
  if [ "$LOGIN_USER" != root ] && getent group docker >/dev/null; then usermod -aG docker "$LOGIN_USER" || true; fi
}

sync_code() {
  mkdir -p "$APP_DIR"
  if [ -n "$SRC_DIR" ] && [ "$(readlink -f "$SRC_DIR")" != "$(readlink -f "$APP_DIR")" ]; then
    log "Copying the code from $SRC_DIR to $APP_DIR (keeping .env, data, runs, venv, scanners)"
    rsync -a \
      --exclude='.env' --exclude='.settings.key' --exclude='venv/' --exclude='.venv/' --exclude='.scanners/' \
      --exclude='data/*.json' --exclude='runs/' --exclude='stream_events.db*' --exclude='__pycache__/' \
      --exclude='node_modules/' --exclude='dist/' \
      "$SRC_DIR"/ "$APP_DIR"/
  elif [ -d "$APP_DIR/.git" ]; then
    log "Updating $APP_DIR from origin/$BRANCH"
    run_git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH"
    run_git -C "$APP_DIR" reset --hard "origin/$BRANCH"
  elif [ -f "$APP_DIR/cip-api/main.py" ]; then
    log "Using the code already in $APP_DIR"
  else
    log "Cloning $REPO_URL into $APP_DIR"
    run_git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
  fi
  mkdir -p "$APP_DIR/cip-api/data" "$APP_DIR/cip-api/runs"
  chown -R "$SVC_USER:$SVC_USER" "$APP_DIR"
  chmod 755 "$APP_DIR"   # nginx (www-data) must be able to read cip-app/dist
}

set_env() {   # set_env KEY VALUE – replace the line in cip-api/.env or append it
  local key="$1" val="$2" f="$APP_DIR/cip-api/.env"
  if grep -qE "^${key}=" "$f"; then sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$f"; else printf '%s="%s"\n' "$key" "$val" >> "$f"; fi
}

configure_env() {
  local f="$APP_DIR/cip-api/.env" fresh=0
  if [ ! -f "$f" ]; then
    log "Creating cip-api/.env from the example"
    cp "$APP_DIR/cip-api/.env.example" "$f"; fresh=1
    set_env environment production
    set_env settings_secret_key "$(openssl rand -base64 32 | tr '+/' '-_')"   # Fernet key for the Settings page
  fi
  chown "$SVC_USER:$SVC_USER" "$f"; chmod 600 "$f"
  grep -qE '^environment="?production"?$' "$f" || { warn "environment is not production in .env – setting it"; set_env environment production; }
  if grep -qE '^settings_secret_key=("")?$' "$f"; then set_env settings_secret_key "$(openssl rand -base64 32 | tr '+/' '-_')"; fi
  if [ "$fresh" = 1 ]; then
    warn "cip-api/.env was just created. Add your LLM key(s) (openai_* / anthropic_* / google_api_key) and github_token"
    warn "(private repos):   sudo nano $f"
    warn "Then run this script again to install the dependencies and start the services."
    exit 0
  fi
  grep -qE '^(openai_api_key|anthropic_api_key|google_api_key)="[^"]+"' "$f" || grep -qE '^llm_provider="?none"?' "$f" \
    || warn "No LLM API key in .env – the agents fall back to rule-based behaviour (or fail). Set one and re-run."
}

install_backend() {
  log "API: Python venv + requirements"
  [ -x "$APP_DIR/cip-api/venv/bin/python" ] || as_svc python3 -m venv "$APP_DIR/cip-api/venv"
  as_svc "$APP_DIR/cip-api/venv/bin/pip" install --upgrade pip
  as_svc "$APP_DIR/cip-api/venv/bin/pip" install -r "$APP_DIR/cip-api/requirements.txt"
  if [ "$INSTALL_SCANNERS" = 1 ] && [ ! -f "$APP_DIR/cip-api/.scanners/installed.txt" ]; then
    log "Security scanners into cip-api/.scanners (own venv + downloaded binaries – a few minutes)"
    (cd "$APP_DIR/cip-api" && as_svc env GITHUB_TOKEN="${GITHUB_TOKEN:-}" venv/bin/python scripts/install_scanners.py) \
      && as_svc touch "$APP_DIR/cip-api/.scanners/installed.txt" \
      || warn "Scanner install had problems – the pipeline repairs missing scanners itself (Settings → Scanners → Repair)."
  fi
}

build_frontend() {
  log "UI: npm ci + vite build"
  (cd "$APP_DIR/cip-app" && as_svc npm ci --no-audit --no-fund && as_svc npm run build)
}

write_services() {
  log "systemd unit cip-api.service and the nginx site"
  cat > /etc/systemd/system/cip-api.service <<EOF
[Unit]
Description=CIP DevSecOps API (FastAPI + LangGraph, starts the scanner/docker MCP servers itself)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$APP_DIR/cip-api
Environment=HOME=$SVC_HOME
Environment=PYTHONUNBUFFERED=1
Environment=PATH=$APP_DIR/cip-api/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# One worker only: runs, the SSE stream and the JSON/SQLite state are local to this process.
ExecStart=$APP_DIR/cip-api/venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=60
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/nginx/sites-available/cip <<EOF
server {
    listen 80 default_server;
    server_name _;
    root $APP_DIR/cip-app/dist;
    index index.html;

    # API on 127.0.0.1:8000; the /api prefix is stripped (as in vite.config.js and cip-app/nginx.conf)
    location /api/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_buffering off;            # live logs / SSE
        proxy_cache off;
        proxy_read_timeout 3600s;
    }

    location / {
        try_files \$uri /index.html;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/cip /etc/nginx/sites-enabled/cip
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl daemon-reload
  systemctl enable nginx cip-api >/dev/null 2>&1
}

configure_firewall() {
  log "Firewall (ufw): deny incoming, allow SSH"
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null; ufw allow OpenSSH >/dev/null
  if [ -n "${ALLOWED_CIDR:-}" ]; then
    ufw allow from "$ALLOWED_CIDR" to any port 80 proto tcp >/dev/null; log "Port 80 open to $ALLOWED_CIDR only"
  else
    warn "ALLOWED_CIDR not set: port 80 stays closed. Reach the app through an SSH tunnel (see the end)."
  fi
  ufw --force enable >/dev/null
  # The scanner / docker MCP servers listen on 0.0.0.0:8051/8052 WITHOUT authentication (docker_run!) – ufw's default
  # deny keeps them private. Docker-published ports (the pipeline's local registry on :5000) bypass ufw:
  # keep 5000, 8000, 8051 and 8052 closed in the EC2 security group too.
}

start_services() {
  log "Starting cip-api and nginx"
  systemctl restart cip-api
  systemctl restart nginx
}

health() {
  log "Waiting for the API and the web app"
  local i
  for i in $(seq 1 40); do
    if curl -fsS -o /dev/null http://127.0.0.1:8000/pipelines 2>/dev/null && curl -fsS -o /dev/null http://127.0.0.1/api/pipelines 2>/dev/null; then
      printf '\033[1;32mOK\033[0m  API (:8000) and web (:80, /api proxy) answer\n'; return 0
    fi
    sleep 3
  done
  warn "No answer after 2 minutes. Check:  sudo $0 logs    and    sudo journalctl -u nginx -n 50"
  return 1
}

summary() {
  local ip; ip=$(curl -fsS -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')
  cat <<EOF

Done.  Code: $APP_DIR   API service: cip-api   Data: $APP_DIR/cip-api/data, $APP_DIR/cip-api/runs
  Status:  sudo $0 status        Logs:  sudo $0 logs        Update:  sudo $0 update

Open the app from your own machine through an SSH tunnel (no public port needed):
  ssh -i <key.pem> -L 8080:127.0.0.1:80 ${LOGIN_USER}@${ip}
  then browse http://localhost:8080/       (UI login is the demo admin/1234 – change it before sharing access)
EOF
}

case "$CMD" in
  install)
    check_platform; install_packages; install_node; install_docker; install_chrome; create_user
    sync_code; configure_env; install_backend; build_frontend; write_services; configure_firewall; start_services
    health || true; summary ;;
  update)
    create_user; sync_code; configure_env; install_backend; build_frontend; write_services; start_services; health || true ;;
  status)
    systemctl --no-pager status cip-api nginx | grep -E 'Loaded|Active|●' || true
    curl -fsS -o /dev/null -w 'API  direct : HTTP %{http_code}\n' http://127.0.0.1:8000/pipelines || echo "API  direct : down"
    curl -fsS -o /dev/null -w 'Web  /api   : HTTP %{http_code}\n' http://127.0.0.1/api/pipelines || echo "Web  /api   : down"
    df -h / | tail -1; command -v docker >/dev/null && docker system df || true ;;
  logs)    journalctl -u cip-api -f -n 100 ;;
  restart) systemctl restart cip-api nginx ;;
  stop)    systemctl stop cip-api ;;
  start)   systemctl start cip-api nginx ;;
  *)       die "Unknown command '$CMD' (install | update | status | logs | restart | stop | start)" ;;
esac
