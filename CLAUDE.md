# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS app (Swift/SwiftUI) for controlling **Xsens Movella DOT** motion sensors via Bluetooth. Manages device discovery, connection, multi-device synchronization, recording, and flash storage operations.

## Build Commands

```bash
# Open in Xcode
open Brooks-Movella-App.xcodeproj

# Build from command line
xcodebuild -scheme "Brooks-Movella-App" -configuration Debug

# Build for a specific simulator
xcodebuild -scheme "Brooks-Movella-App" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15'
```

There is one target (`Brooks-Movella-App`), one scheme (`Brooks-Movella-App`), and two build configurations (Debug/Release). No package manager is used — the only third-party dependency is the `MovellaDotSdk.framework` binary embedded directly in the project.

Note: Bluetooth functionality requires a physical iOS device; simulator testing is limited.

## Architecture

**Pattern:** Singleton Manager + ObservableObject models + SwiftUI views (MVVM-like)

```
ContentView (TabView: Connect | Sync | Export)
    ├── ConnectionView  ──→ DotManager.shared ──→ MovellaDotSdk
    ├── SyncView         ──→ DotManager.shared ──→ [Dot] models
    └── ExportView       (placeholder)
```

### Key Components

- **`DotManager`** (`Managers/DotManager.swift`) — Singleton that owns all app state. Handles Bluetooth scanning, connection queuing, sync coordination, recording control, and flash operations. All SDK calls go through `sdkQueue` (serial); state mutations through `stateQueue` (serial); UI updates dispatched to main thread.

- **`Dot`** (`Models/Dot.swift`) — ObservableObject wrapping a native `DotDevice`. Publishes connection, recording, and flash storage state for SwiftUI binding. Manages per-device operations (configure, record, erase flash). Uses a gatekeeper flag to handle the SDK's double-firing callback bug.

- **`ContentView`** — TabView routing to the three feature views.
- **`ConnectionView`** — Device scanning/connection UI with retry timer.
- **`SyncView`** — Multi-device sync, recording controls, flash storage display with status tags and color-coded bars.
- **`ExportView`** — Stub for future data export.

### Threading Model

Three execution contexts must be respected:
1. **`stateQueue`** (serial) — protects `DotManager` internal state (`byUuid`, `connectQueue`, flags)
2. **`sdkQueue`** (serial) — serializes all `MovellaDotSdk` API calls
3. **Main thread** — all `@Published` property updates and UI work

### SDK Quirks

- The Movella SDK fires some completion callbacks **twice**. The `Dot` model uses a gatekeeper flag (`_flashInfoDone`) to capture only the first result.
- Recording state requires polling via `getRecordingStatus()` rather than push notifications.
- `DotConnectionDelegate` is the primary callback interface from the SDK.

### Cross-Module Communication

Uses `NotificationCenter` for pub/sub between manager and views. Custom notification names are defined in `Utilities/Notifications.swift`.

## No Test Suite

There are currently no unit or integration tests in this project.
