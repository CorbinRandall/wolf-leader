# Wolf Leader

**AI Project Storage** for agents — typed memories, `SPEC.yaml` checkpoints, session handoff, and MCP tools for Cursor, Claude Code, CLI workflows, and any client that speaks HTTP or MCP.


The idea is simple. With all your different AI apps (chats, IDE's, etc.), it can be really hard to keep track of everything. So rather than trying to keep it all within each AI, you'll just save a project for whatever you're working on into this application, it will distill it down to all the needed information. That way you can hand off to other AI tools and even if you lose an important chat- you can have all the context you need! 

Runs on **any Docker host**: Raspberry Pi, Windows, Linux, macOS, Unraid, cloud VM.

## Features

- **Web UI** — browse projects, memories, archived sessions; copy agent prompts
- **MCP server** — `set_project`, `recall`, `remember`, `get_brief`, `save_session`, …
- **Typed checkpoints** — `SPEC.yaml` + `AGENT_BRIEF.md` per project with handoff tiers (`continue` / `orient` / `rebuild`)
- **Continue modes** — compose deploy/maintain, server daemons, client setup, integration, investigation
- **`/save` pipeline** — auto-extract memories, refresh briefs, archive sessions
- **Markdown backbone** — `data/projects/{slug}/PROJECT.md` + git-friendly layout (runtime data gitignored)

## Quick start

```bash
git clone git@github.com:YOU/wolf-leader.git && cd wolf-leader
cp .env.example .env    # set IDE_STORAGE_PUBLIC_URL to your host IP
./scripts/setup.sh
```

Open **http://YOUR_HOST:6971** → Setup tab → connect MCP on each client.

**Full guide:** [INSTALL.md](INSTALL.md)

## Ports

| Service | Port | Purpose |
|---------|------|---------|
| REST + Web UI | 6971 | API, browser UI, agent brief URLs |
| MCP | 6972 | Wolf Leader MCP tools (`/mcp`) |

## MCP config (Cursor example)

```json
{
  "mcpServers": {
    "wolf-leader": { "url": "http://YOUR_HOST:6972/mcp" }
  }
}
```

## Agent workflow

1. **Start** — `set_project` → `get_brief()` / `recall()`
2. **Work** — `remember()` for durable decisions
3. **Checkpoint** — type `/save` or MCP `save_session`

Copy `data/AGENTS.md` into workspace roots after first run (see `examples/AGENTS.md`).

## Compose layouts

| File | Use |
|------|-----|
| `docker-compose.yml` | Portable default (Pi, Windows, Linux, …) |
| `docker-compose.dev.yml` | Live-mount source for development |
| `docker-compose.unraid.yml` | Unraid overlay (extra bind mounts) |
| `docker-compose.local.yml` | Your private overrides (not in git) |

```bash
# Portable
docker compose up -d --build

# Unraid
docker compose -f docker-compose.yml -f docker-compose.unraid.yml up -d --build

# Development
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

## Run natively (no Docker)

For a single host without Docker — e.g. a Mac without Docker Desktop — you can run
Wolf Leader directly with Python. It's lighter (no container, no VM) and the Docker
workflow above is unchanged; this is an optional alternative.

```bash
./run-local.sh     # first run bootstraps ./.venv, then starts REST :6971 + MCP :6972 on 127.0.0.1
./stop-local.sh    # stop both
```

Requires Python 3.11+ (uses [`uv`](https://github.com/astral-sh/uv) if present, else
`python3 -m venv`). Binds to `127.0.0.1` by default; override `HOST` / `MCP_HOST` /
`IDE_STORAGE_PUBLIC_URL` / `IDE_STORAGE_MCP_URL` to expose on a LAN or Tailscale.

## Environment variables

See [`.env.example`](.env.example). Minimum:

- `IDE_STORAGE_PUBLIC_URL` — how clients reach the Web UI / brief URLs
- `IDE_STORAGE_MCP_URL` — MCP endpoint for agents

Optional: `CURSOR_TRANSCRIPTS_ROOT`, `COMPOSE_MANAGER_ROOT`, `IDE_STORAGE_HOST_LABEL`

## API (selection)

- `GET /health`
- `GET /api/onboarding`
- `GET /api/bootstrap?path=…`
- `GET /api/projects/{slug}/agent-brief`
- `POST /api/projects` — create project

Legacy chat/snippet endpoints remain available — see inline docs in `ide_storage/main.py`.

## Data & privacy

**Do not commit** `data/ide-work.db` or `data/projects/*` (except `_example/`). Your project memory stays in `./data` on the host.

Back up `./data` to preserve everything.

## Private GitHub repo

```bash
git init && git add . && git status   # confirm no DB or personal projects staged
git commit -m "Initial release"
gh repo create wolf-leader --private --source=. --push
```

## Unraid note

If this folder is deployed via Compose Manager, the running stack is unaffected until you recreate containers. When you choose to update:

```bash
docker compose -f docker-compose.yml -f docker-compose.unraid.yml up -d --build
```

## License

Private / personal use — add a license file if you open-source later.
