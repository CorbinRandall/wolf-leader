#!/usr/bin/env python3
"""Find and parse this chat's local transcript for /wolfhowl (Cursor, Codex, Claude Code).

Parsing happens here so the agent never spends tokens re-typing the conversation.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

MAX_MSG_CHARS = 12000
DEFAULT_ROOT = Path.home() / ".cursor" / "projects"
CODEX_ROOTS = (
    Path.home() / ".codex" / "sessions",
    Path.home() / ".codex" / "archived_sessions",
)
CLAUDE_ROOT = Path.home() / ".claude" / "projects"
SESSION_ENV_VARS = (
    "WOLF_LEADER_SESSION_ID",
    "CODEX_THREAD_ID",
    "CODEX_SESSION_ID",
    "CURSOR_SESSION_ID",
    "CLAUDE_SESSION_ID",
)
# Harness-injected "user" turns that are not the person talking.
INJECTED_PREFIXES = (
    "<recommended_plugins>",
    "<environment_context>",
    "# AGENTS.md instructions",
    "<heartbeat>",
    "<system-reminder>",
    "<skills_instructions>",
    "<codex_apps_client_time_context>",
)


def load_env() -> tuple[str, Path | None]:
    api = os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API") or "http://127.0.0.1:6971"
    env_files = (
        Path.home() / ".codex" / "wolf-leader.env",
        Path.home() / ".cursor" / "wolf-leader.env",
        Path.home() / ".claude" / "wolf-leader.env",
    )
    env_file = next((path for path in env_files if path.is_file()), None)
    if env_file:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if key == "WOLF_LEADER_API_LOCAL" and value:
                api = value
            elif key == "WOLF_LEADER_API" and value and not os.environ.get("WOLF_LEADER_API_LOCAL"):
                api = value
    custom = os.environ.get("CURSOR_TRANSCRIPTS_ROOT")
    root = Path(custom) if custom else None
    return api.rstrip("/"), root


# A turn that is nothing but one <snake_case_tag>…</snake_case_tag> block is the client
# talking to the model (page context, tool plumbing), not the person.
_WRAPPED_BLOCK = re.compile(r"^\s*<([a-z][a-z0-9]*(?:[_-][a-z0-9]+)+)>.*</\1>\s*$", re.S)


def is_injected(text: str) -> bool:
    return text.lstrip().startswith(INJECTED_PREFIXES) or bool(_WRAPPED_BLOCK.match(text))


def session_id_from_env() -> str:
    for name in SESSION_ENV_VARS:
        value = (os.environ.get(name) or "").strip()
        if value:
            return value
    return ""


def _blocks_text(content) -> str:
    if isinstance(content, str):
        return content.strip()
    parts = []
    for block in content or []:
        if isinstance(block, dict) and block.get("type") in ("text", "input_text", "output_text") and block.get("text"):
            parts.append(block["text"])
    return "\n".join(parts).strip()


def clean_user(text: str) -> str:
    return re.sub(r"</?user_query>", "", text).strip()


def truncate(text: str, limit: int = MAX_MSG_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 80] + "\n\n[... truncated for storage ...]"


def parse_transcript(path: Path) -> list[dict[str, str]]:
    """Read a Cursor, Codex, or Claude Code .jsonl transcript into user/assistant turns."""
    messages: list[dict[str, str]] = []
    pending_assistant: list[str] = []

    def flush() -> None:
        if pending_assistant:
            messages.append({"role": "assistant", "content": truncate("\n\n".join(pending_assistant))})
            pending_assistant.clear()

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        item = entry
        if entry.get("type") == "response_item" and isinstance(entry.get("payload"), dict):
            item = entry["payload"]  # Codex rollout row
        message = item.get("message") if isinstance(item.get("message"), dict) else {}
        role = item.get("role") or message.get("role")
        if role not in ("user", "assistant") or entry.get("isMeta") or entry.get("isSidechain"):
            continue
        text = _blocks_text(message.get("content")) or _blocks_text(item.get("content"))
        if not text:
            continue
        if role == "user":
            text = clean_user(text)
            if not text or is_injected(text):
                continue
            flush()
            messages.append({"role": "user", "content": truncate(text)})
        else:
            pending_assistant.append(text)
    flush()
    return messages


def _cursor_roots(root_hint: Path | None) -> list[Path]:
    roots: list[Path] = []
    if root_hint:
        roots.append(root_hint)
    roots.append(DEFAULT_ROOT / "root" / "agent-transcripts")
    if DEFAULT_ROOT.is_dir():
        for child in sorted(DEFAULT_ROOT.iterdir()):
            candidate = child / "agent-transcripts"
            if candidate.is_dir():
                roots.append(candidate)
    return roots


def find_transcript(
    session_id: str | None = None,
    *,
    root_hint: Path | None = None,
) -> tuple[str, Path] | tuple[None, None]:
    """Locate the transcript for exactly this session id.

    Never falls back to "newest transcript": that attached unrelated chats before.
    """
    sid = (session_id or session_id_from_env()).strip()
    if not sid:
        return None, None
    for root in _cursor_roots(root_hint):
        path = root / sid / f"{sid}.jsonl"
        if path.is_file():
            return sid, path
    if CLAUDE_ROOT.is_dir():
        for path in CLAUDE_ROOT.glob(f"*/{sid}.jsonl"):
            return sid, path
    codex: list[tuple[float, Path]] = []
    for root in CODEX_ROOTS:
        if root.is_dir():
            codex.extend((path.stat().st_mtime, path) for path in root.rglob(f"rollout-*{sid}*.jsonl"))
    if codex:
        # A resumed thread writes a new rollout file; the newest holds the live turns.
        codex.sort(reverse=True)
        return sid, codex[0][1]
    return None, None


def title_from_messages(messages: list[dict[str, str]]) -> str:
    for msg in messages:
        if msg.get("role") != "user":
            continue
        text = clean_user(msg.get("content") or "")
        text = re.sub(r"\s+", " ", text).strip()
        if len(text) > 80:
            text = text[:77] + "..."
        if text:
            return text
    return "Agent session"
