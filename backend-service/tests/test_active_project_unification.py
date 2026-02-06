from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from stash_backend.api import _ensure_active_project_loaded
from stash_backend.config import Settings
from stash_backend.service_container import build_services


class ActiveProjectUnificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._project_dir = tempfile.TemporaryDirectory()
        self._config_dir = tempfile.TemporaryDirectory()
        self.runtime_config_path = str((Path(self._config_dir.name) / "runtime-config.json").resolve())

    def tearDown(self) -> None:
        self._project_dir.cleanup()
        self._config_dir.cleanup()

    def _new_services(self):
        settings = Settings(runtime_config_path=self.runtime_config_path, scan_interval_seconds=60)
        return build_services(settings)

    def test_active_project_persists_and_auto_loads_after_service_restart(self) -> None:
        project_root = Path(self._project_dir.name).resolve()
        project_id = ""
        first_services = self._new_services()

        context = first_services.project_store.open_or_create(
            name="Demo",
            root_path=str(project_root),
        )
        project_id = context.project_id
        first_services.runtime_config.update(
            active_project_id=project_id,
            active_project_root_path=str(context.root_path),
        )
        first_services.project_store.close()

        self.assertTrue(project_id)
        second_services = self._new_services()
        second_services.watcher.ensure_project_watch = lambda _project_id: None  # type: ignore[assignment]

        self.assertEqual(second_services.project_store.list_projects(), [])
        _ensure_active_project_loaded(second_services)

        loaded_projects = second_services.project_store.list_projects()
        self.assertEqual(len(loaded_projects), 1)
        loaded = loaded_projects[0]
        self.assertEqual(loaded.project_id, project_id)
        self.assertEqual(loaded.root_path.resolve(), project_root)

        cfg = second_services.runtime_config.get()
        self.assertEqual(cfg.active_project_id, project_id)
        self.assertEqual(Path(cfg.active_project_root_path or "").resolve(), project_root)
        second_services.project_store.close()

    def test_missing_active_project_root_clears_runtime_selection(self) -> None:
        project_root = Path(self._project_dir.name).resolve()
        first_services = self._new_services()
        context = first_services.project_store.open_or_create(
            name="Demo",
            root_path=str(project_root),
        )
        first_services.runtime_config.update(
            active_project_id=context.project_id,
            active_project_root_path=str(context.root_path),
        )
        first_services.project_store.close()

        shutil.rmtree(project_root, ignore_errors=True)
        self.assertFalse(project_root.exists())
        second_services = self._new_services()
        second_services.watcher.ensure_project_watch = lambda _project_id: None  # type: ignore[assignment]
        _ensure_active_project_loaded(second_services)

        self.assertEqual(second_services.project_store.list_projects(), [])
        cfg = second_services.runtime_config.get()
        self.assertIsNone(cfg.active_project_id)
        self.assertIsNone(cfg.active_project_root_path)
        second_services.project_store.close()


if __name__ == "__main__":
    unittest.main()
