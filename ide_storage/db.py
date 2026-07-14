import os
import sqlite3
from contextlib import contextmanager
from pathlib import Path

MEMORY_TYPES = (
    "active_work",
    "constraint",
    "problem",
    "goal",
    "decision",
    "note",
    "caveat",
)


def get_db_path() -> str:
    return os.environ.get("IDE_STORAGE_DB_PATH", "/data/ide-work.db")


def db_file() -> Path:
    """Resolved SQLite path — always read env at call time (not import time)."""
    return Path(get_db_path())


def get_projects_dir() -> str:
    return os.environ.get("IDE_STORAGE_PROJECTS_DIR", "/data/projects")


def _add_column(cur, table: str, column: str, col_type: str) -> None:
    try:
        cur.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}")
    except sqlite3.OperationalError:
        pass


_vec_extension_loaded = False


def load_vec_extension(conn: sqlite3.Connection) -> bool:
    """Load sqlite-vec on this connection; return False if unavailable.

    Gated behind ``embeddings_enabled()`` so the lean / keyword-only image never
    needs sqlite-vec installed (the import is only attempted when embeddings are
    explicitly turned on).
    """
    from ide_storage.embeddings import embeddings_enabled

    if not embeddings_enabled():
        return False

    global _vec_extension_loaded
    if not _vec_extension_loaded:
        try:
            import sqlite_vec

            sqlite_vec.load(conn)
            _vec_extension_loaded = True
            return True
        except Exception:
            return False
    try:
        import sqlite_vec

        sqlite_vec.load(conn)
        return True
    except Exception:
        return False


def vec_extension_available() -> bool:
    try:
        conn = sqlite3.connect(":memory:")
        ok = load_vec_extension(conn)
        conn.close()
        return ok
    except Exception:
        return False


def init_db() -> None:
    path = get_db_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.makedirs(get_projects_dir(), exist_ok=True)

    with sqlite3.connect(path) as conn:
        cur = conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute("PRAGMA synchronous=NORMAL")
        cur.execute("PRAGMA foreign_keys=ON")

        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS chats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT,
                workspace_path TEXT,
                device_name TEXT,
                session_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                content TEXT NOT NULL,
                metadata TEXT
            )
            """
        )
        _add_column(cur, "chats", "project_id", "INTEGER")
        _add_column(cur, "chats", "status", "TEXT DEFAULT 'active'")
        _add_column(cur, "chats", "tags", "TEXT")
        # When the conversation actually happened (not when /save ran).
        _add_column(cur, "chats", "occurred_at", "TEXT")
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_chats_occurred ON chats(occurred_at)"
        )

        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                description TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                metadata TEXT
            )
            """
        )
        _add_column(cur, "projects", "slug", "TEXT")
        _add_column(cur, "projects", "status", "TEXT DEFAULT 'active'")
        _add_column(cur, "projects", "compose_path", "TEXT")
        _add_column(cur, "projects", "tags", "TEXT")

        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS snippets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT,
                language TEXT,
                content TEXT NOT NULL,
                project_id INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                tags TEXT,
                FOREIGN KEY (project_id) REFERENCES projects(id)
            )
            """
        )

        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TEXT NOT NULL,
                metadata TEXT,
                FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
            )
            """
        )

        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id INTEGER NOT NULL,
                type TEXT NOT NULL,
                content TEXT NOT NULL,
                source_chat_id INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
                FOREIGN KEY (source_chat_id) REFERENCES chats(id) ON DELETE SET NULL
            )
            """
        )

        cur.execute("CREATE INDEX IF NOT EXISTS idx_chats_workspace ON chats(workspace_path)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_chats_created ON chats(created_at)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_chats_session ON chats(session_id)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_chats_project ON chats(project_id)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_chats_status ON chats(status)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_projects_slug ON projects(slug)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_snippets_project ON snippets(project_id)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_memories_project ON memories(project_id)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type)")
        _add_column(cur, "memories", "status", "TEXT DEFAULT 'active'")
        _add_column(cur, "memories", "semantic_descriptor", "TEXT")

        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS embeddings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                ref_id INTEGER NOT NULL,
                model TEXT NOT NULL,
                dim INTEGER NOT NULL,
                text_hash TEXT NOT NULL,
                embed_text TEXT NOT NULL,
                vector BLOB NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(kind, ref_id, model)
            )
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_embeddings_kind ON embeddings(kind)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_embeddings_hash ON embeddings(text_hash)"
        )

        _backfill_occurred_at(cur)

        conn.commit()


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
        # init_db may not set row_factory — support both Row and tuple.
        if hasattr(row, "keys"):
            chat_id, title, created_at, occurred_at = (
                row["id"],
                row["title"],
                row["created_at"],
                row["occurred_at"],
            )
        else:
            chat_id, title, created_at, occurred_at = row
        cur.execute(
            "SELECT created_at FROM messages WHERE chat_id = ? ORDER BY id ASC LIMIT 40",
            (chat_id,),
        )
        msg_rows = cur.fetchall()
        msgs = []
        for mr in msg_rows:
            created = mr["created_at"] if hasattr(mr, "keys") else mr[0]
            msgs.append({"created_at": created})
        # Prefer title timestamp over uniform save-time message stamps when
        # every message shares the chat created_at (typical Path B save).
        title_dt = parse_title_timestamp(title)
        msg_dt = earliest_message_time(msgs)
        created = (created_at or "").strip()
        if title_dt and msg_dt and isoformat_utc(msg_dt) == created:
            occurred = isoformat_utc(title_dt)
        else:
            occurred = infer_occurred_at(
                title=title,
                messages=msgs,
                created_at=created,
            )
        if occurred:
            cur.execute(
                "UPDATE chats SET occurred_at = ? WHERE id = ?",
                (occurred, chat_id),
            )


@contextmanager
def db_conn():
    path = get_db_path()
    conn = sqlite3.connect(path, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA foreign_keys=ON")
    load_vec_extension(conn)
    try:
        yield conn
    finally:
        conn.close()
