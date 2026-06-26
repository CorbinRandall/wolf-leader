#!/usr/bin/env python3
"""Topic projects: one hub project per distinct server-admin chat topic (not catch-all)."""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any

from ide_storage.markdown_sync import ensure_project_md_from_db, regenerate_index

from ide_storage.db import get_db_path

DB_PATH = Path(get_db_path())
CATCH_ALL_PROJECT_ID = 1

TOPIC_PATH = "/root"

# Add topic specs here to split catch-all chats into dedicated projects.
# Each entry: slug, name, description, relink pattern, optional chat_ids to migrate.
TOPIC_SPECS: list[dict[str, Any]] = [
    {
        "slug": "unraid-hang-bug",
        "name": "Unraid Hang Bug",
        "description": "Investigate Unraid wedged/hung state: ping OK, SSH banner timeout, WebUI dead.",
        "pattern": r"unraid.?hang|hang bug|banner exchange|wedged.*unraid|ssh/webui dead",
        "chat_ids": [],
    },
]

MANUAL_SLUG_LINKS: dict[int, str] = {
    cid: spec["slug"] for spec in TOPIC_SPECS for cid in spec.get("chat_ids", [])
}


def _slug_to_id(cur: sqlite3.Cursor, slug: str) -> int | None:
    cur.execute(
        "SELECT id FROM projects WHERE slug = ? AND COALESCE(status, 'active') != 'archived'",
        (slug,),
    )
    row = cur.fetchone()
    return row[0] if row else None


def ensure_topic_project(cur: sqlite3.Cursor, spec: dict[str, Any], now: str) -> int:
    """Create or update a topic project; return project id."""
    from ide_storage.project_archetypes import metadata_patch

    existing = _slug_to_id(cur, spec["slug"])
    tags = json.dumps(["topic", "server-admin"])
    compose_path = spec.get("compose_path")
    meta = metadata_patch(
        {"metadata": json.dumps({"kind": "topic", "auto_created": True})},
    )
    slug = spec["slug"]
    if slug == "ssh-passwordless":
        meta = metadata_patch(
            {"metadata": json.dumps(meta)},
            continue_mode="client_setup",
            deploy_state="partial",
        )
    elif compose_path:
        meta = metadata_patch(
            {"metadata": json.dumps(meta)},
            continue_mode="compose_deploy",
            deploy_state=spec.get("deploy_state", "partial"),
        )
    elif spec["slug"] == "unraid-hang-bug":
        meta = metadata_patch(
            {"metadata": json.dumps(meta)},
            continue_mode="investigation",
            deploy_state="removed",
        )
    metadata = json.dumps(meta)

    if existing:
        cur.execute(
            """
            UPDATE projects
            SET name = ?, description = ?, path = ?, tags = ?, compose_path = COALESCE(?, compose_path),
                metadata = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                spec["name"],
                spec["description"],
                TOPIC_PATH,
                tags,
                compose_path,
                metadata,
                now,
                existing,
            ),
        )
        return existing

    cur.execute(
        """
        INSERT INTO projects (name, path, description, slug, status, compose_path,
            tags, created_at, updated_at, metadata)
        VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)
        """,
        (
            spec["name"],
            TOPIC_PATH,
            spec["description"],
            spec["slug"],
            compose_path,
            tags,
            now,
            now,
            metadata,
        ),
    )
    return cur.lastrowid


def topic_project_rules(db_path: Path | None = None) -> list[tuple[int, re.Pattern[str]]]:
    """Runtime rules from TOPIC_SPECS + DB ids (specific patterns before catch-all)."""
    path = db_path or DB_PATH
    if not path.exists():
        return []
    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        rules: list[tuple[int, re.Pattern[str]]] = []
        for spec in TOPIC_SPECS:
            pid = _slug_to_id(cur, spec["slug"])
            if pid is None:
                continue
            rules.append((pid, re.compile(spec["pattern"], re.I)))
        return rules
    finally:
        conn.close()


def resolve_manual_slug(cur: sqlite3.Cursor, chat_id: int) -> int | None:
    slug = MANUAL_SLUG_LINKS.get(chat_id)
    if not slug:
        return None
    return _slug_to_id(cur, slug)


def migrate_catch_all_topics(
    db_path: Path = DB_PATH,
    *,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Split catch-all project 1 chats/memories into dedicated topic projects."""
    now = datetime.utcnow().isoformat()
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    created: list[dict[str, Any]] = []
    moved_chats: list[dict[str, Any]] = []
    moved_memories: list[dict[str, Any]] = []

    slug_to_id: dict[str, int] = {}

    for spec in TOPIC_SPECS:
        if dry_run:
            pid = _slug_to_id(cur, spec["slug"])
            if pid is None:
                pid = -1
        else:
            pid = ensure_topic_project(cur, spec, now)
            cur.execute("SELECT * FROM projects WHERE id = ?", (pid,))
            ensure_project_md_from_db(dict(cur.fetchone()))

        slug_to_id[spec["slug"]] = pid
        created.append({"slug": spec["slug"], "id": pid, "name": spec["name"]})

        for chat_id in spec.get("chat_ids", []):
            cur.execute(
                "SELECT id, title, project_id FROM chats WHERE id = ?",
                (chat_id,),
            )
            row = cur.fetchone()
            if not row:
                continue
            if row["project_id"] == pid:
                continue
            moved_chats.append(
                {
                    "chat_id": chat_id,
                    "title": row["title"],
                    "from": row["project_id"],
                    "to": pid,
                    "slug": spec["slug"],
                }
            )
            if not dry_run:
                cur.execute(
                    "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
                    (pid, now, chat_id),
                )

            cur.execute(
                "SELECT id FROM memories WHERE source_chat_id = ? AND project_id != ?",
                (chat_id, pid),
            )
            for mem in cur.fetchall():
                moved_memories.append(
                    {"memory_id": mem[0], "chat_id": chat_id, "to": pid, "slug": spec["slug"]}
                )
                if not dry_run:
                    cur.execute(
                        "UPDATE memories SET project_id = ?, updated_at = ? WHERE id = ?",
                        (pid, now, mem[0]),
                    )

    if not dry_run:
        # Memories left on catch-all whose source chat moved elsewhere
        cur.execute(
            """
            UPDATE memories
            SET project_id = (
                SELECT c.project_id FROM chats c WHERE c.id = memories.source_chat_id
            ),
            updated_at = ?
            WHERE project_id = ?
              AND source_chat_id IS NOT NULL
              AND EXISTS (
                SELECT 1 FROM chats c
                WHERE c.id = memories.source_chat_id
                  AND c.project_id IS NOT NULL
                  AND c.project_id != ?
              )
            """,
            (now, CATCH_ALL_PROJECT_ID, CATCH_ALL_PROJECT_ID),
        )
        conn.commit()
        regenerate_index()

    cur.execute(
        "SELECT COUNT(*) FROM chats WHERE project_id = ?",
        (CATCH_ALL_PROJECT_ID,),
    )
    remaining_catch_all = cur.fetchone()[0]
    cur.execute(
        "SELECT COUNT(*) FROM memories WHERE project_id = ?",
        (CATCH_ALL_PROJECT_ID,),
    )
    remaining_memories = cur.fetchone()[0]

    conn.close()

    return {
        "dry_run": dry_run,
        "projects": created,
        "slug_to_id": slug_to_id,
        "moved_chats": moved_chats,
        "moved_memories_count": len(moved_memories),
        "moved_memories": moved_memories[:20],
        "catch_all_remaining": {
            "chats": remaining_catch_all,
            "memories": remaining_memories,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Create topic projects and migrate catch-all chats")
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    result = migrate_catch_all_topics(args.db, dry_run=args.dry_run)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
