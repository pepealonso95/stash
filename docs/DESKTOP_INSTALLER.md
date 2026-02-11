# Desktop Installer (macOS)

Stash supports two installer paths:

1. **Release install (recommended for end users):** no local Swift build.
2. **Developer install (source build):** for contributors working in this repo.

## Requirements

- macOS 14+
- `python3` in `PATH`, version `>=3.11`

Developer/source install also requires:

- Xcode Command Line Tools (`xcode-select --install`)
- `swift` in `PATH`

## Fresh Machine Quickstart (Release Install)

Latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/pepealonso95/stash/main/scripts/bootstrap/install_stash_local.sh | bash
```

Pinned version:

```bash
curl -fsSL https://raw.githubusercontent.com/pepealonso95/stash/main/scripts/bootstrap/install_stash_local.sh | bash -s -- --version v0.3.0
```

The bootstrap wrapper executes `scripts/desktop/install_from_release.sh`, which:

1. Resolves latest release (or `--version` / `STASH_VERSION`)
2. Downloads required release assets
3. Verifies SHA256 checksums
4. Installs app bundle to `/Applications` (`~/Applications` fallback)
5. Provisions backend runtime venv and installs backend wheel + runtime dependencies

### Release Installer Interface

Command:

```bash
./scripts/desktop/install_from_release.sh [--version vX.Y.Z] [--install-dir <path>]
```

Environment overrides:

- `STASH_VERSION`
- `STASH_INSTALL_DIR`
- `STASH_BACKEND_URL`
- `STASH_RUNTIME_BASE`
- `STASH_CODEX_MODE`
- `STASH_CODEX_BIN` (optional)
- `STASH_REPO` (defaults to `pepealonso95/stash`)

## Release Artifacts Contract

Each release version `X.Y.Z` must include:

- `stash-local-macos-universal-X.Y.Z.tar.gz`
- `stash-backend-X.Y.Z-py3-none-any.whl`
- `stash-local-checksums-X.Y.Z.txt`
- `release-manifest-X.Y.Z.json`

Required `release-manifest` keys:

- `version`
- `app_asset`
- `backend_wheel_asset`
- `checksums_asset`
- `minimum_macos`
- `minimum_python`

Schema source:

- `docs/release-manifest.schema.json`

## Runtime Portability Contract

The installed app must not embed build-machine absolute paths.

Launcher defaults:

- `RUNTIME_BASE=${STASH_RUNTIME_BASE:-$HOME/Library/Application Support/StashLocal/runtime}`
- `BACKEND_VENV=$RUNTIME_BASE/.venv`
- `STASH_BACKEND_URL` defaults to `http://127.0.0.1:8765`
- `codex` binary resolved from `PATH` at runtime unless overridden

## Developer Install (Build From Source)

From repo root:

```bash
./scripts/desktop/install_desktop_app.sh
```

This script builds `StashMacOSApp` and `StashOverlay` locally, then assembles the app bundle.

Common overrides:

```bash
STASH_DESKTOP_TARGET_DIR="/Applications" \
STASH_DESKTOP_APP_NAME="Stash Local.app" \
STASH_BACKEND_URL="http://127.0.0.1:8765" \
STASH_CODEX_MODE="cli" \
./scripts/desktop/install_desktop_app.sh
```

## Logs

```text
~/Library/Logs/StashLocal/backend.log
~/Library/Logs/StashLocal/overlay.log
```

## Unsigned App (Gatekeeper)

For initial unsigned releases:

1. Right-click app and choose `Open`, or
2. Remove quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Stash Local.app"
```

## Release Process (Maintainers)

Workflow: `.github/workflows/release-macos.yml`

1. Merge to `main`.
2. Tag and push:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

3. Workflow builds universal app binaries + backend wheel, creates checksums + manifest, validates artifacts, and publishes GitHub Release.
4. Validate installer on clean Apple Silicon and Intel machines.

Rollback:

- Keep existing release immutable.
- Publish a new patch tag (for example `vX.Y.(Z+1)`) with fixes.

## Failure Cases

- Python < 3.11: installer exits with actionable version error.
- Corrupt download: checksum verification fails and install aborts.
- GitHub API/network issues: installer exits without changing existing app/runtime.
