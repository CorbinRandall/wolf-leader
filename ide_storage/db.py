"""Postgres + pgvector database layer.

One database, vectors next to the rows they describe. This module exposes a thin
connection wrapper so the rest of the code base can keep writing SQLite-style
SQL (``?`` placeholders, ``cur.lastrowid``, ``row["col"]`` / ``row[0]``) while
everything actually runs on Postgres.

Connection string: ``DATABASE_URL`` (or ``IDE_STORAGE_DATABASE_URL``).
"""
from __future__ import annotations

import os
import re
from contextlib import contextmanager
from typing import Any, Iterator, Sequence

import psycopg
from psycopg import sql as _pgsql  # noqa: F401  (re-exported for callers that want it)

MEMORY_TYPES = (
    "active_work",
    "constraint",
    "problem",
    "goal",
    "decision",
    "note",
    "caveat",
)

JOB_STATES = ("queued", "running", "done", "failed", "cancelled")

DEFAULT_DATABASE_URL = "postgresql://wolf:wolf@127.0.0.1:5432/wolf_leader"


def database_url() -> str:
    return (
        os.environ.get("DATABASE_URL")
        or os.environ.get("IDE_STORAGE_DATABASE_URL")
        or DEFAULT_DATABASE_URL
    )


def get_db_path() -> str:
    """Kept for callers/logs that still print a 'database location'."""
    return database_url()


def db_file() -> str:
    """Legacy name. There is no file any more; returns the connection URL."""
    return database_url()


def get_projects_dir() -> str:
    return os.environ.get("IDE_STORAGE_PROJECTS_DIR", "/data/projects")


def get_vault_dir() -> str | None:
    """Obsidian vault folder on the share (e.g. /srv/wolf/wolf-leader/vault)."""
    value = os.environ.get("IDE_STORAGE_VAULT_DIR", "").strip()
    return value or None


# --------------------------------------------------------------------------- rows
class Row(Sequence):
    """Row that supports ``row["col"]``, ``row[0]``, ``dict(row)`` and ``row.keys()``."""

    __slots__ = ("_cols", "_vals", "_index")

    def __init__(self, cols: tuple[str, ...], vals: tuple[Any, ...], index: dict[str, int]):
        self._cols = cols
        self._vals = vals
        self._index = index

    def __getitem__(self, key):  # type: ignore[override]
        if isinstance(key, (int, slice)):
            return self._vals[key]
        return self._vals[self._index[key]]

    def __len__(self) -> int:
        return len(self._vals)

    def __iter__(self) -> Iterator[Any]:
        return iter(self._vals)

    def keys(self):
        return list(self._cols)

    def values(self):
        return list(self._vals)

    def items(self):
        return list(zip(self._cols, self._vals))

    def get(self, key, default=None):
        idx = self._index.get(key)
        return default if idx is None else self._vals[idx]

    def __contains__(self, key) -> bool:  # type: ignore[override]
        return key in self._index

    def __repr__(self) -> str:
        return f"Row({dict(self.items())!r})"


def _row_factory(cursor: psycopg.Cursor):
    desc = cursor.description or ()
    cols = tuple(d.name for d in desc)
    index = {name: i for i, name in enumerate(cols)}

    def make(values: Sequence[Any]) -> Row:
        return Row(cols, tuple(values), index)

    return make


# ----------------------------------------------------------------- SQL translation
_LIKE_RE = re.compile(r"(?<![A-Za-z_])LIKE(?![A-Za-z_])")
_PRINTF_RE = re.compile(r"(?<![A-Za-z_])printf\(", re.IGNORECASE)
_INSERT_RE = re.compile(r"^\s*INSERT\s+INTO\s+([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)
_RETURNING_RE = re.compile(r"\bRETURNING\b", re.IGNORECASE)
_HAS_ID_TABLES = {
    "projects",
    "project_paths",
    "chats",
    "messages",
    "memories",
    "embeddings",
    "howls",
    "jobs",
    "fs_catalog",
    "file_chunks",
    "knowledge_revisions",
}


def translate_sql(sql: str, has_params: bool) -> str:
    """SQLite-flavoured SQL -> Postgres.

    * ``?`` -> ``%s`` (outside string literals); literal ``%`` -> ``%%`` when
      params are bound (psycopg only interprets ``%`` in that case)
    * ``LIKE`` -> ``ILIKE`` (SQLite LIKE is case-insensitive)
    * ``printf(`` -> ``format(``
    """
    out: list[str] = []
    in_str = False
    for ch in sql:
        if ch == "'":
            in_str = not in_str
            out.append(ch)
        elif in_str:
            out.append("%%" if (ch == "%" and has_params) else ch)
        elif ch == "?" and has_params:
            out.append("%s")
        elif ch == "%" and has_params:
            out.append("%%")
        else:
            out.append(ch)
    text = "".join(out)
    text = _LIKE_RE.sub("ILIKE", text)
    text = _PRINTF_RE.sub("format(", text)
    return text


def _auto_returning(sql: str) -> str | None:
    """Append ``RETURNING id`` to plain INSERTs so ``cur.lastrowid`` works."""
    m = _INSERT_RE.match(sql)
    if not m or _RETURNING_RE.search(sql):
        return None
    if m.group(1).lower() not in _HAS_ID_TABLES:
        return None
    return sql.rstrip().rstrip(";") + " RETURNING id"


def _clean_params(params: Sequence[Any]) -> tuple:
    # Postgres text columns reject NUL bytes; transcripts and files on disk can
    # carry them (UTF-16 saves, pasted binary). Drop them rather than fail the save.
    return tuple(p.replace("\x00", "") if isinstance(p, str) and "\x00" in p else p for p in params)


# ----------------------------------------------------------------- wrappers
class Cursor:
    def __init__(self, raw: psycopg.Cursor):
        self._raw = raw
        self.lastrowid: int | None = None

    def execute(self, sql: str, params: Sequence[Any] | None = None) -> "Cursor":
        has_params = params is not None and len(params) > 0
        text = translate_sql(sql, has_params)
        bound = _clean_params(params) if has_params else None
        returning = _auto_returning(text)
        if returning is not None:
            self._raw.execute(returning, bound)
            row = self._raw.fetchone()
            self.lastrowid = int(row[0]) if row and row[0] is not None else None
        else:
            self._raw.execute(text, bound)
            self.lastrowid = None
        return self

    def executemany(self, sql: str, seq: Sequence[Sequence[Any]]) -> "Cursor":
        text = translate_sql(sql, True)
        self._raw.executemany(text, [_clean_params(p) for p in seq])
        return self

    def fetchone(self):
        return self._raw.fetchone()

    def fetchall(self):
        return self._raw.fetchall()

    def fetchmany(self, size: int | None = None):
        return self._raw.fetchmany(size) if size else self._raw.fetchmany()

    @property
    def rowcount(self) -> int:
        return self._raw.rowcount

    @property
    def description(self):
        return self._raw.description

    def __iter__(self):
        return iter(self._raw)

    def close(self) -> None:
        self._raw.close()


class Connection:
    """sqlite3-shaped facade over a psycopg connection."""

    def __init__(self, raw: psycopg.Connection):
        self._raw = raw
        self.row_factory = None  # accepted and ignored (rows are always Row)

    def cursor(self) -> Cursor:
        return Cursor(self._raw.cursor(row_factory=_row_factory))

    def execute(self, sql: str, params: Sequence[Any] | None = None) -> Cursor:
        return self.cursor().execute(sql, params)

    def commit(self) -> None:
        self._raw.commit()

    def rollback(self) -> None:
        self._raw.rollback()

    def close(self) -> None:
        try:
            self._raw.close()
        except Exception:
            pass

    @property
    def closed(self) -> bool:
        return self._raw.closed

    @property
    def raw(self) -> psycopg.Connection:
        return self._raw

    def __enter__(self) -> "Connection":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        # sqlite3 semantics: commit on success, rollback on error, do not close.
        if exc_type is None:
            self.commit()
        else:
            self.rollback()


def _register_vector(conn: psycopg.Connection) -> None:
    try:
        from pgvector.psycopg import register_vector

        register_vector(conn)
    except Exception:
        # Extension not created yet (first init) or pgvector package missing.
        pass


def connect(db_path: Any = None, *, autocommit: bool = False) -> Connection:
    """Open a connection. ``db_path`` is accepted for legacy call sites and ignored."""
    raw = psycopg.connect(database_url(), autocommit=autocommit)
    _register_vector(raw)
    return Connection(raw)


@contextmanager
def db_conn():
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


# ----------------------------------------------------------------- schema
def _vector_dim() -> int:
    from ide_storage.embeddings import embed_dim

    return embed_dim()


SCHEMA_STATEMENTS = [
    "CREATE EXTENSION IF NOT EXISTS vector",
    """
    CREATE TABLE IF NOT EXISTS projects (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL DEFAULT '',
        description TEXT,
        slug TEXT,
        status TEXT DEFAULT 'active',
        compose_path TEXT,
        tags TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        metadata TEXT
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_projects_slug ON projects(slug)",
    "CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path)",
    """
    CREATE TABLE IF NOT EXISTS project_paths (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'workspace',
        device_name TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(project_id, path)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_project_paths_path ON project_paths(path)",
    """
    CREATE TABLE IF NOT EXISTS chats (
        id BIGSERIAL PRIMARY KEY,
        title TEXT,
        workspace_path TEXT,
        device_name TEXT,
        session_id TEXT,
        project_id BIGINT REFERENCES projects(id) ON DELETE SET NULL,
        status TEXT DEFAULT 'active',
        tags TEXT,
        occurred_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        metadata TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_chats_workspace ON chats(workspace_path)",
    "CREATE INDEX IF NOT EXISTS idx_chats_created ON chats(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_chats_session ON chats(session_id)",
    "CREATE INDEX IF NOT EXISTS idx_chats_project ON chats(project_id)",
    "CREATE INDEX IF NOT EXISTS idx_chats_status ON chats(status)",
    "CREATE INDEX IF NOT EXISTS idx_chats_occurred ON chats(occurred_at)",
    """
    CREATE TABLE IF NOT EXISTS messages (
        id BIGSERIAL PRIMARY KEY,
        chat_id BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL,
        metadata TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id)",
    """
    CREATE TABLE IF NOT EXISTS memories (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        source_chat_id BIGINT REFERENCES chats(id) ON DELETE SET NULL,
        status TEXT DEFAULT 'active',
        semantic_descriptor TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_memories_project ON memories(project_id)",
    "CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type)",
    """
    CREATE TABLE IF NOT EXISTS howls (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT REFERENCES projects(id) ON DELETE CASCADE,
        chat_id BIGINT REFERENCES chats(id) ON DELETE SET NULL,
        device_name TEXT,
        workspace_path TEXT,
        summary TEXT,
        actions TEXT,
        offers TEXT,
        git_commit TEXT,
        git_branch TEXT,
        git_remote TEXT,
        memories_added INTEGER DEFAULT 0,
        files_ingested INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_howls_project ON howls(project_id)",
    """
    CREATE TABLE IF NOT EXISTS jobs (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT REFERENCES projects(id) ON DELETE SET NULL,
        howl_id BIGINT REFERENCES howls(id) ON DELETE SET NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'queued',
        title TEXT,
        connector TEXT,
        target TEXT,
        payload TEXT,
        result TEXT,
        error TEXT,
        progress REAL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        started_at TEXT,
        finished_at TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state)",
    "CREATE INDEX IF NOT EXISTS idx_jobs_project ON jobs(project_id)",
    """
    CREATE TABLE IF NOT EXISTS fs_catalog (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        root_path TEXT NOT NULL,
        rel_path TEXT NOT NULL,
        name TEXT NOT NULL,
        ext TEXT,
        is_dir BOOLEAN NOT NULL DEFAULT FALSE,
        size BIGINT,
        mtime TEXT,
        content_hash TEXT,
        git_status TEXT,
        blurb TEXT,
        updated_at TEXT NOT NULL,
        UNIQUE(project_id, root_path, rel_path)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_fs_catalog_project ON fs_catalog(project_id)",
    "CREATE INDEX IF NOT EXISTS idx_fs_catalog_name ON fs_catalog(name)",
    """
    CREATE TABLE IF NOT EXISTS file_chunks (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        fs_catalog_id BIGINT REFERENCES fs_catalog(id) ON DELETE CASCADE,
        howl_id BIGINT REFERENCES howls(id) ON DELETE SET NULL,
        path TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        reason TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(project_id, path, chunk_index)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_file_chunks_project ON file_chunks(project_id)",
    """
    CREATE TABLE IF NOT EXISTS knowledge_revisions (
        id BIGSERIAL PRIMARY KEY,
        project_id BIGINT REFERENCES projects(id) ON DELETE CASCADE,
        howl_id BIGINT REFERENCES howls(id) ON DELETE SET NULL,
        repo_path TEXT,
        commit_sha TEXT,
        branch TEXT,
        note TEXT,
        created_at TEXT NOT NULL
    )
    """,
]

EMBEDDINGS_TABLE_TEMPLATE = """
    CREATE TABLE IF NOT EXISTS embeddings (
        id BIGSERIAL PRIMARY KEY,
        kind TEXT NOT NULL,
        ref_id BIGINT NOT NULL,
        model TEXT NOT NULL,
        dim INTEGER NOT NULL,
        text_hash TEXT NOT NULL,
        embed_text TEXT NOT NULL,
        vector vector({dim}) NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(kind, ref_id, model)
    )
"""

EMBEDDINGS_INDEXES = [
    "CREATE INDEX IF NOT EXISTS idx_embeddings_kind ON embeddings(kind)",
    "CREATE INDEX IF NOT EXISTS idx_embeddings_hash ON embeddings(text_hash)",
    "CREATE INDEX IF NOT EXISTS idx_embeddings_hnsw ON embeddings USING hnsw (vector vector_cosine_ops)",
]

VIEWS = [
    # Latest handoff per project: newest archived chat (the /save checkpoint) or
    # active_work memory, whichever is newer.
    """
    CREATE OR REPLACE VIEW v_left_off AS
    SELECT p.id AS project_id,
           p.slug,
           c.id AS chat_id,
           c.title AS chat_title,
           c.content AS summary,
           COALESCE(c.occurred_at, c.created_at, c.updated_at) AS occurred_at,
           c.metadata AS chat_metadata
    FROM projects p
    LEFT JOIN LATERAL (
        SELECT * FROM chats ch
        WHERE ch.project_id = p.id
        ORDER BY COALESCE(ch.occurred_at, ch.created_at, ch.updated_at) DESC
        LIMIT 1
    ) c ON TRUE
    """,
    # The one "eat this" picture per project, as JSON columns.
    """
    CREATE OR REPLACE VIEW v_project_recall AS
    SELECT p.id, p.slug, p.name, p.description, p.status, p.path, p.compose_path,
           p.tags, p.metadata, p.updated_at,
           (SELECT COALESCE(json_agg(json_build_object(
                'path', pp.path, 'kind', pp.kind, 'device_name', pp.device_name)
                ORDER BY pp.id), '[]'::json)
              FROM project_paths pp WHERE pp.project_id = p.id) AS paths,
           (SELECT COALESCE(json_agg(json_build_object(
                'id', m.id, 'type', m.type, 'content', m.content,
                'updated_at', m.updated_at) ORDER BY m.updated_at DESC), '[]'::json)
              FROM (SELECT * FROM memories mm
                    WHERE mm.project_id = p.id AND COALESCE(mm.status,'active') = 'active'
                    ORDER BY mm.updated_at DESC LIMIT 40) m) AS memories,
           (SELECT COALESCE(json_agg(json_build_object(
                'id', h.id, 'summary', h.summary, 'device_name', h.device_name,
                'git_commit', h.git_commit, 'git_branch', h.git_branch,
                'created_at', h.created_at) ORDER BY h.created_at DESC), '[]'::json)
              FROM (SELECT * FROM howls hh WHERE hh.project_id = p.id
                    ORDER BY hh.created_at DESC LIMIT 10) h) AS howls,
           (SELECT COALESCE(json_agg(json_build_object(
                'id', c.id, 'title', c.title, 'content', c.content,
                'status', c.status,
                'occurred_at', COALESCE(c.occurred_at, c.created_at, c.updated_at))
                ORDER BY COALESCE(c.occurred_at, c.created_at, c.updated_at) DESC), '[]'::json)
              FROM (SELECT * FROM chats cc WHERE cc.project_id = p.id
                    ORDER BY COALESCE(cc.occurred_at, cc.created_at, cc.updated_at) DESC
                    LIMIT 10) c) AS sessions,
           (SELECT COALESCE(json_agg(json_build_object(
                'id', j.id, 'kind', j.kind, 'state', j.state, 'title', j.title,
                'connector', j.connector, 'progress', j.progress,
                'updated_at', j.updated_at) ORDER BY j.updated_at DESC), '[]'::json)
              FROM jobs j WHERE j.project_id = p.id
                AND j.state IN ('queued', 'running')) AS open_jobs,
           (SELECT row_to_json(l) FROM v_left_off l WHERE l.project_id = p.id) AS left_off
    FROM projects p
    """,
]


def init_db() -> None:
    """Create the schema (idempotent). Also backfills project_paths from legacy columns."""
    os.makedirs(get_projects_dir(), exist_ok=True)
    vault = get_vault_dir()
    if vault:
        os.makedirs(vault, exist_ok=True)

    raw = psycopg.connect(database_url(), autocommit=True)
    try:
        with raw.cursor() as cur:
            for stmt in SCHEMA_STATEMENTS:
                cur.execute(stmt)
            cur.execute(EMBEDDINGS_TABLE_TEMPLATE.format(dim=_vector_dim()))
            for stmt in EMBEDDINGS_INDEXES:
                cur.execute(stmt)
            for stmt in VIEWS:
                cur.execute(stmt)
    finally:
        raw.close()

    with db_conn() as conn:
        cur = conn.cursor()
        _backfill_project_paths(cur)
        _backfill_occurred_at(cur)
        conn.commit()


def _backfill_project_paths(cur) -> None:
    """Mirror projects.path / compose_path into project_paths (aliases table)."""
    from datetime import datetime

    now = datetime.utcnow().isoformat()
    cur.execute("SELECT id, path, compose_path FROM projects")
    for row in cur.fetchall():
        for kind, value in (("workspace", row["path"]), ("compose", row["compose_path"])):
            value = (value or "").strip()
            if not value:
                continue
            cur.execute(
                """
                INSERT INTO project_paths (project_id, path, kind, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (project_id, path) DO NOTHING
                """,
                (row["id"], value, kind, now),
            )


def _backfill_occurred_at(cur) -> None:
    """Fill missing occurred_at from title timestamps / oldest message / created_at."""
    from .session_time import (
        earliest_message_time,
        infer_occurred_at,
        isoformat_utc,
        parse_title_timestamp,
    )

    cur.execute(
        """
        SELECT id, title, created_at, occurred_at
        FROM chats
        WHERE occurred_at IS NULL OR TRIM(occurred_at) = ''
        """
    )
    rows = cur.fetchall()
    for row in rows:
        chat_id, title, created_at = row["id"], row["title"], row["created_at"]
        cur.execute(
            "SELECT created_at FROM messages WHERE chat_id = ? ORDER BY id ASC LIMIT 40",
            (chat_id,),
        )
        msgs = [{"created_at": mr["created_at"]} for mr in cur.fetchall()]
        title_dt = parse_title_timestamp(title)
        msg_dt = earliest_message_time(msgs)
        created = (created_at or "").strip()
        if title_dt and msg_dt and isoformat_utc(msg_dt) == created:
            occurred = isoformat_utc(title_dt)
        else:
            occurred = infer_occurred_at(title=title, messages=msgs, created_at=created)
        if occurred:
            cur.execute(
                "UPDATE chats SET occurred_at = ? WHERE id = ?",
                (occurred, chat_id),
            )


def vector_available() -> bool:
    """True when the pgvector extension is installed in the target database."""
    try:
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
            return cur.fetchone() is not None
    except Exception:
        return False
