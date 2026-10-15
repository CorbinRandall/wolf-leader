"""Local mode: the hub on one computer, everything in one folder, reachable only from there."""
from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient


def test_local_settings_keep_everything_in_one_folder(tmp_path, monkeypatch):
    from ide_storage.local import local_env

    for key in ("DATABASE_URL", "IDE_STORAGE_PROJECTS_DIR", "IDE_STORAGE_VAULT_DIR", "HOST", "MCP_HOST", "PORT"):
        monkeypatch.delenv(key, raising=False)
    env = local_env(tmp_path / "hub", 7001, 7002)
    assert env["DATABASE_URL"] == f"sqlite:///{(tmp_path / 'hub' / 'wolf-leader.db').as_posix()}"
    assert all(Path(env[k]).is_relative_to(tmp_path / "hub")
               for k in ("IDE_STORAGE_PROJECTS_DIR", "IDE_STORAGE_VAULT_DIR", "IDE_STORAGE_SKILLS_DIR"))
    assert (env["HOST"], env["MCP_HOST"], env["PORT"]) == ("127.0.0.1", "127.0.0.1", "7001")
    assert env["IDE_STORAGE_MCP_URL"] == "http://127.0.0.1:7002/mcp"


def test_health_names_the_database():
    from ide_storage.db import is_sqlite
    from ide_storage.main import app

    database = TestClient(app).get("/health").json()["database"]
    assert database["ok"] is True
    assert database["engine"] == ("sqlite" if is_sqlite() else "postgres")


def test_sqlite_path_on_windows_and_unix(monkeypatch):
    from ide_storage.db import sqlite_path

    monkeypatch.setenv("DATABASE_URL", "sqlite:///D:/a/data/wolf-leader.db")
    assert sqlite_path() == "D:/a/data/wolf-leader.db"
    monkeypatch.setenv("DATABASE_URL", "sqlite:///" + "srv/x/wolf-leader.db")
    assert sqlite_path() == "/srv/x/wolf-leader.db"
