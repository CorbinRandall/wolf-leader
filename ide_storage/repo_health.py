"""Where each project's files are versioned, and whether the hub's own content is safe.

One read model for the app's Repos page:

* per project: has a git repo or not, last commit, uncommitted changes, which machine
* which projects have files but no repo yet
* folders that several projects share (a save from there cannot pick a project)
* the notes vaults: uncommitted changes, and a scheduled commit so they keep a history
* the last off-site copy of the repos and the database
"""
from __future__ import annotations

import glob
import logging
import os
import subprocess
import threading
from datetime import datetime, timezone
from typing import Any

from ide_storage.db import db_conn, get_vault_dir
from ide_storage.paths import _norm, share_root

logger = logging.getLogger(__name__)

# Repo hosts where "private" cannot be assumed from the URL alone.
_PUBLIC_HOSTS = ("github.com", "gitlab.com", "bitbucket.org")


def _now() -> str:
    return datetime.utcnow().isoformat()


def _git(repo: str, *args: str, timeout: int = 30) -> str | None:
    """Run git in ``repo``; None on any failure. Never raises."""
    try:
        r = subprocess.run(
            ["git", "-c", f"safe.directory={repo}", "-C", repo, *args],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:  # noqa: BLE001
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def share_git_dir() -> str:
    return os.environ.get("WOLF_GIT_DIR") or f"{share_root()}/wolf-leader/git"


def share_repo(slug: str | None) -> dict[str, Any]:
    """The project's bare repo on the share, if the hub has one with commits."""
    import re

    if not slug:
        return {"exists": False, "commits": 0}
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "-", slug).strip("-")
    path = f"{share_git_dir()}/{safe}.git"
    if not os.path.isdir(os.path.join(path, "objects")):
        return {"exists": False, "commits": 0}
    count = _git(path, "rev-list", "--all", "--count")
    info: dict[str, Any] = {"exists": True, "path": path, "commits": int(count) if (count or "").isdigit() else 0}
    if info["commits"]:
        last = _git(path, "log", "-1", "--all", "--format=%H%x1f%cI%x1f%s")
        if last:
            sha, when, subject = (last.split("\x1f") + ["", "", ""])[:3]
            info.update({"last_commit": sha, "last_commit_at": when, "last_subject": subject})
    return info


def _is_home_folder(path: str) -> bool:
    """A home directory or filesystem root: where someone happened to be, not a project's folder."""
    import re

    n = _norm(path)
    return n in ("", "/", "/root", "/home") or bool(
        re.fullmatch(r"/(users|home)/[^/]+", n) or re.fullmatch(r"[a-z]:(/users/[^/]+)?", n)
    )


def _holds_notes_repo(folder: str, notes: list[str]) -> bool:
    """True when a notes vault under git lives inside this folder (same person, any mount spelling)."""
    tail = "/".join(_norm(folder).split("/")[-2:])
    return bool(tail) and any(_norm(repo).endswith(f"/{tail}/vault") or _norm(repo).endswith(f"/{tail}") for repo in notes)


def _setup_prompt(project: dict[str, Any], folder: str) -> str:
    name, slug = project.get("name") or project.get("slug"), project.get("slug")
    return (
        f"Put the Wolf Leader project \"{name}\" (slug `{slug}`) under version control.\n\n"
        f"1. Go to its folder: {folder}\n"
        f"2. Run the wolfhowl skill's runner with `{slug} --create-repo --plan` and show me what it would commit "
        "and what it would leave out. Secrets (.env, keys), databases, dependencies and files over 25 MB are left out "
        "automatically; tell me if anything else looks like a secret or data.\n"
        f"3. After I say OK, run it again with `{slug} --create-repo`. It runs git init, commits, and pushes to "
        "this project's private repo on the Wolf Leader hub.\n"
        "4. If the wolfhowl skill is not installed on this machine, connect it to Wolf Leader first (/wolfeat --setup).\n\n"
        "Do not push to GitHub or any other host unless I ask."
    )


def project_repo_status() -> list[dict[str, Any]]:
    """Every active project with its version-control state, most in need of attention first."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.slug, p.name, p.status, p.compose_path,
                   (SELECT COUNT(*) FROM memories m WHERE m.project_id = p.id) AS memories
            FROM projects p
            WHERE COALESCE(p.status, 'active') != 'archived' AND p.slug IS NOT NULL AND p.slug != ''
            ORDER BY p.name
            """
        )
        projects = [dict(r) for r in cur.fetchall()]
        cur.execute("SELECT id, project_id, path, kind, device_name FROM project_paths ORDER BY id")
        paths: dict[int, list[dict[str, Any]]] = {}
        owners: dict[str, set[int]] = {}
        for row in cur.fetchall():
            row = dict(row)
            paths.setdefault(int(row["project_id"]), []).append(row)
            owners.setdefault(_norm(row["path"]), set()).add(int(row["project_id"]))
        cur.execute(
            """
            SELECT DISTINCT ON (project_id) project_id, git_commit, git_branch, git_remote,
                   git_dirty_files, device_name, workspace_path, created_at
            FROM howls
            WHERE git_commit IS NOT NULL OR git_remote IS NOT NULL
            ORDER BY project_id, created_at DESC
            """
        )
        howls = {int(r["project_id"]): dict(r) for r in cur.fetchall()}
    active_ids = {int(p["id"]) for p in projects}
    notes = notes_repos()

    out: list[dict[str, Any]] = []
    for project in projects:
        pid = int(project["id"])
        howl = howls.get(pid) or {}
        repo = share_repo(project["slug"])
        real = [p for p in paths.get(pid, []) if not _is_home_folder(p["path"])]
        own = [p for p in real if len(owners.get(_norm(p["path"]), set()) & active_ids) <= 1]
        shared = [p for p in real if p not in own]
        remote = howl.get("git_remote")
        item: dict[str, Any] = {
            "project_id": pid,
            "slug": project["slug"],
            "name": project["name"],
            "status": project.get("status"),
            "memories": int(project.get("memories") or 0),
            "folders": [p["path"] for p in own],
            "shared_folders": [p["path"] for p in shared],
            "remote": remote,
            "branch": howl.get("git_branch"),
            "last_commit": howl.get("git_commit") or repo.get("last_commit"),
            "last_commit_at": repo.get("last_commit_at"),
            "last_subject": repo.get("last_subject"),
            "dirty_files": howl.get("git_dirty_files"),
            "device_name": howl.get("device_name"),
            "howled_at": howl.get("created_at"),
            "share_repo": repo,
            "remote_is_public_host": bool(remote and any(h in remote for h in _PUBLIC_HOSTS)),
        }
        # A remote with nothing ever committed to it is not version history.
        if howl.get("git_commit") or repo.get("commits"):
            item["state"] = "versioned"
        elif any(_holds_notes_repo(p["path"], notes) for p in own):
            vault = next(r for r in notes if any(_holds_notes_repo(p["path"], [r]) for p in own))
            last = (_git(vault, "log", "-1", "--format=%H%x1f%cI%x1f%s") or "").split("\x1f")
            item.update({
                "state": "versioned", "why": "Notes vault under git", "remote": _git(vault, "remote", "get-url", "origin"),
                "last_commit": last[0] or None if last else None,
                "last_commit_at": last[1] if len(last) > 1 else None,
                "last_subject": last[2] if len(last) > 2 else None,
            })
        elif own:
            # Prefer the deployed stack's folder: that is the thing with files to lose.
            compose = next((p["path"] for p in own if p["kind"] == "compose"), None)
            folder = compose or own[0]["path"]
            item.update({
                "state": "needs_repo",
                "folder": folder,
                "why": "Compose stack with no version history" if compose else "Has a folder but no git repo",
                "setup_prompt": _setup_prompt(project, folder),
            })
        elif shared:
            item.update({"state": "shared_folder", "why": "Only lives in a folder shared with other projects"})
        else:
            item["state"] = "knowledge_only"
        out.append(item)

    order = {"needs_repo": 0, "shared_folder": 1, "versioned": 2, "knowledge_only": 3}
    out.sort(key=lambda i: (order[i["state"]], -i["memories"], i["name"].lower()))
    return out


def shared_folders() -> list[dict[str, Any]]:
    """Folders registered to more than one active project."""
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT pp.path, p.id, p.slug, p.name
            FROM project_paths pp
            JOIN projects p ON p.id = pp.project_id
            WHERE COALESCE(p.status, 'active') != 'archived'
            ORDER BY pp.path, p.name
            """
        )
        groups: dict[str, dict[str, Any]] = {}
        for row in cur.fetchall():
            row = dict(row)
            group = groups.setdefault(_norm(row["path"]), {"path": row["path"], "projects": {}})
            group["projects"].setdefault(int(row["id"]), {"id": int(row["id"]), "slug": row["slug"], "name": row["name"]})
    out = [
        {"path": g["path"], "projects": list(g["projects"].values())}
        for g in groups.values() if len(g["projects"]) > 1
    ]
    out.sort(key=lambda g: (-len(g["projects"]), g["path"]))
    return out


def unlink_folder(project_id: int, path: str) -> dict[str, Any]:
    """Stop treating ``path`` as this project's folder (aliases and the legacy columns)."""
    target = _norm(path)
    if not target:
        raise ValueError("path is required")
    removed = 0
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, path FROM project_paths WHERE project_id = ?", (project_id,))
        for row in cur.fetchall():
            if _norm(row["path"]) == target:
                cur.execute("DELETE FROM project_paths WHERE id = ?", (row["id"],))
                removed += 1
        cur.execute("SELECT path, compose_path FROM projects WHERE id = ?", (project_id,))
        row = cur.fetchone()
        if row is None:
            raise LookupError("project not found")
        # The legacy columns are re-mirrored into the alias table at every boot; clear them too.
        if _norm(row["path"] or "") == target:
            cur.execute("UPDATE projects SET path = '', updated_at = ? WHERE id = ?", (_now(), project_id))
            removed += 1
        if _norm(row["compose_path"] or "") == target:
            cur.execute("UPDATE projects SET compose_path = NULL, updated_at = ? WHERE id = ?", (_now(), project_id))
            removed += 1
        conn.commit()
    return {"ok": True, "project_id": project_id, "path": path, "removed": removed}


# ------------------------------------------------------------------- notes vaults
def notes_repos() -> list[str]:
    """Git repos holding notes: this hub's vault, and each person's vault on the share."""
    found: list[str] = []
    candidates = [get_vault_dir() or ""]
    candidates += sorted(glob.glob(os.path.join(share_root(), "*", "wolfleader", "vault")))
    candidates += [p for p in (os.environ.get("WOLF_NOTES_REPOS") or "").split(os.pathsep) if p]
    for path in candidates:
        path = os.path.realpath(path) if path else ""
        if path and path not in found and os.path.isdir(os.path.join(path, ".git")):
            found.append(path)
    return found


def _owner_label(repo: str) -> str:
    parts = repo.rstrip("/").split("/")
    # <share>/<Person>/wolfleader/vault -> "Person"
    if len(parts) >= 3 and parts[-2] == "wolfleader":
        return parts[-3]
    return parts[-1]


def notes_status() -> list[dict[str, Any]]:
    out = []
    for repo in notes_repos():
        dirty = _git(repo, "status", "--porcelain")
        last = _git(repo, "log", "-1", "--format=%H%x1f%cI%x1f%s") or ""
        sha, when, subject = (last.split("\x1f") + ["", "", ""])[:3]
        out.append({
            "owner": _owner_label(repo),
            "path": repo,
            "uncommitted": len([ln for ln in (dirty or "").splitlines() if ln.strip()]),
            "last_commit": sha or None,
            "last_commit_at": when or None,
            "last_subject": subject or None,
            "remote": _git(repo, "remote", "get-url", "origin"),
        })
    return out


def _share_push_target(remote: str) -> str | None:
    """The hub's own bare repo behind ``remote``, or None. Never an outside host on a timer.

    ``origin`` is often spelled the way the host or a client sees the share, so
    match the repo by name inside the hub's git folder instead of by prefix.
    """
    if not remote or "://" in remote or "@" in remote:
        return None
    candidate = os.path.join(share_git_dir(), os.path.basename(remote.rstrip("/\\")))
    return candidate if os.path.isdir(os.path.join(candidate, "objects")) else None


_notes_lock = threading.Lock()
MAX_NOTE_FILE_MB = 25


def commit_notes() -> list[dict[str, Any]]:
    """Commit whatever changed in each notes vault, so notes keep a history. Never forces or resets."""
    results: list[dict[str, Any]] = []
    if not _notes_lock.acquire(blocking=False):
        return [{"skipped": "a notes commit is already running"}]
    try:
        for repo in notes_repos():
            result: dict[str, Any] = {"owner": _owner_label(repo), "path": repo, "committed": 0}
            results.append(result)
            if _git(repo, "config", "--bool", "autosave.skip") == "true":
                result["skipped"] = "autosave.skip is set"
                continue
            gitdir = os.path.join(repo, ".git")
            busy = next((m for m in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply")
                         if os.path.exists(os.path.join(gitdir, m))), None)
            if busy:
                result["skipped"] = f"{busy} in progress"
                continue
            if _git(repo, "symbolic-ref", "-q", "HEAD") is None:
                result["skipped"] = "detached HEAD"
                continue
            changed = [ln[3:].strip().strip('"') for ln in (_git(repo, "status", "--porcelain") or "").splitlines() if ln.strip()]
            if not changed:
                continue
            too_big = [
                f for f in changed
                if os.path.isfile(os.path.join(repo, f)) and os.path.getsize(os.path.join(repo, f)) > MAX_NOTE_FILE_MB * 1024 * 1024
            ]
            if too_big:
                result["skipped"] = f"file over {MAX_NOTE_FILE_MB} MB is not in .gitignore: {too_big[0]}"
                continue
            if _git(repo, "add", "-A") is None:
                result["error"] = "git add failed"
                continue
            staged = [ln for ln in (_git(repo, "diff", "--cached", "--name-only") or "").splitlines() if ln.strip()]
            if not staged:
                continue
            done = _git(
                repo, "-c", "user.name=Wolf Leader", "-c", "user.email=notes@wolf-leader.local",
                "commit", "-q", "-m", f"notes: {len(staged)} changed file(s)",
                "-m", "Scheduled commit by the Wolf Leader hub so notes keep a history.",
            )
            if done is None:
                result["error"] = "git commit failed"
                continue
            result["committed"] = len(staged)
            target = _share_push_target(_git(repo, "remote", "get-url", "origin") or "")
            if target:
                result["pushed"] = _git(repo, "push", "-q", target, "HEAD", timeout=120) is not None
    finally:
        _notes_lock.release()
    return results


def start_notes_schedule() -> None:
    """Commit the notes vaults every WOLF_NOTES_AUTOSAVE_MINUTES (default 30; 0 turns it off)."""
    try:
        minutes = float(os.environ.get("WOLF_NOTES_AUTOSAVE_MINUTES", "30"))
    except ValueError:
        minutes = 30
    if minutes <= 0:
        return

    def loop() -> None:
        stop = threading.Event()
        while not stop.wait(minutes * 60):
            try:
                saved = [r for r in commit_notes() if r.get("committed")]
                if saved:
                    logger.info("notes committed: %s", {r["owner"]: r["committed"] for r in saved})
            except Exception:  # noqa: BLE001
                logger.exception("scheduled notes commit failed")

    threading.Thread(target=loop, name="notes-autosave", daemon=True).start()


# ------------------------------------------------------------------ off-site copy
def record_offsite(report: dict[str, Any]) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO offsite_copies (device_name, destination, repos, dump_name, bytes, ok, detail, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                (report.get("device_name") or "")[:200], (report.get("destination") or "")[:500],
                int(report.get("repos") or 0), (report.get("dump_name") or "")[:200] or None,
                int(report.get("bytes") or 0), 1 if report.get("ok", True) else 0,
                (report.get("detail") or "")[:1000] or None, _now(),
            ),
        )
        conn.commit()
    return offsite_status()


def offsite_status() -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM offsite_copies WHERE ok = 1 ORDER BY created_at DESC LIMIT 1")
        good = cur.fetchone()
        cur.execute("SELECT * FROM offsite_copies ORDER BY created_at DESC LIMIT 1")
        latest = cur.fetchone()
    good, latest = (dict(good) if good else None), (dict(latest) if latest else None)
    age_hours = None
    if good:
        try:
            then = datetime.fromisoformat(good["created_at"]).replace(tzinfo=timezone.utc)
            age_hours = round((datetime.now(timezone.utc) - then).total_seconds() / 3600, 1)
        except ValueError:
            pass
    return {
        "last_good": good,
        "latest": latest,
        "age_hours": age_hours,
        # A daily job that has not reported for two days needs a look.
        "stale": good is None or (age_hours is not None and age_hours > 48),
        "last_failed": bool(latest and not latest.get("ok")),
    }


def overview(public_url: str = "") -> dict[str, Any]:
    projects = project_repo_status()
    counts: dict[str, int] = {}
    for item in projects:
        counts[item["state"]] = counts.get(item["state"], 0) + 1
    base = public_url.rstrip("/")
    return {
        "projects": projects,
        "counts": counts,
        "shared_folders": shared_folders(),
        "notes": notes_status(),
        "notes_schedule_minutes": float(os.environ.get("WOLF_NOTES_AUTOSAVE_MINUTES", "30") or 0),
        "offsite": offsite_status(),
        "offsite_install": (
            f"curl -fsSL {base}/api/offsite-mirror.sh -o ~/wolf-leader-offsite-mirror.sh && "
            "bash ~/wolf-leader-offsite-mirror.sh --install --host <ssh-name-of-the-hub-server>"
        ) if base else "",
    }
