#!/usr/bin/env bash
set -euo pipefail

REPO="${STASH_REPO:-pepealonso95/stash}"
INSTALL_DIR_OVERRIDE="${STASH_INSTALL_DIR:-}"
VERSION_INPUT="${STASH_VERSION:-}"
BACKEND_URL="${STASH_BACKEND_URL:-http://127.0.0.1:8765}"
RUNTIME_BASE="${STASH_RUNTIME_BASE:-$HOME/Library/Application Support/StashLocal/runtime}"
CODEX_MODE="${STASH_CODEX_MODE:-cli}"

MIN_MACOS_MAJOR=14
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=11

usage() {
  cat <<'USAGE'
Install Stash Local from GitHub Releases (no local Swift build required).

Usage:
  ./scripts/desktop/install_from_release.sh [--version vX.Y.Z] [--install-dir <path>]

Options:
  --version <vX.Y.Z>   Install a specific release tag (or X.Y.Z).
  --install-dir <path> Install app bundle into this directory.
  -h, --help           Show this help.

Environment:
  STASH_VERSION         Same as --version
  STASH_INSTALL_DIR     Same as --install-dir
  STASH_BACKEND_URL     Launcher backend URL (default: http://127.0.0.1:8765)
  STASH_RUNTIME_BASE    Runtime folder (default: ~/Library/Application Support/StashLocal/runtime)
  STASH_CODEX_MODE      Launcher codex mode (default: cli)
  STASH_CODEX_BIN       Optional codex binary override persisted to launcher.conf
  STASH_REPO            GitHub repo slug (default: pepealonso95/stash)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION_INPUT="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR_OVERRIDE="$2"
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

log() {
  printf '[stash-release-install] %s\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

normalize_tag() {
  local raw="$1"
  if [[ "$raw" == v* ]]; then
    printf '%s' "$raw"
  else
    printf 'v%s' "$raw"
  fi
}

resolve_version_and_tag() {
  local input="$1"
  if [[ -n "$input" ]]; then
    TAG="$(normalize_tag "$input")"
    VERSION="${TAG#v}"
    return
  fi

  local latest
  latest="$(python3 - "$REPO" <<'PY'
import json
import sys
import urllib.request

repo = sys.argv[1]
url = f"https://api.github.com/repos/{repo}/releases/latest"
req = urllib.request.Request(url, headers={"User-Agent": "stash-installer"})
try:
    with urllib.request.urlopen(req) as response:
        payload = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    print(f"Failed to query latest release: {exc}", file=sys.stderr)
    sys.exit(1)

tag = payload.get("tag_name")
if not tag:
    print("Latest release is missing tag_name", file=sys.stderr)
    sys.exit(1)
print(tag)
PY
)"
  TAG="$(normalize_tag "$latest")"
  VERSION="${TAG#v}"
}

check_platform_requirements() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This installer only supports macOS." >&2
    exit 1
  fi

  local os_version os_major
  os_version="$(sw_vers -productVersion)"
  os_major="${os_version%%.*}"
  if (( os_major < MIN_MACOS_MAJOR )); then
    echo "macOS ${MIN_MACOS_MAJOR}+ is required (found ${os_version})." >&2
    exit 1
  fi

  require_cmd python3
  if ! python3 - "$MIN_PYTHON_MAJOR" "$MIN_PYTHON_MINOR" <<'PY'
import sys
maj = int(sys.argv[1])
min_ = int(sys.argv[2])
if sys.version_info < (maj, min_):
    raise SystemExit(1)
PY
  then
    echo "python3 >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} is required." >&2
    exit 1
  fi
}

resolve_install_dir() {
  if [[ -n "$INSTALL_DIR_OVERRIDE" ]]; then
    INSTALL_DIR="$INSTALL_DIR_OVERRIDE"
    mkdir -p "$INSTALL_DIR"
    return
  fi

  if mkdir -p "/Applications" 2>/dev/null && [[ -w "/Applications" ]]; then
    INSTALL_DIR="/Applications"
    return
  fi

  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
}

fetch_release_assets() {
  local app_asset="$1"
  local wheel_asset="$2"
  local checksums_asset="$3"
  local manifest_asset="$4"

  python3 - "$REPO" "$TAG" "$app_asset" "$wheel_asset" "$checksums_asset" "$manifest_asset" <<'PY' > "$TMP_DIR/assets.tsv"
import json
import sys
import urllib.request

repo, tag = sys.argv[1], sys.argv[2]
required = sys.argv[3:]
url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
req = urllib.request.Request(url, headers={"User-Agent": "stash-installer"})
try:
    with urllib.request.urlopen(req) as response:
        payload = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    print(f"Failed to fetch release metadata for {tag}: {exc}", file=sys.stderr)
    sys.exit(1)

assets = {asset.get("name"): asset.get("browser_download_url") for asset in payload.get("assets", [])}
missing = [name for name in required if name not in assets or not assets[name]]
if missing:
    print("Missing release assets: " + ", ".join(missing), file=sys.stderr)
    sys.exit(2)

for name in required:
    print(f"{name}\t{assets[name]}")
PY

  while IFS=$'\t' read -r asset_name asset_url; do
    log "Downloading ${asset_name}"
    curl -fsSL --retry 3 --retry-delay 1 -o "$TMP_DIR/$asset_name" "$asset_url"
  done < "$TMP_DIR/assets.tsv"
}

validate_manifest() {
  local manifest_path="$1"
  local app_asset="$2"
  local wheel_asset="$3"
  local checksums_asset="$4"

  python3 - "$manifest_path" "$VERSION" "$app_asset" "$wheel_asset" "$checksums_asset" <<'PY'
import json
import sys

manifest_path, version, app_asset, wheel_asset, checksums_asset = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

required_keys = [
    "version",
    "app_asset",
    "backend_wheel_asset",
    "checksums_asset",
    "minimum_macos",
    "minimum_python",
]
missing = [key for key in required_keys if key not in payload]
if missing:
    raise SystemExit(f"Manifest missing keys: {', '.join(missing)}")

if payload["version"] != version:
    raise SystemExit(f"Manifest version mismatch: expected {version}, got {payload['version']}")
if payload["app_asset"] != app_asset:
    raise SystemExit("Manifest app_asset does not match expected filename")
if payload["backend_wheel_asset"] != wheel_asset:
    raise SystemExit("Manifest backend_wheel_asset does not match expected filename")
if payload["checksums_asset"] != checksums_asset:
    raise SystemExit("Manifest checksums_asset does not match expected filename")
PY
}

install_runtime() {
  local wheel_path="$1"
  local backend_venv="$2"

  mkdir -p "$RUNTIME_BASE"
  python3 -m venv "$backend_venv"
  # shellcheck disable=SC1091
  source "$backend_venv/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install "$wheel_path"
  python -m pip install "uv>=0.4.30" "pypdf>=4.2.0"
  python - <<'PY'
import stash_backend
print("stash_backend import OK")
PY
  deactivate >/dev/null 2>&1 || true
}

write_launcher_config() {
  local app_path="$1"
  local conf_path="$app_path/Contents/Resources/launcher.conf"

  cat > "$conf_path" <<EOF_CONF
STASH_BACKEND_URL="$BACKEND_URL"
STASH_CODEX_MODE="$CODEX_MODE"
STASH_RUNTIME_BASE="$RUNTIME_BASE"
EOF_CONF

  if [[ -n "${STASH_CODEX_BIN:-}" ]]; then
    printf 'STASH_CODEX_BIN="%s"\n' "$STASH_CODEX_BIN" >> "$conf_path"
  fi
}

require_cmd curl
require_cmd shasum
require_cmd tar

check_platform_requirements
resolve_version_and_tag "$VERSION_INPUT"

APP_ASSET="stash-local-macos-universal-${VERSION}.tar.gz"
WHEEL_ASSET="stash-backend-${VERSION}-py3-none-any.whl"
CHECKSUMS_ASSET="stash-local-checksums-${VERSION}.txt"
MANIFEST_ASSET="release-manifest-${VERSION}.json"

TMP_DIR="$(mktemp -d /tmp/stash-release-install.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Installing from ${REPO} release ${TAG}"
fetch_release_assets "$APP_ASSET" "$WHEEL_ASSET" "$CHECKSUMS_ASSET" "$MANIFEST_ASSET"
validate_manifest "$TMP_DIR/$MANIFEST_ASSET" "$APP_ASSET" "$WHEEL_ASSET" "$CHECKSUMS_ASSET"

log "Verifying SHA256 checksums"
(
  cd "$TMP_DIR"
  shasum -a 256 -c "$CHECKSUMS_ASSET"
)

resolve_install_dir
APP_NAME="Stash Local.app"
TARGET_APP="$INSTALL_DIR/$APP_NAME"

log "Installing app bundle to $TARGET_APP"
tar -xzf "$TMP_DIR/$APP_ASSET" -C "$TMP_DIR"
EXTRACTED_APP="$(find "$TMP_DIR" -maxdepth 2 -type d -name "$APP_NAME" | head -n 1 || true)"
if [[ -z "$EXTRACTED_APP" ]]; then
  echo "Could not locate extracted app bundle in archive." >&2
  exit 1
fi

rm -rf "$TARGET_APP"
cp -R "$EXTRACTED_APP" "$TARGET_APP"
write_launcher_config "$TARGET_APP"

BACKEND_VENV="$RUNTIME_BASE/.venv"
log "Provisioning backend runtime at $BACKEND_VENV"
install_runtime "$TMP_DIR/$WHEEL_ASSET" "$BACKEND_VENV"

log "Install complete"
log "- App: $TARGET_APP"
log "- Runtime: $BACKEND_VENV"
log "- Launch: open \"$TARGET_APP\""
log "- Logs: ~/Library/Logs/StashLocal/backend.log and ~/Library/Logs/StashLocal/overlay.log"

if [[ "$INSTALL_DIR" == "$HOME/Applications" ]]; then
  log "Note: Installed to ~/Applications because /Applications was not writable."
fi
