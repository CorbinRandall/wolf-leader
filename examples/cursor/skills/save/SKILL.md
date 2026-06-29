---
name: save
description: Save the current Cursor session to Wolf Leader (existing project only — auto-detect, checkpoint, archive).
disable-model-invocation: true
---

# Save to Wolf Leader (existing project)

Checkpoint work on a project that **already exists**. For a new project from this chat, use `/new` instead.

Works in **any** agent (Cursor, Claude, etc.). Reload the Cursor window after install if `/save` is missing from the `/` menu.

## Run when invoked

User says: "save this", "save to Wolf Leader", "checkpoint this chat", or `/save`.

Do **not** use for rabbit-hole chats or brand-new topics — use `/new`.

## Step 1 — Hub URL

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
```

## Step 2 — Fetch the guide (mandatory)

**On shell** (WebFetch often blocks LAN IPs):

```bash
curl -s "${API}/api/save-project-guide"
```

Canonical prompt:

```
Save this conversation to Wolf Leader on corbox. Fetch and follow every step: ${API}/api/save-project-guide
```

## Step 3 — Execute

**Bundled script** (auto-detect existing project; remote transcript upload when needed):

```bash
~/.cursor/skills/save/scripts/save-session.sh
```

Optional slug **only** when auto-detect is wrong but the project already exists:

```bash
~/.cursor/skills/save/scripts/save-session.sh existing-slug
```

**Manual API:**

- **Cursor with local transcript:** `POST /api/save-project` with `{}`
- **No transcript:** `POST /api/save-project` with `title` + `messages` from this conversation
- **MCP:** `save_session()` per the guide

Do **not** create a new project. If nothing matches, tell the user to use `/new`.

## Step 4 — Report

Project slug, brief URL, pickup prompt, and `summary` from the API response.
