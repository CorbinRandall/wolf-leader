"""Project owners: who a project belongs to on a hub several people share.

Owners are named in ``WOLF_OWNERS`` (comma separated, e.g. ``Alice,Bob``). Each
owner has a folder of the same name at the top of the share, so a project whose
path is ``<share>/Alice/...`` belongs to Alice without anyone saying so.

A project's owner is, in order:

1. ``metadata.owner`` when someone set it by hand (``owner_source: "set"``)
2. the owner folder one of its paths sits in (``owner_source: "folder"``)
3. nobody (``owner: None``)
"""
from __future__ import annotations

import json
import os
from typing import Any, Iterable

from ide_storage.db import db_conn
from ide_storage.paths import split_share


def configured_owners() -> list[str]:
    """Owner names from ``WOLF_OWNERS``, in the order given, without duplicates."""
    out: list[str] = []
    for raw in os.environ.get("WOLF_OWNERS", "").split(","):
        name = raw.strip()
        if name and name.lower() not in {o.lower() for o in out}:
            out.append(name)
    return out


def canonical_owner(name: str | None) -> str | None:
    """``name`` as spelled in ``WOLF_OWNERS``; None if it is not a known owner.

    With no owners configured any non-empty name is accepted as typed.
    """
    name = (name or "").strip()
    if not name:
        return None
    owners = configured_owners()
    if not owners:
        return name
    for owner in owners:
        if owner.lower() == name.lower():
            return owner
    return None


def owner_from_path(path: str | None) -> str | None:
    """Owner whose folder ``path`` sits in, or None."""
    owners = configured_owners()
    if not owners or not path:
        return None
    hit = split_share(path)
    if hit is None:
        return None
    first = hit[1].split("/", 1)[0].lower()
    for owner in owners:
        if owner.lower() == first:
            return owner
    return None


def _metadata(project: dict[str, Any]) -> dict[str, Any]:
    raw = project.get("metadata")
    if isinstance(raw, dict):
        return raw
    try:
        parsed = json.loads(raw) if raw else {}
    except (json.JSONDecodeError, TypeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def project_owner(project: dict[str, Any], paths: Iterable[str] = ()) -> dict[str, Any]:
    """``{"owner": ..., "owner_source": "set" | "folder" | None}`` for one project row."""
    explicit = _metadata(project).get("owner")
    if isinstance(explicit, str) and explicit.strip():
        return {"owner": canonical_owner(explicit) or explicit.strip(), "owner_source": "set"}
    for path in (project.get("path"), project.get("compose_path"), *paths):
        owner = owner_from_path(path)
        if owner:
            return {"owner": owner, "owner_source": "folder"}
    return {"owner": None, "owner_source": None}


def attach_owners(projects: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Add ``owner`` / ``owner_source`` to project rows (in place); returns them."""
    if not projects:
        return projects
    aliases: dict[int, list[str]] = {}
    ids = [int(p["id"]) for p in projects if p.get("id") is not None]
    if ids and configured_owners():
        placeholders = ",".join("?" * len(ids))
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute(
                f"SELECT project_id, path FROM project_paths WHERE project_id IN ({placeholders}) ORDER BY id",
                ids,
            )
            for row in cur.fetchall():
                aliases.setdefault(int(row["project_id"]), []).append(row["path"])
    for project in projects:
        project.update(project_owner(project, aliases.get(int(project["id"]), []) if project.get("id") is not None else []))
    return projects


def owner_summary() -> dict[str, Any]:
    """Configured owners plus how many projects each one has (``""`` = unassigned)."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, path, compose_path, metadata FROM projects")
        projects = attach_owners([dict(r) for r in cur.fetchall()])
    counts: dict[str, int] = {}
    for project in projects:
        key = project["owner"] or ""
        counts[key] = counts.get(key, 0) + 1
    owners = configured_owners()
    for name in sorted(k for k in counts if k and k not in owners):
        owners.append(name)
    return {"owners": owners, "configured": bool(configured_owners()), "counts": counts}


def set_owner(project_ids: Iterable[int], owner: str | None) -> int:
    """Write (or clear, with a blank ``owner``) ``metadata.owner``; returns rows changed.

    ``updated_at`` is left alone: labelling a project is not work on it.
    """
    name = (owner or "").strip()
    if name:
        resolved = canonical_owner(name)
        if resolved is None:
            raise ValueError(f"Unknown owner: {name}")
        name = resolved
    changed = 0
    with db_conn() as conn:
        cur = conn.cursor()
        for project_id in project_ids:
            cur.execute("SELECT metadata FROM projects WHERE id = ?", (project_id,))
            row = cur.fetchone()
            if not row:
                continue
            meta = _metadata(dict(row))
            if name:
                meta["owner"] = name
            else:
                meta.pop("owner", None)
            cur.execute(
                "UPDATE projects SET metadata = ? WHERE id = ?",
                (json.dumps(meta) if meta else None, project_id),
            )
            changed += 1
        conn.commit()
    return changed


def unassigned_project_ids() -> list[int]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, path, compose_path, metadata FROM projects")
        projects = attach_owners([dict(r) for r in cur.fetchall()])
    return [int(p["id"]) for p in projects if not p["owner"]]
