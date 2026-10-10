"""Mirror a project's files to the Wolf Leader share, and pull missing ones back.

push: copies git-tracked + untracked-not-ignored files to <share>/projects/<slug>/,
      registers that folder as a "share" path on the hub (so the file catalog works).
pull: copies files that exist on the share mirror but are missing locally.
      Never overwrites or deletes local files.

Usage: python sync_share.py push|pull [slug]
Share root: $WOLF_LEADER_SHARE, else W:/wolf-leader (Windows) or /srv/wolf/wolf-leader.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def share_root() -> Path | None:
    for c in (os.environ.get("WOLF_LEADER_SHARE"), "W:/wolf-leader", "/srv/wolf/wolf-leader", "/Volumes/wolf/wolf-leader"):
        if c and Path(c).is_dir():
            return Path(c)
    return None


def guess_slug(workspace: str) -> str:
    r = subprocess.run(["git", "-C", workspace, "remote", "get-url", "origin"], capture_output=True, text=True)
    url = r.stdout.strip()
    if url:
        return Path(url.rstrip("/\\")).name.removesuffix(".git")
    return Path(workspace).name.lower().replace(" ", "-")


def repo_files(workspace: str) -> list[str]:
    r = subprocess.run(["git", "-C", workspace, "ls-files", "-co", "--exclude-standard", "-z"],
                       capture_output=True, text=True, check=True)
    return [f for f in r.stdout.split("\0") if f]


def _register(workspace: str, dest: Path) -> None:
    api = os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API") or "http://wolf.local:6971"
    q = urllib.parse.urlencode({"path": workspace})
    pid = json.load(urllib.request.urlopen(f"{api}/api/paths/resolve?{q}", timeout=20)).get("project_id")
    if not pid:
        return
    existing = json.load(urllib.request.urlopen(f"{api}/api/projects/{pid}/paths", timeout=20))
    if any(Path(p["path"]) == dest for p in existing):
        return
    req = urllib.request.Request(f"{api}/api/projects/{pid}/paths", method="POST",
                                 data=json.dumps({"path": str(dest), "kind": "share"}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=20)


def _long(p: Path) -> str:
    """Windows long-path form so deep files don't fail at 260 chars."""
    if os.name != "nt":
        return str(p)
    a = os.path.abspath(str(p))
    if a.startswith("\\\\?\\"):
        return a
    return "\\\\?\\UNC\\" + a[2:] if a.startswith("\\\\") else "\\\\?\\" + a


def push(workspace: str, slug: str | None = None) -> str | None:
    root = share_root()
    if not root:
        return None
    dest = root / "projects" / (slug or guess_slug(workspace))
    for rel in repo_files(workspace):
        src, dst = Path(workspace) / rel, dest / rel
        if not src.is_file():
            continue
        if dst.is_file() and dst.stat().st_size == src.stat().st_size and dst.stat().st_mtime >= src.stat().st_mtime:
            continue
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(_long(src), _long(dst))
        except OSError as exc:
            print(f"share mirror: skipped {rel}: {exc}", file=sys.stderr)
    try:
        _register(workspace, dest)
    except Exception as exc:
        print(f"share path not registered: {exc}", file=sys.stderr)
    return str(dest)


def pull(workspace: str, slug: str | None = None) -> list[str]:
    root = share_root()
    if not root:
        raise SystemExit("share not mounted (set WOLF_LEADER_SHARE)")
    src_root = root / "projects" / (slug or guess_slug(workspace))
    copied = []
    for src in src_root.rglob("*"):
        if not src.is_file() or ".git" in src.relative_to(src_root).parts:
            continue
        dst = Path(workspace) / src.relative_to(src_root)
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(str(dst))
    return copied


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    slug = sys.argv[2] if len(sys.argv) > 2 else None
    ws = os.environ.get("CURSOR_WORKSPACE") or os.getcwd()
    if mode == "push":
        print(push(ws, slug) or "share not mounted; nothing mirrored")
    elif mode == "pull":
        got = pull(ws, slug)
        print(f"pulled {len(got)} missing file(s)")
        for g in got:
            print("  " + g)
    else:
        raise SystemExit(__doc__)
