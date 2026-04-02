# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS app (Swift/SwiftUI) for controlling **Xsens Movella DOT** motion sensors via Bluetooth. Manages device discovery, connection, multi-device synchronization, recording, flash storage, and data export to CSV.

## Build Commands

```bash
# Open in Xcode
open Brooks-Movella-App.xcodeproj

# Build from command line
xcodebuild -scheme "Brooks-Movella-App" -configuration Debug

# Build for a specific simulator
xcodebuild -scheme "Brooks-Movella-App" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15'
```

One target (`Brooks-Movella-App`), one scheme, two build configurations (Debug/Release). No package manager — the only third-party dependency is `MovellaDotSdk.framework` embedded directly in the project.

Bluetooth functionality requires a physical iOS device; simulator testing is limited.

## Architecture

**Pattern:** Singleton Manager + ObservableObject models + SwiftUI views (MVVM-like)

```
ContentView (TabView: Connect | Sync | Export)
    ├── ConnectionView  ──→ DotManager.shared ──→ MovellaDotSdk
    ├── SyncView        ──→ DotManager.shared ──→ [Dot] models
    └── ExportView      ──→ ExportManager.shared ──→ [Dot] models
```

### DotManager (`Managers/DotManager.swift`)

Singleton owning all Bluetooth and session state. Delegates to three sub-components, all accessed through the queues below:

- **`DotRegistry`** — non-thread-safe state container (`byUuid`, `connectQueue`, flags). Access only on `stateQueue`.
- **`DotScanner`** — triggers Bluetooth scans on `sdkQueue`.
- **`DotOperationRunner`** — runs sequential bulk operations (record start/stop, erase, flash refresh) on `sdkQueue`.

**Threading contract (must be respected everywhere):**
1. **`stateQueue`** (serial) — protects `DotRegistry` reads/writes and `DotManager` internal flags.
2. **`sdkQueue`** (serial) — serializes every call into `MovellaDotSdk`. `ExportManager` shares this queue.
3. **Main thread** — all `@Published` property writes for SwiftUI binding.

`notify()` snapshots registry state on `stateQueue` and pushes it to `@Published` properties on the main thread. It's the single mechanism for updating the UI.

### Dot (`Models/Dot.swift`)

`ObservableObject` wrapping a `DotDevice`. Publishes `connectionPhase`, `isRecording`, `sessionSynced`, flash storage bytes, and recording file list. All `@Published` mutations go through `setOnMain(_:)`.

`isRecording` is `@Published private(set)` — only writable via `syncRecordingState()`, which reads the live SDK property `device.recording.recordingStatus` and pushes to `@Published` on main. All recording state updates (SDK callbacks, polling success, idle-sensor skip paths) go through this one method. Never set `isRecording` directly.

Key details:
- `device` reference can change after reconnect — `updateDevice(_:)` re-installs the recording callback.
- `getFlashInfo` and `getExportFileInfo` both use a single-flight gatekeeper (`inFlight` flag + waiter queue) to guard against the SDK's double-firing callbacks.
- Recording start/stop polls `getRecordingStatus()` every 0.3s up to a 5s timeout because SDK push events aren't reliable.

### ExportManager (`Managers/ExportManager.swift`)

Singleton managing the full export lifecycle. Uses a **single-phase streaming pipeline** per file: BLE packets are formatted into CSV rows and written directly to disk as they arrive. Foreground-only; cancels with a 3-second cleanup grace period if the app backgrounds.

> Note: An earlier two-phase design (BLE → `.bin` via `BinaryStreamWriter`, then `.bin` → `.csv` via `BinaryToCsvConverter`) was replaced. Those files no longer exist.

**Threading:**
- SDK calls + data callback processing → `DotManager.shared.sdkQueue`
- File I/O → `fileQueue` (serial, `ExportManager`-private)
- Device sequencing → `exportSequenceQueue` (serial, keeps `fileQueue` free for write callbacks)

**Export flow:** `fetchRecordings()` → select files → `buildCart()` → `startExport()` → share sheet. `retryFailed()` inspects disk state: if `.csv` exists → done; else full pipeline (no partial binary to resume from).

**SDK call sequence per file:**
1. `device.stopExportFileData()` — reset any prior state
2. `device.exportDataFormat = Data(...)` — set fields: timestamp, Euler angles, acceleration, angular velocity
3. `device.recording.exportFileList = [fileIndex]` — single-file array
4. Install `setDidParseExportFileDataBlock` — fires for every BLE packet; formats CSV row, batches to `fileQueue` every 200 packets
5. Install `device.recording.exportFileDone` — fires at end; flushes final batch, closes file handle, marks task complete
6. `device.startExportFileData()` — begins BLE transfer

**Progress estimation:** SDK provides no total packet count. Estimated from file size using empirical ratio (~88 bytes/packet on-device). Progress is capped at 0.99 until `exportFileDone` fires.

**Watchdog:** A per-file `ExportWatchdog` timer runs on `sdkQueue`. If no packets arrive for 10 seconds, it cancels the transfer, deletes the partial CSV, and marks the task failed.

**Generation IDs:** `exportFileGeneration` is incremented before each export. Callbacks check their captured generation against the current value to discard stale calls from prior attempts.

CSV columns: `packet_counter,timestamp,euler_x,euler_y,euler_z,acc_x,acc_y,acc_z,gyr_x,gyr_y,gyr_z`

Exported files are saved to `Documents/Exports/`.

### State Machines

**`SessionPhase`** (session-level, lives on `DotManager`):
```
idle → syncing → startingRecording → recording → stoppingRecording → idle
         └──────────────────────────────────────────────────────→ error(…)
```
`isSyncActive` suppresses spurious connect/disconnect events the SDK fires during clock sync.

**`ConnectionPhase`** (per-device, lives on `DotRegistry`/`Dot`):
```
idle → connecting → initializing → ready
           └──────────────────────→ failed(…)
```
`initializing` means connected but flash info fetch is in progress. `ready` means fully usable.

**`ExportPhase`**: `idle → fetching → ready → exporting → done`

### SDK Quirks

- Several SDK completion callbacks fire **twice**. Guard with a boolean `hasCapturedResult` (local variable captured in the callback closure) — set it to `true` on first call and return early thereafter.
- `DotSyncManager.startSync()` internally disconnects and reconnects each device. `onDeviceDisconnected`/`onDeviceConnectSucceeded` suppress normal handling when `sessionPhase.isSyncActive` is true. Device references for syncing UUIDs are frozen in `DotRegistry` during sync.
- Connection attempts have a 10-second timeout managed by `DispatchWorkItem` timers on the main thread.
- `DotDevicePool.bindDevice()` must be called on `sdkQueue` after every connect/reconnect.
- `device.exportDataFormat` and `device.recording.exportFileList` must be set before calling `startExportFileData()`.
- `exportFileDone` can fire twice; guard with `exportCompleted` boolean and bump `exportFileGeneration` immediately on first call.
- `setDidParseExportFileDataBlock` callback fires on `sdkQueue`; do not dispatch back to `sdkQueue` from inside it (deadlock). Dispatch file writes to `fileQueue` instead.

## No Test Suite

There are currently no unit or integration tests in this project.
