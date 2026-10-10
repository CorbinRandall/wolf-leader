"""Obsidian vault writer — markdown notes on the share, linked with [[wikilinks]].

Layout (``IDE_STORAGE_VAULT_DIR``, e.g. ``/srv/wolf/wolf-leader/vault`` == ``W:\\wolf-leader\\vault``):

    Home.md                    map of content
    projects/<slug>.md         living brief per project
    howls/<slug>/<stamp>.md    one note per broadcast
    topics/<topic>.md          hubs: tags + vector-neighbour clusters

Notes are generated from Postgres (the source of truth). Their "Related" section
comes from pgvector nearest neighbours, which is what makes Obsidian's graph
useful without anyone hand-linking anything.
"""
from __future__ import annotations

import json
import os
import re
from typing import Any

from ide_storage import localtime as LT
from ide_storage.db import db_conn, get_vault_dir

_SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def _slugify(text: str) -> str:
    text = _SAFE.sub("-", (text or "").strip().lower()).strip("-")
    return text or "untitled"


def vault_root() -> str | None:
    return get_vault_dir()


def _write(rel: str, content: str) -> str | None:
    root = vault_root()
    if not root:
        return None
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    existing = None
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                existing = fh.read()
        except OSError:
            existing = None
    if existing == content:
        return path
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return path


def _fm(data: dict[str, Any]) -> str:
    lines = ["---"]
    for k, v in data.items():
        if v is None or v == "" or v == []:
            continue
        if isinstance(v, list):
            lines.append(f"{k}:")
            lines.extend(f"  - {json.dumps(str(x)) if isinstance(x, str) and (':' in x or '#' in x) else x}" for x in v)
        elif isinstance(v, str) and (":" in v or "#" in v or v.startswith(("[", "{"))):
            lines.append(f"{k}: {json.dumps(v)}")
        else:
            lines.append(f"{k}: {v}")
    lines.append("---")
    return "\n".join(lines)


def _tags(*raws: Any) -> list[str]:
    out: list[str] = []
    for raw in raws:
        if not raw:
            continue
        vals = raw
        if isinstance(raw, str):
            try:
                vals = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                vals = [t.strip() for t in raw.split(",")]
        if isinstance(vals, (list, tuple)):
            for t in vals:
                t = _slugify(str(t))
                if t and t not in out:
                    out.append(t)
    return out


def project_link(slug: str, name: str | None = None) -> str:
    return f"[[projects/{slug}|{name or slug}]]"


def howl_link(slug: str, stamp: str, label: str | None = None) -> str:
    return f"[[howls/{slug}/{stamp}|{label or stamp}]]"


def _related_section(kind: str, ref_id: int, *, exclude_slug: str | None = None) -> list[str]:
    try:
        from ide_storage.embed_index import neighbors_for

        hits = neighbors_for(kind, ref_id, kinds=("project", "howl", "memory"), limit=10)
    except Exception:
        hits = []
    if not hits:
        return []
    lines = ["## Related", ""]
    seen: set[str] = set()
    for h in hits:
        if h["kind"] == "project":
            slug = h.get("slug")
            if not slug or slug == exclude_slug:
                continue
            link = project_link(slug, h.get("title"))
        elif h["kind"] == "howl":
            slug = h.get("slug")
            if not slug:
                continue
            stamp = _stamp_from_iso(h.get("created_at") or "")
            link = howl_link(slug, stamp, f"{slug} howl {LT.fmt(h.get('created_at'), stamp)}")
        else:
            pid = h.get("project_id")
            pslug = _slug_for_project(pid) if pid else None
            if not pslug:
                continue
            link = f"{project_link(pslug)} — {(h.get('content') or '')[:100]}"
        if link in seen:
            continue
        seen.add(link)
        lines.append(f"- {link} ({h['similarity']:.2f})")
    return lines + [""] if len(lines) > 2 else []


_slug_cache: dict[int, str] = {}


def _slug_for_project(pid: int) -> str | None:
    if pid in _slug_cache:
        return _slug_cache[pid]
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT slug FROM projects WHERE id = ?", (pid,))
        row = cur.fetchone()
    slug = row["slug"] if row and row["slug"] else None
    if slug:
        _slug_cache[pid] = slug
    return slug


def _stamp_from_iso(iso: str) -> str:
    return LT.stamp(iso)


# ----------------------------------------------------------------- project note
def write_project_note(project_id: int) -> str | None:
    if not vault_root():
        return None
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM v_project_recall WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if not row:
            return None
        rec = dict(row)
        cur.execute(
            "SELECT id, created_at, summary, git_commit, device_name FROM howls WHERE project_id = ? ORDER BY created_at DESC LIMIT 20",
            (project_id,),
        )
        howls = [dict(r) for r in cur.fetchall()]
        cur.execute(
            "SELECT id, kind, state, title, connector, updated_at FROM jobs WHERE project_id = ? AND state IN ('queued','running') ORDER BY updated_at DESC",
            (project_id,),
        )
        jobs = [dict(r) for r in cur.fetchall()]

    slug = rec.get("slug") or f"project-{project_id}"
    _slug_cache[project_id] = slug
    meta = {}
    if rec.get("metadata"):
        try:
            meta = json.loads(rec["metadata"]) or {}
        except (json.JSONDecodeError, TypeError):
            meta = {}
    tags = ["project", *(_tags(rec.get("tags")))]
    paths = rec.get("paths") or []
    if isinstance(paths, str):
        paths = json.loads(paths)
    memories = rec.get("memories") or []
    if isinstance(memories, str):
        memories = json.loads(memories)
    left = rec.get("left_off") or {}
    if isinstance(left, str):
        left = json.loads(left)

    lines = [
        _fm(
            {
                "slug": slug,
                "type": "project",
                "status": rec.get("status") or "active",
                "tags": tags,
                "updated": LT.fmt(rec.get("updated_at")),
                "paths": [p["path"] for p in paths][:8],
                "git_commit": howls[0].get("git_commit") if howls and howls[0].get("git_commit") else None,
            }
        ),
        "",
        f"# {rec.get('name') or slug}",
        "",
    ]
    if rec.get("description"):
        lines += [rec["description"].strip(), ""]

    if left and (left.get("summary") or left.get("chat_title")):
        lines += ["## Where we left off", ""]
        when = LT.fmt(left.get("occurred_at"))
        lines.append(f"_{when}_ — **{left.get('chat_title') or 'last session'}**")
        if left.get("summary"):
            lines += ["", (left["summary"] or "").strip()]
        lines.append("")

    if paths:
        lines += ["## Where it lives", ""]
        for p in paths:
            lines.append(f"- `{p['path']}`" + (f" ({p['kind']})" if p.get("kind") else ""))
        lines.append("")

    by_type: dict[str, list[dict]] = {}
    for m in memories:
        by_type.setdefault(m.get("type") or "note", []).append(m)
    if by_type:
        lines += ["## What we know", ""]
        for typ in ("goal", "decision", "constraint", "active_work", "problem", "caveat", "note"):
            items = by_type.get(typ)
            if not items:
                continue
            lines.append(f"### {typ.replace('_', ' ').title()}")
            lines.append("")
            for m in items[:15]:
                lines.append(f"- {(m.get('content') or '').strip()}")
            lines.append("")

    if howls:
        lines += ["## Howls", ""]
        for h in howls:
            stamp = _stamp_from_iso(h["created_at"])
            extra = []
            if h.get("device_name"):
                extra.append(h["device_name"])
            if h.get("git_commit"):
                extra.append(f"`{h['git_commit'][:8]}`")
            first = (h.get("summary") or "").strip().splitlines()[0][:90] if h.get("summary") else ""
            lines.append(f"- {howl_link(slug, stamp, LT.fmt(h['created_at'], stamp))} {' · '.join(extra)} — {first}".rstrip(" —"))
        lines.append("")

    if jobs:
        lines += ["## Open jobs", ""]
        for j in jobs:
            lines.append(f"- **{j['state']}** {j['kind']} — {j.get('title') or ''} ({j.get('connector') or 'hub'})")
        lines.append("")

    lines += _related_section("project", project_id, exclude_slug=slug)
    lines += [f"Tags: {' '.join('#' + t for t in tags)}", "", "← [[Home]]", ""]
    return _write(f"projects/{slug}.md", "\n".join(lines))


# -------------------------------------------------------------------- howl note
def write_howl_note(howl_id: int) -> str | None:
    if not vault_root():
        return None
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT h.*, p.slug AS project_slug, p.name AS project_name, p.tags AS project_tags,
                   c.title AS chat_title
            FROM howls h
            LEFT JOIN projects p ON p.id = h.project_id
            LEFT JOIN chats c ON c.id = h.chat_id
            WHERE h.id = ?
            """,
            (howl_id,),
        )
        row = cur.fetchone()
        if not row:
            return None
        h = dict(row)
        mems: list[dict] = []
        if h.get("chat_id"):
            cur.execute(
                "SELECT type, content FROM memories WHERE source_chat_id = ? AND COALESCE(status,'active') = 'active' ORDER BY id",
                (h["chat_id"],),
            )
            mems = [dict(r) for r in cur.fetchall()]
        cur.execute("SELECT DISTINCT path FROM file_chunks WHERE howl_id = ? ORDER BY path", (howl_id,))
        files = [r["path"] for r in cur.fetchall()]

    slug = h.get("project_slug") or f"project-{h.get('project_id')}"
    stamp = _stamp_from_iso(h["created_at"])
    actions = []
    offers = []
    try:
        actions = json.loads(h.get("actions") or "[]")
    except (json.JSONDecodeError, TypeError):
        pass
    try:
        offers = json.loads(h.get("offers") or "[]")
    except (json.JSONDecodeError, TypeError):
        pass

    lines = [
        _fm(
            {
                "type": "howl",
                "project": slug,
                "date": LT.fmt(h["created_at"]),
                "device": h.get("device_name"),
                "git_commit": h.get("git_commit"),
                "git_branch": h.get("git_branch"),
                "tags": ["howl", slug, *(_tags(h.get("project_tags")))],
            }
        ),
        "",
        f"# Howl · {h.get('project_name') or slug} · {LT.fmt(h['created_at'], stamp)}",
        "",
        f"Project: {project_link(slug, h.get('project_name'))}",
    ]
    if h.get("chat_title"):
        lines.append(f"Session: **{h['chat_title']}**")
    if h.get("workspace_path"):
        lines.append(f"Workspace: `{h['workspace_path']}`")
    if h.get("git_commit"):
        lines.append(f"Git: `{h['git_commit']}`" + (f" on `{h['git_branch']}`" if h.get("git_branch") else ""))
    lines.append("")
    if h.get("summary"):
        lines += ["## Summary", "", h["summary"].strip(), ""]
    if mems:
        lines += ["## Memories added", ""]
        for m in mems:
            lines.append(f"- **{m['type']}** — {m['content'].strip()}")
        lines.append("")
    if files:
        lines += ["## Files ingested", ""]
        lines += [f"- `{f}`" for f in files]
        lines.append("")
    if actions:
        lines += ["## What ran", ""]
        lines += [f"- {a}" for a in actions]
        lines.append("")
    if offers:
        lines += ["## Offered (not done unless you said yes)", ""]
        lines += [f"- {o}" for o in offers]
        lines.append("")
    lines += _related_section("howl", howl_id)
    lines += ["← " + project_link(slug), ""]
    return _write(f"howls/{slug}/{stamp}.md", "\n".join(lines))


# -------------------------------------------------------------- home + topics
def write_home() -> str | None:
    if not vault_root():
        return None
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.slug, p.name, p.description, p.status, p.updated_at,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memory_count,
                   (SELECT COUNT(*) FROM howls h WHERE h.project_id = p.id) AS howl_count
            FROM projects p
            WHERE COALESCE(p.status,'active') != 'archived'
            ORDER BY p.updated_at DESC
            """
        )
        projects = [dict(r) for r in cur.fetchall()]
        cur.execute(
            """
            SELECT h.created_at, h.summary, h.device_name, p.slug, p.name
            FROM howls h JOIN projects p ON p.id = h.project_id
            ORDER BY h.created_at DESC LIMIT 15
            """
        )
        howls = [dict(r) for r in cur.fetchall()]
    topics = sorted(_topic_index().keys())
    now = LT.now_display()
    lines = [
        _fm({"type": "home", "tags": ["home"], "generated": now}),
        "",
        "# Wolf Leader — Home",
        "",
        f"_Generated by the hub {now}. Edit projects in the hub, not here — this file is regenerated._",
        "",
        "## Projects",
        "",
    ]
    for p in projects:
        slug = p["slug"] or f"project-{p['id']}"
        desc = (p.get("description") or "").strip().splitlines()[0][:100] if p.get("description") else ""
        lines.append(f"- {project_link(slug, p['name'])} — {desc} ({p['memory_count']} memories, {p['howl_count']} howls)".replace(" —  (", " ("))
    lines += ["", "## Recent howls", ""]
    for h in howls:
        stamp = _stamp_from_iso(h["created_at"])
        first = (h.get("summary") or "").strip().splitlines()[0][:90] if h.get("summary") else ""
        lines.append(f"- {howl_link(h['slug'], stamp, LT.fmt(h['created_at'], stamp))} · {project_link(h['slug'], h['name'])} — {first}".rstrip(" —"))
    if topics:
        lines += ["", "## Topics", ""]
        lines += [f"- [[topics/{t}|{t}]]" for t in topics]
    lines.append("")
    return _write("Home.md", "\n".join(lines))


def _topic_index() -> dict[str, list[dict[str, Any]]]:
    """topic -> projects, from project tags plus vector neighbourhoods."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, slug, name, tags FROM projects WHERE COALESCE(status,'active') != 'archived' AND slug IS NOT NULL"
        )
        projects = [dict(r) for r in cur.fetchall()]
    topics: dict[str, list[dict[str, Any]]] = {}
    for p in projects:
        for t in _tags(p.get("tags")):
            topics.setdefault(t, []).append(p)
    # Vector clusters: a project with >= 2 close neighbours forms a topic hub named
    # after itself; cheap, deterministic, and only when embeddings exist.
    try:
        from ide_storage.embed_index import neighbors_for

        for p in projects:
            hits = [h for h in neighbors_for("project", p["id"], kinds=("project",), limit=5, min_similarity=0.55)]
            if len(hits) >= 2:
                key = f"cluster-{p['slug']}"
                members = [p] + [
                    {"id": h["id"], "slug": h.get("slug"), "name": h.get("title")} for h in hits if h.get("slug")
                ]
                topics[key] = members
    except Exception:
        pass
    return topics


def write_topics() -> list[str]:
    if not vault_root():
        return []
    written: list[str] = []
    for topic, members in _topic_index().items():
        lines = [
            _fm({"type": "topic", "tags": ["topic", topic]}),
            "",
            f"# Topic · {topic}",
            "",
            "Projects that share this topic (tags or embedding neighbourhood):",
            "",
        ]
        seen = set()
        for m in members:
            if not m.get("slug") or m["slug"] in seen:
                continue
            seen.add(m["slug"])
            lines.append(f"- {project_link(m['slug'], m.get('name'))}")
        lines += ["", "← [[Home]]", ""]
        path = _write(f"topics/{_slugify(topic)}.md", "\n".join(lines))
        if path:
            written.append(path)
    return written


def prune_vault() -> int:
    """Remove generated notes whose project/howl/topic no longer exists (our folders only)."""
    root = vault_root()
    if not root:
        return 0
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT slug FROM projects WHERE slug IS NOT NULL")
        slugs = {r["slug"] for r in cur.fetchall()}
        cur.execute("SELECT h.created_at, p.slug FROM howls h JOIN projects p ON p.id = h.project_id")
        howl_keys = {(r["slug"], _stamp_from_iso(r["created_at"])) for r in cur.fetchall()}
    topics = {_slugify(t) for t in _topic_index()}
    removed = 0
    proj_dir = os.path.join(root, "projects")
    if os.path.isdir(proj_dir):
        for fn in os.listdir(proj_dir):
            if fn.endswith(".md") and fn[:-3] not in slugs:
                os.remove(os.path.join(proj_dir, fn))
                removed += 1
    howl_dir = os.path.join(root, "howls")
    if os.path.isdir(howl_dir):
        for slug in os.listdir(howl_dir):
            sub = os.path.join(howl_dir, slug)
            if not os.path.isdir(sub):
                continue
            for fn in os.listdir(sub):
                if fn.endswith(".md") and (slug, fn[:-3]) not in howl_keys:
                    os.remove(os.path.join(sub, fn))
                    removed += 1
            if not os.listdir(sub):
                os.rmdir(sub)
    topic_dir = os.path.join(root, "topics")
    if os.path.isdir(topic_dir):
        for fn in os.listdir(topic_dir):
            if fn.endswith(".md") and fn[:-3] not in topics:
                os.remove(os.path.join(topic_dir, fn))
                removed += 1
    return removed


def refresh_vault(project_id: int | None = None, *, howl_id: int | None = None) -> dict[str, Any]:
    """Everything the vault needs after a save/howl. Safe no-op if no vault dir."""
    if not vault_root():
        return {"skipped": True, "reason": "IDE_STORAGE_VAULT_DIR not set"}
    out: dict[str, Any] = {"vault": vault_root()}
    try:
        if howl_id is not None:
            out["howl_note"] = write_howl_note(howl_id)
        if project_id is not None:
            out["project_note"] = write_project_note(project_id)
        out["home"] = write_home()
        out["topics"] = len(write_topics())
        out["pruned"] = prune_vault()
    except Exception as exc:  # noqa: BLE001 — vault is a mirror, never fail the save
        out["error"] = str(exc)
    return out
