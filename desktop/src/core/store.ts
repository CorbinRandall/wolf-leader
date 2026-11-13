// The app's own state: settings, every chat, and the AI running each chat.
// Chats are kept in the same form the Mac app uses and synced through the hub, so a chat
// started on one computer (or in one app) continues on another exactly as it was.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentByID, findTool, scanAgents, type FoundAgent } from "./agents";
import { makeDriver, type AgentDriver, type AgentEvent, type PermissionMode } from "./drivers";
import { Hub } from "./hub";
import { isoMs, nowApple, oneLine, safeSlug, uuid, APPLE_EPOCH } from "./util";

export interface ChatItem {
  id: string;
  kind: "user" | "agent" | "thinking" | "tool" | "approval" | "error" | "note";
  text: string;
  detail: string;
  output: string;
  status?: "running" | "done" | "failed" | "pending" | "allowed" | "denied";
  at: number;
}

export interface ChatRecord {
  id: string;
  projectID?: number;
  projectName?: string;
  projectSlug?: string;
  agentID: string;
  title: string;
  cwd: string;
  mode: PermissionMode;
  model?: string;
  effort?: string;
  agentSessionID?: string;
  items: ChatItem[];
  created: number;
  updated: number;
  contextSent: boolean;
  agentDevice?: string;
  activeDevice?: string;
  activeUntil?: number;
  needsHandoff?: boolean;
  screenControlDevice?: string;
}

export interface Config {
  hubURL: string;
  deviceName: string;
  person?: string;
  agentID: string;
  theme?: string;
}

export interface NewChat {
  agentID: string;
  project?: { id: number; name: string; slug: string };
  model?: string;
  effort?: string;
}

const TOOLS_NOTE = (slug?: string) => `<wolf_leader_tools>
You have the wolf-leader tools: Wolf Leader is the user's memory across every AI they use. Use them when the conversation needs something you weren't given above:
- search: find anything in their projects, memories and past chats (any assistant, any device)
- recall / get_brief / get_memories${slug ? ` (this project: ${slug})` : ""}: a project's full context
- get_session: read an earlier chat in full; get_profile: who the user is
- remember: record a decision, constraint, problem or open work worth keeping for the next chat
- add_to_profile: something lasting the user said about themselves
Wolf Leader saves this chat and files it in its project on its own: never save the chat, howl, or create or switch projects.
</wolf_leader_tools>`;

const MEMORY_ORDER = ["goal", "constraint", "decision", "active_work", "problem", "caveat", "note"];
const clip = (text: string, limit: number) => (text.length > limit ? text.slice(0, limit) + "\n…" : text);

/** One chat while the app is open: its record, and the agent running it. */
class Session {
  driver: AgentDriver | null = null;
  busy = false;
  private saveTimer: NodeJS.Timeout | null = null;
  private pushTimer: NodeJS.Timeout | null = null;

  constructor(private store: Store, public record: ChatRecord) {}

  private touch(): void {
    this.record.updated = nowApple();
    this.store.changed(this);
    if (!this.saveTimer) {
      this.saveTimer = setTimeout(() => {
        this.saveTimer = null;
        this.store.writeLocal(this.record);
      }, 400);
    }
  }

  private add(kind: ChatItem["kind"], text: string, extra: Partial<ChatItem> = {}): ChatItem {
    const item: ChatItem = { id: uuid(), kind, text, detail: "", output: "", at: nowApple(), ...extra };
    this.record.items.push(item);
    return item;
  }

  private find(id: string, kind: ChatItem["kind"]): ChatItem | undefined {
    for (let i = this.record.items.length - 1; i >= 0; i--) {
      const item = this.record.items[i];
      if (item.id === id && item.kind === kind) return item;
    }
    return undefined;
  }

  apply(event: AgentEvent): void {
    switch (event.type) {
      case "session":
        this.record.agentSessionID = event.id;
        this.record.agentDevice = this.store.config.deviceName;
        break;
      case "textDelta":
      case "thinkingDelta":
      case "text": {
        const kind = event.type === "thinkingDelta" ? "thinking" : "agent";
        const item = this.find(event.id, kind);
        if (!item) this.add(kind, event.text, { id: event.id });
        else if (event.type === "text") item.text = event.text;
        else item.text += event.text;
        break;
      }
      case "toolStarted":
        if (!this.find(event.id, "tool")) this.add("tool", event.title, { id: event.id, detail: event.detail, status: "running" });
        break;
      case "toolUpdated": {
        const item = this.find(event.id, "tool");
        if (item) {
          if (event.output) item.output = event.output;
          if (event.status) item.status = event.status;
        }
        break;
      }
      case "approval":
        if (!event.mustAsk && (this.store.rules.never_ask || this.record.mode === "auto")) {
          // "Never ask": approve it for good, so the agent doesn't ask about this again.
          this.add("approval", event.title, { id: event.id, detail: event.detail, status: "allowed" });
          setImmediate(() => this.driver?.answer(event.id, true, true));
        } else {
          this.add("approval", event.title, { id: event.id, detail: event.detail, status: "pending" });
        }
        break;
      case "note":
        this.add("note", event.text);
        break;
      case "turnFinished":
        if (event.error) this.add("error", event.error);
        this.finishTurn();
        break;
      case "exited":
        this.driver = null;
        if (event.reason) this.add("error", event.reason);
        if (this.busy) this.finishTurn();
        break;
    }
    this.touch();
  }

  private finishTurn(): void {
    this.busy = false;
    delete this.record.activeDevice;
    delete this.record.activeUntil;
    for (const item of this.record.items) {
      if (item.status === "running") item.status = "done";
      if (item.status === "pending") item.status = "denied";
    }
    this.touch();
    this.store.writeLocal(this.record);
    this.store.push(this.record);
    this.store.file(this.record).catch((error) => console.error("couldn't file the chat:", error));
  }

  send(text: string, attachments: string[] = []): void {
    if (this.busy) throw new Error("This chat is still working.");
    const other = this.record.activeDevice;
    if (other && other !== this.store.config.deviceName && (this.record.activeUntil ?? 0) > nowApple()) {
      throw new Error(`This chat is working on ${other} right now.`);
    }
    // "Never ask" applies to every chat, old ones too.
    if (this.store.rules.never_ask && this.record.mode !== "auto") {
      this.record.mode = "auto";
      this.driver?.stop();
      this.driver = null;
    }
    const earlier = this.record.items.slice();
    const shown = [text, attachments.length ? attachments.map((f) => `📎 ${path.basename(f)}`).join("  ") : ""].filter(Boolean).join("\n\n");
    this.add("user", shown);
    if (this.record.title === "New chat") this.record.title = oneLine(text || shown, 60);
    this.busy = true;
    this.record.activeDevice = this.store.config.deviceName;
    this.record.activeUntil = nowApple() + 600;
    this.touch();
    this.schedulePush();
    this.run(text, attachments, earlier).catch((error) => {
      this.add("error", String(error?.message ?? error));
      this.finishTurn();
    });
  }

  private async run(text: string, attachments: string[], earlier: ChatItem[]): Promise<void> {
    if (!this.driver) await this.connect();
    const parts: string[] = [];
    if (!this.record.contextSent || this.record.needsHandoff) {
      const context = await this.store.context(this.record);
      if (context) parts.push(context);
      if (this.store.rules.hub_tools !== false) parts.push(TOOLS_NOTE(this.record.projectSlug));
      const rules = String(this.store.rules.rules ?? "").trim();
      if (rules) parts.push(`<your_rules>\n${rules}\n</your_rules>`);
    }
    if (this.record.needsHandoff) {
      const handoff = Store.handoff(earlier, agentByID(this.record.agentID)?.name ?? "the agent");
      if (handoff) parts.push(handoff);
    }
    if (text) parts.push(text);
    this.record.contextSent = true;
    delete this.record.needsHandoff;
    await this.driver!.send(parts.join("\n\n"), attachments);
  }

  private async connect(): Promise<void> {
    const agent = agentByID(this.record.agentID);
    if (!agent) throw new Error("This chat's agent isn't known to this version of Wolf Leader.");
    const executable = findTool(agent.binary);
    if (!executable) throw new Error(`${agent.name} isn't set up on this computer yet. ${agent.installHint}`);
    if (!this.record.cwd || !fs.existsSync(this.record.cwd)) this.record.cwd = this.store.folderFor(this.record);
    // An agent session only exists on the device that ran it. Anywhere else (or with no session
    // to resume) the agent starts fresh and is handed the conversation so far.
    const resumable = !this.record.agentDevice || this.record.agentDevice === this.store.config.deviceName;
    const resumeID = resumable ? this.record.agentSessionID ?? null : null;
    if (!resumeID && this.record.items.filter((i) => i.kind === "user").length > 1) this.record.needsHandoff = true;
    const driver = makeDriver(agent.proto, {
      name: agent.name, executable, args: agent.args, cwd: this.record.cwd, mode: this.record.mode, resumeID,
      model: this.record.model ?? null, effort: this.record.effort ?? null,
      toolsURL: this.store.rules.hub_tools === false ? null : this.store.hub.mcpURL(),
      stateDir: this.store.dir,
      emit: (event) => this.apply(event),
    });
    this.driver = driver;
    try {
      await driver.start();
    } catch (error) {
      driver.stop();
      this.driver = null;
      throw error;
    }
  }

  answer(itemID: string, allow: boolean, always = false): void {
    const item = this.find(itemID, "approval");
    if (!item || item.status !== "pending") return;
    item.status = allow ? "allowed" : "denied";
    this.driver?.answer(itemID, allow, always);
    this.touch();
  }

  interrupt(): void {
    this.driver?.interrupt();
  }

  /** The mode, model and effort are fixed when an agent starts, so it restarts (resuming its
   *  session) for the next message. */
  set(changes: Partial<Pick<ChatRecord, "mode" | "model" | "effort">>): void {
    Object.assign(this.record, changes);
    for (const key of ["model", "effort"] as const) if (!this.record[key]) delete this.record[key];
    if (!this.busy) {
      this.driver?.stop();
      this.driver = null;
    }
    this.touch();
    this.schedulePush();
  }

  /** Continue this chat with another AI: it is handed the conversation so far. */
  switchAgent(agentID: string): void {
    if (this.busy || agentID === this.record.agentID) return;
    this.driver?.stop();
    this.driver = null;
    this.record.agentID = agentID;
    delete this.record.agentSessionID;
    delete this.record.model;
    delete this.record.effort;
    this.record.needsHandoff = true;
    this.add("note", `Continuing with ${agentByID(agentID)?.name ?? agentID}. It gets the conversation so far with your next message.`);
    this.touch();
    this.schedulePush();
  }

  attach(project: { id: number; name: string; slug: string }): void {
    if (project.id === this.record.projectID) return;
    this.record.projectID = project.id;
    this.record.projectName = project.name;
    this.record.projectSlug = project.slug;
    this.record.contextSent = false;
    this.add("note", `Connected to ${project.name}. The next message brings in its notes.`);
    this.touch();
    this.store.push(this.record);
    this.store.file(this.record).catch(() => {});
  }

  private schedulePush(): void {
    if (this.pushTimer) clearTimeout(this.pushTimer);
    this.pushTimer = setTimeout(() => this.store.push(this.record), 1500);
  }

  shutdown(): void {
    this.driver?.stop();
    this.driver = null;
    this.busy = false;
  }
}

export class Store {
  config: Config;
  hub: Hub;
  rules: any = {};
  agents: FoundAgent[] = [];
  records = new Map<string, ChatRecord>();
  private sessions = new Map<string, Session>();
  private since: string | null = null;
  onChat: (snapshot: { record: ChatRecord; busy: boolean }) => void = () => {};
  onList: () => void = () => {};

  constructor(public dir: string) {
    fs.mkdirSync(path.join(dir, "chats"), { recursive: true });
    this.config = this.readConfig();
    this.hub = new Hub(this.config.hubURL);
    for (const file of fs.readdirSync(path.join(dir, "chats"))) {
      if (!file.endsWith(".json")) continue;
      try {
        const record = JSON.parse(fs.readFileSync(path.join(dir, "chats", file), "utf8"));
        if (record?.id) this.records.set(record.id, record);
      } catch {}
    }
    this.agents = scanAgents();
  }

  // ---- settings
  private configFile(): string {
    return path.join(this.dir, "config.json");
  }

  private readConfig(): Config {
    let saved: Partial<Config> = {};
    try {
      saved = JSON.parse(fs.readFileSync(this.configFile(), "utf8"));
    } catch {}
    return {
      hubURL: saved.hubURL || Store.setupHubURL() || "http://127.0.0.1:6971",
      deviceName: saved.deviceName || os.hostname().split(".")[0] || "this computer",
      person: saved.person,
      agentID: saved.agentID || "claude",
      theme: saved.theme,
    };
  }

  /** The hub address Wolf Leader's setup already wrote for the AI tools on this computer. */
  static setupHubURL(): string | null {
    for (const file of [".claude/wolf-leader.env", ".cursor/wolf-leader.env"]) {
      try {
        const match = fs.readFileSync(path.join(os.homedir(), file), "utf8").match(/^WOLF_LEADER_API=(\S+)/m);
        if (match) return match[1];
      } catch {}
    }
    return null;
  }

  setConfig(changes: Partial<Config>): void {
    const hubChanged = changes.hubURL !== undefined && changes.hubURL.trim() !== this.config.hubURL;
    Object.assign(this.config, changes);
    this.config.hubURL = this.config.hubURL.trim().replace(/\/+$/, "");
    fs.writeFileSync(this.configFile(), JSON.stringify(this.config, null, 2));
    if (hubChanged) {
      this.hub = new Hub(this.config.hubURL);
      this.since = null;
      this.refresh().catch(() => {});
    }
  }

  // ---- chats on this computer
  writeLocal(record: ChatRecord): void {
    this.records.set(record.id, record);
    try {
      fs.writeFileSync(path.join(this.dir, "chats", `${record.id}.json`), JSON.stringify(record));
    } catch (error) {
      console.error("couldn't save a chat:", error);
    }
  }

  changed(session: Session): void {
    this.records.set(session.record.id, session.record);
    this.onChat({ record: session.record, busy: session.busy });
  }

  session(id: string): Session | null {
    const open = this.sessions.get(id);
    if (open) return open;
    const record = this.records.get(id);
    if (!record) return null;
    const session = new Session(this, record);
    this.sessions.set(id, session);
    return session;
  }

  isRunning(id: string): boolean {
    return this.sessions.get(id)?.busy ?? false;
  }

  create(fresh: NewChat): Session {
    const record: ChatRecord = {
      id: uuid(), agentID: fresh.agentID, title: "New chat", cwd: "", items: [], created: nowApple(), updated: nowApple(),
      mode: this.rules.never_ask ? "auto" : ["ask", "edits", "auto"].includes(this.rules.default_mode) ? this.rules.default_mode : "ask",
      contextSent: false,
    };
    if (fresh.project) Object.assign(record, { projectID: fresh.project.id, projectName: fresh.project.name, projectSlug: fresh.project.slug });
    if (fresh.model) record.model = fresh.model;
    if (fresh.effort) record.effort = fresh.effort;
    record.cwd = this.folderFor(record);
    this.records.set(record.id, record);
    const session = new Session(this, record);
    this.sessions.set(record.id, session);
    return session;
  }

  remove(id: string): void {
    this.sessions.get(id)?.shutdown();
    this.sessions.delete(id);
    this.records.delete(id);
    try {
      fs.unlinkSync(path.join(this.dir, "chats", `${id}.json`));
    } catch {}
    this.hub.request("DELETE", `/api/app-chats/${id}?device=${encodeURIComponent(this.config.deviceName)}`).catch(() => {});
    this.onList();
  }

  folderFor(record: ChatRecord): string {
    const folder = record.projectSlug
      ? path.join(this.dir, "projects", safeSlug(record.projectSlug))
      : path.join(this.dir, "loose-chats", record.id);
    fs.mkdirSync(folder, { recursive: true });
    return folder;
  }

  stopAll(): void {
    for (const session of this.sessions.values()) session.shutdown();
  }

  // ---- the hub
  /** Bring in the rules and every chat changed on other devices since the last pull. */
  async refresh(): Promise<void> {
    this.agents = scanAgents();
    const rules = await this.hub.tryGet("/api/chat-rules");
    if (rules && typeof rules === "object") this.rules = rules;
    if (!this.config.person) {
      const who = await this.hub.tryGet("/api/whoami");
      if (who?.person) this.config.person = who.person;
    }
    await this.pull();
    this.onList();
  }

  async pull(): Promise<void> {
    const data = await this.hub.tryGet(`/api/app-chats?limit=2000${this.since ? `&since=${encodeURIComponent(this.since)}` : ""}`);
    if (!data?.chats) return;
    for (const row of data.chats) {
      if (row.deleted) {
        if (this.records.has(row.id) && !this.isRunning(row.id)) {
          this.sessions.delete(row.id);
          this.records.delete(row.id);
          try {
            fs.unlinkSync(path.join(this.dir, "chats", `${row.id}.json`));
          } catch {}
        }
        continue;
      }
      const remote: ChatRecord | null = row.record;
      if (!remote?.id || !Array.isArray(remote.items)) continue;
      const mine = this.records.get(remote.id);
      if (mine && (mine.updated >= remote.updated || this.isRunning(remote.id))) continue;
      const session = this.sessions.get(remote.id);
      if (session) {
        // Another device carried this chat on: take its copy, and start the agent fresh next time.
        session.driver?.stop();
        session.driver = null;
        session.record = remote;
      }
      this.writeLocal(remote);
      if (session) this.onChat({ record: remote, busy: false });
    }
    if (typeof data.now === "string") this.since = data.now;
  }

  async push(record: ChatRecord): Promise<void> {
    if (!record.items.some((i) => i.kind === "user")) return;
    const body: any = { record, updated: isoMs(record.updated), device: this.config.deviceName, title: record.title, agent_id: record.agentID };
    if (record.projectID !== undefined) body.project_id = record.projectID;
    try {
      await this.hub.request("PUT", `/api/app-chats/${record.id}`, body);
    } catch (error: any) {
      // Another device changed this chat after us: take its copy.
      const remote = error?.status === 409 ? error.body?.detail?.chat?.record : null;
      if (remote?.id && !this.isRunning(remote.id)) {
        const session = this.sessions.get(remote.id);
        if (session) session.record = remote;
        this.writeLocal(remote);
        this.onChat({ record: remote, busy: false });
      }
    }
  }

  /** Save (or update) the chat in its project's logbook, as the Mac app does after every reply. */
  async file(chat: ChatRecord): Promise<void> {
    const messages: { role: string; content: string }[] = [];
    let total = 0;
    for (let i = chat.items.length - 1; i >= 0; i--) {
      const item = chat.items[i];
      const entry =
        item.kind === "user" ? { role: "user", content: item.text.slice(0, 20_000) }
        : item.kind === "agent" ? { role: "assistant", content: item.text.slice(0, 20_000) }
        : item.kind === "tool" ? { role: "assistant", content: `[step] ${item.text}` }
        : null;
      if (!entry || !entry.content.trim()) continue;
      total += entry.content.length;
      if (total > 600_000) break;
      messages.unshift(entry);
    }
    if (!messages.some((m) => m.role === "user")) return;
    const agentName = agentByID(chat.agentID)?.name ?? chat.agentID;
    const lastReply = [...chat.items].reverse().find((i) => i.kind === "agent")?.text ?? "";
    const firstAsk = chat.items.find((i) => i.kind === "user")?.text ?? "";
    const summary = `${agentName} chat in Wolf Leader${chat.agentDevice ? ` on ${chat.agentDevice}` : ""}${chat.projectName ? `, project ${chat.projectName}` : ""}.\n` +
      `Asked: ${oneLine(firstAsk, 600)}\nLatest reply: ${oneLine(lastReply, 1500)}`;
    const args: any = {
      title: `${agentName}: ${chat.title}`,
      content: summary,
      session_id: `wolf-chat-${chat.id}`,
      workspace_path: chat.cwd,
      messages_json: JSON.stringify(messages),
      occurred_at: new Date((chat.created + APPLE_EPOCH) * 1000).toISOString().replace(/\.\d+Z$/, "Z"),
    };
    if (chat.projectID !== undefined) args.project_id = chat.projectID;
    const reply = await this.hub.callTool("save_session", args);
    if (reply?.ok === false) throw new Error(reply.error ?? "The hub didn't save the chat.");
  }

  /** Everything an agent should know before the first message of a chat, as one block. */
  async context(record: ChatRecord): Promise<string | null> {
    const hub = this.hub;
    const who = this.config.person?.trim() || null;
    const pid = record.projectID;
    const key = record.projectSlug || (pid !== undefined ? String(pid) : null);
    const [about, shared, brief, memories, ledger] = await Promise.all([
      who ? hub.tryGet(`/api/people/${encodeURIComponent(who)}/profile.md`) : null,
      hub.tryGet(`/api/shared-context${pid !== undefined ? `?exclude=${pid}` : ""}`),
      key ? hub.tryGet(`/api/projects/${encodeURIComponent(key)}/agent-brief`, 60_000) : null,
      pid !== undefined ? hub.tryGet(`/api/memories?project_id=${pid}&limit=200`) : null,
      pid !== undefined ? hub.tryGet(`/api/projects/${pid}/chats?limit=12`) : null,
    ]);
    const sections: string[] = [];
    if (typeof about === "string" && about.trim()) sections.push(`<about_you person="${who}">\n${clip(about.trim(), 3000)}\n</about_you>`);
    if (shared?.text?.trim()) {
      sections.push(`<shared_context>\nApplies to every project: things the user set up once (servers, network, accounts and how to reach them).\n${clip(shared.text.trim(), 12_000)}\n</shared_context>`);
    }
    if (pid !== undefined) {
      const parts: string[] = [];
      const purpose = brief?.purpose_summary || brief?.description;
      const pickup = brief?.agent_prompt || brief?.pickup_prompt;
      if (purpose) parts.push(`Purpose: ${purpose}`);
      if (pickup) parts.push(`Where it was left off:\n${pickup}`);
      const rows: any[] = Array.isArray(memories) ? memories : memories?.memories ?? [];
      const picked = rows
        .filter((m) => String(m.content ?? "").trim())
        .sort((a, b) => (MEMORY_ORDER.indexOf(a.type) + 100) % 100 - (MEMORY_ORDER.indexOf(b.type) + 100) % 100)
        .slice(0, 25);
      if (picked.length) parts.push("Key memories:\n" + picked.map((m) => `- ${m.type}: ${oneLine(m.content, 400)}`).join("\n"));
      const chats: any[] = (Array.isArray(ledger) ? ledger : ledger?.chats ?? []).filter((c: any) => c.session_id !== `wolf-chat-${record.id}`).slice(0, 10);
      if (chats.length) {
        parts.push("Project ledger (recent chats in this project, newest first, from every assistant and device):\n" +
          chats.map((c) => `- ${String(c.occurred_at ?? c.updated_at ?? "").slice(0, 10)} ${oneLine(c.title, 80)}: ${oneLine(c.content ?? c.summary ?? "", 300)}`).join("\n"));
      }
      const name = record.projectName ?? "this project";
      sections.push(`<project name="${name}">\nThis chat is part of the Wolf Leader project "${name}". Wolf Leader writes it to the project's ledger after every reply, so the next chat (with any assistant, on any device) picks up from here.\n${clip(parts.join("\n\n"), 12_000)}\n</project>`);
    }
    if (!sections.length) return null;
    return `<wolf_leader_context>\nWolf Leader is the user's own memory across every AI assistant they use. Use this to pick up where things are; don't recite it back.\n${sections.join("\n\n")}\n</wolf_leader_context>`;
  }

  /** The conversation so far, for an agent that is picking a chat up (another device or another AI). */
  static handoff(items: ChatItem[], agentName: string): string | null {
    const lines = items
      .filter((i) => (i.kind === "user" || i.kind === "agent") && i.text.trim())
      .map((i) => `${i.kind === "user" ? "User" : "Assistant"}: ${i.text.slice(0, 4000)}`);
    if (!lines.length) return null;
    const cut = lines.length > 40;
    return `<wolf_leader_conversation_so_far>\nYou (${agentName}) are picking up a conversation that was already going in Wolf Leader, maybe on another device or with another assistant. Here it is${cut ? ", newest part" : ""}. Carry on from where it left off: don't repeat what was said, and treat the steps as already done.\n\n${lines.slice(-40).join("\n\n")}\n</wolf_leader_conversation_so_far>`;
  }
}
