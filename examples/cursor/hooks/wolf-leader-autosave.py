#!/usr/bin/env python3
"""Idempotently save a meaningful Codex, Cursor or Claude Code transcript after each response."""
from __future__ import annotations
import json, os, re, sys, urllib.request
from pathlib import Path

API=(os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API") or "http://127.0.0.1:6971").rstrip("/")
CLIENT_DIR=Path(os.environ.get("WOLF_LEADER_CLIENT_DIR") or (Path.home()/".cursor"))

# Client-injected "user" turns: not the person talking, so never the title or the match text.
INJECTED_PREFIXES=("<command-name>","<local-command","<command-message>","<recommended_plugins>","<environment_context>","# AGENTS.md instructions","<heartbeat>","<system-reminder>","<skills_instructions>","<codex_apps_client_time_context>")
WRAPPED_BLOCK=re.compile(r"^\s*<([a-z][a-z0-9]*(?:[_-][a-z0-9]+)+)>.*</\1>\s*$", re.S)

def call(method, path, body=None, timeout=180):
    data=json.dumps(body).encode() if body is not None else None
    req=urllib.request.Request(API+path,data=data,method=method,headers={"Content-Type":"application/json"} if data else {})
    with urllib.request.urlopen(req,timeout=timeout) as response:return json.loads(response.read())

def text_blocks(content):
    if isinstance(content,str): return content
    return "\n".join((b.get("text") or "") for b in (content or []) if isinstance(b,dict))

def parse(path):
    messages=[]
    for line in Path(path).read_text(errors="replace").splitlines():
        try: row=json.loads(line)
        except Exception: continue
        role=None; content=""; created=row.get("timestamp")
        if row.get("type")=="response_item" and row.get("payload",{}).get("type")=="message":
            item=row["payload"]; role=item.get("role"); content=text_blocks(item.get("content"))
        elif row.get("role") in ("user","assistant"):
            role=row.get("role"); content=text_blocks(row.get("message",{}).get("content"))
        elif row.get("type") in ("user","assistant") and isinstance(row.get("message"),dict):
            # Claude Code: side chats and its own notes are not the conversation; tool results have no text.
            if row.get("isMeta") or row.get("isSidechain"): continue
            role=row["message"].get("role"); content=text_blocks(row["message"].get("content"))
        if role not in ("user","assistant") or not content.strip(): continue
        if role=="user" and (content.lstrip().startswith(INJECTED_PREFIXES) or WRAPPED_BLOCK.match(content)): continue
        messages.append({"role":role,"content":content.strip(),**({"created_at":created} if created else {})})
    return messages


def title_for(messages):
    text=next((m["content"] for m in messages if m["role"]=="user"),"New project")
    text=re.sub(r"\s+"," ",text).strip()
    return text[:77]+("..." if len(text)>77 else "")

def meaningful(messages):
    users=[m["content"] for m in messages if m["role"]=="user"]
    assistants=[m["content"] for m in messages if m["role"]=="assistant"]
    if not users or not assistants or sum(map(len,users)) < 35:return False
    first=users[0].lower()
    return not ("transcription formatting assistant" in first or "reply with ok" in first)

def is_wolf_leader_topic(text):
    """Wolf Leader maintenance belongs to its canonical project, even when
    the transcript also mentions other projects being used as examples."""
    return bool(re.search(r"\bwolf[- ]?leader\b|\bwolfleader\b|ide[- ]?storage|autosav(?:e|ing)|recall before", text, re.I))


def main():
    try: event=json.load(sys.stdin)
    except Exception: print('{"continue":true}'); return
    transcript=event.get("transcript_path"); sid=event.get("session_id"); cwd=event.get("cwd") or ""
    if not transcript or not Path(transcript).is_file(): print('{"continue":true}'); return
    messages=parse(transcript)
    if not meaningful(messages): print('{"continue":true}'); return
    title=title_for(messages); text="\n".join(m["content"] for m in messages)[:80000]
    match=call("POST","/api/projects/match",{"text":text,"messages":messages,"workspace_path":cwd})
    best=match.get("best") or {}; slug="ide-storage" if is_wolf_leader_topic(text) else (best.get("slug") if best.get("confidence") in ("high","medium") else None)
    # No clear project: it goes to One-offs, the standard home for chats that belong to no
    # project, instead of a new project being made for every unmatched chat.
    body={"session_id":sid,"workspace_path":cwd,"title":title,
        "content":f"Automatic checkpoint with {len(messages)} messages.","messages":messages,
        "occurred_at":messages[0].get("created_at")}
    body["slug"]=slug or "one-offs"
    result=call("POST","/api/save-project",body)
    CLIENT_DIR.joinpath("wolf-leader-last-save.json").write_text(json.dumps(result,indent=2))
    print('{"continue":true}')

if __name__=="__main__":
    try: main()
    except Exception as exc:
        try: CLIENT_DIR.joinpath("wolf-leader-autosave-error.log").write_text(str(exc))
        except Exception: pass
        print('{"continue":true}')
