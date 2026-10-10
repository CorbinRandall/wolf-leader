"""Shared test fixtures: every test gets an isolated, initialized Postgres schema.

Tests need a reachable Postgres with the pgvector extension. Point
``TEST_DATABASE_URL`` (or ``DATABASE_URL``) at it, e.g.

    docker run -d -p 55432:5432 -e POSTGRES_PASSWORD=wolf -e POSTGRES_USER=wolf \
        -e POSTGRES_DB=wolf_leader pgvector/pgvector:pg16
    TEST_DATABASE_URL=postgresql://wolf:wolf@127.0.0.1:55432/wolf_leader pytest

Each test runs inside its own schema (``search_path``) so tests never see each
other's rows; the schema is dropped afterwards.
"""
from __future__ import annotations

import os
import uuid

import pytest

TEST_URL = (
    os.environ.get("TEST_DATABASE_URL")
    or os.environ.get("DATABASE_URL")
    or "postgresql://wolf:wolf@127.0.0.1:55432/wolf_leader"
)


def _admin_conn():
    import psycopg

    return psycopg.connect(TEST_URL, autocommit=True)


@pytest.fixture(autouse=True)
def isolated_db(tmp_path, monkeypatch):
    schema = "t_" + uuid.uuid4().hex[:12]
    try:
        admin = _admin_conn()
    except Exception as exc:  # noqa: BLE001
        pytest.skip(f"Postgres not reachable at {TEST_URL}: {exc}")
    with admin.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector")
        cur.execute(f'CREATE SCHEMA "{schema}"')

    sep = "&" if "?" in TEST_URL else "?"
    url = f"{TEST_URL}{sep}options=-csearch_path%3D{schema},public"
    monkeypatch.setenv("DATABASE_URL", url)
    monkeypatch.setenv("IDE_STORAGE_PROJECTS_DIR", str(tmp_path / "projects"))
    monkeypatch.setenv("IDE_STORAGE_VAULT_DIR", str(tmp_path / "vault"))
    monkeypatch.setenv("IDE_STORAGE_WIKI_CONTENT_DIR", str(tmp_path / "wiki"))
    # Keyword-only by default so the suite does not need the ONNX model.
    monkeypatch.setenv("IDE_STORAGE_EMBEDDINGS_ENABLED", "0")

    from ide_storage.db import init_db

    init_db()
    yield
    with admin.cursor() as cur:
        cur.execute(f'DROP SCHEMA "{schema}" CASCADE')
    admin.close()
