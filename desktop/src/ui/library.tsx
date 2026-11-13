// The Library: what every chat can draw on. Your skills, what Wolf Leader knows about each
// person, and snippets you reuse.
import { useEffect, useState } from "react";
import { call, Group, Line, Markdown, oneLine } from "./kit";

const get = (path: string) => call("hub.get", path);
const send = (method: string, path: string, body?: any) => call("hub.request", method, path, body);
const enc = encodeURIComponent;

export function Library({ app, setApp, tab, setTab }: { app: any; setApp: (a: any) => void; tab: string; setTab: (t: string) => void }) {
  const tabs: [string, string][] = [["skills", "Skills"], ["people", "People"], ["snippets", "Snippets"]];
  return (
    <div className="page">
      <div className="tabs">{tabs.map(([id, label]) => <span key={id} className={`tab ${tab === id ? "on" : ""}`} onClick={() => setTab(id)}>{label}</span>)}</div>
      {tab === "people" ? <People app={app} /> : tab === "snippets" ? <Snippets /> : <Skills app={app} setApp={setApp} />}
    </div>
  );
}

// ----------------------------------------------------------------- skills
function Skills({ app, setApp }: { app: any; setApp: (a: any) => void }) {
  const [skills, setSkills] = useState<any[]>([]);
  const [open, setOpen] = useState<any>(null);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [note, setNote] = useState("");
  const rules = app.rules ?? {};
  const load = () => get("/api/skills").then((d) => setSkills(d?.skills ?? [])).catch(() => {});
  useEffect(() => { load(); }, []);
  // None chosen yet means every skill except the two the app does on its own.
  const chosen: string[] = Array.isArray(rules.skills) ? rules.skills : skills.map((s) => s.name).filter((n) => !["wolfhowl", "wolfeat"].includes(n));
  const toggle = async (skill: string, on: boolean) => {
    const next = on ? [...new Set([...chosen, skill])] : chosen.filter((s) => s !== skill);
    await send("PUT", "/api/chat-rules", { never_ask: !!rules.never_ask, default_mode: rules.default_mode ?? "ask", rules: rules.rules ?? "", skills: next, hub_tools: rules.hub_tools !== false }).catch(() => {});
    setApp(await call("refresh"));
  };
  const create = async () => {
    try {
      await send("POST", "/api/skills", { name: name.trim(), description: description.trim() });
      setAdding(false);
      setName("");
      setDescription("");
      await load();
    } catch {
      setNote("Couldn't make that skill. Use a short name with letters, numbers and dashes, and one that isn't taken.");
    }
  };
  return (
    <>
      <div className="row head">
        <div className="grow"><h1>Skills</h1><p className="sub">Your skills, kept in one place. Wolf Leader hands the chosen ones to every AI, so a skill you write once works everywhere.</p></div>
        <button className="btn primary" onClick={() => setAdding(true)}>Add skill</button>
      </div>
      <Group title="Your skills" subtitle={`${skills.length} in the library.`} icon="▧">
        {skills.map((s) => (
          <div className="row line" key={s.id}>
            <div className="grow min0 click" onClick={() => setOpen(s)}><b>{s.name}</b><div className="sub clamp2">{s.description}</div></div>
            <label className="check" title="Give this skill to every chat"><input type="checkbox" checked={chosen.includes(s.name)} onChange={(e) => toggle(s.name, e.target.checked)} /> Every chat</label>
          </div>
        ))}
        {!skills.length ? <p className="sub">No skills yet. Add one, or bring them in from your AI tools on the Mac app.</p> : null}
      </Group>
      {adding ? (
        <div className="sheet" onClick={() => setAdding(false)}>
          <div className="sheet-body form" onClick={(e) => e.stopPropagation()}>
            <h3>New skill</h3>
            <label>Name<input className="field" autoFocus value={name} onChange={(e) => setName(e.target.value)} placeholder="for example: weekly-report" /></label>
            <label>When should an AI use it?<textarea className="field area" rows={3} value={description} onChange={(e) => setDescription(e.target.value)} /></label>
            {note ? <p className="sub bad">{note}</p> : null}
            <div className="row end"><button className="btn" onClick={() => setAdding(false)}>Cancel</button><button className="btn primary" disabled={!name.trim()} onClick={create}>Create</button></div>
          </div>
        </div>
      ) : null}
      {open ? <SkillSheet skill={open} close={() => { setOpen(null); load(); }} /> : null}
    </>
  );
}
function SkillSheet({ skill, close }: { skill: any; close: () => void }) {
  const [text, setText] = useState<string | null>(null);
  const [saved, setSaved] = useState("");
  const [editing, setEditing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  useEffect(() => {
    get(`/api/skills/${enc(skill.name)}/files/SKILL.md`).then((d) => { setText(d?.content ?? ""); setSaved(d?.content ?? ""); }).catch(() => { setText(""); });
  }, [skill.name]);
  const save = async () => {
    await send("PUT", `/api/skills/${enc(skill.name)}/files/SKILL.md`, { content: text ?? "" });
    setSaved(text ?? "");
    setEditing(false);
  };
  return (
    <div className="sheet" onClick={close}>
      <div className="sheet-body wide" onClick={(e) => e.stopPropagation()}>
        <div className="row">
          <h3 className="grow ellip">{skill.name}</h3>
          {editing ? <><button className="btn" onClick={() => { setText(saved); setEditing(false); }}>Cancel</button><button className="btn primary" disabled={text === saved} onClick={save}>Save</button></>
            : <><button className="btn" onClick={() => setEditing(true)}>Edit</button><button className="btn" onClick={() => setConfirming(true)}>Delete</button><button className="btn" onClick={close}>Close</button></>}
        </div>
        {confirming ? (
          <div className="row line"><p className="grow">Delete {skill.name} from the library, for every device?</p>
            <button className="btn" onClick={() => setConfirming(false)}>Keep</button>
            <button className="btn danger" onClick={async () => { await send("DELETE", `/api/skills/${enc(skill.name)}`).catch(() => {}); close(); }}>Delete</button></div>
        ) : null}
        <div className="sheet-list">
          {text === null ? <p className="sub">Loading…</p>
            : editing ? <textarea className="field area code" rows={22} value={text} onChange={(e) => setText(e.target.value)} />
            : <Markdown text={text.replace(/^---[\s\S]*?---\s*/, "")} />}
        </div>
      </div>
    </div>
  );
}

// ----------------------------------------------------------------- people
function People({ app }: { app: any }) {
  const [owners, setOwners] = useState<string[]>([]);
  const [person, setPerson] = useState<string>(app.config.person ?? "");
  const [profile, setProfile] = useState<any>(null);
  const [text, setText] = useState("");
  const [kind, setKind] = useState("");
  const [editing, setEditing] = useState<any>(null);
  useEffect(() => { get("/api/owners").then((d) => { setOwners(d?.owners ?? []);
    // Whose computer is this? Guess from its name ("Corbin's PC") before falling back to the first person.
    if (!person && d?.owners?.length) setPerson(d.owners.find((o: string) => String(app.config.deviceName).toLowerCase().includes(o.toLowerCase())) ?? d.owners[0]);
  }).catch(() => {}); }, []);
  const load = () => (person ? get(`/api/people/${enc(person)}/profile`).then(setProfile).catch(() => setProfile(null)) : undefined);
  useEffect(() => { setProfile(null); load(); }, [person]);
  const add = async () => {
    if (!text.trim() || !person) return;
    const body: any = { text: text.trim(), source: "manual" };
    if (kind) body.kind = kind;
    await send("POST", `/api/people/${enc(person)}/profile`, body).catch(() => {});
    setText("");
    load();
  };
  const kinds: Record<string, string> = profile?.kinds ?? {};
  return (
    <>
      <div className="row head">
        <div className="grow"><h1>People</h1><p className="sub">What Wolf Leader knows about each person. It goes to every AI at the start of a chat, so you never explain yourself twice.</p></div>
        <select className="pill" value={person} onChange={(e) => setPerson(e.target.value)}>{owners.map((o) => <option key={o} value={o}>{o}</option>)}</select>
      </div>
      {!owners.length ? <p className="sub">This hub has no people set up yet.</p> : null}
      {profile ? (
        <>
          <section className="group">
            <div className="row">
              <select className="pill" value={kind} onChange={(e) => setKind(e.target.value)}>
                <option value="">Let Wolf Leader sort it</option>
                {Object.entries(kinds).map(([k, label]) => <option key={k} value={k}>{label}</option>)}
              </select>
              <input className="field grow" placeholder={`Something lasting about ${person}`} value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
              <button className="btn primary" disabled={!text.trim()} onClick={add}>Add</button>
            </div>
          </section>
          {(profile.sections ?? []).map((s: any) => (
            <Group key={s.kind} title={s.title} subtitle={`${s.items.length} item${s.items.length === 1 ? "" : "s"}`}>
              {s.items.map((item: any) => (
                <div className="row line" key={item.id}>
                  {editing?.id === item.id ? (
                    <>
                      <textarea className="field area grow" rows={3} value={editing.text} onChange={(e) => setEditing({ ...editing, text: e.target.value })} />
                      <button className="btn primary" onClick={async () => { await send("PUT", `/api/profile-items/${item.id}`, { text: editing.text }).catch(() => {}); setEditing(null); load(); }}>Save</button>
                      <button className="btn" onClick={() => setEditing(null)}>Cancel</button>
                    </>
                  ) : (
                    <>
                      <div className="grow min0"><Markdown text={item.text} /></div>
                      <button className="btn" onClick={() => setEditing({ id: item.id, text: item.text })}>Edit</button>
                      <button className="btn" onClick={async () => { await send("DELETE", `/api/profile-items/${item.id}`).catch(() => {}); load(); }}>Remove</button>
                    </>
                  )}
                </div>
              ))}
              {!s.items.length ? <p className="sub">Nothing yet.</p> : null}
            </Group>
          ))}
        </>
      ) : null}
    </>
  );
}

// --------------------------------------------------------------- snippets
function Snippets() {
  const [snippets, setSnippets] = useState<any[]>([]);
  const [title, setTitle] = useState("");
  const [content, setContent] = useState("");
  const [copied, setCopied] = useState<number | null>(null);
  const load = () => get("/api/snippets").then((d) => setSnippets(d?.snippets ?? [])).catch(() => {});
  useEffect(() => { load(); }, []);
  const add = async () => {
    if (!content.trim()) return;
    await send("POST", "/api/snippets", { title: title.trim() || oneLine(content, 40), language: "", content }).catch(() => {});
    setTitle("");
    setContent("");
    load();
  };
  return (
    <>
      <div className="row head"><div className="grow"><h1>Snippets</h1><p className="sub">Text you reuse: a prompt, a command, a checklist. Kept on the hub, on every device.</p></div></div>
      <section className="group form">
        <input className="field" placeholder="Name" value={title} onChange={(e) => setTitle(e.target.value)} />
        <textarea className="field area" rows={4} placeholder="The text to keep" value={content} onChange={(e) => setContent(e.target.value)} />
        <div className="row end"><button className="btn primary" disabled={!content.trim()} onClick={add}>Save snippet</button></div>
      </section>
      <Group title="Saved" subtitle={`${snippets.length} snippet${snippets.length === 1 ? "" : "s"}`}>
        {snippets.map((s) => (
          <div className="row line" key={s.id}>
            <div className="grow min0"><b>{s.title || "Snippet"}</b><div className="sub clamp2">{oneLine(s.content, 200)}</div></div>
            <button className="btn" onClick={() => { navigator.clipboard.writeText(s.content); setCopied(s.id); }}>{copied === s.id ? "Copied" : "Copy"}</button>
            <button className="btn" onClick={async () => { await send("DELETE", `/api/snippets/${s.id}`).catch(() => {}); load(); }}>Remove</button>
          </div>
        ))}
        {!snippets.length ? <p className="sub">None yet.</p> : null}
      </Group>
    </>
  );
}
