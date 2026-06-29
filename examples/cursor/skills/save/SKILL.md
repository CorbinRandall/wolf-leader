---
name: save
description: Save the current Cursor session to Wolf Leader (transcript sync, memories, brief refresh, archive).
disable-model-invocation: true
---

# Save to Wolf Leader

Works in **any** agent (Cursor, Claude, etc.). User may not have `/save` in their slash menu until the skill is installed and the window reloaded.

## Run when invoked

User says: "save this", "save to Wolf Leader", "checkpoint this chat", or `/save`.

## Step 1 — Load hub config

Read `~/.cursor/wolf-leader.env` if present for `WOLF_LEADER_API` / `WOLF_LEADER_API_LOCAL`.

Default API: `http://127.0.0.1:6971` (same host as Cursor SSH). Use the LAN URL from env when the hub runs elsewhere.

## Step 2 — Fetch the guide (mandatory)

**On shell** (WebFetch often blocks LAN IPs):

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
curl -s "${API}/api/save-project-guide"
```

Read `content` and follow the path that matches this environment (Cursor transcript vs in-context messages).

Or run the bundled script:

```bash
~/.cursor/skills/save/scripts/save-session.sh
```

## Step 3 — Execute

- **Cursor with local transcript:** `POST /api/save-project` with `{}`
- **Claude / no transcript:** `POST /api/save-project` with `title` + `messages` from this conversation
- **MCP connected:** `save_session()` per the guide

Do **not** ask for project slug unless auto-detection fails.

## Step 4 — Report

Project slug, brief URL, pickup prompt, and `summary` from the API response.
