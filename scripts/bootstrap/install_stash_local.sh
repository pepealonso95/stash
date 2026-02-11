#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_INSTALLER="$ROOT_DIR/scripts/desktop/install_from_release.sh"

if [[ -f "$LOCAL_INSTALLER" ]]; then
  exec "$LOCAL_INSTALLER" "$@"
fi

REPO="${STASH_REPO:-pepealonso95/stash}"
REF="${STASH_BOOTSTRAP_REF:-main}"
INSTALLER_URL="https://raw.githubusercontent.com/${REPO}/${REF}/scripts/desktop/install_from_release.sh"

TMP_SCRIPT="$(mktemp /tmp/stash-install-from-release.XXXXXX.sh)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

curl -fsSL "$INSTALLER_URL" -o "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"
exec "$TMP_SCRIPT" "$@"
