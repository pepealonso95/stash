#!/usr/bin/env bash
set -euo pipefail

SUITE_NAME="com.stash.overlay.settings"
MODE_KEY="overlayMode"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/desktop/set_overlay_mode.sh <visible|hidden|disabled>

Examples:
  ./scripts/desktop/set_overlay_mode.sh hidden
  ./scripts/desktop/set_overlay_mode.sh visible
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

MODE="$1"
case "$MODE" in
  visible|hidden|disabled)
    ;;
  *)
    echo "Invalid overlay mode: $MODE" >&2
    usage
    exit 1
    ;;
esac

defaults write "$SUITE_NAME" "$MODE_KEY" -string "$MODE"
CURRENT_MODE="$(defaults read "$SUITE_NAME" "$MODE_KEY")"

echo "Overlay startup mode set to: $CURRENT_MODE"
echo "Restart Stash Local for the change to take effect."
