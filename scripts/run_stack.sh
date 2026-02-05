#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_PROJECT_PATH="${STASH_FRONTEND_PROJECT_PATH:-}"

cleanup() {
  if [[ -n "${BACKEND_PID:-}" ]]; then
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
    wait "$BACKEND_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$ROOT_DIR/scripts/run_backend.sh" &
BACKEND_PID=$!

sleep 1

echo "Backend running on http://127.0.0.1:8765 (pid=$BACKEND_PID)"

if [ -n "$FRONTEND_PROJECT_PATH" ] && [ -d "$FRONTEND_PROJECT_PATH" ]; then
  echo "Opening frontend project: $FRONTEND_PROJECT_PATH"
  open "$FRONTEND_PROJECT_PATH"
else
  FRONTEND_PACKAGE=""
  if [ -f "$ROOT_DIR/frontend-macos/Package.swift" ]; then
    FRONTEND_PACKAGE="$ROOT_DIR/frontend-macos/Package.swift"
  fi

  XCODEPROJ="$(find "$ROOT_DIR" -maxdepth 4 -type d -name '*.xcodeproj' \
    ! -path "$ROOT_DIR/.git/*" \
    ! -path "$ROOT_DIR/.venv/*" \
    ! -path "$ROOT_DIR/backend-service/*" | head -n 1)"

  if [ -n "$XCODEPROJ" ]; then
    echo "Opening frontend project: $XCODEPROJ"
    open "$XCODEPROJ"
  elif [ -n "$FRONTEND_PACKAGE" ]; then
    echo "Opening frontend Swift package: $FRONTEND_PACKAGE"
    open "$FRONTEND_PACKAGE"
  else
    echo "No frontend Xcode project or Swift package found."
    echo "Set STASH_FRONTEND_PROJECT_PATH to an .xcodeproj if needed."
    echo "Backend stays running. Press Ctrl+C to stop."
  fi
fi

wait "$BACKEND_PID"
