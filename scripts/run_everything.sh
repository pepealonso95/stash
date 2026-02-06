#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install_stack.sh"
RUN_SCRIPT="$ROOT_DIR/scripts/run_stack.sh"
VENV_DIR="$ROOT_DIR/.venv"

MODE="auto"

usage() {
  cat <<USAGE
Usage: ./scripts/run_everything.sh [--install|--skip-install]

Runs the full Stash stack (backend + frontend) with one command.

Options:
  --install       Always run install first.
  --skip-install  Never run install first.
  -h, --help      Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      MODE="install"
      shift
      ;;
    --skip-install)
      MODE="skip-install"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$MODE" == "install" ]]; then
  "$INSTALL_SCRIPT"
elif [[ "$MODE" == "auto" ]]; then
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "No .venv found. Running install first..."
    "$INSTALL_SCRIPT"
  else
    echo "Using existing environment in $VENV_DIR"
    echo "Pass --install to force reinstall."
  fi
fi

exec "$RUN_SCRIPT"
