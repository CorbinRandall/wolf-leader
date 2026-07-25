"""Sync project briefs and index to markdown files on disk."""
import os
from datetime import datetime
from typing import Any, Dict, List

from .branding import MCP_SERVER_KEY, PRODUCT_NAME, PRODUCT_TAGLINE
from .db import db_conn, get_projects_dir


def get_data_dir() -> str:
    return os.path.normpath(os.path.join(get_projects_dir(), ".."))


def read_project_md(slug: str) -> str:
    path = os.path.join(get_projects_dir(), slug, "PROJECT.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return ""


def write_project_md(slug: str, content: str) -> str:
    path_dir = os.path.join(get_projects_dir(), slug)
    os.makedirs(path_dir, exist_ok=True)
    path = os.path.join(path_dir, "PROJECT.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def read_agent_brief(slug: str) -> str:
    path = os.path.join(get_projects_dir(), slug, "AGENT_BRIEF.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return ""


def write_agent_brief(slug: str, content: str) -> str:
    path_dir = os.path.join(get_projects_dir(), slug)
    os.makedirs(path_dir, exist_ok=True)
    path = os.path.join(path_dir, "AGENT_BRIEF.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def agent_brief_mtime(slug: str) -> str | None:
    path = os.path.join(get_projects_dir(), slug, "AGENT_BRIEF.md")
    if not os.path.isfile(path):
        return None
    return datetime.utcfromtimestamp(os.path.getmtime(path)).isoformat()


def ensure_project_md_from_db(project: Dict[str, Any]) -> str:
    slug = project.get("slug") or f"project-{project['id']}"
    existing = read_project_md(slug)
    if existing.strip():
        return existing
    lines = [
        f"# {project.get('name', slug)}",
        "",
        f"**Status:** {project.get('status') or 'active'}",
    ]
    if project.get("compose_path"):
        lines.append(f"**Compose:** `{project['compose_path']}`")
    if project.get("path"):
        lines.append(f"**Path:** `{project['path']}`")
    lines.append("")
    if project.get("description"):
        lines.extend(["## Overview", "", project["description"], ""])
    lines.extend(
        [
            "## Key decisions",
            "",
            "_Add via web UI Memories or API `POST /api/memories`._",
            "",
            "## Open issues",
            "",
            "_None recorded._",
            "",
        ]
    )
    content = "\n".join(lines)
    write_project_md(slug, content)
    return content


def regenerate_index() -> str:
    public = os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    compose = os.environ.get(
        "IDE_STORAGE_COMPOSE_PATH",
        "/boot/config/plugins/compose.manager/projects/wolf-leader",
    )
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.*,
                   (SELECT COUNT(*) FROM chats c WHERE c.project_id = p.id) AS chat_count,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memory_count
            FROM projects p
            WHERE COALESCE(p.status, 'active') != 'archived'
            ORDER BY p.updated_at DESC
            """
        )
        projects = [dict(r) for r in cur.fetchall()]
        cur.execute(
            """
            SELECT c.id, c.title, c.updated_at, c.project_id, p.slug AS project_slug
            FROM chats c
            LEFT JOIN projects p ON c.project_id = p.id
            WHERE COALESCE(c.status, 'active') != 'archived'
            ORDER BY c.updated_at DESC
            LIMIT 30
            """
        )
        recent_chats = [dict(r) for r in cur.fetchall()]

    lines = [
        f"# {PRODUCT_NAME} — {PRODUCT_TAGLINE}",
        "",
        f"_Auto-generated {now}_",
        "",
        f"**Web UI:** {public}",
        f"**Setup (new devices):** [{public}/?tab=setup]({public}/?tab=setup)",
        f"**ONBOARDING.md:** `{compose}/data/ONBOARDING.md`",
        f"**AGENTS.md:** `{compose}/data/AGENTS.md`",
        "",
        "## Projects",
        "",
    ]
    if not projects:
        lines.append("_No projects yet._")
    else:
        for p in projects:
            slug = p.get("slug") or f"project-{p['id']}"
            lines.append(f"### [{p['name']}]({public}/?project={p['id']}) (`{slug}`)")
            if p.get("compose_path"):
                lines.append(f"- Compose: `{p['compose_path']}`")
            lines.append(
                f"- Sessions: {p.get('chat_count', 0)} | Memories: {p.get('memory_count', 0)}"
            )
            lines.append(f"- Brief: `data/projects/{slug}/PROJECT.md`")
            lines.append("")

    lines.extend(["## Recent sessions", ""])
    if not recent_chats:
        lines.append("_No chats yet._")
    else:
        for c in recent_chats:
            title = c.get("title") or f"Chat #{c['id']}"
            proj = f" ({c['project_slug']})" if c.get("project_slug") else ""
            lines.append(
                f"- [{title}]({public}/?chat={c['id']}){proj} — {(c.get('updated_at') or '')[:10]}"
            )

    content = "\n".join(lines) + "\n"
    index_path = os.path.join(get_data_dir(), "INDEX.md")
    with open(index_path, "w", encoding="utf-8") as f:
        f.write(content)
    return content


def read_index_md() -> str:
    index_path = os.path.join(get_data_dir(), "INDEX.md")
    if os.path.isfile(index_path):
        with open(index_path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return regenerate_index()


def read_onboarding_md() -> str:
    path = os.path.join(get_data_dir(), "ONBOARDING.md")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    return f"# {PRODUCT_NAME} onboarding\n\nONBOARDING.md not found on hub.\n"


def _build_save_guide() -> str:
    return f"""\
# Save this conversation to {PRODUCT_NAME}

**Use at the end of any agent chat** — Claude, Cursor, Codex, etc.

This guide is the **canonical checklist**. Client `/save` skills stay thin: fetch
this URL and follow it. Timeline rules, descriptors, and path details live here
so you do not rewrite skills every time the process changes.

---

## Your job

1. Sync the full conversation into the hub
2. **Auto-detect** which project it belongs to (do not ask unless detection fails)
3. Set **occurred_at** to when the conversation actually happened (not save time)
4. Write a **semantic descriptor** for the project and for each key memory
5. Extract typed memories, refresh agent brief, archive the session
6. Report: project slug, brief URL, Logbook/pickup summary for the next agent

---

## Session timeline (`occurred_at`) — required for Logbook order

The project **Logbook** sorts by when sessions *happened*, not when `/save` ran.
Older chats saved later must still appear earlier on the timeline.

Include on `POST /api/save-project` or MCP `save_session`:

```json
{{
  "slug": "imessage-archive",
  "title": "Dashboard Stop button",
  "occurred_at": "2026-07-02T21:35:00",
  "messages": []
}}
```

If omitted, the hub picks (first match):

1. Explicit `occurred_at` you pass
2. Cursor title `<timestamp>…</timestamp>`
3. Earliest real message `created_at`
4. Local transcript file mtime
5. Save time (last resort)

---

## Semantic descriptors — required for vector search

{PRODUCT_NAME} uses vector embeddings so agents can find projects and memories by
description, not just keywords.

### For the project (when its purpose became clearer this session)

`PUT /api/projects/<id>` with `metadata.semantic_descriptor`:

Write 2–4 sentences: what this project does, synonyms for its name,
and how you'd describe it to someone who forgot the name.

### For every memory you POST — semantic_descriptor is required

```json
{{
  "project_id": 7,
  "type": "decision",
  "content": "Use WAL mode for SQLite to prevent lock contention.",
  "semantic_descriptor": "SQLite concurrency fix: WAL journal mode and busy_timeout let readers continue while the embedding backfill writes, preventing API timeouts."
}}
```

---

## Pick one path

### Path A — Cursor on the hub host (local transcript exists)

```bash
curl -s -X POST http://127.0.0.1:6971/api/save-project \\
  -H 'Content-Type: application/json' \\
  -d '{{}}'
```

Optional: `"session_id"`, `"slug"`, `"occurred_at"`.

### Path B — Any other agent (conversation is in your context)

```bash
curl -s -X POST http://127.0.0.1:6971/api/save-project \\
  -H 'Content-Type: application/json' \\
  -d '{{
    "title": "Short topic title",
    "content": "One-line summary of what was accomplished",
    "slug": "my-project",
    "occurred_at": "2026-07-02T21:35:00",
    "messages": [
      {{"role": "user", "content": "..."}},
      {{"role": "assistant", "content": "..."}}
    ]
  }}'
```

### Path C — MCP connected

```
save_session(title="...", content="...", occurred_at="...", messages_json="[...]")
```

---

## Project detection (do not ask unless ambiguous)

Scan the conversation for compose paths, explicit slugs, topic phrases, port
numbers. List projects if unsure: `GET /api/projects` or MCP `list_projects`.

---

## After save — report to user

- **Project** linked (name + slug)
- **Brief URL** — `<hub>/api/projects/<slug>/agent-brief`
- **Logbook / pickup** from the API response
- Session is **archived**; future agents load the brief + Logbook

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `No Cursor transcript found` | Use Path B with `messages` array |
| Wrong project linked | Re-run with `"slug": "correct-slug"` |
| Wrong Logbook order | Pass `occurred_at` for the real session time |
| Cannot reach LAN IP | On the hub host itself: use `http://127.0.0.1:6971` |
"""


_SEMANTIC_DESCRIPTOR_ADDENDUM = f"""

---

## Semantic descriptors — required for vector search

{PRODUCT_NAME} uses vector embeddings so agents can find things by description,
not just keywords. Add these for every save to keep the search index sharp.

### For the project

`PUT /api/projects/<id>` — set `metadata.semantic_descriptor` to 2–4 sentences:
what this project does, synonyms for its name, and how you'd explain it from scratch.

### For every memory you POST

Add `semantic_descriptor` to each `POST /api/memories`:

```json
{{
  "project_id": 7,
  "type": "decision",
  "content": "Use WAL mode for SQLite.",
  "semantic_descriptor": "SQLite concurrency fix: WAL mode lets readers proceed while the embedding backfill writes, preventing API timeouts."
}}
```

1–2 sentences per memory: what this fact means, what problem it solves, any synonyms.
"""


def read_save_project_md() -> str:
    # Code-built guide is canonical so hub deploys update agent instructions
    # without rewriting client skills. Optional file override:
    # IDE_STORAGE_SAVE_GUIDE_FILE=1
    if os.environ.get("IDE_STORAGE_SAVE_GUIDE_FILE", "").strip() == "1":
        path = os.path.join(get_data_dir(), "SAVE_PROJECT.md")
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                content = f.read()
            if "occurred_at" not in content.lower():
                content += "\n\n## Session timeline\n\nPass `occurred_at` (ISO) for Logbook order.\n"
            if "semantic descriptor" not in content.lower():
                content += _SEMANTIC_DESCRIPTOR_ADDENDUM
            return content
    return _build_save_guide()
