#!/usr/bin/env python3
"""Idempotently save a meaningful Codex/Cursor transcript after each response."""
from __future__ import annotations
import json, os, re, subprocess, sys, urllib.request
from pathlib import Path

API=(os.environ.get("WOLF_LEADER_API_LOCAL") or os.environ.get("WOLF_LEADER_API") or "http://127.0.0.1:6971").rstrip("/")

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
        if role not in ("user","assistant") or not content.strip(): continue
        if role=="user" and content.lstrip().startswith(("<recommended_plugins>","<environment_context>","# AGENTS.md instructions","<heartbeat>")): continue
        messages.append({"role":role,"content":content.strip(),**({"created_at":created} if created else {})})
    return messages

def slugify(text):
    words=re.sub(r"[^a-zA-Z0-9 ]+"," ",text).lower().split()
    drop={"can","could","would","please","help","me","the","a","an","to","with","this","that","my","i"}
    words=[w for w in words if w not in drop][:7]
    return "-".join(words)[:64] or "untitled-project"

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

def maybe_git(cwd, created):
    if not created or os.environ.get("WOLF_LEADER_AUTO_GIT","1") != "1": return
    path=Path(cwd)
    if not path.is_dir() or "/Documents/Codex/" in str(path): return
    try:
        inside=subprocess.run(["git","-C",str(path),"rev-parse","--is-inside-work-tree"],capture_output=True).returncode==0
        if not inside and any(path.iterdir()): subprocess.run(["git","-C",str(path),"init"],capture_output=True,timeout=10)
    except Exception: pass

def main():
    try: event=json.load(sys.stdin)
    except Exception: print('{"continue":true}'); return
    transcript=event.get("transcript_path"); sid=event.get("session_id"); cwd=event.get("cwd") or ""
    if not transcript or not Path(transcript).is_file(): print('{"continue":true}'); return
    messages=parse(transcript)
    if not meaningful(messages): print('{"continue":true}'); return
    title=title_for(messages); text="\n".join(m["content"] for m in messages)[:80000]
    match=call("POST","/api/projects/match",{"text":text,"messages":messages,"workspace_path":cwd})
    best=match.get("best") or {}; slug=best.get("slug") if best.get("confidence") in ("high","medium") else None; created=False
    if not slug:
        slug=slugify(title); projects=call("GET","/api/projects").get("projects",[]); existing={p.get("slug") for p in projects}
        base=slug; n=2
        while slug in existing: slug=f"{base[:58]}-{n}"; n+=1
        call("POST","/api/projects",{"name":title[:80],"slug":slug,"path":cwd,"description":title,
             "metadata":{"auto_created":True,"semantic_descriptor":f"Automatically created project for: {title}"},"tags":["auto-created"]})
        created=True
    maybe_git(cwd,created)
    result=call("POST","/api/save-project",{"session_id":sid,"slug":slug,"workspace_path":cwd,"title":title,
        "content":f"Automatic checkpoint with {len(messages)} messages.","messages":messages,
        "occurred_at":messages[0].get("created_at")})
    Path.home().joinpath(".cursor/wolf-leader-last-save.json").write_text(json.dumps(result,indent=2))
    print('{"continue":true}')

if __name__=="__main__":
    try: main()
    except Exception as exc:
        try: Path.home().joinpath(".cursor/wolf-leader-autosave-error.log").write_text(str(exc))
        except Exception: pass
        print('{"continue":true}')
