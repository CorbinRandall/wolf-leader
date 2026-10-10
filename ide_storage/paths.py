"""Path aliases for the one share that everything lives on.

The same folder is seen as:

* ``W:\\...``                     Windows clients (mapped drive)
* ``\\\\wolf.local\\wolf\\...``      Windows UNC (SMB)
* ``/srv/wolf/...``                the hub itself
* ``/volume1/<share>/...``         on a NAS, if the share lives there (optional)
* ``/Volumes/wolf/...``            macOS (SMB)

``to_hub_path`` maps any of those to the hub-local form so the hub can read the
file; ``variants`` produces every spelling so ``project_paths`` can be matched
from any machine. Configure with ``IDE_STORAGE_SHARE_*`` env vars.
"""
from __future__ import annotations

import os
import re
from datetime import datetime
from typing import Any, Iterable

from ide_storage.db import db_conn


def share_root() -> str:
    """The shared drive as the hub sees it (``/srv/wolf`` in the container)."""
    raw = os.environ.get("WOLF_SHARE_ROOT") or os.environ.get("IDE_STORAGE_SHARE_ROOT") or "/srv/wolf"
    raw = raw.strip().replace("\\", "/")
    while len(raw) > 1 and raw.endswith("/"):
        raw = raw[:-1]
    return raw or "/srv/wolf"


def _named_roots() -> dict[str, str]:
    # The hub machine hosts the drive and shares it (Samba); clients map it.
    return {
        "hub": share_root(),
        "windows": os.environ.get("IDE_STORAGE_SHARE_WINDOWS", "W:\\"),
        "unc": os.environ.get("IDE_STORAGE_SHARE_UNC", "\\\\wolf.local\\wolf"),
        "nas": os.environ.get("IDE_STORAGE_SHARE_NAS", ""),
        "mac": os.environ.get("IDE_STORAGE_SHARE_MAC", "/Volumes/wolf"),
    }


def _alias_roots() -> list[str]:
    """All root spellings of the share, hub form first."""
    named = _named_roots()
    roots = [named["hub"]]
    extra = os.environ.get("IDE_STORAGE_SHARE_EXTRA", "")
    for r in (named["windows"], named["unc"], named["nas"], named["mac"], *extra.split(";")):
        r = (r or "").strip()
        if r and r not in roots:
            roots.append(r)
    return roots


def _norm(p: str) -> str:
    """Slashes forward, no trailing slash, lower-case (Windows/SMB are case-insensitive)."""
    p = (p or "").strip().replace("\\", "/")
    while len(p) > 1 and p.endswith("/"):
        p = p[:-1]
    return p.lower()


def _root_norm(root: str) -> str:
    n = _norm(root)
    # "o:" from "O:\" — keep the drive letter form comparable with "o:/foo"
    return n


def split_share(path: str) -> tuple[str, str] | None:
    """Return (matched_root, relative_posix) if ``path`` is under any alias root."""
    n = _norm(path)
    for root in _alias_roots():
        rn = _root_norm(root)
        if n == rn:
            return root, ""
        prefix = rn if rn.endswith("/") else rn + "/"
        if n.startswith(prefix):
            rel = path.replace("\\", "/")[len(prefix):]
            # Preserve the caller's original casing for the relative part.
            return root, rel.strip("/")
    return None


def to_hub_path(path: str) -> str | None:
    """Any alias form -> hub-local absolute path, or None if not on the share."""
    hit = split_share(path)
    if hit is None:
        return None
    _, rel = hit
    return share_root() if not rel else f"{share_root()}/{rel}"


def is_on_share(path: str) -> bool:
    return split_share(path) is not None


def variants(path: str) -> list[str]:
    """All spellings of a share path (Windows, UNC, hub, NAS, mac). Non-share paths -> [path]."""
    hit = split_share(path)
    if hit is None:
        return [path]
    _, rel = hit
    out: list[str] = []
    for root in _alias_roots():
        if "\\" in root or re.match(r"^[A-Za-z]:", root):
            r = root.rstrip("\\/")
            out.append(r + ("\\" + rel.replace("/", "\\") if rel else "\\"))
        else:
            r = root.rstrip("/")
            out.append(f"{r}/{rel}" if rel else r)
    return out


def ancestors(path: str) -> list[str]:
    """path and each parent, normalized, longest first."""
    n = _norm(path)
    out = []
    while n:
        out.append(n)
        parent = n.rsplit("/", 1)[0] if "/" in n else ""
        if parent == n or not parent or parent.endswith(":"):
            if parent and parent != n:
                out.append(parent)
            break
        n = parent
    return out


def match_candidates(path: str) -> list[str]:
    """Normalized prefixes of ``path`` in every alias spelling, for a DB IN-match."""
    cands: set[str] = set()
    for v in variants(path):
        for a in ancestors(v):
            cands.add(a)
    return sorted(cands, key=len, reverse=True)


# --------------------------------------------------------------------- database
def register_project_path(
    project_id: int,
    path: str,
    *,
    kind: str = "workspace",
    device_name: str | None = None,
) -> dict[str, Any]:
    """Record ``path`` (and its hub spelling) as an alias for the project."""
    path = (path or "").strip()
    if not path:
        return {"added": 0}
    now = datetime.utcnow().isoformat()
    to_add = [path]
    hub = to_hub_path(path)
    if hub and hub != path:
        to_add.append(hub)
    added = 0
    with db_conn() as conn:
        cur = conn.cursor()
        for p in to_add:
            cur.execute(
                """
                INSERT INTO project_paths (project_id, path, kind, device_name, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (project_id, path) DO NOTHING
                """,
                (project_id, p, kind, device_name, now),
            )
            added += cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0
        conn.commit()
    return {"added": added, "paths": to_add, "hub_path": hub}


def resolve_project_id_by_path(path: str) -> int | None:
    """Longest-prefix match of ``path`` against project_paths, in SQL."""
    cands = match_candidates(path)
    if not cands:
        return None
    placeholders = ",".join("?" * len(cands))
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT pp.project_id, pp.path
            FROM project_paths pp
            JOIN projects p ON p.id = pp.project_id
            WHERE COALESCE(p.status, 'active') != 'archived'
              AND lower(replace(rtrim(pp.path, '/\\'), '\\', '/')) IN ({placeholders})
            ORDER BY length(pp.path) DESC
            LIMIT 1
            """,
            cands,
        )
        row = cur.fetchone()
    return int(row["project_id"]) if row else None


def project_paths(project_id: int) -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, path, kind, device_name, created_at FROM project_paths WHERE project_id = ? ORDER BY id",
            (project_id,),
        )
        return [dict(r) for r in cur.fetchall()]


def hub_roots_for_project(project_id: int) -> list[str]:
    """Distinct hub-local roots the hub can actually read for this project."""
    roots: list[str] = []
    for row in project_paths(project_id):
        hub = to_hub_path(row["path"])
        if hub and hub not in roots and os.path.isdir(hub):
            roots.append(hub)
    return roots


def describe_aliases(path: str | None = None) -> dict[str, Any]:
    """Root spellings of the share (windows/unc/hub/nas/mac); with ``path``, also that path everywhere."""
    out: dict[str, Any] = dict(_named_roots())
    out["share_roots"] = _alias_roots()
    if path:
        out.update(
            {
                "input": path,
                "on_share": is_on_share(path),
                "hub_path": to_hub_path(path),
                "variants": variants(path),
            }
        )
    return out
