"""Run the hub on this computer: no Docker, no database server.

    python -m ide_storage.local [--data DIR] [--port 6971] [--mcp-port 6972] [--print-env]

Everything lives in one folder (the database is a single SQLite file next to the notes, skills
and search model), and both servers listen on this computer only. The Wolf Leader app starts
this in the background; it can also be run by hand. Other computers can reach it later through
something like Tailscale, or the data can move to a server hub.

Default folder:
    macOS    ~/Library/Application Support/WolfLeader/hub
    Windows  %LOCALAPPDATA%\\WolfLeader\\hub
    Linux    ~/.local/share/wolf-leader/hub
"""
from __future__ import annotations

import argparse
import os
import signal
import socket
import subprocess
import sys
from pathlib import Path


def default_data_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "WolfLeader" / "hub"
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "WolfLeader" / "hub"
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "wolf-leader" / "hub"


def local_env(data: Path, port: int, mcp_port: int) -> dict[str, str]:
    """Settings for a hub that lives in `data`. Anything already set in the environment wins."""
    db = data / "wolf-leader.db"
    values = {
        "DATABASE_URL": f"sqlite:///{db.as_posix()}",
        "IDE_STORAGE_PROJECTS_DIR": str(data / "projects"),
        "IDE_STORAGE_VAULT_DIR": str(data / "vault"),
        "IDE_STORAGE_SKILLS_DIR": str(data / "skills"),
        "FASTEMBED_CACHE_PATH": str(data / "models"),
        "WOLF_GIT_DIR": str(data / "git"),
        "HOST": "127.0.0.1",
        "MCP_HOST": "127.0.0.1",
        "PORT": str(port),
        "MCP_PORT": str(mcp_port),
        "IDE_STORAGE_PUBLIC_URL": f"http://127.0.0.1:{port}",
        "IDE_STORAGE_MCP_URL": f"http://127.0.0.1:{mcp_port}/mcp",
        "IDE_STORAGE_HOST_LABEL": socket.gethostname().split(".")[0] or "this-computer",
        "WOLF_LOCAL_HUB": "1",
        "WOLF_WIKI_ENABLED": "0",
    }
    return {k: os.environ.get(k) or v for k, v in values.items()}


def seed_models(dest: Path) -> None:
    """Copy the search model that came with the installer, so search works offline at once."""
    source = os.environ.get("WOLF_RUNTIME_MODELS")
    if not source or not Path(source).is_dir() or (dest.is_dir() and any(dest.iterdir())):
        return
    import shutil

    shutil.copytree(source, dest, dirs_exist_ok=True)


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=None, help="folder for everything this hub keeps")
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORT") or 6971))
    ap.add_argument("--mcp-port", type=int, default=int(os.environ.get("MCP_PORT") or 6972))
    ap.add_argument("--print-env", action="store_true", help="print the settings and stop")
    args = ap.parse_args(argv)

    data = (args.data or Path(os.environ.get("WOLF_LOCAL_DATA") or default_data_dir())).expanduser()
    env = local_env(data, args.port, args.mcp_port)
    if args.print_env:
        for key, value in env.items():
            print(f"{key}={value}")
        return 0
    for port in (args.port, args.mcp_port):
        if port_in_use(port):
            print(f"Port {port} is already in use: is a Wolf Leader hub already running?", file=sys.stderr)
            return 3
    data.mkdir(parents=True, exist_ok=True)
    if sys.stdout is None or sys.stderr is None:  # pythonw on Windows has no console to write to
        log = open(data / "hub.log", "a", buffering=1, encoding="utf-8")
        sys.stdout = sys.stdout or log
        sys.stderr = sys.stderr or log
    seed_models(Path(env["FASTEMBED_CACHE_PATH"]))
    os.environ.update(env)

    # The MCP server runs beside the API as its own process, as in the server image.
    mcp_log = open(data / "mcp.log", "a", encoding="utf-8")
    # The MCP process must find this same code, however this one was started (run_hub.pyw adds it
    # to sys.path only for itself).
    code_dir = str(Path(__file__).resolve().parent.parent)
    child_env = dict(os.environ)
    child_env["PYTHONPATH"] = os.pathsep.join(p for p in (code_dir, child_env.get("PYTHONPATH", "")) if p)
    mcp = subprocess.Popen([sys.executable, "-m", "ide_storage.mcp_standalone"], env=child_env,
                           stdout=mcp_log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

    def stop(*_):
        mcp.terminate()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    try:
        import uvicorn

        from ide_storage.main import app

        print(f"Wolf Leader is running at http://127.0.0.1:{args.port} (data: {data})", flush=True)
        uvicorn.run(app, host=env["HOST"], port=args.port, log_level=os.environ.get("LOG_LEVEL", "warning"))
    finally:
        mcp.terminate()
        try:
            mcp.wait(timeout=10)
        except subprocess.TimeoutExpired:
            mcp.kill()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
