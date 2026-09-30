"""Conservative duplicate-project detection and lossless database merging."""

from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any, Iterable

from .db import db_conn


def normalize_project_identity(value: str | None) -> str:
    """Normalize punctuation/case only; do not fuzzy-match different words."""
    return re.sub(r"[^a-z0-9]+", "", (value or "").lower())


def _json_dict(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except (TypeError, json.JSONDecodeError):
        return {}


def _json_list(raw: Any) -> list[Any]:
    if isinstance(raw, list):
        return raw
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, list) else []
    except (TypeError, json.JSONDecodeError):
        return []


def find_duplicate_groups(projects: Iterable[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """Return connected groups sharing an exact normalized name or slug."""
    rows = [dict(project) for project in projects]
    if len(rows) < 2:
        return []

    parent = list(range(len(rows)))

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left: int, right: int) -> None:
        left_root, right_root = find(left), find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    seen: dict[str, int] = {}
    for index, project in enumerate(rows):
        keys = {
            normalize_project_identity(project.get("name")),
            normalize_project_identity(project.get("slug")),
        }
        for key in {key for key in keys if len(key) >= 3}:
            if key in seen:
                union(index, seen[key])
            else:
                seen[key] = index

    groups: dict[int, list[dict[str, Any]]] = {}
    for index, project in enumerate(rows):
        groups.setdefault(find(index), []).append(project)
    duplicates = [group for group in groups.values() if len(group) > 1]
    return sorted(duplicates, key=lambda group: (-len(group), group[0].get("name", "").lower()))


def list_duplicate_projects() -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.*,
                   (SELECT COUNT(*) FROM chats c WHERE c.project_id = p.id) AS chat_count,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memory_count,
                   (SELECT COUNT(*) FROM snippets s WHERE s.project_id = p.id) AS snippet_count
            FROM projects p
            ORDER BY p.updated_at DESC, p.id DESC
            """
        )
        rows = [dict(row) for row in cur.fetchall()]
    groups = find_duplicate_groups(rows)
    return [
        {
            "key": normalize_project_identity(group[0].get("name") or group[0].get("slug")),
            "projects": group,
            "count": len(group),
        }
        for group in groups
    ]


def merge_projects(target_id: int, source_ids: list[int]) -> dict[str, Any]:
    """Move all linked rows into target and remove duplicate project records."""
    source_ids = list(dict.fromkeys(int(project_id) for project_id in source_ids))
    if not source_ids:
        raise ValueError("Choose at least one duplicate project to merge")
    if target_id in source_ids:
        raise ValueError("The project to keep cannot also be a duplicate source")

    requested_ids = [int(target_id), *source_ids]
    placeholders = ",".join("?" for _ in requested_ids)

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(f"SELECT * FROM projects WHERE id IN ({placeholders})", requested_ids)
        projects = {int(row["id"]): dict(row) for row in cur.fetchall()}
        missing = [project_id for project_id in requested_ids if project_id not in projects]
        if missing:
            raise LookupError(f"Project not found: {missing[0]}")

        duplicate_groups = find_duplicate_groups(projects.values())
        if not any({int(project["id"]) for project in group} == set(requested_ids) for group in duplicate_groups):
            raise ValueError("The selected projects are not duplicates")

        target = projects[int(target_id)]
        sources = [projects[project_id] for project_id in source_ids]

        merged_metadata: dict[str, Any] = {}
        merged_tags: list[Any] = []
        for project in [*sources, target]:
            merged_metadata.update(_json_dict(project.get("metadata")))
            for tag in _json_list(project.get("tags")):
                if tag not in merged_tags:
                    merged_tags.append(tag)
        merged_from = list(merged_metadata.get("merged_from_projects") or [])
        for source in sources:
            marker = {"id": source["id"], "name": source["name"], "slug": source.get("slug")}
            if marker not in merged_from:
                merged_from.append(marker)
        merged_metadata["merged_from_projects"] = merged_from

        def preferred(field: str) -> Any:
            return target.get(field) or next((source.get(field) for source in sources if source.get(field)), None)

        descriptions = [
            str(project.get("description") or "").strip()
            for project in [target, *sources]
            if project.get("description")
        ]
        best_description = max(descriptions, key=len) if descriptions else None

        cur.execute(
            """
            UPDATE projects
            SET description = ?, compose_path = ?, path = ?, tags = ?, metadata = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                best_description,
                preferred("compose_path"),
                preferred("path"),
                json.dumps(merged_tags) if merged_tags else None,
                json.dumps(merged_metadata),
                datetime.utcnow().isoformat(),
                target_id,
            ),
        )

        moved = {"chats": 0, "memories": 0, "snippets": 0}
        for table, label in (("chats", "chats"), ("memories", "memories"), ("snippets", "snippets")):
            source_placeholders = ",".join("?" for _ in source_ids)
            cur.execute(
                f"UPDATE {table} SET project_id = ? WHERE project_id IN ({source_placeholders})",
                [target_id, *source_ids],
            )
            moved[label] = cur.rowcount

        source_placeholders = ",".join("?" for _ in source_ids)
        cur.execute(f"DELETE FROM projects WHERE id IN ({source_placeholders})", source_ids)
        removed_count = cur.rowcount
        conn.commit()

    return {
        "target_id": target_id,
        "target_name": target["name"],
        "removed_ids": source_ids,
        "removed_count": removed_count,
        "moved": moved,
    }
