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

    # origin spelled as another machine sees the share still reaches the hub's bare repo.
    bare = share / "wolf-leader" / "git" / "corbin-notes.git"
    bare.parent.mkdir(parents=True)
    _git(share, "init", "-q", "--bare", str(bare))
    _git(vault, "remote", "add", "origin", "/somewhere/else/wolf-leader/git/corbin-notes.git")
    (vault / "Pushed.md").write_text("p\n")
    assert commit_notes()[0]["pushed"] is True
    assert subprocess.run(["git", "-C", str(bare), "log", "-1", "--format=%s", "--all"],
                          capture_output=True, text=True).stdout.strip() == "notes: 1 changed file(s)"
    _git(vault, "remote", "set-url", "origin", "git@github.com:someone/notes.git")
    (vault / "Private.md").write_text("p\n")
    assert "pushed" not in commit_notes()[0]

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
    assert body["counts"] == {"journal_only": 2}
    assert body["shared_folders"][0]["path"] == "/lab"
    assert body["offsite"]["stale"] is True
    assert "offsite-mirror.sh" in body["offsite_install"]

    assert client.delete(f"/api/projects/{video}/paths", params={"path": "/lab"}).json()["removed"] == 1
    assert client.get("/api/repos").json()["shared_folders"] == []
    assert client.delete("/api/projects/999999/paths", params={"path": "/lab"}).status_code == 404

    assert client.post("/api/backups/offsite", json={"repos": 3, "device_name": "nas"}).json()["last_good"]["repos"] == 3
    assert client.get("/api/offsite-mirror.sh").text.startswith("#!/usr/bin/env bash")
    assert client.post("/api/notes/commit").json() == {"results": [], "notes": []}


def test_project_repo_endpoint_creates_the_share_repo(share):
    from ide_storage.main import app

    client = TestClient(app)
    _project("recipes")

    remote = client.post("/api/projects/by-slug/recipes/repo", json={"client_os": "mac"}).json()

    assert remote["name"] == "recipes.git"
    assert (share / "wolf-leader" / "git" / "recipes.git" / "objects").is_dir()
    assert client.post("/api/projects/by-slug/nope/repo", json={}).status_code == 404


def test_projects_with_a_commit_are_listed_and_the_rest_are_just_the_journal(tmp_path, share):
    from ide_storage.howl import run_howl
    from ide_storage.repo_health import project_repo_status

    stack = _project("nextcloud")
    register_project_path(stack, "/stacks/nextcloud", kind="compose")
    _project("ideas")
    tracked = _project("immich")
    register_project_path(tracked, "/stacks/immich")
    messages = [{"role": "user", "content": "immich"}, {"role": "assistant", "content": "decision: ok"}]
    run_howl(slug="immich", workspace_path="/stacks/immich", messages=messages, session_id="s1", device_name="mac",
             git={"is_repo": True, "commit": "abc123", "branch": "main", "remote": "git@example.com:me/immich.git", "dirty_files": 4})

    status = project_repo_status()
    by = _by_slug(status)

    assert by["immich"]["state"] == "versioned"
    assert (by["immich"]["last_commit"], by["immich"]["dirty_files"], by["immich"]["device_name"]) == ("abc123", 4, "mac")
    # A Compose stack or folder with no git history is not a problem to fix: it is just the journal.
    assert by["nextcloud"]["state"] == by["ideas"]["state"] == "journal_only"
    assert "setup_prompt" not in by["nextcloud"]
    assert status[0]["slug"] == "immich"


def test_notes_vault_projects_show_their_vault_history(share):
    from ide_storage.repo_health import project_repo_status

    vault = share / "Sam" / "wolfleader" / "vault"
    vault.mkdir(parents=True)
    _git(vault, "init", "-q", "-b", "main")
    (vault / "Home.md").write_text("# Home\n")
    _git(vault, "add", "-A")
    _git(vault, "commit", "-q", "-m", "Start notes")
    person = _project("sam-notes")
    register_project_path(person, "/srv/content/Sam/wolfleader")

    item = _by_slug(project_repo_status())["sam-notes"]

    assert (item["state"], item["why"], item["last_subject"]) == ("versioned", "Notes vault under git", "Start notes")


def test_a_save_never_creates_a_repo_or_offers_git_work(share):
    from ide_storage.howl import run_howl

    _project("recipes")
    messages = [{"role": "user", "content": "x"}, {"role": "assistant", "content": "decision: y"}]

    for git in ({"is_repo": False}, {"is_repo": True, "commit": "abc123", "branch": "main", "dirty_files": 3}):
        report = run_howl(slug="recipes", workspace_path="/work/recipes", messages=messages, session_id="g1", git=git)
        assert report["ok"] is True
        assert "git_remote" not in report
        assert not (share / "wolf-leader" / "git").exists()
        kinds = {o["kind"] for o in report["offers"]}
        assert not kinds & {"git_init", "git_commit", "git_push", "create_repo", "move_to_share"}

    steps = {s["step"]: s for s in report["checklist"]}
    assert [s["step"] for s in report["checklist"]] == ["project", "saved", "git", "offsite"]
    assert steps["git"]["detail"] == "noted commit abc123 (3 uncommitted)"
    assert steps["offsite"]["state"] == "ask"
