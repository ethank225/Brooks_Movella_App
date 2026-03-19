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
    @Published private(set) var flashUsedBytes: Int = 0
    @Published private(set) var flashTotalBytes: Int = 1  // default 1 to avoid divide-by-zero

    var storagePercentageUsed: Double {
        guard flashTotalBytes > 0 else { return 0 }
        return (Double(flashUsedBytes) / Double(flashTotalBytes)) * 100.0
    }
    
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

    // MARK: - Init

    init(device: DotDevice, sdkQueue: DispatchQueue) {
        self.device = device
        self.sdkQueue = sdkQueue
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
            self.setOnMain { self.isRecording = isRec }
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

    /// Ensures `@Published` mutations happen on the main thread.
    private func setOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

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
            self.setOnMain { self.sessionSynced = synced }
        }
    }

    /// Polls the SDK for the current recording state (push isn't always reliable).
    func refreshRecordingStatus() {
        sdkQueue.async { self.device.getRecordingStatus() }
    }

    /// Queries the SDK for current recording state and calls completion with the result.
    /// Completion fires on `sdkQueue`. Includes a 3s timeout (assumes not recording on timeout).
    func checkRecordingStatus(completion: @escaping (Bool) -> Void) {
        sdkQueue.async {
            var hasCompleted = false
            self.recordingStatusCompletion = { isRec in
                guard !hasCompleted else { return }
                hasCompleted = true
                completion(isRec)
            }
            self.device.getRecordingStatus()

            // Timeout — if SDK doesn't respond, assume not recording
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.sdkQueue.async {
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    self?.recordingStatusCompletion = nil
                    completion(false)
                }
            }
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

            self.device.setFlashInfoDoneBlock { [weak self] _ in
                guard let self, !hasCapturedResult else { return }
                hasCapturedResult = true

                let used = Int(self.device.usedSpace)
                let total = Int(self.device.totalSpace)
                self.setFlashSnapshot(usedBytes: used, totalBytes: total)

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
        setOnMain {
            self.flashUsedBytes = usedBytes
            self.flashTotalBytes = max(totalBytes, 1)
        }
    }

    // MARK: - Recording

    /// Starts recording on this sensor. Refreshes flash info first to ensure
    /// the device is ready, then issues the start command and polls until
    /// `isRecording` confirms the state change (up to 5s timeout).
    func startRecording(seconds: UInt16 = 0xFFFF, completion: @escaping (Bool) -> Void) {
        getFlashInfo { [weak self] success in
            guard let self else { completion(false); return }

            guard success, self.isInitialized else {
                print("❌ [\(self.address)] Cannot start recording (not initialized)")
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

            self.waitForRecordingState(true, timeout: 5.0) { success in
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
                
                self.setOnMain { self.recordingFiles = files }
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
                self?.setOnMain { self?.isErasing = false }
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
