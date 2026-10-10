"""Jobs + connectors.

A *job* is a row in ``jobs`` that some connector advances. Connectors are small
adapters configured with ``WOLF_CONNECTORS`` (JSON) in the hub's .env:

    WOLF_CONNECTORS='{
      "models":   {"type": "ollama", "url": "http://<models-host>:11434"},
      "homepage": {"type": "http",   "url": "http://<service-host>/"}
    }'

Kinds:
  model_pull   — ask an Ollama host to pull ``target``; progress tracked from its stream.
  model_list   — snapshot of models on an Ollama host (result JSON).
  probe        — HTTP GET a URL (status/latency) — "is that machine's task up?".
  note         — a manual job the agent records and later closes (deploy watch etc.).

The Wolf Leader container never hosts models itself; ``model_pull`` runs on the
model host and the client downloads from there (see ``download_hint``).
"""
from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any

from ide_storage.db import db_conn

JOB_KINDS = ("model_pull", "model_list", "probe", "note")
STATES = ("queued", "running", "done", "failed", "cancelled")


def _now() -> str:
    return datetime.utcnow().isoformat()


def connectors() -> dict[str, dict[str, Any]]:
    raw = os.environ.get("WOLF_CONNECTORS", "").strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict) and v.get("type")}


def describe_connectors() -> list[dict[str, Any]]:
    out = []
    for name, cfg in connectors().items():
        out.append({"name": name, "type": cfg.get("type"), "url": cfg.get("url"), "kinds": _kinds_for(cfg.get("type"))})
    return out


def _kinds_for(ctype: str | None) -> list[str]:
    return {"ollama": ["model_pull", "model_list"], "http": ["probe"]}.get(ctype or "", []) + ["note"]


# ------------------------------------------------------------------- CRUD
def create_job(
    *,
    kind: str,
    project_id: int | None = None,
    howl_id: int | None = None,
    title: str | None = None,
    connector: str | None = None,
    target: str | None = None,
    payload: dict[str, Any] | None = None,
    run: bool = True,
) -> dict[str, Any]:
    if kind not in JOB_KINDS:
        raise ValueError(f"kind must be one of {JOB_KINDS}")
    if kind != "note":
        cfg = connectors().get(connector or "")
        if not cfg:
            raise ValueError(f"unknown connector {connector!r}; configured: {list(connectors())}")
        if kind not in _kinds_for(cfg.get("type")):
            raise ValueError(f"connector {connector} ({cfg.get('type')}) cannot run {kind}")
    now = _now()
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO jobs (project_id, howl_id, kind, state, title, connector, target, payload, created_at, updated_at)
            VALUES (?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?)
            """,
            (project_id, howl_id, kind, title or f"{kind} {target or ''}".strip(), connector, target,
             json.dumps(payload or {}), now, now),
        )
        job_id = int(cur.lastrowid)
        conn.commit()
    if run and kind != "note":
        t = threading.Thread(target=_run_job, args=(job_id,), daemon=True)
        t.start()
    return get_job(job_id)


def get_job(job_id: int) -> dict[str, Any]:
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM jobs WHERE id = ?", (job_id,))
        row = cur.fetchone()
    if not row:
        raise KeyError(job_id)
    job = dict(row)
    for k in ("payload", "result"):
        if isinstance(job.get(k), str):
            try:
                job[k] = json.loads(job[k])
            except json.JSONDecodeError:
                pass
    return job


def list_jobs(*, project_id: int | None = None, state: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
    sql = "SELECT * FROM jobs WHERE 1=1"
    params: list[Any] = []
    if project_id is not None:
        sql += " AND project_id = ?"
        params.append(project_id)
    if state:
        sql += " AND state = ?"
        params.append(state)
    sql += " ORDER BY updated_at DESC LIMIT ?"
    params.append(limit)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        rows = [dict(r) for r in cur.fetchall()]
    for job in rows:
        for k in ("payload", "result"):
            if isinstance(job.get(k), str):
                try:
                    job[k] = json.loads(job[k])
                except json.JSONDecodeError:
                    pass
    return rows


def update_job(job_id: int, **fields: Any) -> dict[str, Any]:
    allowed = {"state", "title", "result", "error", "progress", "started_at", "finished_at"}
    sets, params = [], []
    for k, v in fields.items():
        if k not in allowed:
            continue
        if k == "result" and not isinstance(v, str):
            v = json.dumps(v, default=str)
        sets.append(f"{k} = ?")
        params.append(v)
    if fields.get("state") in ("done", "failed", "cancelled") and "finished_at" not in fields:
        sets.append("finished_at = ?")
        params.append(_now())
    sets.append("updated_at = ?")
    params.append(_now())
    params.append(job_id)
    with db_conn() as conn:
        conn.cursor().execute(f"UPDATE jobs SET {', '.join(sets)} WHERE id = ?", params)
        conn.commit()
    return get_job(job_id)


# --------------------------------------------------------------- runners
def _http_json(url: str, data: dict | None = None, timeout: float = 30, stream: bool = False):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Content-Type": "application/json"}, method="POST" if data is not None else "GET")
    return urllib.request.urlopen(req, timeout=timeout)


def _run_job(job_id: int) -> None:
    try:
        job = get_job(job_id)
    except KeyError:
        return
    cfg = connectors().get(job.get("connector") or "", {})
    update_job(job_id, state="running", started_at=_now(), progress=0.0)
    try:
        if job["kind"] == "probe":
            result = _probe(cfg.get("url") or job.get("target") or "")
        elif job["kind"] == "model_list":
            result = _ollama_list(cfg["url"])
        elif job["kind"] == "model_pull":
            result = _ollama_pull(job_id, cfg["url"], job.get("target") or "")
        else:
            result = {"note": "manual job; close it with PUT /api/jobs/{id}"}
        update_job(job_id, state="done", result=result, progress=1.0)
    except Exception as exc:  # noqa: BLE001
        update_job(job_id, state="failed", error=str(exc)[:2000])


def _probe(url: str) -> dict[str, Any]:
    if not url:
        raise ValueError("probe needs a url (connector.url or target)")
    t0 = time.time()
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            status = resp.status
            body = resp.read(512).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        status, body = e.code, ""
    return {"url": url, "status": status, "ms": round((time.time() - t0) * 1000), "head": body[:200], "checked_at": _now()}


def _ollama_list(base: str) -> dict[str, Any]:
    with _http_json(f"{base.rstrip('/')}/api/tags") as resp:
        data = json.loads(resp.read().decode())
    models = [{"name": m.get("name"), "size": m.get("size"), "modified_at": m.get("modified_at")} for m in data.get("models", [])]
    return {"host": base, "models": models, "count": len(models), "checked_at": _now()}


def _ollama_pull(job_id: int, base: str, model: str) -> dict[str, Any]:
    if not model:
        raise ValueError("model_pull needs target=<model name>")
    url = f"{base.rstrip('/')}/api/pull"
    last = 0.0
    with _http_json(url, {"model": model, "stream": True}, timeout=3600) as resp:
        for line in resp:
            try:
                ev = json.loads(line.decode())
            except json.JSONDecodeError:
                continue
            total, done = ev.get("total"), ev.get("completed")
            if total and done:
                frac = done / total
                if frac - last >= 0.02:
                    last = frac
                    update_job(job_id, progress=round(frac, 3), title=f"pull {model} — {ev.get('status')}")
            if ev.get("error"):
                raise RuntimeError(ev["error"])
    return {
        "host": base,
        "model": model,
        "pulled_at": _now(),
        "download_hint": {
            "ollama_client": f"OLLAMA_HOST={base} ollama pull {model}",
            "api": f"{base.rstrip('/')}/api/pull  {{\"model\": \"{model}\"}}",
            "blob_api": f"{base.rstrip('/')}/api/show  {{\"model\": \"{model}\"}}",
        },
    }
