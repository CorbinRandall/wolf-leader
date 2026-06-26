# Wolf Leader — Install Guide

**AI Project Storage** for agents — memories, checkpoints, and handoff. Runs anywhere Docker runs: Linux server, Raspberry Pi, Windows (Docker Desktop), macOS, Unraid, NAS, cloud VM.

## Requirements

- Docker Engine 24+ and Docker Compose v2
- ~512 MB RAM, ~500 MB disk for the image + your `data/` growth
- Ports **6971** (REST/Web UI) and **6972** (MCP) available on the host

## Quick start (any platform)

```bash
git clone git@github.com:YOU/wolf-leader.git
cd wolf-leader
cp .env.example .env
```

Edit `.env`:

```bash
# Use the address other machines will use to reach this host
IDE_STORAGE_PUBLIC_URL=http://192.168.1.100:6971
IDE_STORAGE_MCP_URL=http://192.168.1.100:6972/mcp
IDE_STORAGE_HOST_LABEL=homelab   # optional — appears in agent pickup prompts
```

Run setup:

```bash
chmod +x scripts/*.sh
./scripts/setup.sh
```

Open the Web UI → **Setup** tab → connect MCP on each client.

## What gets stored where

| Path | Purpose | In git? |
|------|---------|---------|
| `ide_storage/` | Python app (FastAPI + MCP) | Yes |
| `data/ide-work.db` | SQLite database | **No** — private |
| `data/projects/` | PROJECT.md, SPEC.yaml, briefs | **No** — your projects |
| `data/projects/_example/` | Template only | Yes |
| `examples/` | Seed docs copied on first run | Yes |
| `.env` | Host URLs and paths | **No** |

**Backup:** copy the entire `data/` folder.

## Platform notes

### Linux / Raspberry Pi

```bash
# Install Docker (Debian/Ubuntu/Raspberry Pi OS)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out/in after

./scripts/setup.sh
```

Optional: mount agent transcripts for auto-import. Create `docker-compose.local.yml`:

```yaml
services:
  wolf-leader:
    environment:
      CURSOR_TRANSCRIPTS_ROOT: /transcripts
    volumes:
      - /home/you/.cursor/projects/your-workspace/agent-transcripts:/transcripts:ro
```

Then: `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d`

### Windows (Docker Desktop)

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
2. Clone repo to e.g. `C:\Users\you\wolf-leader`
3. Copy `.env.example` → `.env`; set `IDE_STORAGE_PUBLIC_URL=http://localhost:6971` for local-only, or your LAN IP for other devices
4. In PowerShell: `docker compose up -d --build`
5. Cursor MCP on Windows: `http://localhost:6972/mcp` or LAN IP

WSL2 path for transcripts (optional):

```yaml
# docker-compose.local.yml
services:
  wolf-leader:
    volumes:
      - /mnt/c/Users/you/.cursor/projects/foo/agent-transcripts:/transcripts:ro
    environment:
      CURSOR_TRANSCRIPTS_ROOT: /transcripts
```

### macOS

Same as Linux. Docker Desktop → clone → `.env` → `./scripts/setup.sh`.

For Claude Desktop MCP, use your Mac's LAN IP so multiple clients can reach the hub.

### Unraid (Compose Manager)

1. Clone or copy this repo to a compose folder, e.g.  
   `/boot/config/plugins/compose.manager/projects/wolf-leader`
2. Keep your live `data/` and database — they are gitignored
3. On next **voluntary** recreate (not required now if stack is healthy):

```bash
cd /boot/config/plugins/compose.manager/projects/wolf-leader
cp .env.example .env   # or merge with existing env
docker compose -f docker-compose.yml -f docker-compose.unraid.yml up -d --build
```

The `docker-compose.unraid.yml` overlay adds Unraid-specific mounts (compose manager root, docker.sock, Cursor transcripts, etc.). Set URLs and `IDE_STORAGE_HOST_LABEL` in `.env`.

Create `docker-compose.local.yml` for personal overrides without editing committed files.

## Client setup (each agent / device)

1. **MCP** — add `wolf-leader` → `http://YOUR_HOST:6972/mcp`
2. **AGENTS.md** — copy/symlink `data/AGENTS.md` into workspace roots
3. **`/save` skill** — optional Cursor skill for on-demand checkpoints
4. **Hooks** — optional sessionStart/stop for auto-import + save

See `examples/ONBOARDING.md` (copied to `data/ONBOARDING.md` on setup) for the full agent workflow.

## Creating a private GitHub repo

```bash
cd wolf-leader
git init
git add .
git status   # verify no ide-work.db or personal projects are staged
git commit -m "Initial Wolf Leader release"
gh repo create wolf-leader --private --source=. --push
```

Or create an empty private repo on GitHub, then:

```bash
git remote add origin git@github.com:YOU/wolf-leader.git
git push -u origin main
```

## Updating a running instance

```bash
git pull
docker compose up -d --build
```

Your `data/` and `.env` are untouched.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP won't connect | Check firewall on 6972; verify `IDE_STORAGE_MCP_URL` matches what clients use |
| Empty Web UI | Run `scripts/init-data.sh`; check `data/ide-work.db` permissions |
| Agent brief 404 | Create project in UI or register via API; run `/save` once |
| Port in use | Change `PORT` / `MCP_PORT` in `.env` |

Health check: `curl -s http://127.0.0.1:6971/health`

## Architecture (short)

```
Clients (Cursor, Claude, scripts, …)
    │  MCP :6972  /  REST :6971
    ▼
┌─────────────────────────────┐
│  wolf-leader container      │
│  FastAPI + MCP standalone   │
│  SQLite → ./data/ide-work.db│
│  Markdown → data/projects/  │
└─────────────────────────────┘
```

Distillation pipeline (`/save`): extract memories → `SPEC.yaml` → `AGENT_BRIEF.md` → archive session.
