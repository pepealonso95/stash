#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET_DIR="${STASH_DESKTOP_TARGET_DIR:-$HOME/Desktop}"
APP_NAME="${STASH_DESKTOP_APP_NAME:-Stash Local.app}"
APP_BUNDLE="$TARGET_DIR/$APP_NAME"

BACKEND_URL="${STASH_BACKEND_URL:-http://127.0.0.1:8765}"
RUNTIME_BASE="${STASH_RUNTIME_BASE:-$HOME/Library/Application Support/StashLocal/runtime}"
BACKEND_VENV="$RUNTIME_BASE/.venv"
BACKEND_CODEX_MODE="${STASH_CODEX_MODE:-cli}"
BACKEND_CODEX_BIN=""
APP_VERSION="${STASH_DESKTOP_APP_VERSION:-0.3.0}"

ICON_SOURCE="${STASH_ICON_SOURCE:-$ROOT_DIR/frontend-macos/Resources/AppIcon-source.png}"
ICON_ICNS="${STASH_ICON_ICNS:-$ROOT_DIR/frontend-macos/Resources/AppIcon.icns}"

usage() {
  cat <<'USAGE'
Developer installer (builds from local source)

Usage:
  ./scripts/desktop/install_desktop_app.sh

Optional environment variables:
  STASH_DESKTOP_TARGET_DIR   Output folder (default: ~/Desktop)
  STASH_DESKTOP_APP_NAME     App bundle name (default: Stash Local.app)
  STASH_BACKEND_URL          Backend URL in launcher config (default: http://127.0.0.1:8765)
  STASH_RUNTIME_BASE         Runtime folder (default: ~/Library/Application Support/StashLocal/runtime)
  STASH_CODEX_MODE           Codex mode (default: cli)
  STASH_CODEX_BIN            Codex binary override
  STASH_DESKTOP_APP_VERSION  App version string (default: 0.3.0)

End-user install path (no local Swift build):
  ./scripts/desktop/install_from_release.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

log() {
  printf '[stash-installer] %s\n' "$1"
}

find_frontend_release_binary() {
  local candidate
  candidate=""

  if [[ -x "$ROOT_DIR/frontend-macos/.build/release/StashMacOSApp" ]]; then
    candidate="$ROOT_DIR/frontend-macos/.build/release/StashMacOSApp"
  fi

  if [[ -z "$candidate" ]]; then
    candidate="$(find "$ROOT_DIR/frontend-macos/.build" -type f -name 'StashMacOSApp' -perm -u+x 2>/dev/null | grep '/release/' | head -n 1 || true)"
  fi

  printf '%s' "$candidate"
}

find_overlay_release_binary() {
  local candidate
  candidate=""

  if [[ -x "$ROOT_DIR/frontend-macos/.build/release/StashOverlay" ]]; then
    candidate="$ROOT_DIR/frontend-macos/.build/release/StashOverlay"
  fi

  if [[ -z "$candidate" ]]; then
    candidate="$(find "$ROOT_DIR/frontend-macos/.build" -type f -name 'StashOverlay' -perm -u+x 2>/dev/null | grep '/release/' | head -n 1 || true)"
  fi

  printf '%s' "$candidate"
}

resolve_codex_binary() {
  if [[ -n "${STASH_CODEX_BIN:-}" && -x "${STASH_CODEX_BIN:-}" ]]; then
    printf '%s' "${STASH_CODEX_BIN:-}"
    return
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return
  fi

  for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex "$HOME/.local/bin/codex"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done

  printf '%s' "codex"
}

if [[ ! -d "$ROOT_DIR/frontend-macos" ]]; then
  echo "frontend-macos folder is missing. Cannot build desktop app." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required to build frontend-macos" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to build backend runtime" >&2
  exit 1
fi

BACKEND_CODEX_BIN="$(resolve_codex_binary)"
log "Developer source installer: building from local repo"
log "Using Codex CLI binary: $BACKEND_CODEX_BIN"

log "Preparing backend runtime at $BACKEND_VENV"
mkdir -p "$RUNTIME_BASE"
python3 -m venv "$BACKEND_VENV"
# shellcheck disable=SC1091
source "$BACKEND_VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install "$ROOT_DIR/backend-service"

if [[ ! -x "$BACKEND_VENV/bin/uv" ]]; then
  python -m pip install "uv>=0.4.30"
fi

if [[ ! -x "$BACKEND_VENV/bin/uv" ]]; then
  echo "Failed to provision required CLI tool: uv" >&2
  exit 1
fi

PYPDF_VERSION="$(python - <<'PY'
import pypdf
print(pypdf.__version__)
PY
)"

log "Backend toolchain ready (uv: $BACKEND_VENV/bin/uv, pypdf: $PYPDF_VERSION)"
deactivate >/dev/null 2>&1 || true

log "Building frontend release binaries"
(
  cd "$ROOT_DIR/frontend-macos"
  swift build -c release --product StashMacOSApp
  swift build -c release --product StashOverlay
)

if [[ -f "$ICON_SOURCE" ]]; then
  log "Building app icon from $ICON_SOURCE"
  STASH_ICON_SOURCE="$ICON_SOURCE" STASH_ICNS_OUT="$ICON_ICNS" "$ROOT_DIR/scripts/desktop/build_icns.sh"
else
  log "Icon source not found at $ICON_SOURCE; continuing without icon override"
fi

FRONTEND_BIN="$(find_frontend_release_binary)"
OVERLAY_BIN="$(find_overlay_release_binary)"
if [[ -z "$FRONTEND_BIN" || ! -x "$FRONTEND_BIN" ]]; then
  echo "Could not locate built frontend binary." >&2
  exit 1
fi
if [[ -z "$OVERLAY_BIN" || ! -x "$OVERLAY_BIN" ]]; then
  echo "Could not locate built overlay binary." >&2
  exit 1
fi

log "Assembling app bundle at $APP_BUNDLE"
STASH_BACKEND_URL="$BACKEND_URL" \
STASH_CODEX_MODE="$BACKEND_CODEX_MODE" \
STASH_RUNTIME_BASE="$RUNTIME_BASE" \
STASH_CODEX_BIN="$BACKEND_CODEX_BIN" \
STASH_ICON_ICNS="$ICON_ICNS" \
"$ROOT_DIR/scripts/desktop/assemble_app_bundle.sh" \
  --frontend-bin "$FRONTEND_BIN" \
  --overlay-bin "$OVERLAY_BIN" \
  --out-app "$APP_BUNDLE" \
  --version "$APP_VERSION"

log "Desktop app installed"
log "- App: $APP_BUNDLE"
log "- Backend runtime: $BACKEND_VENV"
log "- Backend URL: $BACKEND_URL"
log "Double-click the app bundle to launch locally."
log "For end-user machines, prefer ./scripts/desktop/install_from_release.sh"
