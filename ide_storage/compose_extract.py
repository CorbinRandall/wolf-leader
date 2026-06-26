#!/usr/bin/env python3
"""Extract structured compose topology from chats and docker-compose.yml."""
from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

# Well-known env var names (names only — never values)
ENV_NAME_RE = re.compile(
    r"\b(CURSOR_API_KEY|TELEGRAM_BOT_TOKEN|TELEGRAM_[A-Z_]+|OPENAI_API_KEY|"
    r"ANTHROPIC_API_KEY|CLAUDE_[A-Z_]+|BOT_TOKEN|API_KEY|[A-Z][A-Z0-9_]{3,})\b"
)
ENV_FILE_RE = re.compile(r"(/mnt/user/appdata/[a-z0-9._/-]+(?:\.env|/config\.yaml)?)", re.I)
PORT_MAP_RE = re.compile(r"(?<!\d\.)(?<!\d)([1-9]\d{1,4})\s*:\s*(\d{2,5})(?!\d)")
SERVICE_NAME_RE = re.compile(
    r"(?i)\b(?:service|container)\s+[`'\"]?([a-z][a-z0-9-]{2,})[`'\"]?"
)
_SKIP_SERVICE_NAMES = frozenset(
    {
        "the", "and", "for", "with", "via", "names", "name", "image", "port", "this", "that",
        "currently", "was", "toolkit", "that", "from", "into", "using", "used", "have", "been",
        "will", "would", "should", "could", "also", "just", "only", "when", "then", "than",
    }
)

COMPOSE_FILENAMES = ("docker-compose.yml", "compose.yml", "docker-compose.yaml", "compose.yaml")
IMAGE_RE = re.compile(r"(?i)(?:image|ghcr\.io|docker\.io)[/:][\w./:@-]+")
CONFIG_FILE_RE = re.compile(
    r"(?i)(?:config\.yaml|\.env|CLAUDE-SETUP\.md|docker-compose\.yml)"
)

KNOWN_ENV_VARS = frozenset(
    {
        "CURSOR_API_KEY",
        "TELEGRAM_BOT_TOKEN",
        "TELEGRAM_CHAT_ID",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "BOT_TOKEN",
        "API_KEY",
    }
)


def _load_compose_yaml(compose_dir: str) -> tuple[dict[str, Any] | None, Path | None]:
    """Load parsed docker-compose from a directory; return (data, file_path)."""
    base = Path(compose_dir)
    for name in COMPOSE_FILENAMES:
        path = base / name
        if path.is_file():
            try:
                import yaml  # type: ignore

                data = yaml.safe_load(path.read_text(encoding="utf-8", errors="replace"))
                if isinstance(data, dict):
                    return data, path
            except Exception:
                pass
    return None, None


def _compose_dir_from_labels(labels: dict[str, str], *, require_disk: bool = True) -> str | None:
    """Resolve compose directory from Docker Compose container labels."""
    working_dir = (labels.get("com.docker.compose.project.working_dir") or "").strip()
    if working_dir:
        if not require_disk:
            return working_dir.rstrip("/")
        data, _ = _load_compose_yaml(working_dir)
        if data and data.get("services"):
            return working_dir.rstrip("/")

    config_files = (labels.get("com.docker.compose.project.config_files") or "").strip()
    if config_files:
        for part in config_files.split(","):
            cfg = part.strip()
            if not cfg:
                continue
            parent = str(Path(cfg).parent)
            if not parent:
                continue
            if not require_disk:
                return parent.rstrip("/")
            if os.path.isdir(parent):
                data, _ = _load_compose_yaml(parent)
                if data and data.get("services"):
                    return parent.rstrip("/")
    return None


def discover_compose_from_container_labels(
    slug: str,
    containers: list[dict[str, Any]] | None,
    *,
    require_disk: bool = True,
) -> tuple[str | None, str | None]:
    """Match running container name/project to slug; return (compose_dir, container_name)."""
    if not containers:
        return None, None

    slug_low = slug.lower().replace("_", "-")
    slug_variants = {slug_low, slug_low.replace("-", ""), slug_low.replace("-", "_")}

    best_dir: str | None = None
    best_name: str | None = None
    for entry in containers:
        name = (entry.get("name") or "").lstrip("/")
        name_low = name.lower()
        labels = entry.get("labels") or {}
        project = (labels.get("com.docker.compose.project") or "").lower()

        matched = (
            slug_low in name_low
            or name_low in slug_variants
            or project in slug_variants
            or slug_low in project
        )
        if not matched:
            continue

        compose_dir = _compose_dir_from_labels(labels, require_disk=require_disk)
        if compose_dir:
            return compose_dir, name
        if not best_name:
            best_name = name

    return best_dir, best_name


def discover_compose_path(
    slug: str,
    project: dict[str, Any] | None = None,
    paths: list[str] | None = None,
    containers: list[dict[str, Any]] | None = None,
) -> str | None:
    """Find docker-compose directory when DB compose_path is empty."""
    project = project or {}
    candidates: list[str] = []
    db_compose = (project.get("compose_path") or "").strip()
    if db_compose:
        candidates.append(db_compose)
    project_path = (project.get("path") or "").strip()
    if project_path:
        candidates.append(project_path)

    slug_title = slug.replace("-", " ").title().replace(" ", "")
    slug_underscore = slug.replace("-", "_")

    # Common homelab locations
    candidates.extend(
        [
            f"/root/{slug}",
            f"/mnt/user/Media/{slug}",
            f"/mnt/user/Media/{slug_title}",
            f"/mnt/user/appdata/{slug}",
            f"/boot/config/plugins/compose.manager/projects/{slug}",
            f"/boot/config/plugins/compose.manager/projects/{slug.title()}",
            f"/boot/config/plugins/compose.manager/projects/{slug_underscore}",
        ]
    )
    for raw in paths or []:
        p = raw.rstrip("/.,;:")
        if p:
            candidates.append(p)
            parent = str(Path(p).parent)
            if parent and parent != "/":
                candidates.append(parent)

    seen: set[str] = set()
    for cand in candidates:
        cand = cand.rstrip("/")
        if not cand or cand in seen:
            continue
        seen.add(cand)
        if not os.path.isdir(cand):
            continue
        data, _ = _load_compose_yaml(cand)
        if data and data.get("services"):
            return cand

    from_labels, _ = discover_compose_from_container_labels(slug, containers, require_disk=True)
    if from_labels:
        return from_labels
    from_labels, _ = discover_compose_from_container_labels(slug, containers, require_disk=False)
    return from_labels


def _default_env_file(appdata_path: str | None, slug: str) -> str:
    if appdata_path:
        env = os.path.join(appdata_path, ".env")
        if os.path.isfile(env) or appdata_path.startswith("/mnt/user/appdata"):
            return env
    return f"/mnt/user/appdata/{slug}/.env"


def extract_env_vars(
    texts: list[str],
    *,
    slug: str = "",
    appdata_path: str | None = None,
) -> list[dict[str, Any]]:
    """Structured env var names + file paths — never secret values."""
    default_file = _default_env_file(appdata_path, slug)
    found: dict[str, dict[str, Any]] = {}

    for text in texts:
        for path in ENV_FILE_RE.findall(text):
            path = path.rstrip("/.,;:")
            if not path.endswith(".env") and not path.endswith("config.yaml"):
                if appdata_path:
                    path = os.path.join(appdata_path, ".env")
                elif "/appdata/" in path:
                    path = path.rstrip("/") + "/.env"
            for var in ENV_NAME_RE.findall(text):
                if var in KNOWN_ENV_VARS or var.endswith("_KEY") or var.endswith("_TOKEN"):
                    found[var] = {"var": var, "file": path, "required": True}

    for text in texts:
        for var in ENV_NAME_RE.findall(text):
            if var not in KNOWN_ENV_VARS and not (var.endswith("_KEY") or var.endswith("_TOKEN")):
                continue
            if var not in found:
                found[var] = {"var": var, "file": default_file, "required": True}

    return list(found.values())[:12]


def extract_services_from_compose(compose_path: str) -> list[dict[str, Any]]:
    data, path = _load_compose_yaml(compose_path)
    if not data:
        if path and path.is_file():
            return _extract_services_regex(path.read_text(encoding="utf-8", errors="replace"))
        return []

    services = []
    for name, cfg in (data.get("services") or {}).items():
        if not isinstance(cfg, dict):
            continue
        entry: dict[str, Any] = {"name": name}
        if cfg.get("image"):
            entry["image"] = str(cfg["image"])[:120]
        ports = []
        for p in cfg.get("ports") or []:
            ports.append(str(p)[:40])
        if ports:
            entry["ports"] = ports[:4]
        services.append(entry)
    return services[:8]


def extract_volumes_from_compose(compose_path: str) -> dict[str, Any]:
    """Named volumes + bind mounts from compose file."""
    data, _ = _load_compose_yaml(compose_path)
    if not data:
        return {"named": [], "binds": [], "relative_binds": []}

    base = Path(compose_path)
    named: list[str] = []
    for vol in (data.get("volumes") or {}).keys():
        named.append(str(vol))

    binds: list[str] = []
    relative_binds: list[str] = []
    for _svc, cfg in (data.get("services") or {}).items():
        if not isinstance(cfg, dict):
            continue
        for vol in cfg.get("volumes") or []:
            vol_s = str(vol)
            if ":/" not in vol_s:
                if not vol_s.startswith("/") and vol_s not in named:
                    named.append(vol_s.split(":")[0])
                continue
            host = vol_s.split(":", 1)[0]
            if host.startswith("/"):
                if host not in binds:
                    binds.append(host[:120])
            elif host.startswith("./") or host.startswith("../"):
                relative_binds.append(host[:80])
                resolved = str((base / host).resolve())
                if resolved not in binds:
                    binds.append(resolved[:120])

    return {
        "named": list(dict.fromkeys(named))[:12],
        "binds": binds[:8],
        "relative_binds": relative_binds[:6],
    }


def extract_env_from_compose(compose_path: str) -> list[dict[str, Any]]:
    """Env var NAMES from compose services — never values."""
    data, path = _load_compose_yaml(compose_path)
    if not data:
        return []

    env_file = str(path.parent / ".env") if path else ""
    found: dict[str, dict[str, Any]] = {}
    for cfg in (data.get("services") or {}).values():
        if not isinstance(cfg, dict):
            continue
        for key in cfg.get("environment") or []:
            if isinstance(key, str) and "=" in key:
                var = key.split("=", 1)[0].strip()
            elif isinstance(key, str):
                var = key.strip()
            else:
                continue
            if var and var not in found:
                found[var] = {"var": var, "file": env_file, "required": True}
        env_file_ref = cfg.get("env_file")
        if env_file_ref:
            ref = env_file_ref if isinstance(env_file_ref, str) else str(env_file_ref[0])
            if not os.path.isabs(ref):
                ref = str(path.parent / ref) if path else ref
            for var in found:
                found[var]["file"] = ref
    return list(found.values())[:12]


def _extract_services_regex(text: str) -> list[dict[str, Any]]:
    services: list[dict[str, Any]] = []
    seen: set[str] = set()
    for match in SERVICE_NAME_RE.finditer(text):
        name = match.group(1).lower()
        if name in seen or name in _SKIP_SERVICE_NAMES:
            continue
        seen.add(name)
        entry: dict[str, Any] = {"name": name}
        ports = [f"{a}:{b}" for a, b in PORT_MAP_RE.findall(text)]
        if ports:
            entry["ports"] = ports[:3]
        services.append(entry)
        if len(services) >= 6:
            break
    return services


def extract_services_from_text(texts: list[str], slug: str = "") -> list[dict[str, Any]]:
    blob = "\n".join(texts)
    services: list[dict[str, Any]] = []
    seen: set[str] = set()
    ports = list(dict.fromkeys(f"{a}:{b}" for a, b in PORT_MAP_RE.findall(blob)))[:4]

    # Explicit service names common in homelab chats
    for name in (slug, f"{slug}-dashboard" if slug else "", "gateway", "dashboard"):
        if not name or name in seen or name in _SKIP_SERVICE_NAMES:
            continue
        if re.search(rf"(?i)\b{re.escape(name)}\b", blob):
            seen.add(name)
            entry: dict[str, Any] = {"name": name}
            if ports:
                entry["ports"] = ports[:2]
            img = IMAGE_RE.search(blob)
            if img:
                entry["image"] = img.group(0)[:100]
            services.append(entry)

    for extra in _extract_services_regex(blob):
        if extra["name"] not in seen and extra["name"] not in _SKIP_SERVICE_NAMES:
            seen.add(extra["name"])
            if ports and "ports" not in extra:
                extra["ports"] = ports[:2]
            services.append(extra)

    return services[:6]


def extract_config_files(
    texts: list[str],
    appdata_path: str | None,
    *,
    compose_path: str | None = None,
) -> list[dict[str, Any]]:
    """Return config paths with on-disk status — only default appdata paths when they exist."""
    files: list[dict[str, Any]] = []
    seen: set[str] = set()

    def add(path: str) -> None:
        path = path.rstrip("/.,;:")
        if not path or path in seen:
            return
        seen.add(path)
        files.append({"path": path, "status": "present" if os.path.exists(path) else "missing"})

    if compose_path:
        # Only surface the compose file that actually exists; if none do, emit a
        # single canonical "missing" entry instead of all four name variants.
        present = next(
            (os.path.join(compose_path, n) for n in COMPOSE_FILENAMES
             if os.path.isfile(os.path.join(compose_path, n))),
            None,
        )
        add(present or os.path.join(compose_path, COMPOSE_FILENAMES[0]))
        env_in_compose = os.path.join(compose_path, ".env")
        if os.path.isfile(env_in_compose):
            add(env_in_compose)

    if appdata_path and os.path.isdir(appdata_path):
        for name in ("config.yaml", ".env", "CLAUDE-SETUP.md", "pairing"):
            add(f"{appdata_path}/{name}")

    for text in texts:
        for match in re.findall(r"(/[^\s`\"']+(?:config\.yaml|\.env|CLAUDE-SETUP\.md|docker-compose\.yml))", text, re.I):
            add(match.rstrip("/.,;:"))

    return files[:8]


def extract_services_from_seed(seed_text: str) -> list[dict[str, Any]]:
    services: list[dict[str, Any]] = []
    for line in seed_text.splitlines():
        m = re.match(r"^\|\s*([a-z][a-z0-9-]+)\s*\|\s*(\d+)?", line.strip(), re.I)
        if not m:
            continue
        name = m.group(1).lower()
        if name in _SKIP_SERVICE_NAMES or name in ("service", "notes", "port"):
            continue
        entry: dict[str, Any] = {"name": name}
        if m.group(2):
            port = m.group(2)
            entry["ports"] = [f"{port}:{port}"]
        services.append(entry)
    return services[:6]


def merge_services(
    compose_path: str,
    texts: list[str],
    slug: str,
    *,
    seed_text: str = "",
    project: dict[str, Any] | None = None,
    paths: list[str] | None = None,
) -> list[dict[str, Any]]:
    effective = compose_path
    if not effective or not os.path.isdir(effective):
        effective = discover_compose_path(slug, project, paths) or ""
    if effective and os.path.isdir(effective):
        from_compose = extract_services_from_compose(effective)
        if from_compose:
            return from_compose
    if seed_text:
        from_seed = extract_services_from_seed(seed_text)
        if from_seed:
            return from_seed
    return extract_services_from_text(texts, slug)
