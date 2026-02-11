#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/desktop/assemble_app_bundle.sh \
    --frontend-bin <path> \
    --overlay-bin <path> \
    --out-app <path/to/App.app> \
    [--version <x.y.z>] \
    [--icon-icns <path>]

Environment overrides written into launcher.conf:
  STASH_BACKEND_URL   (default: http://127.0.0.1:8765)
  STASH_CODEX_MODE    (default: cli)
  STASH_RUNTIME_BASE  (optional)
  STASH_CODEX_BIN     (optional)
USAGE
}

FRONTEND_BIN=""
OVERLAY_BIN=""
OUT_APP=""
APP_VERSION="0.3.0"
ICON_ICNS="${STASH_ICON_ICNS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frontend-bin)
      FRONTEND_BIN="$2"
      shift 2
      ;;
    --overlay-bin)
      OVERLAY_BIN="$2"
      shift 2
      ;;
    --out-app)
      OUT_APP="$2"
      shift 2
      ;;
    --version)
      APP_VERSION="$2"
      shift 2
      ;;
    --icon-icns)
      ICON_ICNS="$2"
      shift 2
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

if [[ -z "$FRONTEND_BIN" || -z "$OVERLAY_BIN" || -z "$OUT_APP" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

if [[ ! -x "$FRONTEND_BIN" ]]; then
  echo "Frontend binary not executable: $FRONTEND_BIN" >&2
  exit 1
fi

if [[ ! -x "$OVERLAY_BIN" ]]; then
  echo "Overlay binary not executable: $OVERLAY_BIN" >&2
  exit 1
fi

OUT_APP="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT_APP")"
APP_CONTENTS="$OUT_APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

python3 - <<PY
from pathlib import Path
import shutil

app = Path(r'''$OUT_APP''')
if app.exists():
    shutil.rmtree(app)
(app / 'Contents' / 'MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Contents' / 'Resources').mkdir(parents=True, exist_ok=True)
PY

cp "$FRONTEND_BIN" "$APP_RESOURCES/StashMacOSApp"
chmod +x "$APP_RESOURCES/StashMacOSApp"
cp "$OVERLAY_BIN" "$APP_RESOURCES/StashOverlay"
chmod +x "$APP_RESOURCES/StashOverlay"

if [[ -n "$ICON_ICNS" && -f "$ICON_ICNS" ]]; then
  cp "$ICON_ICNS" "$APP_RESOURCES/AppIcon.icns"
fi

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Stash Local</string>
  <key>CFBundleDisplayName</key>
  <string>Stash Local</string>
  <key>CFBundleIdentifier</key>
  <string>com.pepealonso95.stash.local.desktop</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>StashDesktopLauncher</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$APP_RESOURCES/launcher.conf" <<EOF_CONF
STASH_BACKEND_URL="${STASH_BACKEND_URL:-http://127.0.0.1:8765}"
STASH_CODEX_MODE="${STASH_CODEX_MODE:-cli}"
EOF_CONF

if [[ -n "${STASH_RUNTIME_BASE:-}" ]]; then
  printf 'STASH_RUNTIME_BASE="%s"\n' "$STASH_RUNTIME_BASE" >> "$APP_RESOURCES/launcher.conf"
fi

if [[ -n "${STASH_CODEX_BIN:-}" ]]; then
  printf 'STASH_CODEX_BIN="%s"\n' "$STASH_CODEX_BIN" >> "$APP_RESOURCES/launcher.conf"
fi

cat > "$APP_MACOS/StashDesktopLauncher" <<'EOF_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES_DIR="$(cd "$SCRIPT_DIR/../Resources" && pwd)"
CONF_PATH="$RES_DIR/launcher.conf"
OVERLAY_BIN="$RES_DIR/StashOverlay"

if [[ ! -f "$CONF_PATH" ]]; then
  osascript -e 'display alert "Stash Local" message "Launcher config missing. Re-run installer." as critical'
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF_PATH"

STASH_BACKEND_URL="${STASH_BACKEND_URL:-http://127.0.0.1:8765}"
STASH_CODEX_MODE="${STASH_CODEX_MODE:-cli}"
RUNTIME_BASE="${STASH_RUNTIME_BASE:-$HOME/Library/Application Support/StashLocal/runtime}"
BACKEND_VENV="$RUNTIME_BASE/.venv"

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

CODEX_BIN="$(resolve_codex_binary)"

LOG_DIR="$HOME/Library/Logs/StashLocal"
STATE_DIR="$HOME/Library/Application Support/StashLocal"
BACKEND_PID_FILE="$STATE_DIR/backend.pid"
mkdir -p "$LOG_DIR" "$STATE_DIR"

export PATH="$BACKEND_VENV/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:$PATH"
if [[ -n "$CODEX_BIN" ]]; then
  CODEX_DIR="$(dirname "$CODEX_BIN")"
  if [[ -d "$CODEX_DIR" ]]; then
    export PATH="$CODEX_DIR:$PATH"
  fi
fi

health_ok() {
  curl -fsS "$STASH_BACKEND_URL/health" >/dev/null 2>&1
}

backend_started_by_launcher=0

if ! health_ok; then
  if [[ ! -x "$BACKEND_VENV/bin/python" ]]; then
    osascript -e 'display alert "Stash Local" message "Missing backend runtime. Reinstall with install_from_release.sh or install_desktop_app.sh." as critical'
    exit 1
  fi

  nohup env STASH_CODEX_MODE="$STASH_CODEX_MODE" STASH_CODEX_BIN="$CODEX_BIN" PATH="$PATH" \
    "$BACKEND_VENV/bin/python" -m uvicorn stash_backend.main:app --host 127.0.0.1 --port 8765 \
    >"$LOG_DIR/backend.log" 2>&1 &

  BACKEND_PID=$!
  echo "$BACKEND_PID" > "$BACKEND_PID_FILE"
  backend_started_by_launcher=1

  for _ in $(seq 1 120); do
    if health_ok; then
      break
    fi
    sleep 0.25
  done
fi

if ! health_ok; then
  osascript -e 'display alert "Stash Local" message "Backend failed to start. Check ~/Library/Logs/StashLocal/backend.log" as critical'
  exit 1
fi

if [[ ! -x "$OVERLAY_BIN" ]]; then
  osascript -e 'display alert "Stash Local" message "Overlay binary missing. Reinstall app." as critical'
  exit 1
fi

export STASH_BACKEND_URL
export STASH_CODEX_MODE
export STASH_CODEX_BIN="$CODEX_BIN"
"$OVERLAY_BIN" >>"$LOG_DIR/overlay.log" 2>&1 || true

if [[ "$backend_started_by_launcher" -eq 1 && -f "$BACKEND_PID_FILE" ]]; then
  pid="$(cat "$BACKEND_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$BACKEND_PID_FILE"
fi
EOF_LAUNCHER

chmod +x "$APP_MACOS/StashDesktopLauncher"

echo "Assembled app bundle: $OUT_APP"
