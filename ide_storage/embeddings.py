"""Optional CPU ONNX embeddings via fastembed (all-MiniLM-L6-v2)."""
from __future__ import annotations

import os
import struct
from typing import Sequence

DEFAULT_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
DEFAULT_DIM = 384

_model = None
_model_name: str | None = None
_load_error: str | None = None


def embeddings_enabled() -> bool:
    return os.environ.get("IDE_STORAGE_EMBEDDINGS_ENABLED", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


def embed_model_name() -> str:
    return os.environ.get("IDE_STORAGE_EMBED_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL


def embed_dim() -> int:
    name = embed_model_name()
    if "MiniLM" in name or name.endswith("all-MiniLM-L6-v2"):
        return 384
    return int(os.environ.get("IDE_STORAGE_EMBED_DIM", str(DEFAULT_DIM)))


def embeddings_available() -> bool:
    if not embeddings_enabled():
        return False
    try:
        _get_model()
        return True
    except Exception:
        return False


def embeddings_status() -> dict:
    return {
        "enabled": embeddings_enabled(),
        "available": embeddings_available(),
        "model": embed_model_name(),
        "dim": embed_dim(),
        "error": _load_error,
    }


def _cache_dir() -> str | None:
    path = os.environ.get("FASTEMBED_CACHE_PATH", "").strip()
    return path or None


def _get_model():
    global _model, _model_name, _load_error
    if not embeddings_enabled():
        raise RuntimeError("embeddings disabled (IDE_STORAGE_EMBEDDINGS_ENABLED)")
    name = embed_model_name()
    if _model is not None and _model_name == name:
        return _model
    try:
        from fastembed import TextEmbedding

        kwargs: dict = {"model_name": name}
        cache = _cache_dir()
        if cache:
            kwargs["cache_dir"] = cache
        _model = TextEmbedding(**kwargs)
        _model_name = name
        _load_error = None
        return _model
    except Exception as exc:
        _load_error = str(exc)
        raise


def embed_texts(texts: Sequence[str]) -> list[list[float]] | None:
    """Return embedding vectors, or None when embeddings are disabled/unavailable.

    Contract: the returned list is positionally aligned 1:1 with ``texts`` so
    callers (sync_dirty, backfill) can safely ``zip`` vectors back onto their
    source rows. We intentionally do NOT drop empty entries — empty/whitespace
    strings are replaced with a single-space placeholder to keep alignment and
    avoid model errors on empty input. Callers should pre-filter rows that have
    no usable text before embedding.
    """
    if not embeddings_enabled():
        return None
    cleaned = [(t or "").strip() for t in texts]
    if not cleaned:
        return []
    safe = [c if c else " " for c in cleaned]
    try:
        model = _get_model()
        vectors = [list(vec) for vec in model.embed(safe)]
    except Exception as exc:
        global _load_error
        _load_error = str(exc)
        return None
    if len(vectors) != len(cleaned):
        _load_error = (
            f"embedding count mismatch: got {len(vectors)} vectors for {len(cleaned)} texts"
        )
        return None
    return vectors


def embed_one(text: str) -> list[float] | None:
    vecs = embed_texts([text])
    if vecs is None:
        return None
    return vecs[0] if vecs else None


def serialize_vector(vector: Sequence[float]) -> bytes:
    return struct.pack(f"{len(vector)}f", *vector)


def deserialize_vector(blob: bytes) -> list[float]:
    n = len(blob) // 4
    return list(struct.unpack(f"{n}f", blob))
