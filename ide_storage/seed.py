"""One-time seed for known homelab projects."""
import json
from datetime import datetime

from .db import db_conn
from .markdown_sync import ensure_project_md_from_db, regenerate_index


def seed_if_needed() -> None:
    """Optional starter projects for fresh installs. Add entries in seeds[] if desired."""
    now = datetime.utcnow().isoformat()
    seeds: list[dict] = []

    with db_conn() as conn:
        cur = conn.cursor()
        for s in seeds:
            cur.execute("SELECT id FROM projects WHERE slug = ?", (s["slug"],))
            row = cur.fetchone()
            if row:
                project_id = row["id"]
            else:
                cur.execute(
                    """
                    INSERT INTO projects (name, path, description, slug, status, compose_path,
                        created_at, updated_at, metadata)
                    VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)
                    """,
                    (
                        s["name"],
                        s["path"],
                        s["description"],
                        s["slug"],
                        s["compose_path"],
                        now,
                        now,
                        json.dumps({"topic": s["slug"]}),
                    ),
                )
                project_id = cur.lastrowid

            if s.get("chat_session_id"):
                cur.execute(
                    "UPDATE chats SET project_id = ? WHERE session_id = ?",
                    (project_id, s["chat_session_id"]),
                )

            cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            ensure_project_md_from_db(dict(cur.fetchone()))

        conn.commit()

    if seeds:
        regenerate_index()
