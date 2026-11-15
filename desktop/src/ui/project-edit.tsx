// Changing a project: its name and stage, its North Star, the path (milestones and goals),
// and what the journal knows.
import { useState } from "react";
import { call, Group, whenISO } from "./kit";

type Reload = () => Promise<void> | void;
const put = (path: string, body: any) => call("hub.request", "PUT", path, body);
const post = (path: string, body: any) => call("hub.request", "POST", path, body);
const del = (path: string) => call("hub.request", "DELETE", path);

/** The ⋯ menu on a project's header: details, stage, owner, sharing, delete. */
export function ProjectMenu({ project, columns, owners, reload, onDeleted }: { project: any; columns: any[]; owners: string[]; reload: Reload; onDeleted: () => void }) {
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [name, setName] = useState(project.name);
  const [description, setDescription] = useState(project.description ?? "");
  const [topics, setTopics] = useState((Array.isArray(project.tags) ? project.tags : []).join(", "));
  let meta: any = {};
  try {
    meta = typeof project.metadata === "string" ? JSON.parse(project.metadata || "{}") : project.metadata ?? {};
  } catch {}
  const change = async (body: any) => {
    await put(`/api/projects/${project.id}`, body).catch(() => {});
    await reload();
  };
  const save = async () => {
    await put(`/api/projects/${project.id}`, { name: name.trim() || project.name, description });
    await put(`/api/projects/${project.id}`, { tags: topics.split(",").map((t) => t.trim()).filter(Boolean) }).catch(() => {});
    setEditing(false);
    await reload();
  };
  return (
    <>
      <select className="pill" value={project.status ?? ""} onChange={(e) => change({ status: e.target.value })} title="Where this project is">
        {columns.map((c) => <option key={c.status} value={c.status}>{c.label}</option>)}
        {!columns.some((c) => c.status === project.status) ? <option value={project.status}>{project.status}</option> : null}
      </select>
      {owners.length ? (
        <select className="pill" value={project.owner ?? ""} onChange={(e) => change({ owner: e.target.value })} title="Whose project this is">
          <option value="">No owner</option>
          {owners.map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
      ) : null}
      <select className="pill" value="" title="More" onChange={(e) => {
        const v = e.target.value;
        if (v === "edit") setEditing(true);
        if (v === "shared") change({ metadata: { shared: !meta.shared } });
        if (v === "everyone") change({ metadata: { everyone: !meta.everyone } });
        if (v === "delete") setDeleting(true);
      }}>
        <option value="">⋯</option>
        <option value="edit">Edit name, description and topics…</option>
        <option value="shared">{meta.shared ? "✓ " : ""}Share with every project</option>
        <option value="everyone">{meta.everyone ? "✓ " : ""}Let everyone on this hub see it</option>
        <option value="delete">Delete project…</option>
      </select>
      {meta.shared ? <span className="tag" title="Every chat, in any project, gets this project's notes and memories">Shared with every project</span> : null}
      {editing ? (
        <div className="sheet" onClick={() => setEditing(false)}>
          <div className="sheet-body form" onClick={(e) => e.stopPropagation()}>
            <h3>Edit project</h3>
            <label>Name<input className="field" value={name} onChange={(e) => setName(e.target.value)} /></label>
            <label>What it is<textarea className="field area" rows={4} value={description} onChange={(e) => setDescription(e.target.value)} /></label>
            <label>Topics (comma separated)<input className="field" value={topics} onChange={(e) => setTopics(e.target.value)} /></label>
            <div className="row end"><button className="btn" onClick={() => setEditing(false)}>Cancel</button><button className="btn primary" onClick={save}>Save</button></div>
          </div>
        </div>
      ) : null}
      {deleting ? (
        <div className="sheet" onClick={() => setDeleting(false)}>
          <div className="sheet-body form" onClick={(e) => e.stopPropagation()}>
            <h3>Delete {project.name}?</h3>
            <p className="sub">Its memories, goals and saved sessions go with it. This can't be undone.</p>
            <div className="row end">
              <button className="btn" onClick={() => setDeleting(false)}>Cancel</button>
              <button className="btn danger" onClick={async () => { await del(`/api/projects/${project.id}`).catch(() => {}); onDeleted(); await reload(); }}>Delete project</button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}

/** Where the project is heading. Changing it keeps the earlier versions. */
export function NorthStarCard({ projectID, star, suggestion, reload }: { projectID: number; star: any; suggestion: string; reload: Reload }) {
  const current = star?.current;
  const [editing, setEditing] = useState(false);
  const [body, setBody] = useState("");
  const [why, setWhy] = useState("");
  const [history, setHistory] = useState(false);
  const versions: any[] = star?.versions ?? star?.history ?? [];
  const save = async () => {
    if (!body.trim()) return;
    await put(`/api/projects/${projectID}/north-star`, { body: body.trim(), why: why.trim() });
    setEditing(false);
    setWhy("");
    await reload();
  };
  return (
    <section className="group">
      <div className="row">
        <div className="eyebrow gold grow">★ North Star</div>
        {!editing ? <button className="btn" onClick={() => { setBody(current?.body ?? suggestion ?? ""); setEditing(true); }}>{current?.body ? "Change it" : "Set it"}</button> : null}
      </div>
      {editing ? (
        <div className="form">
          <textarea className="field area" rows={4} autoFocus value={body} onChange={(e) => setBody(e.target.value)} placeholder="Where is this heading? A sentence or two." />
          {current?.body ? <input className="field" value={why} onChange={(e) => setWhy(e.target.value)} placeholder="Why it changed (optional)" /> : null}
          <div className="row end"><button className="btn" onClick={() => setEditing(false)}>Cancel</button><button className="btn primary" disabled={!body.trim()} onClick={save}>Save</button></div>
        </div>
      ) : (
        <>
          <p className={current?.body ? "stands" : "sub"}>{current?.body || "Where is this heading? A sentence or two."}</p>
          {current?.created_at ? (
            <p className="sub">Since {whenISO(current.created_at)}
              {versions.length > 1 ? <> · <span className="link" onClick={() => setHistory(!history)}>Changed {versions.length - 1} time{versions.length === 2 ? "" : "s"}</span></> : null}
              {current.why ? <> · Why it changed: {current.why}</> : null}
            </p>
          ) : null}
          {history ? versions.filter((v) => v.id !== current?.id).map((v) => (
            <div className="row line" key={v.id}><div className="grow min0"><p className="sub">{whenISO(v.created_at)}</p><p>{v.body}</p></div>
              <button className="btn" onClick={async () => { await del(`/api/north-star-versions/${v.id}`).catch(() => {}); await reload(); }}>Remove</button></div>
          )) : null}
        </>
      )}
    </section>
  );
}

const PHASES: [string, string][] = [["now", "Now"], ["next", "Next"], ["later", "Later"]];
const GOAL_STATUS: [string, string][] = [["proposed", "Proposed"], ["committed", "Committed"], ["verified", "Verified"]];
const MILESTONE_STATUS: [string, string][] = [["not_started", "Not started"], ["in_progress", "In progress"], ["done", "Done"]];

function GoalRow({ goal, milestones, reload }: { goal: any; milestones: any[]; reload: Reload }) {
  const change = async (body: any) => { await put(`/api/goals/${goal.id}`, body).catch(() => {}); await reload(); };
  return (
    <div className="row line">
      <div className="grow min0"><b>{goal.title}</b>{goal.done_when ? <div className="sub">Done when: {goal.done_when}</div> : null}{goal.proof ? <div className="sub">Proof: {goal.proof}</div> : null}</div>
      <select className="pill" value={goal.phase ?? "now"} onChange={(e) => change({ phase: e.target.value })}>{PHASES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
      <select className="pill" value={goal.status ?? "proposed"} onChange={(e) => change({ status: e.target.value })}>{GOAL_STATUS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
      <select className="pill" value="" title="More" onChange={async (e) => {
        const v = e.target.value;
        if (v === "delete") { await del(`/api/goals/${goal.id}`).catch(() => {}); await reload(); }
        else if (v.startsWith("m:")) change({ milestone_id: Number(v.slice(2)) });
      }}>
        <option value="">⋯</option>
        {milestones.filter((m) => m.id !== goal.milestone_id).map((m) => <option key={m.id} value={`m:${m.id}`}>Move under: {m.title.slice(0, 40)}</option>)}
        {goal.milestone_id ? <option value="m:0">Take out of its milestone</option> : null}
        <option value="delete">Delete goal</option>
      </select>
    </div>
  );
}

/** Milestones toward the North Star, with goals under each. */
export function PathCard({ projectID, progress, reload }: { projectID: number; progress: any; reload: Reload }) {
  const goals: any[] = progress?.goals ?? [];
  const milestones: any[] = (progress?.milestones ?? []).slice().sort((a: any, b: any) => (a.position ?? 0) - (b.position ?? 0));
  const [milestone, setMilestone] = useState("");
  const [title, setTitle] = useState("");
  const [doneWhen, setDoneWhen] = useState("");
  const [phase, setPhase] = useState("now");
  const [under, setUnder] = useState(0);
  const [renaming, setRenaming] = useState<{ id: number; title: string } | null>(null);
  const addMilestone = async () => {
    if (!milestone.trim()) return;
    await post(`/api/projects/${projectID}/milestones`, { title: milestone.trim() });
    setMilestone("");
    await reload();
  };
  const addGoal = async () => {
    if (!title.trim()) return;
    const body: any = { title: title.trim(), done_when: doneWhen.trim(), phase };
    if (under) body.milestone_id = under;
    await post(`/api/projects/${projectID}/goals`, body);
    setTitle("");
    setDoneWhen("");
    await reload();
  };
  const loose = goals.filter((g) => !g.milestone_id || !milestones.some((m) => m.id === g.milestone_id));
  return (
    <Group title="The path" subtitle="Milestones toward the North Star, with goals under each." icon="⚑">
      {milestones.map((m, i) => (
        <div className="milestone" key={m.id}>
          <div className="row">
            <span className="num">{i + 1}</span>
            <b className="grow">{m.title}</b>
            <select className="pill" value={m.status ?? "not_started"} onChange={async (e) => { await put(`/api/milestones/${m.id}`, { status: e.target.value }).catch(() => {}); await reload(); }}>
              {MILESTONE_STATUS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
            <select className="pill" value="" title="More" onChange={async (e) => {
              if (e.target.value === "rename") setRenaming({ id: m.id, title: m.title });
              if (e.target.value === "delete") { await del(`/api/milestones/${m.id}`).catch(() => {}); await reload(); }
            }}>
              <option value="">⋯</option><option value="rename">Rename…</option><option value="delete">Delete milestone</option>
            </select>
          </div>
          <div className="under">
            {goals.filter((g) => g.milestone_id === m.id).map((g) => <GoalRow key={g.id} goal={g} milestones={milestones} reload={reload} />)}
            {!goals.some((g) => g.milestone_id === m.id) ? <p className="sub">No goals under this yet.</p> : null}
          </div>
        </div>
      ))}
      {renaming ? (
        <div className="sheet" onClick={() => setRenaming(null)}>
          <div className="sheet-body form" onClick={(e) => e.stopPropagation()}>
            <h3>Rename milestone</h3>
            <input className="field" autoFocus value={renaming.title} onChange={(e) => setRenaming({ ...renaming, title: e.target.value })} />
            <div className="row end">
              <button className="btn" onClick={() => setRenaming(null)}>Cancel</button>
              <button className="btn primary" disabled={!renaming.title.trim()} onClick={async () => { await put(`/api/milestones/${renaming.id}`, { title: renaming.title.trim() }).catch(() => {}); setRenaming(null); await reload(); }}>Save</button>
            </div>
          </div>
        </div>
      ) : null}
      {loose.length ? <div className="eyebrow pad-top">Not under a milestone</div> : null}
      {loose.map((g) => <GoalRow key={g.id} goal={g} milestones={milestones} reload={reload} />)}
      <div className="row add">
        <input className="field grow" placeholder="Add a milestone (a big chunk of the journey)" value={milestone} onChange={(e) => setMilestone(e.target.value)} onKeyDown={(e) => e.key === "Enter" && addMilestone()} />
        <button className="btn" disabled={!milestone.trim()} onClick={addMilestone}>Add milestone</button>
      </div>
      <div className="eyebrow pad-top">Add a goal</div>
      <div className="form">
        <input className="field" placeholder="What should be true?" value={title} onChange={(e) => setTitle(e.target.value)} />
        <input className="field" placeholder="Done when… (how you will know)" value={doneWhen} onChange={(e) => setDoneWhen(e.target.value)} onKeyDown={(e) => e.key === "Enter" && addGoal()} />
        <div className="row">
          <select className="pill" value={phase} onChange={(e) => setPhase(e.target.value)}>{PHASES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
          <select className="pill" value={under} onChange={(e) => setUnder(Number(e.target.value))}>
            <option value={0}>No milestone</option>
            {milestones.map((m) => <option key={m.id} value={m.id}>{m.title.slice(0, 50)}</option>)}
          </select>
          <span className="grow" />
          <button className="btn primary" disabled={!title.trim()} onClick={addGoal}>Add goal</button>
        </div>
      </div>
    </Group>
  );
}

const MEMORY_KINDS = ["note", "decision", "constraint", "goal", "active_work", "problem", "caveat"];
/** Write something into the journal by hand. */
export function MemoryAdd({ projectID, reload }: { projectID: number; reload: Reload }) {
  const [text, setText] = useState("");
  const [kind, setKind] = useState("note");
  const add = async () => {
    if (!text.trim()) return;
    await post("/api/memories", { project_id: projectID, type: kind, content: text.trim() });
    setText("");
    await reload();
  };
  return (
    <div className="row add">
      <select className="pill" value={kind} onChange={(e) => setKind(e.target.value)}>{MEMORY_KINDS.map((k) => <option key={k} value={k}>{k.replace(/_/g, " ")}</option>)}</select>
      <input className="field grow" placeholder="Add something worth remembering" value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
      <button className="btn" disabled={!text.trim()} onClick={add}>Add</button>
    </div>
  );
}
