# Wolf Leader — Device & Agent Onboarding

**Give this document to any new device, agent, or zero-context automation.**

Replace `YOUR_HOST` with your server's reachable address (LAN IP, hostname, or Tailscale).

The Setup tab's **Copy setup prompt** button does this automatically. Its copied prompt is generated from `IDE_STORAGE_PUBLIC_URL` and `IDE_STORAGE_MCP_URL`, so installers receive this hub's live URLs rather than the `YOUR_HOST` examples below.

| Resource | URL / path |
|----------|------------|
| **This doc (web)** | http://YOUR_HOST:6971/?tab=setup |
| **This doc (API)** | http://YOUR_HOST:6971/api/onboarding |
| **Web UI** | http://YOUR_HOST:6971 |
| **MCP** | `http://YOUR_HOST:6972/mcp` |
| **Client setup (API)** | http://YOUR_HOST:6971/api/client-setup |
| **Client setup (doc)** | `./data/IDE_CLIENT_SETUP.md` |
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

## Client setup (paste into any agent)

No git clone on the client — the hub serves the install bundle.

| Step | Action |
|------|--------|
| 1 | Open http://YOUR_HOST:6971/?tab=setup |
| 2 | Click **Copy setup prompt** and paste into Cursor, Claude Code, Gemini, or any MCP-capable agent |
| 3 | Agent fetches setup instructions, identifies IDE and workspace, connects MCP, and verifies hub health |
| 4 | For Cursor or Codex, install the matching client integration. It adds `/save`, `/new`, recall, and automatic saving. Reload and run the verifier |
| 5 | In Codex, review and trust the three Wolf Leader hooks in Settings → Hooks; untrusted hooks do not run |
| 6 | Complete one test checkpoint and confirm it reached the hub before reporting setup complete |

API:

```bash
curl -s http://YOUR_HOST:6971/api/client-setup
```

One-liner (Cursor — set `WORKSPACE` to your project root):

```bash
WOLF_LEADER_API=http://YOUR_HOST:6971 \
WOLF_LEADER_MCP=http://YOUR_HOST:6972/mcp \
WOLF_LEADER_CLIENT=cursor \
WORKSPACE="$PWD" \
  bash -c "$(curl -fsSL http://YOUR_HOST:6971/api/client-setup/install.sh)"
```

Works on **macOS, Windows, and Linux** — local or remote (SSH). Use the hub's LAN/Tailscale URL when the hub is not on the same machine.

---

## Zero-context agent: exact steps

```
Connect this workspace to Wolf Leader and finish setup.

1. Fetch and read: http://YOUR_HOST:6971/api/onboarding and http://YOUR_HOST:6971/api/client-setup
2. Identify OS, IDE, config-owning machine, and absolute workspace path; preserve existing client configuration
3. Add MCP `wolf-leader` → `http://YOUR_HOST:6972/mcp`
4. Import agent transcripts not yet in the hub
5. For Cursor or Codex, run the hub installer with WOLF_LEADER_CLIENT set correctly, reload, and verify skills and hooks
6. Place AGENTS.md in workspace root (copy from hub data/AGENTS.md)
7. Call resolve_project + recall before project work
8. In Codex, trust the Wolf Leader hooks in Settings → Hooks
9. Complete a test save and confirm it appears in the hub
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

## Phase 1 — Connect MCP (any agent)

**Wolf Leader MCP port 6972.** REST/Web UI port **6971**.

Add MCP server `wolf-leader` → `http://YOUR_HOST:6972/mcp` in your agent's config:

### Cursor

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "wolf-leader": { "url": "http://YOUR_HOST:6972/mcp" }
  }
}
```

### Claude Code CLI

```bash
claude mcp add wolf-leader --url http://YOUR_HOST:6972/mcp
```

### Claude Desktop (macOS)

`~/Library/Application Support/Claude/claude_desktop_config.json` — same MCP entry.

### Remote workspace

On the **machine where the hub runs**, MCP can use `http://127.0.0.1:6972/mcp`. On **other machines**, use the LAN/Tailscale URL.

---

## Phase 2 — Cursor or Codex client

Install skills, MCP, hooks, and rules in one step from a wolf-leader checkout:

```bash
WOLF_LEADER_API=http://YOUR_HOST:6971 \
WOLF_LEADER_MCP=http://YOUR_HOST:6972/mcp \
WOLF_LEADER_CLIENT=cursor \
  bash -c "$(curl -fsSL http://YOUR_HOST:6971/api/client-setup/install.sh)"

# For Codex, use WOLF_LEADER_CLIENT=codex instead.
```

This installs and verifies:

- **`/save` and `/new` skills** → the client skill directory
- **MCP** → `~/.cursor/mcp.json` (`wolf-leader` server)
- **Hooks** — session/prompt recall plus automatic saves when a turn stops
- **Rule** — `wolf-leader-hub.mdc` (recall / remember / save)
- **`AGENTS.md`** symlink in workspace root (optional `WORKSPACE=/root`)

Source files live in `examples/cursor/` with the Codex hook template in `examples/codex/`. See INSTALL.md for details.

Codex requires a one-time trust review after files are installed. Reload Codex, open **Settings → Hooks**, and trust all three Wolf Leader hooks. Then rerun `scripts/verify-codex-client.sh`. Do not call setup complete until the verifier passes and a test checkpoint is visible in Wolf Leader.

---

## Phase 3 — First project

1. Create a project in the Web UI (or copy `data/projects/_example/` as a template)
2. Point `compose_path` at your stack folder if applicable
3. Work with an agent; type `/save` to checkpoint

---

## Backup

Back up the entire `./data` directory (SQLite DB + `projects/` markdown). That's the whole hub state.
