"""The /wolfhowl skill replaces /save and /new: transcript parsing, project choice, runner."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "examples" / "shared" / "skills" / "wolfhowl" / "scripts"
SID = "01a12378-1312-7633-8c74-b295163b3b41"


def _load_session():
    spec = importlib.util.spec_from_file_location("wl_session_under_test", SCRIPTS / "session.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _write_jsonl(path: Path, rows: list[dict]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
    return path


def test_parse_transcript_reads_cursor_codex_and_claude_code(tmp_path):
    session = _load_session()
    cursor = _write_jsonl(tmp_path / "cursor.jsonl", [
        {"role": "user", "message": {"content": [{"type": "text", "text": "<user_query>fix the fan curve</user_query>"}]}},
        {"role": "assistant", "message": {"content": [{"type": "text", "text": "Done."}]}},
    ])
    codex = _write_jsonl(tmp_path / "codex.jsonl", [
        {"type": "session_meta", "payload": {"id": SID}},
        {"type": "response_item", "payload": {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "rules"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "<environment_context>cwd</environment_context>"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": '<external_codex_apps_open_page>{"page_id":null}</external_codex_apps_open_page>'}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "fix the fan curve"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Looking."}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Done."}]}},
    ])
    claude = _write_jsonl(tmp_path / "claude.jsonl", [
        {"type": "user", "message": {"role": "user", "content": "fix the fan curve"}},
        {"type": "user", "isMeta": True, "message": {"role": "user", "content": "caveat"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash"}, {"type": "text", "text": "Done."}]}},
    ])

    assert session.parse_transcript(cursor) == [
        {"role": "user", "content": "fix the fan curve"},
        {"role": "assistant", "content": "Done."},
    ]
    assert session.parse_transcript(codex) == [
        {"role": "user", "content": "fix the fan curve"},
        {"role": "assistant", "content": "Looking.\n\nDone."},
    ]
    assert session.parse_transcript(claude) == [
        {"role": "user", "content": "fix the fan curve"},
        {"role": "assistant", "content": "Done."},
    ]


def test_find_transcript_only_returns_the_exact_session(tmp_path, monkeypatch):
    session = _load_session()
    cursor_root = tmp_path / "cursor"
    codex_root = tmp_path / "codex"
    monkeypatch.setattr(session, "DEFAULT_ROOT", cursor_root)
    monkeypatch.setattr(session, "CODEX_ROOTS", (codex_root,))
    monkeypatch.setattr(session, "CLAUDE_ROOT", tmp_path / "claude")
    for name in session.SESSION_ENV_VARS:
        monkeypatch.delenv(name, raising=False)

    # An unrelated, newer Cursor chat must never be picked up for a Codex session id.
    _write_jsonl(cursor_root / "proj" / "agent-transcripts" / "other" / "other.jsonl", [{"role": "user"}])
    rollout = _write_jsonl(codex_root / "2026" / "10" / "12" / f"rollout-2026-10-12T10-10-27-{SID}.jsonl", [{}])

    assert session.find_transcript(SID) == (SID, rollout)
    assert session.find_transcript("no-such-session") == (None, None)
    assert session.find_transcript(None) == (None, None)

    claude = _write_jsonl(tmp_path / "claude" / "-Users-me-proj" / "abc-123.jsonl", [{}])
    assert session.find_transcript("abc-123") == ("abc-123", claude)


class _FakeHub(BaseHTTPRequestHandler):
    best: dict | None = None
    legacy = False
    calls: list[tuple[str, str, dict | None]] = []

    def _reply(self, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        type(self).calls.append(("GET", self.path, None))
        self._reply({"projects": [{"slug": "homelab", "name": "Homelab"}]})

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        type(self).calls.append(("POST", self.path, body))
        if self.path == "/api/projects/match":
            self._reply({"best": type(self).best, "matches": [{"slug": "homelab", "name": "Homelab", "score": 20}]})
        elif self.path == "/api/projects":
            self._reply({"id": 9, "slug": body["slug"]})
        elif self.path == "/api/howl" and type(self).legacy:
            self.send_error(404)
        else:
            self._reply({"ok": True, "summary": "saved", "offers": [], "project_slug": body.get("slug")})

    def log_message(self, *args):
        pass


@pytest.fixture
def hub(tmp_path, monkeypatch):
    _FakeHub.best, _FakeHub.legacy, _FakeHub.calls = None, False, []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeHub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    home = tmp_path / "home"
    _write_jsonl(home / ".codex" / "sessions" / f"rollout-2026-10-12T10-10-27-{SID}.jsonl", [
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "tune the fan curve"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Tuned."}]}},
    ])
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    env = {
        "HOME": str(home),
        "USERPROFILE": str(home),
        "PATH": __import__("os").environ.get("PATH", ""),
        "WOLF_LEADER_API": f"http://127.0.0.1:{server.server_address[1]}",
        "WOLF_LEADER_WORKSPACE": str(workspace),
    }

    def run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "wolfhowl.py"), *args, "--no-share"],
            capture_output=True, text=True, env=env, cwd=workspace, timeout=60,
        )

    yield run
    server.shutdown()


def _posts(path: str) -> list[dict]:
    return [body for method, called, body in _FakeHub.calls if method == "POST" and called == path]


def test_runner_stops_and_asks_when_no_project_matches(hub):
    result = hub("--session-id", SID)

    assert result.returncode == 3, result.stderr
    report = json.loads(result.stdout)
    assert report["needs_project_choice"] is True
    assert report["candidates"] == [{"slug": "homelab", "name": "Homelab", "score": 20}]
    assert _posts("/api/howl") == []
    assert _posts("/api/projects") == []
    # The transcript text is what gets matched, read from disk rather than retyped by the model.
    assert _posts("/api/projects/match")[0]["messages"][0]["content"] == "tune the fan curve"


def test_runner_saves_the_local_transcript_to_a_confident_match(hub):
    _FakeHub.best = {"slug": "homelab", "confidence": "high"}

    result = hub("--session-id", SID)

    assert result.returncode == 0, result.stderr
    howl = _posts("/api/howl")[0]
    assert howl["slug"] == "homelab"
    assert howl["session_id"] == SID
    assert howl["title"] == "tune the fan curve"
    assert [m["role"] for m in howl["messages"]] == ["user", "assistant"]
    assert howl["git"] == {"is_repo": False}


def test_runner_creates_a_project_only_with_new(hub):
    result = hub("fan-lab", "--new", "--project-name", "Fan Lab", "--session-id", SID)

    assert result.returncode == 0, result.stderr
    created = _posts("/api/projects")[0]
    assert (created["slug"], created["name"]) == ("fan-lab", "Fan Lab")
    assert _posts("/api/howl")[0]["slug"] == "fan-lab"

    assert hub("--new", "--session-id", SID).returncode == 2
    assert hub("homelab", "--new", "--project-name", "Homelab", "--session-id", SID).returncode == 1


def test_runner_still_saves_on_a_hub_without_howl(hub):
    _FakeHub.best, _FakeHub.legacy = {"slug": "homelab", "confidence": "high"}, True

    result = hub("--session-id", SID)

    assert result.returncode == 0, result.stderr
    saved = _posts("/api/save-project")[0]
    assert saved["slug"] == "homelab"
    assert len(saved["messages"]) == 2
    assert "older than /wolfhowl" in json.loads(result.stdout)["note"]


def test_runner_refuses_to_guess_the_session(hub):
    result = hub()

    assert result.returncode == 2
    assert "refusing to guess" in result.stderr
    assert _FakeHub.calls == []


def test_howl_does_not_create_a_project_without_the_users_choice(tmp_path, monkeypatch):
    from ide_storage.howl import run_howl

    # Keep the howl's mirrors (wiki pages, share git remote) out of the repo checkout.
    monkeypatch.setenv("WOLF_WIKI_ENABLED", "0")
    monkeypatch.setenv("WOLF_SHARE_ROOT", str(tmp_path / "share"))
    monkeypatch.delenv("IDE_STORAGE_VAULT_DIR", raising=False)

    workspace = str(tmp_path / "brand-new-folder")
    messages = [
        {"role": "user", "content": "start a brand new thing"},
        {"role": "assistant", "content": "decision: first note"},
    ]
    report = run_howl(workspace_path=workspace, messages=messages, session_id="s-1")

    assert report["ok"] is False
    assert report["needs_project_choice"] is True
    assert "created_project" not in report

    created = run_howl(
        workspace_path=workspace,
        messages=messages,
        session_id="s-1",
        create_project=True,
        project_name="Brand New",
    )
    assert created["created_project"]["name"] == "Brand New"


def _project(slug: str, path: str | None = None) -> int:
    from ide_storage.db import db_conn

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO projects (name, path, slug, status, created_at, updated_at) VALUES (?, ?, ?, 'active', 'now', 'now')",
            (slug.title(), path or "", slug),
        )
        conn.commit()
        cur.execute("SELECT id FROM projects WHERE slug = ?", (slug,))
        return int(cur.fetchone()["id"])


def test_a_folder_shared_by_several_projects_resolves_to_none(tmp_path):
    from ide_storage.hub import resolve_project
    from ide_storage.howl import run_eat, run_howl
    from ide_storage.paths import register_project_path

    shared, own = str(tmp_path / "workspace"), str(tmp_path / "workspace" / "fans")
    cooling, video, fans = _project("cooling"), _project("video"), _project("fans")
    register_project_path(cooling, shared)
    register_project_path(video, shared, force=True)  # how old data came to share a folder
    register_project_path(fans, own)

    assert resolve_project(path=shared) is None
    assert resolve_project(path=shared + "/notes") is None
    # A project with its own folder inside the shared one still resolves.
    assert resolve_project(path=own + "/src")["slug"] == "fans"

    messages = [{"role": "user", "content": "hello"}, {"role": "assistant", "content": "decision: hi"}]
    howl = run_howl(workspace_path=shared, messages=messages, session_id="s-shared")
    assert howl["needs_project_choice"] is True
    assert sorted(c["slug"] for c in howl["candidates"]) == ["cooling", "video"]
    assert sorted(c["slug"] for c in run_eat(workspace_path=shared)["candidates"]) == ["cooling", "video"]


def test_projects_sharing_a_legacy_path_do_not_resolve(tmp_path):
    from ide_storage.hub import resolve_project

    home = str(tmp_path / "root")
    _project("ssh-setup", home)
    _project("cache-drive", home)

    assert resolve_project(path=home) is None


def test_howl_does_not_link_a_folder_another_project_owns(tmp_path, monkeypatch):
    from ide_storage.howl import run_howl
    from ide_storage.paths import project_paths, register_project_path

    monkeypatch.setenv("WOLF_WIKI_ENABLED", "0")
    monkeypatch.setenv("WOLF_SHARE_ROOT", str(tmp_path / "share"))
    workspace = str(tmp_path / "lab")
    cooling, immich = _project("cooling"), _project("immich")
    register_project_path(cooling, workspace)

    messages = [{"role": "user", "content": "immich compose"}, {"role": "assistant", "content": "decision: done"}]
    report = run_howl(slug="immich", workspace_path=workspace, messages=messages, session_id="s-immich")

    assert report["ok"] is True
    assert report["path_alias"]["shared_with"] == ["cooling"]
    assert "not linked" in report["note"] or "was not" in report["note"]
    assert project_paths(immich) == []


def _runner(tmp_path, folder, *args, api="http://127.0.0.1:9"):
    import os

    env = {"HOME": str(tmp_path / "home"), "PATH": os.environ.get("PATH", ""), "WOLF_LEADER_API": api,
           "WOLF_LEADER_WORKSPACE": str(folder), "GIT_CONFIG_GLOBAL": os.devnull}
    (tmp_path / "home").mkdir(exist_ok=True)
    return subprocess.run([sys.executable, str(SCRIPTS / "wolfhowl.py"), *args],
                          capture_output=True, text=True, env=env, cwd=folder, timeout=60)


def test_create_repo_leaves_secrets_data_and_nested_repos_out(tmp_path):
    folder = tmp_path / "stack"
    (folder / "node_modules" / "x").mkdir(parents=True)
    (folder / "vendor" / "lib").mkdir(parents=True)
    (folder / "compose.yml").write_text("services: {}\n")
    (folder / ".env").write_text("TOKEN=real\n")
    (folder / ".env.example").write_text("TOKEN=\n")
    (folder / "server.key").write_text("k\n")
    (folder / "node_modules" / "x" / "i.js").write_text("1\n")
    (folder / "vendor" / "lib" / "f.txt").write_text("1\n")
    subprocess.run(["git", "init", "-q", str(folder / "vendor" / "lib")], check=True)

    plan = json.loads(_runner(tmp_path, folder, "--create-repo", "--plan").stdout)
    assert sorted(plan["to_commit"]) == [".env.example", "compose.yml"]
    assert sorted(plan["ignored"]) == [".env", "node_modules/", "server.key"]
    assert plan["nested_repos"] == ["vendor/lib/"]
    assert not (folder / ".git").exists()  # a plan changes nothing

    assert _runner(tmp_path, folder, "--create-repo").returncode == 2  # needs the slug

    result = json.loads(_runner(tmp_path, folder, "stack", "--create-repo", "--no-push").stdout)
    assert result["ok"] is True
    tracked = subprocess.run(["git", "-C", str(folder), "ls-files"], capture_output=True, text=True).stdout.split()
    assert sorted(tracked) == [".env.example", ".gitignore", "compose.yml"]
    assert subprocess.run(["git", "-C", str(folder), "status", "--porcelain"], capture_output=True, text=True).stdout == ""

    # Running it again on a clean repo is harmless.
    again = json.loads(_runner(tmp_path, folder, "stack", "--create-repo", "--no-push").stdout)
    assert again["ok"] is True and again["done"] == []


def test_create_repo_refuses_a_folder_inside_another_repo(tmp_path):
    outer = tmp_path / "outer"
    inner = outer / "inner"
    inner.mkdir(parents=True)
    (inner / "a.txt").write_text("a\n")
    subprocess.run(["git", "init", "-q", str(outer)], check=True)

    result = _runner(tmp_path, inner, "inner", "--create-repo", "--no-push")

    assert result.returncode == 1
    assert "inside another git repo" in json.loads(result.stdout)["error"]


def test_a_home_folder_never_claims_the_projects_inside_it(tmp_path):
    from ide_storage.hub import create_project_for_path, resolve_project
    from ide_storage.paths import register_project_path

    home = "/" + "Users/example"
    migration = _project("migration", home)
    register_project_path(migration, home, force=True)  # how old data came to hold one

    # The home folder itself still finds its project...
    assert resolve_project(path=home)["slug"] == "migration"
    # ...but a new folder inside it is not that project.
    new_folder = home + "/Projects/live-worship"
    assert resolve_project(path=new_folder) is None
    made = create_project_for_path(new_folder, name="Live Worship")
    assert made["created"] is True and made["name"] == "Live Worship"
    assert resolve_project(path=new_folder + "/song-1")["id"] == made["id"]
    # Asking again for the same folder returns it rather than making a second one.
    again = create_project_for_path(new_folder, name="Live Worship")
    assert (again["created"], again["id"]) == (False, made["id"])
    # And a home folder is not linked to a project unless forced.
    assert register_project_path(made["id"], home)["broad_folder"] is True


def test_a_new_folder_under_a_real_project_folder_still_belongs_to_it():
    from ide_storage.hub import create_project_for_path, resolve_project
    from ide_storage.paths import register_project_path

    pid = _project("fans")
    register_project_path(pid, "/work/fans")
    assert resolve_project(path="/work/fans/scripts")["id"] == pid
    # Creating a project for a subfolder on purpose makes a new one.
    assert create_project_for_path("/work/fans/scripts", name="Fan Scripts")["created"] is True
