.PHONY: install run-backend run-stack smoke-test install-desktop

install:
	./scripts/install_stack.sh

run-backend:
	./scripts/run_backend.sh

run-stack:
	./scripts/run_stack.sh

smoke-test:
	./scripts/smoke_test_backend.sh

install-desktop:
	./scripts/desktop/install_desktop_app.sh
