import asyncio

from ide_storage import main
from ide_storage.db import db_conn, init_db


def test_columns_add_edit_delete_and_move_projects(tmp_path, monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_DB_PATH", str(tmp_path / "wolf.db"))
    monkeypatch.setenv("IDE_STORAGE_PROJECTS_DIR", str(tmp_path / "projects"))
    init_db()

    initial = asyncio.run(main.get_kanban_columns())["columns"]
    assert [column["status"] for column in initial] == ["backlog", "in_progress", "done"]

    added = asyncio.run(main.add_kanban_column(main.KanbanColumnCreate(label="Waiting", description="Blocked work")))
    status = added["column"]["status"]
    assert status == "waiting"

    edited = asyncio.run(main.update_kanban_column(status, main.KanbanColumnUpdate(label="Waiting on others")))
    assert edited["column"]["label"] == "Waiting on others"

    reordered = asyncio.run(
        main.reorder_kanban_columns(main.KanbanColumnOrder(statuses=[status, "backlog", "in_progress", "done"]))
    )
    assert reordered["columns"][0]["status"] == status

    with db_conn() as conn:
        conn.execute(
            "INSERT INTO projects (name, path, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            ("Test project", "/test", status, "now", "now"),
        )
        conn.commit()

    deleted = asyncio.run(main.delete_kanban_column(status, "backlog"))
    assert status not in {column["status"] for column in deleted["columns"]}
    with db_conn() as conn:
        row = conn.execute("SELECT status FROM projects WHERE name = 'Test project'").fetchone()
    assert row["status"] == "backlog"
