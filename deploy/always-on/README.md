# Always-On Deployment (Option B)

This folder provides ready-to-use deployment configs so MiroFish can run continuously outside Cloud Agent sessions.

## Prerequisites

1. Push your repository to GitHub.
2. Keep `MiroFish/` in your repo (this deployment uses the upstream container image, so source build is not required on host).
3. Obtain:
   - `LLM_API_KEY` (OpenAI)
   - `ZEP_API_KEY`

Recommended defaults:
- `LLM_BASE_URL=https://api.openai.com/v1`
- `LLM_MODEL_NAME=gpt-4o-mini`

---

## Option 1: VPS / VM (simplest and reliable)

Files:
- `docker-compose.yml`
- `.env.example`

Steps:
1. Copy this folder to your server.
2. Create `.env` from `.env.example` and fill real keys.
3. Start:

```bash
docker compose up -d
```

4. Open:
- Frontend: `http://<your-server>:3000`
- API: `http://<your-server>:5001`
- Portal app: `http://<your-server>:8080`

### Portal app (recommended)

The compose stack now includes a small website (`portal/`) that gives you a clean entrypoint for MiroFish from any device.

From the portal you can:
- Save your MiroFish URL in browser storage
- Run a backend health check
- Open MiroFish in one tap

Default portal URL:
- `http://<your-server>:8080`

To update:

```bash
docker compose pull
docker compose up -d
```

---

## Option 2: Render (Blueprint)

File:
- `render.yaml`

What it creates:
- `mirofish-backend` web service (port 5001)
- `mirofish-frontend` static site (built from Vite)

Important:
- The frontend in this repo defaults API to localhost.
- On Render, set `VITE_API_BASE_URL` to your backend URL (already templated in `render.yaml`).

Steps:
1. In Render: New -> Blueprint -> connect this repo.
2. Select `deploy/always-on/render.yaml`.
3. Enter secret values when prompted:
   - `LLM_API_KEY`
   - `ZEP_API_KEY`
4. Deploy.

---

## Option 3: Railway

File:
- `railway.json`

This is a lightweight service definition you can adapt in Railway.

Suggested Railway setup:
1. Create project from GitHub repo.
2. Add service using Docker image `ghcr.io/666ghj/mirofish:latest`.
3. Expose port 3000 for frontend and 5001 for backend, or place a reverse proxy in front.
4. Add env vars from `.env.example`.

---

## Security

- Never commit real API keys.
- Rotate keys if they were pasted into chat/history.
- Use platform secret managers for production deployments.
