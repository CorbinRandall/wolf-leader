"""Who is asking: an access key per person, and each person sees only their own projects.

A hub several people share keeps one key per person (``access-keys.json`` in the data
folder). A request says who it is from with its key, sent any of three ways so every tool
can do it without new code:

- in the address: ``http://hub:6971/k/<key>/api/...`` and ``http://hub:6972/k/<key>/mcp``
- ``Authorization: Bearer <key>``
- the ``wl_key`` cookie (the web page sets it when opened through a ``/k/<key>/`` link)

The hub's admin (``WOLF_ADMIN``) sees everything. Anyone else sees the projects they own
or made, plus projects marked for everyone; in Postgres that limit is enforced by the
database itself (row-level security), so every endpoint and every MCP tool obeys it.

Requests with no key are allowed on the hub's own ports (reached only from the server
itself or an SSH tunnel) and refused on the public ports (``WOLF_PUBLIC_PORT``,
``WOLF_MCP_PUBLIC_PORT``), which are the ones published to the network.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import socket
import time
from contextvars import ContextVar
from typing import Any, Dict, List, Optional

# The person this request is limited to. None means no limit: the admin, a keyless request
# on a trusted port, or the hub's own background work.
current_person: ContextVar[Optional[str]] = ContextVar("wolf_person", default=None)

_KEY_IN_PATH = re.compile(r"^/k/([A-Za-z0-9_-]{16,})(/.*)?$")
_OPEN_PATHS = ("/health",)
_PROJECT_PATH = re.compile(r"^/api/projects/([^/]+)(/|$)")
_keys_cache: Dict[str, Any] = {"mtime": None, "keys": {}}
_visible_cache: Dict[str, Any] = {}


def admin_name() -> str:
    return os.environ.get("WOLF_ADMIN", "").strip()


def public_ports() -> set:
    ports = set()
    for name in ("WOLF_PUBLIC_PORT", "WOLF_MCP_PUBLIC_PORT"):
        value = os.environ.get(name, "").strip()
        if value.isdigit():
            ports.add(int(value))
    return ports


def restricted_person() -> Optional[str]:
    return current_person.get()


# ------------------------------------------------------------------ keys
def _keys_file() -> str:
    from .db import get_projects_dir

    explicit = os.environ.get("WOLF_ACCESS_KEYS_FILE", "").strip()
    return explicit or os.path.join(os.path.dirname(get_projects_dir().rstrip("/")), "access-keys.json")


def load_keys() -> Dict[str, str]:
    """``{person: key}``. Read again whenever the file changes (the MCP server is another process)."""
    path = _keys_file()
    try:
        mtime = os.stat(path).st_mtime_ns
    except OSError:
        _keys_cache.update(mtime=None, keys={})
        return {}
    if _keys_cache["mtime"] != mtime or _keys_cache.get("path") != path:
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
            keys = {str(k): str(v) for k, v in data.items() if v}
        except Exception:  # noqa: BLE001
            keys = {}
        _keys_cache.update(mtime=mtime, keys=keys, path=path)
    return dict(_keys_cache["keys"])


def _save_keys(keys: Dict[str, str]) -> None:
    path = _keys_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as handle:
        json.dump(keys, handle, indent=2)
    os.replace(tmp, path)
    _keys_cache.update(mtime=None)


def key_for(person: str, *, new: bool = False) -> str:
    """The person's key, made on first use. ``new`` replaces it (the old one stops working)."""
    keys = load_keys()
    match = next((name for name in keys if name.lower() == person.lower()), None)
    if match and not new:
        return keys[match]
    if match:
        del keys[match]
    keys[person] = secrets.token_urlsafe(24)
    _save_keys(keys)
    return keys[person]


def person_for_key(key: str) -> Optional[str]:
    if not key:
        return None
    for person, value in load_keys().items():
        if secrets.compare_digest(value, key):
            return person
    return None


def is_admin(person: Optional[str]) -> bool:
    return bool(person) and person.lower() == admin_name().lower()


# ------------------------------------------------------- what a person sees
def visible_project_ids(person: str) -> List[int]:
    """Projects this person owns, plus those marked for everyone. Looked up with no limit applied."""
    cached = _visible_cache.get(person.lower())
    if cached and time.monotonic() - cached[0] < 5:
        return cached[1]
    token = current_person.set(None)
    try:
        from .db import db_conn
        from .owners import attach_owners

        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute("SELECT id, path, compose_path, metadata FROM projects")
            rows = [dict(r) for r in cur.fetchall()]
        ids = []
        for row in attach_owners(rows):
            meta = row.get("metadata")
            try:
                meta = json.loads(meta) if isinstance(meta, str) and meta else (meta or {})
            except Exception:  # noqa: BLE001
                meta = {}
            everyone = isinstance(meta, dict) and bool(meta.get("everyone"))
            if everyone or (row.get("owner") or "").lower() == person.lower():
                ids.append(int(row["id"]))
    finally:
        current_person.reset(token)
    _visible_cache[person.lower()] = (time.monotonic(), ids)
    return ids


def apply_to_connection(raw) -> None:
    """Limit a new Postgres connection to what the current person may see. No-op for no limit."""
    person = restricted_person()
    if not person:
        return
    visible = ",".join(str(i) for i in visible_project_ids(person)) or "0"
    with raw.cursor() as cur:
        cur.execute("SELECT set_config('wolf.person', %s, false), set_config('wolf.visible', %s, false)", (person, visible))
        cur.execute("SET ROLE wolf_member")
    if not raw.autocommit:
        raw.commit()


# Tables whose rows belong to a project.
_PROJECT_TABLES = [
    "snippets", "project_paths", "memories", "howls", "north_stars", "goals", "milestones",
    "build_prompts", "jobs", "fs_catalog", "file_chunks", "knowledge_revisions",
]
_PERSON = "current_setting('wolf.person', true)"
_HAS_PROJECT = "EXISTS (SELECT 1 FROM projects wp WHERE wp.id = project_id)"
_POLICY = "wolf_own_v1"


def _policies() -> Dict[str, str]:
    rules = {
        "projects": f"wolf_sees(id) OR created_by = {_PERSON}",
        "chats": f"(project_id IS NOT NULL AND {_HAS_PROJECT}) OR (project_id IS NULL AND created_by = {_PERSON})",
        "app_chats": f"(project_id IS NOT NULL AND {_HAS_PROJECT}) OR (project_id IS NULL AND created_by = {_PERSON})",
        "messages": "EXISTS (SELECT 1 FROM chats wc WHERE wc.id = chat_id)",
        "attachments": f"(project_id IS NOT NULL AND {_HAS_PROJECT}) OR EXISTS (SELECT 1 FROM chats wc WHERE wc.id = chat_id)",
        "profile_items": f"lower(person) = lower({_PERSON})",
        "offsite_copies": "false",
        "app_settings": "true",
        "embeddings": (
            "CASE kind"
            " WHEN 'memory' THEN EXISTS (SELECT 1 FROM memories x WHERE x.id = ref_id)"
            " WHEN 'chat' THEN EXISTS (SELECT 1 FROM chats x WHERE x.id = ref_id)"
            " WHEN 'howl' THEN EXISTS (SELECT 1 FROM howls x WHERE x.id = ref_id)"
            " WHEN 'catalog' THEN EXISTS (SELECT 1 FROM fs_catalog x WHERE x.id = ref_id)"
            " WHEN 'chunk' THEN EXISTS (SELECT 1 FROM file_chunks x WHERE x.id = ref_id)"
            " WHEN 'project' THEN EXISTS (SELECT 1 FROM projects x WHERE x.id = ref_id)"
            " ELSE false END"
        ),
    }
    for table in _PROJECT_TABLES:
        rules[table] = _HAS_PROJECT
    return rules


def setup_database(cur) -> None:
    """Postgres only, idempotent: the member role, who-made-it columns and the per-table rules.

    The hub's own database user is not subject to these rules; they apply only after a
    connection switches to ``wolf_member`` (see ``apply_to_connection``).
    """
    cur.execute("SELECT pg_advisory_lock(7710011)")
    try:
        _setup_locked(cur)
    finally:
        cur.execute("SELECT pg_advisory_unlock(7710011)")


def _setup_locked(cur) -> None:
    def column(sql: str) -> set:
        cur.execute(sql)
        return {(r["v"] if isinstance(r, dict) else r[0]) for r in cur.fetchall()}

    tables = column("SELECT tablename AS v FROM pg_tables WHERE schemaname = current_schema()")
    for table in ("projects", "chats", "app_chats"):
        if table in tables:
            cur.execute(f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS created_by TEXT DEFAULT {_PERSON}")
    cur.execute(
        "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'wolf_member') THEN "
        "CREATE ROLE wolf_member NOLOGIN; END IF; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
    )
    cur.execute(
        "CREATE OR REPLACE FUNCTION wolf_sees(pid BIGINT) RETURNS boolean LANGUAGE sql STABLE AS "
        "$$ SELECT pid = ANY(string_to_array(NULLIF(current_setting('wolf.visible', true), ''), ',')::bigint[]) $$"
    )
    schema = column("SELECT current_schema() AS v").pop()
    cur.execute(f'GRANT USAGE, CREATE ON SCHEMA "{schema}" TO wolf_member')
    cur.execute(f'GRANT ALL ON ALL TABLES IN SCHEMA "{schema}" TO wolf_member')
    cur.execute(f'GRANT ALL ON ALL SEQUENCES IN SCHEMA "{schema}" TO wolf_member')
    cur.execute(f'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA "{schema}" TO wolf_member')
    have = column("SELECT tablename || '/' || policyname AS v FROM pg_policies WHERE schemaname = current_schema()")
    for table, rule in _policies().items():
        if table not in tables:
            continue
        cur.execute(f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY")
        if f"{table}/{_POLICY}" not in have:
            cur.execute(f"CREATE POLICY {_POLICY} ON {table} USING ({rule}) WITH CHECK (true)")
    # Views answer as whoever asks, so they obey the same rules.
    for view in column("SELECT viewname AS v FROM pg_views WHERE schemaname = current_schema()"):
        cur.execute(f"ALTER VIEW {view} SET (security_invoker = true)")


# ------------------------------------------------------------- the gate
_SIGN_IN = """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wolf Leader</title>
<body style="font:16px -apple-system,system-ui,sans-serif;max-width:26em;margin:18vh auto;padding:0 1em;color:#dde3f0;background:#0b1220">
<h2>Wolf Leader</h2><p>Paste your access key to sign in.</p>
<form onsubmit="location.href='/k/'+encodeURIComponent(this.k.value.trim())+'/';return false">
<input name="k" autofocus autocomplete="off" style="width:100%;padding:.6em;font:inherit;border-radius:8px;border:1px solid #334;background:#111a2e;color:inherit">
<button style="margin-top:.8em;padding:.6em 1.2em;font:inherit;border-radius:8px;border:0;background:#4c8dff;color:#fff">Sign in</button>
</form><p style="color:#8892a6;font-size:.85em">Ask the hub's owner for your key.</p></body>"""


async def _reply(send, status: int, body: bytes, content_type: bytes, extra: Optional[list] = None) -> None:
    headers = [(b"content-type", content_type), (b"content-length", str(len(body)).encode())] + (extra or [])
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


def _project_visible(key: str, person: str) -> bool:
    """Is this project (id or slug) one the person may see? Checked with their own limits."""
    from .db import db_conn, is_sqlite

    if is_sqlite():
        return True
    token = current_person.set(person)
    try:
        with db_conn() as conn:
            cur = conn.cursor()
            if key.isdigit():
                cur.execute("SELECT 1 FROM projects WHERE id = ?", (int(key),))
            else:
                cur.execute("SELECT 1 FROM projects WHERE slug = ?", (key,))
            return cur.fetchone() is not None
    finally:
        current_person.reset(token)


def _is_project_key(key: str) -> bool:
    """True when ``key`` names a real project (so a fixed route such as /api/projects/merge passes)."""
    from .db import db_conn

    token = current_person.set(None)
    try:
        with db_conn() as conn:
            cur = conn.cursor()
            if key.isdigit():
                cur.execute("SELECT 1 FROM projects WHERE id = ?", (int(key),))
            else:
                cur.execute("SELECT 1 FROM projects WHERE slug = ?", (key,))
            return cur.fetchone() is not None
    finally:
        current_person.reset(token)


class AccessMiddleware:
    """ASGI gate in front of the REST app and the MCP app: works out who is asking."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path") or "/"
        key = None
        via_link = False
        match = _KEY_IN_PATH.match(path)
        if match:
            key, path, via_link = match.group(1), match.group(2) or "/", True
            # Rewritten in place so the key never reaches the app or its access log.
            scope["path"] = path
            scope["raw_path"] = path.encode()
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers") or []}
        if not key and headers.get("authorization", "").lower().startswith("bearer "):
            key = headers["authorization"][7:].strip()
        if not key:
            cookie = re.search(r"(?:^|;\s*)wl_key=([A-Za-z0-9_-]+)", headers.get("cookie", ""))
            key = cookie.group(1) if cookie else None

        server = scope.get("server") or ("", 0)
        public = server[1] in public_ports()
        is_page = scope.get("method") == "GET" and not path.startswith(("/api", "/mcp", "/static", "/health"))
        person = None
        if key:
            person = person_for_key(key)
            if not person:
                if is_page:
                    return await _reply(send, 401, _SIGN_IN.encode(), b"text/html; charset=utf-8",
                                        [(b"set-cookie", b"wl_key=; Path=/; Max-Age=0")])
                return await _reply(send, 401, b'{"detail":"That access key is not valid."}', b"application/json")
        elif public and path not in _OPEN_PATHS and scope.get("method") != "OPTIONS":
            if is_page:
                return await _reply(send, 401, _SIGN_IN.encode(), b"text/html; charset=utf-8")
            return await _reply(send, 401, b'{"detail":"This hub needs your access key."}', b"application/json")

        if via_link and is_page:
            # Opened in a browser through a personal link: remember the key, show a clean address.
            cookie = f"wl_key={key}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax".encode()
            return await _reply(send, 303, b"", b"text/plain", [(b"location", path.encode()), (b"set-cookie", cookie)])

        limited = person if person and not is_admin(person) else None
        if limited:
            project = _PROJECT_PATH.match(path)
            if project and not _project_visible(project.group(1), limited) and _is_project_key(project.group(1)):
                return await _reply(send, 404, b'{"detail":"Project not found"}', b"application/json")
        scope.setdefault("state", {})["wolf_person"] = person
        token = current_person.set(limited)
        try:
            await self.app(scope, receive, send)
        finally:
            current_person.reset(token)


def serve(app, host: str, port: int, public_port: Optional[int] = None, log_level: str = "info") -> None:
    """Run an ASGI app on its usual port and, when set, on a second public port in the same process."""
    import asyncio

    import uvicorn

    config = uvicorn.Config(app, host=host, port=port, log_level=log_level)
    server = uvicorn.Server(config)
    if not public_port or public_port == port:
        server.run()
        return
    sockets = []
    for p in (port, public_port):
        sock = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, p))
        sock.set_inheritable(True)
        sockets.append(sock)
    asyncio.run(server.serve(sockets=sockets))
