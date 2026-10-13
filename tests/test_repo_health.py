"""Repo health: which projects are versioned, shared folders, notes commits, off-site copies."""
from __future__ import annotations

import subprocess

import pytest
from fastapi.testclient import TestClient

from ide_storage.db import db_conn
from ide_storage.paths import register_project_path


@pytest.fixture(autouse=True)
def share(tmp_path, monkeypatch):
    root = tmp_path / "share"
    monkeypatch.setenv("WOLF_SHARE_ROOT", str(root))
    monkeypatch.setenv("WOLF_WIKI_ENABLED", "0")
    monkeypatch.delenv("WOLF_GIT_DIR", raising=False)
    return root


def _project(slug: str, path: str = "", compose: str | None = None) -> int:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO projects (name, path, compose_path, slug, status, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, 'active', 'now', 'now')",
            (slug.title(), path, compose, slug),
        )
        conn.commit()
        cur.execute("SELECT id FROM projects WHERE slug = ?", (slug,))
        return int(cur.fetchone()["id"])


def _git(cwd, *args):
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(cwd), *args],
        check=True, capture_output=True,
    )


def _by_slug(items):
    return {item["slug"]: item for item in items}


def test_projects_are_sorted_into_versioned_needs_repo_shared_and_knowledge_only(tmp_path, share):
    from ide_storage.howl import run_howl
    from ide_storage.repo_health import project_repo_status

    stack = _project("nextcloud")
    register_project_path(stack, "/stacks/nextcloud", kind="compose")
    a, b = _project("fans"), _project("video")
    register_project_path(a, "/lab")
    register_project_path(b, "/lab", force=True)
    _project("ideas")
    tracked = _project("immich")
    register_project_path(tracked, "/stacks/immich")
    messages = [{"role": "user", "content": "immich"}, {"role": "assistant", "content": "decision: ok"}]
    run_howl(slug="immich", workspace_path="/stacks/immich", messages=messages, session_id="s1", device_name="mac",
             git={"is_repo": True, "commit": "abc123", "branch": "main", "remote": "/share/git/immich.git", "dirty_files": 4})

    status = project_repo_status()
    by = _by_slug(status)

    assert by["nextcloud"]["state"] == "needs_repo"
    assert by["nextcloud"]["folder"] == "/stacks/nextcloud"
    assert "Compose stack" in by["nextcloud"]["why"]
    assert "/stacks/nextcloud" in by["nextcloud"]["setup_prompt"] and "/wolfhowl" in by["nextcloud"]["setup_prompt"]
    assert by["fans"]["state"] == by["video"]["state"] == "shared_folder"
    assert by["ideas"]["state"] == "knowledge_only"
    assert by["immich"]["state"] == "versioned"
    assert (by["immich"]["last_commit"], by["immich"]["dirty_files"], by["immich"]["device_name"]) == ("abc123", 4, "mac")
    # What needs attention comes first.
    assert status[0]["slug"] == "nextcloud"


def test_a_share_repo_with_commits_counts_as_versioned(tmp_path, share):
    from ide_storage.repo_health import project_repo_status

    pid = _project("recipes")
    register_project_path(pid, "/work/recipes")
    work = tmp_path / "work"
    work.mkdir()
    _git(work, "init", "-q", "-b", "main")
    (work / "README.md").write_text("hi")
    _git(work, "add", "-A")
    _git(work, "commit", "-q", "-m", "Add recipes")
    bare = share / "wolf-leader" / "git" / "recipes.git"
    bare.parent.mkdir(parents=True)
    _git(tmp_path, "clone", "-q", "--bare", str(work), str(bare))

    item = _by_slug(project_repo_status())["recipes"]

    assert item["state"] == "versioned"
    assert item["share_repo"]["commits"] == 1
    assert item["last_subject"] == "Add recipes"

    # An empty placeholder repo does not count.
    other = _project("empty")
    register_project_path(other, "/work/empty")
    _git(tmp_path, "init", "-q", "--bare", str(share / "wolf-leader" / "git" / "empty.git"))
    assert _by_slug(project_repo_status())["empty"]["state"] == "needs_repo"


def test_shared_folders_can_be_untangled():
    from ide_storage.hub import resolve_project
    from ide_storage.repo_health import shared_folders, unlink_folder

    cooling, video = _project("cooling", "/lab"), _project("video")
    register_project_path(cooling, "/lab")
    register_project_path(video, "/lab", force=True)

    groups = shared_folders()
    assert [(g["path"], sorted(p["slug"] for p in g["projects"])) for g in groups] == [("/lab", ["cooling", "video"])]
    assert resolve_project(path="/lab") is None

    # Also clears the legacy column, or the next boot would link the folder again.
    assert unlink_folder(cooling, "/lab")["removed"] == 2

    assert shared_folders() == []
    assert resolve_project(path="/lab")["slug"] == "video"
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT path FROM projects WHERE id = ?", (cooling,))
        assert cur.fetchone()["path"] == ""


def test_notes_are_committed_on_request_and_left_alone_when_clean(share):
    from ide_storage.repo_health import commit_notes, notes_status

    vault = share / "Corbin" / "wolfleader" / "vault"
    vault.mkdir(parents=True)
    _git(vault, "init", "-q", "-b", "main")
    (vault / "Home.md").write_text("# Home\n")
    _git(vault, "add", "-A")
    _git(vault, "commit", "-q", "-m", "Start notes")

    assert [r["committed"] for r in commit_notes()] == [0]

    (vault / "Home.md").write_text("# Home\n\nmore\n")
    (vault / "New.md").write_text("new\n")
    before = notes_status()[0]
    assert (before["owner"], before["uncommitted"]) == ("Corbin", 2)

    assert [r["committed"] for r in commit_notes()] == [2]

    after = notes_status()[0]
    assert after["uncommitted"] == 0
    assert after["last_subject"] == "notes: 2 changed file(s)"

    # A vault can opt out.
    (vault / "Later.md").write_text("x\n")
    _git(vault, "config", "autosave.skip", "true")
    assert commit_notes()[0]["skipped"] == "autosave.skip is set"


def test_offsite_copy_reports_drive_the_status():
    from ide_storage.repo_health import offsite_status, record_offsite

    assert offsite_status()["stale"] is True
    assert offsite_status()["last_good"] is None

    status = record_offsite({"device_name": "mac", "destination": "~/Backup", "repos": 7, "dump_name": "d.dump", "bytes": 10})
    assert status["stale"] is False
    assert (status["last_good"]["repos"], status["last_good"]["device_name"]) == (7, "mac")

    failed = record_offsite({"device_name": "mac", "ok": False, "detail": "ssh: no route"})
    assert failed["last_failed"] is True
    assert failed["last_good"]["repos"] == 7


def test_repos_endpoint_and_unlink_route(share):
    from ide_storage.main import app

    client = TestClient(app)
    cooling, video = _project("cooling"), _project("video")
    register_project_path(cooling, "/lab")
    register_project_path(video, "/lab", force=True)

    body = client.get("/api/repos").json()
    assert body["counts"] == {"shared_folder": 2}
    assert body["shared_folders"][0]["path"] == "/lab"
    assert body["offsite"]["stale"] is True
    assert "offsite-mirror.sh" in body["offsite_install"]

    assert client.delete(f"/api/projects/{video}/paths", params={"path": "/lab"}).json()["removed"] == 1
    assert client.get("/api/repos").json()["shared_folders"] == []
    assert client.delete("/api/projects/999999/paths", params={"path": "/lab"}).status_code == 404

    assert client.post("/api/backups/offsite", json={"repos": 3, "device_name": "nas"}).json()["last_good"]["repos"] == 3
    assert client.get("/api/offsite-mirror.sh").text.startswith("#!/usr/bin/env bash")
    assert client.post("/api/notes/commit").json() == {"results": [], "notes": []}


def test_home_folders_and_empty_remotes_are_not_mistaken_for_project_folders(share):
    from ide_storage.howl import run_howl
    from ide_storage.repo_health import project_repo_status

    migration = _project("migration")
    register_project_path(migration, "/Users/example")
    windows = _project("win-notes")
    register_project_path(windows, "C:\\Users\\example")

    # A remote was recorded once, but nothing was ever committed.
    cooling = _project("cooling")
    register_project_path(cooling, "/work/cooling")
    messages = [{"role": "user", "content": "fans"}, {"role": "assistant", "content": "decision: ok"}]
    run_howl(slug="cooling", workspace_path="/work/cooling", messages=messages, session_id="s9",
             git={"is_repo": True, "commit": None, "remote": "/share/git/cooling.git", "dirty_files": 44})

    # A person's Wolf Leader folder whose notes vault is already a repo.
    vault = share / "Sam" / "wolfleader" / "vault"
    vault.mkdir(parents=True)
    _git(vault, "init", "-q", "-b", "main")
    person = _project("sam-notes")
    register_project_path(person, "/srv/content/Sam/wolfleader")

    by = _by_slug(project_repo_status())

    assert by["migration"]["state"] == by["win-notes"]["state"] == "knowledge_only"
    assert by["cooling"]["state"] == "needs_repo"
    assert by["cooling"]["dirty_files"] == 44
    assert (by["sam-notes"]["state"], by["sam-notes"]["why"]) == ("versioned", "Notes vault under git")
