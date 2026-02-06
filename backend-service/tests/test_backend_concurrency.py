from __future__ import annotations

import tempfile
import threading
import unittest
from pathlib import Path

from stash_backend.config import Settings
from stash_backend.db import ProjectRepository
from stash_backend.indexer import IndexingService
from stash_backend.project_store import ProjectStore


class BackendConcurrencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.project_store = ProjectStore()
        self.context = self.project_store.open_or_create(name="Demo", root_path=self._tmp.name)
        self.repo = ProjectRepository(self.context)
        self.conversation = self.repo.create_conversation("General")

    def tearDown(self) -> None:
        self.project_store.close()
        self._tmp.cleanup()

    def test_create_message_sequence_numbers_are_unique_under_concurrency(self) -> None:
        worker_count = 24
        barrier = threading.Barrier(worker_count)
        errors: list[Exception] = []
        created_messages: list[dict[str, object]] = []
        guard = threading.Lock()

        def worker(index: int) -> None:
            try:
                barrier.wait(timeout=5)
                message = self.repo.create_message(
                    self.conversation["id"],
                    role="user",
                    content=f"msg-{index}",
                    parts=[],
                    parent_message_id=None,
                    metadata={},
                )
                with guard:
                    created_messages.append(message)
            except Exception as exc:
                with guard:
                    errors.append(exc)

        threads = [threading.Thread(target=worker, args=(idx,)) for idx in range(worker_count)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)

        self.assertFalse(errors, f"concurrent create_message errors: {errors!r}")
        self.assertEqual(len(created_messages), worker_count)

        sequence_numbers = sorted(int(message["sequence_no"]) for message in created_messages)
        expected = list(range(1, worker_count + 1))
        self.assertEqual(sequence_numbers, expected)

    def test_concurrent_asset_reindex_keeps_single_chunk_set(self) -> None:
        root = Path(self._tmp.name)
        file_path = root / "notes.txt"
        file_text = "\n".join(f"line-{index}: alpha beta gamma delta epsilon zeta eta theta" for index in range(240))
        file_path.write_text(file_text, encoding="utf-8")

        asset = self.repo.create_or_update_asset(
            kind="file",
            title="notes.txt",
            path_or_url=str(file_path),
            content=None,
            tags=[],
        )

        indexer = IndexingService(
            Settings(
                chunk_size_chars=120,
                chunk_overlap_chars=40,
            )
        )
        expected_chunks = len(indexer._chunk_text(file_text))
        self.assertGreater(expected_chunks, 1)

        worker_count = 8

        for _ in range(8):
            barrier = threading.Barrier(worker_count)
            errors: list[Exception] = []
            guard = threading.Lock()

            def worker() -> None:
                try:
                    barrier.wait(timeout=5)
                    indexer.index_asset(self.context, self.repo, asset["id"])
                except Exception as exc:
                    with guard:
                        errors.append(exc)

            threads = [threading.Thread(target=worker) for _ in range(worker_count)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=15)

            self.assertFalse(errors, f"concurrent index_asset errors: {errors!r}")

            with self.context.lock:
                chunk_count_row = self.context.conn.execute(
                    "SELECT COUNT(*) AS total FROM chunks WHERE asset_id=?",
                    (asset["id"],),
                ).fetchone()
                embedding_count_row = self.context.conn.execute(
                    "SELECT COUNT(*) AS total FROM embeddings WHERE asset_id=?",
                    (asset["id"],),
                ).fetchone()

            chunk_count = int(chunk_count_row["total"]) if chunk_count_row else -1
            embedding_count = int(embedding_count_row["total"]) if embedding_count_row else -1

            self.assertEqual(chunk_count, expected_chunks)
            self.assertEqual(embedding_count, expected_chunks)


if __name__ == "__main__":
    unittest.main()
