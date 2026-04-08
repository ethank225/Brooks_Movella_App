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

    /// True while a transient background operation is in flight (syncing, starting, stopping).
    /// NOT true during steady-state recording. Distinct from DotManager.isBusy which covers all active phases.
    var isTransitioning: Bool {
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

// MARK: - Testable Decision Logic

/// Lightweight snapshot of a sensor's state for precondition checks.
/// Avoids coupling test code to `Dot` (which wraps SDK objects).
struct DotSnapshot {
    let isReady: Bool
    let isSynced: Bool
    let isRecording: Bool
}

/// Which initialization path to take after a successful BLE connect.
enum ConnectPath: Equatable {
    case syncReconnect
    case queuedButNotActive
    case autoReconnect
    case normalConnect(settleDelay: TimeInterval)
}

/// Extracted pure functions for unit testing without Bluetooth.
/// Each function mirrors a decision point inside DotManager but takes
/// value-type inputs and returns value-type outputs — no SDK, no queues.
enum DotManagerLogic {

    // MARK: - Begin Session Preconditions

    /// Validates whether a recording session can start for the given runner state.
    /// Returns `nil` on success, or an error message describing why it's blocked.
    static func validateBeginSession(
        currentPhase: SessionPhase,
        connectQueueEmpty: Bool,
        dots: [DotSnapshot],
        runnerExists: Bool
    ) -> String? {
        guard currentPhase == .idle || currentPhase.isError else {
            return "Runner is busy (\(currentPhase))"
        }
        guard connectQueueEmpty else {
            return "Connections still pending"
        }
        guard runnerExists else {
            return "Runner not found"
        }
        let readyDots = dots.filter(\.isReady)
        guard !readyDots.isEmpty else {
            return "No ready sensors"
        }
        if readyDots.count >= 2 && !readyDots.allSatisfy(\.isSynced) {
            return "Sensors not synced"
        }
        if readyDots.contains(where: \.isRecording) {
            return "Sensor already recording"
        }
        return nil
    }

    // MARK: - Resync Preconditions

    /// Validates whether a resync can start for the given runner state.
    static func validateResync(
        currentPhase: SessionPhase,
        anySyncActive: Bool,
        readyDotCount: Int
    ) -> String? {
        guard currentPhase == .idle else {
            return "Runner is not idle (\(currentPhase))"
        }
        guard !anySyncActive else {
            return "Another runner is syncing"
        }
        guard readyDotCount >= 2 else {
            return "Need 2+ ready sensors (have \(readyDotCount))"
        }
        return nil
    }

    // MARK: - Connect Path Selection

    /// Determines which initialization path to take after BLE connect succeeds.
    static func determineConnectPath(
        syncInProgress: Bool,
        isSyncingUuid: Bool,
        isInConnectQueue: Bool,
        isConnectInProgress: Bool,
        hasDot: Bool
    ) -> ConnectPath {
        if syncInProgress && isSyncingUuid {
            return .syncReconnect
        }
        if isInConnectQueue && !isConnectInProgress {
            return .queuedButNotActive
        }
        if hasDot && !isConnectInProgress && !isInConnectQueue {
            return .autoReconnect
        }
        let settleDelay: TimeInterval = hasDot ? 2.0 : 0
        return .normalConnect(settleDelay: settleDelay)
    }

    // MARK: - Sync Result Parsing

    /// Identifier for matching sync results back to dots.
    struct DotIdentifier {
        let address: String
        let macAddress: String
    }

    /// Parses the raw SDK sync results array into a typed SyncResult.
    static func parseSyncResults(
        rawResults: [[String: Any]]?,
        dots: [DotIdentifier]
    ) -> DotManager.SyncResult {
        guard let results = rawResults else {
            let allUuids = Set(dots.map(\.address))
            return DotManager.SyncResult(
                allSuccess: false,
                succeededUuids: [],
                failedUuids: allUuids,
                errorMsg: "Sync failed — no results from SDK."
            )
        }

        var succeededUuids = Set<String>()
        var failedUuids = Set<String>()

        for result in results {
            let addr = (result["address"] as? String) ?? "?"
            let success = (result["success"] as? Bool) ?? false

            if let dot = dots.first(where: { $0.macAddress == addr || $0.address == addr }) {
                if success {
                    succeededUuids.insert(dot.address)
                } else {
                    failedUuids.insert(dot.address)
                }
            }
        }

        // Dots not in results at all count as failed
        for dot in dots where !succeededUuids.contains(dot.address) && !failedUuids.contains(dot.address) {
            failedUuids.insert(dot.address)
        }

        let allSuccess = failedUuids.isEmpty
        let errorMsg = allSuccess ? nil : "\(failedUuids.count) of \(dots.count) sensors failed to sync."
        return DotManager.SyncResult(
            allSuccess: allSuccess,
            succeededUuids: succeededUuids,
            failedUuids: failedUuids,
            errorMsg: errorMsg
        )
    }

    // MARK: - Phase Transition Side Effects

    /// Computes what should change when a runner's phase transitions.
    struct PhaseTransitionEffects {
        let syncInProgress: Bool
        let shouldClearSyncingUuids: Bool
        let shouldClearExportCart: Bool
        let shouldPurgeStaleConnections: Bool
    }

    static func computePhaseEffects(
        newPhase: SessionPhase,
        allPhases: [String: SessionPhase]
    ) -> PhaseTransitionEffects {
        // After updating the target runner, check if any runner is still sync-active
        let syncInProgress = allPhases.values.contains { $0.isSyncActive }
        let shouldClearSyncingUuids = !newPhase.isSyncActive
        let shouldClearExportCart = newPhase == .recording
        let shouldPurgeStaleConnections = newPhase == .idle

        return PhaseTransitionEffects(
            syncInProgress: syncInProgress,
            shouldClearSyncingUuids: shouldClearSyncingUuids,
            shouldClearExportCart: shouldClearExportCart,
            shouldPurgeStaleConnections: shouldPurgeStaleConnections
        )
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
    /// Exposed read-only for `ExportManager` to share the same serial queue.
    let sdkQueue = DispatchQueue(label: "DotManager.sdkQueue", qos: .userInitiated)

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
    /// Shadow copy on stateQueue. Source of truth for phase logic.
    private var runnerPhasesInternal: [String: SessionPhase] = [:]
    /// Published for SwiftUI. Updated on main thread from runnerPhasesInternal.
    @Published private(set) var runnerPhases: [String: SessionPhase] = [:]

    /// Internal busy check — must be called on stateQueue.
    private var isBusyInternal: Bool {
        registry.syncInProgress
        || runnerPhasesInternal.values.contains {
            switch $0 {
            case .syncing, .startingRecording, .recording, .stoppingRecording:
                return true
            default:
                return false
            }
        }
    }

    /// Aggregate phase across all runners. Used by views that need a single "is the system busy" answer.
    var sessionPhase: SessionPhase {
        Self.aggregateSessionPhase(from: runnerPhases)
    }

    /// Pure function that reduces per-runner phases into a single aggregate phase.
    /// Extracted so it can be unit-tested without instantiating DotManager.
    static func aggregateSessionPhase(from phases: [String: SessionPhase]) -> SessionPhase {
        let p = phases.values
        if p.contains(.syncing) { return .syncing }
        if p.contains(.startingRecording) { return .startingRecording }
        if p.contains(.stoppingRecording) { return .stoppingRecording }
        if p.contains(.recording) { return .recording }
        if let e = p.first(where: { $0.isError }) { return e }
        return .idle
    }
    /// True when any runner is in a syncing phase. Used to disable start buttons on other runners.
    var isAnySyncing: Bool {
        runnerPhases.values.contains { $0.isSyncActive }
    }

    // MARK: - State Hierarchy
    //
    // DotManager.isBusy (UI gate — blocks export, erase, connect, scan)
    // ├── isAnySyncing (runnerPhases contains .syncing)
    // └── runnerPhases contains .startingRecording / .recording / .stoppingRecording
    //
    // DotManager.isBusyInternal (stateQueue gate — blocks refreshStorage, flash timers)
    // ├── registry.syncInProgress (also used for sync-specific reconnect suppression)
    // └── runnerPhasesInternal contains active phases
    //
    // DotManager.isErasing (derived from connectedDots — blocks export, recording start)
    // DotManager.hasFlashIssue (derived — blocks recording start, shows banners)
    //   └── isAnyErasingFromPreviousSession (subset — distinguishes "finishing erase" from "corrupted")

    /// True when any operation requires exclusive BLE access.
    /// Covers: syncing, recording, starting, stopping.
    /// All BLE entry points (export, flash refresh, erase) must check this.
    var isBusy: Bool {
        runnerPhases.values.contains {
            switch $0 {
            case .syncing, .startingRecording, .recording, .stoppingRecording:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var hasPendingConnections: Bool = false

    /// Derived from per-Dot erase state — self-healing, no manual set/clear needed.
    var isErasing: Bool { connectedDots.contains { $0.isErasing } }

    var hasFlashIssue: Bool {
        connectedDots.contains { $0.flashCorrupted || $0.isErasingFromPreviousSession }
    }

    /// Separate from hasFlashIssue because UI shows different banners/colors
    /// for "actively finishing erase from prior session" vs "flash is corrupted."
    /// FlashIssueBanner uses this to choose "Finishing Erase..." vs "Storage Needs Repair."
    var isAnyErasingFromPreviousSession: Bool {
        connectedDots.contains { $0.isErasingFromPreviousSession }
    }

    @Published var selectedOutputRate: Int = 120
    @Published var selectedFilterIndex: Int = 0
    

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
            if self.registry.hasErasingFromPreviousSession { return }
            if self.registry.syncInProgress {
                print("🔍 Scan skipped — sync in progress")
                return
            }

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
            guard !self.registry.syncInProgress else {
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

    /// Start a recording session for a specific runner.
    ///
    /// Start recording on a runner's sensors. All sensors with 2+ dots must
    /// already be synced — call `resyncRunner(runnerId:)` first if needed.
    ///
    /// Flow: `idle` → `startingRecording` → `recording`
    func beginSession(runnerId: String) {
        stateQueue.async {
            let currentPhase = self.runnerPhasesInternal[runnerId] ?? .idle
            guard currentPhase == .idle || currentPhase.isError else { return }

            guard self.registry.connectQueue.isEmpty && self.registry.connectInProgress == nil else {
                print("⛔ beginSession(\(runnerId)) blocked — connections still pending (queue=\(self.registry.connectQueue.count), inProgress=\(self.registry.connectInProgress ?? "nil"))")
                return
            }

            guard let runner = RunnerStore.shared.runner(forId: runnerId) else {
                print("⛔ beginSession(\(runnerId)) — runner not found")
                return
            }

            let dots = runner.sensorUuids.compactMap { uuid -> Dot? in
                guard let dotState = self.registry.byUuid[uuid],
                      dotState.connectionPhase == .ready,
                      let dot = dotState.dot else { return nil }
                return dot
            }
            guard !dots.isEmpty else { return }

            // Guard: multi-sensor groups must be synced before recording
            if dots.count >= 2 && !dots.allSatisfy({ $0.device.isSynced() }) {
                print("⛔ beginSession(\(runnerId)) blocked — sensors not synced")
                return
            }

            // Guard: none of these sensors are already recording
            for dot in dots where dot.isRecording {
                print("⛔ beginSession(\(runnerId)) blocked — sensor \(dot.address) is already recording")
                self.setPhase(.error("Sensor \(dot.address) is already recording."), forRunner: runnerId)
                return
            }

            print("▶️ beginSession(\(runnerId)): \(dots.count) dot(s) ready")
            for dot in dots {
                let uuid = dot.address
                let phase = self.registry.byUuid[uuid]?.connectionPhase ?? .idle
                print("   [\(uuid)] phase=\(phase) isInitialized=\(dot.device.isInitialized()) isRecording=\(dot.isRecording)")
            }

            let outputRate = self.selectedOutputRate
            let filterIndex = self.selectedFilterIndex
            for dot in dots {
                dot.configure(outputRate: outputRate, filterIndex: filterIndex)
            }

            self.performStartRecording(dots: dots, runnerId: runnerId)
        }
    }

    /// Stop the recording session for a specific runner.
    ///
    /// Flow: `recording` → `stoppingRecording` → `idle`
    func endSession(runnerId: String) {
        stateQueue.async {
            guard self.runnerPhasesInternal[runnerId] == .recording else { return }

            guard let runner = RunnerStore.shared.runner(forId: runnerId) else { return }
            let dots = runner.sensorUuids.compactMap { uuid -> Dot? in
                guard let dot = self.registry.dot(forUuid: uuid),
                      dot.isConnected else { return nil }
                let phase = self.registry.byUuid[uuid]?.connectionPhase
                guard phase == .ready else {
                    print("⏭️ [\(uuid)] Still initializing — skipping stop")
                    return nil
                }
                return dot
            }

            self.setPhase(.stoppingRecording, forRunner: runnerId)

            self.operations.runAll(
                dots: dots,
                operation: { dot, done in
                    let liveStatus = dot.device.recording.recordingStatus
                    guard liveStatus == .isRecording else {
                        print("⏭️ [\(dot.address)] SDK recordingStatus=\(liveStatus.rawValue) — skipping stop")
                        DispatchQueue.main.async { dot.syncRecordingState() }
                        done(true)
                        return
                    }
                    dot.stopRecording(completion: done)
                }
            ) { [weak self] success in
                guard let self else { return }
                self.stateQueue.async {
                    if success {
                        
                        self.setPhase(.idle, forRunner: runnerId)
                        // Settle delay — sensor needs time to finalize flash
                        // after stopping a resumed recording
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.stateQueue.async {
                                guard let self, !self.isBusyInternal else { return }
                                for dot in dots {
                                    dot.getFlashInfo { _ in }
                                }
                            }
                        }
                    } else {
                        self.setPhase(.error("Failed to stop recording. Please try again."), forRunner: runnerId)
                    }
                }
            }
        }
    }

    /// Clear an error state for a specific runner, returning to `idle` so the user can retry.
    func dismissError(runnerId: String) {
        stateQueue.async {
            if self.runnerPhasesInternal[runnerId]?.isError == true {
                self.setPhase(.idle, forRunner: runnerId)
            }
        }
    }

    // MARK: - Resync

    /// Whether a specific runner can be resynced right now.
    func canResync(runnerId: String) -> Bool {
        let phase = runnerPhases[runnerId] ?? .idle
        guard phase == .idle else { return false }
        guard !isAnySyncing else { return false }
        guard let runner = RunnerStore.shared.runner(forId: runnerId) else { return false }
        let connectedCount = runner.sensorUuids.filter { uuid in
            connectedDots.contains { $0.address == uuid && $0.connectionPhase == .ready }
        }.count
        return connectedCount >= 2
    }

    /// Re-synchronize clocks for a runner's sensors without starting recording.
    /// Available when the runner is idle and has 2+ connected sensors.
    func resyncRunner(runnerId: String) {
        stateQueue.async {
            let currentPhase = self.runnerPhasesInternal[runnerId] ?? .idle
            guard currentPhase == .idle else { return }
            guard !self.runnerPhasesInternal.values.contains(where: { $0.isSyncActive }) else { return }

            guard let runner = RunnerStore.shared.runner(forId: runnerId) else { return }

            let dots = runner.sensorUuids.compactMap { uuid -> Dot? in
                guard let dotState = self.registry.byUuid[uuid],
                      dotState.connectionPhase == .ready,
                      let dot = dotState.dot else { return nil }
                return dot
            }
            guard dots.count >= 2 else { return }

            self.setPhase(.syncing, forRunner: runnerId)
            self.registry.syncingUuids.formUnion(dots.map { $0.device.uuid })

            self.performSync(dots: dots, runnerId: runnerId) { [weak self] result in
                guard let self else { return }
                self.stateQueue.async {
                    // setPhase handles syncInProgress and syncingUuids cleanup.
                    if result.allSuccess {
                        self.setPhase(.idle, forRunner: runnerId)
                    } else {
                        self.setPhase(.error(result.errorMsg ?? "Sync failed"), forRunner: runnerId)
                        print("❌ Resync failed for runner \(runnerId): \(result.errorMsg ?? "unknown")")
                    }

                    // Refresh storage for sensors that are still connected.
                    // After a failed sync the SDK has already reconnected the
                    // devices, so they remain at .ready — no need to reset their
                    // connection state. The runner's .error phase prompts the user
                    // to retry.
                    let connectedDots = dots.filter {
                        self.registry.byUuid[$0.address]?.connectionPhase == .ready
                    }
                    if !connectedDots.isEmpty {
                        self.refreshStorage(dots: connectedDots)
                    }
                }
            }
        }
    }

    /// Restore `.recording` phase for runners whose sensors are still recording.
    ///
    /// Called from `SyncView.onAppear` when the manager is idle but one or
    /// more dots report `isRecording == true` (the sensors kept recording while
    /// the app was killed).
    func resumeRecordingSession() {
        stateQueue.async {
            for dot in self.registry.connectedDots where dot.isRecording {
                if let runner = RunnerStore.shared.runner(forSensorUuid: dot.address) {
                    let phase = self.runnerPhasesInternal[runner.id] ?? .idle
                    if phase == .idle {
                        self.setPhase(.recording, forRunner: runner.id)
                    }
                }
            }
        }
    }

    // MARK: - Single-Runner Convenience

    /// Fixed runner ID used in single-runner mode.
    static let singleRunnerID = "__single__"

    /// Single-runner mode: creates an ephemeral runner from all ready connected
    /// sensors, then delegates to `beginSession(runnerId:)`.
    func beginSession() {
        stateQueue.async {
            let readyUuids = self.registry.connectedDots
                .filter { self.registry.byUuid[$0.address]?.connectionPhase == .ready }
                .map { $0.address }
            guard !readyUuids.isEmpty else { return }

            DispatchQueue.main.async {
                RunnerStore.shared.setRunner(
                    Runner(id: Self.singleRunnerID, label: "Session", sensorUuids: readyUuids)
                )
                self.beginSession(runnerId: Self.singleRunnerID)
            }
        }
    }

    /// Single-runner mode: stops the ephemeral session.
    func endSession() {
        endSession(runnerId: Self.singleRunnerID)
    }

    /// Single-runner mode: clears the error on the ephemeral runner.
    func dismissError() {
        dismissError(runnerId: Self.singleRunnerID)
    }

    /// Single-runner mode: creates/updates the ephemeral runner, then syncs its sensors.
    /// Does NOT start recording — the user must tap "Start Recording" separately.
    func syncSession() {
        stateQueue.async {
            let readyUuids = self.registry.connectedDots
                .filter { self.registry.byUuid[$0.address]?.connectionPhase == .ready }
                .map { $0.address }
            guard readyUuids.count >= 2 else { return }

            DispatchQueue.main.async {
                RunnerStore.shared.setRunner(
                    Runner(id: Self.singleRunnerID, label: "Session", sensorUuids: readyUuids)
                )
                self.resyncRunner(runnerId: Self.singleRunnerID)
            }
        }
    }

    /// Promotes the `__single__` runner to a real runner with a new UUID.
    /// Transfers any active session phase to the new runner ID.
    /// Must be called on the **main thread** (mutates RunnerStore).
    func promoteSingleRunner(to newId: String, label: String) {
        let store = RunnerStore.shared
        guard let single = store.runner(forId: Self.singleRunnerID) else { return }

        // Replace __single__ with the real runner in the store.
        store.setRunner(Runner(id: newId, label: label, sensorUuids: single.sensorUuids))
        store.removeRunner(id: Self.singleRunnerID)

        // Transfer session phase on stateQueue.
        stateQueue.async {
            if let phase = self.runnerPhasesInternal.removeValue(forKey: Self.singleRunnerID) {
                self.runnerPhasesInternal[newId] = phase
            }
            let snapshot = self.runnerPhasesInternal
            DispatchQueue.main.async { self.runnerPhases = snapshot }
            self.notify()
        }
    }

    // MARK: - Session Helpers

    /// Single writer for per-runner session phase. Must be called on `stateQueue`.
    ///
    /// Also keeps `registry.syncInProgress` in lockstep — the registry flag is
    /// read by `dequeueNextConnection` to block new connections during sync, and
    /// is cheaper to check than dispatching to main for the published property.
    private func setPhase(_ phase: SessionPhase, forRunner runnerId: String) {
        runnerPhasesInternal[runnerId] = phase
        registry.syncInProgress = runnerPhasesInternal.values.contains { $0.isSyncActive }
        if !phase.isSyncActive {
            let sensorUuids = Set(RunnerStore.shared.runner(forId: runnerId)?.sensorUuids ?? [])
            registry.syncingUuids.subtract(sensorUuids)
        }
        // Clear stale export cart when a new recording begins.
        if phase == .recording {
            DispatchQueue.main.async {
                ExportManager.shared.clearCart()
                ExportManager.shared.resetExport()
            }
        }
        // Safety net: when returning to idle, purge connection-tracking entries
        // for devices that are already connected. Prevents stale hasPendingConnections
        // from blocking the UI after edge-case races.
        if phase == .idle {
            registry.connectQueue.removeAll { uuid in
                registry.byUuid[uuid]?.connectionPhase.isConnected == true
            }
            if let ip = registry.connectInProgress,
               registry.byUuid[ip]?.connectionPhase.isConnected == true {
                registry.connectInProgress = nil
            }
        }

        let snapshot = runnerPhasesInternal
        DispatchQueue.main.async {
            self.runnerPhases = snapshot
        }
        notify()
    }

    /// Synchronize sensor clocks via `DotSyncManager`. Must be called on `stateQueue`.
    ///
    /// The SDK internally disconnects and reconnects each device during sync;
    /// delegate methods suppress those events when `isSyncActive` is true.
    /// Completion is dispatched back to `stateQueue`.
    /// Result of a sync operation, with per-sensor success info.
    struct SyncResult {
        let allSuccess: Bool
        let succeededUuids: Set<String>
        let failedUuids: Set<String>
        let errorMsg: String?
    }

    private func performSync(dots: [Dot], runnerId: String, completion: @escaping (SyncResult) -> Void) {
        // Snapshot device references now (on stateQueue) before sync mutates anything.
        // The registry freezes these references while syncInProgress is true.
        let devices = dots.map { $0.device }
        print("🔄 Starting sync with \(devices.count) devices...")

        sdkQueue.async { [weak self] in
            guard let self else { return }

            // If already synced from before, stop first to handle the edge case.
            for device in devices where device.isSynced() {
                print("⚠️ [\(device.uuid)] Already synced — stopping before re-sync")
                DotSyncManager.stopSync([device])
            }

            for device in devices {
                print("🔍 [PRE-SYNC] \(device.uuid): isInitialized=\(device.isInitialized())")
            }

            DotSyncManager.startSync(devices) { results in
                self.stateQueue.async {
                    guard let results = results as? [[String: Any]] else {
                        print("❌ Sync failed - no results")
                        dots.forEach { $0.refreshSyncStatus() }
                        let allUuids = Set(dots.map { $0.address })
                        completion(SyncResult(allSuccess: false, succeededUuids: [], failedUuids: allUuids, errorMsg: "Sync failed — no results from SDK."))
                        return
                    }

                    var succeededUuids = Set<String>()
                    var failedUuids = Set<String>()

                    for result in results {
                        let addr = (result["address"] as? String) ?? "?"
                        let status = (result["status"] as? Int) ?? -1
                        let success = (result["success"] as? Bool) ?? false
                        let done = (result["doneSuccess"] as? Int) ?? -1
                        print("🔄 [SYNC RESULT] \(addr): status=\(status) success=\(success) doneSuccess=\(done)")

                        // Match result address back to dot UUID
                        if let dot = dots.first(where: { $0.device.macAddress == addr || $0.address == addr }) {
                            if success {
                                succeededUuids.insert(dot.address)
                            } else {
                                failedUuids.insert(dot.address)
                            }
                        }
                    }

                    // Any dots not in results at all count as failed
                    for dot in dots where !succeededUuids.contains(dot.address) && !failedUuids.contains(dot.address) {
                        failedUuids.insert(dot.address)
                    }

                    let allSuccess = failedUuids.isEmpty
                    dots.forEach { $0.refreshSyncStatus() }

                    if allSuccess {
                        print("✅ Sync completed")
                    } else {
                        print("❌ Sync failed — \(failedUuids.count) of \(dots.count) devices")
                    }

                    // NOTE: refreshStorage is NOT called here. The caller is responsible
                    // for calling it on successful sensors AFTER cleaning up syncingUuids.

                    let errorMsg = allSuccess ? nil : "\(failedUuids.count) of \(dots.count) sensors failed to sync. Please try again."
                    completion(SyncResult(allSuccess: allSuccess, succeededUuids: succeededUuids, failedUuids: failedUuids, errorMsg: errorMsg))
                }
            }
        }
    }

    /// Issue start-recording to each dot sequentially. Must be called on `stateQueue`.
    /// `0xFFFF` tells the sensor to record indefinitely until explicitly stopped.
    private func performStartRecording(dots: [Dot], runnerId: String) {
        setPhase(.startingRecording, forRunner: runnerId)
        print("🎙️ performStartRecording(\(runnerId)): \(dots.map { $0.address })")

        operations.runAll(
            dots: dots,
            operation: { dot, done in dot.startRecording(seconds: 0xFFFF, completion: done) }
        ) { [weak self] success in
            guard let self else { return }
            self.stateQueue.async {
                if success {
                    self.setPhase(.recording, forRunner: runnerId)
                } else {
                    self.setPhase(.error("Recording failed to start. Please try again."), forRunner: runnerId)
                }
            }
        }
    }

    // MARK: - Flash Storage

    /// Erase recorded data on every connected sensor. Only allowed when idle.
    func eraseAllFlash(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            guard self.runnerPhasesInternal.values.allSatisfy({ $0 == .idle || $0.isError }) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.registry.connectedDots

            self.operations.runAll(
                dots: dotsSnapshot,
                operation: { dot, done in dot.eraseFlash(completion: done) },
                completion: { success in
                    completion(success)
                }
            )
        }
    }

    // MARK: - Internal Helpers

    /// Reset erase-related flags and install the erase-state-change callback on a
    /// freshly (re)connected dot. Called from each path in `onDeviceConnectSucceeded`.
    private func resetEraseState(_ dot: Dot) {
        dot.onEraseStateChanged = { [weak self] in
            self?.stateQueue.async { self?.notify() }
        }
        setOnMain {
            dot.isErasing = false
            dot.isErasingFromPreviousSession = false
            dot.flashCorrupted = false
        }
    }

    /// Dequeue the next device and issue a connect call. Must be called on `stateQueue`.
    private func processConnectQueue() {
        guard let device = registry.dequeueNextConnection() else { return }
        print("🔗 Connecting to \(displayAddress(for: device))")

        sdkQueue.async {
            DotConnectionManager.connect(device)
        }
    }

    /// Fetch flash usage for each dot after sync or connection. Must be called on `stateQueue`.
    private func refreshStorage(dots: [Dot], settleDelay: TimeInterval = 0) {
        guard !isBusyInternal else {
            print("💾 Storage refresh skipped — system busy")
            return
        }
        operations.refreshStorage(dots: dots, settleDelay: settleDelay) { [weak self] dot, success in
            self?.stateQueue.async {
                guard let self else { return }
                let uuid = dot.device.uuid

                self.registry.initializationInProgress.remove(uuid)

                guard success else {
                    // Flash info timed out — check if the sensor is mid-erase.
                    // The SDK won't respond to flash queries while erasing, so the
                    // timeout is expected. Check the recording status property directly.
                    let recStatus = dot.device.recording.recordingStatus
                    print("⚠️ [\(uuid)] Flash info failed — recordingStatus=\(recStatus.rawValue)")

                    if recStatus == .isErasing {
                        print("⏳ [\(uuid)] Sensor is mid-erase — marking .ready and polling")
                        self.registry.setConnectionPhase(uuid, .ready)
                        dot.refreshBattery()
                        dot.refreshSyncStatus()
                        setOnMain { dot.isErasingFromPreviousSession = true }
                        dot.startErasePollFromManager()
                        self.notify()
                        return
                    }

                    if recStatus == .isRecording {
                        print("⏳ [\(uuid)] Flash timeout but sensor is recording — recovering to .ready")
                        self.registry.setConnectionPhase(uuid, .ready)
                        dot.refreshSyncStatus()

                        if let runner = RunnerStore.shared.runner(forSensorUuid: uuid) {
                            let phase = self.runnerPhasesInternal[runner.id] ?? .idle
                            if phase == .idle || phase.isError {
                                print("🔄 [\(uuid)] Restoring .recording for runner \(runner.id)")
                                self.setPhase(.recording, forRunner: runner.id)
                            }
                        }
                        self.notify()
                        return
                    }

                    print("⚠️ [\(uuid)] Init failed — not marking .ready")
                    self.registry.setConnectionPhase(uuid, .failed("Initialization timed out"))
                    self.notify()
                    return
                }

                self.registry.setConnectionPhase(uuid, .ready)
                print("✅ [\(uuid)] phase now .ready")
                dot.refreshBattery()
                dot.refreshSyncStatus()

                // Re-query actual recording state after reconnect.
                // SDK does not push this automatically, so isRecording stays stale otherwise.
                dot.refreshRecordingStatus()

                self.notify()
            }
        } completion: {}
    }

    /// Check if a sensor is still recording after reconnect and either skip
    /// flash queries (recording sensors won't respond) or run the normal
    /// `refreshStorage` path. Must be called on `stateQueue`.
    ///
    /// Uses `checkRecordingStatus(completion:)` which waits for the SDK callback
    /// before returning — avoids the race where `refreshRecordingStatus()` is async
    /// and `isRecording` hasn't updated by the time we check it.
    private func initializeAfterConnect(dot: Dot, settleDelay: TimeInterval = 0) {
        let uuid = dot.address

        dot.checkSensorActivity { [weak self] activity in
            guard let self else { return }
            self.stateQueue.async {

                switch activity {
                case .recording:
                    print("⏳ [\(uuid)] Still recording — skipping flash query")
                    self.registry.initializationInProgress.remove(uuid)
                    self.registry.setConnectionPhase(uuid, .ready)
                    dot.refreshSyncStatus()
                    print("✅ [\(uuid)] phase now .ready (recording device, flash skipped)")

                    if let runner = RunnerStore.shared.runner(forSensorUuid: uuid) {
                        let phase = self.runnerPhasesInternal[runner.id] ?? .idle
                        if phase == .idle || phase.isError {
                            print("🔄 [\(uuid)] Restoring .recording for runner \(runner.id)")
                            self.setPhase(.recording, forRunner: runner.id)
                        }
                    }
                    self.notify()

                case .erasing:
                    print("⏳ [\(uuid)] Still erasing from previous session — skipping flash query")
                    self.registry.initializationInProgress.remove(uuid)
                    self.registry.setConnectionPhase(uuid, .ready)
                    dot.refreshSyncStatus()
                    print("✅ [\(uuid)] phase now .ready (erasing device, flash skipped)")
                    dot.refreshBattery()
                    setOnMain { dot.isErasingFromPreviousSession = true }
                    dot.startErasePollFromManager()
                    self.notify()

                case .idle:
                    self.refreshStorage(dots: [dot], settleDelay: settleDelay)
                }
            }
        }
    }

    /// Snapshot registry state and push it to `@Published` properties on the main thread.
    /// Must be called on `stateQueue`.
    private func notify() {
        let scanning = registry.isScanningInternal
        let disc = registry.discovered
        let all = registry.dots
        let connected = registry.connectedDots
        let pending = !registry.connectQueue.isEmpty || registry.connectInProgress != nil

        DispatchQueue.main.async {
            self.isScanning = scanning
            self.discovered = disc
            self.dots = all
            self.connectedDots = connected
            self.hasPendingConnections = pending
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
            // Only suppress sensors that are part of the active sync operation.
            if self.registry.syncInProgress && self.registry.syncingUuids.contains(device.uuid) {
                self.registry.recordReconnection(device)
                return
            }

            // Device connected while still queued but not yet being actively
            // connected (e.g. SDK auto-reconnect fired before we dequeued it).
            // Remove from queue to prevent double-processing, then use the
            // lightweight path. Do NOT call advanceConnectQueue() since this
            // device was not connectInProgress.
            if self.registry.connectQueue.contains(device.uuid)
                && self.registry.connectInProgress != device.uuid {
                self.registry.connectQueue.removeAll { $0 == device.uuid }
                print("🔄 [\(device.uuid)] Connected while still queued — treating as auto-reconnect")

                self.registry.recordReconnection(device)
                self.registry.setConnectionPhase(device.uuid, .initializing)

                self.sdkQueue.async {
                    DotDevicePool.bindDevice(device)
                }

                if let dot = self.registry.dot(forUuid: device.uuid) {
                    self.resetEraseState(dot)
                    self.initializeAfterConnect(dot: dot)
                }
                self.notify()
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
                    self.resetEraseState(dot)
                    self.initializeAfterConnect(dot: dot)
                }
                self.notify()
                return
            }

            // Detect a BT-reset reconnect: the Dot model already exists (device
            // previously connected) but went through the normal connect queue
            // because onManagerStateUpdate(.poweredOn) re-queued the UUID.
            // In this case bindDevice() causes isInitialized() to return true
            // before the SDK finishes its internal BLE handshake, so we need a
            // settle delay before calling getFlashInfo.
            let isReconnect = self.registry.byUuid[device.uuid]?.dot != nil
            let settleDelay: TimeInterval = isReconnect ? 2.0 : 0

            // recordConnection sets phase to .initializing
            self.registry.recordConnection(device)
            print("🔗 [\(device.uuid)] phase now .initializing")

            self.sdkQueue.async {
                DotDevicePool.bindDevice(device)
            }

            if let dot = self.registry.dot(forUuid: device.uuid) {
                self.resetEraseState(dot)
                self.initializeAfterConnect(dot: dot, settleDelay: settleDelay)

                self.registry.advanceConnectQueue(expect: device.uuid)
                self.processConnectQueue()
                self.notify()
            }
        }
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        print("❌ Connect failed: \(device.uuid)")
        stateQueue.async {
            // During sync the SDK manages connections itself — don't interfere
            // with sensors that are part of the active sync operation.
            if self.registry.syncInProgress && self.registry.syncingUuids.contains(device.uuid) { return }
            self.cancelConnectTimer(device.uuid)
            self.registry.setConnectionPhase(device.uuid, .failed("Connection failed"))
            self.registry.advanceConnectQueue(expect: device.uuid)
            self.processConnectQueue()
            self.notify()
        }
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        print("⛓️‍💥 Disconnected: \(device.uuid)")
        stateQueue.async {
            if self.registry.syncInProgress && self.registry.syncingUuids.contains(device.uuid) {
                // SDK-managed disconnect during sync — ignore entirely.
                // The dots remain visually "connected" throughout the sync process.
                return
            }

            self.registry.recordDisconnection(device.uuid)

            // If this sensor belonged to a recording runner and no sensors
            // in that runner are still connected, move the runner to error.
            for (runnerId, phase) in self.runnerPhasesInternal where phase == .recording || phase == .syncing || phase == .startingRecording {
                guard let runner = RunnerStore.shared.runner(forId: runnerId) else { continue }
                guard runner.sensorUuids.contains(device.uuid) else { continue }
                let hasConnected = runner.sensorUuids.contains { uuid in
                    self.registry.byUuid[uuid]?.connectionPhase.isConnected == true
                }
                if !hasConnected {
                    self.setPhase(.error("All sensors disconnected."), forRunner: runnerId)
                }
            }

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
                    // Start timers for every queued UUID so a silent connect failure
                    // doesn't leave connectInProgress stuck forever.
                    for uuid in self.registry.connectQueue {
                        self.startConnectTimer(uuid)
                    }
                    // Use the persisted DotDevice from byUuid immediately — no need
                    // to wait for onDiscover. startScan runs in parallel as a fallback
                    // in case the stored reference is stale.
                    self.processConnectQueue()
                    self.startScan()
                }

            case .poweredOff, .resetting:
                print("⚠️ Bluetooth powered OFF/RESET")
                self.cancelAllConnectTimers()
                self.registry.clearBusyFlags()
                self.registry.markAllDisconnected()
                for (runnerId, phase) in self.runnerPhasesInternal where phase != .idle {
                    self.setPhase(.error("Bluetooth disconnected."), forRunner: runnerId)
                }

            case .unauthorized, .unsupported:
                print("❌ Bluetooth Error: \(managerState.rawValue)")

            @unknown default:
                break
            }
        }
    }
}

