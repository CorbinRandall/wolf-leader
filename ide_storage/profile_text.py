"""Turn notes other AI tools keep about a person into profile items. No database here, so the
history scanner can use it on any computer."""
from __future__ import annotations

import re
from typing import Any

_FRONT = re.compile(r"^---\s*\n.*?\n---\s*\n", re.S)


def items_from_text(text: str, source: str, default_kind: str = "about") -> list[dict[str, Any]]:
    """Split a memory or rules file into profile items: one per bullet or short paragraph."""
    body = _FRONT.sub("", text or "")
    body = re.sub(r"\*\*(Why|How to apply):\*\*.*", "", body)  # keep the rule, not its bookkeeping
    out: list[dict[str, Any]] = []
    for chunk in re.split(r"\n\s*\n|\n(?=\s*[-*] )", body):
        line = re.sub(r"^\s*(#+|[-*]|\d+\.)\s*", "", chunk.strip())
        line = " ".join(line.split())
        if 12 <= len(line) <= 600 and not line.startswith(("```", "|", "<")):
            out.append({"text": line, "kind": guess_kind(line, default_kind), "source": source})
    return out


def guess_kind(text: str, default: str = "about") -> str:
    t = text.lower()
    if re.search(r"\b(don't|do not|never|avoid|stop)\b", t):
        return "avoid"
    if re.search(r"\b(reply|replies|answer|short|plain|tone|wording|write|explain|bullet|jargon)\b", t):
        return "style"
    if re.search(r"\b(mac|windows|linux|server|ssh|cursor|codex|claude|editor|terminal|unraid|docker)\b", t):
        return "tools"
    if re.search(r"\b(prefer|likes?|wants?|always|first|before|ask)\b", t):
        return "preference"
    return default
