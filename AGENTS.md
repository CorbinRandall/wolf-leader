# AGENTS.md — Wolf Leader (background-memory fork)

Wolf Leader is a self-hosted memory hub for AI coding agents: chats, typed memories, handoff briefs,
an Obsidian vault and a Fumadocs wiki, served over REST (`:6971`) and MCP (`:6972/mcp`).

## Layout

| Path | What |
|---|---|
| `ide_storage/` | Hub: FastAPI REST (`api*.py`), MCP server (`mcp_server.py`), core logic (`hub.py`, `save_project.py`, `memory_ops.py`) |
| `wiki/` | Fumadocs wiki built from the vault |
| `examples/cursor/` | Client files the installer copies into `~/.cursor` (rule, skills `wolfhowl` `wolfeat` `save` `new`) |
| `examples/AGENTS.md` | Global agent instructions installed for users |
| `installer/` | Windows (Inno Setup) and Mac (osascript wizard) installers; `CONFIG.md` + `PROMPT.md` are the shared contract |
| `scripts/` | Deploy, client install/verify, `wolf-backfill.py` |
| `tests/` | pytest suite |

## Run

- Hub: `docker compose -f docker-compose.postgres.yml up -d --build` (copy `.env.example` → `.env` first).
- Installer for end users: `start.bat` (Windows) or `start.command` (Mac).
- Tests: `python -m pytest -q`.

## Rules for agents working here

- Never commit `.env`, passwords, hostnames or IPs from a real network. Use `wolf.local`, `W:` and
  `<placeholders>` in docs and defaults.
- Client installs never add Cursor hooks; hooks are opt-in with `WOLF_LEADER_HOOKS=1`.
- Shell scripts and `.command` files stay LF (see `.gitattributes`).
- If you change the answer-file format, update `installer/CONFIG.md`, `installer/PROMPT.md` and both
  installers together.

## What this fork does differently from upstream

Upstream is `CorbinRandall/wolf-leader`. This fork adds:

1. **Background memory, no commands.** The installed rule makes the agent `resolve_project` at chat
   start, offer to `create_project` when the folder has none (asks first), `remember` decisions as
   they happen, and `save_session` after each meaningful step (at least every ~8 turns). It mentions
   saves in one line and only asks on errors. No hooks, no `.sh` files opening in the editor.
2. **Chat-ID matching that sticks.** Every save carries the chat's real `session_id`, so re-saves
   update one record (messages are replaced, not duplicated). Once a chat is filed under a project it
   stays there; only an explicit `project_id`/slug moves it. Inbox (catch-all) chats can still be
   re-filed. `wolfhowl` refuses to run without a session id rather than guess.
3. **Typed-line summaries.** `save_session` content is one `type: fact` line per item
   (`decision:`, `problem:`, `active_work:` …); the hub mines those lines as memories instead of
   guessing from free text.
4. **Share-hosted everything.** Vault, project file mirrors (`sync_share.py`), backups and bare git
   remotes (`<share>/wolf-leader/git/<slug>.git`, created on first `/wolfhowl`) live on one SMB share.
   No GitHub needed for project history.
5. **`/wolfhowl` and `/wolfeat`.** Howl broadcasts a session (save, git state, file catalog, vault
   notes) and offers commit/push/ingest; eat pulls the latest context onto another machine. On Windows
   the skills run through Git Bash, never WSL `bash`.
6. **Postgres + pgvector** stack (`docker-compose.postgres.yml`) with hybrid search.
7. **Local time everywhere** humans read it: `HH:MM MM/DD/YYYY`, zone from `WOLF_TZ`.
8. **Backfill.** `scripts/wolf-backfill.py` imports existing Cursor and Claude Code chats into
   grouped projects.
9. **Installers.** A three-step wizard (have WL? → toggles → let your own AI agent describe this
   machine in a strict INI) plus share passwords and a git identity page so local git never stalls on
   a GitHub login.
