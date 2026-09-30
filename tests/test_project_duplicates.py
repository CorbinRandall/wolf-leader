from __future__ import annotations

import json

import pytest

from ide_storage.db import db_conn
from ide_storage.project_duplicates import (
    find_duplicate_groups,
    list_duplicate_projects,
    merge_projects,
    normalize_project_identity,
)


def _project(name: str, slug: str, *, description=None, metadata=None, tags=None) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO projects (name, path, description, slug, status, created_at, updated_at, metadata, tags)
            VALUES (?, ?, ?, ?, 'active', 'now', 'now', ?, ?)
            """,
            (name, f"/projects/{slug}", description, slug, json.dumps(metadata) if metadata else None, json.dumps(tags) if tags else None),
        )
        conn.commit()
        return int(cur.lastrowid)


def test_normalized_duplicate_detection_is_conservative():
    assert normalize_project_identity("Unraid MCP Hub") == "unraidmcphub"
    groups = find_duplicate_groups(
        [
            {"id": 1, "name": "Unraid MCP Hub", "slug": "unraid-mcp-hub"},
            {"id": 2, "name": "unraid-mcp-hub", "slug": "unraid-mcp-hub-copy"},
            {"id": 3, "name": "Unraid MCP", "slug": "unraid-mcp"},
        ]
    )
    assert [[project["id"] for project in group] for group in groups] == [[1, 2]]


def test_duplicate_listing_includes_linked_counts():
    keep = _project("Unraid MCP Hub", "unraid-mcp-hub")
    duplicate = _project("unraid-mcp-hub", "unraid-mcp-hub-copy")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO chats (title, content, project_id, created_at, updated_at) VALUES ('x', 'x', ?, 'now', 'now')",
            (duplicate,),
        )
        cur.execute(
            "INSERT INTO memories (project_id, type, content, created_at, updated_at) VALUES (?, 'note', 'x', 'now', 'now')",
            (keep,),
        )
        conn.commit()

    groups = list_duplicate_projects()
    assert len(groups) == 1
    by_id = {project["id"]: project for project in groups[0]["projects"]}
    assert by_id[duplicate]["chat_count"] == 1
    assert by_id[keep]["memory_count"] == 1


def test_merge_reassigns_linked_data_and_preserves_metadata():
    keep = _project("Unraid MCP Hub", "unraid-mcp-hub", description="Compose stack", metadata={"keep": True}, tags=["hub"])
    duplicate = _project("unraid-mcp-hub", "unraid-mcp-hub-copy", description="A much richer project description", metadata={"source": True}, tags=["mcp"])
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO chats (title, content, project_id, created_at, updated_at) VALUES ('x', 'x', ?, 'now', 'now')",
            (duplicate,),
        )
        cur.execute(
            "INSERT INTO memories (project_id, type, content, created_at, updated_at) VALUES (?, 'note', 'x', 'now', 'now')",
            (duplicate,),
        )
        cur.execute(
            "INSERT INTO snippets (title, content, project_id, created_at, updated_at) VALUES ('x', 'x', ?, 'now', 'now')",
            (duplicate,),
        )
        conn.commit()

    report = merge_projects(keep, [duplicate])
    assert report["moved"] == {"chats": 1, "memories": 1, "snippets": 1}

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, description, metadata, tags FROM projects")
        rows = cur.fetchall()
        assert [row["id"] for row in rows] == [keep]
        metadata = json.loads(rows[0]["metadata"])
        assert metadata["keep"] is True
        assert metadata["source"] is True
        assert metadata["merged_from_projects"][0]["id"] == duplicate
        assert rows[0]["description"] == "A much richer project description"
        assert json.loads(rows[0]["tags"]) == ["mcp", "hub"]
        for table in ("chats", "memories", "snippets"):
            cur.execute(f"SELECT project_id FROM {table}")
            assert cur.fetchone()["project_id"] == keep


def test_merge_rejects_projects_that_are_not_duplicates():
    first = _project("First project", "first-project")
    second = _project("Second project", "second-project")

    with pytest.raises(ValueError, match="not duplicates"):
        merge_projects(first, [second])

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM projects ORDER BY id")
        assert [row["id"] for row in cur.fetchall()] == [first, second]
