#!/usr/bin/env python3
"""Memory automation: dedup, auto-extract from chats, distill on change."""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from datetime import datetime
from typing import Any, Optional

from ide_storage.db import MEMORY_TYPES, db_conn
from ide_storage.markdown_sync import regenerate_index

# --- Normalization / dedup ---

_WORD_RE = re.compile(r"[a-z0-9]+")


def normalize_text(text: str) -> str:
    return " ".join(_WORD_RE.findall(text.lower()))


def similarity(a: str, b: str) -> float:
    wa = set(normalize_text(a).split())
    wb = set(normalize_text(b).split())
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / len(wa | wb)


def is_duplicate(content: str, existing: list[dict], threshold: float = 0.82) -> Optional[dict]:
    norm = normalize_text(content)
    if len(norm) < 12:
        return None
    for mem in existing:
        if (mem.get("status") or "active") == "superseded":
            continue
        ex = mem.get("content") or ""
        if not ex:
            continue
        if norm in normalize_text(ex) or normalize_text(ex) in norm:
            return mem
        if similarity(content, ex) >= threshold:
            return mem
    return None


_SUPERSEDE_TYPES = frozenset({"decision", "constraint", "goal", "problem", "active_work", "caveat", "note"})
_CONTRADICTION_RE = re.compile(
    r"(?i)\b(fixed|instead|replaced|no longer|deprecated|updated to|changed to|"
    r"now uses|switched to|removed|disabled|enabled|reconfigured|no more|"
    r"detected|configured|updated and|key added|already pointed)\b"
)
_TOPIC_RE = re.compile(
    r"(?i)\b(CURSOR_API_KEY|TELEGRAM|API[_ ]?KEY|OAuth|composer-2\.5|env[_ ]?file|"
    r"gateway|polling|model id|haiku|claude)\b"
)
_NEGATION_RE = re.compile(r"(?i)\b(no |not |never |missing|without |absent)\b")
_AFFIRMATION_RE = re.compile(
    r"(?i)\b(detected|configured|added|updated|fixed|working|connected|polling)\b"
)
_ENV_NOTE_RE = re.compile(r"(?i)\b(env|api[_ ]?key|token|secret|cursor|telegram)\b")


def _topic_tokens(text: str) -> set[str]:
    return {m.group(0).lower() for m in _TOPIC_RE.finditer(text)}


def _topics_overlap(a: str, b: str) -> bool:
    ta, tb = _topic_tokens(a), _topic_tokens(b)
    return bool(ta and tb and (ta & tb))


def _is_topic_contradiction(new_content: str, old_content: str) -> bool:
    if not _topics_overlap(new_content, old_content):
        return False
    new_neg, old_neg = bool(_NEGATION_RE.search(new_content)), bool(_NEGATION_RE.search(old_content))
    new_pos, old_pos = bool(_AFFIRMATION_RE.search(new_content)), bool(_AFFIRMATION_RE.search(old_content))
    if new_neg != old_neg:
        return True
    if new_pos and old_neg:
        return True
    if old_pos and new_neg:
        return True
    return bool(_CONTRADICTION_RE.search(new_content))


def _should_supersede_similar(new_content: str, *, auto_extracted: bool) -> bool:
    if not auto_extracted:
        return True
    if _CONTRADICTION_RE.search(new_content):
        return True
    return bool(_ENV_NOTE_RE.search(new_content) and _AFFIRMATION_RE.search(new_content))


def _supersede_types_for(content: str, typ: str) -> set[str]:
    types = set(_SUPERSEDE_TYPES)
    if _ENV_NOTE_RE.search(content):
        types.add("note")
    return types if typ in types else {typ}


def _find_supersede_targets(
    content: str,
    typ: str,
    existing: list[dict],
    *,
    low: float = 0.40,
    high: float = 0.82,
) -> list[dict]:
    """Older memories on same topic that may be contradicted."""
    allowed_types = _supersede_types_for(content, typ)
    targets = []
    for mem in existing:
        if (mem.get("status") or "active") != "active":
            continue
        if mem.get("type") not in allowed_types:
            continue
        ex = mem.get("content") or ""
        sim = similarity(content, ex)
        if _is_topic_contradiction(content, ex):
            targets.append(mem)
            continue
        if _topics_overlap(content, ex) and sim >= 0.28:
            if _CONTRADICTION_RE.search(content) or _AFFIRMATION_RE.search(content):
                targets.append(mem)
            continue
        if low <= sim < high and mem.get("type") == typ:
            targets.append(mem)
    return targets


def _mark_superseded(cur, memory_ids: list[int], now: str) -> int:
    if not memory_ids:
        return 0
    placeholders = ",".join("?" * len(memory_ids))
    cur.execute(
        f"UPDATE memories SET status = 'superseded', updated_at = ? WHERE id IN ({placeholders})",
        [now, *memory_ids],
    )
    return cur.rowcount


# --- Auto-extraction from chat text ---

_SKIP_PHRASES = (
    "let me",
    "i'll ",
    "i will ",
    "searching",
    "reading",
    "looking at",
    "here's what",
    "summary of",
    "todo write",
    "tool call",
    "fetch ",
    "grep ",
    "when to use which",
    "think of three layers",
    "agent workflow (ideal)",
    "concrete improvements",
    "bottom line",
    "recommended model",
)

_META_SKIP_RE = re.compile(
    r"(?i)(?:→|\[e\.g\.|example one-liner|^\s*##\s|"
    r"^\s*\d+\.\s+\*\*start\*\*|^when to use which type|"
    r"^\s*-\s*→|agent start prompt|copy from the project)"
)

_FRAGMENT_RE = re.compile(r"^[,;.\s]|^[a-z]{1,3}\s|phan networks|ng new/")
_BRIEF_FRAGMENT_RE = re.compile(
    r"(?i)^(?:#{1,3}\s|\w\*\*\s|[-*•]\s*\*\*(?:decision|constraint|goal|problem)\*\*:?\s*—|"
    r"\|[^|]+\|[^|]+\||^\d+\.\s+\*\*)"
)

_TYPE_RULES: list[tuple[str, re.Pattern]] = [
    (
        "constraint",
        re.compile(
            r"(?i)(?:never\s|always\s|do not\s|don't\s|must not|cannot\s|"
            r"hard rule|/boot\s*\(fat\)|fail-closed|only via\s)"
        ),
    ),
    ("problem", re.compile(r"(?i)(?:bug|broken|fails?|error|root cause|issue:|doesn't work|not working)")),
    ("caveat", re.compile(r"(?i)(?:caveat|warning|be careful|edge case|unless\s|wiped on plugin)")),
    ("decision", re.compile(r"(?i)(?:decided|we chose|fixed|deployed|implemented|use .+ instead|→|re-run\s)")),
    ("goal", re.compile(r"(?i)(?:should only|target behavior|goal is|block only|never block)")),
    ("active_work", re.compile(r"(?i)(?:todo|next step|still need|validation matrix|in progress|remaining)")),
    ("note", re.compile(r"(?i)(?:compose path|located at|runs on port|mcp.*697)")),
]

_BULLET_RE = re.compile(r"^[\s]*[-*•]\s+\*{0,2}(\w+)\*{0,2}:?\s*(.{20,350})$", re.MULTILINE)
_TYPED_LINE_RE = re.compile(
    r"(?i)^[\s]*[-*•]?\s*\*{0,2}(decision|constraint|goal|problem|caveat|active_work|note)\*{0,2}:?\s*(.{15,350})$",
    re.MULTILINE,
)


def _classify_line(line: str) -> str:
    for typ, pat in _TYPE_RULES:
        if pat.search(line):
            return typ
    return "note"


def _clean_candidate(text: str) -> str:
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"`+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text.strip("-•* ")
    return text


def _usable_candidate(text: str) -> bool:
    if len(text) < 28 or len(text) > 400:
        return False
    words = text.split()
    if len(words) < 6:
        return False
    low = text.lower()
    if any(p in low for p in _SKIP_PHRASES):
        return False
    if low.startswith(("http://", "https://", "```", "## ")):
        return False
    if _META_SKIP_RE.search(text):
        return False
    if _FRAGMENT_RE.search(text):
        return False
    # Skip table/list debris (high symbol ratio or no verb-like word)
    alpha = sum(c.isalpha() for c in text)
    if alpha / max(len(text), 1) < 0.55:
        return False
    if not re.search(r"(?i)\b(is|are|was|use|must|never|always|fixed|deployed|path|port|block|sleep|run|install)\b", text):
        return False
    if _BRIEF_FRAGMENT_RE.search(text):
        return False
    return True


def is_brief_worthy_memory(content: str) -> bool:
    """Filter memories when rendering agent briefs."""
    return _usable_candidate(_clean_candidate(content))


# Cross-project topic markers — reject when slug/name don't match
_CROSS_PROJECT_TOPICS: list[tuple[re.Pattern, frozenset[str]]] = [
    (re.compile(r"(?i)\b(s3[\s_-]?sleep|dynamix\.s3|sleep daemon|sleep script)\b"), frozenset({"s3-sleep"})),
    (re.compile(r"(?i)\b(plex|transcode/|imagegenius/plex)\b"), frozenset({"plex"})),
    (re.compile(r"(?i)\b(immich|imagegenius)\b"), frozenset({"immich", "cache-drive"})),
    (re.compile(r"(?i)\b(nextcloud|collabora)\b"), frozenset({"nextcloud"})),
    (re.compile(r"(?i)\b(hermes|telegram bot|gateway)\b"), frozenset({"hermes", "cache-drive"})),
    (re.compile(r"(?i)\b(odysseus)\b"), frozenset({"odysseus"})),
    (re.compile(r"(?i)\b(metube|youtube downloader)\b"), frozenset({"metube"})),
    (re.compile(r"(?i)\b(cache drive|mover|cache pool|encoded-video)\b"), frozenset({"cache-drive"})),
    (re.compile(r"(?i)\b(google sso|cloudflare access|oidc callback)\b"), frozenset({"google-sso"})),
    (re.compile(r"(?i)\b(docker dashboard|portainer)\b"), frozenset({"docker-dashboard"})),
]


def is_memory_relevant_to_project(
    content: str,
    slug: str,
    project_name: str = "",
) -> bool:
    """Drop memories that clearly belong to a different project."""
    if not content or len(content.strip()) < 15:
        return False
    low = content.lower()
    slug_low = slug.lower()
    name_tokens = {t.lower() for t in re.findall(r"[a-z0-9]+", project_name) if len(t) > 2}
    name_tokens.add(slug_low.replace("-", " "))
    name_tokens.add(slug_low)

    for pattern, allowed_slugs in _CROSS_PROJECT_TOPICS:
        if pattern.search(content) and slug not in allowed_slugs:
            return False

    # SSH project: reject sleep/S3/compose-deploy noise
    if slug == "ssh-passwordless":
        if re.search(
            r"(?i)\b(sleep|s3[\s_-]?sleep|docker compose|compose up|appdata|stays awake|"
            r"spun down|ui connection|port 80)\b",
            content,
        ):
            return False
        if not re.search(r"(?i)\b(ssh|authorized_keys|passwordless|public key|id_ed25519|id_rsa)\b", content):
            return False

    # Daemon projects: reject compose vocabulary unless slug matches
    if slug == "s3-sleep":
        if re.search(r"(?i)\b(docker compose up|compose path|appdata/)\b", content):
            return False

    if slug in ("wolf-leader", "ide-storage"):
        if re.search(
            r"(?i)\b(hermes|metube|nextcloud|immich|s3[\s_-]?sleep|odysseus|plex)\b",
            content,
        ) and not re.search(r"(?i)\b(ide[\s_-]?storage|6971|6972|distill|handoff|SPEC\.yaml)\b", content):
            return False
        if re.search(r"(?i)/mnt/user/appdata/(?!wolf-leader|ide-storage)[a-z0-9._-]+", content):
            return False

    return True


def extract_from_text(text: str, *, chat_id: Optional[int] = None) -> list[dict]:
    candidates: list[dict] = []
    seen: set[str] = set()

    def add(typ: str, content: str) -> None:
        content = _clean_candidate(content)
        if not _usable_candidate(content):
            return
        key = normalize_text(content)
        if key in seen:
            return
        seen.add(key)
        candidates.append({"type": typ, "content": content, "source_chat_id": chat_id})

    for match in _TYPED_LINE_RE.finditer(text):
        add(match.group(1).lower(), match.group(2))

    for match in _BULLET_RE.finditer(text):
        label, body = match.group(1).lower(), match.group(2)
        if label in MEMORY_TYPES:
            add(label, body)
        else:
            add(_classify_line(body), body)

    for para in re.split(r"\n\s*\n", text):
        para = _clean_candidate(para)
        if not _usable_candidate(para):
            continue
        if len(para) > 220:
            continue
        typ = _classify_line(para)
        if typ in ("decision", "constraint", "problem", "caveat", "goal", "active_work"):
            add(typ, para)
        elif typ == "note" and re.search(r"(?i)(?:compose|/boot/|/usr/local/|container|plugin|mcp|port\s+\d)", para):
            add(typ, para)

    return candidates


def _load_existing_memories(cur, project_id: int, *, include_superseded: bool = False) -> list[dict]:
    if include_superseded:
        cur.execute(
            "SELECT id, type, content, source_chat_id, status FROM memories WHERE project_id = ?",
            (project_id,),
        )
    else:
        cur.execute(
            """
            SELECT id, type, content, source_chat_id, status FROM memories
            WHERE project_id = ? AND COALESCE(status, 'active') = 'active'
            """,
            (project_id,),
        )
    return [dict(r) for r in cur.fetchall()]


def _chats_needing_extraction(cur, project_id: int) -> list[dict]:
    """Chats with no memories sourced from them yet."""
    cur.execute(
        """
        SELECT c.id, c.title
        FROM chats c
        WHERE c.project_id = ?
          AND COALESCE(c.status, 'active') != 'archived'
          AND NOT EXISTS (
            SELECT 1 FROM memories m WHERE m.source_chat_id = c.id
          )
        ORDER BY c.updated_at DESC
        """,
        (project_id,),
    )
    return [dict(r) for r in cur.fetchall()]


def insert_memory(
    project_id: int,
    typ: str,
    content: str,
    *,
    source_chat_id: Optional[int] = None,
    semantic_descriptor: Optional[str] = None,
    existing: Optional[list[dict]] = None,
    auto_extracted: bool = False,
) -> dict:
    if typ not in MEMORY_TYPES:
        raise ValueError(f"type must be one of {MEMORY_TYPES}")
    content = _clean_candidate(content)
    if not content:
        raise ValueError("content empty after cleanup")

    from ide_storage.embeddings import embeddings_enabled

    now = datetime.utcnow().isoformat()
    descriptor_source = "agent" if (semantic_descriptor and semantic_descriptor.strip()) else "none"
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, name, slug FROM projects WHERE id = ?", (project_id,))
        proj = cur.fetchone()
        if not proj:
            raise ValueError("Project not found")

        # A1/A2/A5: never let the vector index go silently content-only. When
        # embeddings are on but the agent gave no descriptor, synthesize a cheap
        # fallback so memory_embed_text always has a descriptor to prepend.
        if descriptor_source != "agent" and embeddings_enabled():
            from ide_storage.embed_index import synthesize_descriptor

            semantic_descriptor = synthesize_descriptor(
                kind="memory",
                type=typ,
                content=content,
                project_name=proj["name"],
                slug=proj["slug"],
            )
            descriptor_source = "synthesized"

        if existing is None:
            existing = _load_existing_memories(cur, project_id)

        dup = is_duplicate(content, existing)
        if dup:
            return {
                "id": dup["id"],
                "project_id": project_id,
                "type": dup["type"],
                "content": dup["content"],
                "action": "skipped_duplicate",
                "source_chat_id": dup.get("source_chat_id"),
                "descriptor_source": descriptor_source,
            }

        superseded_ids: list[int] = []
        if _should_supersede_similar(content, auto_extracted=auto_extracted):
            for old in _find_supersede_targets(content, typ, existing):
                superseded_ids.append(old["id"])
            superseded_ids = list(dict.fromkeys(superseded_ids))

        cur.execute(
            """
            INSERT INTO memories (project_id, type, content, source_chat_id, created_at, updated_at, status, semantic_descriptor)
            VALUES (?, ?, ?, ?, ?, ?, 'active', ?)
            """,
            (project_id, typ, content, source_chat_id, now, now, semantic_descriptor),
        )
        mid = cur.lastrowid
        superseded_count = _mark_superseded(cur, superseded_ids, now)
        conn.commit()

    from ide_storage.embed_index import delete_embeddings, sync_dirty

    # D4: drop stale vectors for memories we just superseded so they no longer
    # surface in semantic search.
    if superseded_ids:
        delete_embeddings([("memory", i) for i in superseded_ids])

    sync_dirty(project_id=project_id, memory_ids=[mid])

    return {
        "id": mid,
        "project_id": project_id,
        "type": typ,
        "content": content,
        "source_chat_id": source_chat_id,
        "action": "created",
        "auto_extracted": auto_extracted,
        "superseded_count": superseded_count,
        "superseded_ids": superseded_ids,
        "descriptor_source": descriptor_source,
    }


def extract_memories_for_project(
    project_id: int,
    *,
    chat_id: Optional[int] = None,
    max_new: int = 12,
) -> dict:
    """Rule-based memory extraction from linked chat transcripts."""
    created: list[dict] = []
    skipped = 0
    scanned_chats = 0

    with db_conn() as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        existing = _load_existing_memories(cur, project_id)

        if chat_id:
            chat_ids = [chat_id]
        else:
            pending = _chats_needing_extraction(cur, project_id)
            cur.execute(
                "SELECT COUNT(*) FROM memories WHERE project_id = ?",
                (project_id,),
            )
            mem_count = cur.fetchone()[0]
            # Re-scan oldest chats if project is still thin on memories
            if mem_count < 4:
                cur.execute(
                    """
                    SELECT id FROM chats
                    WHERE project_id = ? AND COALESCE(status, 'active') != 'archived'
                    ORDER BY updated_at DESC LIMIT 8
                    """,
                    (project_id,),
                )
                chat_ids = [r[0] for r in cur.fetchall()]
            else:
                chat_ids = [c["id"] for c in pending]

        for cid in chat_ids:
            if len(created) >= max_new:
                break
            cur.execute(
                "SELECT role, content FROM messages WHERE chat_id = ? ORDER BY id",
                (cid,),
            )
            msgs = [dict(r) for r in cur.fetchall()]
            if not msgs:
                continue
            scanned_chats += 1
            text = "\n\n".join(
                m["content"] for m in msgs if m["role"] == "assistant" and m.get("content")
            )
            if not text:
                text = "\n\n".join(m["content"] for m in msgs if m.get("content"))
            for cand in extract_from_text(text, chat_id=cid):
                if len(created) >= max_new:
                    break
                try:
                    result = insert_memory(
                        project_id,
                        cand["type"],
                        cand["content"],
                        source_chat_id=cid,
                        existing=existing,
                        auto_extracted=True,
                    )
                except ValueError:
                    continue
                if result.get("action") == "created":
                    created.append(result)
                    existing.append(result)
                else:
                    skipped += 1

    synthesized = sum(1 for m in created if m.get("descriptor_source") == "synthesized")
    result = {
        "project_id": project_id,
        "created": len(created),
        "skipped_duplicates": skipped,
        "scanned_chats": scanned_chats,
        "memories": created,
        "descriptors_synthesized": synthesized,
    }
    # A4: make it observable (not silent) when embeddings are on yet memories were
    # saved without an agent-provided descriptor and we had to synthesize one.
    if synthesized:
        result["warnings"] = [
            f"{synthesized} memory descriptor(s) auto-synthesized "
            "(no agent semantic_descriptor provided); vector quality may be lower."
        ]
    return result


def refresh_project_after_memory_change(project_id: int) -> dict:
    """Regenerate agent brief and search index after memory changes."""
    from ide_storage.distill_project import distill_project
    from ide_storage.embed_index import sync_dirty

    distill = distill_project(project_id)
    regenerate_index()
    sync_dirty(project_id=project_id)
    return distill


def remember_and_refresh(
    project_id: int,
    typ: str,
    content: str,
    source_chat_id: Optional[int] = None,
    semantic_descriptor: Optional[str] = None,
) -> dict:
    result = insert_memory(
        project_id,
        typ,
        content,
        source_chat_id=source_chat_id,
        semantic_descriptor=semantic_descriptor,
    )
    if result.get("action") == "created":
        result["distill"] = refresh_project_after_memory_change(project_id)
    return result


def extract_all_projects(*, max_new_per_project: int = 15) -> list[dict]:
    from ide_storage.distill_project import distill_project

    results = []
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT DISTINCT p.id
            FROM projects p
            JOIN chats c ON c.project_id = p.id
            WHERE COALESCE(p.status, 'active') != 'archived'
              AND COALESCE(c.status, 'active') != 'archived'
            ORDER BY p.id
            """
        )
        ids = [row[0] for row in cur.fetchall()]

    for pid in ids:
        extract = extract_memories_for_project(pid, max_new=max_new_per_project)
        distill = distill_project(pid)
        results.append({"project_id": pid, "extract": extract, "distill": distill})
    regenerate_index()
    return results


def prune_low_quality_memories(*, dry_run: bool = False) -> dict:
    """Remove auto-extracted or junk memories that fail quality checks."""
    removed: list[dict] = []
    kept = 0
    with db_conn() as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute("SELECT id, type, content, source_chat_id, project_id FROM memories")
        rows = [dict(r) for r in cur.fetchall()]
        for row in rows:
            content = row.get("content") or ""
            auto = row.get("source_chat_id") is not None
            if not auto and _usable_candidate(content):
                kept += 1
                continue
            if auto and not _usable_candidate(content):
                removed.append(row)
                if not dry_run:
                    cur.execute("DELETE FROM memories WHERE id = ?", (row["id"],))
            else:
                kept += 1
        if not dry_run:
            conn.commit()
    if not dry_run and removed:
        from ide_storage.embed_index import delete_embeddings

        delete_embeddings([("memory", r["id"]) for r in removed])
    return {"removed": len(removed), "kept": kept, "samples": removed[:8]}


def archive_chat(chat_id: int) -> dict:
    """Mark a chat archived after successful project checkpoint."""
    now = datetime.utcnow().isoformat()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE chats SET status = 'archived', updated_at = ?
            WHERE id = ? AND COALESCE(status, 'active') != 'archived'
            """,
            (now, chat_id),
        )
        archived = cur.rowcount > 0
        conn.commit()
    if archived:
        # D4: archived chats are excluded from search, so drop their stale vector.
        from ide_storage.embed_index import delete_embeddings

        delete_embeddings([("chat", chat_id)])
    return {"chat_id": chat_id, "archived": archived, "status": "archived"}


def archive_all_chats(*, project_id: Optional[int] = None) -> dict:
    """One-time bootstrap: archive all chats (optionally per project)."""
    now = datetime.utcnow().isoformat()
    with db_conn() as conn:
        cur = conn.cursor()
        if project_id:
            cur.execute(
                """
                UPDATE chats SET status = 'archived', updated_at = ?
                WHERE project_id = ? AND COALESCE(status, 'active') != 'archived'
                """,
                (now, project_id),
            )
        else:
            cur.execute(
                """
                UPDATE chats SET status = 'archived', updated_at = ?
                WHERE COALESCE(status, 'active') != 'archived'
                """,
                (now,),
            )
        count = cur.rowcount
        conn.commit()
    return {"archived": count, "project_id": project_id}


def filter_bullets_against_memories(bullets: list[str], memories: list[dict]) -> list[str]:
    """Drop chat-extracted bullets that duplicate typed memories."""
    if not memories:
        return bullets
    kept: list[str] = []
    for b in bullets:
        if is_duplicate(b, memories, threshold=0.65):
            continue
        kept.append(b)
    return kept


def main() -> None:
    parser = argparse.ArgumentParser(description="Memory extraction and refresh")
    parser.add_argument("--project-id", type=int)
    parser.add_argument("--chat-id", type=int)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--max-new", type=int, default=15)
    parser.add_argument("--prune", action="store_true", help="Remove low-quality auto-extracted memories")
    parser.add_argument("--archive-all", action="store_true", help="Archive all chats (bootstrap)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.archive_all:
        result = archive_all_chats(project_id=args.project_id)
        print(json.dumps(result, indent=2))
        if not args.dry_run:
            from ide_storage.distill_project import distill_all
            distill_all()
            regenerate_index()
        return

    if args.prune:
        print(json.dumps(prune_low_quality_memories(dry_run=args.dry_run), indent=2))
        if not args.dry_run:
            from ide_storage.distill_project import distill_all
            print(json.dumps({"redistilled": distill_all()}, indent=2, default=str)[:2000])
        return

    if args.all:
        results = extract_all_projects(max_new_per_project=args.max_new)
    elif args.project_id:
        extract = extract_memories_for_project(
            args.project_id, chat_id=args.chat_id, max_new=args.max_new
        )
        distill = refresh_project_after_memory_change(args.project_id)
        results = [{"project_id": args.project_id, "extract": extract, "distill": distill}]
    else:
        parser.error("Provide --project-id N or --all")

    print(json.dumps({"processed": len(results), "results": results}, indent=2))


if __name__ == "__main__":
    main()
