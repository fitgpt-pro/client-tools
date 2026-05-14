# client-tools

Public deployment files and setup scripts for self-hostable [fitgpt-pro](https://github.com/fitgpt-pro) services.

The source code of the services lives in private repositories; the Docker images are public on GitHub Container Registry. This repo holds everything operators (and external clients) need to run them.

## Reference deployment target

The defaults in this repo are sized for the FitGPT Pro reference VPS, where `video-editor` and `n8n` run side-by-side on a single host.

| Param | Value |
|---|---|
| Provider | Timeweb VPS |
| OS | Ubuntu 24.04 LTS |
| Kernel | 6.8.0 x86_64 |
| CPU | 2 vCPU (AMD EPYC) |
| RAM | 1.9 GB |
| Swap | 2 GB |
| Disk | 38 GB |
| Docker | 29.x + Compose v5.x |

**Resource budget when both services share this host:**

| Service | `cpus` | `mem_limit` | `memswap_limit` | DB |
|---|---|---|---|---|
| `video-editor` | 1.5 | 800m | 2g | — |
| `n8n` | 1.0 | 700m | 1500m | SQLite (`setup.sh --sqlite`) |
| OS + Docker daemon | — | ≈ 400m | — | — |
| **Total RAM** | — | **≈ 1.9 GB** | — | — |

CPU is soft-oversubscribed (1.5 + 1.0 > 2 cores) — idle cores from one service get reused by the other; under simultaneous peak both throttle but neither dies.

Larger hosts (≥ 4 vCPU / 4 GB RAM) can keep the upstream `.env.example` defaults and use n8n's Postgres backend (omit `--sqlite`) for higher concurrent-workflow throughput.

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

**Default resource limits** are sized for the reference 2 vCPU / 1.9 GB host shared with `n8n` (`CPUS_LIMIT=1.5`, `MEM_LIMIT=800m`, `MEMSWAP_LIMIT=2g`). Under simultaneous peak load with `n8n` both services will swap-thrash — that's the price of sharing the box. **Standalone deployment** (no `n8n` on the same host) — raise the limits in `/opt/video-editor/.env` (see the comments at the bottom of the file) and `docker compose up -d`.

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

Self-hosted [n8n](https://n8n.io) workflow automation with PostgreSQL (default) or SQLite backend, plus optional Caddy reverse proxy for automatic HTTPS via Let's Encrypt.

**Image (public):** `docker.n8n.io/n8nio/n8n:stable`

#### Quick start on a fresh Ubuntu/Debian server

| Mode | Minimum host | When to use |
|---|---|---|
| **Postgres + Caddy + HTTPS** | 2 vCPU, 4 GB RAM, 10 GB disk | Standalone n8n, many concurrent workflows |
| **Postgres, plain HTTP** | 2 vCPU, 4 GB RAM, 10 GB disk | Standalone n8n behind another proxy |
| **SQLite, plain HTTP (`--sqlite`)** | 2 vCPU, 2 GB RAM, 10 GB disk | Shared host (e.g. alongside `video-editor`); low concurrency |

Plain HTTP, Postgres (no domain — webhooks from the public internet will not work):

```bash
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash
```

HTTPS with Let's Encrypt (requires a domain's A record pointing to the server):

```bash
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | \
  sudo bash -s -- --domain n8n.example.com --email admin@example.com
```

**SQLite** mode — saves ≈ 300 MB RAM by skipping Postgres. Recommended on the reference 2 GB shared host:

```bash
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/setup.sh | sudo bash -s -- --sqlite
```

`--sqlite` is compatible with `--domain` (just add both flags). The data lives in a Docker volume (`n8n_storage`) and can be migrated to Postgres later via n8n's CLI export/import.

The script will:

1. Install Docker if missing
2. Add 2 GB of swap if the server has less than 1 GB
3. Pick a free port starting at 5678 (plain HTTP) — skipped in HTTPS mode
4. Pull `n8n` (+ `postgres` unless `--sqlite`, + `caddy` when `--domain` is set) and start them
5. Generate `N8N_ENCRYPTION_KEY` (+ Postgres passwords in Postgres mode)
6. Wait for `/healthz` and print the URL

Files end up in `/opt/n8n/`. Re-running the script is safe — it skips secret regeneration if `.env` already exists. Switching DB modes (`--sqlite` ↔ default Postgres) on an existing install is **not** supported: the script will refuse to overwrite the running config. To switch, export workflows from the UI, `docker compose down -v`, then re-run setup in the new mode.

After setup, open the URL in a browser and create the owner account on first login.

#### Manual deployment

Postgres backend:

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

SQLite backend:

```bash
mkdir -p /opt/n8n && cd /opt/n8n
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/docker-compose.sqlite.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/fitgpt-pro/client-tools/main/n8n/.env.sqlite.example      -o .env
# Edit .env — set N8N_ENCRYPTION_KEY (openssl rand -hex 32) and N8N_HOST.
docker compose pull && docker compose up -d
```

For n8n configuration reference (env vars, scaling, monitoring) see the official docs: https://docs.n8n.io/hosting/
