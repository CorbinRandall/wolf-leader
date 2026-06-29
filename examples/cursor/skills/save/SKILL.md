---
name: save
description: Save the current Cursor session to Wolf Leader — checkpoint existing work or create a new project from a rabbit-hole chat.
disable-model-invocation: true
---

# Save to Wolf Leader

One command for **both** cases: checkpointing work on an existing project **and** saving a long tangent as a **new** project.

Works in **any** agent (Cursor, Claude, etc.). Reload the Cursor window after install if `/save` is missing from the `/` menu.

## Run when invoked

User says: "save this", "save to Wolf Leader", "checkpoint", "save as new project", "rabbit hole save", or `/save`.

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

Canonical user prompt (works for both existing and new):

```
Save this conversation to Wolf Leader on corbox. Fetch and follow every step: ${API}/api/save-project-guide
```

## Step 3 — Decide: existing project or new?

Read the **full conversation**:

| Situation | What to do |
|-----------|------------|
| Clear match to an existing project | Auto-detect — no slug needed |
| New topic, rabbit hole, or no match | Derive a **name + slug**, or pass slug to the script |
| Ambiguous | Ask user once for name/slug |

## Step 4 — Execute

**Bundled script** (preferred — auto-detect, remote upload, or create project):

```bash
~/.cursor/skills/save/scripts/save-session.sh
```

Force a specific / new project:

```bash
~/.cursor/skills/save/scripts/save-session.sh my-project-slug "My Project Name"
```

**Manual API** (when not using the script):

- **Existing project, local transcript:** `POST /api/save-project` with `{}`
- **Existing or new with slug:** `POST /api/save-project` with `{"slug":"SLUG"}`
- **No transcript:** `POST /api/save-project` with `slug`, `title`, and full `messages`
- **New project first:** `POST /api/projects` then save with that `slug`
- **MCP:** `set_project({ slug })` then `save_session` per the guide

When no slug is given and auto-detect finds nothing, the script **creates a new project** from the conversation title.

## Step 5 — Report

Project name + slug, whether the project was created, brief URL, pickup prompt, and `summary`.
