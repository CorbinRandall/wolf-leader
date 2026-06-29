---
name: save-new
description: Save a long rabbit-hole chat as a new Wolf Leader project (create project, then checkpoint).
disable-model-invocation: true
---

# Save as new Wolf Leader project

Use when a **long conversation** went off-topic or explored something new — not when checkpointing work on an **existing** project (use `/save` for that).

## Run when invoked

User says: "save this as a new project", "new project from this chat", "rabbit hole save", or `/save-new`.

## Step 1 — Hub URL

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
```

## Step 2 — Fetch the save guide (mandatory)

```bash
curl -s "${API}/api/save-project-guide"
```

Read `content`. This chat has **no** existing project — do **not** rely on auto-detection alone.

## Step 3 — User prompt (canonical)

```
Save this conversation to Wolf Leader on corbox. Fetch and follow every step: ${API}/api/save-project-guide
```

(Substitute the real `API` from step 1.)

## Step 4 — Choose or create the project

1. From the **full conversation**, pick a short **project name** and **slug** (e.g. `Docker Dashboard Links` → `docker-dashboard-links`).
2. `GET ${API}/api/projects` — if slug exists and is the wrong topic, pick a more specific slug.
3. If slug is new, `POST ${API}/api/projects`:

```json
{
  "name": "Human-readable project name",
  "slug": "kebab-case-slug",
  "path": "/root",
  "description": "One sentence from this conversation"
}
```

Only ask the user for name/slug if the topic is genuinely ambiguous after reading the chat.

## Step 5 — Save and checkpoint

**Prefer the bundled script** (creates project if needed, uploads transcript, distills):

```bash
~/.cursor/skills/save-new/scripts/save-new-session.sh SLUG "Project Name"
```

Or manually:

- **Cursor on corbox with transcript:** `POST /api/save-project` with `{"slug":"SLUG"}` after project exists
- **No local transcript (or remote hub):** `POST /api/save-project` with `slug`, `title`, and full `messages` array from this conversation
- **MCP:** `set_project({ slug })` then `save_session` with messages per the guide

Do **not** let auto-detect override your chosen slug.

## Step 6 — Report

Project name + slug, whether it was created or already existed, brief URL, pickup prompt, and summary.
