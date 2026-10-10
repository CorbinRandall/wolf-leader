"""Export Postgres -> wiki/content/docs (Markdown for Fumadocs) and rebuild the static site.

The wiki is the browser twin of the Obsidian vault: same facts, same links,
rendered by Fumadocs with the Halo theme and served by FastAPI at /wiki.

Obsidian ``[[target|label]]`` links are rewritten to ``[label](/docs/target)``.
Files are written as ``.md`` (not ``.mdx``) so arbitrary text from memories and
chats cannot break the MDX compiler.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from ide_storage import localtime as LT
from ide_storage.db import db_conn

WIKI_DIR = Path(os.environ.get("WOLF_WIKI_DIR", str(Path(__file__).resolve().parent.parent / "wiki")))
CONTENT_DIR = WIKI_DIR / "content" / "docs"
OUT_DIR = WIKI_DIR / "out"
BUILD_TIMEOUT = int(os.environ.get("WOLF_WIKI_BUILD_TIMEOUT", "900"))

_build_lock = threading.Lock()
_WIKILINK = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]")


def wiki_enabled() -> bool:
    if os.environ.get("WOLF_WIKI_ENABLED", "1").lower() in ("0", "false", "no"):
        return False
    return WIKI_DIR.is_dir() and (WIKI_DIR / "package.json").is_file()


def wiki_out_dir() -> Path | None:
    return OUT_DIR if (OUT_DIR / "index.html").is_file() else None


def _rewrite_links(md: str) -> str:
    def repl(m: re.Match[str]) -> str:
        target, label = m.group(1).strip(), (m.group(2) or "").strip()
        if target.lower() == "home":
            return f"[{label or 'Home'}](/docs)"
        return f"[{label or target.rsplit('/', 1)[-1]}](/docs/{target.strip('/')})"

    return _WIKILINK.sub(repl, md)


def _frontmatter(title: str, description: str | None = None, **extra: Any) -> str:
    data = {"title": title}
    if description:
        data["description"] = description.strip().splitlines()[0][:200]
    data.update({k: v for k, v in extra.items() if v not in (None, "", [])})
    lines = ["---"]
    for k, v in data.items():
        lines.append(f"{k}: {json.dumps(v, ensure_ascii=False)}")
    lines.append("---")
    return "\n".join(lines)


def _write(rel: str, content: str) -> None:
    path = CONTENT_DIR / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text(encoding="utf-8") == content:
        return
    path.write_text(content, encoding="utf-8", newline="\n")


def _from_vault_note(rel_md: str) -> str | None:
    """Reuse the vault note body when the vault exists (single source of truth)."""
    from ide_storage.vault import vault_root

    root = vault_root()
    if not root:
        return None
    p = Path(root) / rel_md
    if not p.is_file():
        return None
    return p.read_text(encoding="utf-8")


def _strip_frontmatter(md: str) -> tuple[dict[str, Any], str]:
    if not md.startswith("---"):
        return {}, md
    end = md.find("\n---", 3)
    if end == -1:
        return {}, md
    raw = md[3:end].strip().splitlines()
    fm: dict[str, Any] = {}
    key = None
    for ln in raw:
        if ln.startswith("  - ") and key:
            fm.setdefault(key, []).append(ln[4:].strip().strip('"'))
        elif ":" in ln:
            key, _, val = ln.partition(":")
            key = key.strip()
            val = val.strip()
            fm[key] = val.strip('"') if val else []
    return fm, md[end + 4:].lstrip("\n")


def export_content() -> dict[str, Any]:
    """Regenerate every page under wiki/content/docs from Postgres (via the vault writer)."""
    if not wiki_enabled():
        return {"skipped": True, "reason": "wiki dir not present"}
    from ide_storage import vault as V

    written = 0
    keep: set[Path] = set()

    def put(rel: str, body: str, title: str, description: str | None = None, **extra: Any) -> None:
        nonlocal written
        content = _frontmatter(title, description, **extra) + "\n\n" + _rewrite_links(body).rstrip() + "\n"
        _write(rel, content)
        keep.add(CONTENT_DIR / rel)
        written += 1

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, slug, name, description FROM projects WHERE COALESCE(status,'active') != 'archived' AND slug IS NOT NULL ORDER BY updated_at DESC"
        )
        projects = [dict(r) for r in cur.fetchall()]
        cur.execute(
            "SELECT h.id, h.created_at, h.summary, p.slug FROM howls h JOIN projects p ON p.id = h.project_id ORDER BY h.created_at DESC"
        )
        howls = [dict(r) for r in cur.fetchall()]

    # Home
    home_md = _from_vault_note("Home.md")
    if home_md is None:
        V.write_home()
        home_md = _from_vault_note("Home.md") or "# Wolf Leader\n\nNo content yet."
    _, body = _strip_frontmatter(home_md)
    body = re.sub(r"^# .*\n", "", body, count=1)
    put("index.md", body, "Wolf Leader — Home", "Map of every project, newest howls first.")

    # Projects
    for p in projects:
        note = _from_vault_note(f"projects/{p['slug']}.md")
        if note is None:
            V.write_project_note(p["id"])
            note = _from_vault_note(f"projects/{p['slug']}.md")
        if note is None:
            continue
        _, body = _strip_frontmatter(note)
        body = re.sub(r"^# .*\n", "", body, count=1)
        put(f"projects/{p['slug']}.md", body, p["name"] or p["slug"], p.get("description"))
    put(
        "projects/index.md",
        "\n".join(f"- [[projects/{p['slug']}|{p['name'] or p['slug']}]]" for p in projects) or "_No projects yet._",
        "Projects",
        "Living brief per project.",
    )

    # Howls
    by_slug: dict[str, list[dict]] = {}
    for h in howls:
        stamp = V._stamp_from_iso(h["created_at"])
        note = _from_vault_note(f"howls/{h['slug']}/{stamp}.md")
        if note is None:
            V.write_howl_note(h["id"])
            note = _from_vault_note(f"howls/{h['slug']}/{stamp}.md")
        if note is None:
            continue
        _, body = _strip_frontmatter(note)
        body = re.sub(r"^# .*\n", "", body, count=1)
        first = (h.get("summary") or "").strip().splitlines()[0][:160] if h.get("summary") else None
        when = LT.fmt(h["created_at"], stamp)
        put(f"howls/{h['slug']}/{stamp}.md", body, f"{h['slug']} · {when}", first)
        by_slug.setdefault(h["slug"], []).append({"stamp": stamp, "when": when, "first": first})
    for slug, items in by_slug.items():
        put(
            f"howls/{slug}/index.md",
            "\n".join(f"- [[howls/{slug}/{i['stamp']}|{i['when']}]] {('— ' + i['first']) if i['first'] else ''}" for i in items),
            f"Howls · {slug}",
            f"{len(items)} broadcast(s) for [[projects/{slug}]].",
        )
    put(
        "howls/index.md",
        "\n".join(f"- [[howls/{s}|{s}]] ({len(items)})" for s, items in by_slug.items()) or "_No howls yet._",
        "Howls",
        "Every broadcast, grouped by project.",
    )

    # Topics
    topics_dir = Path(V.vault_root() or "") / "topics"
    topic_files = sorted(topics_dir.glob("*.md")) if V.vault_root() and topics_dir.is_dir() else []
    for tf in topic_files:
        _, body = _strip_frontmatter(tf.read_text(encoding="utf-8"))
        body = re.sub(r"^# .*\n", "", body, count=1)
        put(f"topics/{tf.stem}.md", body, f"Topic · {tf.stem}")
    put(
        "topics/index.md",
        "\n".join(f"- [[topics/{tf.stem}|{tf.stem}]]" for tf in topic_files) or "_No topics yet._",
        "Topics",
        "Hubs from tags and embedding neighbourhoods.",
    )

    # Sidebar order
    _write("meta.json", json.dumps({"title": "Wolf Leader", "pages": ["index", "projects", "howls", "topics"]}, indent=2) + "\n")
    keep.add(CONTENT_DIR / "meta.json")
    for sub in ("projects", "howls", "topics"):
        _write(f"{sub}/meta.json", json.dumps({"title": sub.title(), "pages": ["index", "..."]}, indent=2) + "\n")
        keep.add(CONTENT_DIR / sub / "meta.json")

    # Prune pages for things that no longer exist (only under our content dir).
    removed = 0
    if CONTENT_DIR.is_dir():
        for path in CONTENT_DIR.rglob("*"):
            if path.is_file() and path.suffix in (".md", ".mdx", ".json") and path not in keep:
                path.unlink()
                removed += 1
    return {"exported": written, "removed": removed, "content_dir": str(CONTENT_DIR)}


def build_static() -> dict[str, Any]:
    """`next build` (static export) -> wiki/out, atomically swapped in."""
    if not wiki_enabled():
        return {"skipped": True}
    if not (WIKI_DIR / "node_modules").is_dir():
        return {"built": False, "error": "wiki/node_modules missing — image built without the wiki toolchain"}
    npm = shutil.which("npm") or shutil.which("npm.cmd")
    if not npm:
        return {"built": False, "error": "npm not on PATH in the hub container"}
    with _build_lock:
        t0 = time.time()
        env = {**os.environ, "NEXT_TELEMETRY_DISABLED": "1", "CI": "1"}
        proc = subprocess.run(
            [npm, "run", "build"], cwd=str(WIKI_DIR), capture_output=True, text=True, timeout=BUILD_TIMEOUT, env=env
        )
        if proc.returncode != 0:
            return {"built": False, "error": (proc.stderr or proc.stdout)[-4000:], "seconds": round(time.time() - t0, 1)}
        return {"built": True, "seconds": round(time.time() - t0, 1), "out": str(OUT_DIR)}


def export_and_build() -> dict[str, Any]:
    out = export_content()
    if out.get("skipped"):
        return out
    out.update(build_static())
    return out


if __name__ == "__main__":
    print(json.dumps(export_and_build(), indent=2, default=str))
