from fastapi.testclient import TestClient
from datetime import datetime, timezone

from ide_storage.db import db_conn
from ide_storage.main import app


def _insert_project(name: str, slug: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    with db_conn() as conn:
        conn.execute(
            "INSERT INTO projects (name, path, slug, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)",
            (name, f"/projects/{slug}", slug, now, now),
        )
        conn.commit()


def test_project_slug_serves_web_ui():
    _insert_project("Fire TV AI Video", "fire-tv-ai-video")

    with TestClient(app) as client:
        response = client.get("/fire-tv-ai-video")

    assert response.status_code == 200
    assert "<title>Wolf Leader</title>" in response.text
    assert response.headers["cache-control"] == "no-cache, no-store, must-revalidate"


def test_unknown_project_slug_is_404():
    with TestClient(app) as client:
        response = client.get("/not-a-real-project")

    assert response.status_code == 404
    assert response.json() == {"detail": "Project not found"}


def test_wiki_pages_are_revalidated_but_build_assets_are_cached(tmp_path):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from ide_storage.main import _WikiFiles

    (tmp_path / "docs").mkdir()
    (tmp_path / "index.html").write_text("<h1>front</h1>")
    (tmp_path / "docs" / "index.html").write_text("<h1>overview</h1>")
    (tmp_path / "_next" / "static" / "chunks").mkdir(parents=True)
    (tmp_path / "_next" / "static" / "chunks" / "app-abc123.js").write_text("1")
    site = FastAPI()
    site.mount("/wiki", _WikiFiles(directory=str(tmp_path), html=True), name="wiki")
    client = TestClient(site)

    assert client.get("/wiki/").headers["cache-control"] == "no-cache"
    page = client.get("/wiki/docs/")
    assert page.headers["cache-control"] == "no-cache"
    # A re-check with the page's ETag costs no download when nothing changed.
    assert client.get("/wiki/docs/", headers={"If-None-Match": page.headers["etag"]}).status_code == 304
    assert "immutable" in client.get("/wiki/_next/static/chunks/app-abc123.js").headers["cache-control"]
