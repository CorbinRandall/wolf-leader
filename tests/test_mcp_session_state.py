from __future__ import annotations

from types import SimpleNamespace

from ide_storage import mcp_server


def test_active_project_state_expires(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(mcp_server.time, "monotonic", lambda: now[0])
    mcp_server._active_by_session.clear()

    ctx = SimpleNamespace(session_id="old-session")
    state = mcp_server._get_active(ctx)
    state["slug"] = "old-project"

    now[0] += mcp_server._ACTIVE_SESSION_TTL_SECONDS + 1
    fresh = mcp_server._get_active(SimpleNamespace(session_id="new-session"))

    assert "old-session" not in mcp_server._active_by_session
    assert fresh["slug"] is None


def test_active_project_state_is_bounded(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(mcp_server.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(mcp_server, "_ACTIVE_SESSION_MAX_ENTRIES", 2)
    mcp_server._active_by_session.clear()

    for session_id in ("one", "two", "three"):
        mcp_server._get_active(SimpleNamespace(session_id=session_id))
        now[0] += 1

    assert len(mcp_server._active_by_session) == 2
    assert "one" not in mcp_server._active_by_session

