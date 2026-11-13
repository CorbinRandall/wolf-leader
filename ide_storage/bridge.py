"""Wolf Leader on this computer: the chat app for Windows, Linux and Mac, in a browser.

A small helper that runs on the person's own computer (the AI tools live there, not on the
hub). It does three things on http://127.0.0.1:6974:

- runs Claude Code and Codex for a chat and reports what they do, step by step;
- keeps each chat in the same form the Mac app uses, on the hub, so a chat started here
  continues in the Mac app and the other way round;
- passes every other request on to the hub, so the whole Wolf Leader web page works from
  this one address (and carries the person's access key, if they have one).

Standard library only, so it runs with any Python 3.9+ and needs nothing installed.

    python3 -m ide_storage.bridge --hub http://127.0.0.1:6971
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, List, Optional

VERSION = "1"
APPLE_EPOCH = 978307200  # the Mac app stores times as seconds since 2001-01-01
SCREEN_SERVER = "wolf-leader"
BLOCKED_TOOLS = ["save_session", "save_current_session", "wolfhowl", "wolfeat", "create_project", "set_project", "resolve_project"]

AGENTS = [
    {"id": "claude", "name": "Claude", "company": "Anthropic", "binary": "claude",
     "hint": "Install Claude Code, then run `claude` once to sign in."},
    {"id": "codex", "name": "Codex", "company": "OpenAI", "binary": "codex",
     "hint": "Install the Codex CLI, then run `codex login`."},
]


def now_apple() -> float:
    return time.time() - APPLE_EPOCH


def iso_ms(apple: float) -> str:
    t = apple + APPLE_EPOCH
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def one_line(text: str, limit: int = 90) -> str:
    flat = " ".join(str(text or "").split())
    return flat if len(flat) <= limit else flat[:limit] + "…"


def describe(value: Any, limit: int = 4000) -> str:
    """Short, readable text for any JSON value an agent sends (tool inputs and outputs)."""
    if value is None:
        return ""
    if isinstance(value, str):
        text = value
    elif isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
            elif isinstance(item, dict) and "content" in item:
                parts.append(describe(item["content"], limit))
            else:
                parts.append(describe(item, limit))
        text = "\n".join(parts)
    else:
        text = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + "\n…"


# ------------------------------------------------------------ finding the AI tools
def search_path() -> str:
    home = os.path.expanduser("~")
    extra = [f"{home}/.local/bin", f"{home}/.npm-global/bin", f"{home}/.bun/bin", f"{home}/.claude/local",
             f"{home}/.volta/bin", f"{home}/.yarn/bin", f"{home}/.asdf/shims", "/opt/homebrew/bin", "/usr/local/bin"]
    if os.name == "nt":
        extra += [os.path.join(os.environ.get("APPDATA", ""), "npm"), os.path.join(home, ".local", "bin")]
    nvm = os.path.join(home, ".nvm", "versions", "node")
    if os.path.isdir(nvm):
        extra += [os.path.join(nvm, v, "bin") for v in sorted(os.listdir(nvm), reverse=True)]
    seen: List[str] = []
    for d in extra + os.environ.get("PATH", "").split(os.pathsep):
        if d and d not in seen:
            seen.append(d)
    return os.pathsep.join(seen)


def find_tool(binary: str) -> Optional[str]:
    return shutil.which(binary, path=search_path())


def tool_env() -> Dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = search_path()
    env["WOLF_LEADER_IN_APP"] = "1"  # tells the tools' own save hooks this chat saves itself
    return env


# ------------------------------------------------------------------- the hub
class Hub:
    def __init__(self, url: str):
        self.url = url.rstrip("/")
        self._mcp_session: Optional[str] = None
        self._lock = threading.Lock()

    def mcp_url(self) -> str:
        m = re.match(r"^(https?://[^/:]+)(?::(\d+))?(/.*)?$", self.url)
        if not m:
            return self.url + "/mcp"
        port = int(m.group(2) or 6971) + 1
        return f"{m.group(1)}:{port}{(m.group(3) or '').rstrip('/')}/mcp"

    def request(self, method: str, path: str, body: Any = None, timeout: float = 30) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout) as reply:
            raw = reply.read()
        try:
            return json.loads(raw)
        except ValueError:
            return raw.decode("utf-8", "replace")

    def get(self, path: str, timeout: float = 30) -> Any:
        try:
            return self.request("GET", path, timeout=timeout)
        except Exception:  # noqa: BLE001 - context is best effort; a chat still runs without it
            return None

    def _mcp_post(self, payload: Dict[str, Any], session: Optional[str]) -> tuple:
        req = urllib.request.Request(self.mcp_url(), data=json.dumps(payload).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if session:
            req.add_header("mcp-session-id", session)
        with urllib.request.urlopen(req, timeout=120) as reply:
            return reply.read().decode("utf-8", "replace"), reply.headers.get("mcp-session-id")

    def call_tool(self, tool: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Call one of the hub's MCP tools (used to file a chat in its project's logbook)."""
        with self._lock:
            for attempt in (1, 2):
                try:
                    if not self._mcp_session:
                        _, sid = self._mcp_post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                            "protocolVersion": "2025-03-26", "capabilities": {},
                            "clientInfo": {"name": "wolf-leader-bridge", "version": VERSION}}}, None)
                        self._mcp_session = sid
                        self._mcp_post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
                    text, _ = self._mcp_post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                              "params": {"name": tool, "arguments": arguments}}, self._mcp_session)
                    for line in text.splitlines():
                        line = line[5:].strip() if line.startswith("data:") else line.strip()
                        if line.startswith("{"):
                            reply = json.loads(line)
                            result = reply.get("result") or {}
                            if isinstance(result.get("structuredContent"), dict):
                                return result["structuredContent"]
                            return result
                    return {}
                except urllib.error.HTTPError:
                    self._mcp_session = None
                    if attempt == 2:
                        raise
        return {}


# ------------------------------------------------------------------ drivers
class JSONLines:
    """A child process that speaks one JSON object per line on stdin and stdout."""

    def __init__(self, args: List[str], cwd: str, on_message: Callable[[dict], None], on_exit: Callable[[int, str], None]):
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0  # type: ignore[attr-defined]
        self.proc = subprocess.Popen(args, cwd=cwd, env=tool_env(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, creationflags=flags)
        self._tail: List[str] = []
        self._write = threading.Lock()
        threading.Thread(target=self._read, args=(on_message, on_exit), daemon=True).start()
        threading.Thread(target=self._errors, daemon=True).start()

    def _read(self, on_message, on_exit) -> None:
        assert self.proc.stdout
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("{"):
                continue
            try:
                on_message(json.loads(line))
            except Exception as exc:  # noqa: BLE001
                sys.stderr.write(f"bridge: couldn't handle a message: {exc}\n")
        code = self.proc.wait()
        on_exit(code, " ".join(self._tail[-6:]))

    def _errors(self) -> None:
        assert self.proc.stderr
        for raw in self.proc.stderr:
            self._tail.append(raw.decode("utf-8", "replace").strip())
            del self._tail[:-20]

    def send(self, message: dict) -> None:
        with self._write:
            try:
                assert self.proc.stdin
                self.proc.stdin.write((json.dumps(message) + "\n").encode())
                self.proc.stdin.flush()
            except Exception:  # noqa: BLE001 - the exit handler reports a dead process
                pass

    @property
    def running(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        try:
            self.proc.terminate()
        except Exception:  # noqa: BLE001
            pass


def claude_title(name: str, data: dict) -> str:
    if isinstance(data.get("command"), str):
        return f"Run `{one_line(data['command'], 70)}`"
    path = data.get("file_path") or data.get("path") or data.get("notebook_path")
    if isinstance(path, str):
        verb = {"Read": "Read", "Write": "Write", "Edit": "Edit", "MultiEdit": "Edit"}.get(name, name)
        return f"{verb} {os.path.basename(path)}"
    for key in ("pattern", "query"):
        if isinstance(data.get(key), str):
            return f"{name} “{one_line(data[key], 50)}”"
    if isinstance(data.get("url"), str):
        return f"{name} {data['url']}"
    if isinstance(data.get("description"), str):
        return f"{name}: {one_line(data['description'], 60)}"
    return name.replace("mcp__", "").replace("__", " · ")


class ClaudeDriver:
    """Claude Code in stream-json mode; approvals arrive as `can_use_tool` control requests."""

    def __init__(self, executable: str, cwd: str, mode: str, resume: Optional[str], model: Optional[str],
                 tools_url: Optional[str], emit: Callable[..., None]):
        self.emit = emit
        self.approvals: Dict[str, dict] = {}
        self.message_id = ""
        self.blocks: Dict[int, str] = {}
        self.streamed: set = set()
        self.exited = False
        permission = {"ask": "default", "edits": "acceptEdits", "auto": "bypassPermissions"}.get(mode, "default")
        args = [executable, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", permission]
        if resume:
            args += ["--resume", resume]
        if model:
            args += ["--model", model]
        if tools_url:
            folder = os.path.join(state_dir(), "agents")
            os.makedirs(folder, exist_ok=True)
            config = os.path.join(folder, "wolf-leader-mcp.json")
            with open(config, "w", encoding="utf-8") as handle:
                json.dump({"mcpServers": {SCREEN_SERVER: {"type": "http", "url": tools_url}}}, handle)
            args += ["--mcp-config", config, "--allowedTools", f"mcp__{SCREEN_SERVER}",
                     "--disallowedTools", ",".join(f"mcp__{SCREEN_SERVER}__{t}" for t in BLOCKED_TOOLS)]
        self.proc = JSONLines(args, cwd, self._handle, self._exit)
        self.proc.send({"type": "control_request", "request_id": "init", "request": {"subtype": "initialize"}})

    def send(self, text: str) -> None:
        self.proc.send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]},
                        "parent_tool_use_id": None, "session_id": ""})

    def interrupt(self) -> None:
        self.proc.send({"type": "control_request", "request_id": str(uuid.uuid4()), "request": {"subtype": "interrupt"}})

    def answer(self, approval: str, allow: bool) -> None:
        request = self.approvals.pop(approval, None)
        if request is None:
            return
        response = ({"behavior": "allow", "updatedInput": request.get("input") or {}} if allow
                    else {"behavior": "deny", "message": "The user said no to this step in Wolf Leader."})
        self.proc.send({"type": "control_response",
                        "response": {"subtype": "success", "request_id": approval, "response": response}})

    def stop(self) -> None:
        self.exited = True
        self.proc.stop()

    def _exit(self, code: int, tail: str) -> None:
        if self.exited:
            return
        self.exited = True
        self.emit("exited", reason=None if code == 0 and not tail else (one_line(tail, 400) or f"Claude stopped (exit {code})."))

    def _handle(self, m: dict) -> None:
        kind = m.get("type")
        if kind == "system" and m.get("subtype") == "init" and m.get("session_id"):
            self.emit("session", id=m["session_id"])
        elif kind == "stream_event":
            event = m.get("event") or {}
            etype = event.get("type")
            if etype == "message_start":
                self.message_id = (event.get("message") or {}).get("id") or str(uuid.uuid4())
                self.blocks = {}
            elif etype == "content_block_start":
                self.blocks[event.get("index", 0)] = f"{self.message_id}-{event.get('index', 0)}"
            elif etype == "content_block_delta":
                key = self.blocks.get(event.get("index", 0))
                delta = event.get("delta") or {}
                if key and delta.get("type") == "text_delta" and isinstance(delta.get("text"), str):
                    self.streamed.add(self.message_id)
                    self.emit("text_delta", id=key, text=delta["text"])
                elif key and isinstance(delta.get("thinking"), str):
                    self.emit("thinking_delta", id=key, text=delta["thinking"])
        elif kind == "assistant":
            message = m.get("message") or {}
            mid = message.get("id") or str(uuid.uuid4())
            for block in message.get("content") or []:
                if block.get("type") == "text" and mid not in self.streamed and block.get("text"):
                    self.emit("text", id=f"{mid}-full-{abs(hash(block['text']))}", text=block["text"])
                elif block.get("type") == "tool_use":
                    data = block.get("input") or {}
                    self.emit("tool_started", id=block.get("id") or str(uuid.uuid4()),
                              title=claude_title(block.get("name") or "Tool", data), detail=describe(data))
        elif kind == "user":
            for block in (m.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id"):
                    self.emit("tool_updated", id=block["tool_use_id"], output=describe(block.get("content")),
                              status="failed" if block.get("is_error") else "done")
        elif kind == "control_request":
            request = m.get("request") or {}
            rid = m.get("request_id")
            if request.get("subtype") != "can_use_tool":
                self.proc.send({"type": "control_response",
                                "response": {"subtype": "error", "request_id": rid, "error": "Not supported in Wolf Leader."}})
                return
            self.approvals[rid] = request
            data = request.get("input") or {}
            self.emit("approval", id=rid, title=claude_title(request.get("display_name") or request.get("tool_name") or "a tool", data),
                      detail=describe(data))
        elif kind == "result":
            failed = bool(m.get("is_error"))
            self.emit("turn_finished", error=(m.get("result") or "Claude reported an error.") if failed else None)


class CodexDriver:
    """Codex through `codex app-server`: JSON-RPC over stdio, one thread per chat."""

    def __init__(self, executable: str, cwd: str, mode: str, resume: Optional[str], model: Optional[str],
                 tools_url: Optional[str], emit: Callable[..., None]):
        self.emit = emit
        self.cwd = cwd
        self.thread: Optional[str] = resume
        self.turn: Optional[str] = None
        self.approvals: Dict[str, Any] = {}
        self.questions: set = set()
        self.waiting: Dict[int, threading.Event] = {}
        self.replies: Dict[int, dict] = {}
        self.next_id = 1
        self.exited = False
        args = [executable]
        if tools_url:
            blocked = ",".join(f'"{t}"' for t in BLOCKED_TOOLS)
            args += ["-c", f'mcp_servers.{SCREEN_SERVER}.url="{tools_url}"',
                     "-c", f"mcp_servers.{SCREEN_SERVER}.disabled_tools=[{blocked}]",
                     "-c", f'mcp_servers.{SCREEN_SERVER}.default_tools_approval_mode="approve"',
                     "-c", "mcp_servers.ide-storage.enabled=false"]
        args += ["app-server"]
        self.proc = JSONLines(args, cwd, self._handle, self._exit)
        self._request("initialize", {"clientInfo": {"name": "wolf-leader", "title": "Wolf Leader", "version": "3"}})
        self.proc.send({"method": "initialized"})
        settings: Dict[str, Any] = {
            "cwd": cwd,
            "approvalPolicy": {"ask": "untrusted", "edits": "on-request", "auto": "never"}.get(mode, "untrusted"),
            "sandbox": "danger-full-access" if mode == "auto" else "workspace-write",
        }
        model = model or self._usable_model()
        if model:
            settings["model"] = model
        if self.thread:
            try:
                self._request("thread/resume", dict(settings, threadId=self.thread))
                return
            except RuntimeError:
                self.emit("note", text="Couldn't pick the old Codex thread back up, so this continues in a new one.")
        result = self._request("thread/start", settings)
        self.thread = (result.get("thread") or {}).get("id")
        if self.thread:
            self.emit("session", id=self.thread)

    def _usable_model(self) -> Optional[str]:
        """A model to ask for when the one in ~/.codex/config.toml isn't offered to this account
        (an old setting would otherwise fail every turn). None leaves Codex's own choice alone."""
        configured = None
        try:
            with open(os.path.join(os.path.expanduser("~"), ".codex", "config.toml"), encoding="utf-8") as handle:
                for raw in handle:
                    line = raw.strip()
                    if line.startswith("["):
                        break
                    match = re.match(r"^model\s*=\s*[\"']?([^\"']+)[\"']?\s*$", line)
                    if match:
                        configured = match.group(1).strip()
                        break
        except OSError:
            return None
        if not configured:
            return None
        try:
            listed = self._request("model/list", {}, timeout=20)
        except RuntimeError:
            return None
        rows = listed.get("data") or listed.get("models") or []
        ids = [r.get("id") or r.get("model") for r in rows if isinstance(r, dict) and (r.get("id") or r.get("model"))]
        if not ids or configured in ids:
            return None
        fallback = next((r.get("id") or r.get("model") for r in rows if isinstance(r, dict) and r.get("isDefault")), ids[0])
        self.emit("note", text=f"Codex is set to {configured}, which your account doesn't offer, so this chat uses {fallback}.")
        return fallback

    def _request(self, method: str, params: dict, timeout: float = 60) -> dict:
        rid = self.next_id
        self.next_id += 1
        done = threading.Event()
        self.waiting[rid] = done
        self.proc.send({"id": rid, "method": method, "params": params})
        if not done.wait(timeout):
            self.waiting.pop(rid, None)
            raise RuntimeError(f"Codex didn't answer {method}.")
        reply = self.replies.pop(rid, {})
        if "error" in reply:
            raise RuntimeError((reply["error"] or {}).get("message") or f"Codex refused {method}.")
        return reply.get("result") or {}

    def send(self, text: str) -> None:
        if not self.thread:
            raise RuntimeError("Codex isn't running.")
        result = self._request("turn/start", {"threadId": self.thread, "input": [{"type": "text", "text": text}]})
        self.turn = (result.get("turn") or {}).get("id")

    def interrupt(self) -> None:
        if self.thread and self.turn:
            threading.Thread(target=lambda: self._quiet("turn/interrupt", {"threadId": self.thread, "turnId": self.turn}),
                             daemon=True).start()

    def _quiet(self, method: str, params: dict) -> None:
        try:
            self._request(method, params, timeout=15)
        except RuntimeError:
            pass

    def answer(self, approval: str, allow: bool) -> None:
        rid = self.approvals.pop(approval, None)
        if rid is None:
            return
        if approval in self.questions:
            self.questions.discard(approval)
            self.proc.send({"id": rid, "result": {"action": "accept" if allow else "decline", "content": None, "_meta": None}})
        else:
            self.proc.send({"id": rid, "result": {"decision": "accept" if allow else "decline"}})

    def stop(self) -> None:
        self.exited = True
        self.proc.stop()

    def _exit(self, code: int, tail: str) -> None:
        for event in list(self.waiting.values()):
            event.set()
        if self.exited:
            return
        self.exited = True
        self.emit("exited", reason=None if code == 0 else (one_line(tail, 400) or f"Codex stopped (exit {code})."))

    @staticmethod
    def _command(item: dict) -> str:
        command = item.get("command")
        command = " ".join(command) if isinstance(command, list) else (command or "")
        for prefix in ("/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "):
            if command.startswith(prefix):
                command = command[len(prefix):]
                if len(command) >= 2 and command[0] in "'\"" and command[-1] == command[0]:
                    command = command[1:-1]
        return command

    def _handle(self, m: dict) -> None:
        if "id" in m and "method" not in m:  # a reply to one of our requests
            self.replies[m["id"]] = m
            event = self.waiting.pop(m["id"], None)
            if event:
                event.set()
            return
        method = m.get("method") or ""
        params = m.get("params") or {}
        if "id" in m:  # Codex is asking us something
            key = str(uuid.uuid4())
            if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                          "execCommandApproval", "applyPatchApproval"):
                self.approvals[key] = m["id"]
                command = self._command(params)
                detail = params.get("reason") or ""
                if params.get("cwd"):
                    detail += ("\n" if detail else "") + f"In {params['cwd']}"
                self.emit("approval", id=key, title=f"Run `{one_line(command, 70)}`" if command else "Change files", detail=detail)
            elif method == "mcpServer/elicitation/request":
                self.approvals[key] = m["id"]
                self.questions.add(key)
                self.emit("approval", id=key, title=f"Use {params.get('serverName') or 'a tool'}", detail=params.get("message") or "")
            else:
                self.proc.send({"id": m["id"], "error": {"code": -32601, "message": f"Wolf Leader doesn't handle {method} yet."}})
            return
        item_id = params.get("itemId") or ""
        if method == "item/agentMessage/delta" and isinstance(params.get("delta"), str):
            self.emit("text_delta", id=item_id, text=params["delta"])
        elif method in ("item/reasoning/summaryTextDelta", "item/reasoning/textDelta") and isinstance(params.get("delta"), str):
            self.emit("thinking_delta", id=item_id, text=params["delta"])
        elif method == "item/started":
            item = params.get("item") or {}
            iid = item.get("id") or str(uuid.uuid4())
            kind = item.get("type")
            if kind == "commandExecution":
                self.emit("tool_started", id=iid, title=f"Run `{one_line(self._command(item), 70)}`", detail="")
            elif kind == "fileChange":
                paths = [os.path.basename(c.get("path", "")) for c in item.get("changes") or [] if c.get("path")]
                self.emit("tool_started", id=iid, title="Edit " + (", ".join(paths[:3]) if paths else "files"), detail="")
            elif kind == "mcpToolCall":
                self.emit("tool_started", id=iid, title=f"{item.get('server') or 'tool'} · {item.get('tool') or ''}",
                          detail=describe(item.get("arguments")))
            elif kind == "webSearch":
                self.emit("tool_started", id=iid, title=f"Search the web “{item.get('query') or ''}”", detail="")
        elif method == "item/completed":
            item = params.get("item") or {}
            iid = item.get("id") or ""
            status = "failed" if item.get("status") in ("failed", "declined") else "done"
            kind = item.get("type")
            if kind == "agentMessage" and item.get("text"):
                self.emit("text", id=iid, text=item["text"])
            elif kind == "commandExecution":
                self.emit("tool_updated", id=iid, output=item.get("aggregatedOutput") or "", status=status)
            elif kind == "fileChange":
                self.emit("tool_updated", id=iid, output="\n".join(c.get("diff") or "" for c in item.get("changes") or []), status=status)
            elif kind == "mcpToolCall":
                self.emit("tool_updated", id=iid, output=describe(item.get("result") or item.get("error")), status=status)
            elif kind == "webSearch":
                self.emit("tool_updated", id=iid, output="", status="done")
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            error = (turn.get("error") or {}).get("message")
            self.turn = None
            self.emit("turn_finished", error=(error or "Codex couldn't finish.") if turn.get("status") == "failed" else error)
        elif method == "error":
            message = (params.get("error") or {}).get("message")
            if message and not params.get("willRetry"):
                self.emit("note", text=message)


# ------------------------------------------------------------------ a chat
def state_dir() -> str:
    base = os.environ.get("WOLF_LEADER_HOME") or os.path.join(os.path.expanduser("~"), ".wolf-leader")
    os.makedirs(base, exist_ok=True)
    return base


def safe_slug(slug: str) -> str:
    cleaned = re.sub(r"[^a-z0-9._-]+", "-", (slug or "").lower()).strip("-")
    return cleaned or "project"


TOOLS_NOTE = """<wolf_leader_tools>
You have the wolf-leader tools: Wolf Leader is the user's memory across every AI they use. Use them when the conversation needs something you weren't given above:
- search: find anything in their projects, memories and past chats (any assistant, any device)
- recall / get_brief / get_memories{project}: a project's full context
- get_session: read an earlier chat in full; get_profile: who the user is
- remember: record a decision, constraint, problem or open work worth keeping for the next chat
- add_to_profile: something lasting the user said about themselves
Wolf Leader saves this chat and files it in its project on its own: never save the chat, howl, or create or switch projects.
</wolf_leader_tools>"""


class Session:
    """One chat on this computer: its record (the Mac app's format), and the agent running it."""

    def __init__(self, bridge: "Bridge", record: dict):
        self.bridge = bridge
        self.record = record
        self.driver: Any = None
        self.busy = False
        self.version = 0
        self.changed = threading.Condition()
        self.lock = threading.RLock()
        self._save_timer: Optional[threading.Timer] = None

    # -- record helpers
    def _touch(self) -> None:
        self.record["updated"] = now_apple()
        with self.changed:
            self.version += 1
            self.changed.notify_all()

    def _item(self, kind: str, text: str, item_id: Optional[str] = None, **extra: Any) -> dict:
        item = {"id": item_id or str(uuid.uuid4()).upper(), "kind": kind, "text": text, "detail": "", "output": "", "at": now_apple()}
        item.update(extra)
        self.record["items"].append(item)
        return item

    def _find(self, item_id: str, kind: str) -> Optional[dict]:
        for item in reversed(self.record["items"]):
            if item["id"] == item_id and item["kind"] == kind:
                return item
        return None

    def snapshot(self) -> dict:
        with self.lock:
            return {"version": self.version, "busy": self.busy, "record": json.loads(json.dumps(self.record))}

    # -- events from the agent
    def emit(self, kind: str, **data: Any) -> None:
        with self.lock:
            if kind == "session":
                self.record["agentSessionID"] = data["id"]
                self.record["agentDevice"] = self.bridge.device
            elif kind in ("text_delta", "thinking_delta", "text"):
                item_kind = "thinking" if kind == "thinking_delta" else "agent"
                item = self._find(data["id"], item_kind)
                if item is None:
                    self._item(item_kind, data["text"], data["id"])
                elif kind == "text":
                    item["text"] = data["text"]
                else:
                    item["text"] += data["text"]
            elif kind == "tool_started":
                if self._find(data["id"], "tool") is None:
                    self._item("tool", data["title"], data["id"], detail=data.get("detail") or "", status="running")
            elif kind == "tool_updated":
                item = self._find(data["id"], "tool")
                if item is not None:
                    if data.get("output"):
                        item["output"] = data["output"]
                    item["status"] = data.get("status") or item.get("status")
            elif kind == "approval":
                if self.record.get("mode") == "auto":
                    self._item("approval", data["title"], data["id"], detail=data.get("detail") or "", status="allowed")
                    driver = self.driver
                    threading.Thread(target=lambda: driver and driver.answer(data["id"], True), daemon=True).start()
                else:
                    self._item("approval", data["title"], data["id"], detail=data.get("detail") or "", status="pending")
            elif kind == "note":
                self._item("note", data["text"])
            elif kind == "turn_finished":
                if data.get("error"):
                    self._item("error", data["error"])
                self._finish()
            elif kind == "exited":
                self.driver = None
                if data.get("reason"):
                    self._item("error", data["reason"])
                if self.busy:
                    self._finish()
            self._touch()

    def _finish(self) -> None:
        self.busy = False
        self.record.pop("activeDevice", None)
        self.record.pop("activeUntil", None)
        for item in self.record["items"]:
            if item.get("status") == "running":
                item["status"] = "done"
            elif item.get("status") == "pending":
                item["status"] = "denied"
        self.save(now=True)

    # -- what the person does
    def send(self, text: str) -> None:
        with self.lock:
            if self.busy:
                raise RuntimeError("This chat is still working.")
            text = text.strip()
            if not text:
                raise RuntimeError("Nothing to send.")
            self._item("user", text)
            if self.record.get("title") in ("", "New chat"):
                self.record["title"] = one_line(text, 60)
            self.busy = True
            self.record["activeDevice"] = self.bridge.device
            self.record["activeUntil"] = now_apple() + 600
            self._touch()
        threading.Thread(target=self._run, args=(text,), daemon=True).start()

    def _run(self, text: str) -> None:
        try:
            if self.driver is None:
                self._connect()
            parts: List[str] = []
            if not self.record.get("contextSent"):
                context = self.bridge.context(self.record)
                if context:
                    parts.append(context)
            parts.append(text)
            self.record["contextSent"] = True
            self.driver.send("\n\n".join(parts))
        except Exception as exc:  # noqa: BLE001
            with self.lock:
                self._item("error", str(exc))
                self._finish()
                self._touch()

    def _connect(self) -> None:
        agent = next((a for a in AGENTS if a["id"] == self.record.get("agentID")), None)
        if agent is None:
            raise RuntimeError("This chat's AI isn't one Wolf Leader can run on this computer yet (Claude and Codex are).")
        executable = find_tool(agent["binary"])
        if not executable:
            raise RuntimeError(f"{agent['name']} isn't set up on this computer yet. {agent['hint']}")
        cwd = self.record.get("cwd") or ""
        if not cwd or not os.path.isdir(cwd):
            cwd = self.bridge.folder_for(self.record)
            self.record["cwd"] = cwd
        # An agent's own session only exists on the computer that ran it.
        resumable = self.record.get("agentDevice") in (None, self.bridge.device)
        resume = self.record.get("agentSessionID") if resumable else None
        if not resume and sum(1 for i in self.record["items"] if i["kind"] == "user") > 1:
            self.record["contextSent"] = False
            self._handoff = True
        mode = self.bridge.mode_for(self.record)
        self.record["mode"] = mode
        tools = self.bridge.hub.mcp_url() if self.bridge.rules().get("hub_tools", True) else None
        cls = ClaudeDriver if agent["id"] == "claude" else CodexDriver
        self.driver = cls(executable, cwd, mode, resume, self.record.get("model"), tools, self.emit)

    def answer(self, item_id: str, allow: bool) -> None:
        with self.lock:
            item = self._find(item_id, "approval")
            if item is None or item.get("status") != "pending":
                return
            item["status"] = "allowed" if allow else "denied"
            driver = self.driver
            self._touch()
        if driver:
            driver.answer(item_id, allow)

    def stop(self) -> None:
        if self.driver:
            self.driver.interrupt()

    # -- keeping it on the hub
    def save(self, now: bool = False) -> None:
        if self._save_timer:
            self._save_timer.cancel()
        if now:
            threading.Thread(target=self._save, daemon=True).start()
        else:
            self._save_timer = threading.Timer(2.0, self._save)
            self._save_timer.daemon = True
            self._save_timer.start()

    def _save(self) -> None:
        with self.lock:
            record = json.loads(json.dumps(self.record))
        hub = self.bridge.hub
        try:
            body = {"record": record, "updated": iso_ms(record["updated"]), "device": self.bridge.device,
                    "title": record.get("title"), "agent_id": record.get("agentID")}
            if record.get("projectID") is not None:
                body["project_id"] = record["projectID"]
            hub.request("PUT", f"/api/app-chats/{record['id']}", body)
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"bridge: couldn't sync the chat to the hub: {exc}\n")
        try:
            self._file(record)
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"bridge: couldn't file the chat in its logbook: {exc}\n")

    def _file(self, record: dict) -> None:
        """File the chat in its project's logbook, the way the Mac app does after every reply."""
        messages = []
        for item in record["items"]:
            role = {"user": "user", "agent": "assistant"}.get(item["kind"])
            content = item["text"] if role else (f"[step] {item['text']}" if item["kind"] == "tool" else "")
            if content.strip():
                messages.append({"role": role or "assistant", "content": content[:20000]})
        if not any(m["role"] == "user" for m in messages):
            return
        agent = next((a["name"] for a in AGENTS if a["id"] == record.get("agentID")), record.get("agentID") or "AI")
        first = next((i["text"] for i in record["items"] if i["kind"] == "user"), "")
        last = next((i["text"] for i in reversed(record["items"]) if i["kind"] == "agent"), "")
        where = f", project {record['projectName']}" if record.get("projectName") else ""
        summary = (f"{agent} chat in Wolf Leader on {self.bridge.device}{where}.\n"
                   f"Asked: {one_line(first, 600)}\nLatest reply: {one_line(last, 1500)}")
        arguments = {
            "title": f"{agent}: {record.get('title') or 'Chat'}",
            "content": summary,
            "session_id": f"wolf-chat-{record['id']}",
            "workspace_path": record.get("cwd") or "",
            "messages_json": json.dumps(messages[-400:]),
            "occurred_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record["created"] + APPLE_EPOCH)),
        }
        if record.get("projectID") is not None:
            arguments["project_id"] = record["projectID"]
        self.bridge.hub.call_tool("save_session", arguments)


class Bridge:
    def __init__(self, hub_url: str, port: int):
        self.hub = Hub(hub_url)
        self.port = port
        self.device = os.environ.get("WOLF_LEADER_DEVICE") or socket.gethostname().split(".")[0] or "this computer"
        self.sessions: Dict[str, Session] = {}
        self.lock = threading.Lock()
        self._rules: tuple = (0.0, {})

    def rules(self) -> dict:
        at, value = self._rules
        if time.time() - at > 30:
            value = self.hub.get("/api/chat-rules") or value or {}
            value = value.get("rules", value) if isinstance(value, dict) and isinstance(value.get("rules"), dict) else value
            self._rules = (time.time(), value)
        return value if isinstance(value, dict) else {}

    def mode_for(self, record: dict) -> str:
        rules = self.rules()
        if rules.get("never_ask"):
            return "auto"
        return record.get("mode") if record.get("mode") in ("ask", "edits", "auto") else (rules.get("default_mode") or "ask")

    def folder_for(self, record: dict) -> str:
        if record.get("projectSlug"):
            folder = os.path.join(state_dir(), "projects", safe_slug(record["projectSlug"]))
        else:
            folder = os.path.join(state_dir(), "loose-chats", record["id"])
        os.makedirs(folder, exist_ok=True)
        return folder

    def context(self, record: dict) -> Optional[str]:
        """What an agent should know before a chat's first message: who you are and the project."""
        sections: List[str] = []
        who = (self.hub.get("/api/whoami") or {}).get("person")
        if who:
            about = self.hub.get(f"/api/people/{urllib.request.quote(who)}/profile.md")
            if isinstance(about, str) and about.strip():
                sections.append(f'<about_you person="{who}">\n{about.strip()[:3000]}\n</about_you>')
        pid = record.get("projectID")
        shared = self.hub.get("/api/shared-context" + (f"?exclude={pid}" if pid is not None else "")) or {}
        if isinstance(shared, dict) and (shared.get("text") or "").strip():
            sections.append("<shared_context>\nApplies to every project: things the user set up once (servers, network, "
                            f"accounts and how to reach them).\n{shared['text'].strip()[:12000]}\n</shared_context>")
        if pid is not None:
            key = record.get("projectSlug") or str(pid)
            brief = self.hub.get(f"/api/projects/{urllib.request.quote(str(key))}/agent-brief", timeout=60) or {}
            parts = []
            if isinstance(brief, dict):
                purpose = brief.get("purpose_summary") or brief.get("description")
                pickup = brief.get("agent_prompt") or brief.get("pickup_prompt")
                if purpose:
                    parts.append(f"Purpose: {purpose}")
                if pickup:
                    parts.append(f"Where it was left off:\n{pickup}")
            name = record.get("projectName") or "this project"
            sections.append(f'<project name="{name}">\nThis chat is part of the Wolf Leader project "{name}". Wolf Leader '
                            "writes it to the project's ledger after every reply, so the next chat (with any assistant, "
                            "on any device) picks up from here.\n" + "\n\n".join(parts)[:12000] + "\n</project>")
        earlier = [i for i in record["items"][:-1] if i["kind"] in ("user", "agent") and i["text"].strip()]
        if earlier:
            lines = [("User: " if i["kind"] == "user" else "Assistant: ") + i["text"][:4000] for i in earlier[-30:]]
            sections.append("<wolf_leader_conversation_so_far>\nYou are picking up a conversation that was already going in "
                            "Wolf Leader, maybe on another device or with another assistant. Carry on from where it left "
                            "off: don't repeat what was said.\n\n" + "\n\n".join(lines) + "\n</wolf_leader_conversation_so_far>")
        if not sections:
            body = ""
        else:
            body = ("<wolf_leader_context>\nWolf Leader is the user's own memory across every AI assistant they use. Use this "
                    "to pick up where things are; don't recite it back.\n" + "\n\n".join(sections) + "\n</wolf_leader_context>")
        if self.rules().get("hub_tools", True):
            slug = record.get("projectSlug")
            body += ("\n\n" if body else "") + TOOLS_NOTE.replace("{project}", f" (this project: {slug})" if slug else "")
        extra = (self.rules().get("rules") or "").strip() if isinstance(self.rules().get("rules"), str) else ""
        if extra:
            body += f"\n\n<your_rules>\n{extra}\n</your_rules>"
        return body or None

    def session(self, chat_id: str, create: Optional[dict] = None) -> Session:
        with self.lock:
            existing = self.sessions.get(chat_id)
            if existing:
                return existing
            record = None
            if create is None:
                row = self.hub.get(f"/api/app-chats/{urllib.request.quote(chat_id)}")
                record = (row or {}).get("record") if isinstance(row, dict) else None
                if record is None:
                    raise KeyError(chat_id)
            else:
                record = {"id": chat_id, "agentID": create.get("agentID") or "claude", "title": "New chat", "cwd": "",
                          "mode": create.get("mode") or "ask", "items": [], "created": now_apple(), "updated": now_apple(),
                          "contextSent": False}
                for key in ("projectID", "projectName", "projectSlug", "model"):
                    if create.get(key) not in (None, ""):
                        record[key] = create[key]
            record.setdefault("items", [])
            session = Session(self, record)
            self.sessions[chat_id] = session
            return session

    def status(self) -> dict:
        agents = []
        for agent in AGENTS:
            path = find_tool(agent["binary"])
            agents.append({"id": agent["id"], "name": agent["name"], "company": agent["company"], "found": bool(path), "hint": agent["hint"]})
        return {"ok": True, "version": VERSION, "device": self.device, "system": platform.system(), "hub": self.hub.url.split("/k/")[0],
                "agents": agents}


# ---------------------------------------------------------------- web server
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding",
       "upgrade", "host", "content-length", "accept-encoding"}


def make_handler(bridge: Bridge):
    allowed_hosts = {f"127.0.0.1:{bridge.port}", f"localhost:{bridge.port}"}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args: Any) -> None:  # quiet
            pass

        def _json(self, code: int, body: Any) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                return json.loads(raw) if raw else {}
            except ValueError:
                return {}

        def _allowed(self) -> bool:
            # Only this computer's own browser, on this page: another site (or another machine)
            # must never be able to start an AI here.
            if (self.headers.get("Host") or "").lower() not in allowed_hosts:
                return False
            origin = self.headers.get("Origin")
            return origin is None or origin.lower() in {f"http://{h}" for h in allowed_hosts}

        def _route(self, method: str) -> None:
            if not self._allowed():
                return self._json(403, {"detail": "Open Wolf Leader from this computer."})
            path = self.path.split("?", 1)[0]
            query = dict(p.split("=", 1) for p in self.path.split("?", 1)[1].split("&") if "=" in p) if "?" in self.path else {}
            try:
                if path == "/chat" and method == "GET":
                    # The helper carries its own copy of the page, so chat works with an older hub too.
                    page = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static", "chat.html")
                    if os.path.isfile(page):
                        with open(page, "rb") as handle:
                            data = handle.read()
                        self.send_response(200)
                        self.send_header("Content-Type", "text/html; charset=utf-8")
                        self.send_header("Content-Length", str(len(data)))
                        self.send_header("Cache-Control", "no-store")
                        self.end_headers()
                        self.wfile.write(data)
                        return
                if path == "/bridge/status" and method == "GET":
                    return self._json(200, bridge.status())
                m = re.match(r"^/bridge/chats/([A-Za-z0-9-]{8,80})(/[a-z]+)?$", path)
                if m:
                    chat_id, action = m.group(1), (m.group(2) or "")
                    if method == "GET" and action == "":
                        return self._json(200, bridge.session(chat_id).snapshot())
                    if method == "GET" and action == "/events":
                        session = bridge.session(chat_id)
                        after = int(query.get("after") or -1)
                        deadline = time.time() + 25
                        with session.changed:
                            while session.version <= after and time.time() < deadline:
                                session.changed.wait(timeout=max(0.1, deadline - time.time()))
                        time.sleep(0.12)  # let a burst of streamed words land in one update
                        return self._json(200, session.snapshot())
                    body = self._body()
                    if method == "POST" and action == "/send":
                        session = bridge.session(chat_id, create=body.get("new")) if body.get("new") else bridge.session(chat_id)
                        session.send(str(body.get("text") or ""))
                        return self._json(200, {"ok": True})
                    if method == "POST" and action == "/answer":
                        bridge.session(chat_id).answer(str(body.get("item") or ""), bool(body.get("allow")))
                        return self._json(200, {"ok": True})
                    if method == "POST" and action == "/stop":
                        bridge.session(chat_id).stop()
                        return self._json(200, {"ok": True})
                    return self._json(404, {"detail": "Not found"})
                if path.startswith("/bridge/"):
                    return self._json(404, {"detail": "Not found"})
            except KeyError:
                return self._json(404, {"detail": "No such chat"})
            except RuntimeError as exc:
                return self._json(409, {"detail": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"detail": str(exc)})
            self._proxy(method)

        def _proxy(self, method: str) -> None:
            """Everything that isn't the helper's own goes to the hub, so the page has one address."""
            length = int(self.headers.get("Content-Length") or 0)
            data = self.rfile.read(length) if length else None
            req = urllib.request.Request(bridge.hub.url + self.path, data=data, method=method)
            for key, value in self.headers.items():
                if key.lower() not in HOP and key.lower() != "origin":
                    req.add_header(key, value)
            try:
                reply = urllib.request.urlopen(req, timeout=600)
            except urllib.error.HTTPError as exc:
                reply = exc
            except Exception as exc:  # noqa: BLE001
                return self._json(502, {"detail": f"Can't reach the hub at {bridge.status()['hub']}: {exc}"})
            body = reply.read()
            self.send_response(reply.status if hasattr(reply, "status") else reply.code)
            for key, value in reply.headers.items():
                if key.lower() not in HOP:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            self._route("GET")

        def do_POST(self) -> None:  # noqa: N802
            self._route("POST")

        def do_PUT(self) -> None:  # noqa: N802
            self._route("PUT")

        def do_DELETE(self) -> None:  # noqa: N802
            self._route("DELETE")

        def do_PATCH(self) -> None:  # noqa: N802
            self._route("PATCH")

    return Handler


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Wolf Leader on this computer: chat with your AI tools in a browser.")
    parser.add_argument("--hub", default=os.environ.get("WOLF_LEADER_API") or "http://127.0.0.1:6971",
                        help="Your hub's address (a personal address with /k/<key> works too).")
    parser.add_argument("--port", type=int, default=int(os.environ.get("WOLF_LEADER_BRIDGE_PORT") or 6974))
    parser.add_argument("--open", action="store_true", help="Open the chat page in your browser.")
    args = parser.parse_args(argv)
    bridge = Bridge(args.hub, args.port)
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(bridge))
    except OSError:
        # Already running: just show the page.
        if args.open:
            import webbrowser

            webbrowser.open(f"http://127.0.0.1:{args.port}/chat")
        return 0
    server.daemon_threads = True
    print(f"Wolf Leader is at http://127.0.0.1:{args.port}/chat (hub: {bridge.status()['hub']})", flush=True)
    if args.open:
        import webbrowser

        threading.Timer(0.5, lambda: webbrowser.open(f"http://127.0.0.1:{args.port}/chat")).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
