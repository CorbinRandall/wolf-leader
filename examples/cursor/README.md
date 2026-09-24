# Cursor client integration

Canonical files for Wolf Leader on Cursor workspaces. Install with:

```bash
# From a wolf-leader checkout (set your hub URLs):
WOLF_LEADER_API=http://YOUR_HOST:6971 \
WOLF_LEADER_MCP=http://YOUR_HOST:6972/mcp \
./scripts/install-cursor-client.sh

# Verify:
./scripts/verify-cursor-client.sh
```

## What gets installed

| Target | Source |
|--------|--------|
| `~/.cursor/skills/save/` | `/save` slash command |
| `~/.cursor/mcp.json` | Wolf Leader MCP (merged if exists) |
| `~/.cursor/hooks.json` + `~/.cursor/hooks/` | sessionStart/before-prompt recall + background autosave after responses and on stop |
| `~/.cursor/rules/wolf-leader-hub.mdc` | Always-on agent rule |
| `~/.cursor/wolf-leader.env` | Hub URLs (created once; edit to change host) |
| `$WORKSPACE/AGENTS.md` | Symlink to `examples/AGENTS.md` (optional) |

After install, **reload the Cursor window** so `/save` appears in the `/` menu.

Automatic saves are best-effort. Check `~/.cursor/wolf-leader-last-save.json` for the latest result and `~/.cursor/wolf-leader-autosave-error.log` for failures. Use `/save` for a deliberate final checkpoint. During onboarding, choose an economy, balanced, or maximum-quality model policy and record it in the workspace `AGENTS.md`.

## Remote SSH

When Wolf Leader runs on another host (not `127.0.0.1:6971` on the SSH server), set `WOLF_LEADER_API` to the LAN URL. The install script writes `~/.cursor/wolf-leader.env`; hooks and `save-session.sh` read it.

## Do not install here

- `~/.cursor/skills-cursor/` — Cursor-managed built-ins; overwritten by the product.
