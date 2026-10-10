"""Mirrors of Postgres that humans read: the Obsidian vault and the Fumadocs wiki.

Called at the end of every save / howl. Never raises — a mirror failing must not
fail the write that produced the knowledge.
"""
from __future__ import annotations

import logging
import threading
from typing import Any

logger = logging.getLogger(__name__)

_wiki_lock = threading.Lock()
_wiki_timer: threading.Timer | None = None
WIKI_DEBOUNCE_SECONDS = 20.0


def _wiki_rebuild() -> None:
    global _wiki_timer
    with _wiki_lock:
        _wiki_timer = None
    try:
        from ide_storage.wiki_export import export_and_build

        result = export_and_build()
        logger.info("wiki rebuilt: %s", {k: result.get(k) for k in ("exported", "built", "error")})
    except Exception:  # noqa: BLE001
        logger.exception("wiki rebuild failed")


def schedule_wiki_rebuild(delay: float = WIKI_DEBOUNCE_SECONDS) -> bool:
    """Debounced: many saves in a row produce one build."""
    global _wiki_timer
    with _wiki_lock:
        if _wiki_timer is not None:
            _wiki_timer.cancel()
        _wiki_timer = threading.Timer(delay, _wiki_rebuild)
        _wiki_timer.daemon = True
        _wiki_timer.start()
    return True


def refresh_mirrors(project_id: int | None, *, howl_id: int | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {}
    try:
        from ide_storage.vault import refresh_vault

        out["vault"] = refresh_vault(project_id, howl_id=howl_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("vault refresh failed")
        out["vault"] = {"error": str(exc)}
    try:
        from ide_storage.wiki_export import export_content, wiki_enabled

        if wiki_enabled():
            out["wiki"] = export_content()
            out["wiki"]["build_scheduled"] = schedule_wiki_rebuild()
        else:
            out["wiki"] = {"skipped": True}
    except Exception as exc:  # noqa: BLE001
        logger.exception("wiki export failed")
        out["wiki"] = {"error": str(exc)}
    return out
