// The screens. One app for Windows, Mac and Linux; it follows the Mac app screen for screen:
// projects first in the sidebar, a home page to start or pick up, a chat, a project's page,
// search and settings.
import { createRoot } from "react-dom/client";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

declare global {
  interface Window {
    wolf: { call: (name: string, ...args: any[]) => Promise<any>; on: (channel: string, listener: (payload: any) => void) => () => void };
    __nav?: (route: string) => void;
  }
}
const call = window.wolf.call;
const APPLE = 978307200;

// ---------------------------------------------------------------- helpers
type Route = { page: "home" | "chat" | "project" | "projects" | "chats" | "search" | "settings"; id?: string; tab?: string; q?: string; project?: any };

const oneLine = (s: any, n = 80) => {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n) + "…" : t;
};
function when(apple?: number | null): string {
  if (!apple) return "";
  const d = new Date((apple + APPLE) * 1000);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return d.toLocaleDateString([], { month: "short", day: "numeric", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}
const whenISO = (iso?: string | null) => (iso ? when(Date.parse(iso.endsWith("Z") || iso.includes("+") ? iso : iso + "Z") / 1000 - APPLE) : "");
const isOpen = (p: any) => !["done", "archived"].includes(p.status);

/** A small, safe Markdown: headings, lists, code, bold, links. Enough to read an AI's reply. */
function inline(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  const pattern = /(`[^`\n]+`)|(\*\*[^*\n]+\*\*)|(\[[^\]\n]+\]\((https?:\/\/[^)\s]+)\))|(https?:\/\/[^\s)]+)/g;
  let last = 0;
  let match: RegExpExecArray | null;
  let n = 0;
  while ((match = pattern.exec(text))) {
    if (match.index > last) out.push(text.slice(last, match.index));
    const k = `${key}-${n++}`;
    if (match[1]) out.push(<code key={k}>{match[1].slice(1, -1)}</code>);
    else if (match[2]) out.push(<b key={k}>{match[2].slice(2, -2)}</b>);
    else if (match[3]) out.push(<a key={k} href={match[4]} target="_blank" rel="noreferrer">{match[3].slice(1, match[3].indexOf("]"))}</a>);
    else out.push(<a key={k} href={match[5]} target="_blank" rel="noreferrer">{match[5]}</a>);
    last = match.index + match[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}
function Markdown({ text }: { text: string }) {
  const blocks = useMemo(() => {
    const nodes: ReactNode[] = [];
    const parts = String(text ?? "").split(/```/);
    parts.forEach((part, i) => {
      if (i % 2) {
        nodes.push(<pre key={`c${i}`}><code>{part.replace(/^[a-zA-Z0-9_+-]*\n/, "")}</code></pre>);
        return;
      }
      let list: ReactNode[] = [];
      const flush = () => {
        if (list.length) nodes.push(<ul key={`u${i}-${nodes.length}`}>{list}</ul>);
        list = [];
      };
      part.split("\n").forEach((line, j) => {
        const key = `${i}-${j}`;
        const heading = line.match(/^(#{1,4})\s+(.*)$/);
        const bullet = line.match(/^\s*(?:[-*•]|\d+\.)\s+(.*)$/);
        if (bullet) list.push(<li key={key}>{inline(bullet[1], key)}</li>);
        else {
          flush();
          if (heading) nodes.push(<div key={key} className={`md-h md-h${heading[1].length}`}>{inline(heading[2], key)}</div>);
          else if (line.trim()) nodes.push(<p key={key}>{inline(line, key)}</p>);
        }
      });
      flush();
    });
    return nodes;
  }, [text]);
  return <div className="md">{blocks}</div>;
}

// ------------------------------------------------------------------ data
interface AppState { version: string; platform: string; config: any; agents: any[]; rules: any; hubOK: boolean; chats: any[] }

function useApp() {
  const [app, setApp] = useState<AppState | null>(null);
  const [projects, setProjects] = useState<any[]>([]);
  const [progress, setProgress] = useState<Record<number, any>>({});
  const loadProjects = async () => {
    const [p, g] = await Promise.all([call("hub.get", "/api/projects").catch(() => null), call("hub.get", "/api/progress").catch(() => null)]);
    if (p?.projects) setProjects(p.projects);
    if (g?.projects) setProgress(Object.fromEntries(g.projects.map((x: any) => [x.project_id ?? x.id, x])));
  };
  const reload = async () => {
    setApp(await call("refresh").catch(() => call("state")));
    await loadProjects();
  };
  useEffect(() => {
    call("state").then(setApp);
    reload();
    const offList = window.wolf.on("list", (chats) => setApp((a) => (a ? { ...a, chats } : a)));
    const timer = setInterval(async () => {
      const s = await call("state").catch(() => null);
      if (s) setApp(s);
    }, 30_000);
    return () => {
      offList();
      clearInterval(timer);
    };
  }, []);
  return { app, setApp, projects, progress, reload, loadProjects };
}
type Ctx = ReturnType<typeof useApp> & { go: (r: Route) => void; route: Route; app: AppState };

/** Is an agent working in this project, does it need you, or where did it stop. */
function pulse(ctx: Ctx, project: any): { line: string; state: "needsYou" | "working" | "idle" } {
  const chats = ctx.app.chats.filter((c) => c.projectID === project.id);
  if (chats.some((c) => c.needsYou)) return { line: "Needs your OK", state: "needsYou" };
  if (chats.some((c) => c.running)) return { line: "Working…", state: "working" };
  const pr = ctx.progress[project.id];
  if (pr?.next_step?.text) return { line: "Next: " + oneLine(pr.next_step.text), state: "idle" };
  if (pr?.where_it_stands) return { line: oneLine(pr.where_it_stands), state: "idle" };
  return { line: oneLine(project.description) || "Not started", state: "idle" };
}
function lastUsed(ctx: Ctx, project: any): number {
  const chat = Math.max(0, ...ctx.app.chats.filter((c) => c.projectID === project.id).map((c) => c.updated + APPLE));
  const hub = Date.parse(ctx.progress[project.id]?.last_session ?? project.updated_at ?? "") / 1000 || 0;
  return Math.max(chat, hub);
}
const latestChat = (ctx: Ctx, projectID: number) => ctx.app.chats.filter((c) => c.projectID === projectID).sort((a, b) => b.updated - a.updated)[0];
/** Pick the project back up: its latest conversation, or a new one when it has none. */
function resume(ctx: Ctx, project: any) {
  const chat = latestChat(ctx, project.id);
  if (chat) ctx.go({ page: "chat", id: chat.id });
  else ctx.go({ page: "home", project });
}
const refOf = (p: any) => ({ id: p.id, name: p.name, slug: p.slug || String(p.id) });

// ---------------------------------------------------------------- sidebar
function Sidebar({ ctx }: { ctx: Ctx }) {
  const [all, setAll] = useState(false);
  const open = ctx.projects.filter(isOpen).sort((a, b) => lastUsed(ctx, b) - lastUsed(ctx, a));
  const current = ctx.route.page === "project" ? Number(ctx.route.id)
    : ctx.route.page === "chat" ? ctx.app.chats.find((c) => c.id === ctx.route.id)?.projectID : null;
  const shown = all ? open : open.filter((p, i) => i < 7 || p.id === current || pulse(ctx, p).state !== "idle");
  const loose = ctx.app.chats.some((c) => c.projectID == null);
  const item = (label: string, icon: string, active: boolean, onClick: () => void, extra?: ReactNode) => (
    <div className={`nav ${active ? "on" : ""}`} onClick={onClick}><span className="ico">{icon}</span><span className="grow">{label}</span>{extra}</div>
  );
  return (
    <aside className={`sidebar ${ctx.app.platform}`}>
      <div className="brand"><span className="mark">◭</span> WOLF LEADER</div>
      {item("New chat", "✎", ctx.route.page === "home", () => ctx.go({ page: "home" }))}
      {item("Search", "⌕", ctx.route.page === "search", () => ctx.go({ page: "search" }))}
      <div className="side-title">Projects</div>
      <div className="side-scroll">
        {shown.map((p) => {
          const s = pulse(ctx, p);
          return (
            <div key={p.id} className={`nav two ${p.id === current ? "on" : ""}`} onClick={() => ctx.go({ page: "project", id: String(p.id) })} title={p.name}>
              <div className="grow min0">
                <div className="ellip">{p.name}</div>
                <div className={`sub ellip ${s.state !== "idle" ? "live" : ""}`}>{s.line}</div>
              </div>
              {s.state === "needsYou" ? <span className="dot" title="Waiting for your OK" /> : s.state === "working" ? <span className="spin" title="Working" /> : null}
            </div>
          );
        })}
        {open.length > shown.length || (all && open.length > 7) ? (
          <div className="more" onClick={() => setAll(!all)}>{all ? "Show fewer" : `${open.length - shown.length} more`}</div>
        ) : null}
        {item("All projects", "☰", ctx.route.page === "projects", () => ctx.go({ page: "projects" }))}
        {loose ? item("Loose chats", "▤", ctx.route.page === "chats", () => ctx.go({ page: "chats" })) : null}
        <div className="gap" />
        {item("Settings", "⚙", ctx.route.page === "settings", () => ctx.go({ page: "settings" }))}
      </div>
      <div className="hub-card" onClick={() => ctx.go({ page: "settings", tab: "hub" })} title={ctx.app.config.hubDisplay}>
        <span className={`hub-dot ${ctx.app.hubOK ? "ok" : "bad"}`} />
        <span className="ellip">{ctx.app.hubOK ? "Hub online" : "Can't reach hub"} · {(() => { try { return new URL(ctx.app.config.hubDisplay).hostname; } catch { return ctx.app.config.hubDisplay; } })()}</span>
      </div>
    </aside>
  );
}

// --------------------------------------------------------------- composer
const MODELS: Record<string, { models: [string, string][]; efforts: string[] }> = {
  claude: { models: [["", "Default model"], ["fable", "Fable"], ["opus", "Opus"], ["sonnet", "Sonnet"], ["haiku", "Haiku"]], efforts: ["low", "medium", "high", "xhigh", "max"] },
  codex: { models: [["", "Default model"]], efforts: ["low", "medium", "high"] },
};
function ModelMenu({ agentID, model, effort, onChange }: { agentID: string; model?: string; effort?: string; onChange: (m?: string, e?: string) => void }) {
  const spec = MODELS[agentID];
  if (!spec) return null;
  return (
    <>
      {spec.models.length > 1 ? (
        <select className="pill" value={model ?? ""} onChange={(e) => onChange(e.target.value || undefined, effort)} title="Which model">
          {spec.models.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
        </select>
      ) : null}
      <select className="pill" value={effort ?? ""} onChange={(e) => onChange(model, e.target.value || undefined)} title="How hard it thinks">
        <option value="">Default effort</option>
        {spec.efforts.map((e) => <option key={e} value={e}>{e[0].toUpperCase() + e.slice(1)} effort</option>)}
      </select>
    </>
  );
}
function Attachments({ files, setFiles }: { files: string[]; setFiles: (f: string[]) => void }) {
  if (!files.length) return null;
  return (
    <div className="chips">
      {files.map((f) => (
        <span className="chip file" key={f} title={f}>📎 {f.split(/[\\/]/).pop()} <b onClick={() => setFiles(files.filter((x) => x !== f))}>×</b></span>
      ))}
    </div>
  );
}
const attach = async (files: string[], setFiles: (f: string[]) => void) => {
  const picked: string[] = await call("files.pick");
  setFiles([...files, ...picked.filter((p) => !files.includes(p))]);
};
function onEnter(send: () => void) {
  return (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey && !e.altKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      send();
    }
  };
}

// ------------------------------------------------------------------- home
function Home({ ctx }: { ctx: Ctx }) {
  const ready = ctx.app.agents.filter((a) => a.found);
  const [agentID, setAgentID] = useState(ready.find((a) => a.id === ctx.app.config.agentID)?.id ?? ready[0]?.id ?? "");
  const [project, setProject] = useState<any>(ctx.route.project ?? null);
  const [naming, setNaming] = useState(false);
  const [newName, setNewName] = useState("");
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<string[]>([]);
  const [model, setModel] = useState<string | undefined>();
  const [effort, setEffort] = useState<string | undefined>();
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState("");
  const [picking, setPicking] = useState(false);
  const box = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { setProject(ctx.route.project ?? null); box.current?.focus(); }, [ctx.route]);
  useEffect(() => { if (!agentID && ready[0]) setAgentID(ready[0].id); }, [ready.length]);
  const open = ctx.projects.filter(isOpen).sort((a, b) => lastUsed(ctx, b) - lastUsed(ctx, a));
  const chips = open.slice(0, 6);
  if (project && !chips.some((p) => p.id === project.id)) chips.unshift(project);
  const recent = open.filter((p) => lastUsed(ctx, p) > 0).slice(0, 3);
  const agent = ready.find((a) => a.id === agentID);

  const start = async () => {
    if ((!draft.trim() && !files.length) || !agent || starting || (naming && !newName.trim())) return;
    setStarting(true);
    setError("");
    try {
      let ref = project ? refOf(project) : undefined;
      if (naming) {
        const made = await call("hub.request", "POST", "/api/projects/start", { name: newName.trim(), description: "", north_star: "", owner: ctx.app.config.person ?? "", status: "in_progress", milestones: [], folder: "", tags: [] })
          .catch(() => call("hub.request", "POST", "/api/projects", { name: newName.trim(), path: "" }));
        const id = made?.id ?? made?.project_id;
        await ctx.loadProjects();
        const found = (await call("hub.get", "/api/projects")).projects.find((p: any) => p.id === id);
        ref = found ? refOf(found) : { id, name: newName.trim(), slug: String(id) };
      }
      call("config.set", { agentID: agent.id });
      const id = await call("chat.start", { agentID: agent.id, project: ref, model, effort }, draft.trim(), files);
      ctx.go({ page: "chat", id });
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setStarting(false);
    }
  };

  return (
    <div className="page center">
      <div className="hero">
        <div className="mark big">◭</div>
        <h1>{project ? `What's next for ${project.name}?` : naming ? "Start something new" : "What do you want to work on?"}</h1>
      </div>
      <div className="chips mid">
        <span className={`chip ${!project && !naming ? "on" : ""}`} onClick={() => { setProject(null); setNaming(false); }}>No project</span>
        {chips.map((p) => (
          <span key={p.id} className={`chip ${project?.id === p.id && !naming ? "on" : ""}`} onClick={() => { setProject(p); setNaming(false); }}>{p.name}</span>
        ))}
        <span className="chip" onClick={() => setPicking(true)}>More…</span>
        <span className={`chip accent ${naming ? "on" : ""}`} onClick={() => { setNaming(true); setProject(null); }}>+ New project</span>
      </div>
      {naming ? <input className="field name" autoFocus placeholder="Name the new project" value={newName} onChange={(e) => setNewName(e.target.value)} /> : null}
      <div className="composer big">
        <textarea ref={box} rows={3} placeholder={agent ? `Message ${agent.name}…` : "Message…"} value={draft} disabled={starting}
          onChange={(e) => setDraft(e.target.value)} onKeyDown={onEnter(start)} />
        <Attachments files={files} setFiles={setFiles} />
        <div className="bar">
          <select className="pill strong" value={agentID} onChange={(e) => { setAgentID(e.target.value); setModel(undefined); setEffort(undefined); }}>
            {ready.length ? ready.map((a) => <option key={a.id} value={a.id}>{a.name}</option>) : <option value="">No AI tool found</option>}
          </select>
          <button className="icon" title="Attach files or images" onClick={() => attach(files, setFiles)}>📎</button>
          <ModelMenu agentID={agentID} model={model} effort={effort} onChange={(m, e) => { setModel(m); setEffort(e); }} />
          <span className="grow" />
          <button className="send" disabled={starting || !agent || (!draft.trim() && !files.length)} onClick={start}>{starting ? "…" : "↑"}</button>
        </div>
      </div>
      {error ? <div className="pill-msg bad">{error}</div> : null}
      {!ready.length ? (
        <div className="notice">
          <b>No AI tool found on this computer</b>
          <p>Wolf Leader runs the AI tools you already use. Install one, then come back:</p>
          {ctx.app.agents.slice(0, 3).map((a) => <p key={a.id} className="muted">• {a.name}: {a.installHint}</p>)}
          <button className="btn" onClick={() => ctx.reload()}>Check again</button>
        </div>
      ) : null}
      {!project && !naming && !draft && recent.length ? (
        <div className="pickup">
          <div className="eyebrow">Pick up where you left off</div>
          {recent.map((p) => (
            <div className="card row" key={p.id}>
              <div className="grow min0 click" onClick={() => ctx.go({ page: "project", id: String(p.id) })}>
                <b className="ellip">{p.name}</b>
                <div className="sub ellip">{pulse(ctx, p).line}</div>
              </div>
              <span className="faint">{when(lastUsed(ctx, p) - APPLE)}</span>
              <button className="btn" onClick={() => resume(ctx, p)}>Continue</button>
            </div>
          ))}
        </div>
      ) : null}
      {picking ? (
        <div className="sheet" onClick={() => setPicking(false)}>
          <div className="sheet-body" onClick={(e) => e.stopPropagation()}>
            <h3>Choose a project</h3>
            <div className="sheet-list">
              {ctx.projects.slice().sort((a, b) => a.name.localeCompare(b.name)).map((p) => (
                <div key={p.id} className="nav" onClick={() => { setProject(p); setNaming(false); setPicking(false); }}>{p.name}<span className="grow" /><span className="faint">{p.status}</span></div>
              ))}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

// ------------------------------------------------------------------- chat
function StepGroup({ items }: { items: any[] }) {
  const [open, setOpen] = useState(false);
  const running = items.some((i) => i.status === "running");
  const failed = items.filter((i) => i.status === "failed").length;
  return (
    <div className="steps">
      <div className="steps-head" onClick={() => setOpen(!open)}>
        <span className="caret">{open ? "▾" : "▸"}</span>
        {running ? <span className="spin" /> : null}
        {running ? oneLine(items[items.length - 1].text, 90) : `${items.length} step${items.length === 1 ? "" : "s"}${failed ? ` · ${failed} failed` : ""}`}
      </div>
      {open ? items.map((i) => <Step key={i.id + i.kind} item={i} />) : null}
    </div>
  );
}
function Step({ item }: { item: any }) {
  const [open, setOpen] = useState(false);
  const mark = item.kind === "thinking" ? "…" : item.status === "failed" ? "✕" : item.status === "running" ? "⋯" : "✓";
  const body = item.kind === "thinking" ? item.text : [item.detail, item.output].filter(Boolean).join("\n\n");
  return (
    <div className="step">
      <div className={`step-head ${item.status === "failed" ? "bad" : ""}`} onClick={() => setOpen(!open)}>{mark} {item.kind === "thinking" ? "Thinking" : item.text}</div>
      {open && body ? <pre>{body}</pre> : null}
    </div>
  );
}
function Chat({ ctx, id }: { ctx: Ctx; id: string }) {
  const [snap, setSnap] = useState<{ record: any; busy: boolean } | null>(null);
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<string[]>([]);
  const [error, setError] = useState("");
  const log = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  useEffect(() => {
    setSnap(null);
    call("chat.get", id).then(setSnap);
    return window.wolf.on("chat", (payload) => { if (payload.record.id === id) setSnap(payload); });
  }, [id]);
  useEffect(() => { if (stick.current && log.current) log.current.scrollTop = log.current.scrollHeight; }, [snap]);
  if (!snap) return <div className="page center"><div className="muted pad">Opening…</div></div>;
  const { record, busy } = snap;
  const agent = ctx.app.agents.find((a) => a.id === record.agentID);
  const neverAsk = !!ctx.app.rules.never_ask;
  const others = ctx.app.agents.filter((a) => a.found && a.id !== record.agentID);

  // A run of agent steps folds into one "N steps" row.
  const groups: any[] = [];
  for (const item of record.items) {
    const isStep = item.kind === "tool" || item.kind === "thinking";
    const last = groups[groups.length - 1];
    if (isStep && last?.steps) last.steps.push(item);
    else if (isStep) groups.push({ key: item.id + "g", steps: [item] });
    else groups.push({ key: item.id + item.kind, item });
  }
  const send = async () => {
    if ((!draft.trim() && !files.length) || busy) return;
    const text = draft.trim();
    const sent = files;
    setDraft("");
    setFiles([]);
    setError("");
    stick.current = true;
    try {
      await call("chat.send", id, text, sent);
    } catch (e: any) {
      setDraft(text);
      setFiles(sent);
      setError(String(e?.message ?? e).replace(/^Error invoking remote method 'wolf': Error: /, ""));
    }
  };
  const modes: [string, string][] = [["ask", "Ask first"], ["edits", "Auto-edit"], ["auto", "Full auto"]];
  return (
    <div className="chat">
      <header className="chat-head">
        <div className="min0">
          {record.projectID != null ? <div className="crumb" onClick={() => ctx.go({ page: "project", id: String(record.projectID) })}>‹ {record.projectName}</div> : null}
          <div className="title-row"><h2 className="ellip">{record.title}</h2>{agent ? <span className="tag">{agent.name} · {agent.company}</span> : <span className="tag">{record.agentID}</span>}</div>
        </div>
        <span className="grow" />
        {others.length ? (
          <select className="pill" value="" disabled={busy} onChange={(e) => e.target.value && call("chat.switchAgent", id, e.target.value)} title="Hand this chat to another AI">
            <option value="">Continue with…</option>
            {others.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select>
        ) : null}
        <select className="pill" value={record.projectID ?? ""} disabled={busy} title="This chat's project"
          onChange={(e) => { const p = ctx.projects.find((x) => String(x.id) === e.target.value); if (p) call("chat.attach", id, refOf(p)); }}>
          <option value="">{record.projectID == null ? "Add to a project…" : `In ${record.projectName}`}</option>
          {ctx.projects.filter(isOpen).filter((p) => p.id !== record.projectID).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        <ModelMenu agentID={record.agentID} model={record.model} effort={record.effort} onChange={(m, e) => call("chat.set", id, { model: m, effort: e })} />
        {neverAsk ? <span className="pill static" title="Every chat runs without asking (Settings > Rules).">⚡ Never asks</span> : (
          <select className="pill" value={record.mode} onChange={(e) => call("chat.set", id, { mode: e.target.value })} title="How much it may do without asking">
            {modes.map(([m, label]) => <option key={m} value={m}>{label}</option>)}
          </select>
        )}
      </header>
      <div className="log" ref={log} onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80; }}>
        <div className="wrap">
          {groups.map((g) => {
            if (g.steps) return <StepGroup key={g.key} items={g.steps} />;
            const item = g.item;
            if (item.kind === "user") return <div key={g.key} className="msg user">{item.text}</div>;
            if (item.kind === "agent") return <div key={g.key} className="msg"><Markdown text={item.text} /></div>;
            if (item.kind === "approval") {
              if (item.status !== "pending") return <div key={g.key} className="msg note">{item.status === "allowed" ? "Allowed" : "Not allowed"}: {item.text}</div>;
              return (
                <div key={g.key} className="ask">
                  <p><b>Allow this step?</b> {item.text}</p>
                  {item.detail ? <pre>{item.detail}</pre> : null}
                  <button className="btn primary" onClick={() => call("chat.answer", id, item.id, true)}>Allow</button>
                  <button className="btn" onClick={() => call("chat.answer", id, item.id, true, true)}>Always allow</button>
                  <button className="btn" onClick={() => call("chat.answer", id, item.id, false)}>Don't allow</button>
                </div>
              );
            }
            return <div key={g.key} className={`msg ${item.kind === "error" ? "error" : "note"}`}>{item.text}</div>;
          })}
          {busy && !record.items.some((i: any) => i.status === "running") && record.items[record.items.length - 1]?.kind === "user" ? <div className="msg note"><span className="spin" /> Starting {agent?.name ?? "the AI"}…</div> : null}
        </div>
      </div>
      {agent && !agent.found ? <div className="bar-note">{agent.name} isn't set up on this computer. {agent.installHint}</div> : null}
      {error ? <div className="bar-note bad">{error}</div> : null}
      <footer className="chat-foot">
        <div className="composer">
          <Attachments files={files} setFiles={setFiles} />
          <div className="bar">
            <button className="icon" title="Attach files or images" disabled={busy} onClick={() => attach(files, setFiles)}>📎</button>
            <textarea rows={1} placeholder={`Message ${agent?.name ?? "the agent"}…`} value={draft} disabled={busy} autoFocus
              onChange={(e) => { setDraft(e.target.value); e.target.style.height = "auto"; e.target.style.height = Math.min(e.target.scrollHeight, 220) + "px"; }} onKeyDown={onEnter(send)} />
            {busy ? <button className="btn" onClick={() => call("chat.stop", id)}>■ Stop</button>
              : <button className="btn primary" disabled={!draft.trim() && !files.length} onClick={send}>Send</button>}
          </div>
        </div>
      </footer>
    </div>
  );
}

// ---------------------------------------------------------------- project
function Group({ title, subtitle, icon, fold, children }: { title: string; subtitle?: string; icon?: string; fold?: string; children: ReactNode }) {
  const key = fold ? `fold.${fold}` : null;
  const [open, setOpen] = useState(() => (key ? localStorage.getItem(key) === "1" : true));
  const toggle = () => { if (!key) return; localStorage.setItem(key, open ? "0" : "1"); setOpen(!open); };
  return (
    <section className="group">
      <div className={`group-head ${key ? "click" : ""}`} onClick={toggle}>
        {icon ? <span className="badge">{icon}</span> : null}
        <div className="grow min0"><div className="group-title">{title}</div>{subtitle ? <div className="sub">{subtitle}</div> : null}</div>
        {key ? <span className="caret">{open ? "▾" : "▸"}</span> : null}
      </div>
      {open ? <div className="group-body">{children}</div> : null}
    </section>
  );
}
function ChatRow({ ctx, chat, showProject }: { ctx: Ctx; chat: any; showProject?: boolean }) {
  const agent = ctx.app.agents.find((a) => a.id === chat.agentID);
  return (
    <div className="row click line" onClick={() => ctx.go({ page: "chat", id: chat.id })}>
      <div className="grow min0">
        <b className="ellip">{chat.title}</b>
        <div className="sub ellip">{[agent?.name ?? chat.agentID, showProject ? chat.projectName : null, `${chat.messages} messages`, chat.device && chat.device !== ctx.app.config.deviceName ? `last on ${chat.device}` : null].filter(Boolean).join(" · ")}</div>
      </div>
      {chat.running ? <span className="tag warn">Working</span> : null}
      <span className="faint">{when(chat.updated)}</span>
      <span className="faint">›</span>
    </div>
  );
}
function Project({ ctx, id }: { ctx: Ctx; id: number }) {
  const project = ctx.projects.find((p) => p.id === id);
  const pr = ctx.progress[id];
  const [logbook, setLogbook] = useState<any[]>([]);
  const [memories, setMemories] = useState<any[]>([]);
  const [star, setStar] = useState<any>(null);
  const [brief, setBrief] = useState<any>(null);
  const [reading, setReading] = useState<any>(null);
  useEffect(() => {
    setLogbook([]); setMemories([]); setStar(null); setBrief(null);
    call("hub.get", `/api/projects/${id}/where-left-off`).then((d) => setLogbook(d?.entries ?? [])).catch(() => {});
    call("hub.get", `/api/memories?project_id=${id}&limit=200`).then((d) => setMemories(Array.isArray(d) ? d : d?.memories ?? [])).catch(() => {});
    call("hub.get", `/api/projects/${id}/north-star`).then(setStar).catch(() => {});
    call("hub.get", `/api/projects/${id}/agent-brief`).then(setBrief).catch(() => {});
  }, [id]);
  if (!project) return <div className="page"><div className="muted pad">Loading the project…</div></div>;
  const state = pulse(ctx, project);
  const chats = ctx.app.chats.filter((c) => c.projectID === id);
  const latest = chats[0];
  const stands = String(pr?.where_it_stands ?? project.description ?? "").replace(/\*\*/g, "");
  const last = logbook[0];
  const goals: any[] = pr?.goals ?? [];
  const byType: Record<string, any[]> = {};
  for (const m of memories) (byType[m.type || "note"] ||= []).push(m);
  return (
    <div className="page">
      <div className="crumb" onClick={() => ctx.go({ page: "projects" })}>‹ Projects</div>
      <div className="eyebrow">Project</div>
      <h1 className="h-project">{project.name}</h1>
      <div className="meta">
        <span className="tag">{String(project.status ?? "").replace(/_/g, " ")}</span>
        {project.owner ? <span className="tag soft">{project.owner}</span> : null}
        <span className="faint">{project.chat_count ?? 0} sessions · {project.memory_count ?? 0} memories{pr?.last_session ? ` · last worked on ${whenISO(pr.last_session)}` : ""}</span>
      </div>

      <section className="group hero-card">
        <div className="row">
          <span className="eyebrow accent">Where you left off</span>
          {state.state === "needsYou" ? <span className="tag warn">Needs your OK</span> : state.state === "working" ? <span className="tag warn">Working</span> : null}
          <span className="grow" />
          <span className="faint">{whenISO(pr?.last_session ?? project.updated_at)}</span>
        </div>
        <p className="stands">{stands || "Nothing saved yet. Start a chat and Wolf Leader keeps track from here."}</p>
        {last?.summary && last.summary !== stands ? <><div className="eyebrow">Last session</div><p className="sub clamp">{last.summary}</p></> : null}
        {pr?.next_step?.text ? <><div className="eyebrow accent">Next step</div><p><b>{pr.next_step.text}</b></p>{pr.next_step.done_when ? <p className="sub">Done when: {pr.next_step.done_when}</p> : null}</> : null}
        <div className="row">
          <button className="btn primary" onClick={() => resume(ctx, project)} title={latest ? `Opens “${latest.title}”` : "Starts this project's first chat"}>▶ {latest ? "Continue" : "Start"}</button>
          {latest ? <button className="btn" onClick={() => ctx.go({ page: "home", project })}>＋ Fresh chat</button> : null}
        </div>
      </section>

      {chats.length > 1 ? (
        <Group title="Conversations" subtitle={`${chats.length} in this project, newest first.`} icon="▤" fold="project.chats">
          {chats.slice(0, 12).map((c) => <ChatRow key={c.id} ctx={ctx} chat={c} />)}
        </Group>
      ) : null}

      <section className="group">
        <div className="eyebrow gold">★ North Star</div>
        <p className={star?.current?.body ? "stands" : "sub"}>{star?.current?.body || "Where is this heading? A sentence or two."}</p>
      </section>

      {goals.length ? (
        <Group title="The path" subtitle="Goals toward the North Star." icon="⚑">
          {goals.map((g) => (
            <div className="row line" key={g.id}>
              <div className="grow min0"><b>{g.title}</b>{g.done_when ? <div className="sub">Done when: {g.done_when}</div> : null}</div>
              <span className={`tag ${g.status === "verified" ? "good" : "soft"}`}>{String(g.status ?? g.phase ?? "").replace(/_/g, " ")}</span>
            </div>
          ))}
        </Group>
      ) : null}

      <Group title="Logbook" subtitle="What each session did, newest first. Open one to read it." icon="▥" fold="project.logbook">
        {logbook.length ? logbook.slice(0, 30).map((e) => (
          <div className="row click line" key={e.chat_id} onClick={() => setReading(e)}>
            <div className="grow min0"><b className="ellip">{e.title}</b><div className="sub clamp2">{e.summary}</div></div>
            <span className="faint">{whenISO(e.occurred_at)}</span>
          </div>
        )) : <p className="sub">No sessions saved yet.</p>}
      </Group>

      <Group title="What the journal knows" subtitle={`${memories.length} memories`} icon="◈" fold="project.memories">
        {Object.keys(byType).sort().map((type) => (
          <div key={type}><div className="eyebrow">{type.replace(/_/g, " ")}</div>{byType[type].slice(0, 40).map((m) => <p className="memory" key={m.id}>• {m.content}</p>)}</div>
        ))}
        {!memories.length ? <p className="sub">Nothing yet.</p> : null}
      </Group>

      <Group title="Project brief" subtitle="What every AI is told at the start of a chat here." icon="▤" fold="project.brief">
        {brief?.brief_md ? <Markdown text={brief.brief_md} /> : <p className="sub">{brief?.purpose_summary || "No brief yet."}</p>}
      </Group>

      {reading ? <SessionReader entry={reading} close={() => setReading(null)} /> : null}
    </div>
  );
}
function SessionReader({ entry, close }: { entry: any; close: () => void }) {
  const [messages, setMessages] = useState<any[] | null>(null);
  useEffect(() => { call("hub.get", `/api/chats/${entry.chat_id}/messages`).then((d) => setMessages(d?.messages ?? [])).catch(() => setMessages([])); }, [entry.chat_id]);
  return (
    <div className="sheet" onClick={close}>
      <div className="sheet-body wide" onClick={(e) => e.stopPropagation()}>
        <div className="row"><h3 className="grow ellip">{entry.title}</h3><button className="btn" onClick={close}>Close</button></div>
        <div className="sheet-list">
          {messages === null ? <p className="sub">Loading…</p> : messages.length ? messages.map((m) => (
            <div key={m.id} className={`msg ${m.role === "user" ? "user" : ""}`}>{m.role === "user" ? m.content : <Markdown text={m.content} />}</div>
          )) : <p className="sub">{entry.summary || "Nothing was saved for this session."}</p>}
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------ lists and search
function Projects({ ctx }: { ctx: Ctx }) {
  const [q, setQ] = useState("");
  const [showDone, setShowDone] = useState(false);
  const match = (p: any) => !q.trim() || [p.name, p.description, p.owner].some((t) => String(t ?? "").toLowerCase().includes(q.trim().toLowerCase()));
  const open = ctx.projects.filter(isOpen).filter(match).sort((a, b) => lastUsed(ctx, b) - lastUsed(ctx, a));
  const done = ctx.projects.filter((p) => !isOpen(p)).filter(match).sort((a, b) => a.name.localeCompare(b.name));
  const row = (p: any) => (
    <div className="row click line" key={p.id} onClick={() => ctx.go({ page: "project", id: String(p.id) })}>
      <div className="grow min0"><b className="ellip">{p.name}</b><div className="sub ellip">{pulse(ctx, p).line}</div></div>
      {p.owner ? <span className="tag soft">{p.owner}</span> : null}
      <span className="faint">{when(lastUsed(ctx, p) - APPLE)}</span>
      <button className="btn" onClick={(e) => { e.stopPropagation(); resume(ctx, p); }}>Continue</button>
    </div>
  );
  return (
    <div className="page">
      <div className="eyebrow">Projects</div>
      <h1>All projects</h1>
      <input className="field" placeholder="Filter projects" value={q} onChange={(e) => setQ(e.target.value)} />
      <Group title="Open" subtitle={`${open.length} projects, the ones you used last on top.`}>{open.map(row)}{!open.length ? <p className="sub">Nothing here.</p> : null}</Group>
      <section className="group"><div className="group-head click" onClick={() => setShowDone(!showDone)}><div className="grow"><div className="group-title">Done</div><div className="sub">{done.length} finished or archived.</div></div><span className="caret">{showDone ? "▾" : "▸"}</span></div>{showDone ? <div className="group-body">{done.map(row)}</div> : null}</section>
    </div>
  );
}
function Chats({ ctx }: { ctx: Ctx }) {
  const loose = ctx.app.chats.filter((c) => c.projectID == null);
  const rest = ctx.app.chats.filter((c) => c.projectID != null);
  return (
    <div className="page">
      <div className="eyebrow">Chats</div>
      <h1>All chats</h1>
      <p className="sub">Every chat with every AI, on every device. Each reply is saved to Wolf Leader as it happens, so you can pick a chat up on another computer, or with another AI.</p>
      <Group title="Not in a project yet">{loose.length ? loose.map((c) => <ChatRow key={c.id} ctx={ctx} chat={c} />) : <p className="sub">None.</p>}</Group>
      <Group title="In projects">{rest.slice(0, 60).map((c) => <ChatRow key={c.id} ctx={ctx} chat={c} showProject />)}</Group>
    </div>
  );
}
function Search({ ctx }: { ctx: Ctx }) {
  const [q, setQ] = useState(ctx.route.q ?? "");
  const [results, setResults] = useState<any[] | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async () => {
    if (!q.trim()) return;
    setBusy(true);
    const d = await call("hub.get", `/api/search?q=${encodeURIComponent(q.trim())}`).catch(() => null);
    setResults(d?.results ?? []);
    setBusy(false);
  };
  return (
    <div className="page">
      <div className="eyebrow">Search</div>
      <h1>Find anything</h1>
      <div className="row"><input className="field grow" autoFocus placeholder="Projects, memories and past chats, from every AI and device" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && run()} /><button className="btn primary" onClick={run}>{busy ? "Searching…" : "Search"}</button></div>
      {results ? (
        <Group title={`${results.length} result${results.length === 1 ? "" : "s"}`}>
          {results.map((r, i) => {
            const pid = r.project_id ?? (r.kind === "project" ? r.id : null);
            return (
              <div className={`row line ${pid ? "click" : ""}`} key={i} onClick={() => pid && ctx.go({ page: "project", id: String(pid) })}>
                <span className="tag soft">{r.kind}</span>
                <div className="grow min0"><b className="ellip">{r.title || r.project_name || oneLine(r.snippet ?? r.content, 70)}</b><div className="sub clamp2">{oneLine(r.snippet ?? r.content ?? "", 240)}</div></div>
                {r.project_name ? <span className="faint">{r.project_name}</span> : null}
              </div>
            );
          })}
          {!results.length ? <p className="sub">Nothing found. Try different words.</p> : null}
        </Group>
      ) : null}
    </div>
  );
}

// --------------------------------------------------------------- settings
function Settings({ ctx }: { ctx: Ctx }) {
  const [tab, setTab] = useState(ctx.route.tab ?? "general");
  useEffect(() => { if (ctx.route.tab) setTab(ctx.route.tab); }, [ctx.route.tab]);
  const tabs: [string, string][] = [["general", "General"], ["agents", "AI tools"], ["rules", "Rules"], ["hub", "Hub"], ["about", "About"]];
  return (
    <div className="page">
      <div className="tabs">{tabs.map(([id, label]) => <span key={id} className={`tab ${tab === id ? "on" : ""}`} onClick={() => setTab(id)}>{label}</span>)}</div>
      {tab === "general" ? <SettingsGeneral ctx={ctx} /> : null}
      {tab === "agents" ? <SettingsAgents ctx={ctx} /> : null}
      {tab === "rules" ? <SettingsRules ctx={ctx} /> : null}
      {tab === "hub" ? <SettingsHub ctx={ctx} /> : null}
      {tab === "about" ? (
        <Group title="Wolf Leader" subtitle="Your projects and AI history, with any AI." icon="◭">
          <Line title="Version" detail="The same app on Windows, Mac and Linux.">{ctx.app.version}</Line>
          <Line title="This computer" detail="How this device is named in your chats.">{ctx.app.config.deviceName}</Line>
        </Group>
      ) : null}
    </div>
  );
}
function Line({ title, detail, children }: { title: string; detail?: string; children?: ReactNode }) {
  return <div className="row line"><div className="grow min0"><b>{title}</b>{detail ? <div className="sub">{detail}</div> : null}</div>{children}</div>;
}
function SettingsGeneral({ ctx }: { ctx: Ctx }) {
  const [owners, setOwners] = useState<string[]>([]);
  useEffect(() => { call("hub.get", "/api/owners").then((d) => setOwners(d?.owners ?? [])).catch(() => {}); }, []);
  const set = async (changes: any) => ctx.setApp(await call("config.set", changes));
  return (
    <Group title="You" subtitle="Every chat starts with what Wolf Leader knows about you and the project, whichever AI you use." icon="☺">
      <Line title="This computer is used by" detail="Your profile goes to every AI at the start of a chat.">
        <select className="pill" value={ctx.app.config.person ?? ""} onChange={(e) => set({ person: e.target.value || undefined })}>
          <option value="">Nobody in particular</option>
          {owners.map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
      </Line>
      <Line title="This computer's name" detail="Shown on chats so you can tell where each one ran.">
        <input className="field small" defaultValue={ctx.app.config.deviceName} onBlur={(e) => e.target.value.trim() && set({ deviceName: e.target.value.trim() })} />
      </Line>
    </Group>
  );
}
function SettingsAgents({ ctx }: { ctx: Ctx }) {
  return (
    <Group title="AI tools" subtitle="Wolf Leader runs the AI tools installed on this computer. Each one keeps its own sign-in." icon="✦">
      {ctx.app.agents.map((a) => (
        <Line key={a.id} title={`${a.name} · ${a.company}`} detail={a.found ? "Ready." : a.installHint}>
          <span className={`tag ${a.found ? "good" : "soft"}`}>{a.found ? "Found" : "Not installed"}</span>
        </Line>
      ))}
      <div className="row"><button className="btn" onClick={() => ctx.reload()}>Look again</button></div>
    </Group>
  );
}
function SettingsRules({ ctx }: { ctx: Ctx }) {
  const rules = ctx.app.rules ?? {};
  const [text, setText] = useState(String(rules.rules ?? ""));
  const save = async (changes: any) => {
    const next = { never_ask: !!rules.never_ask, default_mode: rules.default_mode ?? "ask", rules: rules.rules ?? "", skills: rules.skills ?? null, hub_tools: rules.hub_tools !== false, ...changes };
    await call("hub.request", "PUT", "/api/chat-rules", next).catch(() => {});
    ctx.setApp(await call("refresh"));
  };
  return (
    <Group title="Rules for every chat" subtitle="One set of rules for every chat, every AI and every device." icon="☑">
      <Line title="Never ask" detail="AIs act without asking. Use only if you trust what you run them on.">
        <input type="checkbox" checked={!!rules.never_ask} onChange={(e) => save({ never_ask: e.target.checked })} />
      </Line>
      {!rules.never_ask ? (
        <Line title="New chats start in" detail="How much an AI may do without asking.">
          <select className="pill" value={rules.default_mode ?? "ask"} onChange={(e) => save({ default_mode: e.target.value })}>
            <option value="ask">Ask first</option><option value="edits">Auto-edit</option><option value="auto">Full auto</option>
          </select>
        </Line>
      ) : null}
      <Line title="Wolf Leader's tools in every chat" detail="Lets the AI search your projects and memories and add to them.">
        <input type="checkbox" checked={rules.hub_tools !== false} onChange={(e) => save({ hub_tools: e.target.checked })} />
      </Line>
      <div className="stack">
        <b>Instructions every AI gets</b>
        <textarea className="field area" rows={5} value={text} onChange={(e) => setText(e.target.value)} placeholder="For example: keep answers short and plain." />
        <div className="row"><button className="btn primary" disabled={text === String(rules.rules ?? "")} onClick={() => save({ rules: text })}>Save</button></div>
      </div>
    </Group>
  );
}
function SettingsHub({ ctx }: { ctx: Ctx }) {
  const [url, setUrl] = useState(ctx.app.config.hubURL);
  const [note, setNote] = useState("");
  const [people, setPeople] = useState<any[]>([]);
  const [exporting, setExporting] = useState(false);
  useEffect(() => { call("hub.get", "/api/access").then((d) => setPeople(d?.people ?? [])).catch(() => setPeople([])); }, [ctx.app.config.hubURL]);
  const save = async () => {
    const next = await call("config.set", { hubURL: url.trim() });
    ctx.setApp(next);
    setNote(next.hubOK ? "Connected." : "Saved, but the hub didn't answer at that address.");
    ctx.reload();
  };
  const copy = (text: string, said: string) => { navigator.clipboard.writeText(text); setNote(said); };
  return (
    <>
      <Group title="Hub" subtitle="Where this computer saves and reads memories." icon="▣">
        <Line title="Hub address" detail={note || "For example http://127.0.0.1:6971, or the personal address you were given."}>
          <input className="field mid" value={url} onChange={(e) => setUrl(e.target.value)} />
          <button className="btn primary" disabled={url.trim() === ctx.app.config.hubURL} onClick={save}>Save</button>
        </Line>
        <Line title="Connection" detail={ctx.app.hubOK ? "The hub is answering." : "The hub isn't answering from this computer."}>
          <span className={`tag ${ctx.app.hubOK ? "good" : "bad"}`}>{ctx.app.hubOK ? "Online" : "Offline"}</span>
        </Line>
      </Group>
      <Group title="Your data" subtitle="Everything the hub holds, in files you can open anywhere." icon="⇩">
        <Line title="Export everything" detail="One ZIP in Downloads: every project, memory, chat, your profile and skills.">
          <button className="btn primary" disabled={exporting} onClick={async () => { setExporting(true); try { setNote(`Saved ${await call("export.all")} to Downloads.`); } catch { setNote("Only the hub's admin can export."); } setExporting(false); }}>{exporting ? "Exporting…" : "Export"}</button>
        </Line>
      </Group>
      {people.length ? (
        <Group title="People" subtitle="Each person signs in with their own address and sees only their own projects." icon="☺">
          {people.map((p) => (
            <Line key={p.person} title={p.person} detail={p.admin ? "Admin: sees everything." : "Sees their own projects, and ones marked for everyone."}>
              <button className="btn" onClick={() => copy(p.hub, `${p.person}'s hub address copied.`)}>Copy hub address</button>
              <button className="btn" onClick={() => copy(p.mcp, `${p.person}'s MCP address copied.`)}>Copy MCP address</button>
            </Line>
          ))}
        </Group>
      ) : null}
    </>
  );
}

// -------------------------------------------------------------------- app
function App() {
  const data = useApp();
  const [route, setRoute] = useState<Route>({ page: "home" });
  const stack = useRef<Route[]>([]);
  const go = (next: Route) => { stack.current.push(route); setRoute(next); };
  useEffect(() => {
    // For checking screens without a person (see main.ts takeShots).
    window.__nav = (r: string) => {
      const [page, id] = r.split(":");
      setRoute({ page: page as any, id, tab: page === "settings" ? id : undefined });
    };
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key === "n") { e.preventDefault(); go({ page: "home" }); }
      if (mod && e.key === ",") { e.preventDefault(); go({ page: "settings" }); }
      if (mod && e.key === "[") { e.preventDefault(); const back = stack.current.pop(); if (back) setRoute(back); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  if (!data.app) return <div className="boot">Wolf Leader</div>;
  const ctx = { ...data, app: data.app, go, route } as Ctx;
  let page: ReactNode;
  if (route.page === "chat" && route.id) page = <Chat ctx={ctx} id={route.id} key={route.id} />;
  else if (route.page === "project" && route.id) page = <Project ctx={ctx} id={Number(route.id)} key={route.id} />;
  else if (route.page === "projects") page = <Projects ctx={ctx} />;
  else if (route.page === "chats") page = <Chats ctx={ctx} />;
  else if (route.page === "search") page = <Search ctx={ctx} />;
  else if (route.page === "settings") page = <Settings ctx={ctx} />;
  else page = <Home ctx={ctx} />;
  return (
    <div className="app">
      <Sidebar ctx={ctx} />
      <main className={`main ${ctx.app.platform}`}>{page}</main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
