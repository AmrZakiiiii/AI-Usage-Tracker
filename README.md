# AI Usage Tracker

A native macOS menu bar app built in Swift/SwiftUI that tracks real-time usage for multiple AI providers.

## Supported Providers

- **Codex** — Weekly usage with reset time
- **Claude** — Session (5h window) and weekly (7d) usage via Claude API + isclaude2x.com peak status
- **Antigravity** — Per-model quota tracking
- **Windsurf** — Prompt credits and add-on credits

## Building

Requires Swift 6.0+ and macOS 26 (Tahoe).

```bash
swift build
```

## Running

```bash
# Build, bundle, sign, and launch
swift build
mkdir -p dist/AIUsageTracker.app/Contents/MacOS
cp .build/debug/AIUsageTracker dist/AIUsageTracker.app/Contents/MacOS/
codesign --force --deep --sign - dist/AIUsageTracker.app
open dist/AIUsageTracker.app
```

The app runs as a menu bar item (no Dock icon).

## Architecture

- `Sources/Adapters/` — Provider-specific data fetching (Claude API, Codex server, local SQLite for Windsurf/Antigravity)
- `Sources/Core/` — Shared models and settings
- `Sources/Infrastructure/` — Keychain access, file watching, SQLite, networking
- `Sources/UI/` — SwiftUI views and menu bar controller
- `Sources/State/` — Provider state management
- `Sources/App/` — App entry point and lifecycle
