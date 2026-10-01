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
