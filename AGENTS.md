# Wolf Leader agent guide

Wolf Leader stores project context, typed memories, briefs, and archived sessions for AI agents.

## Setup

Use the running hub's Setup tab. **Copy setup prompt** returns an agent prompt containing the hub's actual configured API and MCP URLs. The canonical setup payload is also available at `/api/client-setup`; onboarding is at `/api/onboarding`.

During setup:

1. Identify the OS, IDE, configuration-owning machine, and absolute workspace path.
2. Ask the owner for a friendly device name and a model policy (economy, balanced, or maximum quality). Install automatic background saves unless the owner explicitly opts out.
3. Connect the `wolf-leader` MCP server using the exact URL supplied by the hub.
4. Preserve existing MCP servers, hooks, and client settings.
5. For Cursor or Codex, run the matching hub-served installer, reload the client, and verify `/save`, `/new`, recall hooks, and save hooks. Codex hooks must be reviewed and trusted in Settings → Hooks.
6. Record owner choices in the workspace `AGENTS.md`. Keep private addresses, credentials, usernames, and machine paths out of tracked examples.

## Every session

1. Resolve the current project from the workspace path.
2. Recall the project or load its brief before making changes.
3. Remember durable decisions as they are made.
4. Let enabled background hooks checkpoint meaningful updates.
5. Use `/save` or MCP `save_session` for a deliberate final checkpoint.

Automatic saves are best-effort. Cursor clients write the latest result to `~/.cursor/wolf-leader-last-save.json` and failures to `~/.cursor/wolf-leader-autosave-error.log`.
Codex clients use the equivalent files under `~/.codex/`.

The distributable agent guide is in `examples/AGENTS.md`. The full install guide is `INSTALL.md`.
