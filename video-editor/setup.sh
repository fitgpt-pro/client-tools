#!/usr/bin/env bash
# Idempotent setup script for fitgpt-pro/video-editor on a fresh Linux server.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/video-editor/setup.sh | sudo bash
#
# What it does:
#   1. Ensures Docker is installed
#   2. Ensures at least 1 GB of swap is configured (creates 2 GB /swapfile if missing)
#   3. Picks the first free port starting at 8000
#   4. Downloads docker-compose.yml + .env.example into /opt/video-editor
#   5. Generates ADMIN_TOKEN / METRICS_TOKEN and prompts for OPENAI_API_KEY (first run only)
#   6. Pulls the image and starts the container
#   7. Waits for /health to respond
#   8. Creates the first API key and prints the summary

set -euo pipefail

readonly RAW_BASE="https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/video-editor"
readonly INSTALL_DIR="/opt/video-editor"
readonly COMPOSE_URL="${RAW_BASE}/docker-compose.yml"
readonly ENV_EXAMPLE_URL="${RAW_BASE}/.env.example"

# --- Colors ---
if [[ -t 1 ]]; then
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_RED='\033[0;31m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
  C_BOLD=''
  C_RESET=''
fi

log()  { printf '%b==>%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b!! %s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()  { printf '%b!! %s%b\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# --- 1. Pre-flight checks ---

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

for cmd in curl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# --- 2. Install Docker ---

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log "Docker and Compose plugin already installed."
else
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  command -v docker >/dev/null 2>&1 || die "Docker installation failed."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing."
fi

# --- 3. Configure swap ---

SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
readonly SWAP_KB
if [[ "$SWAP_KB" -lt 1048576 ]]; then  # less than 1 GB
  log "Swap is less than 1 GB ($((SWAP_KB / 1024)) MB). Creating /swapfile (2 GB)..."
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
else
  log "Swap already configured ($((SWAP_KB / 1024)) MB)."
fi

# --- 4. Pick free port ---

find_free_port() {
  for port in $(seq 8000 8100); do
    if ! ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

# --- 5. Prepare install dir + compose file ---

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Downloading docker-compose.yml..."
curl -fsSL "$COMPOSE_URL" -o docker-compose.yml

# --- 6. Generate .env (idempotent — skip if exists) ---

if [[ -f .env ]]; then
  log ".env already exists — skipping secret generation."
  # shellcheck disable=SC1091
  PORT=$(grep -E '^PORT=' .env | head -n1 | cut -d= -f2)
  [[ -n "${PORT:-}" ]] || die "Existing .env has no PORT — refusing to continue."
  ADMIN_TOKEN=$(grep -E '^ADMIN_TOKEN=' .env | head -n1 | cut -d= -f2)
  [[ -n "${ADMIN_TOKEN:-}" ]] || die "Existing .env has no ADMIN_TOKEN — refusing to continue."
else
  log "Downloading .env.example template..."
  curl -fsSL "$ENV_EXAMPLE_URL" -o .env.example

  PORT=$(find_free_port) || die "No free port found in 8000-8100 range."
  log "Picked free port: $PORT"

  ADMIN_TOKEN=$(openssl rand -hex 32)
  METRICS_TOKEN=$(openssl rand -hex 32)

  # OPENAI_API_KEY can be supplied via env var (e.g. for automated / piped installs).
  # Otherwise prompt interactively through /dev/tty so piped `curl | bash` still works.
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    if [[ -t 0 ]]; then
      INPUT_TTY=/dev/stdin
    elif [[ -r /dev/tty ]]; then
      INPUT_TTY=/dev/tty
    else
      die "OPENAI_API_KEY is not set and no interactive TTY is available. Either: (a) export OPENAI_API_KEY=... before piping into bash, or (b) run the script directly: bash setup.sh"
    fi

    printf '%b' "${C_BOLD}Enter OPENAI_API_KEY: ${C_RESET}" > /dev/tty
    read -r OPENAI_API_KEY < "$INPUT_TTY"
  fi
  [[ -n "$OPENAI_API_KEY" ]] || die "OPENAI_API_KEY is required."

  cp .env.example .env
  # Use perl to avoid sed quoting headaches with potential special chars in tokens.
  PORT="$PORT" \
  ADMIN_TOKEN="$ADMIN_TOKEN" \
  METRICS_TOKEN="$METRICS_TOKEN" \
  OPENAI_API_KEY="$OPENAI_API_KEY" \
    perl -i -pe '
      s/^ADMIN_TOKEN=.*/ADMIN_TOKEN=$ENV{ADMIN_TOKEN}/;
      s/^METRICS_TOKEN=.*/METRICS_TOKEN=$ENV{METRICS_TOKEN}/;
      s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=$ENV{OPENAI_API_KEY}/;
      s/^PORT=.*/PORT=$ENV{PORT}/;
    ' .env

  chmod 600 .env
  log "Generated .env with PORT=$PORT and fresh secrets."
fi

# --- 7. Pull image and start ---

log "Pulling image..."
docker compose pull

log "Starting container..."
docker compose up -d

# --- 8. Wait for /health ---

log "Waiting for /health to respond (up to 60 s)..."
for i in $(seq 1 30); do
  if curl -fs "http://localhost:${PORT}/health" >/dev/null 2>&1; then
    log "Health check passed."
    break
  fi
  if [[ $i -eq 30 ]]; then
    docker compose logs --tail 50 video-editor || true
    die "Service did not become healthy in 60 s."
  fi
  sleep 2
done

# --- 9. Create first API key (idempotent — only if .env was freshly generated) ---

FIRST_API_KEY=""
if [[ ! -f .first-api-key.done ]]; then
  log "Creating first API key..."
  RESPONSE=$(curl -fs -X POST "http://localhost:${PORT}/v1/admin/api-keys" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"first-key","scopes":["*"],"created_by":"setup.sh"}' || true)

  if [[ -n "$RESPONSE" ]]; then
    FIRST_API_KEY=$(printf '%s' "$RESPONSE" | grep -oE '"key":"[^"]*"' | head -n1 | cut -d'"' -f4)
    touch .first-api-key.done
  fi
fi

# --- 10. Summary ---

SERVER_IP=$(curl -fs https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR_SERVER_IP')

cat <<EOF

${C_BOLD}${C_GREEN}=== video-editor is up ===${C_RESET}

  URL:           http://${SERVER_IP}:${PORT}
  API docs:      http://${SERVER_IP}:${PORT}/docs
  Health:        http://${SERVER_IP}:${PORT}/health
  Install dir:   ${INSTALL_DIR}

${C_BOLD}Save these secrets now — they will not be shown again:${C_RESET}

  ADMIN_TOKEN:   ${ADMIN_TOKEN}
EOF

if [[ -n "$FIRST_API_KEY" ]]; then
  cat <<EOF
  First API key: ${FIRST_API_KEY}

  Test it:
    curl -H "Authorization: Bearer ${FIRST_API_KEY}" http://${SERVER_IP}:${PORT}/v1/available-fonts
EOF
elif [[ -f .first-api-key.done ]]; then
  cat <<EOF
  First API key: already created on previous run (not stored).
  Create more keys with:
    curl -X POST http://${SERVER_IP}:${PORT}/v1/admin/api-keys \\
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \\
      -H "Content-Type: application/json" \\
      -d '{"name":"my-key","scopes":["*"]}'
EOF
fi

cat <<EOF

${C_BOLD}Logs:${C_RESET}        cd ${INSTALL_DIR} && docker compose logs -f
${C_BOLD}Restart:${C_RESET}     cd ${INSTALL_DIR} && docker compose restart
${C_BOLD}Update:${C_RESET}      cd ${INSTALL_DIR} && docker compose pull && docker compose up -d
EOF
