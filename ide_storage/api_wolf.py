"""REST surface for /wolfhowl, /wolfeat, paths, catalog/RAG, jobs, vault and wiki."""
from __future__ import annotations

import logging
import os
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ide_storage.branding import PRODUCT_NAME

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["wolf"])


def _public() -> str:
    return os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")


# ---------------------------------------------------------------- models
class HowlMessage(BaseModel):
    role: str
    content: str
    created_at: Optional[str] = None


class GitState(BaseModel):
    commit: Optional[str] = None
    branch: Optional[str] = None
    remote: Optional[str] = None
    dirty_files: Optional[int] = None
    is_repo: Optional[bool] = None


class HowlBody(BaseModel):
    session_id: Optional[str] = None
    slug: Optional[str] = None
    workspace_path: Optional[str] = None
    title: Optional[str] = None
    content: Optional[str] = None
    messages: Optional[List[HowlMessage]] = None
    occurred_at: Optional[str] = None
    device_name: Optional[str] = None
    git: Optional[GitState] = None
    cited_paths: Optional[List[str]] = None
    ingest_cited: bool = False
    refresh_catalog: bool = True
    client_os: Optional[str] = None  # windows | mac | linux — picks the remote spelling


class HowlGitUpdate(BaseModel):
    commit: str
    branch: Optional[str] = None
    remote: Optional[str] = None


class IngestBody(BaseModel):
    project_id: int
    paths: List[str]
    howl_id: Optional[int] = None
    reason: str = "approved"


class PathBody(BaseModel):
    path: str
    kind: str = "workspace"
    device_name: Optional[str] = None


class JobBody(BaseModel):
    kind: str
    project_id: Optional[int] = None
    howl_id: Optional[int] = None
    title: Optional[str] = None
    connector: Optional[str] = None
    target: Optional[str] = None
    payload: Optional[Dict[str, Any]] = None
    run: bool = True


class JobUpdate(BaseModel):
    state: Optional[str] = None
    title: Optional[str] = None
    result: Optional[Any] = None
    error: Optional[str] = None
    progress: Optional[float] = None


# ------------------------------------------------------------- howl / eat
@router.get("/howl-guide")
async def get_howl_guide():
    from ide_storage.howl import howl_guide

    return {
        "content": howl_guide(),
        "agent_prompt": f"Broadcast this session to {PRODUCT_NAME}. Fetch and follow: {_public()}/api/howl-guide",
        "howl_url": f"{_public()}/api/howl",
        "eat_url": f"{_public()}/api/eat",
    }


@router.get("/eat-guide")
async def get_eat_guide():
    from ide_storage.howl import eat_guide

    return {
        "content": eat_guide(),
        "agent_prompt": f"Pull the latest {PRODUCT_NAME} context for this project. Fetch and follow: {_public()}/api/eat-guide",
        "eat_url": f"{_public()}/api/eat",
    }


@router.post("/howl")
async def post_howl(body: HowlBody = HowlBody()):
    from ide_storage.howl import run_howl

    messages = None
    if body.messages:
        messages = [
            {"role": m.role, "content": m.content, **({"created_at": m.created_at} if m.created_at else {})}
            for m in body.messages
        ]
    try:
        report = run_howl(
            session_id=body.session_id,
            slug=body.slug,
            workspace_path=body.workspace_path,
            title=body.title,
            content=body.content,
            messages=messages,
            occurred_at=body.occurred_at,
            device_name=body.device_name,
            git=body.git.model_dump(exclude_none=True) if body.git else None,
            cited_paths=body.cited_paths,
            ingest_cited=body.ingest_cited,
            refresh_catalog=body.refresh_catalog,
            client_os=body.client_os,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("howl failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    if not report.get("ok"):
        raise HTTPException(status_code=400, detail=report.get("error") or "howl failed")
    return report


@router.put("/howls/{howl_id}/git")
async def put_howl_git(howl_id: int, body: HowlGitUpdate):
    """Agent committed after the howl (on offer) — pin the SHA to the howl."""
    from ide_storage.db import db_conn
    from ide_storage.mirrors import refresh_mirrors

    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT project_id FROM howls WHERE id = ?", (howl_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="howl not found")
        cur.execute(
            "UPDATE howls SET git_commit = ?, git_branch = COALESCE(?, git_branch), git_remote = COALESCE(?, git_remote) WHERE id = ?",
            (body.commit, body.branch, body.remote, howl_id),
        )
        conn.commit()
    return {"ok": True, "howl_id": howl_id, "git_commit": body.commit, "mirrors": refresh_mirrors(row["project_id"], howl_id=howl_id)}


@router.get("/howls")
async def list_howls(project_id: Optional[int] = None, limit: int = 30):
    from ide_storage.db import db_conn

    sql = """
        SELECT h.id, h.project_id, p.slug, p.name, h.chat_id, h.device_name, h.workspace_path,
               h.summary, h.git_commit, h.git_branch, h.memories_added, h.files_ingested, h.created_at
        FROM howls h LEFT JOIN projects p ON p.id = h.project_id
    """
    params: list[Any] = []
    if project_id is not None:
        sql += " WHERE h.project_id = ?"
        params.append(project_id)
    sql += " ORDER BY h.created_at DESC LIMIT ?"
    params.append(limit)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        return [dict(r) for r in cur.fetchall()]


@router.get("/eat")
async def get_eat(
    slug: Optional[str] = None,
    project_id: Optional[int] = None,
    workspace_path: Optional[str] = None,
    path: Optional[str] = None,
    device_name: Optional[str] = None,
    since: Optional[str] = None,
    q: Optional[str] = None,
):
    from ide_storage.howl import run_eat

    result = run_eat(slug=slug, project_id=project_id, workspace_path=workspace_path or path,
                     device_name=device_name, since=since, query=q)
    if not result.get("ok"):
        raise HTTPException(status_code=404, detail=result)
    return result


# --------------------------------------------------------------- projects
class EnsureProjectBody(BaseModel):
    path: str
    name: Optional[str] = None
    slug: Optional[str] = None
    device_name: Optional[str] = None
    description: Optional[str] = None


@router.post("/projects/ensure")
async def ensure_project(body: EnsureProjectBody):
    """Resolve the project for a folder, creating it (name from folder) if none matches."""
    from ide_storage.hub import create_project_for_path

    try:
        p = create_project_for_path(body.path, name=body.name, slug=body.slug,
                                    device_name=body.device_name, description=body.description)
    except Exception as exc:  # noqa: BLE001
        logger.exception("ensure project failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"ok": True, "created": bool(p.get("created")), "project_id": p["id"],
            "slug": p.get("slug"), "name": p.get("name")}


# ------------------------------------------------------------------ paths
@router.get("/paths/aliases")
async def get_aliases():
    from ide_storage.paths import describe_aliases

    return describe_aliases()


@router.get("/paths/resolve")
async def resolve_path(path: str):
    from ide_storage.paths import to_hub_path, variants, resolve_project_id_by_path

    return {"input": path, "hub_path": to_hub_path(path), "variants": variants(path),
            "project_id": resolve_project_id_by_path(path)}


@router.get("/projects/{project_id}/paths")
async def get_project_paths(project_id: int):
    from ide_storage.paths import project_paths

    return project_paths(project_id)


@router.post("/projects/{project_id}/paths")
async def add_project_path(project_id: int, body: PathBody):
    from ide_storage.paths import register_project_path

    try:
        return register_project_path(project_id, body.path, kind=body.kind, device_name=body.device_name)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=str(exc)) from exc


# ---------------------------------------------------------- catalog / RAG
@router.post("/projects/{project_id}/catalog/refresh")
async def refresh_project_catalog(project_id: int):
    from ide_storage.catalog import refresh_catalog

    return refresh_catalog(project_id)


@router.get("/catalog")
async def search_catalog(q: str, project_id: Optional[int] = None, limit: int = 20):
    from ide_storage.catalog import catalog_search

    return {"query": q, "results": catalog_search(project_id, q, limit=limit)}


@router.post("/ingest-files")
async def ingest_files_ep(body: IngestBody):
    from ide_storage.catalog import ingest_files
    from ide_storage.mirrors import refresh_mirrors

    report = ingest_files(body.project_id, body.paths, reason=body.reason, howl_id=body.howl_id)
    if body.howl_id:
        from ide_storage.db import db_conn

        with db_conn() as conn:
            conn.cursor().execute(
                "UPDATE howls SET files_ingested = files_ingested + ? WHERE id = ?", (len(report["ingested"]), body.howl_id)
            )
            conn.commit()
    report["mirrors"] = refresh_mirrors(body.project_id, howl_id=body.howl_id)
    return report


# ------------------------------------------------------------------- jobs
@router.get("/connectors")
async def get_connectors():
    from ide_storage.jobs import describe_connectors

    return describe_connectors()


@router.get("/jobs")
async def get_jobs(project_id: Optional[int] = None, state: Optional[str] = None, limit: int = 50):
    from ide_storage.jobs import list_jobs

    return list_jobs(project_id=project_id, state=state, limit=limit)


@router.post("/jobs")
async def post_job(body: JobBody):
    from ide_storage.jobs import create_job

    try:
        return create_job(kind=body.kind, project_id=body.project_id, howl_id=body.howl_id, title=body.title,
                          connector=body.connector, target=body.target, payload=body.payload, run=body.run)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/jobs/{job_id}")
async def get_job_ep(job_id: int):
    from ide_storage.jobs import get_job

    try:
        return get_job(job_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="job not found")


@router.put("/jobs/{job_id}")
async def put_job(job_id: int, body: JobUpdate):
    from ide_storage.jobs import STATES, update_job

    if body.state and body.state not in STATES:
        raise HTTPException(status_code=400, detail=f"state must be one of {STATES}")
    try:
        return update_job(job_id, **body.model_dump(exclude_none=True))
    except KeyError:
        raise HTTPException(status_code=404, detail="job not found")


# ----------------------------------------------------------- vault / wiki
@router.post("/vault/refresh")
async def vault_refresh(project_id: Optional[int] = None):
    from ide_storage.vault import refresh_vault, vault_root, write_home, write_project_note, write_topics
    from ide_storage.db import db_conn

    if not vault_root():
        raise HTTPException(status_code=400, detail="IDE_STORAGE_VAULT_DIR not set")
    if project_id is not None:
        return refresh_vault(project_id)
    with db_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM projects WHERE COALESCE(status,'active') != 'archived'")
        ids = [int(r["id"]) for r in cur.fetchall()]
    notes = [write_project_note(i) for i in ids]
    return {"vault": vault_root(), "projects": len([n for n in notes if n]), "home": write_home(), "topics": len(write_topics())}


@router.post("/wiki/rebuild")
async def wiki_rebuild():
    from ide_storage.wiki_export import export_and_build

    return export_and_build()


@router.get("/wiki/status")
async def wiki_status():
    from ide_storage.wiki_export import CONTENT_DIR, wiki_enabled, wiki_out_dir

    out = wiki_out_dir()
    return {"enabled": wiki_enabled(), "built": out is not None, "out": str(out) if out else None,
            "content_dir": str(CONTENT_DIR), "url": f"{_public()}/wiki/"}
