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
    # No session_id: with one, the hub probes its own Cursor transcript folder first.
    report = run_howl(workspace_path=workspace, content="decision: first note")

    assert report["ok"] is False
    assert report["needs_project_choice"] is True
    assert "created_project" not in report

    created = run_howl(
        workspace_path=workspace,
        content="decision: first note",
        create_project=True,
        project_name="Brand New",
    )
    assert created["created_project"]["name"] == "Brand New"
