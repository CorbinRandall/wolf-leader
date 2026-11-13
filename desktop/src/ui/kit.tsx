// Shared pieces every screen uses: the door to the core, small text helpers, Markdown, and the
// card and row the pages are built from.
import { useMemo, useState, type ReactNode } from "react";

declare global {
  interface Window {
    wolf: { call: (name: string, ...args: any[]) => Promise<any>; on: (channel: string, listener: (payload: any) => void) => () => void };
    __nav?: (route: string) => void;
  }
}
export const call = window.wolf.call;
export const APPLE = 978307200;


export const oneLine = (s: any, n = 80) => {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n) + "…" : t;
};
export function when(apple?: number | null): string {
  if (!apple) return "";
  const d = new Date((apple + APPLE) * 1000);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return d.toLocaleDateString([], { month: "short", day: "numeric", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}
export const whenISO = (iso?: string | null) => (iso ? when(Date.parse(iso.endsWith("Z") || iso.includes("+") ? iso : iso + "Z") / 1000 - APPLE) : "");
export const isOpen = (p: any) => !["done", "archived"].includes(p.status);

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
export function Markdown({ text }: { text: string }) {
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


export function Group({ title, subtitle, icon, fold, children }: { title: string; subtitle?: string; icon?: string; fold?: string; children: ReactNode }) {
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

export function Line({ title, detail, children }: { title: string; detail?: string; children?: ReactNode }) {
  return <div className="row line"><div className="grow min0"><b>{title}</b>{detail ? <div className="sub">{detail}</div> : null}</div>{children}</div>;
}
