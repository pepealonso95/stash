from __future__ import annotations

import tempfile
import unittest

from stash_backend.db import ProjectRepository
from stash_backend.project_store import ProjectStore
from stash_backend.utils import utc_now_iso


class ConversationDeleteTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.project_store = ProjectStore()
        self.context = self.project_store.open_or_create(name="DeleteTests", root_path=self._tmp.name)
        self.repo = ProjectRepository(self.context)

    def tearDown(self) -> None:
        self.project_store.close()
        self._tmp.cleanup()

    def test_delete_conversation_removes_related_records_and_resets_active(self) -> None:
        conv_a = self.repo.create_conversation("A")
        conv_b = self.repo.create_conversation("B")
        self.repo.update_project(active_conversation_id=conv_a["id"])

        msg = self.repo.create_message(
            conv_a["id"],
            role="user",
            content="hello",
            parts=[],
            parent_message_id=None,
            metadata={},
        )
        asset = self.repo.create_or_update_asset(
            kind="note",
            title="Note",
            path_or_url=None,
            content="note body",
            tags=[],
        )
        self.repo.create_message_attachment(msg["id"], asset["id"])

        run = self.repo.create_run(conv_a["id"], msg["id"], mode="manual")
        step_id = self.repo.create_run_step(
            run["id"],
            1,
            "codex_cmd",
            {"cmd": "echo hi"},
        )
        self.repo.finish_run_step(step_id, status="completed", output_data={"exit_code": 0})
        self.repo.upsert_run_change_set(
            run["id"],
            outcome_kind="response_only",
            requires_confirmation=False,
            change_set_id=None,
            changes=[],
            preview_path=None,
            status="none",
        )
        self.repo.add_event(
            "run_started",
            conversation_id=conv_a["id"],
            run_id=run["id"],
            payload={"ts": utc_now_iso()},
        )

        deleted = self.repo.delete_conversation(conv_a["id"])
        self.assertIsNotNone(deleted)
        self.assertEqual(deleted["conversation_id"], conv_a["id"])
        self.assertEqual(deleted["active_conversation_id"], conv_b["id"])

        self.assertIsNone(self.repo.get_conversation(conv_a["id"]))
        self.assertIsNone(self.repo.get_run(run["id"]))
        self.assertEqual(self.repo.list_messages(conv_a["id"], cursor=None, limit=100), [])
        self.assertIsNone(self.repo.get_run_change_set(run["id"]))

        attachments_left = self.repo._fetchone(
            "SELECT COUNT(*) AS total FROM message_attachments WHERE message_id=?",
            (msg["id"],),
        )
        run_steps_left = self.repo._fetchone(
            "SELECT COUNT(*) AS total FROM run_steps WHERE run_id=?",
            (run["id"],),
        )
        run_events_left = self.repo._fetchone(
            "SELECT COUNT(*) AS total FROM events WHERE run_id=?",
            (run["id"],),
        )
        conversation_events_left = self.repo._fetchone(
            "SELECT COUNT(*) AS total FROM events WHERE conversation_id=?",
            (conv_a["id"],),
        )

        self.assertEqual(int(attachments_left["total"]), 0)
        self.assertEqual(int(run_steps_left["total"]), 0)
        self.assertEqual(int(run_events_left["total"]), 0)
        self.assertEqual(int(conversation_events_left["total"]), 0)

        project_view = self.repo.project_view()
        self.assertEqual(project_view["active_conversation_id"], conv_b["id"])

    def test_delete_conversation_returns_none_for_missing_id(self) -> None:
        self.assertIsNone(self.repo.delete_conversation("conv_missing"))


if __name__ == "__main__":
    unittest.main()
