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
