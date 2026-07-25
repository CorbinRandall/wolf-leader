---
name: save
description: Save the current Cursor session to Wolf Leader (existing project).
disable-model-invocation: true
---

# Save to Wolf Leader

Checkpoint work on a project that **already exists**. For a brand-new project, use `/new`.

## Run when invoked

User says: "save this", "save to Wolf Leader", "checkpoint this chat", or `/save`.

## Do this (and nothing else in this file)

1. Resolve the hub URL:

```bash
source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
```

2. **Fetch and follow the live guide** (source of truth — dates, descriptors, paths):

```bash
curl -s "${API}/api/save-project-guide"
```

Canonical starter prompt:

```
Save this conversation to Wolf Leader. Fetch and follow every step: ${API}/api/save-project-guide
```

3. Prefer the bundled runner after you know the slug:

```bash
~/.cursor/skills/save/scripts/save-session.sh CHOSEN-SLUG
```

Do **not** invent save steps here. The guide on the hub defines them and can change without updating this skill.
