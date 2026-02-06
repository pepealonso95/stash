.PHONY: install run-backend run-stack run-everything smoke-test integration-test-codex-cli install-desktop

install:
	./scripts/install_stack.sh

run-backend:
	./scripts/run_backend.sh

run-stack:
	./scripts/run_stack.sh

run-everything:
	./scripts/run_everything.sh

smoke-test:
	./scripts/smoke_test_backend.sh

integration-test-codex-cli:
	./scripts/integration_test_codex_cli_mock.sh

install-desktop:
	./scripts/desktop/install_desktop_app.sh
