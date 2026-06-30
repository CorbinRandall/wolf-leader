"""Match Cursor sessions to hub projects using full transcript + paths."""
from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path
from typing import Any

from ide_storage.hub import normalize_path, resolve_project
from ide_storage.db import db_file
from ide_storage.import_all_transcripts import (
    CATCH_ALL_PROJECT_ID,
    _explicit_project_id,
    _strip_hub_paste,
)

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

TOKEN_STOPWORDS = {
    "compose",
    "docker",
    "server",
    "stack",
    "unraid",
    "active",
    "centralized",
    "project",
    "hub",
    "sleep",
    "file",
    "port",
    "config",
    "plugin",
    "manager",
    "storage",
    "cursor",
    "agent",
    "chat",
    "save",
    "brief",
}

STRONG_PHRASES: list[tuple[str, str, int]] = [
    ("docker-dashboard", r"docker[- ]?dashboard|docker apps website|container links?\s+page", 40),
    ("custom-server-url", r"custom server url|npm.*caddy|reverse proxy", 35),
    ("wolf-leader", r"wolf[- ]?leader|ide[- ]?storage|ide work storage|\b6971\b", 35),
    ("s3-sleep", r"\bs3[- ]?sleep\b|dynamix\.s3\.sleep", 35),
    ("metube", r"\bmetube\b|youtube downloader", 30),
    ("hermes", r"\bhermes\b|telegram bot", 30),
    ("nextcloud", r"\bnextcloud\b", 30),
    ("immich", r"\bimmich\b", 30),
    ("google-sso", r"google sso|\bsaml\b", 30),
]

MIN_SCORE_DEFAULT = 45
MIN_LEAD_DEFAULT = 12
# The winner must also lead by a meaningful fraction of its own score, not just
# an absolute margin. Repeated mentions inflate scores and amplify small,
# arbitrary per-phrase point differences (e.g. a 5pt STRONG_PHRASES gap becomes
# 20pt at 4x hits); without a relative guard, two projects mentioned equally
# would still auto-pick one instead of reading as ambiguous.
MIN_LEAD_RATIO_DEFAULT = 0.15


def transcript_text(path: Path, *, max_chars: int = 80_000) -> str:
    """Concatenate user + assistant text from a Cursor JSONL transcript."""
    from ide_storage.import_transcript import extract_text

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


def conversation_text(
    messages: list[dict[str, str]] | None = None,
    *,
    text: str | None = None,
) -> str:
    if text and text.strip():
        return text.strip()
    if not messages:
        return ""
    return "\n".join(
        (m.get("content") or "").strip()
        for m in messages
        if (m.get("content") or "").strip()
    )


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


def _phrase_hits(pattern: str, text: str, *, flags: int = re.I) -> int:
    try:
        return len(re.findall(pattern, text, flags))
    except re.error:
        return 0


def _slug_patterns(slug: str) -> list[tuple[str, int]]:
    """Patterns for a project slug — never score bare short tokens like 'sleep'."""
    slug = slug.strip().lower()
    if not slug:
        return []
    patterns: list[tuple[str, int]] = [
        (rf"\b{re.escape(slug)}\b", 35),
        (rf"\b{re.escape(slug.replace('-', ' '))}\b", 30),
        (rf"\b{re.escape(slug.replace('-', '_'))}\b", 28),
    ]
    parts = [p for p in re.split(r"[-_]+", slug) if len(p) >= 4 and p not in TOKEN_STOPWORDS]
    if len(parts) >= 2:
        patterns.append((rf"\b{'[- ]+'.join(re.escape(p) for p in parts)}\b", 25))
    return patterns


def _name_pattern(name: str) -> str | None:
    name = re.sub(r"\s+", " ", name.strip())
    if len(name) < 5:
        return None
    return rf"\b{re.escape(name)}\b"


def _description_terms(description: str) -> list[str]:
    terms: list[str] = []
    for token in re.split(r"\W+", description or ""):
        token = token.lower()
        if len(token) >= 5 and token not in TOKEN_STOPWORDS:
            terms.append(token)
    return sorted(set(terms))


def score_project_matches(
    text: str,
    *,
    db_path: Path | None = None,
    workspace_path: str | None = None,
) -> list[dict[str, Any]]:
    """Return project match candidates sorted by score (highest first)."""
    text = _strip_hub_paste(text or "")
    if not text.strip():
        return []

    db = db_path or db_file()
    scores: dict[int, dict[str, Any]] = {}

    def add(pid: int, points: int, reason: str) -> None:
        if points <= 0:
            return
        if pid == CATCH_ALL_PROJECT_ID and points < 50:
            return
        bucket = scores.setdefault(
            pid,
            {"project_id": pid, "score": 0, "reasons": []},
        )
        bucket["score"] += points
        bucket["reasons"].append(reason)

    rows = _slug_rows(db)
    slug_to_id = {r["slug"]: r["id"] for r in rows if r.get("slug")}

    explicit = _explicit_project_id(text, db)
    if explicit is not None:
        add(explicit, 120, "pasted hub project context")

    for slug in set(COMPOSE_SLUG_RE.findall(text)):
        pid = slug_to_id.get(slug.lower())
        if pid:
            add(pid, 100, f"compose path mentions {slug}")

    for slug in set(EXPLICIT_SLUG_RE.findall(text)):
        pid = slug_to_id.get(slug.lower())
        if pid:
            add(pid, 85, f"explicit slug {slug}")

    if workspace_path and normalize_path(workspace_path) not in GENERIC_WORKSPACES:
        project = resolve_project(path=workspace_path)
        if project:
            add(project["id"], 90, f"workspace path {workspace_path}")

    for slug, pattern, pts in STRONG_PHRASES:
        hits = _phrase_hits(pattern, text)
        pid = slug_to_id.get(slug)
        if pid and hits:
            add(pid, pts * min(hits, 4), f"topic phrase ({slug}) x{hits}")

    user_chunks = [c for c in re.split(r"\n+", text) if c.strip()]
    tail = "\n".join(user_chunks[-8:]) if user_chunks else ""

    for row in rows:
        pid = row["id"]
        slug = (row.get("slug") or "").lower()
        name = row.get("name") or ""
        description = row.get("description") or ""

        for pattern, base_pts in _slug_patterns(slug):
            hits = _phrase_hits(pattern, text)
            if hits:
                add(pid, base_pts * min(hits, 3), f"slug '{slug}' x{hits}")
            if tail:
                tail_hits = _phrase_hits(pattern, tail)
                if tail_hits:
                    add(pid, (base_pts // 2) * min(tail_hits, 2), f"recent slug '{slug}' x{tail_hits}")

        name_pat = _name_pattern(name)
        if name_pat:
            hits = _phrase_hits(name_pat, text)
            if hits:
                add(pid, 22 * min(hits, 3), f"name '{name}' x{hits}")

        for term in _description_terms(description):
            hits = _phrase_hits(rf"\b{re.escape(term)}\b", text)
            if hits:
                add(pid, 8 * min(hits, 2), f"description term '{term}' x{hits}")

    # Bounded semantic tie-breaker — keyword/path/slug stay authoritative.
    try:
        from ide_storage.embeddings import embeddings_available
        from ide_storage.embed_index import project_vector_similarities

        if embeddings_available():
            sims = project_vector_similarities(text)
            for pid, sim in sims.items():
                if sim < 0.38:
                    continue
                existing = scores.get(pid, {}).get("score", 0)
                if existing >= 80:
                    continue
                pts = int(min(25, max(0.0, (sim - 0.35) * 40)))
                if pts > 0:
                    add(pid, pts, f"semantic similarity {sim:.2f}")
    except Exception:
        pass

    ranked = sorted(scores.values(), key=lambda x: x["score"], reverse=True)
    for item in ranked:
        row = next((r for r in rows if r["id"] == item["project_id"]), None)
        if row:
            item["slug"] = row.get("slug")
            item["name"] = row.get("name")
        score = item["score"]
        item["confidence"] = (
            "high" if score >= 80 else "medium" if score >= 50 else "low"
        )
    return ranked


def best_project_match(
    text: str,
    *,
    db_path: Path | None = None,
    workspace_path: str | None = None,
    min_score: int = MIN_SCORE_DEFAULT,
    min_lead: int = MIN_LEAD_DEFAULT,
    min_lead_ratio: float = MIN_LEAD_RATIO_DEFAULT,
) -> dict[str, Any] | None:
    matches = score_project_matches(text, db_path=db_path, workspace_path=workspace_path)
    if not matches:
        return None
    top = matches[0]
    if top["score"] < min_score:
        return None
    if len(matches) > 1:
        second = matches[1]["score"]
        lead = top["score"] - second
        if lead < min_lead:
            return None
        # Relative guard: a small lead on a large score (two projects mentioned
        # roughly equally) is ambiguous, not a confident win.
        if lead < top["score"] * min_lead_ratio:
            return None
        if top["score"] == second:
            return None
    return top


def match_projects_payload(
    *,
    messages: list[dict[str, str]] | None = None,
    text: str | None = None,
    workspace_path: str | None = None,
    db_path: Path | None = None,
    min_score: int = MIN_SCORE_DEFAULT,
    min_lead: int = MIN_LEAD_DEFAULT,
    limit: int = 5,
) -> dict[str, Any]:
    """API-friendly ranked match result."""
    body = conversation_text(messages, text=text)
    db = db_path or db_file()
    matches = score_project_matches(body, db_path=db, workspace_path=workspace_path)
    best = best_project_match(
        body,
        db_path=db,
        workspace_path=workspace_path,
        min_score=min_score,
        min_lead=min_lead,
    )
    return {
        "text_chars": len(body),
        "matches": matches[:limit],
        "best": best,
        "recommend_slug": best.get("slug") if best else None,
        "ambiguous": bool(matches and not best and matches[0]["score"] >= min_score // 2),
    }


def guess_project_from_transcript(
    path: Path,
    *,
    db_path: Path | None = None,
    workspace_path: str | None = None,
) -> dict[str, Any]:
    """Infer project from a transcript file path."""
    text = transcript_text(path)
    match = best_project_match(text, db_path=db_path, workspace_path=workspace_path)
    session_id = path.parent.name if path.name.endswith(".jsonl") else path.stem
    if not match:
        ranked = score_project_matches(text, db_path=db_path, workspace_path=workspace_path)
        return {
            "session_id": session_id,
            "matched": False,
            "reason": "no confident project match",
            "candidates": ranked[:3],
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
