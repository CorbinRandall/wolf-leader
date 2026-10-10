---
name: wolfhowl
description: Broadcast this session to Wolf Leader — save + git state + embed + file catalog + Obsidian notes, then offer commit/ingest/jobs.
disable-model-invocation: true
---

# /wolfhowl — howl to the pack

`/save` is the light checkpoint. `/wolfhowl` is the full broadcast: the same save, plus this machine's path alias, the repo's git state, embeddings for everything that landed, a refresh of the project's file catalog on the shared drive, and Obsidian notes in `W:\wolf-leader\vault`. If the repo has no `origin`, the hub makes a bare repo on the share (`W:\wolf-leader\git\<slug>.git`) and the runner sets `origin` to it. It then **offers** follow-ups — it never commits, pushes, ingests, or starts jobs on its own. Git stays local to the share; never push to GitHub or any other host unless the user asks.

## Run when invoked

User says `/wolfhowl`, "howl this", "broadcast this session", "push this to the pack".

## Do this

**Windows:** the scripts below are bash. Do NOT type `bash` in PowerShell (that is WSL and will fail). Run every command through Git Bash by full path:

```powershell
$env:CURSOR_WORKSPACE = (Get-Location).Path
& "C:\Program Files\Git\bin\bash.exe" -lc '~/.cursor/skills/wolfhowl/scripts/wolfhowl.sh'
```

Mac/Linux: run the bash lines as written.

1. Resolve the hub URL:

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://wolf.local:6971}}"
```

2. **Fetch and follow the live guide** (source of truth; it can change without this file changing):

```bash
curl -s "${API}/api/howl-guide"
```

3. Run the bundled runner from the project folder (it collects git state and the transcript for you):

```bash
~/.cursor/skills/wolfhowl/scripts/wolfhowl.sh            # auto-detect project
~/.cursor/skills/wolfhowl/scripts/wolfhowl.sh SLUG       # or pin the slug
```

**Always pass this chat's real session id** (`--session-id <id>`); the runner refuses to guess, because guessing attached the wrong chat. **Pin the slug** whenever `resolve_project` already gave you one, so the chat stays in that project. Outside Cursor (Claude Code etc.) also pass `--content "<typed lines>"` (same format as save_session, `active_work:` line first so it becomes the pickup). The runner also mirrors the repo's files (tracked + untracked-not-ignored) to `W:\wolf-leader\projects\<slug>\` and registers that folder so the file catalog works; `--no-share` skips it.

4. Reply with the hub's `summary` paragraph verbatim, then turn `offers[]` into one short question (commit + push? ingest these files? start a job?). Only act on an offer after the user says yes; when you do, follow the `how` field.

Skip a step that clearly does not apply and say so in one line. Do not invent extra steps here.
