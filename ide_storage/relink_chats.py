#!/usr/bin/env python3
"""Assign project_id to chats based on title/content and manual overrides."""
from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import datetime
from pathlib import Path

from ide_storage.import_all_transcripts import (
    CATCH_ALL_PROJECT_ID,
    DB_PATH,
    TRANSCRIPTS_ROOT,
    guess_project_id,
)
from ide_storage.project_match import best_project_match, transcript_text
from ide_storage.topic_projects import MANUAL_SLUG_LINKS, resolve_manual_slug

# Legacy or ambiguous chats — add explicit project assignments here if needed.
MANUAL_LINKS: dict[int, int] = {}
# Topic chats: resolved via slug in MANUAL_SLUG_LINKS (topic_projects.py)


def chat_text(cur: sqlite3.Cursor, chat_id: int, title: str, content: str | None) -> str:
    parts = [title or "", content or ""]
    cur.execute(
        "SELECT content FROM messages WHERE chat_id = ? AND role = 'user' ORDER BY id LIMIT 3",
        (chat_id,),
    )
    for row in cur.fetchall():
        parts.append(row[0] or "")
    return " ".join(parts)


def relink_chat(
    cur: sqlite3.Cursor,
    chat_id: int,
    *,
    db_path: Path,
    force: bool = False,
    now: str | None = None,
) -> dict | None:
    """Try to assign project_id for one chat. Returns change dict or None."""
    now = now or datetime.utcnow().isoformat()
    cur.execute("SELECT id, title, content, project_id FROM chats WHERE id = ?", (chat_id,))
    row = cur.fetchone()
    if not row:
        return None
    current = row["project_id"]
    if current is not None and not force and chat_id not in MANUAL_LINKS and chat_id not in MANUAL_SLUG_LINKS:
        return None

    project_id = MANUAL_LINKS.get(chat_id)
    if project_id is None:
        project_id = resolve_manual_slug(cur, chat_id)
    if project_id is None:
        text = chat_text(cur, chat_id, row["title"], row["content"])
        project_id = guess_project_id(text, db_path=db_path)

    if project_id is None:
        project_id = CATCH_ALL_PROJECT_ID

    if project_id == current:
        return None

    cur.execute(
        "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
        (project_id, now, chat_id),
    )
    return {"chat_id": chat_id, "from": current, "to": project_id, "title": row["title"]}


def relink_for_session(
    session_id: str,
    db_path: Path = DB_PATH,
    *,
    force: bool = False,
    root: Path = TRANSCRIPTS_ROOT,
) -> dict | None:
    """Relink a single chat by Cursor session_id (full transcript when available)."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT id, project_id, title FROM chats WHERE session_id = ?", (session_id,))
    row = cur.fetchone()
    if not row:
        conn.close()
        return None


    # Manual overrides win over transcript keyword matching.
    manual_id = MANUAL_LINKS.get(row["id"])
    if manual_id is None:
        manual_id = resolve_manual_slug(cur, row["id"])
    if manual_id is not None:
        if manual_id == row["project_id"]:
            conn.close()
            return None
        now = datetime.utcnow().isoformat()
        cur.execute(
            "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
            (manual_id, now, row["id"]),
        )
        conn.commit()
        conn.close()
        return {
            "chat_id": row["id"],
            "from": row["project_id"],
            "to": manual_id,
            "title": row["title"],
            "match_reason": "manual_link",
            "full_transcript": False,
        }

    transcript = root / session_id / f"{session_id}.jsonl"
    project_id = None
    match_reason = None
    if transcript.is_file():
        text = transcript_text(transcript)
        if text.strip():
            match = best_project_match(text, db_path=db_path)
            if match:
                project_id = match["project_id"]
                match_reason = ", ".join(match.get("reasons") or [])

    now = datetime.utcnow().isoformat()
    should_force = force or row["project_id"] is None or row["project_id"] == CATCH_ALL_PROJECT_ID

    if project_id is not None and (should_force or project_id != row["project_id"]):
        if project_id != row["project_id"]:
            cur.execute(
                "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
                (project_id, now, row["id"]),
            )
            conn.commit()
            conn.close()
            return {
                "chat_id": row["id"],
                "from": row["project_id"],
                "to": project_id,
                "title": row["title"],
                "match_reason": match_reason,
                "full_transcript": True,
            }

    result = relink_chat(cur, row["id"], db_path=db_path, now=now, force=should_force)
    conn.commit()
    conn.close()
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Link chats to projects by topic")
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true", help="Re-guess even if project_id is set")
    parser.add_argument(
        "--assign-unlinked-to",
        type=int,
        help="After pattern matching, assign any chat still without a project to this id",
    )
    args = parser.parse_args()

    now = datetime.utcnow().isoformat()
    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT id, title, content, project_id FROM chats ORDER BY id")

    linked = []
    for row in cur.fetchall():
        chat_id = row["id"]
        current = row["project_id"]
        if (
            current is not None
            and not args.force
            and chat_id not in MANUAL_LINKS
            and chat_id not in MANUAL_SLUG_LINKS
        ):
            continue

        project_id = MANUAL_LINKS.get(chat_id)
        if project_id is None:
            project_id = resolve_manual_slug(cur, chat_id)
        if project_id is None:
            text = chat_text(cur, chat_id, row["title"], row["content"])
            project_id = guess_project_id(text, db_path=args.db)

        if project_id is None or project_id == current:
            continue

        linked.append({"chat_id": chat_id, "from": current, "to": project_id, "title": row["title"]})
        if not args.dry_run:
            cur.execute(
                "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
                (project_id, now, chat_id),
            )

    assign_to = args.assign_unlinked_to
    if assign_to is None:
        assign_to = CATCH_ALL_PROJECT_ID

    cur.execute("SELECT id, title, project_id FROM chats WHERE project_id IS NULL ORDER BY id")
    for row in cur.fetchall():
        linked.append(
            {
                "chat_id": row["id"],
                "from": None,
                "to": assign_to,
                "title": row["title"],
                "reason": "assign-unlinked",
            }
        )
        if not args.dry_run:
            cur.execute(
                "UPDATE chats SET project_id = ?, updated_at = ? WHERE id = ?",
                (assign_to, now, row["id"]),
            )

    if not args.dry_run:
        conn.commit()

    cur.execute(
        """
        SELECT p.id, p.name, p.slug, COUNT(c.id) AS chat_count
        FROM projects p
        LEFT JOIN chats c ON c.project_id = p.id
        GROUP BY p.id
        ORDER BY p.id
        """
    )
    summary = [dict(row) for row in cur.fetchall()]
    conn.close()

    print(json.dumps({"linked": len(linked), "results": linked, "projects": summary}, indent=2))


if __name__ == "__main__":
    main()
