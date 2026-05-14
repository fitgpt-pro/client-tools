#!/usr/bin/env bash
# Idempotent setup script for self-hosted n8n on a fresh Linux server.
#
# Usage:
#   # Plain HTTP, Postgres backend (asks about the domain interactively, Enter to skip):
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash
#
#   # HTTPS via Caddy + Let's Encrypt:
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | \
#     sudo bash -s -- --domain n8n.example.com --email admin@example.com
#
#   # SQLite backend (saves ~300 MB RAM — recommended on hosts shared with another service):
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash -s -- --sqlite
#
#   # Explicit plain-HTTP without a domain prompt (useful for non-interactive sessions):
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash -s -- --http
#
#   # Custom plain-HTTP port:
#   curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | \
#     sudo bash -s -- --port 5680
#
# What it does:
#   1. Ensures Docker is installed
#   2. Ensures at least 1 GB of swap is configured (creates 2 GB /swapfile if missing)
#   3. Picks a port (--port, or first free starting at 5678) — skipped when --domain is set
#   4. Downloads docker-compose(.sqlite).yml, .env(.sqlite).example, init-data.sh (Postgres only), Caddyfile into /opt/n8n
#   5. Generates N8N_ENCRYPTION_KEY (+ Postgres passwords in Postgres mode) — first run only
#   6. Computes N8N_HOST / N8N_PROTOCOL / WEBHOOK_URL / COMPOSE_PROFILES based on --domain
#   7. Pulls images and starts containers (n8n + postgres unless --sqlite, plus caddy when --domain is set)
#   8. Waits for /healthz to respond
#   9. Prints the URL — open in a browser to create the owner account
#
# DB mode is locked at first run. Re-running setup.sh with a different --sqlite state than
# the existing /opt/n8n/.env will abort — to migrate, export workflows from the n8n UI,
# `docker compose down -v` in /opt/n8n, then re-run setup.sh in the new mode.

set -euo pipefail

readonly RAW_BASE="https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n"
readonly INSTALL_DIR="/opt/n8n"
readonly COMPOSE_PG_URL="${RAW_BASE}/docker-compose.yml"
readonly COMPOSE_SQLITE_URL="${RAW_BASE}/docker-compose.sqlite.yml"
readonly ENV_PG_URL="${RAW_BASE}/.env.example"
readonly ENV_SQLITE_URL="${RAW_BASE}/.env.sqlite.example"
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
SQLITE_ARG=0
HTTP_ARG=0

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
    --sqlite)
      SQLITE_ARG=1
      shift
      ;;
    --http)
      HTTP_ARG=1
      shift
      ;;
    -h|--help)
      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

[[ "$HTTP_ARG" -eq 1 && -n "$DOMAIN_ARG" ]] && die "--http and --domain are mutually exclusive."

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

# --- 4. Prepare install dir + resolve DB mode ---

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Detect prior DB mode from existing .env so reruns stay consistent and we can refuse
# accidental cross-mode reruns (which would silently lose data).
EXISTING_MODE=""
if [[ -f .env ]]; then
  if grep -q '^N8N_DB_MODE=sqlite' .env 2>/dev/null; then
    EXISTING_MODE="sqlite"
  elif grep -q '^POSTGRES_PASSWORD=' .env 2>/dev/null; then
    EXISTING_MODE="postgres"
  fi
fi

if [[ "$SQLITE_ARG" -eq 1 ]]; then
  DB_MODE="sqlite"
else
  DB_MODE="${EXISTING_MODE:-postgres}"
fi

if [[ -n "$EXISTING_MODE" && "$EXISTING_MODE" != "$DB_MODE" ]]; then
  die "Existing install in $INSTALL_DIR uses DB mode '$EXISTING_MODE' but you requested '$DB_MODE'.
       Mid-life DB switches are not supported automatically. To migrate:
         1. Export workflows from the n8n UI (Workflows -> menu -> Download).
         2. cd $INSTALL_DIR && docker compose down -v   (this DELETES the volumes!)
         3. Re-run setup.sh in the new mode."
fi

log "Downloading deployment files (mode: $DB_MODE)..."
if [[ "$DB_MODE" == "sqlite" ]]; then
  curl -fsSL "$COMPOSE_SQLITE_URL" -o docker-compose.yml
  rm -f init-data.sh
else
  curl -fsSL "$COMPOSE_PG_URL"  -o docker-compose.yml
  curl -fsSL "$INIT_DATA_URL"   -o init-data.sh
  chmod +x init-data.sh
fi
curl -fsSL "$CADDYFILE_URL" -o Caddyfile

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

# --- 6. Bootstrap/load .env ---
#
# Configuration is split into two layers, so reruns can flip an existing install
# between plain HTTP and HTTPS (Caddy) without losing the encryption key.
#
#   Secrets (generated once, preserved on reruns):
#     N8N_ENCRYPTION_KEY, POSTGRES_PASSWORD, POSTGRES_NON_ROOT_PASSWORD (Postgres mode only)
#
#   Mode-dependent settings (recomputed every run from CLI flags or .env):
#     DOMAIN, ACME_EMAIL, N8N_HOST, N8N_PROTOCOL, WEBHOOK_URL, N8N_SECURE_COOKIE,
#     N8N_PORT, N8N_PORT_BINDING, COMPOSE_PROFILES

if [[ "$DB_MODE" == "sqlite" ]]; then
  curl -fsSL "$ENV_SQLITE_URL" -o .env.example
else
  curl -fsSL "$ENV_PG_URL"     -o .env.example
fi

if [[ ! -f .env ]]; then
  log "First run — creating .env from template..."
  cp .env.example .env
  chmod 600 .env
  FRESH_INSTALL=1
else
  log ".env exists — preserving secrets, may update mode-dependent settings."
  FRESH_INSTALL=0
fi

set -a
# shellcheck source=/dev/null
. ./.env
set +a

# --- 7. Generate any missing secrets (preserve existing ones) ---

[[ -n "${N8N_ENCRYPTION_KEY:-}" ]] || N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

if [[ "$DB_MODE" == "postgres" ]]; then
  [[ -n "${POSTGRES_PASSWORD:-}" ]]          || POSTGRES_PASSWORD=$(openssl rand -hex 32)
  [[ -n "${POSTGRES_NON_ROOT_PASSWORD:-}" ]] || POSTGRES_NON_ROOT_PASSWORD=$(openssl rand -hex 32)
else
  POSTGRES_PASSWORD=""
  POSTGRES_NON_ROOT_PASSWORD=""
fi

# --- 8. Resolve mode (HTTPS vs plain HTTP) ---
#
# Precedence:
#   1. --domain on CLI wins (lets reruns flip plain HTTP → HTTPS)
#   2. Otherwise reuse DOMAIN from existing .env
#   3. Otherwise prompt interactively on a fresh install

EXISTING_DOMAIN="${DOMAIN:-}"

if [[ -n "$DOMAIN_ARG" ]]; then
  DOMAIN="$DOMAIN_ARG"
  ACME_EMAIL="$EMAIL_ARG"
  [[ -n "$ACME_EMAIL" ]] || die "--domain requires --email (used for Let's Encrypt registration)"
  if [[ -n "$EXISTING_DOMAIN" && "$EXISTING_DOMAIN" != "$DOMAIN" ]]; then
    log "Switching DOMAIN: $EXISTING_DOMAIN -> $DOMAIN"
  elif [[ -z "$EXISTING_DOMAIN" ]]; then
    log "Switching from plain HTTP to HTTPS via Caddy (domain: $DOMAIN)"
  fi
elif [[ -n "$EXISTING_DOMAIN" ]]; then
  DOMAIN="$EXISTING_DOMAIN"
  log "Reusing DOMAIN=$DOMAIN from .env"
elif [[ "$FRESH_INSTALL" -eq 1 && "$HTTP_ARG" -eq 0 ]]; then
  # Interactive prompt only on a fresh install when the caller did not explicitly
  # opt out via --http. We try three sources for the prompt, in order:
  #   1. stdin is a TTY (`bash setup.sh` run directly from a terminal)
  #   2. /dev/tty is genuinely usable for read+write (interactive ssh, sudo from a TTY)
  #   3. otherwise: skip the prompt and pick plain HTTP, warning the operator.
  #
  # `[[ -r /dev/tty ]]` is not enough: on non-interactive ssh sessions the file
  # exists and is readable per stat() but actually opening it for read or write
  # fails ("No such device or address"). We probe both directions in a subshell
  # to be certain.
  tty_usable() {
    ( : >/dev/tty ) 2>/dev/null && ( : </dev/tty ) 2>/dev/null
  }

  INPUT_TTY=""
  if [[ -t 0 ]]; then
    INPUT_TTY=/dev/stdin
  elif tty_usable; then
    INPUT_TTY=/dev/tty
  fi

  DOMAIN=""
  ACME_EMAIL=""
  if [[ -n "$INPUT_TTY" ]]; then
    if [[ "$INPUT_TTY" == /dev/tty ]]; then
      printf '%b' "${C_BOLD}Do you have a domain pointing to this server? (Enter to skip, or type domain): ${C_RESET}" >/dev/tty
    else
      printf '%b' "${C_BOLD}Do you have a domain pointing to this server? (Enter to skip, or type domain): ${C_RESET}"
    fi
    read -r DOMAIN < "$INPUT_TTY" || DOMAIN=""
    if [[ -n "$DOMAIN" ]]; then
      if [[ "$INPUT_TTY" == /dev/tty ]]; then
        printf '%b' "${C_BOLD}Email for Let's Encrypt notifications: ${C_RESET}" >/dev/tty
      else
        printf '%b' "${C_BOLD}Email for Let's Encrypt notifications: ${C_RESET}"
      fi
      read -r ACME_EMAIL < "$INPUT_TTY" || ACME_EMAIL=""
      [[ -n "$ACME_EMAIL" ]] || die "Email is required when a domain is provided."
    fi
  else
    warn "No interactive terminal available — defaulting to plain HTTP."
    warn "Re-run with --domain DOMAIN --email EMAIL to enable HTTPS, or pass --http to suppress this warning."
  fi
fi

# --- 9. Compute mode-dependent settings ---

if [[ -n "${DOMAIN:-}" ]]; then
  # HTTPS via Caddy: n8n stays on docker network only; bind to loopback so the
  # host's :5678 is never publicly exposed (Caddy is the single public entrypoint).
  [[ -n "${ACME_EMAIL:-}" ]] || die "DOMAIN is set but ACME_EMAIL is missing — pass --email or edit .env"
  N8N_PORT="5678"
  N8N_PORT_BINDING="127.0.0.1:5678:5678"
  N8N_HOST="$DOMAIN"
  N8N_PROTOCOL="https"
  WEBHOOK_URL="https://${DOMAIN}/"
  N8N_SECURE_COOKIE="true"
  COMPOSE_PROFILES="proxy"
else
  # Plain HTTP: publish on 0.0.0.0:N8N_PORT.
  # Priority: --port flag > existing N8N_PORT in .env > first free port from 5678.
  if [[ -n "$PORT_ARG" ]]; then
    N8N_PORT="$PORT_ARG"
  elif [[ -z "${N8N_PORT:-}" ]]; then
    N8N_PORT=$(find_free_port) || die "No free port found in 5678-5800 range."
    log "Picked free port: $N8N_PORT"
  fi
  N8N_PORT_BINDING="${N8N_PORT}:5678"
  SERVER_IP=$(curl -fs https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')
  N8N_HOST="$SERVER_IP"
  N8N_PROTOCOL="http"
  WEBHOOK_URL=""
  N8N_SECURE_COOKIE="false"
  COMPOSE_PROFILES=""
  ACME_EMAIL="${ACME_EMAIL:-}"
fi

# --- 10. Write .env (always — applies updated mode-dependent settings) ---

# Use perl to avoid sed quoting headaches with secrets that may contain slashes.
N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
POSTGRES_NON_ROOT_PASSWORD="$POSTGRES_NON_ROOT_PASSWORD" \
N8N_PORT="$N8N_PORT" \
N8N_PORT_BINDING="$N8N_PORT_BINDING" \
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
    s/^N8N_PORT_BINDING=.*/N8N_PORT_BINDING=$ENV{N8N_PORT_BINDING}/;
    s/^DOMAIN=.*/DOMAIN=$ENV{DOMAIN}/;
    s/^ACME_EMAIL=.*/ACME_EMAIL=$ENV{ACME_EMAIL}/;
    s/^N8N_HOST=.*/N8N_HOST=$ENV{N8N_HOST}/;
    s/^N8N_PROTOCOL=.*/N8N_PROTOCOL=$ENV{N8N_PROTOCOL}/;
    s|^WEBHOOK_URL=.*|WEBHOOK_URL=$ENV{WEBHOOK_URL}|;
    s/^N8N_SECURE_COOKIE=.*/N8N_SECURE_COOKIE=$ENV{N8N_SECURE_COOKIE}/;
    s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$ENV{COMPOSE_PROFILES}/;
  ' .env

# Persist the DB mode so future reruns can detect it and refuse cross-mode changes.
if ! grep -q '^N8N_DB_MODE=' .env; then
  printf '\n# DB mode marker (set by setup.sh, do not edit) ===\nN8N_DB_MODE=%s\n' "$DB_MODE" >> .env
else
  DB_MODE_VAL="$DB_MODE" perl -i -pe 's/^N8N_DB_MODE=.*/N8N_DB_MODE=$ENV{DB_MODE_VAL}/' .env
fi

chmod 600 .env

# Re-load so any downstream commands see the final values.
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

if [[ "$DB_MODE" == "sqlite" ]]; then
  DB_DESC="SQLite (volume: n8n_storage, path: /home/node/.n8n/database.sqlite)"
  BACKUP_CMD="cd ${INSTALL_DIR} && docker compose exec -T n8n tar czf - -C /home/node/.n8n database.sqlite > n8n-backup-\$(date +%F).tar.gz"
  BACKUP_LABEL="Backup SQLite"
else
  DB_DESC="Postgres (in-cluster, volume: db_storage)"
  BACKUP_CMD="cd ${INSTALL_DIR} && docker compose exec -T postgres pg_dump -U n8n n8n | gzip > n8n-backup-\$(date +%F).sql.gz"
  BACKUP_LABEL="Backup Postgres"
fi

cat <<EOF

${C_BOLD}${C_GREEN}=== n8n is up ===${C_RESET}

  URL:           ${PUBLIC_URL}
  Install dir:   ${INSTALL_DIR}
  Database:      ${DB_DESC}

${C_BOLD}First-run steps:${C_RESET}
  1. Open the URL in a browser
  2. Create the owner account (email + password)
  3. n8n redirects to the workflows dashboard

${C_BOLD}${BACKUP_LABEL}:${C_RESET}
  ${BACKUP_CMD}

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
