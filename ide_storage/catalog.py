"""Filesystem catalog + file-body RAG for registered project roots on the share.

* ``refresh_catalog(project_id)`` — cheap, wide: one row per file under each
  registered root (path, name, ext, size, mtime, git status, one-line blurb),
  embedded so "where is X" is answered from Postgres, never by crawling the NAS
  at question time.
* ``ingest_files(project_id, paths)`` — deliberate, narrow: chunk + embed file
  bodies only for files a chat cited, a howl just committed, or you approved.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
from datetime import datetime
from typing import Any, Iterable

from ide_storage.db import db_conn
from ide_storage.paths import hub_roots_for_project, share_root, to_hub_path

SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", ".next", "dist", "build",
    ".cache", ".pytest_cache", ".mypy_ruff", ".idea", ".vscode", "target", ".turbo",
    "wolf-leader",  # our own pgdata/vault folder on the share
}
TEXT_EXT = {
    ".md", ".mdx", ".txt", ".py", ".js", ".ts", ".tsx", ".jsx", ".json", ".yml", ".yaml",
    ".toml", ".ini", ".cfg", ".env", ".sh", ".ps1", ".sql", ".css", ".html", ".xml",
    ".rs", ".go", ".java", ".kt", ".cs", ".c", ".h", ".cpp", ".hpp", ".rb", ".php",
    ".lua", ".ini", ".conf", ".dockerfile", ".csv",
}
TEXT_NAMES = {"dockerfile", "makefile", "readme", "license", "agents.md", ".gitignore"}
MAX_FILES_PER_ROOT = int(os.environ.get("WOLF_CATALOG_MAX_FILES", "6000"))
MAX_BLURB_BYTES = 600
MAX_INGEST_BYTES = 2 * 1024 * 1024
CHUNK_CHARS = 1400
CHUNK_OVERLAP = 200


def _is_text(name: str, ext: str) -> bool:
    return ext.lower() in TEXT_EXT or name.lower() in TEXT_NAMES or name.lower().endswith(".md")


def _blurb(path: str, name: str, ext: str) -> str:
    if not _is_text(name, ext):
        return f"{ext.lstrip('.') or 'file'} file"
    try:
        with open(path, "rb") as fh:
            head = fh.read(MAX_BLURB_BYTES)
    except OSError:
        return ""
    if b"\x00" in head:
        # UTF-16 or binary masquerading behind a text extension.
        return f"{ext.lstrip('.') or 'file'} file (binary or UTF-16)"
    text = head.decode("utf-8", errors="replace")
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    # First heading / docstring / non-comment line, then a little context.
    picked: list[str] = []
    for ln in lines:
        if ln.startswith(("#!", "//", "/*", "*", "<!--")):
            continue
        picked.append(ln.lstrip("#").strip())
        if len(" ".join(picked)) > 200:
            break
    return " ".join(picked)[:240]


def _git_status(root: str) -> dict[str, str]:
    """rel_path -> porcelain status for a git root; {} if not a repo."""
    if not os.path.isdir(os.path.join(root, ".git")):
        return {}
    try:
        out = subprocess.run(
            ["git", "-C", root, "status", "--porcelain", "--untracked-files=all"],
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        return {}
    status: dict[str, str] = {}
    for line in out.stdout.splitlines():
        if len(line) < 4:
            continue
        code, rel = line[:2].strip() or "M", line[3:].strip().strip('"')
        status[rel.replace("\\", "/")] = code
    return status


def git_head(root: str) -> dict[str, Any]:
    """Commit/branch/remote for a repo root the hub can read; {} otherwise."""
    if not os.path.isdir(os.path.join(root, ".git")):
        return {}
    info: dict[str, Any] = {"is_repo": True, "root": root}
    for key, args in (
        ("commit", ["rev-parse", "HEAD"]),
        ("branch", ["rev-parse", "--abbrev-ref", "HEAD"]),
        ("remote", ["remote", "get-url", "origin"]),
    ):
        try:
            r = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=15)
            info[key] = r.stdout.strip() if r.returncode == 0 else None
        except Exception:
            info[key] = None
    try:
        r = subprocess.run(["git", "-C", root, "status", "--porcelain"], capture_output=True, text=True, timeout=30)
        info["dirty_files"] = len([ln for ln in r.stdout.splitlines() if ln.strip()])
    except Exception:
        info["dirty_files"] = None
    return info


def refresh_catalog(project_id: int, *, roots: Iterable[str] | None = None) -> dict[str, Any]:
    """Walk each root, upsert fs_catalog rows, prune vanished ones, embed changes."""
    roots = list(roots) if roots is not None else hub_roots_for_project(project_id)
    roots = [r for r in roots if r and os.path.isdir(r)]
    now = datetime.utcnow().isoformat()
    report: dict[str, Any] = {"project_id": project_id, "roots": roots, "files": 0, "changed": 0, "removed": 0}
    if not roots:
        report["note"] = "no readable roots registered on the share for this project"
        return report

    changed_ids: list[int] = []
    with db_conn() as conn:
        cur = conn.cursor()
        for root in roots:
            git_map = _git_status(root)
            seen: set[str] = set()
            count = 0
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
                for fn in filenames:
                    if count >= MAX_FILES_PER_ROOT:
                        break
                    full = os.path.join(dirpath, fn)
                    rel = os.path.relpath(full, root).replace("\\", "/")
                    try:
                        st = os.stat(full)
                    except OSError:
                        continue
                    ext = os.path.splitext(fn)[1]
                    mtime = datetime.utcfromtimestamp(st.st_mtime).isoformat()
                    seen.add(rel)
                    count += 1
                    cur.execute(
                        "SELECT id, mtime, size FROM fs_catalog WHERE project_id = ? AND root_path = ? AND rel_path = ?",
                        (project_id, root, rel),
                    )
                    row = cur.fetchone()
                    gs = git_map.get(rel)
                    if row and row["mtime"] == mtime and row["size"] == st.st_size:
                        if gs is not None:
                            cur.execute("UPDATE fs_catalog SET git_status = ? WHERE id = ?", (gs, row["id"]))
                        continue
                    blurb = _blurb(full, fn, ext)
                    if row:
                        cur.execute(
                            """
                            UPDATE fs_catalog SET name = ?, ext = ?, size = ?, mtime = ?, git_status = ?,
                                   blurb = ?, updated_at = ? WHERE id = ?
                            """,
                            (fn, ext, st.st_size, mtime, gs, blurb, now, row["id"]),
                        )
                        changed_ids.append(int(row["id"]))
                    else:
                        cur.execute(
                            """
                            INSERT INTO fs_catalog (project_id, root_path, rel_path, name, ext, is_dir, size,
                                                    mtime, git_status, blurb, updated_at)
                            VALUES (?, ?, ?, ?, ?, FALSE, ?, ?, ?, ?, ?)
                            """,
                            (project_id, root, rel, fn, ext, st.st_size, mtime, gs, blurb, now),
                        )
                        if cur.lastrowid:
                            changed_ids.append(int(cur.lastrowid))
            report["files"] += count
            # prune rows for files that vanished under this root
            cur.execute("SELECT id, rel_path FROM fs_catalog WHERE project_id = ? AND root_path = ?", (project_id, root))
            gone = [int(r["id"]) for r in cur.fetchall() if r["rel_path"] not in seen]
            for gid in gone:
                cur.execute("DELETE FROM fs_catalog WHERE id = ?", (gid,))
            report["removed"] += len(gone)
        conn.commit()

    report["changed"] = len(changed_ids)
    if changed_ids:
        from ide_storage.embed_index import sync_dirty

        report["embeddings"] = sync_dirty(catalog_ids=changed_ids)
    return report


def catalog_search(project_id: int | None, query: str, *, limit: int = 20) -> list[dict[str, Any]]:
    """Keyword lookup in the catalog (vector leg lives in search_ops via kind='catalog')."""
    pattern = f"%{query}%"
    with db_conn() as conn:
        cur = conn.cursor()
        sql = """
            SELECT id, project_id, root_path, rel_path, name, ext, size, mtime, git_status, blurb
            FROM fs_catalog WHERE is_dir = FALSE AND (rel_path LIKE ? OR COALESCE(blurb,'') LIKE ?)
        """
        params: list[Any] = [pattern, pattern]
        if project_id is not None:
            sql += " AND project_id = ?"
            params.append(project_id)
        sql += " ORDER BY mtime DESC NULLS LAST LIMIT ?"
        params.append(limit)
        cur.execute(sql, params)
        rows = [dict(r) for r in cur.fetchall()]
    for r in rows:
        r["path"] = f"{r['root_path'].rstrip('/')}/{r['rel_path']}"
    return rows


# ------------------------------------------------------------------ file bodies
def _chunks(text: str) -> list[str]:
    text = text.replace("\r\n", "\n")
    if len(text) <= CHUNK_CHARS:
        return [text] if text.strip() else []
    out: list[str] = []
    paras = re.split(r"\n{2,}", text)
    buf = ""
    for para in paras:
        if len(buf) + len(para) + 2 <= CHUNK_CHARS:
            buf = f"{buf}\n\n{para}" if buf else para
            continue
        if buf:
            out.append(buf)
            tail = buf[-CHUNK_OVERLAP:]
            buf = f"{tail}\n\n{para}" if len(para) < CHUNK_CHARS else ""
        while len(para) > CHUNK_CHARS:
            out.append(para[:CHUNK_CHARS])
            para = para[CHUNK_CHARS - CHUNK_OVERLAP:]
        if para and not buf:
            buf = para
    if buf.strip():
        out.append(buf)
    return out


def ingest_files(
    project_id: int,
    paths: Iterable[str],
    *,
    reason: str = "cited",
    howl_id: int | None = None,
) -> dict[str, Any]:
    """Chunk + embed the bodies of the given files (any alias spelling). Narrow by design."""
    now = datetime.utcnow().isoformat()
    report: dict[str, Any] = {"project_id": project_id, "ingested": [], "skipped": [], "chunks": 0}
    chunk_ids: list[int] = []
    with db_conn() as conn:
        cur = conn.cursor()
        for raw in paths:
            hub = to_hub_path(raw) or (raw if raw.startswith(share_root()) else None)
            if not hub or not os.path.isfile(hub):
                report["skipped"].append({"path": raw, "reason": "not a readable file on the share"})
                continue
            name = os.path.basename(hub)
            ext = os.path.splitext(name)[1]
            if not _is_text(name, ext):
                report["skipped"].append({"path": raw, "reason": "binary/unsupported type"})
                continue
            try:
                if os.path.getsize(hub) > MAX_INGEST_BYTES:
                    report["skipped"].append({"path": raw, "reason": "larger than 2MB"})
                    continue
                with open(hub, "rb") as fh:
                    raw_bytes = fh.read()
                if raw_bytes.startswith((b"\xff\xfe", b"\xfe\xff")):
                    text = raw_bytes.decode("utf-16", errors="replace")
                else:
                    text = raw_bytes.decode("utf-8", errors="replace").replace("\x00", "")
            except OSError as exc:
                report["skipped"].append({"path": raw, "reason": str(exc)})
                continue
            cur.execute("SELECT id FROM fs_catalog WHERE project_id = ? AND (root_path || '/' || rel_path) = ?", (project_id, hub))
            cat = cur.fetchone()
            cat_id = int(cat["id"]) if cat else None
            cur.execute("SELECT id FROM file_chunks WHERE project_id = ? AND path = ?", (project_id, hub))
            old_ids = [int(r["id"]) for r in cur.fetchall()]
            cur.execute("DELETE FROM file_chunks WHERE project_id = ? AND path = ?", (project_id, hub))
            pieces = _chunks(text)
            for idx, piece in enumerate(pieces):
                h = hashlib.sha256(piece.encode("utf-8")).hexdigest()
                cur.execute(
                    """
                    INSERT INTO file_chunks (project_id, fs_catalog_id, howl_id, path, chunk_index,
                                             content, content_hash, reason, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (project_id, cat_id, howl_id, hub, idx, piece, h, reason, now),
                )
                if cur.lastrowid:
                    chunk_ids.append(int(cur.lastrowid))
            report["ingested"].append({"path": hub, "chunks": len(pieces)})
            report["chunks"] += len(pieces)
            if old_ids:
                from ide_storage.embed_index import delete_embeddings

                delete_embeddings([("chunk", i) for i in old_ids])
        conn.commit()
    if chunk_ids:
        from ide_storage.embed_index import sync_dirty

        report["embeddings"] = sync_dirty(chunk_ids=chunk_ids)
    return report


PATH_RE = re.compile(
    r"(?:(?:[A-Za-z]:[\\/]|\\\\[\w.-]+\\|/mnt/o/|/volume1/|/Volumes/)[^\s'\"`<>|)\]]+)"
)


def cited_paths(texts: Iterable[str], *, project_roots: Iterable[str] = ()) -> list[str]:
    """File paths mentioned in text that resolve to real files on the share.

    Absolute share paths are taken as-is; bare relative paths are tried against
    each project root.
    """
    found: list[str] = []
    roots = [r for r in project_roots if r]
    for text in texts:
        if not text:
            continue
        for m in PATH_RE.findall(text):
            cand = m.rstrip(".,;:")
            hub = to_hub_path(cand)
            if hub and os.path.isfile(hub) and hub not in found:
                found.append(hub)
        if roots:
            for rel in re.findall(r"`([\w./\\-]+\.[A-Za-z0-9]{1,6})`", text):
                for root in roots:
                    p = os.path.join(root, rel.replace("\\", "/"))
                    if os.path.isfile(p) and p not in found:
                        found.append(p)
    return found[:40]
