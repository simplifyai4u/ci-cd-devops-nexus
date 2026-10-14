#!/usr/bin/env bash
# CIP DevSecOps platform – installer for a fresh Ubuntu 24.04 (x86_64) host, e.g. an AWS EC2 instance.
#
#   sudo ./deploy/install.sh              install / repair everything and start the app (default)
#   sudo ./deploy/install.sh update       pull the latest code and rebuild
#   sudo ./deploy/install.sh status       show containers and a health check
#   sudo ./deploy/install.sh logs         follow the logs
#   sudo ./deploy/install.sh stop         stop the app (data volumes are kept)
#
# Run it from a clone of the repo, or from anywhere with REPO_URL set (it clones into APP_DIR).
# Safe to re-run: every step checks what is already done.
#
# Optional environment variables:
#   REPO_URL      git URL to clone when not run from inside the repo   (default: the project's GitHub repo)
#   BRANCH        branch to deploy                                      (default: main)
#   APP_DIR       where the code lives when cloned by this script       (default: /opt/cip)
#   GITHUB_TOKEN  token for cloning / pulling a private repo
#   ALLOWED_CIDR  e.g. 203.0.113.7/32 – the only network allowed to reach port 80/443 through ufw.
#                 The app has NO login on the server side and runs the code of the repos it scans, so do not
#                 expose it to the internet. Unset = ports 80/443 stay closed (use the SSH tunnel printed at the end).
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/simplifyai4u/ci-cd-devops-nexus.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/cip}"
CMD="${1:-install}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $*"

# The repo to deploy: the one this script sits in, else APP_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../docker-compose.yml" ]; then APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; fi
DEPLOY_USER="${SUDO_USER:-root}"

git_auth() {   # token goes in a header for this one command – never into .git/config or the process list of the repo
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf -- '-c\nhttp.extraHeader=Authorization: Basic %s\n' "$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
  fi
}
run_git() { local args=(); mapfile -t args < <(git_auth); git "${args[@]}" "$@"; }

compose() { docker compose -f "$APP_DIR/docker-compose.yml" "$@"; }

check_platform() {
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || warn "Tested on Ubuntu 24.04 only (found: ${PRETTY_NAME:-unknown})."
  # cip-api/Dockerfile installs the amd64 Chrome package for the UI tests.
  [ "$(uname -m)" = x86_64 ] || die "x86_64 only (found $(uname -m)): pick a non-Graviton instance type."
  local ram_mb; ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  [ "$ram_mb" -ge 7000 ] || warn "Only ${ram_mb} MB RAM – builds, Chrome and scanners want 8 GB or more."
  local free_gb; free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "$free_gb" -ge 30 ] || warn "Only ${free_gb} GB free on / – image builds fill the disk fast; use 50-100 GB."
}

install_base() {
  log "Base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl git gnupg openssl ufw unattended-upgrades
}

install_docker() {
  if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker already installed ($(docker --version))"
  else
    log "Docker Engine + compose plugin (official apt repo)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # Rotate container logs so they cannot fill the disk.
  if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" } }
JSON
    systemctl restart docker
  fi
  systemctl enable --now docker
  # Pipelines use the default buildx driver so built images land in the local image store.
  docker buildx use default >/dev/null 2>&1 || true
  if [ "$DEPLOY_USER" != root ]; then usermod -aG docker "$DEPLOY_USER" || true; fi
}

fetch_code() {
  if [ -d "$APP_DIR/.git" ]; then
    log "Updating code in $APP_DIR ($BRANCH)"
    run_git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH"
    run_git -C "$APP_DIR" checkout -q "$BRANCH" 2>/dev/null || true
    run_git -C "$APP_DIR" reset --hard "origin/$BRANCH"
  elif [ -f "$APP_DIR/docker-compose.yml" ]; then
    log "Using the code in $APP_DIR"
  else
    log "Cloning $REPO_URL into $APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    run_git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
  fi
}

set_env() {   # set_env KEY VALUE – replace the line in cip-api/.env or append it
  local key="$1" val="$2" f="$APP_DIR/cip-api/.env"
  if grep -qE "^${key}=" "$f"; then sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$f"; else printf '%s="%s"\n' "$key" "$val" >> "$f"; fi
}

configure_env() {
  local f="$APP_DIR/cip-api/.env"
  if [ ! -f "$f" ]; then
    log "Creating cip-api/.env from the example"
    cp "$APP_DIR/cip-api/.env.example" "$f"
    chmod 600 "$f"
    set_env environment production
    # Fernet key (url-safe base64 of 32 bytes) that encrypts the credentials saved on the Settings page.
    set_env settings_secret_key "$(openssl rand -base64 32 | tr '+/' '-_')"
    warn "cip-api/.env was just created. Fill in your LLM key(s) (openai_* / anthropic_* / google_api_key) and"
    warn "github_token if you scan private repos:   sudo nano $f"
    warn "Then run this script again to build and start the app."
    exit 0
  fi
  chmod 600 "$f"
  # Make sure production mode and a persistent secret key are set even on an older .env.
  grep -qE '^environment="?production"?$' "$f" || { warn "environment is not production in .env – setting it"; set_env environment production; }
  if grep -qE '^settings_secret_key=("")?$' "$f"; then
    set_env settings_secret_key "$(openssl rand -base64 32 | tr '+/' '-_')"
    log "Generated settings_secret_key"
  fi
  if ! grep -qE '^(openai_api_key|anthropic_api_key|google_api_key)="[^"]+"' "$f" && ! grep -qE '^llm_provider="?none"?' "$f"; then
    warn "No LLM API key found in .env – agents will fall back to rule-based behaviour (or fail). Set one and re-run."
  fi
}

configure_firewall() {
  log "Firewall (ufw): deny incoming, allow SSH"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  if [ -n "${ALLOWED_CIDR:-}" ]; then
    ufw allow from "$ALLOWED_CIDR" to any port 80,443 proto tcp >/dev/null
    log "Ports 80/443 open to $ALLOWED_CIDR only"
  else
    warn "ALLOWED_CIDR not set: ports 80/443 stay closed. Reach the app through an SSH tunnel (see the end)."
  fi
  ufw --force enable >/dev/null
  # Note: ufw does not filter ports that Docker publishes itself (the pipeline's local registry on :5000).
  # Keep 5000 and the 8000/8051/8052 service ports closed in the EC2 security group as well.
}

start_app() {
  log "Building and starting the app (the first build takes several minutes: Chrome, Node, scanners)"
  compose up -d --build
}

health() {
  log "Waiting for the app to answer"
  local i
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null http://127.0.0.1/api/pipelines 2>/dev/null; then
      printf '\033[1;32mOK\033[0m  the web app and the API answer on this host\n'
      return 0
    fi
    sleep 5
  done
  warn "No answer after 5 minutes. Check:  sudo $0 logs"
  return 1
}

summary() {
  local ip; ip=$(curl -fsS -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')
  cat <<EOF

Done.  Code: $APP_DIR
  Status:   sudo $0 status
  Logs:     sudo $0 logs
  Update:   sudo $0 update

Open the app (from your own machine) through an SSH tunnel – no public port needed:
  ssh -i <key.pem> -L 8080:127.0.0.1:80 ${DEPLOY_USER}@${ip}
  then browse http://localhost:8080/        (UI login is the demo admin/1234 – change it before sharing access)
EOF
  if [ "$DEPLOY_USER" != root ]; then echo "  (log out and in once so '$DEPLOY_USER' can run docker without sudo)"; fi
}

case "$CMD" in
  install)
    check_platform; install_base; install_docker; fetch_code; configure_env; configure_firewall; start_app
    health || true; summary ;;
  update)
    fetch_code; configure_env; start_app; health || true ;;
  status)
    compose ps; curl -fsS -o /dev/null -w 'web/api health: HTTP %{http_code}\n' http://127.0.0.1/api/pipelines || true
    df -h / | tail -1; docker system df ;;
  logs)  compose logs -f --tail=100 ;;
  stop)  compose down ;;
  *)     die "Unknown command '$CMD' (install | update | status | logs | stop)" ;;
esac
