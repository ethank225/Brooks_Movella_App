import Foundation
import MovellaDotSdk
import Combine

/// Observable wrapper around a Movella `DotDevice`.
///
/// Each `Dot` represents a single physical sensor. It publishes connection,
/// recording, sync, and storage state for SwiftUI binding, and exposes
/// methods that send commands to the underlying SDK device.
///
/// **Threading:** All `@Published` properties are set on the main thread
/// via `setOnMain(_:)`. Methods may be called from any thread.
final class Dot: ObservableObject, Identifiable {

    // MARK: - Identity

    /// The underlying SDK device. Updated on reconnect via `updateDevice(_:)`.
    private(set) var device: DotDevice

    /// The device's UUID, used as a stable identifier throughout the app.
    var address: String { device.uuid }
    var id: String { device.uuid }

    /// Centralized display name: custom name → last 3 MAC octets → last 4 UUID chars.
    var displayName: String {
        let uuid = device.uuid
        if let custom = SensorNameStore.shared.names[uuid] {
            return custom
        }
        let mac = device.macAddress
        if !mac.isEmpty {
            let octets = mac.split(separator: ":")
            if octets.count >= 3 {
                return octets.suffix(3).joined(separator: ":")
            }
        }
        return String(uuid.suffix(4))
    }

    // MARK: - Published State (UI-facing)

    @Published private(set) var connectionPhase: ConnectionPhase = .idle

    var isConnected: Bool { connectionPhase.isConnected }
    @Published var isRecording = false
    @Published var sessionSynced = false
    @Published var isErasing = false
    @Published private(set) var recordingFiles: [DotRecordingFile] = []

    /// Flash storage snapshot. Updated after connection, recording, and erase.
    /// We store our own copy because reading `device.usedSpace` / `device.totalSpace`
    /// at render time is unreliable — the SDK can mutate them between frames.
    @Published var flashCorrupted: Bool = false
    @Published var isErasingFromPreviousSession: Bool = false
    @Published private(set) var flashUsedBytes: Int = 0
    @Published private(set) var flashTotalBytes: Int = 1  // default 1 to avoid divide-by-zero
    @Published private(set) var batteryLevel: Int = 0

    var storagePercentageUsed: Double {
        guard flashTotalBytes > 0 else { return 0 }
        return (Double(flashUsedBytes) / Double(flashTotalBytes)) * 100.0
    }

    var batteryPercentage: Double { Double(batteryLevel) }
    
    var negotiatedMTU: Int {
        device.peripheral.maximumWriteValueLength(for: .withoutResponse)
    }

    // MARK: - SDK-Derived State (read-through to device)

    /// Whether the SDK has finished initializing this device after connection.
    var isInitialized: Bool { device.isInitialized() }

    /// Whether the SDK considers this device time-synced with the host.
    var isSynced: Bool { device.isSynced() }

    // MARK: - SDK Queue

    /// Serializes all SDK device calls. Shared with `DotManager.sdkQueue`.
    private let sdkQueue: DispatchQueue

    /// Single-flight guard for `getFlashInfo`. Accessed only on `sdkQueue`.
    private var flashInfoInFlight = false
    private var flashInfoWaiters: [(Bool) -> Void] = []

    /// One-shot completion for the next recording status query. Accessed only on `sdkQueue`.
    private var recordingStatusCompletion: ((Bool) -> Void)?

    /// Single-flight guard for `getExportFileInfo`. Accessed only on `sdkQueue`.
    private var exportFileInfoInFlight = false

    /// Erase-poll state for detecting mid-erase sensors. Accessed only on `sdkQueue`.
    private var erasePollCount = 0
    private var erasePollTimer: DispatchWorkItem?

    /// Called on main thread when erase state changes. Set by DotManager to trigger `notify()`.
    var onEraseStateChanged: (() -> Void)?

    /// Re-publishes when sensor names change so views pick up `displayName` updates.
    private var nameStoreSubscription: AnyCancellable?

    // MARK: - Init

    init(device: DotDevice, sdkQueue: DispatchQueue) {
        self.device = device
        self.sdkQueue = sdkQueue
        nameStoreSubscription = SensorNameStore.shared.$names
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        sdkQueue.async {
            self.installRecordingStatusHandler()
        }
    }

    /// Replace the underlying device reference (e.g. after SDK reconnects during sync).
    /// Re-installs the recording callback since the old device object is stale.
    func updateDevice(_ newDevice: DotDevice) {
        self.device = newDevice
        sdkQueue.async {
            self.installRecordingStatusHandler()
        }
        print("🔄 [\(address)] Device reference updated")
    }

    // MARK: - Recording Status Handler

    /// Installs a permanent callback on `device.recording` that keeps
    /// `isRecording` in sync with the SDK's push notifications.
    /// Called on init and after every device reference update.
    /// Must be called on `sdkQueue`.
    private func installRecordingStatusHandler() {
        let device = self.device
        device.recording.updateRecordingStatus = { [weak self] status in
            guard let self else { return }
            let isRec: Bool
            switch status {
            case .isRecording: isRec = true
            case .isRecordingStopped, .isIdle: isRec = false
            default: return
            }
            setOnMain { self.isRecording = isRec }
            // Fire one-shot completion if pending
            self.sdkQueue.async {
                if let cb = self.recordingStatusCompletion {
                    self.recordingStatusCompletion = nil
                    cb(isRec)
                }
            }
        }
    }

    // MARK: - Thread-safe Setters

    func setConnectionPhase(_ phase: ConnectionPhase) {
        setOnMain { self.connectionPhase = phase }
    }

    func setSessionSynced(_ value: Bool) {
        setOnMain { self.sessionSynced = value }
    }

    // MARK: - Commands

    /// Triggers a visual/haptic signal on the physical sensor for identification.
    func identify() {
        sdkQueue.async { self.device.startIdentifying() }
    }

    /// Sets the sensor's output rate and filter profile.
    func configure(outputRate: Int = 120, filterIndex: Int = 0) {
        let addr = address
        sdkQueue.async {
            self.device.setOutputRate(Int32(outputRate), filterIndex: Int32(filterIndex))
            print("⚙️ [\(addr)] Configured: \(outputRate)Hz, filter \(filterIndex)")
        }
    }

    /// Reads the device's sync state from the SDK and updates `sessionSynced`.
    func refreshSyncStatus() {
        sdkQueue.async {
            let synced = self.device.isSynced()
            setOnMain { self.sessionSynced = synced }
        }
    }

    /// Polls the SDK for the current recording state (push isn't always reliable).
    func refreshRecordingStatus() {
        sdkQueue.async { self.device.getRecordingStatus() }
    }

    enum SensorActivity { case idle, recording, erasing }

    /// Queries the SDK for current recording/erasing state and calls completion with the result.
    /// Completion fires on `sdkQueue`. Includes a 3s timeout (assumes idle on timeout).
    func checkSensorActivity(completion: @escaping (SensorActivity) -> Void) {
        sdkQueue.async {
            var hasCompleted = false

            // Check the property immediately — the SDK may already know the state
            // from the connection handshake before we even ask.
            let currentStatus = self.device.recording.recordingStatus
            print("🔎 [\(self.address)] recordingStatus at connect = \(currentStatus.rawValue)")
            if currentStatus == .isErasing {
                completion(.erasing)
                return
            }

            // Install one-shot for recording states (fired by installRecordingStatusHandler)
            self.recordingStatusCompletion = { isRec in
                guard !hasCompleted else { return }
                hasCompleted = true
                completion(isRec ? .recording : .idle)
            }

            self.device.getRecordingStatus()

            // The recording status handler ignores .isErasing, so re-check the property
            // after giving the SDK time to process the response.
            self.sdkQueue.asyncAfter(deadline: .now() + 0.5) {
                guard !hasCompleted else { return }
                let status = self.device.recording.recordingStatus
                print("🔎 [\(self.address)] recordingStatus after 0.5s = \(status.rawValue)")
                if status == .isErasing {
                    hasCompleted = true
                    self.recordingStatusCompletion = nil
                    completion(.erasing)
                }
            }

            // Timeout — if SDK doesn't respond, assume idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.sdkQueue.async {
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    self?.recordingStatusCompletion = nil
                    completion(.idle)
                }
            }
        }
    }

    /// Legacy wrapper for callers that only care about recording state.
    func checkRecordingStatus(completion: @escaping (Bool) -> Void) {
        checkSensorActivity { activity in
            completion(activity == .recording)
        }
    }

    // MARK: - Flash Storage

    /// Fetches flash usage from the SDK and updates `flashUsedBytes`/`flashTotalBytes`.
    ///
    /// **SDK quirk:** The completion callback often fires twice, with the second
    /// call sometimes reporting doubled values (e.g. 36% → 72%). A gatekeeper
    /// flag captures only the first result and ignores subsequent callbacks.
    func getFlashInfo(completion: @escaping (Bool) -> Void) {
        sdkQueue.async { [weak self] in
            guard let self else { return }

            if self.flashInfoInFlight {
                self.flashInfoWaiters.append(completion)
                return
            }
            self.flashInfoInFlight = true

            var hasCapturedResult = false

            self.device.setFlashInfoDoneBlock { [weak self] status in
                guard let self, !hasCapturedResult else { return }
                hasCapturedResult = true

                let used = Int(self.device.usedSpace)
                let total = Int(self.device.totalSpace)
                let abnormal = (status == .isUninitialized) || (used == 0 && total == 0)

                if abnormal {
                    // Check if sensor is mid-erase from a previous session
                    self.device.getRecordingStatus()

                    self.sdkQueue.async {
                        let recStatus = self.device.recording.recordingStatus
                        self.device.setFlashInfoDoneBlock(nil)
                        let waiters = self.flashInfoWaiters
                        self.flashInfoWaiters = []
                        self.flashInfoInFlight = false

                        if recStatus == .isErasing {
                            // Sensor still erasing — poll until done
                            self.setFlashSnapshot(usedBytes: 0, totalBytes: 1)
                            setOnMain {
                                self.isErasingFromPreviousSession = true
                                self.onEraseStateChanged?()
                            }
                            self.erasePollCount = 0
                            print("⏳ [\(self.address)] Sensor still erasing from previous session — waiting...")

                            completion(true)
                            waiters.forEach { $0(true) }
                            self.startErasePoll()
                        } else {
                            // Not erasing — truly corrupted
                            self.setFlashSnapshot(usedBytes: 0, totalBytes: 1)
                            setOnMain { self.flashCorrupted = true }
                            print("⚠️ [\(self.address)] Flash corrupted (status=\(status), recStatus=\(recStatus), \(used)/\(total)) — needs erase")

                            completion(true)
                            waiters.forEach { $0(true) }
                        }
                    }
                } else {
                    self.setFlashSnapshot(usedBytes: used, totalBytes: total)
                    setOnMain {
                        self.flashCorrupted = false
                        self.isErasingFromPreviousSession = false
                    }
                    print("💾 [\(self.address)] Snapshot: \(used)/\(total) (\(String(format: "%.1f", self.storagePercentageUsed))%)")

                    self.sdkQueue.async {
                        self.device.setFlashInfoDoneBlock(nil)
                        let waiters = self.flashInfoWaiters
                        self.flashInfoWaiters = []
                        self.flashInfoInFlight = false
                        completion(true)
                        waiters.forEach { $0(true) }
                    }
                }
            }

            self.device.getFlashInfo()

            // Safety timeout — the SDK sometimes doesn't fire the callback after reconnect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard !hasCapturedResult else { return }
                hasCapturedResult = true
                print("⏰ [\(self?.address ?? "?")] Flash info timed out")
                self?.sdkQueue.async {
                    self?.device.setFlashInfoDoneBlock(nil)
                    let waiters = self?.flashInfoWaiters ?? []
                    self?.flashInfoWaiters = []
                    self?.flashInfoInFlight = false
                    completion(false)
                    waiters.forEach { $0(false) }
                }
            }
        }
    }

    private func setFlashSnapshot(usedBytes: Int, totalBytes: Int) {
        let battery: Int = device.battery?.value ?? 0
        setOnMain {
            self.flashUsedBytes = usedBytes
            self.flashTotalBytes = max(totalBytes, 1)
            self.batteryLevel = battery
        }
    }

    /// Public entry point for `DotManager` to kick off erase polling after reconnect.
    /// Dispatches to `sdkQueue` so callers don't need to be on it.
    func startErasePollFromManager() {
        sdkQueue.async {
            self.erasePollCount = 0
            self.startErasePoll()
        }
    }

    /// Polls `recordingStatus` every 3s while sensor finishes a previous erase.
    /// Once the erase completes, reads flash info and clears the erasing flag.
    /// After 60 polls (~3 minutes), gives up and marks `flashCorrupted`.
    /// Must be called on `sdkQueue`.
    private func startErasePoll() {
        erasePollTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.erasePollCount += 1
            let attempt = self.erasePollCount
            print("🔄 [\(self.address)] Erase poll #\(attempt)")

            // Ask the SDK to refresh the recording status property
            self.device.getRecordingStatus()

            // Check the property after a short delay
            self.sdkQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let status = self.device.recording.recordingStatus
                print("🔄 [\(self.address)] recordingStatus=\(status.rawValue)")

                if status == .isErasing {
                    // Still erasing — check max attempts
                    if attempt >= 60 {
                        print("⚠️ [\(self.address)] Erase poll limit reached (3 min) — marking corrupted")
                        setOnMain {
                            self.isErasingFromPreviousSession = false
                            self.flashCorrupted = true
                            self.onEraseStateChanged?()
                        }
                    } else {
                        // Schedule next poll in 3 seconds
                        self.startErasePoll()
                    }
                } else {
                    // Erase finished — now flash queries will respond
                    print("✅ [\(self.address)] Erase completed — reading flash info")
                    self.getFlashInfo { [weak self] _ in
                        guard let self else { return }
                        setOnMain {
                            self.isErasingFromPreviousSession = false
                            self.flashCorrupted = false
                            self.onEraseStateChanged?()
                        }
                        print("✅ [\(self.address)] Flash recovered after erase")
                    }
                }
            }
        }

        erasePollTimer = work
        sdkQueue.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// Reads the current battery level from the SDK and publishes it.
    func refreshBattery() {
        let battery: Int = device.battery?.value ?? 0
        setOnMain { self.batteryLevel = battery }
    }

    // MARK: - Recording

    /// Starts recording on this sensor. Refreshes flash info first to ensure
    /// the device is ready, then issues the start command and polls until
    /// `isRecording` confirms the state change (up to 5s timeout).
    func startRecording(seconds: UInt16 = 0xFFFF, completion: @escaping (Bool) -> Void) {
        getFlashInfo { [weak self] success in
            guard let self else { completion(false); return }

            guard success, self.isInitialized else {
                print("❌ [\(self.address)] Cannot start recording (flashInfo=\(success) initialized=\(self.isInitialized))")
                completion(false)
                return
            }

            print("🎬 [\(self.address)] Starting recording...")
            self.sdkQueue.async {
                self.device.startRecording(seconds)
            }

            // Kick the SDK to report status, then poll until confirmed.
            self.sdkQueue.asyncAfter(deadline: .now() + 0.3) {
                self.device.getRecordingStatus()
            }

            self.waitForRecordingState(true, timeout: 10.0) { success in
                print(success
                      ? "🔴 [\(self.address)] Recording confirmed started"
                      : "❌ [\(self.address)] Recording did not start in time")
                completion(success)
            }
        }
    }

    /// Stops recording and refreshes flash info to capture the new usage.
    func stopRecording(completion: @escaping (Bool) -> Void) {
        print("⏹️ [\(address)] Stopping recording...")
        sdkQueue.async { self.device.stopRecording() }

        sdkQueue.asyncAfter(deadline: .now() + 0.3) {
            self.device.getRecordingStatus()
        }

        waitForRecordingState(false, timeout: 5.0) { [weak self] success in
            guard let self else { completion(false); return }
            if success {
                print("⏹️ [\(self.address)] Recording confirmed stopped")
                self.getFlashInfo { _ in }
            } else {
                print("❌ [\(self.address)] Recording did not stop in time")
            }
            completion(success)
        }
    }

    /// Polls `isRecording` every 0.3s until it matches `target` or times out.
    /// The SDK doesn't push recording state reliably, so we poll `getRecordingStatus()`
    /// and check the value that the recording status handler updates.
    private func waitForRecordingState(_ target: Bool, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let start = Date()

        func check() {
            self.sdkQueue.async {
                self.device.getRecordingStatus()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.isRecording == target {
                    completion(true)
                    return
                }
                if Date().timeIntervalSince(start) > timeout {
                    print("⏰ [\(self.address)] Timed out waiting for isRecording=\(target)")
                    completion(false)
                    return
                }
                check()
            }
        }
        check()
    }

    // MARK: - Export File Discovery

    /// Fetches the list of recorded files from the sensor's flash storage.
    ///
    /// Uses the same gatekeeper pattern as `getFlashInfo` to handle the SDK's
    /// double-firing callback. Populates `recordingFiles` on success.
    func getExportFileInfo(completion: @escaping (Bool) -> Void) {
        sdkQueue.async { [weak self] in
            guard let self else { return }

            if self.exportFileInfoInFlight {
                completion(false)
                return
            }
            self.exportFileInfoInFlight = true

            var hasCapturedResult = false

            self.device.setExportFileInfoDone { [weak self] _ in
                guard let self, !hasCapturedResult else { return }
                hasCapturedResult = true

                let files: [DotRecordingFile] = (self.device.recording.files as? [DotRecordingFile]) ?? []

                print("📁 [\(self.address)] Found \(files.count) recording files")
                for (i, f) in files.enumerated() {
                    print("   📄 [\(self.address)] listPos=\(i) size=\(f.fileSize) ts=\(f.timeStamap)")
                }
                
                setOnMain { self.recordingFiles = files }
                self.sdkQueue.async {
                    self.device.setExportFileInfoDone(nil)
                    self.exportFileInfoInFlight = false
                    completion(true)
                }
            }

            self.device.getExportFileInfo()

            // Safety timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                guard !hasCapturedResult else { return }
                hasCapturedResult = true
                print("⏰ [\(self?.address ?? "?")] Export file info timed out")
                self?.sdkQueue.async {
                    self?.device.setExportFileInfoDone(nil)
                    self?.exportFileInfoInFlight = false
                    completion(false)
                }
            }
        }
    }

    // MARK: - Erase

    /// Erases all recorded data on the sensor's flash storage.
    /// Refreshes the flash snapshot on completion.
    func eraseFlash(completion: @escaping (Bool) -> Void) {
        print("🗑️ [\(address)] Erasing flash...")
        setOnMain { self.isErasing = true }

        sdkQueue.async {
            self.device.setEraseDataDoneBlock { [weak self] success in
                let ok = success != 0
                print("🗑️ [\(self?.address ?? "?")] Erase: \(ok ? "success" : "failed")")
                setOnMain { self?.isErasing = false }
                if ok {
                    setOnMain {
                        self?.flashCorrupted = false
                        self?.isErasingFromPreviousSession = false
                    }
                    self?.sdkQueue.async { self?.erasePollTimer?.cancel() }
                }
                self?.getFlashInfo { _ in }
                completion(ok)
            }

            self.device.eraseData()
        }
    }
}

// MARK: - Equatable

extension Dot: Equatable {
    static func == (lhs: Dot, rhs: Dot) -> Bool {
        lhs.address == rhs.address
    }
}
