"""Shared test fixtures: give every test an isolated, initialized SQLite DB.

Without this, tests fall back to the real /data/ide-work.db (which may not have
the schema) and fail with "no such table". Each test gets a fresh temp DB.
"""
from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def isolated_db(tmp_path, monkeypatch):
    db_path = tmp_path / "ide-work.db"
    projects_dir = tmp_path / "projects"
    monkeypatch.setenv("IDE_STORAGE_DB_PATH", str(db_path))
    monkeypatch.setenv("IDE_STORAGE_PROJECTS_DIR", str(projects_dir))
    # Default to keyword-only so tests don't require fastembed/sqlite-vec.
    monkeypatch.delenv("IDE_STORAGE_EMBEDDINGS_ENABLED", raising=False)

    from ide_storage.db import init_db

    init_db()
    yield
