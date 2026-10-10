"""Canonical runtime identity and network endpoints for Wolf Leader."""
from __future__ import annotations

import os
import socket
from dataclasses import asdict, dataclass
from urllib.parse import urlsplit, urlunsplit


def _clean(value: str | None) -> str:
    return (value or "").strip().rstrip("/")


def _host_from_url(url: str) -> str:
    try:
        return urlsplit(url).hostname or ""
    except ValueError:
        return ""


def _url_for(host: str, port: str, path: str = "") -> str:
    # urlsplit requires brackets around IPv6 literals.
    display_host = f"[{host}]" if ":" in host and not host.startswith("[") else host
    return urlunsplit(("http", f"{display_host}:{port}", path, "", ""))


@dataclass(frozen=True)
class RuntimeConfig:
    device_name: str
    public_host: str
    public_url: str
    local_url: str
    mcp_url: str
    port: str
    mcp_port: str

    def as_dict(self) -> dict[str, str]:
        return asdict(self)


def runtime_config() -> RuntimeConfig:
    """Resolve identity once from env, with safe loopback defaults.

    The installer normally writes explicit values to .env. The fallbacks make
    native/dev starts safe and ensure every URL-producing code path agrees.
    """
    port = os.environ.get("PORT", "6971").strip() or "6971"
    mcp_port = os.environ.get("MCP_PORT", "6972").strip() or "6972"
    explicit_public = _clean(os.environ.get("IDE_STORAGE_PUBLIC_URL"))
    explicit_host = _clean(os.environ.get("IDE_STORAGE_PUBLIC_HOST"))
    public_host = explicit_host or _host_from_url(explicit_public) or "127.0.0.1"
    public_url = explicit_public or _url_for(public_host, port)
    local_url = _clean(os.environ.get("IDE_STORAGE_LOCAL_URL")) or _url_for("127.0.0.1", port)
    mcp_url = _clean(os.environ.get("IDE_STORAGE_MCP_URL")) or _url_for(public_host, mcp_port, "/mcp")
    device_name = (
        _clean(os.environ.get("IDE_STORAGE_DEVICE_NAME"))
        or _clean(os.environ.get("IDE_STORAGE_HOST_LABEL"))
        or socket.gethostname().split(".", 1)[0]
        or "wolf-leader"
    )
    return RuntimeConfig(device_name, public_host, public_url, local_url, mcp_url, port, mcp_port)
