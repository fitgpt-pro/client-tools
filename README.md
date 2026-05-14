# client-tools

Public deployment files and setup scripts for self-hostable [fitgpt-pro](https://github.com/fitgpt-pro) services.

The source code of the services lives in private repositories; the Docker images are public on GitHub Container Registry. This repo holds everything operators (and external clients) need to run them.

## Services

### video-editor

FastAPI video processing service (FFmpeg-backed) — extract audio, generate subtitles, compose social videos, uniquify videos, etc.

**Source (private):** https://github.com/fitgpt-pro/video-editor
**Image (public):** `ghcr.io/fitgpt-pro/video-editor:latest`

#### Quick start on a fresh Ubuntu/Debian server

Minimal tier: 2 CPU, 2 GB RAM, 20 GB disk.

```bash
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/video-editor/setup.sh | sudo bash
```

The script will:

1. Install Docker if missing
2. Add 2 GB of swap if the server has less than 1 GB
3. Pick the first free port starting at 8000
4. Pull the image and start the container
5. Generate `ADMIN_TOKEN`, `METRICS_TOKEN`, ask for `OPENAI_API_KEY`
6. Create the first API key and print the URL + tokens

Files end up in `/opt/video-editor/`. Re-running the script is safe — it skips secret regeneration if `.env` exists.

#### Manual deployment

If you prefer to set things up by hand:

```bash
mkdir -p /opt/video-editor && cd /opt/video-editor
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/video-editor/docker-compose.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/video-editor/.env.example -o .env
# Edit .env — set ADMIN_TOKEN, METRICS_TOKEN, OPENAI_API_KEY
docker compose pull && docker compose up -d
```

For configuration reference (env vars, performance tiers, etc.) see the main repo: https://github.com/fitgpt-pro/video-editor

### n8n

Self-hosted [n8n](https://n8n.io) workflow automation with PostgreSQL backend and optional Caddy reverse proxy for automatic HTTPS via Let's Encrypt.

**Image (public):** `docker.n8n.io/n8nio/n8n:stable`

#### Quick start on a fresh Ubuntu/Debian server

Minimum: 2 vCPU, 2 GB RAM, 10 GB disk.

Plain HTTP (no domain — webhooks from the public internet will not work):

```bash
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash
```

HTTPS with Let's Encrypt (requires a domain's A record pointing to the server):

```bash
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | \
  sudo bash -s -- --domain n8n.example.com --email admin@example.com
```

The script will:

1. Install Docker if missing
2. Add 2 GB of swap if the server has less than 1 GB
3. Pick a free port starting at 5678 (plain HTTP) — skipped in HTTPS mode
4. Pull `n8n` + `postgres` (+ `caddy` when `--domain` is set) and start them
5. Generate `N8N_ENCRYPTION_KEY` and Postgres passwords
6. Wait for `/healthz` and print the URL

Files end up in `/opt/n8n/`. Re-running the script is safe — it skips secret regeneration if `.env` already exists.

After setup, open the URL in a browser and create the owner account on first login.

#### Manual deployment

```bash
mkdir -p /opt/n8n && cd /opt/n8n
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/docker-compose.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/init-data.sh    -o init-data.sh && chmod +x init-data.sh
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/Caddyfile       -o Caddyfile
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/.env.example    -o .env
# Edit .env — set N8N_ENCRYPTION_KEY, POSTGRES_PASSWORD, POSTGRES_NON_ROOT_PASSWORD
# (generate each with: openssl rand -hex 32). Optional: set DOMAIN + ACME_EMAIL + COMPOSE_PROFILES=proxy for HTTPS.
docker compose pull && docker compose up -d
```

For n8n configuration reference (env vars, scaling, monitoring) see the official docs: https://docs.n8n.io/hosting/
