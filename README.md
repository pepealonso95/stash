# Stash

Stash is **Codex Cowork**: a local-first AI coworker for safely doing work inside a chosen folder.
It is built for coding and non-coding workflows, so users can let AI handle tasks while keeping work scoped to the project directory.

Stash includes:

- A local backend service (`backend-service/`)
- A workspace app (`StashMacOSApp`)
- A floating overlay app (`StashOverlay`)

## Canonical Repository

This repository is now fully independent. The canonical remote is:

- `https://github.com/pepealonso95/stash`

No upstream auto-sync workflow is used.

## Install (Fresh macOS Machine, Recommended)

Requirements:

- macOS 14+
- `python3` in `PATH`, version `>=3.11`

One-step install from latest GitHub Release:

```bash
curl -fsSL https://raw.githubusercontent.com/pepealonso95/stash/main/scripts/bootstrap/install_stash_local.sh | bash
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/pepealonso95/stash/main/scripts/bootstrap/install_stash_local.sh | bash -s -- --version v0.3.0
```

The installer downloads release assets, verifies checksums, installs `Stash Local.app` to `/Applications` (or `~/Applications` fallback), and provisions backend runtime at:

```text
~/Library/Application Support/StashLocal/runtime/.venv
```

See `docs/DESKTOP_INSTALLER.md` for full options and troubleshooting.

## Developer Install (Build From Source)

Use this only when developing locally:

```bash
./scripts/desktop/install_desktop_app.sh
```

This path requires local Swift toolchain/Xcode Command Line Tools and builds binaries from source.

## Overlay Startup Mode + QuickChat Hotkeys

Overlay startup mode values:

- `visible`
- `hidden` (default)
- `disabled`

`hidden` and `disabled` both suppress overlay visibility at launch in this iteration.
QuickChat hotkeys remain active in all modes:

- `Ctrl+Space`: open QuickChat in latest project and start a new conversation
- `Ctrl+Shift+Space`: open QuickChat project picker and start a new conversation

Set mode from repo root:

```bash
./scripts/desktop/set_overlay_mode.sh hidden
./scripts/desktop/set_overlay_mode.sh visible
./scripts/desktop/set_overlay_mode.sh disabled
```

Restart `Stash Local.app` after changing mode.

## Maintainer Remote Guardrails

Before pushing, verify `origin` points to your fork and not the old upstream:

```bash
git remote -v
git remote get-url origin
```

If this clone still has `fork` as your GitHub repo and `origin` as old upstream, normalize it:

```bash
git remote rename origin upstream-old
git remote rename fork origin
git remote remove upstream-old
```

Guardrail: never push to the old upstream. Push and release from `pepealonso95/stash` only.

## Release Process (Maintainers)

1. Land changes on `main`.
2. Create and push a tag (example):

```bash
git tag v0.3.0
git push origin v0.3.0
```

3. GitHub Actions workflow `.github/workflows/release-macos.yml` builds and publishes:
   - `stash-local-macos-universal-<version>.tar.gz`
   - `stash-backend-<version>-py3-none-any.whl`
   - `stash-local-checksums-<version>.txt`
   - `release-manifest-<version>.json`
4. Validate install on clean Apple Silicon + Intel machines.

Rollback policy:

- Do not replace existing tag assets in place.
- Publish a new patch tag (for example `v0.3.1`) with fixes.

## Troubleshooting

- Unsigned app blocked by Gatekeeper:
  - Right-click `Stash Local.app` and choose `Open`, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Stash Local.app"
```

- Installer fails with Python requirement:
  - Verify `python3 --version` is `3.11+`.

- Runs do not execute through Codex:
  - Verify CLI auth: `codex login status`.

## Additional Docs

- `backend-service/README.md`
- `frontend-macos/README.md`
- `docs/FRONTEND_BACKEND_RUN.md`
- `docs/DESKTOP_INSTALLER.md`
- `docs/release-manifest.schema.json`

## License
Copyright 2026 Kamal Kamalaldin, Mert Gulsan, Pepe Alonso

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
