import Foundation
import Combine
import MovellaDotSdk

// MARK: - Session Phase

/// Tracks the lifecycle of a recording session.
///
/// The UI derives button labels, colors, and disabled states from this single
/// value. Transitions are linear:
///
///     idle ──▶ syncing ──▶ startingRecording ──▶ recording ──▶ stoppingRecording ──▶ idle
///                │                  │                                  │
///                ▼                  ▼                                  ▼
///            error(…)          error(…)                           error(…)
///
/// Any `error` state can transition back to `idle` via `dismissError()`,
/// allowing the user to retry.
nonisolated enum SessionPhase: Equatable, Sendable {
    case idle
    case syncing
    case startingRecording
    case recording
    case stoppingRecording
    case error(String)
}

extension SessionPhase {

    /// True while a background operation is in flight and the UI should show a spinner.
    var isBusy: Bool {
        switch self {
        case .syncing, .startingRecording, .stoppingRecording:
            return true
        default:
            return false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// True when the SDK is performing clock synchronization.
    /// Used by delegate methods to suppress spurious disconnect/reconnect events
    /// that the SDK fires internally during sync.
    var isSyncActive: Bool {
        self == .syncing
    }
}

// MARK: - Connection Phase

/// Per-device connection lifecycle, managed by `DotManager` and stored in `DotRegistry`.
///
/// Transitions:
///     idle ──▶ connecting ──▶ initializing ──▶ ready
///                  │                              │
///                  ▼                              ▼
///            failed(…)                     idle (disconnect)
nonisolated enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case initializing
    case ready
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isBusy: Bool {
        self == .connecting || self == .initializing
    }

    var isConnected: Bool {
        self == .initializing || self == .ready
    }
}

// MARK: - DotManager

/// Singleton that owns all app state related to Movella DOT sensors.
///
/// Responsibilities:
///   - Bluetooth scanning and device discovery
///   - Connection queuing (one at a time to avoid SDK contention)
///   - Session management (sync → record → stop as a single user action)
///   - Flash storage operations (erase)
///
/// **Threading contract:**
///   - `stateQueue` (serial) — protects `DotRegistry` mutations and internal flags.
///   - `sdkQueue`   (serial) — serializes all `MovellaDotSdk` API calls.
///   - Main thread            — all `@Published` property writes for SwiftUI.
///
/// Views observe this object via `@ObservedObject` and read `@Published`
/// properties; they never touch the registry or queues directly.
final class DotManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = DotManager()

    private override init() {
        super.init()
    }

    // MARK: - Queues

    /// Guards all `DotRegistry` reads/writes.
    private let stateQueue = DispatchQueue(label: "DotManager.stateQueue")

    /// Serializes every call into the Movella SDK.
    private let sdkQueue = DispatchQueue(label: "DotManager.sdkQueue")

    // MARK: - Components

    /// Non-thread-safe bookkeeping for all known devices. Access only on `stateQueue`.
    private lazy var registry = DotRegistry(sdkQueue: sdkQueue)

    /// Triggers Bluetooth scans on `sdkQueue`.
    private lazy var scanner = DotScanner(sdkQueue: sdkQueue)

    /// Runs bulk sequential operations (record, erase, etc.) on `sdkQueue`.
    private lazy var operations = DotOperationRunner(sdkQueue: sdkQueue)

    // MARK: - Lifecycle

    /// Call once at app launch to register as the SDK's connection delegate
    /// and enable automatic reconnection.
    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
        DotReconnectManager.setEnable(true)
    }

    // MARK: - Published State (UI-facing)

    @Published private(set) var isScanning: Bool = false
    @Published private(set) var discovered: [DotDevice] = []
    @Published private(set) var dots: [Dot] = []
    @Published private(set) var connectedDots: [Dot] = []
    @Published private(set) var sessionPhase: SessionPhase = .idle

    /// Per-device connection timeout timers. Managed on the main thread.
    private var connectTimers: [String: DispatchWorkItem] = [:]

    /// Thread-safe lookup of a `Dot` model by UUID.
    func dot(forUuid uuid: String) -> Dot? {
        stateQueue.sync { registry.dot(forUuid: uuid) }
    }

    /// Thread-safe lookup of a device's connection phase.
    /// Reads from the Dot (canonical source) first; falls back to DotState
    /// for pre-Dot phases like `.connecting`.
    func connectionPhase(forUuid uuid: String) -> ConnectionPhase {
        stateQueue.sync {
            registry.dot(forUuid: uuid)?.connectionPhase
                ?? registry.byUuid[uuid]?.connectionPhase
                ?? .idle
        }
    }

    // MARK: - Scanning

    /// Begin Bluetooth discovery. Ignored if a scan is already running.
    func startScan() {
        stateQueue.async {
            if self.registry.isScanningInternal { return }

            self.scanner.scan { [weak self] in
                self?.stateQueue.async {
                    guard let self, !self.registry.isScanningInternal else { return }
                    self.registry.isScanningInternal = true
                    print("🔍 Scan started")
                    self.notify()
                }
            }
        }
    }

    func stopScan() {
        stateQueue.async {
            if !self.registry.isScanningInternal { return }
            self.registry.isScanningInternal = false
            print("🔍 Scan stopped")
            self.notify()

            self.scanner.stopScan()
        }
    }

    // MARK: - Connection

    /// Queue a device for connection by UUID. Starts scanning if needed.
    /// Duplicate requests for the same UUID are ignored.
    func connectByUuid(_ uuid: String) {
        let u = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }

        stateQueue.async {
            if self.registry.connectQueue.contains(u) || self.registry.connectInProgress == u { return }
            self.registry.connectQueue.append(u)
            self.registry.setConnectionPhase(u, .connecting)

            self.startScan()
            self.startConnectTimer(u)

            self.processConnectQueue()
            self.notify()
        }
    }

    /// Unbind and disconnect a connected device.
    /// Refused if a sync is in progress to prevent corrupting `DotSyncManager` state.
    func disconnect(_ dot: Dot) {
        stateQueue.async {
            guard !self.sessionPhase.isSyncActive else {
                print("⚠️ Disconnect refused — sync in progress")
                return
            }
            self.sdkQueue.async {
                DotDevicePool.unbindDevice(dot.device)
                DotConnectionManager.disconnect(dot.device)
            }
        }
    }

    /// Remove a UUID from the connect queue (e.g. after a connection timeout).
    /// If the UUID is currently mid-connect, advances to the next queued device.
    func cancelConnect(uuid: String) {
        stateQueue.async {
            self.registry.connectQueue.removeAll { $0 == uuid }
            self.registry.setConnectionPhase(uuid, .failed("Connection timed out"))
            if self.registry.connectInProgress == uuid {
                self.registry.advanceConnectQueue()
                self.processConnectQueue()
            }
            self.notify()
        }
    }

    // MARK: - Session (Unified Sync + Record)

    /// Start a recording session.
    ///
    /// If two or more sensors are connected, clocks are synchronized first to
    /// align multi-sensor data. With a single sensor, recording starts immediately.
    ///
    /// Flow: `idle` → `syncing` → `startingRecording` → `recording`
    func beginSession() {
        stateQueue.async {
            guard self.sessionPhase == .idle || self.sessionPhase.isError else { return }

            let dots = self.registry.connectedDots.filter { dot in
                let uuid = dot.address
                let phase = self.registry.byUuid[uuid]?.connectionPhase ?? .idle
                return phase == .ready
            }
            guard !dots.isEmpty else { return }

            if dots.count >= 2 {
                self.registry.syncingUuids = Set(dots.map { $0.device.uuid })
                self.setPhase(.syncing)
                self.performSync(dots: dots) { [weak self] success, errorMsg in
                    guard let self else { return }
                    if success {
                        self.performStartRecording(dots: dots)
                    } else {
                        self.setPhase(.error(errorMsg ?? "Sync failed. Please try again."))
                    }
                }
            } else {
                self.performStartRecording(dots: dots)
            }
        }
    }

    /// Stop the active recording session.
    ///
    /// Flow: `recording` → `stoppingRecording` → `idle`
    func endSession() {
        stateQueue.async {
            guard self.sessionPhase == .recording else { return }

            let dots = self.registry.connectedDots
            self.setPhase(.stoppingRecording)

            self.operations.runAll(
                dots: dots,
                operation: { dot, done in dot.stopRecording(completion: done) }
            ) { [weak self] success in
                guard let self else { return }
                self.stateQueue.async {
                    if success {
                        self.setPhase(.idle)
                    } else {
                        self.setPhase(.error("Failed to stop recording. Please try again."))
                    }
                }
            }
        }
    }

    /// Clear an error state, returning to `idle` so the user can retry.
    func dismissError() {
        stateQueue.async {
            if self.sessionPhase.isError {
                self.setPhase(.idle)
            }
        }
    }

    /// Restore the `recording` phase after an app relaunch.
    ///
    /// Called from `SyncView.onAppear` when the manager is `idle` but one or
    /// more dots report `isRecording == true` (the sensors kept recording while
    /// the app was killed).
    func resumeRecordingSession() {
        stateQueue.async {
            if self.sessionPhase == .idle {
                self.setPhase(.recording)
            }
        }
    }

    // MARK: - Session Helpers

    /// Single writer for `sessionPhase`. Must be called on `stateQueue`.
    ///
    /// Also keeps `registry.syncInProgress` in lockstep — the registry flag is
    /// read by `dequeueNextConnection` to block new connections during sync, and
    /// is cheaper to check than dispatching to main for the published property.
    private func setPhase(_ phase: SessionPhase) {
        registry.syncInProgress = phase.isSyncActive
        if !phase.isSyncActive {
            registry.syncingUuids.removeAll()
        }
        DispatchQueue.main.async {
            self.sessionPhase = phase
        }
        notify()
    }

    /// Synchronize sensor clocks via `DotSyncManager`. Must be called on `stateQueue`.
    ///
    /// The SDK internally disconnects and reconnects each device during sync;
    /// delegate methods suppress those events when `isSyncActive` is true.
    /// Completion is dispatched back to `stateQueue`.
    private func performSync(dots: [Dot], completion: @escaping (Bool, String?) -> Void) {
        // Snapshot device references now (on stateQueue) before sync mutates anything.
        // The registry freezes these references while syncInProgress is true.
        let devices = dots.map { $0.device }
        print("🔄 Starting sync with \(devices.count) devices...")

        sdkQueue.async { [weak self] in
            guard let self else { return }

            for device in devices {
                print("🔍 [PRE-SYNC] \(device.uuid): isInitialized=\(device.isInitialized())")
            }

            DotSyncManager.startSync(devices) { results in
                self.stateQueue.async {
                    guard let results = results as? [[String: Any]] else {
                        print("❌ Sync failed - no results")
                        dots.forEach { $0.setSessionSynced(false) }
                        completion(false, "Sync failed — no results from SDK.")
                        return
                    }

                    for result in results {
                        let addr = (result["address"] as? String) ?? "?"
                        let status = (result["status"] as? Int) ?? -1
                        let success = (result["success"] as? Bool) ?? false
                        let done = (result["doneSuccess"] as? Int) ?? -1
                        print("🔄 [SYNC RESULT] \(addr): status=\(status) success=\(success) doneSuccess=\(done)")
                    }

                    let allSuccess = results.allSatisfy { ($0["success"] as? Bool) ?? false }
                    dots.forEach { $0.setSessionSynced(allSuccess) }

                    if allSuccess {
                        print("✅ Sync completed")
                    } else {
                        let failCount = results.filter { !(($0["success"] as? Bool) ?? false) }.count
                        print("❌ Sync failed — \(failCount) of \(results.count) devices")
                    }

                    self.refreshStorage(dots: dots)

                    if allSuccess {
                        completion(true, nil)
                    } else {
                        let failCount = results.filter { !(($0["success"] as? Bool) ?? false) }.count
                        completion(false, "\(failCount) of \(results.count) sensors failed to sync. Please try again.")
                    }
                }
            }
        }
    }

    /// Issue start-recording to each dot sequentially. Must be called on `stateQueue`.
    /// `0xFFFF` tells the sensor to record indefinitely until explicitly stopped.
    private func performStartRecording(dots: [Dot]) {
        setPhase(.startingRecording)

        operations.runAll(
            dots: dots,
            operation: { dot, done in dot.startRecording(seconds: 0xFFFF, completion: done) }
        ) { [weak self] success in
            guard let self else { return }
            self.stateQueue.async {
                if success {
                    self.setPhase(.recording)
                } else {
                    self.setPhase(.error("Recording failed to start. Please try again."))
                }
            }
        }
    }

    // MARK: - Flash Storage

    /// Erase recorded data on every connected sensor. Only allowed when idle.
    func eraseAllFlash(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            guard self.sessionPhase == .idle else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.registry.connectedDots

            self.operations.runAll(
                dots: dotsSnapshot,
                operation: { dot, done in dot.eraseFlash(completion: done) },
                completion: completion
            )
        }
    }

    // MARK: - Internal Helpers

    /// Dequeue the next device and issue a connect call. Must be called on `stateQueue`.
    private func processConnectQueue() {
        guard let device = registry.dequeueNextConnection() else { return }
        print("🔗 Connecting to \(displayAddress(for: device))")

        sdkQueue.async {
            DotConnectionManager.connect(device)
        }
    }

    /// Fetch flash usage for each dot after sync or connection. Must be called on `stateQueue`.
    private func refreshStorage(dots: [Dot]) {
        operations.refreshStorage(dots: dots) { [weak self] dot, _ in
            self?.stateQueue.async {
                guard let self else { return }
                let uuid = dot.device.uuid
                self.registry.initializationInProgress.remove(uuid)
                self.registry.setConnectionPhase(uuid, .ready)
                self.notify()

                // After a BT power cycle, restore the recording session once
                // at least one device is back and ready.
                if self.registry.wasRecordingBeforeDisconnect {
                    self.registry.wasRecordingBeforeDisconnect = false
                    print("🔄 Restoring recording session after BT reconnect")
                    self.setPhase(.recording)
                }
            }
        } completion: {}
    }

    /// Snapshot registry state and push it to `@Published` properties on the main thread.
    /// Must be called on `stateQueue`.
    private func notify() {
        let scanning = registry.isScanningInternal
        let disc = registry.discovered
        let all = registry.dots
        let connected = registry.connectedDots

        DispatchQueue.main.async {
            self.isScanning = scanning
            self.discovered = disc
            self.dots = all
            self.connectedDots = connected
        }
    }

    // MARK: - Connect Timers

    /// Start a 10-second timeout for a connection attempt.
    /// If the timer fires, marks the device as failed and cancels the connect.
    /// Safe to call from any thread — dispatches to main for timer scheduling.
    private func startConnectTimer(_ uuid: String) {
        cancelConnectTimer(uuid)

        let work = DispatchWorkItem { [weak self] in
            self?.cancelConnect(uuid: uuid)
        }
        DispatchQueue.main.async {
            self.connectTimers[uuid] = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// Cancel a pending connect timer for a specific UUID.
    /// Safe to call from any thread.
    private func cancelConnectTimer(_ uuid: String) {
        DispatchQueue.main.async {
            self.connectTimers[uuid]?.cancel()
            self.connectTimers.removeValue(forKey: uuid)
        }
    }

    /// Cancel all pending connect timers (e.g. on Bluetooth power-off).
    private func cancelAllConnectTimers() {
        DispatchQueue.main.async {
            for (_, work) in self.connectTimers { work.cancel() }
            self.connectTimers.removeAll()
        }
    }

    // MARK: - Debug

    func printStatus() {
        stateQueue.sync {
            print("--- DotManager Status ---")
            print("Dots: \(registry.byUuid.count) | Connected: \(registry.connectedDots.count)")
            print("Connect Queue: \(registry.connectQueue.count)")
            print("Init Queue: \(registry.initializationInProgress)")
        }
    }

    /// Prefer MAC address for display; fall back to UUID.
    func displayAddress(for device: DotDevice) -> String {
        !device.macAddress.isEmpty ? device.macAddress : device.uuid
    }
}

// MARK: - DotConnectionDelegate (SDK Callbacks)

/// All callbacks fire on an arbitrary SDK thread. Each one hops onto
/// `stateQueue` immediately to safely mutate the registry, then calls
/// `notify()` to push changes to the UI.
extension DotManager: DotConnectionDelegate {

    func onDiscover(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        stateQueue.async {
            self.registry.recordDiscovery(device)
            self.processConnectQueue()
            self.notify()
        }
    }

    func onScanCompleted() {
        stateQueue.async {
            self.registry.isScanningInternal = false
            print("🔍 Scan completed")
            self.notify()

            // If devices are still waiting to connect, kick off another scan.
            if !self.registry.connectQueue.isEmpty { self.startScan() }
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        stateQueue.async {
            guard !device.uuid.isEmpty else {
                self.registry.advanceConnectQueue()
                self.processConnectQueue()
                return
            }

            self.cancelConnectTimer(device.uuid)

            // During sync the SDK internally reconnects each sensor.
            // Update the device reference but skip the full initialization
            // path — the dots were never shown as disconnected to the user.
            if self.sessionPhase.isSyncActive {
                self.registry.recordReconnection(device)
                return
            }

            // SDK auto-reconnect: device was previously connected but the
            // reconnect wasn't user-initiated (not in the connect queue).
            // Use the lightweight path — mark ready immediately and refresh
            // storage in the background.
            let isAutoReconnect = self.registry.byUuid[device.uuid]?.dot != nil
                && self.registry.connectInProgress != device.uuid
                && !self.registry.connectQueue.contains(device.uuid)

            if isAutoReconnect {
                print("🔄 [\(device.uuid)] Auto-reconnect detected")
                self.registry.recordReconnection(device)
                self.registry.setConnectionPhase(device.uuid, .initializing)

                self.sdkQueue.async {
                    DotDevicePool.bindDevice(device)
                }

                if let dot = self.registry.dot(forUuid: device.uuid) {
                    self.refreshStorage(dots: [dot])
                }
                self.notify()
                return
            }

            // recordConnection sets phase to .initializing
            self.registry.recordConnection(device)

            self.sdkQueue.async {
                DotDevicePool.bindDevice(device)
            }

            if let dot = self.registry.dot(forUuid: device.uuid) {
                print("⏳ [\(device.uuid)] Queuing initialization & storage refresh...")

                // refreshStorage will set phase to .ready on completion
                self.refreshStorage(dots: [dot])

                self.registry.advanceConnectQueue()
                self.processConnectQueue()
                self.notify()
            }
        }
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        print("❌ Connect failed: \(device.uuid)")
        stateQueue.async {
            // During sync the SDK manages connections itself — don't interfere.
            if self.sessionPhase.isSyncActive { return }
            self.cancelConnectTimer(device.uuid)
            self.registry.setConnectionPhase(device.uuid, .failed("Connection failed"))
            self.registry.advanceConnectQueue()
            self.processConnectQueue()
            self.notify()
        }
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        print("⛓️‍💥 Disconnected: \(device.uuid)")
        stateQueue.async {
            if self.sessionPhase.isSyncActive {
                // SDK-managed disconnect during sync — ignore entirely.
                // The dots remain visually "connected" throughout the sync process.
                return
            }
            self.registry.recordDisconnection(device.uuid)
            self.notify()
        }
    }

    func onManagerStateUpdate(_ managerState: XSDotManagerState) {
        stateQueue.async {
            switch managerState {
            case .poweredOn:
                print("✅ Bluetooth powered ON")

                // Re-queue all previously connected devices for auto-reconnect.
                for uuid in self.registry.previouslyConnectedUuids {
                    if !self.registry.connectQueue.contains(uuid) {
                        self.registry.connectQueue.append(uuid)
                    }
                }

                if !self.registry.connectQueue.isEmpty {
                    print("🔄 Resuming connection logic for \(self.registry.connectQueue.count) pending devices...")
                    self.registry.isScanningInternal = false
                    self.startScan()
                }

            case .poweredOff, .resetting:
                print("⚠️ Bluetooth powered OFF/RESET")
                self.registry.wasRecordingBeforeDisconnect = (self.sessionPhase == .recording)
                self.cancelAllConnectTimers()
                self.registry.clearBusyFlags()
                self.registry.markAllDisconnected()
                self.setPhase(.error("Bluetooth disconnected."))

            case .unauthorized, .unsupported:
                print("❌ Bluetooth Error: \(managerState.rawValue)")

            @unknown default:
                break
            }
        }
    }
}
