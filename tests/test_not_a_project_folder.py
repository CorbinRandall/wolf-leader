"""AI tools and apps run in folders that aren't projects; the hub never makes a project of them."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

NOT_PROJECTS = [
    "/Users/someone/",
    "/Users/someone/Downloads",
    "/Users/someone/Documents",
    "/Users/someone/Documents/Codex",                       # the Codex app's own folder
    "/Users/someone/Documents/Codex/2026-10-14/fix-thing",  # its dated scratch chats
    "/Users/someone/.codex",
    "/Users/someone/.claude/projects/x",
    "/Users/someone/Library/Application Support/MacParakeet/LocalCLI",  # an app running Codex for itself
    "/private/var/folders/ab/xyz/T/tmp1",
    "/tmp",
    "/root",
    "C:\\Users\\corbin\\AppData\\Roaming\\SomeApp",
    "/root/.codex",
]
PROJECTS = [
    "/Users/someone/Projects/wolf-leader",
    "/Users/someone/Documents/Ableton Plugin",
    "/srv/content/Corbin/wolfleader",
    "/root/seek-online",
    "C:\\Users\\corbin\\code\\seek",
]


@pytest.mark.parametrize("path", NOT_PROJECTS)
def test_tool_and_app_folders_are_not_projects(path):
    from ide_storage.paths import not_a_project_folder

    assert not_a_project_folder(path), path


@pytest.mark.parametrize("path", PROJECTS)
def test_real_folders_still_can_be(path):
    from ide_storage.paths import not_a_project_folder

    assert not_a_project_folder(path) is None, path


def test_hub_refuses_to_name_a_project_after_codex():
    from fastapi.testclient import TestClient

    from ide_storage.main import app

    client = TestClient(app)
    refused = client.post("/api/projects/ensure", json={"path": "/Users/someone/Documents/Codex", "name": "Codex"})
    assert refused.status_code == 400 and "not a project" in refused.json()["detail"]
    made = client.post("/api/projects/ensure", json={"path": "/Users/someone/Projects/garden", "name": "Garden"})
    assert made.status_code == 200 and made.json()["created"] is True
    names = {p["name"] for p in client.get("/api/projects?limit=1000").json()["projects"]}
    assert "Codex" not in names and "Garden" in names


def _importer():
    spec = importlib.util.spec_from_file_location("wolf_import", Path(__file__).resolve().parent.parent / "scripts" / "wolf-import.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_importer_skips_apps_using_ai_and_files_tool_folders_by_content():
    wi = _importer()
    parakeet = "/Users/someone/Library/Application Support/MacParakeet/LocalCLI"
    assert wi.is_automated(parakeet, "You are a helpful assistant that transforms text according to user instructions")
    assert wi.is_automated("/Users/someone/Projects/x", "You are a transcription formatting assistant. Follow the format")
    assert not wi.is_automated("/Users/someone/Projects/x", "can you get this app up and running")
    assert wi.is_broad("/Users/someone/Documents/Codex") and wi.is_broad("/Users/someone/.codex")
    assert not wi.is_broad("/Users/someone/Projects/wolf-leader")
