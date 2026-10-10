"""/wolfhowl (broadcast) and /wolfeat (pull) — the hub side.

``run_howl`` = everything ``/save`` does, then: register this machine's path
alias, record a ``howls`` row with git state, embed it, refresh the filesystem
catalog for the project roots on the share, optionally ingest cited file bodies,
write the Obsidian notes, and hand back a one-paragraph report plus a list of
*offers* (things the agent should ask about, never do silently).

``run_eat`` = ``v_project_recall`` for one project shaped for an agent that is
about to start work on another machine, plus its own offers.
"""
from __future__ import annotations

import json
import os
from datetime import datetime
from typing import Any

from ide_storage import localtime as LT
from ide_storage.db import db_conn
from ide_storage.paths import (
    describe_aliases,
    hub_roots_for_project,
    is_on_share,
    register_project_path,
    to_hub_path,
)

PRODUCT_NAME = os.environ.get("IDE_STORAGE_PRODUCT_NAME", "Wolf Leader")


def _public_base() -> str:
    return os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")


def _now() -> str:
    return datetime.utcnow().isoformat()


# ------------------------------------------------------------------------ howl
def run_howl(
    *,
    session_id: str | None = None,
    slug: str | None = None,
    workspace_path: str | None = None,
    title: str | None = None,
    content: str | None = None,
    messages: list[dict[str, Any]] | None = None,
    occurred_at: str | None = None,
    device_name: str | None = None,
    git: dict[str, Any] | None = None,
    cited_paths: list[str] | None = None,
    ingest_cited: bool = False,
    refresh_catalog: bool = True,
    client_os: str | None = None,
) -> dict[str, Any]:
    from ide_storage.save_project import format_save_summary, save_project

    actions: list[str] = []
    offers: list[dict[str, Any]] = []
    report: dict[str, Any] = {"ok": False, "kind": "howl", "actions": actions, "offers": offers}

    # 0) Resolve or create the project from the folder we are howling from, so the
    #    save below always has a home (alias table first, then create-if-new).
    if not slug and workspace_path:
        from ide_storage.hub import resolve_project

        existing = resolve_project(path=workspace_path)
        if existing:
            slug = existing.get("slug")
        else:
            created = _create_project_for_path(workspace_path, device_name)
            if created:
                slug = created["slug"]
                report["created_project"] = {k: created[k] for k in ("id", "slug", "name")}
                actions.append(f"created project {created['slug']} for {workspace_path}")

    # 1) The /save plate: transcript or messages -> chat -> memories -> brief.
    save = save_project(
        session_id,
        project_slug=slug,
        workspace_path=workspace_path,
        title=title,
        content=content,
        messages=messages,
        occurred_at=occurred_at,
    )
    report["save"] = {k: save.get(k) for k in (
        "ok", "error", "chat_id", "project_id", "project_slug", "project_name",
        "brief_url", "pickup_prompt", "project_linked", "note", "session_id",
    ) if k in save}
    report["save_summary"] = format_save_summary(save)
    if not save.get("ok"):
        report["error"] = save.get("error") or report["save_summary"]
        return report
    actions.append("saved conversation, extracted memories, refreshed brief")

    project_id = save.get("project_id")
    chat_id = save.get("chat_id")
    if not project_id:
        report["ok"] = True
        report["note"] = "Chat saved but no project matched; howl not recorded. Re-run with slug=<project>."
        offers.append({"kind": "assign_project", "why": "no project matched this conversation",
                       "how": f"re-run /wolfhowl with slug=<slug>, or assign in {_public_base()}/?chat={chat_id}"})
        report["summary"] = _paragraph(report)
        return report
    report["project_id"] = project_id
    report["project_slug"] = save.get("project_slug")

    # 2) Path alias for this machine.
    if workspace_path:
        try:
            reg = register_project_path(project_id, workspace_path, kind="workspace", device_name=device_name)
            report["path_alias"] = reg
            if reg.get("added"):
                actions.append(f"registered path alias {workspace_path}")
        except Exception as exc:  # noqa: BLE001
            report["path_alias"] = {"error": str(exc)}

    # 3) Git state: trust the client (it can see its own repo); fall back to the
    #    hub's view of the same folder on the share.
    git_info = dict(git or {})
    hub_roots = hub_roots_for_project(project_id)
    if not git_info.get("commit"):
        from ide_storage.catalog import git_head

        for root in hub_roots:
            head = git_head(root)
            if head.get("commit"):
                git_info = {**head, **{k: v for k, v in git_info.items() if v}}
                break
    # 3b) No remote -> make one on the share. A bare repo under wolf-leader/git/
    #     is created (idempotent); the client adds it as `origin` and pushes on offer.
    if not git_info.get("remote") and (git_info.get("is_repo") or workspace_path):
        remote = ensure_share_remote(save.get("project_slug") or f"project-{project_id}")
        key = {"windows": "windows", "win32": "windows", "mac": "mac", "darwin": "mac"}.get((client_os or "").lower())
        remote["client"] = (remote.get(key) if key else None) or remote["hub"]
        report["git_remote"] = remote
        if remote.get("created"):
            actions.append(f"created git remote on share: {remote['hub']}")
        elif not remote.get("error"):
            actions.append(f"git remote on share ready: {remote['hub']}")
        git_info["remote"] = remote["client"]
        git_info["remote_is_new"] = True
    report["git"] = git_info or None
    if workspace_path and not is_on_share(workspace_path):
        offers.append({
            "kind": "move_to_share",
            "why": f"{workspace_path} is not on the shared drive; only the share is versioned centrally",
            "how": f"clone/move the repo under {describe_aliases()['windows']} (= {describe_aliases()['hub']}) and re-run /wolfhowl",
        })
    new_remote = report.get("git_remote") or {}
    add_origin = f"git remote add origin \"{new_remote.get('client') or new_remote.get('hub')}\" && " if new_remote else ""
    if git_info.get("is_repo") is False or (workspace_path and not git_info):
        offers.append({"kind": "git_init", "why": "project folder is not a git repo; nothing is versioned",
                       "how": f"git init && {add_origin}git add -A && git commit -m 'wolf: initial'"
                              + (" && git push -u origin HEAD" if new_remote else "")})
    elif git_info.get("dirty_files"):
        offers.append({
            "kind": "git_commit",
            "why": f"{git_info['dirty_files']} uncommitted change(s) in the project repo",
            "how": "git add -A && git commit -m '<what changed>'"
                   + (" && git push -u origin HEAD" if new_remote else (" && git push" if git_info.get("remote") else "")),
        })
    elif new_remote and git_info.get("commit"):
        offers.append({
            "kind": "git_push",
            "why": "the repo had no remote; one now exists on the share but has nothing in it",
            "how": "git push -u origin HEAD",
        })

    # 4) Howl row.
    summary_text = _howl_summary(save)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO howls (project_id, chat_id, device_name, workspace_path, summary, actions, offers,
                               git_commit, git_branch, git_remote, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                project_id, chat_id, device_name, workspace_path, summary_text,
                json.dumps(actions), json.dumps([o["kind"] + ": " + o["why"] for o in offers]),
                git_info.get("commit"), git_info.get("branch"), git_info.get("remote"), _now(),
            ),
        )
        howl_id = int(cur.lastrowid)
        cur.execute("SELECT COUNT(*) AS n FROM memories WHERE source_chat_id = ?", (chat_id,))
        mems = int(cur.fetchone()["n"]) if chat_id else 0
        cur.execute("UPDATE howls SET memories_added = ? WHERE id = ?", (mems, howl_id))
        conn.commit()
    report["howl_id"] = howl_id
    report["memories_added"] = mems

    # 5) Embed the howl (chat + memories were embedded by the save pipeline).
    from ide_storage.embed_index import sync_dirty

    report["embeddings"] = sync_dirty(howl_ids=[howl_id])
    actions.append("embedded howl + memories in pgvector")

    # 6) Catalog + optional file bodies.
    if refresh_catalog and hub_roots:
        from ide_storage.catalog import refresh_catalog as _refresh

        cat = _refresh(project_id, roots=hub_roots)
        report["catalog"] = cat
        actions.append(f"catalog: {cat.get('files', 0)} files, {cat.get('changed', 0)} changed")
    elif refresh_catalog:
        report["catalog"] = {"skipped": True, "reason": "no project root on the share is readable by the hub"}

    cited = [p for p in (cited_paths or []) if p]
    if not cited and chat_id:
        cited = _cited_from_chat(chat_id, hub_roots)
    resolvable = [p for p in cited if (to_hub_path(p) or "") and os.path.isfile(to_hub_path(p) or "")]
    report["cited_paths"] = resolvable
    if resolvable and ingest_cited:
        from ide_storage.catalog import ingest_files

        ing = ingest_files(project_id, resolvable, reason="howl", howl_id=howl_id)
        report["ingest"] = ing
        with db_conn() as conn:
            conn.cursor().execute("UPDATE howls SET files_ingested = ? WHERE id = ?", (len(ing["ingested"]), howl_id))
            conn.commit()
        actions.append(f"ingested {len(ing['ingested'])} file bodies ({ing['chunks']} chunks)")
    elif resolvable:
        offers.append({
            "kind": "ingest_files",
            "why": f"{len(resolvable)} file(s) cited in this chat exist on the share but their bodies are not in RAG",
            "how": f"POST {_public_base()}/api/ingest-files {{project_id: {project_id}, paths: [...], howl_id: {howl_id}}}",
            "paths": resolvable[:20],
        })

    # 7) Mirrors: Obsidian vault + wiki.
    from ide_storage.mirrors import refresh_mirrors

    report["mirrors"] = refresh_mirrors(project_id, howl_id=howl_id)
    if report["mirrors"].get("vault", {}).get("howl_note"):
        actions.append("wrote Obsidian notes")

    # 8) Standing offers.
    offers.append({"kind": "start_job", "why": "connectors can watch a deploy or pull a model for you",
                   "how": f"POST {_public_base()}/api/jobs {{project_id: {project_id}, kind: ..., connector: ...}}"})

    report["ok"] = True
    report["howl_url"] = f"{_public_base()}/?project={project_id}"
    report["summary"] = _paragraph(report)
    return report


def share_git_dir() -> str:
    from ide_storage.paths import share_root

    return os.environ.get("WOLF_GIT_DIR") or f"{share_root()}/wolf-leader/git"


def ensure_share_remote(slug: str) -> dict[str, Any]:
    """Bare repo ``<share>/wolf-leader/git/<slug>.git``; created if missing.

    Returns the path in every spelling a client may need. ``client`` is filled in
    by the client itself (it knows its own OS); the hub only offers candidates.
    """
    import re
    import subprocess

    safe = re.sub(r"[^a-zA-Z0-9._-]+", "-", slug).strip("-") or "project"
    hub_dir = f"{share_git_dir()}/{safe}.git"
    a = describe_aliases()
    rel = f"wolf-leader/git/{safe}.git"
    out: dict[str, Any] = {
        "hub": hub_dir,
        "windows": (a["windows"].rstrip("\\") + "\\" + rel.replace("/", "\\")) if a.get("windows") else None,
        "unc": (a["unc"].rstrip("\\") + "\\" + rel.replace("/", "\\")) if a.get("unc") else None,
        "mac": (a["mac"].rstrip("/") + "/" + rel) if a.get("mac") else None,
        "created": False,
    }
    if os.path.isdir(os.path.join(hub_dir, "objects")):
        return out
    try:
        os.makedirs(share_git_dir(), exist_ok=True)
        r = subprocess.run(["git", "init", "--bare", "--initial-branch=main", hub_dir],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            out["error"] = (r.stderr or r.stdout).strip()
            return out
        # Samba clients arrive as the share user; keep the repo writable for them.
        subprocess.run(["git", "-C", hub_dir, "config", "core.sharedRepository", "all"],
                       capture_output=True, timeout=10)
        if os.name != "nt":
            subprocess.run(["chmod", "-R", "a+rwX", hub_dir], capture_output=True, timeout=30)
        out["created"] = True
    except Exception as exc:  # noqa: BLE001
        out["error"] = str(exc)
    return out


def _create_project_for_path(workspace_path: str, device_name: str | None) -> dict[str, Any] | None:
    """New folder, new project: name from the folder, unique slug, path alias registered."""
    import re

    base = re.split(r"[\\/]+", workspace_path.strip().rstrip("\\/"))[-1] or "project"
    name = base.replace("_", " ").replace("-", " ").strip().title() or "Project"
    slug_base = re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")[:60] or "project"
    now = _now()
    hub_path = to_hub_path(workspace_path) or workspace_path
    with db_conn() as conn:
        cur = conn.cursor()
        slug = slug_base
        n = 2
        while True:
            cur.execute("SELECT 1 FROM projects WHERE slug = ?", (slug,))
            if not cur.fetchone():
                break
            slug = f"{slug_base}-{n}"
            n += 1
        cur.execute(
            """
            INSERT INTO projects (name, path, description, slug, status, created_at, updated_at, metadata)
            VALUES (?, ?, ?, ?, 'active', ?, ?, ?)
            """,
            (name, hub_path, f"Created by /wolfhowl from {workspace_path}", slug, now, now,
             json.dumps({"created_by": "wolfhowl", "device_name": device_name})),
        )
        pid = int(cur.lastrowid)
        conn.commit()
    register_project_path(pid, workspace_path, kind="workspace", device_name=device_name)
    return {"id": pid, "slug": slug, "name": name}


def _howl_summary(save: dict[str, Any]) -> str:
    review = (save.get("checkpoint_review") or {}).get("honest_summary")
    parts = []
    if save.get("pickup_prompt"):
        parts.append(str(save["pickup_prompt"]).strip())
    if review:
        parts.append(review)
    return "\n".join(parts)[:4000]


def _cited_from_chat(chat_id: int, roots: list[str]) -> list[str]:
    from ide_storage.catalog import cited_paths

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT content FROM messages WHERE chat_id = ? ORDER BY id", (chat_id,))
        texts = [r["content"] for r in cur.fetchall()]
    return cited_paths(texts, project_roots=roots)


def _paragraph(report: dict[str, Any]) -> str:
    save = report.get("save") or {}
    name = save.get("project_name") or save.get("project_slug") or "project"
    bits = [f"Howl recorded for **{name}**" + (f" (howl #{report['howl_id']})" if report.get("howl_id") else "") + "."]
    if report.get("actions"):
        bits.append("Did: " + "; ".join(report["actions"]) + ".")
    g = report.get("git") or {}
    if g.get("commit"):
        bits.append(f"Git {g.get('branch') or ''} @ `{str(g['commit'])[:8]}`" + (f", {g['dirty_files']} dirty" if g.get("dirty_files") else "") + ".")
    if report.get("offers"):
        bits.append("Can also (ask first): " + "; ".join(o["kind"].replace("_", " ") for o in report["offers"]) + ".")
    if report.get("note"):
        bits.append(report["note"])
    return " ".join(bits)


# ------------------------------------------------------------------------- eat
def run_eat(
    *,
    slug: str | None = None,
    project_id: int | None = None,
    workspace_path: str | None = None,
    device_name: str | None = None,
    since: str | None = None,
    query: str | None = None,
) -> dict[str, Any]:
    from ide_storage.hub import resolve_project

    project = None
    if project_id is not None:
        with db_conn() as conn:
            cur = conn.cursor()
            cur.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cur.fetchone()
            project = dict(row) if row else None
    if project is None and (slug or workspace_path):
        project = resolve_project(slug=slug, path=workspace_path)
    if project is None:
        return {
            "ok": False,
            "error": "no project matched; pass slug=<slug> or a workspace_path that is registered",
            "projects": _project_list(),
        }
    pid = int(project["id"])

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM v_project_recall WHERE id = ?", (pid,))
        rec = dict(cur.fetchone() or {})
        cur.execute(
            """
            SELECT id, chat_id, device_name, workspace_path, summary, actions, offers,
                   git_commit, git_branch, git_remote, memories_added, files_ingested, created_at
            FROM howls WHERE project_id = ? {since} ORDER BY created_at DESC LIMIT 10
            """.format(since="AND created_at > ?" if since else ""),
            (pid, since) if since else (pid,),
        )
        howls = [dict(r) for r in cur.fetchall()]
        cur.execute(
            "SELECT DISTINCT path, reason FROM file_chunks WHERE project_id = ? ORDER BY path LIMIT 50",
            (pid,),
        )
        ingested = [dict(r) for r in cur.fetchall()]

    for h in howls:
        for k in ("actions", "offers"):
            try:
                h[k] = json.loads(h[k]) if isinstance(h.get(k), str) else (h.get(k) or [])
            except (json.JSONDecodeError, TypeError):
                h[k] = []

    for k in ("paths", "memories", "howls", "sessions", "open_jobs", "left_off"):
        v = rec.get(k)
        if isinstance(v, str):
            try:
                rec[k] = json.loads(v)
            except (json.JSONDecodeError, TypeError):
                pass

    related: list[dict[str, Any]] = []
    try:
        from ide_storage.embed_index import neighbors_for

        related = [
            {k: h.get(k) for k in ("kind", "id", "title", "slug", "similarity", "content")}
            for h in neighbors_for("project", pid, kinds=("project", "howl", "memory"), limit=8)
        ]
    except Exception:
        related = []

    search_hits: list[dict[str, Any]] = []
    if query:
        try:
            from ide_storage.search_ops import hybrid_search

            res = hybrid_search(query, limit=40)
            search_hits = [
                r for r in res.get("results", [])
                if r.get("project_id") in (None, pid) or r.get("kind") == "project"
            ][:10]
        except Exception as exc:  # noqa: BLE001
            search_hits = [{"error": str(exc)}]

    # Offers for the puller.
    offers: list[dict[str, Any]] = []
    latest = howls[0] if howls else None
    local_alias = None
    if workspace_path:
        for p in rec.get("paths") or []:
            if device_name and p.get("device_name") == device_name:
                local_alias = p["path"]
    if latest and latest.get("git_commit"):
        offers.append({
            "kind": "git_pull",
            "why": f"latest howl is at {str(latest['git_commit'])[:8]} on {latest.get('git_branch') or 'unknown branch'}",
            "how": f"git -C <your checkout of {rec.get('slug')}> pull" if not local_alias else f"git -C \"{local_alias}\" pull",
        })
    if workspace_path and not local_alias:
        offers.append({
            "kind": "register_path",
            "why": "this machine's path for the project is not registered yet",
            "how": "run /wolfhowl once from this folder, or POST /api/projects/{id}/paths".replace("{id}", str(pid)),
        })
    if ingested:
        offers.append({"kind": "read_files", "why": f"{len(ingested)} file bodies are in RAG for this project",
                       "how": f"GET {_public_base()}/api/search?q=<question>&project_id={pid}&kinds=chunk,catalog"})
    for j in rec.get("open_jobs") or []:
        offers.append({"kind": "job_status", "why": f"open job #{j['id']} {j['kind']} is {j['state']}",
                       "how": f"GET {_public_base()}/api/jobs/{j['id']}"})
    offers.append({"kind": "pull_model", "why": "a model host connector can stage a model for this client",
                   "how": f"POST {_public_base()}/api/jobs {{kind: 'model_pull', connector: '<name>', target: '<model>'}}"})

    slug_ = rec.get("slug") or project.get("slug")
    brief = {
        "project": {k: rec.get(k) for k in ("id", "slug", "name", "description", "status", "tags", "updated_at")},
        "paths": rec.get("paths") or [],
        "left_off": rec.get("left_off"),
        "memories": rec.get("memories") or [],
        "howls": howls,
        "sessions": rec.get("sessions") or [],
        "open_jobs": rec.get("open_jobs") or [],
        "ingested_files": ingested,
        "related": related,
        "search": search_hits,
        "aliases": describe_aliases(),
        "links": {
            "ui": f"{_public_base()}/?project={pid}",
            "brief": f"{_public_base()}/api/projects/{slug_}/agent-brief",
            "wiki": f"{_public_base()}/wiki/projects/{slug_}",
        },
    }
    return {
        "ok": True,
        "kind": "eat",
        "project_id": pid,
        "slug": slug_,
        "brief": brief,
        "offers": offers,
        "summary": _eat_paragraph(brief),
    }


def _eat_paragraph(brief: dict[str, Any]) -> str:
    p = brief["project"]
    left = brief.get("left_off") or {}
    howls = brief.get("howls") or []
    mems = brief.get("memories") or []
    bits = [f"**{p.get('name') or p.get('slug')}** (`{p.get('slug')}`)."]
    if p.get("description"):
        bits.append(str(p["description"]).strip().splitlines()[0][:200])
    if left.get("summary"):
        bits.append(f"Left off: {str(left['summary']).strip()[:300]}")
    if howls:
        h = howls[0]
        bits.append(
            f"Last howl {LT.fmt(h.get('created_at'), str(h.get('created_at'))[:16])} from {h.get('device_name') or 'unknown device'}"
            + (f" at `{str(h['git_commit'])[:8]}`" if h.get("git_commit") else "")
            + f"; {len(howls)} recent howl(s)."
        )
    if mems:
        bits.append(f"{len(mems)} active memories loaded.")
    if brief.get("open_jobs"):
        bits.append(f"{len(brief['open_jobs'])} open job(s).")
    return " ".join(bits)


def _project_list() -> list[dict[str, Any]]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, slug, name FROM projects WHERE COALESCE(status,'active') != 'archived' ORDER BY updated_at DESC LIMIT 50"
        )
        return [dict(r) for r in cur.fetchall()]


# ---------------------------------------------------------------------- guides
def howl_guide() -> str:
    a = describe_aliases()
    base = _public_base()
    return f"""# /wolfhowl — broadcast this session to {PRODUCT_NAME}

You are the agent. This is a suggested plate, not a script. Skip a step if it clearly does not apply, say so in one line.

## Default plate (no questions)
1. Work out the project: use the workspace folder path you are in. Any spelling is fine — `{a['windows']}…`, `{a['hub']}…`, `{a['nas']}…`, UNC — the hub maps them. If the folder is new to the hub, the howl creates the project and registers this path.
2. Collect git state locally (cheap, and you can see the repo even if the hub cannot): `git rev-parse HEAD`, `git rev-parse --abbrev-ref HEAD`, `git remote get-url origin`, `git status --porcelain | wc -l`.
3. POST `{base}/api/howl` with:
   - `session_id` (Cursor) **or** `messages` (any agent), `title`, `workspace_path`, `device_name` (hostname),
   - `git: {{commit, branch, remote, dirty_files, is_repo}}`,
   - optionally `cited_paths` (files this chat attached/changed) and `ingest_cited: true` **only if the user already said yes**.
4. The hub saves the conversation (same as /save), extracts memories, embeds everything into pgvector, records the howl, refreshes the file catalog for the project's folder on the share, and writes the Obsidian notes to `{a['windows']}wolf-leader\\vault`.
5. If the repo has no `origin`, the hub creates a bare repo at `{a['windows']}wolf-leader\\git\\<slug>.git` (= `{a['hub']}/wolf-leader/git/<slug>.git`) and returns it as `git_remote`. The bundled runner sets `origin` to it for you (config only; nothing is pushed). Never point a project at GitHub or any other host unless the user asks.
6. Reply with the hub's `summary` paragraph, verbatim, then the offers.

## Offers (ask, never assume)
The response has `offers[]`. Present the relevant ones as a short question:
- `git_commit` / `git_init` / `git_push` — commit and push the project repo to its `origin` (the share) so the howl points at a real SHA. If yes, run the git commands yourself, then PUT `{base}/api/howls/<id>/git` with the new commit/branch.
- `ingest_files` — chunk + embed the bodies of cited/changed files so /wolfeat and search can quote them. If yes: POST `{base}/api/ingest-files` with `{{project_id, paths, howl_id}}`.
- `move_to_share` — the folder is not on `{a['windows']}`; suggest cloning there.
- `start_job` — connectors: watch a deploy, pull a model. POST `{base}/api/jobs`.

## Never
Do not delete, force-push, reset, or touch anything outside the project folder and `{a['windows']}wolf-leader\\`. /save is unchanged; use it when you want a light checkpoint without git/catalog/vault.
"""


def eat_guide() -> str:
    a = describe_aliases()
    base = _public_base()
    return f"""# /wolfeat — pull the latest context for this project onto this machine

You are the agent. Suggested plate; adapt.

## Default plate
1. Identify the project from the folder you are in (any alias: `{a['windows']}…`, `{a['hub']}…`, `{a['nas']}…`) or from the slug the user names.
2. GET `{base}/api/eat?workspace_path=<folder>&device_name=<hostname>` (or `&slug=<slug>`; add `&q=<question>` to also run a hybrid search).
3. Read `brief`: `left_off`, `memories`, `howls` (newest first, with git SHA + which machine sent it), `open_jobs`, `related` (vector neighbours across projects), `ingested_files`.
4. Reply with the hub's `summary` paragraph, then the two or three facts that matter for what the user is about to do. Do not dump the whole brief.

## Offers (ask, never assume)
- `git_pull` — bring this machine's checkout to the SHA in the latest howl. If the project lives on the shared drive you may already be looking at the same files; only pull a separate clone.
- `register_path` — if this machine's folder is not in `brief.paths`, a `/wolfhowl` from here registers it.
- `read_files` — search `kinds=chunk,catalog` for the file bodies already in RAG; offer to fetch more with `ingest_files` if the answer is not there.
- `job_status` / `pull_model` — connectors (`GET {base}/api/jobs`, `POST {base}/api/jobs`).

## Never
No writes to the hub from /wolfeat except registering a path or starting a job the user asked for. Nothing on the NAS or Proxmox is stopped, restarted, or deleted.
"""
