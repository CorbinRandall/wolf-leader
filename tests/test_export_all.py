"""Export everything: one ZIP with readable Markdown and exact JSON for all of a hub's data."""
from __future__ import annotations

import io
import json
import zipfile

from fastapi.testclient import TestClient


def test_export_holds_projects_memories_and_chats():
    from ide_storage.db import db_conn
    from ide_storage.main import app

    with db_conn() as conn:
        cur = conn.cursor()
        now = "2026-01-02T03:04:05"
        cur.execute("INSERT INTO projects (name, path, slug, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                    ("Kite / Shop", "", "kite-shop", "Sells kites.", now, now))
        cur.execute("SELECT id FROM projects WHERE slug = ?", ("kite-shop",))
        pid = dict(cur.fetchone())["id"]
        cur.execute("INSERT INTO memories (project_id, type, content, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                    (pid, "decision", "Ship on Fridays.", now, now))
        cur.execute("INSERT INTO chats (project_id, title, created_at, updated_at) VALUES (?, ?, ?, ?)", (pid, "Pricing talk", now, now))
        cur.execute("SELECT id FROM chats WHERE title = ?", ("Pricing talk",))
        cid = dict(cur.fetchone())["id"]
        cur.execute("INSERT INTO messages (chat_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                    (cid, "user", "What should a kite cost?", now))
        conn.commit()

    reply = TestClient(app).get("/api/export.zip")
    assert reply.status_code == 200
    assert reply.headers["content-type"] == "application/zip"
    archive = zipfile.ZipFile(io.BytesIO(reply.content))
    names = archive.namelist()

    assert "README.txt" in names
    rows = [json.loads(line) for line in archive.read("data/projects.jsonl").decode().splitlines()]
    assert [r["slug"] for r in rows] == ["kite-shop"]
    assert json.loads(archive.read("data/counts.json"))["messages"] == 1
    # Readable copy: a folder named after the project, safe for any filesystem.
    assert "Ship on Fridays." in archive.read("readable/projects/Kite - Shop/memories.md").decode()
    chat = next(n for n in names if n.startswith("readable/projects/Kite - Shop/chats/") and "Pricing talk" in n)
    assert "What should a kite cost?" in archive.read(chat).decode()
    # Search indexes are rebuilt, not exported.
    assert not any("embeddings" in n for n in names)
