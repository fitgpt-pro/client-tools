#!/usr/bin/env bash
# Idempotent setup script for self-hosted n8n on a fresh Linux server.
#
# Usage:
#   # Plain HTTP (asks about the domain interactively, Enter to skip):
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash
#
#   # HTTPS via Caddy + Let's Encrypt:
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | \
#     sudo bash -s -- --domain n8n.example.com --email admin@example.com
#
#   # Custom plain-HTTP port:
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | \
#     sudo bash -s -- --port 5680
#
# What it does:
#   1. Ensures Docker is installed
#   2. Ensures at least 1 GB of swap is configured (creates 2 GB /swapfile if missing)
#   3. Picks a port (--port, or first free starting at 5678) — skipped when --domain is set
#   4. Downloads docker-compose.yml, .env.example, init-data.sh, Caddyfile into /opt/n8n
#   5. Generates N8N_ENCRYPTION_KEY + Postgres passwords (first run only)
#   6. Computes N8N_HOST / N8N_PROTOCOL / WEBHOOK_URL / COMPOSE_PROFILES based on --domain
#   7. Pulls images and starts containers (n8n + postgres, plus caddy when --domain is set)
#   8. Waits for /healthz to respond
#   9. Prints the URL — open in a browser to create the owner account

set -euo pipefail

readonly RAW_BASE="https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n"
readonly INSTALL_DIR="/opt/n8n"
readonly COMPOSE_URL="${RAW_BASE}/docker-compose.yml"
readonly ENV_EXAMPLE_URL="${RAW_BASE}/.env.example"
readonly INIT_DATA_URL="${RAW_BASE}/init-data.sh"
readonly CADDYFILE_URL="${RAW_BASE}/Caddyfile"

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

# --- Parse args ---

DOMAIN_ARG=""
EMAIL_ARG=""
PORT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN_ARG="${2:-}"
      [[ -n "$DOMAIN_ARG" ]] || die "--domain requires a value (e.g. --domain n8n.example.com)"
      shift 2
      ;;
    --email)
      EMAIL_ARG="${2:-}"
      [[ -n "$EMAIL_ARG" ]] || die "--email requires a value (e.g. --email you@example.com)"
      shift 2
      ;;
    --port)
      PORT_ARG="${2:-}"
      [[ "$PORT_ARG" =~ ^[0-9]+$ ]] || die "--port requires a numeric value"
      shift 2
      ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

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

# --- 4. Prepare install dir + download files ---

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Downloading deployment files..."
curl -fsSL "$COMPOSE_URL"    -o docker-compose.yml
curl -fsSL "$INIT_DATA_URL"  -o init-data.sh
curl -fsSL "$CADDYFILE_URL"  -o Caddyfile
chmod +x init-data.sh

# --- 5. Pick free port (plain-HTTP mode only) ---

find_free_port() {
  for port in $(seq 5678 5800); do
    if ! ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

# --- 6. Determine HTTPS vs plain-HTTP mode ---

DOMAIN=""
ACME_EMAIL=""

if [[ -n "$DOMAIN_ARG" ]]; then
  DOMAIN="$DOMAIN_ARG"
  ACME_EMAIL="$EMAIL_ARG"
  [[ -n "$ACME_EMAIL" ]] || die "--domain requires --email (used for Let's Encrypt registration)"
elif [[ ! -f .env ]]; then
  # Interactive prompt only on fresh install.
  if [[ -t 0 ]]; then
    INPUT_TTY=/dev/stdin
  elif [[ -r /dev/tty ]]; then
    INPUT_TTY=/dev/tty
  else
    INPUT_TTY=""
  fi

  if [[ -n "$INPUT_TTY" ]]; then
    printf '%b' "${C_BOLD}Do you have a domain pointing to this server? (Enter to skip, or type domain): ${C_RESET}" > /dev/tty
    read -r DOMAIN < "$INPUT_TTY" || DOMAIN=""
    if [[ -n "$DOMAIN" ]]; then
      printf '%b' "${C_BOLD}Email for Let's Encrypt notifications: ${C_RESET}" > /dev/tty
      read -r ACME_EMAIL < "$INPUT_TTY" || ACME_EMAIL=""
      [[ -n "$ACME_EMAIL" ]] || die "Email is required when a domain is provided."
    fi
  fi
fi

# --- 7. Generate .env (idempotent — skip if exists) ---

if [[ -f .env ]]; then
  log ".env already exists — skipping secret generation."
else
  log "Downloading .env.example template..."
  curl -fsSL "$ENV_EXAMPLE_URL" -o .env.example

  if [[ -n "$DOMAIN" ]]; then
    N8N_PORT="5678"  # internal only; Caddy listens on 80/443
    N8N_HOST="$DOMAIN"
    N8N_PROTOCOL="https"
    WEBHOOK_URL="https://${DOMAIN}/"
    N8N_SECURE_COOKIE="true"
    COMPOSE_PROFILES="proxy"
  else
    if [[ -n "$PORT_ARG" ]]; then
      N8N_PORT="$PORT_ARG"
    else
      N8N_PORT=$(find_free_port) || die "No free port found in 5678-5800 range."
    fi
    log "Picked port: $N8N_PORT"
    SERVER_IP=$(curl -fs https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')
    N8N_HOST="$SERVER_IP"
    N8N_PROTOCOL="http"
    WEBHOOK_URL=""
    N8N_SECURE_COOKIE="false"
    COMPOSE_PROFILES=""
  fi

  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  POSTGRES_PASSWORD=$(openssl rand -hex 32)
  POSTGRES_NON_ROOT_PASSWORD=$(openssl rand -hex 32)

  cp .env.example .env
  # Use perl to avoid sed quoting headaches with secrets that may contain slashes.
  N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
  POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  POSTGRES_NON_ROOT_PASSWORD="$POSTGRES_NON_ROOT_PASSWORD" \
  N8N_PORT="$N8N_PORT" \
  DOMAIN="$DOMAIN" \
  ACME_EMAIL="$ACME_EMAIL" \
  N8N_HOST="$N8N_HOST" \
  N8N_PROTOCOL="$N8N_PROTOCOL" \
  WEBHOOK_URL="$WEBHOOK_URL" \
  N8N_SECURE_COOKIE="$N8N_SECURE_COOKIE" \
  COMPOSE_PROFILES="$COMPOSE_PROFILES" \
    perl -i -pe '
      s/^N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$ENV{N8N_ENCRYPTION_KEY}/;
      s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$ENV{POSTGRES_PASSWORD}/;
      s/^POSTGRES_NON_ROOT_PASSWORD=.*/POSTGRES_NON_ROOT_PASSWORD=$ENV{POSTGRES_NON_ROOT_PASSWORD}/;
      s/^N8N_PORT=.*/N8N_PORT=$ENV{N8N_PORT}/;
      s/^DOMAIN=.*/DOMAIN=$ENV{DOMAIN}/;
      s/^ACME_EMAIL=.*/ACME_EMAIL=$ENV{ACME_EMAIL}/;
      s/^N8N_HOST=.*/N8N_HOST=$ENV{N8N_HOST}/;
      s/^N8N_PROTOCOL=.*/N8N_PROTOCOL=$ENV{N8N_PROTOCOL}/;
      s|^WEBHOOK_URL=.*|WEBHOOK_URL=$ENV{WEBHOOK_URL}|;
      s/^N8N_SECURE_COOKIE=.*/N8N_SECURE_COOKIE=$ENV{N8N_SECURE_COOKIE}/;
      s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$ENV{COMPOSE_PROFILES}/;
    ' .env

  chmod 600 .env
  log "Generated .env with fresh secrets."
fi

# Re-read .env so the rest of the script can use the values (works on both fresh and existing installs).
set -a
# shellcheck source=/dev/null
. ./.env
set +a

# --- 8. Pull images and start ---

log "Pulling images..."
docker compose pull

log "Starting containers..."
docker compose up -d

# --- 9. Wait for /healthz ---

log "Waiting for n8n /healthz to respond (up to 90 s)..."
HEALTHY=0
for _ in $(seq 1 45); do
  # Always probe from inside the network: works for both plain HTTP and HTTPS modes
  # (in HTTPS mode the host port may not be published).
  if docker compose exec -T n8n wget -qO- http://localhost:5678/healthz >/dev/null 2>&1; then
    HEALTHY=1
    log "n8n is healthy."
    break
  fi
  sleep 2
done

if [[ "$HEALTHY" -ne 1 ]]; then
  docker compose logs --tail 80 n8n || true
  die "n8n did not become healthy in 90 s."
fi

# --- 10. Summary ---

if [[ -n "${DOMAIN:-}" ]]; then
  PUBLIC_URL="https://${DOMAIN}"
else
  # Re-resolve IP for display (may differ from .env if changed).
  DISPLAY_IP=$(curl -fs https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "${N8N_HOST}")
  PUBLIC_URL="http://${DISPLAY_IP}:${N8N_PORT}"
fi

cat <<EOF

${C_BOLD}${C_GREEN}=== n8n is up ===${C_RESET}

  URL:           ${PUBLIC_URL}
  Install dir:   ${INSTALL_DIR}
  Database:      Postgres (in-cluster, volume: db_storage)

${C_BOLD}First-run steps:${C_RESET}
  1. Open the URL in a browser
  2. Create the owner account (email + password)
  3. n8n redirects to the workflows dashboard

${C_BOLD}Backup Postgres:${C_RESET}
  cd ${INSTALL_DIR} && docker compose exec -T postgres pg_dump -U n8n n8n | gzip > n8n-backup-\$(date +%F).sql.gz

${C_BOLD}Logs:${C_RESET}        cd ${INSTALL_DIR} && docker compose logs -f
${C_BOLD}Restart:${C_RESET}     cd ${INSTALL_DIR} && docker compose restart
${C_BOLD}Update:${C_RESET}      cd ${INSTALL_DIR} && docker compose pull && docker compose up -d
EOF

if [[ -z "${DOMAIN:-}" ]]; then
  cat <<EOF

${C_YELLOW}${C_BOLD}WARNING:${C_RESET} n8n is running on plain HTTP. External webhooks (Telegram, Stripe, etc.)
require HTTPS. To enable HTTPS later, re-run setup.sh with:
  --domain your.domain.com --email you@example.com
(DNS A record must point to this server first.)
EOF
fi
