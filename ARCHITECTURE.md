# Brooks Movella App — Architecture & Design Decisions

## Overview
iOS app for capturing motion data from Movella DOT wearable sensors. Connects sensors via Bluetooth, records synchronized motion data, exports CSV files, and uploads to Supabase.

## Sensor Basics (Movella DOT)
- Each DOT has a 3D accelerometer, gyroscope, and magnetometer
- Communicates via Bluetooth Low Energy (BLE) 5.0
- Has 64MB internal storage, records up to 6 hours at 60Hz
- Supports output rates from 1Hz to 120Hz (120Hz recording only)
- Internal sampling rate is 800Hz, downsampled via Strapdown Integration (SDI)
- Sensor fusion algorithm (XKFCore) runs on-device, outputs drift-free 3D orientation
- Each sensor has its own clock domain — synchronization is required for multi-sensor setups

## Synchronization
- Sync aligns sensor clocks to a common time base via BLE advertisement messages
- One sensor is the root node, others are scanners
- Sync takes ~15 seconds and the SDK disconnects/reconnects sensors during the process
- Sync accuracy: 1 ppm after 30 min, 4 ppm after 1 hour
- After sync, multiple recordings can be started/stopped without re-syncing
- Sync is purely clock alignment — sensors do NOT need to be on a flat surface. Movella recommends syncing on a table for body-mounted scenarios because BLE proximity (<50cm) improves sync success rate during the disconnect/reconnect phase — not because the algorithm requires a flat surface.
- Best practice: keep sensors and phone within 50cm during sync, don't stack sensors
- The SDK cannot handle two concurrent startSync calls. If Runner A is syncing, Runner B must wait.
- Sync persists on the sensor until powered off, factory reset, or stopSync is called

## Threading Model (DotManager)
- stateQueue (serial) — protects DotRegistry mutations and internal flags. All state reads/writes happen here.
- sdkQueue (serial) — serializes all Movella SDK API calls. SDK is not thread-safe.
- Main thread — all @Published property writes for SwiftUI
- Pattern: SDK callback fires on arbitrary thread → hop to stateQueue for state mutation → snapshot to main for UI
- Never synchronously dispatch from stateQueue to sdkQueue or vice versa — deadlock risk

## Connection Lifecycle
- Phases: idle → connecting → initializing → ready
- After BLE connect succeeds, the sensor needs initialization (getFlashInfo for storage info)
- getFlashInfo will NOT respond if the sensor is currently recording — this times out and causes "initialization failed"
- Fix: before calling refreshStorage/getFlashInfo, query recording status with checkRecordingStatus(completion:) which waits for the actual SDK callback. If recording, skip flash query and go straight to .ready
- refreshRecordingStatus() is async with two queue hops (sdkQueue → SDK callback → main) — checking isRecording immediately after calling it will see stale data. Always use the callback-based checkRecordingStatus instead.
- The SDK fires disconnect/reconnect events during sync — suppress these when syncingUuids contains the device UUID, not based on a global sync flag. This prevents Runner B's sensors from being suppressed during Runner A's sync.

## Recording
- Recording stores data on-sensor internal flash, not streamed over BLE
- Recording starts/stops via SDK commands
- 0xFFFF = record indefinitely until explicitly stopped
- Sensor continues recording even if BLE disconnects or app is killed
- On reconnect, device.isRecording() from the SDK is the source of truth for recording state
- No recovery persistence file needed — isRecording + RunnerStore runner assignments restore everything

## Per-Runner Session Management
- A Runner is a named group of sensor UUIDs (typically 3 dots per runner)
- Each runner has its own independent SessionPhase: idle → syncing → startingRecording → recording → stoppingRecording → idle
- Multiple runners can record concurrently
- Runners cannot sync concurrently (SDK limitation) — UI disables start buttons on other runners while one is syncing
- RunnerStore persists runner assignments to runners.json
- DotManager.runnerPhases is in-memory only, rebuilt from isRecording + RunnerStore on reconnect
- A computed aggregate sessionPhase provides backward compatibility for views that don't need per-runner granularity

## Two UI Modes
- Single runner mode (default): all connected dots record as one unit. A temporary runner with id "__single__" is created on recording start and deleted on stop.
- Multi-runner mode: user assigns dots to named runners. Runners persist across start/stop cycles. Mode toggle locked when sensors are connected.
- The mode is purely a UI concern backed by UserDefaults "multi_runner_mode". DotManager doesn't know about modes — it just operates on runner IDs.

## Sensor Naming
- SensorNameStore maps sensor UUID to user-defined label via UserDefaults "dot_names"
- Purely visual — all logic uses UUID, display layer substitutes names
- Falls back to showing UUID if no name is set
- Editable inline on the ConnectionView

## Export
- Files exported from sensor internal storage via BLE
- Only query sensors in .ready connection phase — querying during .initializing causes SDK timeouts
- Keep sensors within arm's length during export for BLE reliability
- Each sensor needs both calibration file (small) and run file (large) exported
- Packet loss or upload failure prompts retry

## Persistence Summary
- runners.json — runner assignments (id, label, sensorUuids). Source of truth for which sensors belong to which runner.
- UserDefaults "multi_runner_mode" — UI mode toggle
- UserDefaults "dot_names" — sensor UUID to display name mapping
- No session recovery file — SDK isRecording + runners.json restores state on reconnect

## Key Lessons
- The Movella SDK is not thread-safe. All SDK calls must go through a single serial queue.
- SDK callbacks fire on arbitrary threads. Always hop to your own serial queue before mutating state.
- During sync, the SDK disconnects and reconnects sensors internally. Your delegate callbacks must detect this and suppress connection state changes for syncing sensors.
- getFlashInfo does not respond while a sensor is recording. Always check recording status before querying flash.
- refreshRecordingStatus() is async — never check isRecording synchronously after calling it.
- SampleTimeFine is a relative microsecond clock that resets on sensor reboot. It has no relationship to UTC.
- iOS Bluetooth UUIDs are phone-specific and can theoretically change, but are stable enough for single-phone workflows.
- The sensor's MAC address (D4:22:CD:xx:xx:xx) is the only truly permanent identifier across devices.

---

## Deep Dive: Queue Architecture

DotManager declares two serial queues (`DotManager.swift`):

```
stateQueue = DispatchQueue(label: "DotManager.stateQueue")
sdkQueue   = DispatchQueue(label: "DotManager.sdkQueue", qos: .userInitiated)
```

Every code path in the app follows one of these patterns:

### Pattern 1: SDK Delegate Callback → State Mutation → UI Update

SDK delegate methods (`onDeviceConnectSucceeded`, `onDeviceDisconnected`, `onScanCompleted`, etc.) fire on arbitrary threads. The first line of every delegate method dispatches to `stateQueue`:

```swift
func onDeviceConnectSucceeded(_ device: DotDevice) {
    stateQueue.async { [self] in
        // All state mutation happens here:
        // - registry.recordConnection(device)
        // - registry.setConnectionPhase(uuid, .initializing)
        // ...
        notify()  // snapshots state → dispatches to main thread
    }
}
```

`notify()` is the single bridge from `stateQueue` to main. It captures snapshots of registry state while still on `stateQueue`, then dispatches those immutable copies to `@Published` properties on main:

```swift
private func notify() {
    // Already on stateQueue — safe to read registry
    let scanning   = registry.isScanningInternal
    let discovered = registry.discovered       // [DotDevice]
    let dots       = registry.dots             // [Dot]
    let connected  = registry.connectedDots    // [Dot]
    let pending    = registry.connectInProgress != nil || !registry.connectQueue.isEmpty

    DispatchQueue.main.async {
        self.isScanning          = scanning
        self.discovered          = discovered
        self.dots                = dots
        self.connectedDots       = connected
        self.hasPendingConnections = pending
    }
}
```

This ensures SwiftUI never sees partially-updated state — all five properties update atomically.

### Pattern 2: State Decision → SDK Call

When DotManager needs to call the SDK (connect a device, start a scan, begin sync), it reads state on `stateQueue` first, then dispatches the SDK call to `sdkQueue`:

```swift
// Inside stateQueue.async { ... }
let device = registry.dequeueNextConnection()
sdkQueue.async {
    DotConnectionManager.connect(device)
}
```

The two queues must **never** synchronously dispatch to each other. `stateQueue.sync { sdkQueue.sync { ... } }` or the reverse would deadlock. All cross-queue dispatches are `.async`.

### Pattern 3: SDK Call with Completion → State Update

Operations like `performSync` dispatch to `sdkQueue` for the SDK call, then hop back to `stateQueue` in the completion:

```swift
sdkQueue.async {
    DotSyncManager.startSync(devices) { results in
        stateQueue.async {
            // Parse results, update registry
            notify()
        }
    }
}
```

### Queue Ownership Summary

| Queue | Owns | Never Do |
|-------|------|----------|
| `stateQueue` | `DotRegistry` (all fields), `runnerPhasesInternal`, `syncingUuids`, connect timers | Call SDK methods, `.sync` to sdkQueue |
| `sdkQueue` | All `DotConnectionManager` / `DotSyncManager` / device API calls, `ExportManager` SDK calls | Mutate registry, `.sync` to stateQueue |
| Main thread | All `@Published` properties, SwiftUI binding | Long-running work, SDK calls |

### Shared sdkQueue

`ExportManager` accesses the same queue via a computed property:
```swift
var sdkQueue: DispatchQueue { DotManager.shared.sdkQueue }
```

This is critical — if ExportManager had its own queue, concurrent SDK calls from export and connection would corrupt SDK state.

---

## Deep Dive: Connection Queue

The connection queue ensures only one BLE connection attempt happens at a time. The SDK can't reliably handle concurrent `connect()` calls.

### State (lives in DotRegistry, accessed on stateQueue)

```swift
var connectQueue: [String]       // FIFO array of UUIDs waiting to connect
var connectInProgress: String?   // UUID currently being connected (nil = idle)
```

### Flow

**1. User taps Connect → `connectByUuid(_:)`**

```
connectByUuid(uuid)
    └─ stateQueue.async
        ├─ Guard: uuid exists in registry.byUuid
        ├─ Guard: not a duplicate (uuid not already in connectQueue or connectInProgress)
        ├─ registry.setConnectionPhase(uuid, .connecting)
        ├─ registry.connectQueue.append(uuid)
        ├─ startConnectTimer(uuid)   // 10-second timeout on main thread
        ├─ notify()
        └─ processConnectQueue()
```

**2. `processConnectQueue()` dequeues one device**

```
processConnectQueue()
    └─ stateQueue (already on it)
        ├─ device = registry.dequeueNextConnection()
        │     ├─ Guard: connectInProgress == nil (no active connection)
        │     ├─ Guard: !syncInProgress (sync blocks connections)
        │     ├─ Find first UUID in connectQueue that exists in byUuid
        │     ├─ Remove from connectQueue
        │     ├─ Set connectInProgress = uuid
        │     └─ Return device
        │
        ├─ if device == nil → return (queue empty or blocked)
        │
        └─ sdkQueue.async {
               DotConnectionManager.connect(device)
           }
```

**3. Connection succeeds or fails → advance queue**

Both `onDeviceConnectSucceeded` and `onDeviceConnectFailed` call `advanceConnectQueue()`:

```
advanceConnectQueue()
    └─ stateQueue (already on it)
        ├─ registry.connectInProgress = nil
        └─ processConnectQueue()   // try next in queue
```

**4. Timeout (10 seconds, no SDK callback)**

`startConnectTimer(uuid)` creates a `DispatchWorkItem` scheduled on main thread. If it fires:
- Sets connection phase to `.failed("Connection timed out")`
- Calls `advanceConnectQueue()` to move on

If the SDK callback arrives before timeout, the timer is cancelled via `connectTimers[uuid]?.cancel()`.

### Why One at a Time

The Movella SDK's `DotConnectionManager.connect()` uses shared internal state. Calling it for device B while device A's connection is in-flight can cause A's callback to never fire or fire with B's device reference. The serial queue pattern avoids this entirely.

---

## Deep Dive: Reconnect Logic

`onDeviceConnectSucceeded` handles three distinct reconnection scenarios, each with different initialization paths.

### Entry Point: `onDeviceConnectSucceeded(_ device: DotDevice)`

Everything below runs on `stateQueue`:

```swift
func onDeviceConnectSucceeded(_ device: DotDevice) {
    stateQueue.async { [self] in
        let uuid = device.uuid

        // Cancel timeout timer
        connectTimers[uuid]?.cancel()
        connectTimers[uuid] = nil

        // PATH 1: Sync reconnect
        if registry.syncInProgress && registry.syncingUuids.contains(uuid) {
            registry.recordReconnection(device)  // lightweight update, no phase change
            advanceConnectQueue()
            notify()
            return
        }

        let alreadyKnown = registry.byUuid[uuid]?.dot != nil
        let wasQueued = registry.connectInProgress == uuid

        if alreadyKnown && !wasQueued {
            // PATH 2: Auto-reconnect (iOS reconnected without us asking)
            registry.recordReconnection(device)
            registry.setConnectionPhase(uuid, .initializing)
            initializeAfterConnect(uuid: uuid)

        } else if alreadyKnown && wasQueued {
            // PATH 3: BT-reset reconnect (we re-queued after BT power cycle)
            registry.recordConnection(device)  // updates device ref, creates Dot if needed
            advanceConnectQueue()
            initializeAfterConnect(uuid: uuid, settleDelay: 2.0)

        } else {
            // PATH 4: First-time connection
            registry.recordConnection(device)
            advanceConnectQueue()
            sdkQueue.async { DotDevicePool.bindDevice(device) }
            initializeAfterConnect(uuid: uuid)
        }

        notify()
    }
}
```

### `initializeAfterConnect(uuid:settleDelay:)`

This method decides whether to query flash storage or skip straight to `.ready`:

```swift
func initializeAfterConnect(uuid: String, settleDelay: TimeInterval = 0) {
    guard let dot = registry.dot(forUuid: uuid) else { return }

    dot.checkRecordingStatus { [weak self] isRecording in
        guard let self else { return }
        self.stateQueue.async {
            if isRecording {
                // Sensor is mid-recording — skip flash query (it won't respond)
                self.registry.setConnectionPhase(uuid, .ready)
                self.registry.initializationInProgress.remove(uuid)
                self.restoreRecordingPhase(for: uuid)
                self.notify()
            } else {
                // Safe to query flash — calls getFlashInfo on each dot
                self.refreshStorage(uuids: [uuid], settleDelay: settleDelay)
            }
        }
    }
}
```

**`checkRecordingStatus`** (on `Dot`): Installs a one-shot callback via `recordingStatusCompletion`, then calls `device.getRecordingStatus()` on `sdkQueue`. The callback fires when the SDK pushes the status. A 3-second timeout ensures the completion always fires (with `false` if SDK doesn't respond).

**`refreshStorage`**: Delegates to `DotOperationRunner.refreshStorage()` which calls `dot.getFlashInfo()` for each UUID. On completion, marks the dot `.ready` and calls `notify()`.

### `restoreRecordingPhase(for: uuid)`

When a reconnected sensor is still recording, this method looks up which runner owns that sensor (via `RunnerStore`) and sets that runner's phase to `.recording` if it isn't already. This restores the UI without any persistence file — the sensor's own `isRecording` state is the source of truth.

### The Settle Delay

After a Bluetooth power-off/reset, iOS reconnects devices but the SDK's internal BLE handshake isn't fully complete when `onDeviceConnectSucceeded` fires. `bindDevice()` returns immediately and `device.isInitialized` reports `true`, but `getFlashInfo()` never gets a callback because the underlying GATT services aren't ready.

The 2-second `settleDelay` (passed through to `DotOperationRunner.waitForInitialization`) adds a pause after `isInitialized` returns `true` but before calling `getFlashInfo()`. This gives the SDK time to finish its internal re-initialization.

---

## Deep Dive: Sync Flow

### Entry: `beginSession(runnerId:)`

Called when the user taps "Start" on a runner card. Runs on `stateQueue`:

```
beginSession(runnerId:)
    └─ stateQueue.async
        ├─ Guard: runnerPhasesInternal[runnerId] is .idle or .error
        ├─ Guard: connectQueue is empty AND connectInProgress is nil
        │     (can't sync while connections are in flight)
        ├─ Guard: no other runner is in .syncing phase (isAnySyncing == false)
        ├─ Guard: runner exists in RunnerStore with sensor UUIDs
        ├─ Collect dots in .ready phase for this runner's UUIDs
        ├─ Guard: none of the dots are currently recording
        │
        ├─ Configure each dot: dot.configure(outputRate:, filterIndex:)
        ├─ setPhase(runnerId, .syncing)
        │
        ├─ if dots.count >= 2:
        │     ├─ registry.syncingUuids = Set(uuids)  // freeze these UUIDs
        │     └─ performSync(dots: dots) { success, error in
        │            if success:
        │                performStartRecording(runnerId:, dots:)
        │            else:
        │                setPhase(runnerId, .error(error))
        │         }
        │
        └─ if dots.count == 1:
              └─ performStartRecording(runnerId:, dots:)
                  // Single sensor doesn't need sync
```

### `performSync(dots:completion:)`

```
performSync(dots:, completion:)
    └─ stateQueue (capture device references while state is stable)
        ├─ Snapshot: devices = dots.map { $0.device }
        │     (must capture BEFORE dispatching to sdkQueue, because
        │      the SDK will disconnect/reconnect and device refs change)
        │
        └─ sdkQueue.async {
               DotSyncManager.startSync(devices) { results in
                   stateQueue.async {
                       // Parse results array
                       // Each result has .success boolean
                       // Mark dots as sessionSynced = true
                       // Clear syncingUuids for these UUIDs
                       // Call refreshStorage to re-fetch flash info
                       //   (flash info may be stale after SDK reconnect)
                       completion(allSucceeded, errorMessage)
                   }
               }
           }
```

### Per-UUID Suppression via `syncingUuids`

During sync, the SDK internally disconnects and reconnects each sensor. This fires `onDeviceDisconnected` and `onDeviceConnectSucceeded` delegate callbacks. Without suppression, DotManager would:
- Mark the sensor as disconnected (clear phase, update UI)
- Try to re-initialize it (flash queries, bind device)
- Corrupt the sync by interfering with the SDK's internal reconnection

The fix is `syncingUuids: Set<String>` on `DotRegistry`:

```swift
// In onDeviceDisconnected:
if registry.syncingUuids.contains(uuid) {
    return  // Suppress — SDK is managing this device
}

// In onDeviceConnectSucceeded:
if registry.syncInProgress && registry.syncingUuids.contains(uuid) {
    registry.recordReconnection(device)  // lightweight, no phase change
    return  // Don't initialize — SDK is managing this device
}
```

**Why per-UUID, not a global flag?** If Runner A (sensors 1, 2, 3) is syncing and Runner B (sensors 4, 5, 6) has a sensor disconnect, a global `syncInProgress` flag would suppress Runner B's disconnect handling too. Per-UUID suppression only affects the sensors actually involved in the sync.

### Device Reference Freezing

`syncingUuids` also prevents device reference updates during sync. Both `recordDiscovery()` and `recordReconnection()` check:

```swift
func recordDiscovery(_ device: DotDevice) {
    let uuid = device.uuid
    if syncingUuids.contains(uuid) { return }  // Don't update device ref
    byUuid[uuid]?.device = device
    // ...
}
```

This is critical because `performSync` captures device references before dispatching to `sdkQueue`. If a discovery event updated the registry's device reference mid-sync, the captured references would be stale but the registry's would be new — causing the sync completion handler to operate on mismatched state.

### `setPhase` and Sync Flag Maintenance

```swift
private func setPhase(_ runnerId: String, _ phase: SessionPhase) {
    // Must be on stateQueue
    runnerPhasesInternal[runnerId] = phase

    // Keep syncInProgress in lockstep
    registry.syncInProgress = runnerPhasesInternal.values.contains { $0.isSyncActive }

    // If this runner is no longer syncing, release its UUIDs
    if !phase.isSyncActive, let runner = runnerStore.runner(forId: runnerId) {
        for uuid in runner.sensorUuids {
            registry.syncingUuids.remove(uuid)
        }
    }

    // Snapshot to main thread
    let snapshot = runnerPhasesInternal
    DispatchQueue.main.async { self.runnerPhases = snapshot }
    notify()
}
```

---

## Deep Dive: DotRegistry

`DotRegistry` (`Managers/DotRegistry.swift`) is a plain class (not `ObservableObject`) that holds all mutable sensor state. It exists as a separate type for a single reason: **it is not thread-safe and must only be accessed on `stateQueue`**.

By isolating all mutable state into DotRegistry, the threading contract is clear: if you're touching a `DotRegistry` property, you must be on `stateQueue`. DotManager enforces this by only accessing `registry` inside `stateQueue.async` or `stateQueue.sync` blocks.

### What It Stores

```swift
class DotRegistry {
    // Master dictionary — all known sensors
    var byUuid: [String: DotState] = [:]

    // Connection serialization
    var connectQueue: [String] = []
    var connectInProgress: String? = nil
    var initializationInProgress: Set<String> = []

    // Sync coordination
    var syncInProgress: Bool = false
    var syncingUuids: Set<String> = []

    // Scan state
    var isScanningInternal: Bool = false
}
```

`DotState` bundles a device reference, its `Dot` model, last-seen time, and connection phase:

```swift
struct DotState {
    var device: DotDevice
    var dot: Dot?
    var lastSeen: Date
    var connectionPhase: ConnectionPhase = .idle
}
```

### Computed Snapshot Properties

These are read by `notify()` on `stateQueue` and copied to main:

- **`discovered`** — All devices sorted by `lastSeen` descending (most recent first), mapped to `DotDevice`
- **`dots`** — All `Dot` models (any sensor that has been connected at least once)
- **`connectedDots`** — Dots with `connectionPhase.isConnected` (`.initializing` or `.ready`)
- **`previouslyConnectedUuids`** — UUIDs with non-nil `Dot` (for re-queueing after BT reset)

### Mutation Methods

| Method | Called When | What It Does |
|--------|-----------|--------------|
| `recordDiscovery(device)` | SDK discovers a sensor via scan | Adds/updates `byUuid` entry, updates `lastSeen`. Skips device ref update if `syncingUuids` contains UUID. |
| `recordConnection(device)` | First connect or BT-reset reconnect | Updates/creates `DotState`, creates `Dot` if needed or calls `dot.updateDevice()`, adds UUID to `initializationInProgress`, sets phase to `.initializing`. |
| `recordReconnection(device)` | Auto-reconnect or sync reconnect | Lightweight: updates device ref and `lastSeen`, calls `dot.updateDevice()`. Does NOT change phase. Skips device ref update for syncing UUIDs. |
| `recordDisconnection(uuid)` | Sensor disconnects | Sets phase to `.idle`, clears `sessionSynced`, removes from `initializationInProgress`. |
| `setConnectionPhase(uuid, phase)` | Various state transitions | Updates phase in both `DotState` and the `Dot` model simultaneously. |
| `markAllDisconnected()` | BT powers off | Sets all UUIDs to `.idle` phase. |
| `clearBusyFlags()` | BT resets | Clears `isScanningInternal`, `connectInProgress`, `initializationInProgress`, `syncInProgress`, `syncingUuids`. |

### The Snapshot/Notify Bridge

DotRegistry never publishes state directly. Instead, DotManager's `notify()` method:
1. Reads registry's computed properties on `stateQueue` (producing value-type snapshots)
2. Dispatches those snapshots to `@Published` properties on `main`

This means SwiftUI views never access DotRegistry directly — they observe DotManager's `@Published` properties, which are always safe to read on main.

---

## Deep Dive: DotOperationRunner

`DotOperationRunner` (`Managers/DotOperationRunner.swift`) serializes bulk operations across multiple sensors. It's a stateless helper — all state comes from its arguments.

### Core Method: `runAll(dots:operation:completion:)`

Runs a closure on each dot sequentially (not concurrently), collecting success/failure:

```swift
func runAll(
    dots: [Dot],
    operation: @escaping (Dot, @escaping (Bool) -> Void) -> Void,
    completion: @escaping (Bool) -> Void
) {
    executeSequentially(items: dots, operation: operation) { allSuccess in
        DispatchQueue.main.async { completion(allSuccess) }
    }
}
```

**Used by DotManager for:**
- `startRecording` — calls `dot.startRecording(seconds: 0xFFFF)` on each dot
- `stopRecording` — calls `dot.stopRecording()` on each dot
- `eraseAllFlash` — calls `dot.eraseFlash()` on each dot

### `executeSequentially(items:operation:completion:)`

Generic recursive helper:

```swift
private func executeSequentially<T>(
    items: [T],
    operation: @escaping (T, @escaping (Bool) -> Void) -> Void,
    completion: @escaping (Bool) -> Void
) {
    var index = 0
    var allSuccess = true

    func next() {
        guard index < items.count else { completion(allSuccess); return }
        let item = items[index]
        index += 1
        operation(item) { success in
            if !success { allSuccess = false }
            next()  // recurse to next item
        }
    }
    next()
}
```

Operations run on `sdkQueue` because the `operation` closures (e.g., `dot.startRecording`) dispatch there internally. The recursive `next()` call happens in the operation's completion, which fires on `sdkQueue` or main depending on the specific operation.

### `refreshStorage(dots:settleDelay:onDotComplete:completion:)`

Specialized bulk operation for fetching flash info after connection or sync:

```swift
func refreshStorage(
    dots: [Dot],
    settleDelay: TimeInterval = 0,
    onDotComplete: ((Dot, Bool) -> Void)? = nil,
    completion: @escaping () -> Void
) {
    executeSequentially(items: dots) { dot, done in
        self.waitForInitialization(dot: dot, timeout: 5.0, settleDelay: settleDelay) {
            dot.getFlashInfo { success in
                onDotComplete?(dot, success)
                done(success)
            }
        }
    } completion: { _ in
        completion()
    }
}
```

### `waitForInitialization(dot:timeout:settleDelay:completion:)`

Polls `dot.isInitialized` every 0.2 seconds on `sdkQueue` (using `asyncAfter` to yield the queue between checks). After `isInitialized` returns `true`, waits an additional `settleDelay` before completing:

```swift
private func waitForInitialization(dot: Dot, timeout: TimeInterval, settleDelay: TimeInterval, completion: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(timeout)

    func poll() {
        sdkQueue.asyncAfter(deadline: .now() + 0.2) {
            if dot.isInitialized {
                if settleDelay > 0 {
                    self.sdkQueue.asyncAfter(deadline: .now() + settleDelay) { completion() }
                } else {
                    completion()
                }
            } else if Date() > deadline {
                completion()  // timeout — proceed anyway
            } else {
                poll()  // recurse
            }
        }
    }
    poll()
}
```

The `asyncAfter` pattern is important: it yields `sdkQueue` between polls so other SDK operations (like packet callbacks during export) aren't starved.

---

## Deep Dive: Export Pipeline

ExportManager (`Managers/ExportManager.swift`, `ExportManager+BLETransfer.swift`, `ExportManager+Persistence.swift`) manages the full export lifecycle with three private queues plus the shared `sdkQueue`.

### Queue Architecture

| Queue | Purpose |
|-------|---------|
| `sdkQueue` (shared from DotManager) | All SDK device calls + receives BLE packet callbacks |
| `fileQueue` (serial, `.userInitiated`) | CSV file I/O — open, write batches, close handles |
| `exportSequenceQueue` (serial, `.userInitiated`) | Waits on semaphore for all devices to complete |

### Export Flow

```
fetchRecordings(for: dots)
    └─ For each dot (DispatchGroup):
        dot.getExportFileInfo → recordings[dot.address] = files
    └─ group.notify(queue: .main):
        exportPhase = .ready

buildCart()
    └─ Selected files → CartItems with auto-session grouping (20min window)

startExport()
    └─ Create ExportTasks from CartItems
    └─ Group tasks by dot address
    └─ For each dot (concurrent):
        exportFilesForDot(dot, tasks) → semaphore.signal()
    └─ exportSequenceQueue.async:
        for _ in 0..<deviceCount: semaphore.wait()
        → exportPhase = .done
```

### Per-File BLE Transfer (`exportFilesForDot`)

For each file within a dot, files are exported sequentially:

```
1. fileQueue.async:
      Create CSV file, write header, open FileHandle

2. sdkQueue.async:
      device.stopExportFileData()        // reset prior state
      device.exportDataFormat = Data(...) // timestamp, euler, accel, angvel
      device.recording.exportFileList = [fileIndex]

      // Install packet callback (fires on sdkQueue)
      device.setDidParseExportFileDataBlock { plotData in
          watchdog.beat()                 // reset stall timer
          Format CSV row from plotData fields
          Append to batch buffer
          if packetsReceived % 200 == 0:
              let captured = batch
              fileQueue.async { fileHandle.write(captured) }
          Update progress every 100 packets or 0.5s
      }

      // Install done callback (fires on sdkQueue)
      device.recording.exportFileDone = { ... in
          doneFired = true
          // Watchdog will handle finalization
      }

      // Install watchdog (10s stall detection)
      ExportWatchdog(timeout: 10, queue: sdkQueue) {
          if doneFired:
              Flush final batch → validate → success or fail
          else:
              Genuine stall → fail, delete partial CSV
      }

      device.startExportFileData()       // begin BLE transfer
```

### Generation IDs

`exportFileGenerations: [String: Int]` (keyed by dot address) guards against stale SDK callbacks:

```swift
// Before each file export:
exportFileGenerations[dot.address, default: 0] += 1
let generation = exportFileGenerations[dot.address, default: 0]

// Inside every callback:
guard exportFileGenerations[dot.address] == generation else { return }
```

Bumped on: export start, cancel, watchdog timeout. If a callback from a prior attempt fires after the generation was bumped, the guard rejects it.

### Watchdog

`ExportWatchdog` runs a `DispatchSourceTimer` on `sdkQueue`, firing every 1 second. It checks `Date().timeIntervalSince(lastPacketAt) > timeout`. The packet callback calls `watchdog.beat()` to reset `lastPacketAt`.

On timeout, the watchdog handles two cases:
- **`doneFired == true`**: The SDK signaled completion but the stream was still draining. Flush the final batch, validate packet continuity, and mark success or fail.
- **`doneFired == false`**: Genuine stall (no packets for 10+ seconds). Stop the export, delete the partial CSV, mark failed.

### Packet Count Validation

After each file completes, `validatePacketCount(csvURL:)` reads the CSV, extracts the `packet_counter` column, and checks that `(lastCounter - firstCounter + 1) == rowCount`. Any gap means BLE packets were lost. Failed validation marks the task with `hasPacketLoss = true` and status `.failed`.

### Progress Estimation

SDK provides no total packet count. Estimated from file size:

```swift
let estimatedDuration = max(Double(fileSize) / (88.0 * 33.0), 1.0)
// ~88 bytes per on-device packet, ~33 packets per second over BLE
let progress = min(elapsedTime / estimatedDuration, 0.99)
```

Progress caps at 0.99 until `exportFileDone` fires, then jumps to 1.0.

### Cancel Flow

`cancelExport()` must unwind all concurrent state:
1. Bump `exportSequenceGeneration` (makes the sequence completion handler a no-op)
2. Bump all per-file `exportFileGenerations` (makes packet/done callbacks no-ops)
3. Stop all watchdogs
4. Close all file handles on `fileQueue`
5. Call `device.stopExportFileData()` on `sdkQueue` for all actively-transferring dots
6. Mark all running/queued tasks as `.canceled`, delete partial CSVs
7. Signal the semaphore for each pending device (unblocks `exportSequenceQueue`)

### Retry Logic

`retryFailed()` inspects disk state before deciding what to re-export:
- If CSV exists and wasn't marked with packet loss → mark success (already done)
- If CSV exists but has packet loss → delete CSV, re-export from scratch
- If no CSV exists → full BLE re-export

There is no partial resume — the streaming pipeline has no intermediate binary format to resume from.

### Persistence

Tasks are saved to `Documents/export_records.json` whenever status changes to `.success`, `.failed`, or `.canceled`. On next app launch, `restorePersistedTasks()` rehydrates tasks, verifies CSV files still exist on disk, and deletes orphaned partial CSVs from the export directory.
