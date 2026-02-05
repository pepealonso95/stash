# Stash macOS Frontend

Codex-style light-mode desktop UI for Stash.

## What is implemented

- Three-panel desktop app layout similar to Codex app UX
- Folder-backed project workflow
- File browser for current project root
- Conversation list and message timeline
- Composer to send work requests to backend
- Run polling and status display
- Context search over indexed content

## Backend integration

The app expects the backend service at:

- `http://127.0.0.1:8765` by default

You can override with environment variable before launch:

```bash
STASH_BACKEND_URL=http://127.0.0.1:8765
```

## Build and run

From repo root:

```bash
./scripts/install_stack.sh
./scripts/run_backend.sh
```

In another terminal:

```bash
cd frontend-macos
swift build
swift run
```

Or open in Xcode:

```bash
open frontend-macos/Package.swift
```

## Main files

- `Sources/StashMacOSApp/StashMacOSApp.swift`
- `Sources/StashMacOSApp/RootView.swift`
- `Sources/StashMacOSApp/AppViewModel.swift`
- `Sources/StashMacOSApp/BackendClient.swift`
