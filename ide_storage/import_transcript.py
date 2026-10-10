#!/usr/bin/env python3
"""Import a Cursor agent-transcript JSONL into Wolf Leader."""
import argparse
import json
import re
import urllib.request
from pathlib import Path

MAX_MSG_CHARS = 12000
API_URL = "http://localhost:6971/api/chats"


def extract_text(entry: dict) -> str:
    parts = []
    for block in entry.get("message", {}).get("content", []):
        if block.get("type") == "text" and block.get("text"):
            parts.append(block["text"])
    return "\n".join(parts).strip()


def clean_user(text: str) -> str:
    return re.sub(r"</?user_query>", "", text).strip()


def truncate(text: str, limit: int = MAX_MSG_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 80] + "\n\n[... truncated for storage ...]"


def parse_transcript(path: Path) -> list[dict]:
    messages = []
    pending_assistant = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = entry.get("role")
        text = extract_text(entry)
        if not text:
            continue
        if role == "user":
            if pending_assistant:
                messages.append({
                    "role": "assistant",
                    "content": truncate("\n\n".join(pending_assistant)),
                })
                pending_assistant = []
            messages.append({"role": "user", "content": truncate(clean_user(text))})
        elif role == "assistant":
            pending_assistant.append(text)
    if pending_assistant:
        messages.append({
            "role": "assistant",
            "content": truncate("\n\n".join(pending_assistant)),
        })
    return messages


def main():
    parser = argparse.ArgumentParser(description="Import JSONL transcript to Wolf Leader")
    parser.add_argument("transcript", type=Path, help="Path to .jsonl transcript")
    parser.add_argument("--session-id", help="Cursor session UUID (default: stem of file)")
    parser.add_argument("--title", required=True)
    parser.add_argument("--summary", default="")
    parser.add_argument("--project-id", type=int)
    parser.add_argument("--workspace", default="/root")
    parser.add_argument("--api", default=API_URL)
    args = parser.parse_args()

    session_id = args.session_id or args.transcript.stem
    messages = parse_transcript(args.transcript)
    summary = args.summary or f"Imported {len(messages)} messages from {args.transcript.name}"

    payload = {
        "title": args.title,
        "workspace_path": args.workspace,
        "device_name": "unraid-server",
        "session_id": session_id,
        "content": summary,
        "messages": messages,
    }
    if args.project_id:
        payload["metadata"] = {"project_id": args.project_id}

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        args.api, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        print(resp.read().decode())


if __name__ == "__main__":
    main()
