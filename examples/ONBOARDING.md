# Wolf Leader — Device & Agent Onboarding

**Give this document to any new device, agent, or zero-context automation.**

Replace `YOUR_HOST` with your server's reachable address (LAN IP, hostname, or Tailscale).

| Resource | URL / path |
|----------|------------|
| **This doc (web)** | http://YOUR_HOST:6971/?tab=setup |
| **This doc (API)** | http://YOUR_HOST:6971/api/onboarding |
| **Web UI** | http://YOUR_HOST:6971 |
| **MCP** | `http://YOUR_HOST:6972/mcp` |
| **Host copy** | `./data/ONBOARDING.md` |

---

## What this is

**Wolf Leader** is **AI Project Storage** — the single source of truth for project context across agents and tools:

- Projects with typed **`SPEC.yaml`** checkpoints
- Typed **memories** — auto-extracted on `/save`
- `PROJECT.md` living briefs per project
- **Archive** — full past sessions kept for emergency lookup

See `examples/AGENTS.md` for the short agent workflow reference.

---

## Quick install (server)

```bash
git clone git@github.com:YOU/wolf-leader.git
cd wolf-leader
cp .env.example .env
# Edit .env — set IDE_STORAGE_PUBLIC_URL and IDE_STORAGE_MCP_URL
./scripts/setup.sh
```

Open http://YOUR_HOST:6971 — complete MCP setup on each client device.

Full platform notes: **INSTALL.md**.

---

## Zero-context agent: exact steps

```
Connect this workspace to Wolf Leader and finish setup.

1. Fetch and read: http://YOUR_HOST:6971/api/onboarding
2. Add MCP `wolf-leader` → `http://YOUR_HOST:6972/mcp`
3. Place AGENTS.md in workspace root (copy from hub data/AGENTS.md)
4. Import agent transcripts not yet in the hub
5. Install `/save` skill on each Cursor workspace (optional)
6. Call resolve_project + recall before any project work
7. Type `/save` after meaningful work
```

### MCP tools

`set_project` · `resolve_project` · `recall` · `remember` · `get_brief` · `list_projects` · `search` · `get_session` · `save_session`

### Without MCP

```bash
curl -s 'http://YOUR_HOST:6971/api/bootstrap?path=/your/workspace'
```

---

## Continue modes (every project)

| Mode | Typical use |
|------|-------------|
| `client_setup` | SSH keys, agent config on **this device** |
| `compose_deploy` | Deploy or rebuild a Docker stack |
| `compose_maintain` | Stack running — fix/maintain only |
| `server_daemon` | OS plugin / systemd daemon tuning |
| `integration` | DNS, SSO, reverse proxy |
| `investigation` | Resume diagnosis |
| `external_host` | Service runs on another machine |

Optional stable facts: `data/projects/{slug}/SEED.md`.

---

## Phase 1 — Connect MCP (pick your client)

**Wolf Leader MCP port 6972.** REST/Web UI port **6971**.

### Cursor

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "wolf-leader": { "url": "http://YOUR_HOST:6972/mcp" }
  }
}
```

### Claude Desktop (macOS)

`~/Library/Application Support/Claude/claude_desktop_config.json` — same entry.

### Remote SSH workspace

On the **server**, MCP can use `http://127.0.0.1:6972/mcp`. On **laptops**, use the LAN/Tailscale URL.

---

## Phase 2 — Cursor client (recommended)

Install skills, MCP, hooks, and rules in one step from a wolf-leader checkout:

```bash
WOLF_LEADER_API=http://YOUR_HOST:6971 \
WOLF_LEADER_MCP=http://YOUR_HOST:6972/mcp \
./scripts/install-cursor-client.sh

./scripts/verify-cursor-client.sh
```

This installs:

- **`/save` skill** → `~/.cursor/skills/save/` (reload Cursor window after install)
- **MCP** → `~/.cursor/mcp.json` (`wolf-leader` server)
- **Hooks** — `sessionStart` bootstrap recall + `stop` auto-save
- **Rule** — `wolf-leader-hub.mdc` (recall / remember / save)
- **`AGENTS.md`** symlink in workspace root (optional `WORKSPACE=/root`)

Source files live in `examples/cursor/`. See INSTALL.md for details.

---

## Phase 3 — First project

1. Create a project in the Web UI (or copy `data/projects/_example/` as a template)
2. Point `compose_path` at your stack folder if applicable
3. Work with an agent; type `/save` to checkpoint

---

## Backup

Back up the entire `./data` directory (SQLite DB + `projects/` markdown). That's the whole hub state.
