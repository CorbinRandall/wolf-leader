#!/usr/bin/env python3
"""Mode-aware on-disk and runtime observation for all continue_mode types."""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
from typing import Any

from ide_storage.compose_extract import (
    discover_compose_from_container_labels,
    discover_compose_path,
    extract_volumes_from_compose,
)
from ide_storage.project_archetypes import external_coords, get_continue_mode

APPDATA_RE = re.compile(r"/mnt/user/appdata/[a-z0-9._-]+", re.I)
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")

# slug -> plugin root when not in compose_path
DAEMON_PLUGIN_ROOTS: dict[str, str] = {
    "s3-sleep": "/boot/config/plugins/dynamix.s3.sleep",
}

# slug -> pgrep pattern for daemon health
DAEMON_PROCESS_PATTERNS: dict[str, str] = {
    "s3-sleep": "s3_sleep",
}


def _path_status(path: str | None) -> str:
    if not path:
        return "unknown"
    return "present" if os.path.exists(path) else "missing"


def _docker_available() -> bool:
    return os.path.exists(DOCKER_SOCK)


def _decode_chunked(body: bytes) -> bytes:
    pos = 0
    result = b""
    while pos < len(body):
        line_end = body.find(b"\r\n", pos)
        if line_end == -1:
            break
        size_hex = body[pos:line_end].decode("ascii", errors="ignore").split(";", 1)[0].strip()
        try:
            size = int(size_hex, 16)
        except ValueError:
            break
        pos = line_end + 2
        if size == 0:
            break
        result += body[pos : pos + size]
        pos += size + 2
    return result


def _docker_running_containers() -> list[dict[str, Any]] | None:
    """Return running containers with name + labels, or None if docker unavailable."""
    if not _docker_available():
        return None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(DOCKER_SOCK)
        sock.sendall(
            b"GET /containers/json HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        )
        chunks: list[bytes] = []
        while True:
            part = sock.recv(65536)
            if not part:
                break
            chunks.append(part)
        sock.close()
        raw = b"".join(chunks)
        if b"\r\n\r\n" not in raw:
            return None
        _status, body = raw.split(b"\r\n\r\n", 1)
        if "chunked" in _status.decode("ascii", errors="ignore").lower():
            body = _decode_chunked(body)
        data = json.loads(body.decode("utf-8", errors="replace"))
        out: list[dict[str, Any]] = []
        for c in data:
            names = c.get("Names") or []
            if not names:
                continue
            out.append(
                {
                    "name": names[0].lstrip("/"),
                    "labels": c.get("Labels") or {},
                }
            )
        return out
    except Exception:
        return None


def _docker_container_names() -> list[str] | None:
    """Return running container names, or None if docker socket unavailable."""
    containers = _docker_running_containers()
    if containers is None:
        return None
    return [c["name"] for c in containers]


def _matching_containers(slug: str, compose_path: str, all_names: list[str]) -> list[str]:
    terms = {slug.lower()}
    if compose_path:
        terms.add(os.path.basename(compose_path.rstrip("/")).lower())
    matched = []
    for name in all_names:
        low = name.lower()
        if any(t in low for t in terms if t):
            matched.append(name)
    return matched[:8]


def _appdata_matches_project(path: str, slug: str, compose_path: str) -> bool:
    """Reject appdata paths that belong to a different project slug."""
    base = os.path.basename(path.rstrip("/")).lower().replace("_", "-")
    slug_low = slug.lower().replace("_", "-")
    if base == slug_low:
        return True
    if compose_path:
        folder = os.path.basename(compose_path.rstrip("/")).lower().replace("_", "-")
        if base == folder:
            return True
    return False


def _pick_appdata(slug: str, compose_path: str, texts: list[str]) -> str | None:
    candidates: list[str] = []
    for text in texts:
        for match in APPDATA_RE.findall(text):
            path = match.rstrip("/.,;:")
            if _appdata_matches_project(path, slug, compose_path):
                candidates.append(path)
    if slug:
        candidates.append(f"/mnt/user/appdata/{slug}")
    if compose_path:
        folder = os.path.basename(compose_path.rstrip("/"))
        if folder:
            candidates.append(f"/mnt/user/appdata/{folder}")
    seen: set[str] = set()
    for path in candidates:
        if path not in seen:
            seen.add(path)
            if not _appdata_matches_project(path, slug, compose_path):
                continue
            if os.path.isdir(path):
                return path
    for path in candidates:
        if _appdata_matches_project(path, slug, compose_path):
            return path
    return None


def _pgrep_running(pattern: str) -> bool | None:
    try:
        proc = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True,
            timeout=5,
            check=False,
        )
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return None


def _compose_preflight(
    project: dict[str, Any],
    slug: str,
    texts: list[str],
    all_containers: list[str] | None,
    *,
    discovered_paths: list[str] | None = None,
    container_records: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    compose = (project.get("compose_path") or "").strip()
    compose_discovered_via = "db" if compose and os.path.isdir(compose) else None

    if not compose or not os.path.isdir(compose):
        discovered = discover_compose_path(
            slug, project, discovered_paths, containers=container_records
        )
        if discovered:
            compose = discovered
            compose_discovered_via = "disk" if os.path.isdir(discovered) else "container_labels"
    compose_present = bool(
        compose and (os.path.isdir(compose) or compose_discovered_via == "container_labels")
    )

    if not compose_present and container_records:
        from_labels, matched_name = discover_compose_from_container_labels(
            slug, container_records, require_disk=False
        )
        if from_labels:
            compose = from_labels
            compose_present = True
            compose_discovered_via = "container_labels"
            if matched_name and all_containers is not None and matched_name not in all_containers:
                all_containers = list(all_containers) + [matched_name]

    volumes_info: dict[str, Any] = {"named": [], "binds": [], "relative_binds": []}
    if compose_present:
        if os.path.isdir(compose):
            volumes_info = extract_volumes_from_compose(compose)
        elif compose_discovered_via == "container_labels":
            volumes_info = {"named": [], "binds": [], "relative_binds": []}
    has_named_volumes = bool(volumes_info.get("named"))
    has_bind_mounts = bool(volumes_info.get("binds") or volumes_info.get("relative_binds"))
    uses_local_data = bool(volumes_info.get("relative_binds")) or any(
        "./data" in b or "/data" in b for b in volumes_info.get("binds", [])
    )

    appdata_path: str | None = None
    label_only = compose_discovered_via == "container_labels" and not os.path.isdir(compose)
    if label_only or has_bind_mounts or uses_local_data:
        appdata_status = "n/a"
        appdata_path = None
    else:
        appdata_path = _pick_appdata(slug, compose, texts)
        if appdata_path and not os.path.isdir(appdata_path) and has_named_volumes:
            appdata_status = "n/a"
        else:
            appdata_status = _path_status(appdata_path) if appdata_path else ("n/a" if has_named_volumes else "unknown")

    containers: list[str] = []
    if all_containers is not None:
        containers = _matching_containers(slug, compose, all_containers)
    containers_running = bool(containers)

    docker_check = "ok" if all_containers is not None else "unavailable"

    if compose_present and containers_running:
        observed = "deployed"
    elif not compose_present and appdata_status not in ("present", "n/a") and not containers_running:
        observed = "removed"
    elif compose_present or appdata_status == "present" or containers_running:
        observed = "partial"
    else:
        observed = "removed"

    result: dict[str, Any] = {
        "kind": "compose",
        "compose": "present" if compose_present else "missing",
        "compose_path": compose or None,
        "compose_discovered_via": compose_discovered_via,
        "appdata": appdata_status,
        "appdata_path": appdata_path if appdata_status != "n/a" else None,
        "containers": containers,
        "containers_running": containers_running,
        "docker_check": docker_check,
        "observed_deploy_state": observed,
    }
    if has_named_volumes and not has_bind_mounts:
        result["named_volumes"] = volumes_info["named"]
        result["persistence"] = "named_volumes"
    elif has_bind_mounts:
        result["bind_mounts"] = volumes_info.get("binds") or []
        if volumes_info.get("relative_binds"):
            result["relative_binds"] = volumes_info["relative_binds"]
        result["persistence"] = "bind_mounts"
    return result


def _daemon_preflight(slug: str, project: dict[str, Any]) -> dict[str, Any]:
    plugin = (
        project.get("compose_path")
        or DAEMON_PLUGIN_ROOTS.get(slug)
        or f"/boot/config/plugins/{slug}"
    )
    plugin_present = os.path.isdir(plugin)
    pattern = DAEMON_PROCESS_PATTERNS.get(slug, slug.replace("-", "_"))
    daemon_running = _pgrep_running(pattern) if pattern else None
    # daemon_running: True = seen, False = checked-and-absent, None = couldn't check.
    # The daemon is a HOST process; from inside an isolated-PID container with no
    # pgrep it is unobservable. Never report that as a problem — distinguish it.
    daemon_check = "ok" if daemon_running is not None else "unavailable"

    if not plugin_present:
        observed = "removed"
    elif daemon_running is True:
        observed = "deployed"
    elif daemon_running is False:
        observed = "partial"  # plugin installed but daemon genuinely not running
    else:
        observed = "unknown"  # plugin present; liveness not observable from here

    return {
        "kind": "daemon",
        "plugin_root": "present" if plugin_present else "missing",
        "plugin_path": plugin,
        "daemon_running": daemon_running,
        "daemon_check": daemon_check,
        "docker_check": "n/a",
        "observed_deploy_state": observed,
        # Aliases for shared on_disk yaml helper
        "compose": "n/a",
        "appdata": "n/a",
        "containers_running": False,
        "containers": [],
    }


def _external_preflight(slug: str, project: dict[str, Any]) -> dict[str, Any]:
    """Project runs on another host (e.g. migrated to ProxMox systemd).

    Nothing here is locally observable, so we never claim it is 'down'. We surface
    the documented remote coordinates and an 'external' observed state; the stored
    deploy_state (from metadata) carries the documented up/down truth.
    """
    coords = external_coords(project)
    return {
        "kind": "external",
        "external_host": coords.get("host"),
        "external_path": coords.get("path"),
        "external_port": coords.get("port"),
        "external_url": coords.get("url"),
        "external_service": coords.get("service"),
        "external_note": coords.get("note"),
        "docker_check": "n/a",
        "observed_deploy_state": "external",
        # Aliases for shared on_disk yaml helper / summary logic
        "compose": "n/a",
        "appdata": "n/a",
        "containers_running": False,
        "containers": [],
    }


def _client_setup_preflight(slug: str, texts: list[str]) -> dict[str, Any]:
    default_paths = ["/boot/config/ssh/root/authorized_keys", "/root/.ssh/authorized_keys"]
    found: list[str] = []
    for text in texts:
        found.extend(re.findall(r"/(?:boot|root|mnt)[^\s`\"']+authorized_keys[^\s`\"']*", text))
    paths = list(dict.fromkeys(found + default_paths))[:6]
    checked = [{"path": p, "status": _path_status(p)} for p in paths]
    any_present = any(c["status"] == "present" for c in checked)
    observed = "partial" if any_present else "removed"

    return {
        "kind": "client_setup",
        "server_paths": checked,
        "docker_check": "n/a",
        "observed_deploy_state": observed,
        "compose": "n/a",
        "appdata": "n/a",
        "containers_running": False,
        "containers": [],
    }


def _generic_preflight(slug: str, project: dict[str, Any], texts: list[str]) -> dict[str, Any]:
    compose = (project.get("compose_path") or "").strip()
    compose_present = bool(compose and os.path.isdir(compose))
    observed = "partial" if compose_present else "removed"
    return {
        "kind": "generic",
        "compose": "present" if compose_present else "missing",
        "compose_path": compose or None,
        "docker_check": "n/a",
        "observed_deploy_state": observed,
        "appdata": "unknown",
        "containers_running": False,
        "containers": [],
    }


def run_preflight(
    project: dict[str, Any],
    *,
    slug: str,
    continue_mode: str | None = None,
    assistant_texts: list[str] | None = None,
    discovered_paths: list[str] | None = None,
) -> dict[str, Any]:
    """Observe host state appropriate to continue_mode."""
    texts = assistant_texts or []
    mode = continue_mode or get_continue_mode(project)
    all_containers = _docker_container_names()
    container_records = _docker_running_containers()

    if mode == "server_daemon":
        result = _daemon_preflight(slug, project)
    elif mode == "external_host":
        result = _external_preflight(slug, project)
    elif mode == "client_setup":
        result = _client_setup_preflight(slug, texts)
    elif mode in ("compose_deploy", "compose_maintain"):
        result = _compose_preflight(
            project,
            slug,
            texts,
            all_containers,
            discovered_paths=discovered_paths,
            container_records=container_records,
        )
    else:
        result = _generic_preflight(slug, project, texts)

    result["continue_mode"] = mode
    return result


def on_disk_yaml_lines(preflight: dict[str, Any]) -> list[str]:
    """Mode-appropriate on_disk block for SPEC.yaml."""
    kind = preflight.get("kind", "compose")
    lines = ["on_disk:"]

    if kind == "daemon":
        lines.append(f"  plugin_root: {preflight.get('plugin_root', 'unknown')}")
        if preflight.get("plugin_path"):
            lines.append(f'  plugin_path: "{preflight["plugin_path"]}"')
        dr = preflight.get("daemon_running")
        if dr is True:
            lines.append("  daemon_running: true")
        elif dr is False:
            lines.append("  daemon_running: false")
        else:
            lines.append("  daemon_running: unknown")
        if preflight.get("daemon_check") == "unavailable":
            lines.append("  daemon_check: unavailable  # host process not observable from container")
    elif kind == "client_setup":
        lines.append("  server_paths:")
        for entry in preflight.get("server_paths") or []:
            lines.append(f'    - path: "{entry["path"]}"')
            lines.append(f'      status: {entry["status"]}')
    elif kind == "external":
        if preflight.get("external_host"):
            lines.append(f'  host: "{preflight["external_host"]}"')
        if preflight.get("external_path"):
            lines.append(f'  path: "{preflight["external_path"]}"')
        if preflight.get("external_port"):
            lines.append(f'  port: "{preflight["external_port"]}"')
        if preflight.get("external_service"):
            svc = str(preflight["external_service"]).replace('"', '\\"')
            lines.append(f'  service: "{svc}"')
        lines.append("  observable_locally: false")
    else:
        lines.append(f"  compose: {preflight.get('compose', 'unknown')}")
        appdata = preflight.get("appdata", "unknown")
        lines.append(f"  appdata: {appdata}")
        if preflight.get("compose_path"):
            cp = str(preflight["compose_path"]).replace('"', '\\"')
            lines.append(f'  compose_path: "{cp}"')
        containers = preflight.get("containers") or []
        if containers:
            lines.append("  containers:")
            for c in containers:
                lines.append(f'    - "{c}"')
        else:
            lines.append("  containers: []")
        if preflight.get("appdata_path") and appdata != "n/a":
            path = str(preflight["appdata_path"]).replace('"', '\\"')
            lines.append(f'  appdata_path: "{path}"')
        if preflight.get("named_volumes"):
            lines.append("  persistence: named_volumes")
            lines.append("  named_volumes:")
            for v in preflight["named_volumes"][:8]:
                lines.append(f'    - "{v}"')
        elif preflight.get("bind_mounts") or preflight.get("relative_binds"):
            lines.append("  persistence: bind_mounts")
            lines.append("  binds:")
            for b in (preflight.get("bind_mounts") or [])[:6]:
                bp = str(b).replace('"', '\\"')
                lines.append(f'    - "{bp}"')

    dc = preflight.get("docker_check")
    if dc and dc != "n/a":
        lines.append(f"  docker_check: {dc}")

    return lines
