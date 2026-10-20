import asyncio
import base64
import json
import os

import pytest
from fastapi import HTTPException

from ide_storage import api_wolf
from ide_storage.attachments import add_attachment, list_attachments
from ide_storage.howl import run_eat
from ide_storage.memory_ops import insert_memory, memories_by_ids
from ide_storage.progress import start_project

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


def test_attachments_are_stored_listed_served_and_deleted():
    pid = start_project("Recipe Box")["id"]

    first = asyncio.run(api_wolf.post_attachment(pid, api_wolf.AttachmentCreate(
        filename="../../shot one.png", content_base64=base64.b64encode(PNG).decode(),
        caption="Kanban board", tags=["reddit-post"],
    )))
    assert first["filename"] == "shot-one.png"
    assert first["content_type"] == "image/png"
    assert "path" not in first

    second = add_attachment(pid, "shot one.png", PNG)
    assert second["filename"] == "shot-one-2.png"  # same name never overwrites

    rows = asyncio.run(api_wolf.get_attachments(pid, tag="reddit-post"))["attachments"]
    assert [r["id"] for r in rows] == [first["id"]]

    served = asyncio.run(api_wolf.get_attachment_file(first["id"]))
    assert os.path.basename(served.path) == "shot-one.png"
    assert served.media_type == "image/png"

    asyncio.run(api_wolf.remove_attachment(first["id"]))
    assert not os.path.exists(served.path)
    assert [r["id"] for r in list_attachments(pid)] == [second["id"]]


def test_attachment_rejects_bad_input():
    pid = start_project("Recipe Box")["id"]
    with pytest.raises(HTTPException) as bad:
        asyncio.run(api_wolf.post_attachment(pid, api_wolf.AttachmentCreate(filename="a.png", content_base64="%%%")))
    assert bad.value.status_code == 400
    with pytest.raises(HTTPException) as missing:
        asyncio.run(api_wolf.post_attachment(999999, api_wolf.AttachmentCreate(
            filename="a.png", content_base64=base64.b64encode(PNG).decode())))
    assert missing.value.status_code == 404


def test_index_recall_is_a_short_table_of_contents():
    pid = start_project("Recipe Box", north_star="Paste a link, get a grocery list.")["id"]
    long_decision = "Use Supabase instead of Firebase because the grocery list needs SQL joins. " * 6
    decision = insert_memory(pid, "decision", long_decision)
    insert_memory(pid, "constraint", "Free tier only: stay under the 500 MB database limit.")
    add_attachment(pid, "board.png", PNG, caption="Kanban board")

    full = run_eat(project_id=pid)
    index = run_eat(project_id=pid, detail="index")
    assert index["detail"] == "index"
    assert len(json.dumps(index)) < len(json.dumps(full))

    brief = index["brief"]
    assert brief["north_star"] == "Paste a link, get a grocery list."
    headline = brief["memories"]["decision"]["items"][0]
    assert headline["headline"].endswith("…") and len(headline["headline"]) <= 140
    assert brief["memories"]["constraint"][0]["content"].startswith("Free tier only")
    assert brief["attachments"][0]["caption"] == "Kanban board"
    assert "get_memories" in brief["drill_down"]["memories"]

    opened = memories_by_ids([decision["id"]])
    assert opened[0]["content"].startswith("Use Supabase")
