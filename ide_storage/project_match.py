"""Match Cursor sessions to hub projects using full transcript + paths."""
from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path
from typing import Any

from ide_storage.hub import normalize_path, resolve_project
from ide_storage.import_all_transcripts import (
    CATCH_ALL_PROJECT_ID,
    DB_PATH,
    guess_project_id,
)
from ide_storage.import_transcript import extract_text

COMPOSE_SLUG_RE = re.compile(
    r"/boot/config/plugins/compose\.manager/projects/([a-z0-9][a-z0-9-]*)",
    re.I,
)
EXPLICIT_SLUG_RE = re.compile(
    r"(?:project\s+slug|slug|set_project)\s*[:(]\s*[\"']?([a-z0-9][a-z0-9-]*)",
    re.I,
)
PLUGIN_SLUG_RE = re.compile(r"/boot/config/plugins/([a-z0-9][a-z0-9.-]*)", re.I)

GENERIC_WORKSPACES = {"/", "/root", "/home"}

STRONG_PHRASES: list[tuple[str, str, int]] = [
    ("docker-dashboard", r"docker[- ]?dashboard|docker apps website|container links?\s+page", 40),
    ("custom-server-url", r"custom server url|npm.*caddy|reverse proxy", 35),
    ("wolf-leader", r"wolf[- ]?leader|ide[- ]?storage|ide work storage|\b6971\b", 35),
    ("s3-sleep", r"s3[- ]?sleep|dynamix\.s3\.sleep", 35),
    ("metube", r"\bmetube\b|youtube downloader", 30),
    ("hermes", r"\bhermes\b|telegram bot", 30),
    ("nextcloud", r"\bnextcloud\b", 30),
    ("immich", r"\bimmich\b", 30),
    ("google-sso", r"google sso|\bsaml\b", 30),
]


def transcript_text(path: Path, *, max_chars: int = 80_000) -> str:
    """Concatenate user + assistant text from a Cursor JSONL transcript."""
    parts: list[str] = []
    total = 0
    if not path.is_file():
        return ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = entry.get("role")
        if role not in ("user", "assistant"):
            continue
        text = extract_text(entry)
        if not text:
            continue
        chunk = text.strip()
        parts.append(chunk)
        total += len(chunk)
        if total >= max_chars:
            break
    return "\n".join(parts)


def _slug_rows(db_path: Path) -> list[dict[str, Any]]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, slug, name, compose_path, path, description
        FROM projects WHERE COALESCE(status, 'active') != 'archived'
        """
    )
    rows = [dict(r) for r in cur.fetchall()]
    conn.close()
    return rows


def score_project_matches(
    text: str,
    *,
    db_path: Path = DB_PATH,
    workspace_path: str | None = None,
) -> list[dict[str, Any]]:
    """Return project match candidates sorted by score (highest first)."""
    if not text.strip():
        return []

    scores: dict[int, dict[str, Any]] = {}

    def add(pid: int, points: int, reason: str) -> None:
        if pid == CATCH_ALL_PROJECT_ID and points < 50:
            return
        bucket = scores.setdefault(
            pid,
            {"project_id": pid, "score": 0, "reasons": []},
        )
        bucket["score"] += points
        bucket["reasons"].append(reason)

    rows = _slug_rows(db_path)
    slug_to_id = {r["slug"]: r["id"] for r in rows if r.get("slug")}

    for slug in set(COMPOSE_SLUG_RE.findall(text)):
        pid = slug_to_id.get(slug.lower())
        if pid:
            add(pid, 100, f"compose path mentions {slug}")

    for slug in set(EXPLICIT_SLUG_RE.findall(text)):
        pid = slug_to_id.get(slug.lower())
        if pid:
            add(pid, 85, f"explicit slug {slug}")

    for slug, pattern, pts in STRONG_PHRASES:
        if re.search(pattern, text, re.I):
            pid = slug_to_id.get(slug)
            if pid:
                add(pid, pts, f"topic phrase ({slug})")

    if workspace_path and normalize_path(workspace_path) not in GENERIC_WORKSPACES:
        project = resolve_project(path=workspace_path)
        if project:
            add(project["id"], 90, f"workspace path {workspace_path}")

    guessed = guess_project_id(text, db_path=db_path)
    if guessed:
        add(guessed, 60, "keyword rules on full transcript")

    # Recency: last user messages often name the real topic
    user_chunks = re.split(r"\n+", text)
    tail = "\n".join(user_chunks[-8:])
    tail_guess = guess_project_id(tail, db_path=db_path)
    if tail_guess:
        add(tail_guess, 25, "keyword rules on recent messages")

    ranked = sorted(scores.values(), key=lambda x: x["score"], reverse=True)
    for item in ranked:
        row = next((r for r in rows if r["id"] == item["project_id"]), None)
        if row:
            item["slug"] = row.get("slug")
            item["name"] = row.get("name")
        item["confidence"] = (
            "high" if item["score"] >= 80 else "medium" if item["score"] >= 50 else "low"
        )
    return ranked


def best_project_match(
    text: str,
    *,
    db_path: Path = DB_PATH,
    workspace_path: str | None = None,
    min_score: int = 50,
) -> dict[str, Any] | None:
    matches = score_project_matches(text, db_path=db_path, workspace_path=workspace_path)
    if not matches:
        return None
    top = matches[0]
    if top["score"] < min_score:
        return None
    if len(matches) > 1 and matches[1]["score"] == top["score"]:
        return None
    return top


def guess_project_from_transcript(
    path: Path,
    *,
    db_path: Path = DB_PATH,
    workspace_path: str | None = None,
) -> dict[str, Any]:
    """Infer project from a transcript file path."""
    text = transcript_text(path)
    match = best_project_match(text, db_path=db_path, workspace_path=workspace_path)
    session_id = path.parent.name if path.name.endswith(".jsonl") else path.stem
    if not match:
        return {
            "session_id": session_id,
            "matched": False,
            "reason": "no confident project match",
            "text_chars": len(text),
        }
    return {
        "session_id": session_id,
        "matched": True,
        "project_id": match["project_id"],
        "slug": match.get("slug"),
        "name": match.get("name"),
        "score": match["score"],
        "confidence": match["confidence"],
        "reasons": match["reasons"],
        "text_chars": len(text),
    }
