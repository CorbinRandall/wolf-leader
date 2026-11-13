"""Access keys: each person signs in with their own key and sees only their own projects."""
from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

NOW = "2026-01-02T03:04:05"


@pytest.fixture
def hub(tmp_path, monkeypatch):
    from ide_storage import access, owners
    from ide_storage.db import db_conn, is_sqlite
    from ide_storage.main import app

    if is_sqlite():
        pytest.skip("per-person limits are enforced by Postgres")
    monkeypatch.setenv("WOLF_OWNERS", "Ann,Bo")
    monkeypatch.setenv("WOLF_ADMIN", "Ann")
    monkeypatch.setenv("WOLF_ACCESS_KEYS_FILE", str(tmp_path / "keys.json"))
    owners._cache.update(at=0.0, owners=None)
    access._visible_cache.clear()

    ids = {}
    with db_conn() as conn:
        cur = conn.cursor()
        for slug, owner, extra in (("ann-app", "Ann", {}), ("bo-app", "Bo", {}), ("commons", "Ann", {"everyone": True})):
            cur.execute(
                "INSERT INTO projects (name, path, slug, metadata, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (slug, "", slug, json.dumps({"owner": owner, **extra}), NOW, NOW),
            )
            cur.execute("SELECT id FROM projects WHERE slug = ?", (slug,))
            ids[slug] = dict(cur.fetchone())["id"]
            cur.execute("INSERT INTO memories (project_id, type, content, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                        (ids[slug], "decision", f"secret of {slug}", NOW, NOW))
        conn.commit()
    return TestClient(app), ids


def _slugs(reply):
    data = reply.json()
    rows = data if isinstance(data, list) else data.get("projects", data.get("items", []))
    return sorted(r["slug"] for r in rows)


def test_each_person_sees_only_their_own_projects(hub):
    from ide_storage.access import key_for

    client, ids = hub
    bo = {"Authorization": f"Bearer {key_for('Bo')}"}

    # No key on the hub's own address, and the admin's key: everything.
    assert _slugs(client.get("/api/projects")) == ["ann-app", "bo-app", "commons"]
    assert _slugs(client.get("/api/projects", headers={"Authorization": f"Bearer {key_for('Ann')}"})) == ["ann-app", "bo-app", "commons"]
    # Bo: his own, plus the one marked for everyone.
    assert _slugs(client.get("/api/projects", headers=bo)) == ["bo-app", "commons"]
    # The key can ride in the address instead, for tools that only take a URL.
    assert _slugs(client.get(f"/k/{key_for('Bo')}/api/projects")) == ["bo-app", "commons"]

    assert client.get(f"/api/projects/{ids['ann-app']}/context", headers=bo).status_code == 404
    assert client.get("/api/projects/ann-app/agent-brief", headers=bo).status_code == 404
    assert client.get(f"/api/projects/{ids['bo-app']}/context", headers=bo).status_code == 200
    assert "secret of ann-app" not in client.get("/api/memories", params={"project_id": ids["ann-app"]}, headers=bo).text
    assert "secret of bo-app" in client.get("/api/memories", params={"project_id": ids["bo-app"]}, headers=bo).text
    assert "secret of ann-app" in client.get("/api/memories", params={"project_id": ids["ann-app"]}).text
    assert "secret of ann-app" not in client.get("/api/search", params={"q": "secret"}, headers=bo).text


def test_what_a_person_makes_is_theirs(hub):
    from ide_storage import access
    from ide_storage.db import db_conn

    client, _ = hub
    token = access.current_person.set("Bo")
    try:
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute("INSERT INTO projects (name, path, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?) RETURNING id",
                        ("Bo new", "", "bo-new", NOW, NOW))
            pid = dict(cur.fetchone())["id"]
            cur.execute("INSERT INTO chats (title, created_at, updated_at) VALUES (?, ?, ?) RETURNING id", ("loose one", NOW, NOW))
            assert cur.fetchone() is not None
            conn.commit()
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute("SELECT slug FROM projects ORDER BY slug")
            assert [dict(r)["slug"] for r in cur.fetchall()] == ["bo-app", "bo-new", "commons"]
            cur.execute("SELECT title FROM chats")
            assert [dict(r)["title"] for r in cur.fetchall()] == ["loose one"]
    finally:
        access.current_person.reset(token)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT created_by FROM projects WHERE id = ?", (pid,))
        assert dict(cur.fetchone())["created_by"] == "Bo"


def test_public_port_needs_a_key_and_keys_are_admin_only(hub, monkeypatch):
    from ide_storage.access import key_for

    client, _ = hub
    bo = {"Authorization": f"Bearer {key_for('Bo')}"}
    assert client.get("/api/access", headers=bo).status_code == 403
    assert client.get("/api/export.zip", headers=bo).status_code == 403
    people = client.get("/api/access").json()["people"]
    assert [p["person"] for p in people] == ["Ann", "Bo"] and "/k/" in people[1]["hub"]
    assert client.get("/api/projects", headers={"Authorization": "Bearer not-a-real-key-at-all"}).status_code == 401

    old = key_for("Bo")
    client.post("/api/access/Bo/reset")
    assert client.get("/api/projects", headers={"Authorization": f"Bearer {old}"}).status_code == 401

    # TestClient arrives on port 80; make that the public one.
    monkeypatch.setenv("WOLF_PUBLIC_PORT", "80")
    assert client.get("/api/projects").status_code == 401
    assert client.get("/health").status_code == 200
    assert "access key" in client.get("/").text
    assert _slugs(client.get("/api/projects", headers={"Authorization": f"Bearer {key_for('Bo')}"})) == ["bo-app", "commons"]
