from __future__ import annotations

import json

import pytest

from ide_storage.db import db_conn
from ide_storage.owners import (
    attach_owners,
    canonical_owner,
    owner_from_path,
    owner_summary,
    project_owner,
    set_owner,
    unassigned_project_ids,
)


@pytest.fixture(autouse=True)
def owners_env(monkeypatch):
    monkeypatch.setenv("WOLF_OWNERS", "Alice, Bob")
    monkeypatch.setenv("WOLF_SHARE_ROOT", "/srv/wolf")
    monkeypatch.setenv("IDE_STORAGE_SHARE_EXTRA", "/srv/content")


def _project(slug: str, path: str = "", *, metadata=None) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO projects (name, path, slug, status, created_at, updated_at, metadata)
            VALUES (?, ?, ?, 'active', 'now', 'now', ?)
            """,
            (slug, path, slug, json.dumps(metadata) if metadata else None),
        )
        conn.commit()
        return int(cur.lastrowid)


def test_owner_comes_from_the_owner_folder_in_any_spelling():
    assert owner_from_path("/srv/wolf/Alice/game") == "Alice"
    assert owner_from_path("/srv/content/bob/notes/x") == "Bob"
    assert owner_from_path("W:\\Alice\\game") == "Alice"
    assert owner_from_path("/srv/wolf/wolf-leader/git/game.git") is None
    assert owner_from_path("/Users/alice/Projects/game") is None
    assert owner_from_path("") is None


def test_no_owners_configured_means_no_folder_owner(monkeypatch):
    monkeypatch.delenv("WOLF_OWNERS")
    assert owner_from_path("/srv/wolf/Alice/game") is None
    assert canonical_owner("anyone") == "anyone"


def test_hand_set_owner_beats_the_folder():
    row = {"id": 1, "path": "/srv/wolf/Alice/game", "metadata": json.dumps({"owner": "bob"})}
    assert project_owner(row) == {"owner": "Bob", "owner_source": "set"}
    row["metadata"] = None
    assert project_owner(row) == {"owner": "Alice", "owner_source": "folder"}
    assert project_owner({"id": 2, "path": "/tmp/x"}) == {"owner": None, "owner_source": None}


def test_attach_owners_reads_path_aliases():
    pid = _project("laptop-project", "/Users/someone/code/thing")
    with db_conn() as conn:
        conn.execute(
            "INSERT INTO project_paths (project_id, path, kind, created_at) VALUES (?, ?, 'workspace', 'now')",
            (pid, "/srv/content/Bob/thing"),
        )
        conn.commit()
    rows = attach_owners([{"id": pid, "path": "/Users/someone/code/thing", "metadata": None}])
    assert rows[0]["owner"] == "Bob" and rows[0]["owner_source"] == "folder"


def test_set_owner_keeps_other_metadata_and_updated_at():
    pid = _project("keeps-meta", metadata={"kind": "app"})
    assert set_owner([pid], "alice") == 1
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT metadata, updated_at FROM projects WHERE id = ?", (pid,))
        row = cur.fetchone()
    assert json.loads(row["metadata"]) == {"kind": "app", "owner": "Alice"}
    assert row["updated_at"] == "now"

    set_owner([pid], "")
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT metadata FROM projects WHERE id = ?", (pid,))
        assert json.loads(cur.fetchone()["metadata"]) == {"kind": "app"}

    with pytest.raises(ValueError):
        set_owner([pid], "Mallory")


def test_summary_counts_and_unassigned():
    in_folder = _project("in-folder", "/srv/wolf/Alice/game")
    by_hand = _project("by-hand", "/tmp/a", metadata={"owner": "Bob"})
    nobody = _project("nobody", "/tmp/b")
    summary = owner_summary()
    assert summary["owners"] == ["Alice", "Bob"]
    assert summary["counts"] == {"Alice": 1, "Bob": 1, "": 1}
    assert unassigned_project_ids() == [nobody]
    assert in_folder != by_hand
