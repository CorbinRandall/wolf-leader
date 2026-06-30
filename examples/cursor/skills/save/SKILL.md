---
name: save
description: Save the current Cursor session to Wolf Leader (existing project — agent picks match, then checkpoint).
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

```bash
curl -s "${API}/api/save-project-guide"
```

Canonical prompt:

```
Save this conversation to Wolf Leader. Fetch and follow every step: ${API}/api/save-project-guide
```

## Step 3 — Pick the existing project (mandatory)

Do **not** match on a single stray keyword (e.g. one mention of "sleep" ≠ s3-sleep). Read the **full conversation** and decide the **primary** project.

1. List projects:

```bash
curl -s "${API}/api/projects"
```

2. Optional hub hint (ranked by phrase frequency, not one-word hits):

```bash
curl -s -X POST "${API}/api/projects/match" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[...]}'   # or {"text":"..."} from this chat
```

Use `best` only if confidence is **high** or **medium** and reasons fit the main topic. If `ambiguous` is true or top candidates are close, **you** choose — do not blindly take rank #1.

3. State your pick in one line: slug + why (main task of this chat).

## Step 4 — Write semantic descriptors (required for vector search)

Wolf Leader embeds your descriptors so search works by description, not just keywords.

**Per memory** — include `semantic_descriptor` on every `POST /api/memories`:
```json
{
  "project_id": 7,
  "type": "decision",
  "content": "Use WAL mode for SQLite.",
  "semantic_descriptor": "SQLite concurrency fix: WAL journal mode and busy_timeout let readers continue while writes happen, preventing API timeouts."
}
```
Write 1–2 sentences: what this fact *means*, what problem it solves, any synonyms.

**Per project** — if this session clarified the project's purpose, update it:
`PUT /api/projects/<id>` with `metadata.semantic_descriptor` — 2–4 sentences on
what this project does, its scope, and how you'd describe it to a fresh agent.

## Step 5 — Execute

**Bundled script** with your chosen slug:

```bash
~/.cursor/skills/save/scripts/save-session.sh CHOSEN-SLUG
```

Without a slug (hub auto-match only when confident):

```bash
~/.cursor/skills/save/scripts/save-session.sh
```

**Manual API:**

- `POST /api/save-project` with `{"slug":"CHOSEN-SLUG"}` or `title` + `messages`
- **MCP:** `set_project({ slug })` then `save_session` per the guide

Do **not** create a new project. If nothing fits, tell the user to use `/new`.

## Step 6 — Report

Project slug, brief URL, pickup prompt, and `summary`.
