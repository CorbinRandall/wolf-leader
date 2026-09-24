# Wolf Leader — Agent Onboarding

**Any agent. Any client. Start here.**

Replace `YOUR_HOST` with your server IP, hostname, or Tailscale name.

Prefer the Setup tab's **Copy setup prompt** button. It inserts the running hub's configured API and MCP URLs automatically.

| Resource | URL / path |
|----------|------------|
| **Full onboarding (web)** | http://YOUR_HOST:6971/?tab=setup |
| **Full onboarding (API)** | http://YOUR_HOST:6971/api/onboarding |
| **Web UI** | http://YOUR_HOST:6971 |
| **MCP** | `http://YOUR_HOST:6972/mcp` |
| **Host copy** | `./data/ONBOARDING.md` (after setup) |

## What this is

**Wolf Leader** is **AI Project Storage** — a self-hosted hub for agent project memory:

- **Projects** with typed `SPEC.yaml` checkpoints (compose stacks, daemons, client setup, …)
- Typed **memories** (`decision`, `constraint`, `active_work`, …) — extracted on `/save`
- `PROJECT.md` living briefs per project
- **Archive** — full past sessions for drill-down

Raw transcripts stay on each device. `/save` checkpoints knowledge into the project, then archives the session.

## Zero-context agent prompt

```
Connect this workspace to Wolf Leader and finish setup.

1. Fetch and read http://YOUR_HOST:6971/api/onboarding and http://YOUR_HOST:6971/api/client-setup
2. Identify OS, IDE, config-owning machine, and absolute workspace path
3. Add MCP server `wolf-leader` → `http://YOUR_HOST:6972/mcp`, preserving existing client configuration
4. Place AGENTS.md in workspace root (copy from hub data/AGENTS.md)
5. Install the Cursor client on each machine that owns `~/.cursor`; reload and verify `/save`, `/new`, recall, and automatic-save hooks
6. Call resolve_project + recall before project work
7. Use `/save` after meaningful work; Cursor hooks also save meaningful transcript updates after responses and on stop
```

## Every session (mandatory)

During setup, ask the owner to choose an **economy**, **balanced**, or **maximum-quality** model policy and whether to use automatic background saves. Record the choices in the workspace `AGENTS.md`; do not put personal values into tracked examples. Automatic saves are recommended and best-effort. Check `~/.cursor/wolf-leader-last-save.json` for the latest result and `~/.cursor/wolf-leader-autosave-error.log` for failures. Use `/save` for a deliberate final checkpoint.

| When | Action |
|------|--------|
| **Start** | `resolve_project({ path: "<workspace>" })` → `recall()` or `get_brief()` |
| **During** | `remember({ type: "decision", content: "..." })` for durable facts |
| **Checkpoint** | Type **`/save`** — extract memories → refresh brief → archive session |
| **End** | Stop hook attempts another save; use `/save` for an intentional final checkpoint |

## Handoff tiers

| Tier | Meaning | Agent should… |
|------|---------|----------------|
| **continue** | Environment looks healthy | Maintain/fix only — **do not redeploy** |
| **orient** | Thin checkpoint | Read `on_disk`, load drill-down sessions before big changes |
| **rebuild** | Stack gone but topology in SPEC | Follow `rebuild` steps |

## MCP tools

`set_project` · `resolve_project` · `recall` · `remember` · `get_brief` · `list_projects` · `search` · `get_session` · `save_session`

## Without MCP

```bash
curl -s 'http://YOUR_HOST:6971/api/bootstrap?path=/your/workspace'
curl -s 'http://YOUR_HOST:6971/api/projects/my-project/agent-brief'
```

## Phase 1 — Connect MCP

**Wolf Leader MCP is port 6972** (REST/Web UI is 6971).

### Cursor

File: `~/.cursor/mcp.json` (or project `.cursor/mcp.json`)

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

## Phase 2 — Cursor client (recommended)

```bash
WOLF_LEADER_API=http://YOUR_HOST:6971 \
WOLF_LEADER_MCP=http://YOUR_HOST:6972/mcp \
./scripts/install-cursor-client.sh
```

Installs `/save` and `/new`, MCP, session-start recall and automatic-save hooks, and rules. Reload Cursor after install.

## Phase 3 — Project work

1. `set_project({ slug: "your-project" })`
2. `get_brief()` — read SPEC + pickup prompt
3. Work; `remember()` for decisions
4. `/save` at end

---

**Questions?** Open http://YOUR_HOST:6971 → **Setup** tab, or tell an agent: *"Read ONBOARDING from Wolf Leader and complete setup for this device."*
