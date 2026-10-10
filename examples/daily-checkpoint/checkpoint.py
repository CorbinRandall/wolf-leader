#!/usr/bin/env python3
"""
Mirror an external routine's per-project outcomes into Wolf Leader as a full
checkpoint (typed memories + refreshed SPEC.yaml + agent brief), once per run
per project.

This is a generic client for any "daily recap" / journaling / cron / CI-summary
routine that already knows, per project, what got decided / what's in flight /
what's blocked. It turns that into durable agent memory the next session loads
via recall() / get_brief(). Stdlib only — no dependencies.

INPUT: JSON on stdin:
{
  "date": "2026-06-26",
  "base_url": "http://127.0.0.1:6971",          # optional, this is the default
  "products": [
    {
      "slug": "my-project",                      # must match an existing Wolf Leader project slug
      "summary": "one-line what-moved",
      "decisions":   ["locked X to Y", ...],     # -> memory type 'decision'
      "active_work": ["still need to deploy Z", ...],  # -> 'active_work'
      "problems":    ["A is broken because B", ...],   # -> 'problem'
      "notes":       ["runs on port 3000", ...]        # -> 'note'
    }
  ]
}

USAGE:
    python3 checkpoint.py < payload.json
    # or
    your-recap-tool --emit-json | python3 checkpoint.py

DESIGN CONTRACT (so it can run unattended and never break the caller):
- If the hub is unreachable it SKIPS everything and exits 0 — treat Wolf Leader
  as a mirror, never a blocker.
- Idempotent per (date, slug): re-running a date updates that date's checkpoint.
- It refreshes each touched project's SPEC.yaml + AGENT_BRIEF.md (the hub's
  heuristic distiller). It never writes the hand-authored SEED.md / PROJECT.md.
- The hub's extractor favors firmly-worded decisions ("locked X", "shipped Y");
  softer notes still surface via the archived session + SPEC findings.
- Exits 0 on partial failure; the JSON summary it prints names what was skipped.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

DEFAULT_BASE = "http://127.0.0.1:6971"
TIMEOUT = 8
# The hub's heuristic extractor wants a real sentence; very short bullets won't extract.
MIN_BULLET = 24


def _get(url: str):
    with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode())


def _post(url: str, payload: dict):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode())


def _typed_lines(product: dict) -> str:
    """Render outcomes in the hub's typed-bullet format (- type: text)."""
    out = []
    for key, mtype in (
        ("decisions", "decision"),
        ("active_work", "active_work"),
        ("problems", "problem"),
        ("notes", "note"),
    ):
        for item in product.get(key) or []:
            text = " ".join(str(item).split()).strip()
            if len(text) >= MIN_BULLET:
                out.append(f"- {mtype}: {text}")
    return "\n".join(out)


def main() -> int:
    try:
        spec = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": f"bad stdin json: {exc}"}))
        return 0

    base = (spec.get("base_url") or DEFAULT_BASE).rstrip("/")
    date = spec.get("date") or "undated"
    products = spec.get("products") or []
    summary = {"ok": True, "hub": base, "date": date, "checkpointed": [], "skipped": []}

    # 1. Health gate — never block the caller if the hub is down.
    try:
        h = _get(f"{base}/health")
        if h.get("status") != "healthy":
            raise RuntimeError(f"unhealthy: {h}")
    except Exception as exc:  # noqa: BLE001
        summary["ok"] = False
        summary["skipped_all"] = f"hub unreachable ({exc.__class__.__name__})"
        print(json.dumps(summary))
        return 0

    # 2. Known slugs.
    try:
        valid = {p["slug"] for p in _get(f"{base}/api/projects").get("projects", []) if p.get("slug")}
    except Exception as exc:  # noqa: BLE001
        summary["ok"] = False
        summary["skipped_all"] = f"could not list projects ({exc})"
        print(json.dumps(summary))
        return 0

    # 3. One full checkpoint per project.
    for p in products:
        slug = (p.get("slug") or "").strip()
        if not slug:
            summary["skipped"].append({"slug": None, "why": "no slug"})
            continue
        if slug not in valid:
            summary["skipped"].append({"slug": slug, "why": "unknown project"})
            continue
        body = _typed_lines(p)
        if not body:
            summary["skipped"].append({"slug": slug, "why": "no usable outcomes"})
            continue
        content = (p.get("summary") or f"Checkpoint {date} for {slug}").strip()
        message = f"Checkpoint for {date}.\n\n{body}"
        try:
            rep = _post(
                f"{base}/api/save-project",
                {
                    "slug": slug,
                    "title": f"{date} · checkpoint",
                    "content": content,
                    "session_id": f"checkpoint-{date}-{slug}",
                    "messages": [{"role": "assistant", "content": message}],
                },
            )
            pipe = rep.get("pipeline") if isinstance(rep.get("pipeline"), dict) else {}
            summary["checkpointed"].append(
                {
                    "slug": slug,
                    "linked": rep.get("project_linked", True),
                    "brief_url": rep.get("brief_url"),
                    "handoff_tier": rep.get("handoff_tier") or pipe.get("handoff_tier"),
                }
            )
        except urllib.error.HTTPError as exc:
            summary["skipped"].append({"slug": slug, "why": f"http {exc.code}"})
        except Exception as exc:  # noqa: BLE001
            summary["skipped"].append({"slug": slug, "why": str(exc)[:120]})

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
