#!/usr/bin/env python3
"""Build distilled AGENT_BRIEF.md from project chats, memories, and PROJECT.md."""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any

from ide_storage.db import db_conn, get_db_path, get_projects_dir
from ide_storage.markdown_sync import read_agent_brief, read_project_md, write_agent_brief


def _projects_dir() -> Path:
    return Path(get_projects_dir())

BRIEF_MAX_CHARS = 8000
PATH_RE = re.compile(
    r"(?:/boot/[^\s`\"']+|/usr/local/[^\s`\"']+|/etc/[^\s`\"']+|/root/[^\s`\"']+)"
)
DEPLOYED_RE = re.compile(
    r"(?i)(already deployed|do not repeat|don't repeat|in place|now live|all confirmed|"
    r"what(?:'s| is) now in place|fixes deployed|deployed this round)"
)
BULLET_RE = re.compile(r"^[\s]*[-*•]\s+(.{20,200})$", re.MULTILINE)
TABLE_ROW_RE = re.compile(r"^\|[^|]+\|[^|]+\|", re.MULTILINE)

# Optional seed files keyed by project slug
SEED_FILES: dict[str, list[str]] = {
    "s3-sleep": ["/root/.cursor/plans/harden_s3_sleep_36da83bb.plan.md"],
}


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 40].rsplit("\n", 1)[0] + "\n\n_[Brief truncated — drill into sessions for full detail.]_\n"


def _first_user_line(content: str) -> str:
    line = content.replace("\n", " ").strip()
    line = re.sub(r"<[^>]+>", " ", line)
    line = re.sub(r"\s+", " ", line).strip()
    return (line[:120] + "…") if len(line) > 120 else line


def _extract_paths(texts: list[str], limit: int = 15) -> list[str]:
    seen: set[str] = set()
    paths: list[str] = []
    for text in texts:
        for match in PATH_RE.findall(text):
            p = match.rstrip(".,;:")
            # Normalize trailing slash so "/x/" and "/x" don't both appear.
            if len(p) > 1:
                p = p.rstrip("/")
            if p not in seen and len(p) < 120:
                seen.add(p)
                paths.append(p)
            if len(paths) >= limit:
                return paths
    return paths


def _extract_bullets(texts: list[str], limit: int = 12) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for text in texts:
        for match in BULLET_RE.finditer(text):
            line = match.group(1).strip()
            if len(line) < 25 or line in seen:
                continue
            seen.add(line)
            items.append(line)
            if len(items) >= limit:
                return items
    return items


def _extract_deployed_notes(texts: list[str], limit: int = 8) -> list[str]:
    notes: list[str] = []
    seen: set[str] = set()
    for text in texts:
        if not DEPLOYED_RE.search(text):
            continue
        for para in re.split(r"\n\s*\n", text):
            para = para.strip()
            if len(para) < 40 or len(para) > 400:
                continue
            if DEPLOYED_RE.search(para) and para not in seen:
                seen.add(para)
                notes.append(para.replace("\n", " "))
            if len(notes) >= limit:
                return notes
    return notes



def _load_seed_sections(slug: str) -> list[str]:
    sections: list[str] = []
    candidates = list(SEED_FILES.get(slug, []))
    seed_md = _projects_dir() / slug / "SEED.md"
    if seed_md.is_file():
        candidates.insert(0, str(seed_md))
    for path_str in candidates:
        path = Path(path_str)
        if not path.is_file():
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        # Strip frontmatter
        if raw.startswith("---"):
            parts = raw.split("---", 2)
            if len(parts) >= 3:
                raw = parts[2]
        excerpt = raw.strip()[:2500]
        sections.append(f"_From `{path}`:_\n\n{excerpt}")
    return sections


def distill_project(project_id: int, db_path: Path | None = None) -> dict[str, Any]:
    from ide_storage.memory_ops import extract_memories_for_project, filter_bullets_against_memories

    now = datetime.utcnow().isoformat()
    # Auto-extract memories from unprocessed chats (backend; no user action)
    extract_memories_for_project(project_id, max_new=5)

    with db_conn() as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
        project = cur.fetchone()
        if not project:
            raise ValueError(f"Project {project_id} not found")
        project = dict(project)

        slug = project.get("slug") or f"project-{project_id}"
        cur.execute(
            """
            SELECT id, title, content, updated_at, session_id,
                   COALESCE(status, 'active') AS status
            FROM chats WHERE project_id = ?
            ORDER BY updated_at DESC
            """,
            (project_id,),
        )
        all_chats = [dict(r) for r in cur.fetchall()]
        chats = [c for c in all_chats if c.get("status") != "archived"]
        archived_chats = [c for c in all_chats if c.get("status") == "archived"]

        cur.execute(
            """
            SELECT id, type, content FROM memories
            WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
            ORDER BY updated_at DESC LIMIT 30
            """,
            (project_id,),
        )
        memories = [dict(r) for r in cur.fetchall()]

        all_assistant: list[str] = []
        public = __import__("os").environ.get(
            "IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971"
        ).rstrip("/")

        for chat in all_chats:
            cur.execute(
                "SELECT role, content FROM messages WHERE chat_id = ? ORDER BY id",
                (chat["id"],),
            )
            msgs = [dict(r) for r in cur.fetchall()]
            asst_msgs = [m["content"] for m in msgs if m["role"] == "assistant" and m.get("content")]
            all_assistant.extend(asst_msgs)

    project_md = read_project_md(slug) or ""
    overview = project.get("description") or ""
    if "## Overview" in project_md:
        m = re.search(r"## Overview\s*\n+(.*?)(?=\n## |\Z)", project_md, re.DOTALL)
        if m:
            overview = m.group(1).strip() or overview

    paths = _extract_paths(all_assistant)
    # Drop paths that belong to OTHER compose.manager projects (incl. the hub's
    # own ide_storage source) so a project's brief doesn't leak unrelated files.
    from ide_storage.distill_spec import _filter_cross_project_paths
    paths = _filter_cross_project_paths(paths, slug)
    bullets = _extract_bullets(all_assistant)
    if len(memories) >= 3:
        bullets = filter_bullets_against_memories(bullets, memories)
        if len(memories) >= 6:
            bullets = bullets[:4]
    deployed = _extract_deployed_notes(all_assistant)

    from ide_storage.memory_ops import is_brief_worthy_memory

    worthy = [m for m in memories if is_brief_worthy_memory(m.get("content") or "")]
    decisions = [m for m in worthy if m["type"] in ("decision", "constraint", "goal")]
    issues = [m for m in worthy if m["type"] in ("problem", "caveat", "active_work")]
    notes = [m for m in worthy if m["type"] == "note"]

    lines = [
        f"# Agent brief — {project.get('name', slug)}",
        "",
        f"_Distilled {now[:19]}Z from {len(archived_chats)} archived session(s), {len(memories)} memory(ies)._",
        "",
        "## Overview",
        "",
        overview or "_No overview yet._",
        "",
    ]

    if project.get("compose_path"):
        lines.extend(["## Compose / workspace", "", f"`{project['compose_path']}`", ""])

    seed = _load_seed_sections(slug)
    if seed:
        lines.extend(["## Current state (seed docs)", ""] + seed + [""])

    if paths:
        lines.extend(["## Key paths & files", ""] + [f"- `{p}`" for p in paths] + [""])

    if decisions:
        lines.append("## Decisions & policy")
        lines.append("")
        for m in decisions[:15]:
            lines.append(f"- **{m['type']}:** {m['content'][:400]}")
        lines.append("")

    if bullets and len(memories) < 3:
        lines.extend(["## Extracted policy points (from prior sessions)", ""])
        for b in bullets:
            lines.append(f"- {b}")
        lines.append("")
    elif bullets:
        lines.extend(["## Additional context (from sessions)", ""])
        for b in bullets[:6]:
            lines.append(f"- {b}")
        lines.append("")

    if issues:
        lines.append("## Known issues")
        lines.append("")
        for m in issues[:12]:
            lines.append(f"- **{m['type']}:** {m['content'][:400]}")
        lines.append("")

    if notes:
        lines.append("## Notes")
        lines.append("")
        for m in notes[:8]:
            lines.append(f"- {m['content'][:300]}")
        lines.append("")

    if deployed:
        lines.extend(["## Already done — do not repeat", ""])
        for d in deployed:
            lines.append(f"- {d}")
        lines.append("")

    if archived_chats:
        lines.append(
            f"## Prior sessions ({len(archived_chats)} archived — use hub Archive or get_session for verbatim context)"
        )
        lines.append("")
        for chat in archived_chats[:2]:
            title = chat.get("title") or f"Chat #{chat['id']}"
            lines.append(f"- [#{chat['id']}]({public}/?chat={chat['id']}) {title}")
        if len(archived_chats) > 2:
            lines.append(f"- _…and {len(archived_chats) - 2} more archived sessions_")
        lines.append("")

    lines.extend(
        [
            "## Agent instructions",
            "",
            "1. Treat this brief as authoritative context for this project.",
            "2. Use the compose path above; do not guess container or file locations.",
            "3. Open linked sessions only when you need verbatim prior work.",
            "4. Call `remember()` for new decisions; run `/save` or sync at session end.",
            "",
        ]
    )

    # SPEC.yaml is the canonical checkpoint. distill_spec runs before us in the
    # pipeline and writes a clean SPEC-derived brief; don't clobber it with the
    # chattier legacy brief. Only fall back to the legacy brief if no SPEC exists.
    from ide_storage.distill_spec import _brief_from_spec, read_spec_yaml

    spec_yaml = read_spec_yaml(slug)
    if spec_yaml.strip():
        brief = _truncate(_brief_from_spec(spec_yaml, project, slug), BRIEF_MAX_CHARS)
    else:
        brief = _truncate("\n".join(lines), BRIEF_MAX_CHARS)
    path = write_agent_brief(slug, brief)

    return {
        "project_id": project_id,
        "slug": slug,
        "name": project.get("name"),
        "brief_path": path,
        "brief_chars": len(brief),
        "session_count": len(chats),
        "archived_session_count": len(archived_chats),
        "memory_count": len(memories),
        "updated_at": now,
    }


def distill_all() -> list[dict[str, Any]]:
    results = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id FROM projects WHERE COALESCE(status, 'active') != 'archived' ORDER BY id"
        )
        ids = [row[0] for row in cur.fetchall()]
    for pid in ids:
        try:
            results.append(distill_project(pid))
        except Exception as exc:  # noqa: BLE001
            results.append({"project_id": pid, "error": str(exc)})
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description="Distill project agent briefs")
    parser.add_argument("--project-id", type=int)
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()

    if args.all:
        results = distill_all()
    elif args.project_id:
        results = [distill_project(args.project_id)]
    else:
        parser.error("Provide --project-id N or --all")

    print(json.dumps({"distilled": len(results), "results": results}, indent=2))


if __name__ == "__main__":
    main()
