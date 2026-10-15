#!/usr/bin/env python3
"""Build the self-contained hub that installers put on a computer for local mode.

    python installer/runtime/build_runtime.py --target mac-arm64|mac-x86_64|windows-x86_64|linux-x86_64 \
        [--out dist/runtime/<target>] [--models-from DIR]

The result needs nothing installed on the computer it runs on:

    <out>/python/       a standalone Python (python-build-standalone) with the hub's packages
    <out>/app/          ide_storage plus the built-in skills
    <out>/models/       the search model, so search works offline from the first minute
    <out>/run-hub       (run-hub.cmd on Windows) starts the hub: python -m ide_storage.local

Run it on the system it is for (the packages it installs are that system's own builds). A Mac on
Apple silicon can also build mac-x86_64 through Rosetta.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE = "20260924"
PYTHON = "3.12.14"
TRIPLES = {
    "mac-arm64": "aarch64-apple-darwin",
    "mac-x86_64": "x86_64-apple-darwin",
    "windows-x86_64": "x86_64-pc-windows-msvc",
    "linux-x86_64": "x86_64-unknown-linux-gnu",
}
BASE = f"https://github.com/astral-sh/python-build-standalone/releases/download/{RELEASE}"
MODEL = "sentence-transformers/all-MiniLM-L6-v2"
PRUNE_DIRS = {"__pycache__", "tests", "test", "idlelib", "tkinter", "turtledemo", "ensurepip", "lib2to3"}


def fetch(url: str, dest: Path) -> Path:
    if not dest.exists():
        print(f"  downloading {url.rsplit('/', 1)[-1]}", flush=True)
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".part")
        with urllib.request.urlopen(url, timeout=300) as resp, open(tmp, "wb") as out:
            shutil.copyfileobj(resp, out)
        tmp.replace(dest)
    return dest


def checked_python(target: str, cache: Path) -> Path:
    name = f"cpython-{PYTHON}+{RELEASE}-{TRIPLES[target]}-install_only_stripped.tar.gz"
    archive = fetch(f"{BASE}/{name}", cache / name)
    sums = fetch(f"{BASE}/SHA256SUMS", cache / f"SHA256SUMS-{RELEASE}").read_text().splitlines()
    want = next((line.split()[0] for line in sums if line.strip().endswith(name)), None)
    have = hashlib.sha256(archive.read_bytes()).hexdigest()
    if want != have:
        archive.unlink()
        raise SystemExit(f"checksum mismatch for {name}; deleted it, run again")
    return archive


def python_exe(out: Path, target: str) -> Path:
    return out / "python" / ("python.exe" if target.startswith("windows") else "bin/python3")


def run(args: list[str], **kw) -> None:
    print("  $ " + " ".join(str(a) for a in args), flush=True)
    subprocess.run([str(a) for a in args], check=True, **kw)


def prune(tree: Path) -> None:
    for path in sorted(tree.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if path.is_dir() and path.name in PRUNE_DIRS:
            shutil.rmtree(path, ignore_errors=True)
        elif path.is_file() and path.suffix in (".pyc", ".pyo"):
            path.unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", required=True, choices=sorted(TRIPLES))
    ap.add_argument("--out", type=Path)
    ap.add_argument("--cache", type=Path, default=ROOT / "dist" / "runtime-cache")
    ap.add_argument("--models-from", type=Path, help="reuse a models folder built for another target")
    args = ap.parse_args()
    out = (args.out or ROOT / "dist" / "runtime" / args.target).resolve()

    print(f"==> Hub runtime for {args.target} -> {out}")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    with tarfile.open(checked_python(args.target, args.cache)) as tar:
        tar.extractall(out, filter="data")  # the archive's top folder is python/
    py = python_exe(out, args.target)
    prefix = ["arch", "-x86_64"] if args.target == "mac-x86_64" and platform.machine() == "arm64" else []

    print("==> Packages")
    run([*prefix, py, "-m", "pip", "install", "--no-cache-dir", "--disable-pip-version-check", "--quiet",
         "-r", ROOT / "requirements-local.txt", "-r", ROOT / "requirements-embeddings.txt"])

    print("==> Hub source")
    app = out / "app"
    shutil.copytree(ROOT / "ide_storage", app / "ide_storage",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))
    shutil.copytree(ROOT / "examples" / "shared" / "skills", app / "examples" / "shared" / "skills",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))

    print("==> Search model")
    models = out / "models"
    if args.models_from and args.models_from.is_dir():
        shutil.copytree(args.models_from, models)
    else:
        env = dict(os.environ, PYTHONPATH=str(app), FASTEMBED_CACHE_PATH=str(models))
        run([*prefix, py, "-c", f"from fastembed import TextEmbedding; TextEmbedding({MODEL!r}, cache_dir={str(models)!r})"],
            env=env)

    print("==> Launcher")
    # run_hub.pyw: starts the hub from any working folder, with no console window on Windows.
    (app / "run_hub.pyw").write_text(
        'import os, sys\n'
        'here = os.path.dirname(os.path.abspath(__file__))\n'
        'sys.path.insert(0, here)\n'
        'os.environ.setdefault("WOLF_RUNTIME_MODELS", os.path.join(os.path.dirname(here), "models"))\n'
        'from ide_storage.local import main\n'
        'raise SystemExit(main(sys.argv[1:]))\n')
    if args.target.startswith("windows"):
        (out / "run-hub.cmd").write_text(
            '@echo off\r\nset "HERE=%~dp0"\r\nset "PYTHONPATH=%HERE%app"\r\nset "PYTHONNOUSERSITE=1"\r\n'
            'set "WOLF_RUNTIME_MODELS=%HERE%models"\r\n"%HERE%python\\pythonw.exe" -m ide_storage.local %*\r\n',
            encoding="ascii")
    else:
        launcher = out / "run-hub"
        launcher.write_text(
            '#!/bin/sh\n# Start this computer\'s Wolf Leader hub. Arguments go to ide_storage.local.\n'
            'HERE=$(cd "$(dirname "$0")" && pwd)\n'
            'export PYTHONPATH="$HERE/app" PYTHONNOUSERSITE=1 WOLF_RUNTIME_MODELS="$HERE/models"\n'
            'exec "$HERE/python/bin/python3" -m ide_storage.local "$@"\n')
        launcher.chmod(0o755)

    prune(out / "python")
    (out / "VERSION").write_text(
        (ROOT / "VERSION").read_text().strip() if (ROOT / "VERSION").exists() else
        subprocess.run(["git", "-C", str(ROOT), "describe", "--tags", "--always"], capture_output=True, text=True).stdout.strip() or "dev")

    print("==> Check")
    env = dict(os.environ, PYTHONPATH=str(app), PYTHONNOUSERSITE="1")
    run([*prefix, py, "-c", "import ide_storage.local, ide_storage.main, ide_storage.mcp_server, fastembed; print('imports ok')"],
        env=env)
    size = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    print(f"Built {out} ({size / 1e6:.0f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
