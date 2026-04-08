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
ContentView (TabView: Connect | Record | Export | Profiles)
    ├── ConnectionView              ──→ DotManager.shared ──→ MovellaDotSdk
    ├── SyncView (solo runner)      ──→ DotManager.shared ──→ [Dot] models
    │   └── or ResearcherModeRecordView (multi-runner)
    ├── ExportView                  ──→ ExportManager.shared ──→ [Dot] models
    └── ProfilesView               ──→ RunnerStore.shared
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

**Per-runner session control:**
Session phases are tracked per-runner in `runnerPhasesInternal` (source of truth on `stateQueue`), mirrored to `@Published runnerPhases: [String: SessionPhase]`.

```swift
// Multi-runner API
func beginSession(runnerId: String)       // Start recording for a runner's sensors
func endSession(runnerId: String)         // Stop recording for a runner's sensors
func resyncRunner(runnerId: String)       // Re-sync clocks for a runner's sensors
func dismissError(runnerId: String)       // Clear error → idle

// Single-runner convenience (uses ephemeral "__single__" runner)
func beginSession()                       // Creates ephemeral runner from all ready sensors → starts
func endSession()                         // Stops ephemeral runner
func syncSession()                        // Creates ephemeral runner → syncs
func dismissError()                       // Clears ephemeral error
```

Key published state:
- `@Published runnerPhases: [String: SessionPhase]` — per-runner phase map
- `@Published resyncingRunners: Set<String>` — runner IDs currently mid-resync
- `sessionPhase: SessionPhase` — aggregate computed property for views needing a single state
- `isAnySyncing: Bool` — true if any runner is syncing or resync is active

### Dot (`Models/Dot.swift`)

`ObservableObject` wrapping a `DotDevice`. Publishes `connectionPhase`, `isRecording`, `sessionSynced`, flash storage bytes, and recording file list. All `@Published` mutations go through `setOnMain(_:)`.

`isRecording` is `@Published private(set)` — only writable via `syncRecordingState()`, which reads the live SDK property `device.recording.recordingStatus` and pushes to `@Published` on main. All recording state updates (SDK callbacks, polling success, idle-sensor skip paths) go through this one method. Never set `isRecording` directly.

`sessionSynced` is `@Published private(set)` — only writable via `refreshSyncStatus()`, which reads the live SDK property `device.isSynced()` on `sdkQueue` and pushes to `@Published` on main. Called after sync completes, after `stopSync`, after reconnect initialization, and from `updateDevice(_:)` (guarded to skip during active sync windows). Never set `sessionSynced` directly.

Key details:
- `device` reference can change after reconnect — `updateDevice(_:)` re-installs the recording callback and refreshes sync status (unless in an active sync window).
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

### RunnerStore & Runner Model

**`Runner`** (struct, `Identifiable`, `Codable`):
```swift
struct Runner: Identifiable, Codable {
    let id: String              // UUID string (or "__single__" for ephemeral)
    var label: String           // User-editable name
    var sensorUuids: [String]   // Sensor UUIDs assigned to this runner
}
```

**`RunnerStore`** (`Managers/RunnerStore.swift`) — singleton `ObservableObject` managing runner persistence.
- `@Published runners: [Runner]` — all runners
- `@Published isMultiRunnerMode: Bool` — persisted to `UserDefaults`; toggles solo vs researcher UI
- Persists to JSON file in Application Support directory
- Thread-safe reads via internal snapshot: `runner(forId:)`, `runner(forSensorUuid:)`
- Sensor uniqueness enforced: `assignSensor(uuid:to:)` removes the UUID from all other runners first

### Two Modes: Solo Runner vs Researcher (Multi-Runner)

**Solo runner mode** (`SyncView`):
- All connected sensors treated as one group
- Uses an ephemeral runner with ID `DotManager.singleRunnerID = "__single__"`
- Convenience methods on `DotManager` auto-manage this runner
- Flow: Sync all sensors → Start recording → Stop recording

**Researcher mode** (`ResearcherModeRecordView`):
- Multiple named runners, each with up to 3 assigned sensors
- Drag-and-drop sensor assignment from `AvailableDots` pool to `RunnerCard` drop slots
- Each runner syncs and records independently
- Excludes the ephemeral `singleRunnerID` from the UI

Toggled by `RunnerStore.isMultiRunnerMode`.

### Two-Step Sync → Record Flow

Recording requires a strict two-step process when 2+ sensors are assigned to a runner:

**Step 1 — Sync:** `resyncRunner(runnerId:)` or `syncSession()`
- Precondition: runner idle, 2+ sensors at `.ready`
- Sets runner phase → `.syncing`
- Calls `DotSyncManager.startSync()` (SDK internally disconnects/reconnects each sensor)
- Connect/disconnect events suppressed via `registry.syncingUuids` and `syncInProgress` flag
- On completion: refreshes storage info, runner phase → `.idle`

**Step 2 — Record:** `beginSession(runnerId:)` or `beginSession()`
- Precondition: runner idle, all sensors `.ready`, 2+ sensors must report `device.isSynced()`
- Sets runner phase → `.startingRecording` → issues `startRecording()` per sensor → `.recording`
- Stop via `endSession()` → `.stoppingRecording` → `.idle`

With only 1 sensor assigned, recording starts directly (no sync needed).

### State Machines

**`SessionPhase`** (per-runner, lives in `DotManager.runnerPhases`):
```
idle → syncing → startingRecording → recording → stoppingRecording → idle
         └──────────────────────────────────────────────────────→ error(…)
```
`isSyncActive` suppresses spurious connect/disconnect events the SDK fires during clock sync. Each runner has an independent phase; the aggregate `sessionPhase` computed property reduces all runner phases for views that need a single state.

**`ConnectionPhase`** (per-device, lives on `DotRegistry`/`Dot`):
```
idle → connecting → initializing → ready
           └──────────────────────→ failed(…)
```
`initializing` means connected but flash info fetch is in progress. `ready` means fully usable.

**`ExportPhase`**: `idle → fetching → ready → exporting → done`

### UI Components (Researcher Mode)

**`RunnerCard`** — per-runner card displaying header, sensor slots, and action button.
- Header: status circle with runner initial, editable name, sync status icon, resync button, delete button
- Dots row: up to 3 `DotChip` views + `EmptyDotSlot` drop targets (equal-width, flexible layout)
- Action button: dynamic label/color/icon based on runner phase (sync → start → stop → retry)
- Resync and trash buttons gray out during sync

**`AvailableDots`** — horizontal scrollable row of unassigned sensors. Each `DotChip` is fixed-width (100pt) and draggable. The entire row is a drop target for unassigning sensors from runners.

**`DotChip`** — sensor display tile showing display name, storage bar (%), and connection indicator. Supports drag-and-drop, double-tap to identify, and optional unassign button.

**`EmptyDotSlot`** — dashed-border drop target in `RunnerCard`. Highlights blue when a sensor is dragged over it. Does not animate when sensors are added/removed (uses `.animation(.none)`).

### SDK Quirks

- Several SDK completion callbacks fire **twice**. Guard with a boolean `hasCapturedResult` (local variable captured in the callback closure) — set it to `true` on first call and return early thereafter.
- `DotSyncManager.startSync()` internally disconnects and reconnects each device. `onDeviceDisconnected`/`onDeviceConnectSucceeded` suppress normal handling when any runner's phase `isSyncActive` is true. Device references for syncing UUIDs are frozen in `DotRegistry.syncingUuids` during sync; `DotRegistry.syncInProgress` gates overall sync state.
- Connection attempts have a 10-second timeout managed by `DispatchWorkItem` timers on the main thread.
- `DotDevicePool.bindDevice()` must be called on `sdkQueue` after every connect/reconnect.
- `device.exportDataFormat` and `device.recording.exportFileList` must be set before calling `startExportFileData()`.
- `exportFileDone` can fire twice; guard with `exportCompleted` boolean and bump `exportFileGeneration` immediately on first call.
- `setDidParseExportFileDataBlock` callback fires on `sdkQueue`; do not dispatch back to `sdkQueue` from inside it (deadlock). Dispatch file writes to `fileQueue` instead.

## No Test Suite

There are currently no unit or integration tests in this project.
