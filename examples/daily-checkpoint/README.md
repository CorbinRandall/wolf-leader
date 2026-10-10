# Daily checkpoint integration

Feed an external routine's per-project outcomes into Wolf Leader as a **full
checkpoint** — typed memories + a refreshed `SPEC.yaml` and agent brief — so the
next agent that opens a project picks up what changed without re-reading raw logs.

This is useful when you already run something that summarizes work per project on
a schedule: a nightly journaling/recap routine, a cron job, a CI summary, a
stand-up bot. That routine knows, per project, what got **decided**, what's
**in flight**, and what's **blocked**. `checkpoint.py` turns that into durable
agent memory.

## How it works

`checkpoint.py` reads a JSON payload on stdin and, for each project, calls
`POST /api/save-project`. The hub then extracts typed memories, regenerates that
project's `SPEC.yaml` + `AGENT_BRIEF.md`, and archives the session. Stdlib only —
no dependencies.

```bash
python3 checkpoint.py < payload.json
# or pipe straight from your recap tool:
your-recap-tool --emit-json | python3 checkpoint.py
```

### Payload

```json
{
  "date": "2026-06-26",
  "base_url": "http://127.0.0.1:6971",
  "products": [
    {
      "slug": "my-project",
      "summary": "one-line what-moved",
      "decisions":   ["Locked the API contract to v2.", "Shipped the import endpoint."],
      "active_work": ["Still need to wire the retry queue."],
      "problems":    ["Image upload fails on files over 10 MB."],
      "notes":       ["Dev server runs on port 3000."]
    }
  ]
}
```

Each list maps to a Wolf Leader memory type: `decisions` → `decision`,
`active_work` → `active_work`, `problems` → `problem`, `notes` → `note`.
`slug` must match a project that already exists in the hub.

## Design contract

- **Mirror, never a blocker.** If the hub is unreachable, it skips everything and
  exits `0`. It never fails the routine that calls it.
- **Idempotent per `(date, slug)`.** Re-running a date updates that date's
  checkpoint instead of duplicating it.
- **Doesn't touch your hand-authored docs.** It refreshes `SPEC.yaml` and
  `AGENT_BRIEF.md` (the heuristic distiller's outputs). It never writes
  `SEED.md` or `PROJECT.md`.
- **Decision-biased extractor.** Firmly-worded decisions ("locked X", "shipped Y")
  persist as typed memories; softer notes still surface via the archived session
  and the SPEC's `findings`.
- **Exits 0 on partial failure.** The JSON summary it prints names exactly what
  was checkpointed and what was skipped (unknown slug, no usable outcomes, etc.).

## Output

```json
{
  "ok": true,
  "hub": "http://127.0.0.1:6971",
  "date": "2026-06-26",
  "checkpointed": [
    { "slug": "my-project", "linked": true, "brief_url": "…/api/projects/my-project/agent-brief", "handoff_tier": "orient" }
  ],
  "skipped": []
}
```
