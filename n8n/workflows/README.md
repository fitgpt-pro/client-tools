# n8n workflows

Reference workflow templates for the FitGPT Pro cross-posting pipeline.

All files are scrubbed of secrets (credentials, API keys, instance IDs) but keep
internal sub-workflow references intact. After import, you need to:

1. Re-attach credentials in the marked nodes.
2. Fill in environment-specific variables (base URLs, folder IDs, chat IDs).
3. Activate the workflows.

A future `n8n/workflows/install.sh` will automate this via the n8n REST API or
CLI (`n8n import:workflow`).

## Files

| File | Trigger | Calls (sub-workflows) |
|---|---|---|
| `🚀 Запуск кросспостинга через Upload-Post (Без монтажа).json` | Schedule / manual | `Обработка и публикация…`, `🚨 Error Alert System` |
| `Обработка и публикация в профиль через Upload-Post (без монтажа).json` | `executeWorkflowTrigger` | `Опубликовать через Upload-Post`, `Отредактировать видео` (external) |
| `Опубликовать через Upload-Post.json` | `executeWorkflowTrigger` | — |
| `🚨 Error Alert System.json` | `errorTrigger` + `executeWorkflowTrigger` | — |

> `Отредактировать видео` is not bundled here — it lives in another repo / instance.

## Sub-workflow IDs (preserved in JSON)

`executeWorkflow` nodes pin the called workflow by **ID**, not by name. The
following IDs are referenced inside the JSON files and must exist in the target
n8n instance for cross-workflow calls to resolve:

| ID | Workflow |
|---|---|
| `1eOGfpx0bdXmo29y` | Обработка и публикация в профиль через Upload-Post (без монтажа) |
| `62SJFgBo4SFgGZeY` | 🚨 Error Alert System |
| `R6LusHb9zFZk2X10` | Опубликовать через Upload-Post |
| `ComZzp3QffKd3t3t` | Отредактировать видео *(external, not in this repo)* |

To preserve IDs on import, use the n8n CLI inside the container:

```bash
docker compose exec n8n n8n import:workflow \
  --input=/data/workflows/<file>.json
```

(The REST API `POST /workflows` ignores the `id` field — it always generates a
new one. Only the CLI honors it.)

## Credentials to reconnect after import

### `🚀 Запуск кросспостинга через Upload-Post (Без монтажа).json`
- **Google Sheets** node — source spreadsheet with the publishing queue
  (set `documentId` and `sheetName`).

### `Обработка и публикация в профиль через Upload-Post (без монтажа).json`
- **OpenAI** node — for caption/transcript generation.
- **Google Drive OAuth2** node — set `folderId` for the asset folder.
- **HTTP Bearer Auth** node — credentials for `video-editor`.
- Variable `video_editor_base_url` (Edit Fields node) — set to the deployed
  video-editor URL, e.g. `https://video-editor.example.com`.

### `Опубликовать через Upload-Post.json`
- **HTTP Header Auth** on TikTok / YouTube / Instagram nodes — single
  Upload-Post API key, can be one shared credential.

### `🚨 Error Alert System.json`
- **HTTP Header Auth** on `Get Execution Data` and `Get Calling Workflow`
  nodes — n8n personal API key (Settings → API).
- **Telegram** credentials on `Send Error Alert to Telegram`.
- Variables in `Edit Fields1` node:
  - `n8n_base_url` — e.g. `https://n8n.example.com`
  - `telegram_chat_id` — target chat / user ID for alerts.

## Error workflow wiring

For the cross-posting pipeline, set the Error workflow to `🚨 Error Alert System`
under each workflow's Settings → Error workflow. (Stored in JSON as
`settings.errorWorkflow` — currently empty so it doesn't dangle after import.)
