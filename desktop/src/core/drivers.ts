// How Wolf Leader talks to each AI's command-line tool. One driver per protocol, all with the
// same shape, so a chat doesn't care which AI is behind it:
// - Claude Code's stream-json mode, with approvals over stdio
// - Codex's app-server (JSON-RPC over stdio)
// - the Agent Client Protocol, which Gemini, Grok, OpenCode, Kiro and others speak
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { JSONLines, JSONRPCPeer } from "./process";
import { describe, oneLine, uuid } from "./util";

export type PermissionMode = "ask" | "edits" | "auto";

export type AgentEvent =
  | { type: "session"; id: string }
  | { type: "textDelta"; id: string; text: string }
  | { type: "text"; id: string; text: string }
  | { type: "thinkingDelta"; id: string; text: string }
  | { type: "toolStarted"; id: string; title: string; detail: string }
  | { type: "toolUpdated"; id: string; output?: string; status?: "done" | "failed" | "running" }
  | { type: "approval"; id: string; title: string; detail: string; mustAsk?: boolean }
  | { type: "note"; text: string }
  | { type: "turnFinished"; error?: string | null }
  | { type: "exited"; reason?: string | null };

export interface DriverOptions {
  name: string;
  executable: string;
  args: string[];
  cwd: string;
  mode: PermissionMode;
  resumeID?: string | null;
  model?: string | null;
  effort?: string | null;
  /** The hub's MCP address (Wolf Leader's tools in this chat), or null for none. */
  toolsURL?: string | null;
  /** Where the driver may keep small config files. */
  stateDir: string;
  emit: (event: AgentEvent) => void;
}

export interface AgentDriver {
  start(): Promise<void>;
  send(text: string, attachments: string[]): Promise<void>;
  interrupt(): void;
  answer(approval: string, allow: boolean, always: boolean): void;
  stop(): void;
}

/** Wolf Leader's own tools in every chat. Saving the chat and choosing its project stay with
 *  Wolf Leader, so those tools are left out: an AI calling them would file a second copy. */
export const HUB_SERVER = "wolf-leader";
export const BLOCKED_TOOLS = ["save_session", "save_current_session", "wolfhowl", "wolfeat", "create_project", "set_project", "resolve_project"];

const IMAGE_EXT = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp"]);
const INLINE_LIMIT = 5 * 1024 * 1024;
export const isImage = (file: string) => IMAGE_EXT.has(path.extname(file).toLowerCase());
const mimeType = (file: string) =>
  ({ ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" } as Record<string, string>)[path.extname(file).toLowerCase()] || "image/png";
const fileNote = (files: string[]) => (files.length ? "Attached files:\n" + files.map((f) => `- ${f}`).join("\n") : "");

/** "Ran ls", "Edited main.swift": the tool and its main argument in a few words. */
export function claudeTitle(name: string, input: any): string {
  if (typeof input?.command === "string") return `Run \`${oneLine(input.command, 70)}\``;
  const file = input?.file_path ?? input?.path ?? input?.notebook_path;
  if (typeof file === "string") {
    const base = path.basename(file);
    const verb = ({ Read: "Read", Write: "Write", Edit: "Edit", MultiEdit: "Edit" } as Record<string, string>)[name] ?? name;
    return `${verb} ${base}`;
  }
  if (typeof input?.pattern === "string") return `${name} “${oneLine(input.pattern, 50)}”`;
  if (typeof input?.url === "string") return `${name} ${input.url}`;
  if (typeof input?.query === "string") return `${name} “${oneLine(input.query, 50)}”`;
  if (typeof input?.description === "string") return `${name}: ${oneLine(input.description, 60)}`;
  return name.replace("mcp__", "").replace(/__/g, " · ");
}

// ------------------------------------------------------------------ Claude
export class ClaudeDriver implements AgentDriver {
  private process?: JSONLines;
  private blocks = new Map<number, string>();
  private messageID = "";
  private streamed = new Set<string>();
  private approvals = new Map<string, any>();
  private exitReported = false;

  constructor(private o: DriverOptions) {}

  async start(): Promise<void> {
    const mode = { ask: "default", edits: "acceptEdits", auto: "bypassPermissions" }[this.o.mode];
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode];
    if (this.o.resumeID) args.push("--resume", this.o.resumeID);
    if (this.o.model) args.push("--model", this.o.model);
    if (this.o.effort) args.push("--effort", this.o.effort);
    if (this.o.toolsURL) {
      const dir = path.join(this.o.stateDir, "agents");
      fs.mkdirSync(dir, { recursive: true });
      const file = path.join(dir, "wolf-leader-mcp.json");
      fs.writeFileSync(file, JSON.stringify({ mcpServers: { [HUB_SERVER]: { type: "http", url: this.o.toolsURL } } }, null, 2));
      // Wolf Leader's own tools never need asking about; the save/project ones are off.
      args.push("--mcp-config", file, "--allowedTools", `mcp__${HUB_SERVER}`,
        "--disallowedTools", BLOCKED_TOOLS.map((t) => `mcp__${HUB_SERVER}__${t}`).join(","));
    }
    const process = new JSONLines(this.o.executable, args, this.o.cwd);
    process.onMessage = (m) => this.handle(m);
    process.onExit = (code, tail) => {
      if (this.exitReported) return;
      this.exitReported = true;
      this.o.emit({ type: "exited", reason: code === 0 && !tail ? null : tail ? oneLine(tail, 400) : `Claude stopped (exit ${code}).` });
    };
    this.process = process;
    process.send({ type: "control_request", request_id: "init", request: { subtype: "initialize" } });
  }

  async send(text: string, attachments: string[]): Promise<void> {
    if (!this.process?.running) throw new Error("Claude isn't running.");
    const content: any[] = [];
    const byPath: string[] = [];
    for (const file of attachments) {
      let data: Buffer | null = null;
      try {
        if (isImage(file) && fs.statSync(file).size <= INLINE_LIMIT) data = fs.readFileSync(file);
      } catch {}
      if (data) content.push({ type: "image", source: { type: "base64", media_type: mimeType(file), data: data.toString("base64") } });
      else byPath.push(file);
    }
    content.push({ type: "text", text: [text, fileNote(byPath)].filter(Boolean).join("\n\n") });
    this.process.send({ type: "user", message: { role: "user", content }, parent_tool_use_id: null, session_id: "" });
  }

  interrupt(): void {
    this.process?.send({ type: "control_request", request_id: uuid(), request: { subtype: "interrupt" } });
  }

  answer(id: string, allow: boolean, always: boolean): void {
    const request = this.approvals.get(id);
    if (!request) return;
    this.approvals.delete(id);
    const response: any = allow
      ? { behavior: "allow", updatedInput: request.input ?? {} }
      : { behavior: "deny", message: "The user said no to this step in Wolf Leader." };
    if (allow && always && Array.isArray(request.permission_suggestions)) response.updatedPermissions = request.permission_suggestions;
    this.process?.send({ type: "control_response", response: { subtype: "success", request_id: id, response } });
  }

  stop(): void {
    this.exitReported = true;
    this.process?.stop();
  }

  private handle(m: any): void {
    const emit = this.o.emit;
    switch (m.type) {
      case "system":
        if (m.subtype === "init" && m.session_id) emit({ type: "session", id: m.session_id });
        break;
      case "stream_event": {
        const e = m.event ?? {};
        if (e.type === "message_start") {
          this.messageID = e.message?.id ?? uuid();
          this.blocks.clear();
        } else if (e.type === "content_block_start") {
          this.blocks.set(e.index ?? 0, `${this.messageID}-${e.index ?? 0}`);
        } else if (e.type === "content_block_delta") {
          const key = this.blocks.get(e.index ?? 0);
          if (!key) break;
          if (e.delta?.type === "text_delta" && typeof e.delta.text === "string") {
            this.streamed.add(this.messageID);
            emit({ type: "textDelta", id: key, text: e.delta.text });
          } else if (typeof e.delta?.thinking === "string") {
            emit({ type: "thinkingDelta", id: key, text: e.delta.thinking });
          }
        }
        break;
      }
      case "assistant": {
        const id = m.message?.id ?? uuid();
        for (const block of m.message?.content ?? []) {
          if (block.type === "text" && !this.streamed.has(id) && block.text) {
            // Normally already shown from the stream; this catches text that arrived without it.
            emit({ type: "text", id: `${id}-full-${block.text.length}`, text: block.text });
          } else if (block.type === "tool_use") {
            emit({ type: "toolStarted", id: block.id ?? uuid(), title: claudeTitle(block.name ?? "Tool", block.input ?? {}), detail: describe(block.input ?? {}) });
          }
        }
        break;
      }
      case "user":
        for (const block of m.message?.content ?? []) {
          if (block?.type === "tool_result" && block.tool_use_id) {
            emit({ type: "toolUpdated", id: block.tool_use_id, output: describe(block.content), status: block.is_error ? "failed" : "done" });
          }
        }
        break;
      case "control_request": {
        const request = m.request ?? {};
        if (request.subtype !== "can_use_tool") {
          this.process?.send({ type: "control_response", response: { subtype: "error", request_id: m.request_id, error: "Not supported in Wolf Leader." } });
          break;
        }
        this.approvals.set(m.request_id, request);
        emit({ type: "approval", id: m.request_id, title: claudeTitle(request.display_name ?? request.tool_name ?? "a tool", request.input ?? {}), detail: describe(request.input ?? {}) });
        break;
      }
      case "result":
        emit({ type: "turnFinished", error: m.is_error ? m.result || "Claude reported an error." : null });
        break;
    }
  }
}

// ------------------------------------------------------------------- Codex
export class CodexDriver implements AgentDriver {
  private peer?: JSONRPCPeer;
  private threadID: string | null;
  private turnID: string | null = null;
  private approvals = new Map<string, any>();
  /** Approvals that are a tool's own question rather than a command or file change. */
  private toolQuestions = new Set<string>();
  private exitReported = false;

  constructor(private o: DriverOptions) {
    this.threadID = o.resumeID ?? null;
  }

  async start(): Promise<void> {
    // Config overrides go before the subcommand (`codex -c … app-server`).
    const args: string[] = [];
    if (this.o.toolsURL) {
      const list = BLOCKED_TOOLS.map((t) => `"${t}"`).join(",");
      // Codex holds MCP calls for approval on its own unless the server says otherwise;
      // Wolf Leader's tools are always fine to use.
      args.push("-c", `mcp_servers.${HUB_SERVER}.url="${this.o.toolsURL}"`,
        "-c", `mcp_servers.${HUB_SERVER}.disabled_tools=[${list}]`,
        "-c", `mcp_servers.${HUB_SERVER}.default_tools_approval_mode="approve"`,
        "-c", "mcp_servers.ide-storage.enabled=false");
    }
    if (this.o.effort) args.push("-c", `model_reasoning_effort="${this.o.effort}"`);
    args.push(...this.o.args);
    const peer = new JSONRPCPeer(new JSONLines(this.o.executable, args, this.o.cwd), false);
    peer.onNotification = (method, params) => this.handle(method, params);
    peer.onRequest = (id, method, params) => this.handleRequest(id, method, params);
    peer.onExit = (reason) => {
      if (this.exitReported) return;
      this.exitReported = true;
      this.o.emit({ type: "exited", reason });
    };
    this.peer = peer;
    await peer.request("initialize", { clientInfo: { name: "wolf-leader", title: "Wolf Leader", version: "3" } });
    peer.notify("initialized");
    const settings: any = {
      cwd: this.o.cwd,
      approvalPolicy: { ask: "untrusted", edits: "on-request", auto: "never" }[this.o.mode],
      sandbox: this.o.mode === "auto" ? "danger-full-access" : "workspace-write",
    };
    const model = this.o.model ?? (await this.usableModel(peer));
    if (model) settings.model = model;
    if (this.threadID) {
      try {
        await peer.request("thread/resume", { ...settings, threadId: this.threadID });
        return;
      } catch {
        this.o.emit({ type: "note", text: "Couldn't pick the old Codex thread back up, so this continues in a new one." });
      }
    }
    const result = await peer.request("thread/start", settings);
    if (result?.thread?.id) {
      this.threadID = result.thread.id;
      this.o.emit({ type: "session", id: result.thread.id });
    }
  }

  /** The model to ask for when the one in ~/.codex/config.toml isn't offered to this account
   *  (an old setting would otherwise fail every turn). null = leave Codex's choice alone. */
  private async usableModel(peer: JSONRPCPeer): Promise<string | null> {
    const configured = CodexDriver.configuredModel();
    if (!configured) return null;
    let listed: any;
    try {
      listed = await peer.request("model/list", {}, 20_000);
    } catch {
      return null;
    }
    const rows: any[] = listed?.data ?? listed?.models ?? [];
    const ids = rows.map((r) => r?.id ?? r?.model).filter(Boolean);
    if (!ids.length || ids.includes(configured)) return null;
    const fallback = rows.find((r) => r?.isDefault)?.id ?? rows.find((r) => r?.isDefault)?.model ?? ids[0];
    this.o.emit({ type: "note", text: `Codex is set to ${configured}, which your account doesn't offer, so this chat uses ${fallback}.` });
    return fallback;
  }

  /** The top-level `model = "…"` in ~/.codex/config.toml (before any [section]). */
  static configuredModel(): string | null {
    try {
      for (const raw of fs.readFileSync(path.join(os.homedir(), ".codex", "config.toml"), "utf8").split(/\r?\n/)) {
        const line = raw.trim();
        if (line.startsWith("[")) break;
        const match = line.match(/^model\s*=\s*["']?([^"']+)["']?\s*$/);
        if (match) return match[1].trim() || null;
      }
    } catch {}
    return null;
  }

  async send(text: string, attachments: string[]): Promise<void> {
    if (!this.peer || !this.threadID) throw new Error("Codex isn't running.");
    const images = attachments.filter(isImage);
    const body = [text, fileNote(attachments.filter((f) => !isImage(f)))].filter(Boolean).join("\n\n");
    const input: any[] = [{ type: "text", text: body }, ...images.map((p) => ({ type: "localImage", path: p }))];
    const result = await this.peer.request("turn/start", { threadId: this.threadID, input });
    this.turnID = result?.turn?.id ?? null;
  }

  interrupt(): void {
    if (this.peer && this.threadID && this.turnID) this.peer.request("turn/interrupt", { threadId: this.threadID, turnId: this.turnID }, 15_000).catch(() => {});
  }

  answer(id: string, allow: boolean, always: boolean): void {
    const requestID = this.approvals.get(id);
    if (requestID === undefined) return;
    this.approvals.delete(id);
    if (this.toolQuestions.delete(id)) {
      // A tool's own question (MCP elicitation) is answered accept / decline.
      this.peer?.respond(requestID, { action: allow ? "accept" : "decline", content: null, _meta: null });
    } else {
      this.peer?.respond(requestID, { decision: allow ? (always ? "acceptForSession" : "accept") : "decline" });
    }
  }

  stop(): void {
    this.exitReported = true;
    this.peer?.process.stop();
  }

  /** The command without the `/bin/zsh -lc '…'` wrapper Codex adds. */
  static command(item: any): string {
    let command: string = Array.isArray(item?.command) ? item.command.join(" ") : item?.command ?? "";
    for (const prefix of ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "powershell.exe -Command ", "pwsh -Command "]) {
      if (command.startsWith(prefix)) {
        command = command.slice(prefix.length);
        if (command.length >= 2 && (command[0] === "'" || command[0] === '"') && command.endsWith(command[0])) command = command.slice(1, -1);
      }
    }
    return command;
  }

  private handle(method: string, params: any): void {
    const emit = this.o.emit;
    const itemID = params.itemId ?? "";
    switch (method) {
      case "item/agentMessage/delta":
        if (typeof params.delta === "string") emit({ type: "textDelta", id: itemID, text: params.delta });
        break;
      case "item/reasoning/summaryTextDelta":
      case "item/reasoning/textDelta":
        if (typeof params.delta === "string") emit({ type: "thinkingDelta", id: itemID, text: params.delta });
        break;
      case "item/started": {
        const item = params.item ?? {};
        const id = item.id ?? uuid();
        if (item.type === "commandExecution") emit({ type: "toolStarted", id, title: `Run \`${oneLine(CodexDriver.command(item), 70)}\``, detail: "" });
        else if (item.type === "fileChange") {
          const paths = (item.changes ?? []).map((c: any) => path.basename(c.path ?? "")).filter(Boolean);
          const title = !paths.length ? "Edit files" : "Edit " + (paths.length > 3 ? `${paths.slice(0, 3).join(", ")} and ${paths.length - 3} more` : paths.join(", "));
          emit({ type: "toolStarted", id, title, detail: "" });
        } else if (item.type === "mcpToolCall") emit({ type: "toolStarted", id, title: `${item.server ?? "tool"} · ${item.tool ?? ""}`, detail: describe(item.arguments) });
        else if (item.type === "webSearch") emit({ type: "toolStarted", id, title: `Search the web “${item.query ?? ""}”`, detail: "" });
        break;
      }
      case "item/completed": {
        const item = params.item ?? {};
        const id = item.id ?? "";
        const status = ["failed", "declined"].includes(item.status) ? "failed" : "done";
        if (item.type === "agentMessage" && item.text) emit({ type: "text", id, text: item.text });
        else if (item.type === "commandExecution") emit({ type: "toolUpdated", id, output: item.aggregatedOutput ?? "", status });
        else if (item.type === "fileChange") emit({ type: "toolUpdated", id, output: (item.changes ?? []).map((c: any) => c.diff ?? "").join("\n"), status });
        else if (item.type === "mcpToolCall") emit({ type: "toolUpdated", id, output: describe(item.result ?? item.error), status });
        else if (item.type === "webSearch") emit({ type: "toolUpdated", id, status: "done" });
        break;
      }
      case "turn/completed": {
        const turn = params.turn ?? {};
        const error = turn.error?.message ?? null;
        this.turnID = null;
        emit({ type: "turnFinished", error: turn.status === "failed" ? error ?? "Codex couldn't finish." : error });
        break;
      }
      case "error":
        if (params.error?.message && !params.willRetry) emit({ type: "note", text: params.error.message });
        break;
    }
  }

  private handleRequest(id: any, method: string, params: any): void {
    const key = uuid();
    switch (method) {
      case "item/commandExecution/requestApproval":
      case "item/fileChange/requestApproval":
      case "execCommandApproval":
      case "applyPatchApproval": {
        this.approvals.set(key, id);
        const command = CodexDriver.command(params);
        let detail = params.reason ?? "";
        if (params.cwd) detail += (detail ? "\n" : "") + `In ${params.cwd}`;
        this.o.emit({ type: "approval", id: key, title: command ? `Run \`${oneLine(command, 70)}\`` : "Change files", detail });
        break;
      }
      case "mcpServer/elicitation/request":
        // Codex asks before it calls a tool from an MCP server it wasn't told to trust.
        this.approvals.set(key, id);
        this.toolQuestions.add(key);
        this.o.emit({ type: "approval", id: key, title: `Use ${params.serverName ?? "a tool"}`, detail: params.message ?? "" });
        break;
      default:
        this.peer?.respondError(id, `Wolf Leader doesn't handle ${method} yet.`);
    }
  }
}

// --------------------------------------------------------------------- ACP
/** Any agent that speaks the Agent Client Protocol (Gemini, Grok, OpenCode, Kiro, Copilot, Fx). */
export class AcpDriver implements AgentDriver {
  private peer?: JSONRPCPeer;
  private sessionID: string | null;
  private approvals = new Map<string, { requestID: any; allow?: string; always?: string; reject?: string }>();
  /** Text arrives in chunks; a tool call in between starts a new message. */
  private textID = uuid();
  private thoughtID = uuid();
  /** While an old session is loading, the agent replays it; that history is already on screen. */
  private replaying = false;
  private exitReported = false;

  constructor(private o: DriverOptions) {
    this.sessionID = o.resumeID ?? null;
  }

  async start(): Promise<void> {
    const peer = new JSONRPCPeer(new JSONLines(this.o.executable, this.o.args, this.o.cwd), true);
    peer.onNotification = (method, params) => this.handle(method, params);
    peer.onRequest = (id, method, params) => this.handleRequest(id, method, params);
    peer.onExit = (reason) => {
      if (this.exitReported) return;
      this.exitReported = true;
      this.o.emit({ type: "exited", reason });
    };
    this.peer = peer;
    const hello = await peer.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: "wolf-leader", title: "Wolf Leader", version: "3" },
    });
    const capabilities = hello?.agentCapabilities ?? {};
    // Wolf Leader's tools, for agents that can take an HTTP MCP server.
    const servers = this.o.toolsURL && capabilities.mcpCapabilities?.http === true
      ? [{ type: "http", name: HUB_SERVER, url: this.o.toolsURL, headers: [] }]
      : [];
    if (this.sessionID && capabilities.loadSession) {
      this.replaying = true;
      try {
        await peer.request("session/load", { sessionId: this.sessionID, cwd: this.o.cwd, mcpServers: servers });
        this.replaying = false;
        return;
      } catch {
        this.replaying = false;
      }
    }
    if (this.sessionID) this.o.emit({ type: "note", text: `${this.o.name} can't reopen the old session, so this continues in a new one.` });
    const result = await peer.request("session/new", { cwd: this.o.cwd, mcpServers: servers });
    if (!result?.sessionId) throw new Error(`${this.o.name} didn't start a session.`);
    this.sessionID = result.sessionId;
    this.o.emit({ type: "session", id: result.sessionId });
  }

  async send(text: string, attachments: string[]): Promise<void> {
    if (!this.peer || !this.sessionID) throw new Error(`${this.o.name} isn't running.`);
    this.textID = uuid();
    const body = [text, fileNote(attachments)].filter(Boolean).join("\n\n");
    // A turn can run for a long time; the answer to session/prompt is what ends it.
    this.peer
      .request("session/prompt", { sessionId: this.sessionID, prompt: [{ type: "text", text: body }] }, 6 * 3600_000)
      .then((result) => this.o.emit({ type: "turnFinished", error: result?.stopReason === "refusal" ? `${this.o.name} refused to continue.` : null }))
      .catch((error) => this.o.emit({ type: "turnFinished", error: String(error?.message ?? error) }));
  }

  interrupt(): void {
    if (this.sessionID) this.peer?.notify("session/cancel", { sessionId: this.sessionID });
  }

  answer(id: string, allow: boolean, always: boolean): void {
    const pending = this.approvals.get(id);
    if (!pending) return;
    this.approvals.delete(id);
    const option = allow ? (always ? pending.always ?? pending.allow : pending.allow) : pending.reject;
    this.peer?.respond(pending.requestID, { outcome: option ? { outcome: "selected", optionId: option } : { outcome: "cancelled" } });
  }

  stop(): void {
    this.exitReported = true;
    this.peer?.process.stop();
  }

  private handle(method: string, params: any): void {
    if (method !== "session/update" || this.replaying) return;
    const update = params.update ?? {};
    const emit = this.o.emit;
    const text = update.content?.type === "text" ? update.content.text : null;
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
        if (text) emit({ type: "textDelta", id: this.textID, text });
        break;
      case "agent_thought_chunk":
        if (text) emit({ type: "thinkingDelta", id: this.thoughtID, text });
        break;
      case "tool_call":
        this.textID = uuid();
        this.thoughtID = uuid();
        emit({ type: "toolStarted", id: update.toolCallId ?? uuid(), title: update.title ?? "Tool", detail: describe(update.rawInput) });
        break;
      case "tool_call_update": {
        const status = ({ completed: "done", failed: "failed", pending: "running", in_progress: "running" } as any)[update.status];
        const output = (update.content ?? []).map((c: any) => (c?.content?.type === "text" ? c.content.text : "")).filter(Boolean).join("\n");
        emit({ type: "toolUpdated", id: update.toolCallId ?? "", output: output || describe(update.rawOutput) || undefined, status });
        break;
      }
    }
  }

  private handleRequest(id: any, method: string, params: any): void {
    if (method !== "session/request_permission") {
      this.peer?.respondError(id, `Wolf Leader doesn't handle ${method} yet.`);
      return;
    }
    const options: any[] = params.options ?? [];
    const option = (kind: string) => options.find((o) => o.kind === kind)?.optionId;
    const allow = option("allow_once") ?? option("allow_always");
    const call = params.toolCall ?? {};
    const kind = call.kind ?? "";
    // Auto-edit lets file edits and reads through; Full auto lets everything through.
    if (allow && (this.o.mode === "auto" || (this.o.mode === "edits" && ["edit", "read", "search", "think", "fetch"].includes(kind)))) {
      this.peer?.respond(id, { outcome: { outcome: "selected", optionId: allow } });
      return;
    }
    const key = uuid();
    this.approvals.set(key, { requestID: id, allow, always: option("allow_always"), reject: option("reject_once") ?? option("reject_always") });
    this.o.emit({ type: "approval", id: key, title: call.title ?? "Allow this step?", detail: describe(call.rawInput) });
  }
}

export function makeDriver(proto: "claude" | "codex" | "acp", options: DriverOptions): AgentDriver {
  if (proto === "claude") return new ClaudeDriver(options);
  if (proto === "codex") return new CodexDriver(options);
  return new AcpDriver(options);
}
