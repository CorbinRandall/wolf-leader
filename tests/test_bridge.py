"""The chat helper that runs on a person's own computer (ide_storage/bridge.py)."""
from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from ide_storage import bridge


def _serve():
    server = ThreadingHTTPServer(("127.0.0.1", 0), None)
    port = server.server_address[1]
    helper = bridge.Bridge("http://127.0.0.1:9", port)  # no hub needed for these checks
    server.RequestHandlerClass = bridge.make_handler(helper)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, port


def _get(port, path, headers=None):
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=10) as reply:
            return reply.status, reply.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def test_only_this_computers_own_page_may_use_the_helper():
    server, port = _serve()
    try:
        code, body = _get(port, "/bridge/status")
        assert code == 200 and {a["id"] for a in json.loads(body)["agents"]} == {"claude", "codex"}
        # The page itself is served by the helper, so chat works with an older hub.
        code, page = _get(port, "/chat")
        assert code == 200 and b"Wolf Leader" in page
        # Another website, or another machine's name for this one, is refused.
        assert _get(port, "/bridge/status", {"Origin": "http://evil.example"})[0] == 403
        assert _get(port, "/bridge/status", {"Host": "evil.example"})[0] == 403
        assert _get(port, "/bridge/chats/not-a-real-chat-id")[0] == 404
    finally:
        server.shutdown()


def test_addresses_and_times_match_the_mac_app():
    assert bridge.Hub("http://127.0.0.1:6971").mcp_url() == "http://127.0.0.1:6972/mcp"
    # A personal address keeps its access key.
    assert bridge.Hub("http://bbq:6971/k/abc123").mcp_url() == "http://bbq:6972/k/abc123/mcp"
    # The Mac app stores times as seconds since 2001; the hub wants ISO with milliseconds.
    assert bridge.iso_ms(0.5) == "2001-01-01T00:00:00.500Z"
    assert bridge.claude_title("Bash", {"command": "ls -la"}) == "Run `ls -la`"
    assert bridge.claude_title("Edit", {"file_path": "/a/b/main.py"}) == "Edit main.py"
