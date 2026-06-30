---
name: new
description: New Wolf Leader project — workspace setup at chat start, or create project and save at chat end.
disable-model-invocation: true
---

# New Wolf Leader project

Use `/new` at the **beginning** or **end** of a chat. Pick the path that matches.

| When | Goal |
|------|------|
| **Start** of chat | Connect workspace, run onboarding |
| **End** of chat | Create a **new** project from this conversation and save |

For checkpointing an **existing** project, use `/save` instead.

## Hub URL (both paths)

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
```

---

## Path A — Beginning (setup)

Use at the **start** of a completely new project or zero-context session.

User says: "set up Wolf Leader", "connect workspace", or `/new` at chat start.

### Fetch onboarding (mandatory)

```bash
curl -s "${API}/api/onboarding"
```

Canonical prompt:

```
Connect this workspace to Wolf Leader and finish setup.

Fetch and follow: ${API}/api/onboarding
```

Read `content` and complete every step (MCP, AGENTS.md, hooks, skills, transcript import).

If client files are missing:

```bash
WOLF_LEADER_API="${API}" WOLF_LEADER_MCP="${API%:6971}:6972/mcp" \
  ./scripts/install-cursor-client.sh
```

Reload the Cursor window after installing skills.

**Report:** MCP connected, `AGENTS.md` present, `/save` and `/new` skills installed, hub reachable.

---

## Path B — End (create project + save)

Use after a **long rabbit-hole** or new-topic chat when this work should become its **own** project.

User says: "save as new project", "new project from this chat", or `/new` at chat end.

### Fetch save guide (mandatory)

```bash
curl -s "${API}/api/save-project-guide"
```

Canonical prompt:

```
Save this conversation to Wolf Leader. Fetch and follow every step: ${API}/api/save-project-guide
```

This is a **new** project — do **not** rely on auto-detect. Do **not** use `/save`.

### Choose name + slug

1. From the **full conversation**, pick a short **name** and **slug** (e.g. `Docker Dashboard` → `docker-dashboard`).
2. `GET ${API}/api/projects` — if slug exists for a different topic, pick a more specific slug.
3. Only ask the user if the topic is genuinely ambiguous.

### Write semantic descriptors (required for vector search)

Wolf Leader embeds these so search works by description, not just keywords.

**For the new project** — include in `POST /api/projects`:
```json
{
  "name": "My Project",
  "slug": "my-project",
  "description": "One-line summary shown in the UI.",
  "metadata": {
    "semantic_descriptor": "2–4 sentences: what this project does, its purpose, synonyms for its name, and how you'd explain it to a fresh agent who never saw the name."
  }
}
```

**For every memory** — include `semantic_descriptor` on each `POST /api/memories`:
```json
{
  "project_id": 7,
  "type": "decision",
  "content": "Short raw fact.",
  "semantic_descriptor": "1–2 sentences: what this fact means, what problem it solves, any synonyms."
}
```

### Execute

**Bundled script** (creates project if needed, uploads transcript, distills):

```bash
~/.cursor/skills/new/scripts/new-project-session.sh
```

With explicit slug:

```bash
~/.cursor/skills/new/scripts/new-project-session.sh my-project-slug "My Project Name"
```

**Manual API:**

- `POST /api/projects` with `name`, `slug`, `path`
- `POST /api/save-project` with `slug`, `title`, and full `messages`
- Or MCP: `set_project({ slug })` then `save_session` per the guide

**Report:** Project name + slug, whether created, brief URL, pickup prompt, summary.
