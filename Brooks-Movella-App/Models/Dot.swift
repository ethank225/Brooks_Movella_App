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

    @Published var isConnected = false
    @Published var isRecording = false
    @Published var sessionSynced = false

    /// Flash storage snapshot. Updated after connection, recording, and erase.
    /// We store our own copy because reading `device.usedSpace` / `device.totalSpace`
    /// at render time is unreliable — the SDK can mutate them between frames.
    @Published private(set) var flashUsedBytes: Int = 0
    @Published private(set) var flashTotalBytes: Int = 1  // default 1 to avoid divide-by-zero

    var storagePercentageUsed: Double {
        guard flashTotalBytes > 0 else { return 0 }
        return (Double(flashUsedBytes) / Double(flashTotalBytes)) * 100.0
    }

    // MARK: - SDK-Derived State (read-through to device)

    /// Whether the SDK has finished initializing this device after connection.
    var isInitialized: Bool { device.isInitialized() }

    /// Whether the SDK considers this device time-synced with the host.
    var isSynced: Bool { device.isSynced() }

    // MARK: - Init

    init(device: DotDevice) {
        self.device = device
        installRecordingStatusHandler()
    }

    /// Replace the underlying device reference (e.g. after SDK reconnects during sync).
    /// Re-installs the recording callback since the old device object is stale.
    func updateDevice(_ newDevice: DotDevice) {
        self.device = newDevice
        installRecordingStatusHandler()
        print("🔄 [\(address)] Device reference updated")
    }

    // MARK: - Recording Status Handler

    /// Installs a permanent callback on `device.recording` that keeps
    /// `isRecording` in sync with the SDK's push notifications.
    /// Called on init and after every device reference update.
    private func installRecordingStatusHandler() {
        device.recording.updateRecordingStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .isRecording:
                self.setOnMain { self.isRecording = true }
            case .isRecordingStopped, .isIdle:
                self.setOnMain { self.isRecording = false }
            default:
                break
            }
        }
    }

    // MARK: - Thread-safe Setters

    /// Ensures `@Published` mutations happen on the main thread.
    private func setOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    func setIsConnected(_ value: Bool) {
        setOnMain { self.isConnected = value }
    }

    func setSessionSynced(_ value: Bool) {
        setOnMain { self.sessionSynced = value }
    }

    // MARK: - Commands

    /// Triggers a visual/haptic signal on the physical sensor for identification.
    func identify() {
        device.startIdentifying()
    }

    /// Sets the sensor's output rate and filter profile.
    func configure(outputRate: Int = 120, filterIndex: Int = 0) {
        device.setOutputRate(Int32(outputRate), filterIndex: Int32(filterIndex))
        print("⚙️ [\(address)] Configured: \(outputRate)Hz, filter \(filterIndex)")
    }

    /// Reads the device's sync state from the SDK and updates `sessionSynced`.
    func refreshSyncStatus() {
        let synced = device.isSynced()
        setOnMain { self.sessionSynced = synced }
    }

    /// Polls the SDK for the current recording state (push isn't always reliable).
    func refreshRecordingStatus() {
        device.getRecordingStatus()
    }

    // MARK: - Flash Storage

    /// Fetches flash usage from the SDK and updates `flashUsedBytes`/`flashTotalBytes`.
    ///
    /// **SDK quirk:** The completion callback often fires twice, with the second
    /// call sometimes reporting doubled values (e.g. 36% → 72%). A gatekeeper
    /// flag captures only the first result and ignores subsequent callbacks.
    func getFlashInfo(completion: @escaping (Bool) -> Void) {
        let run = { [weak self] in
            guard let self else { return }

            var hasCapturedResult = false

            self.device.setFlashInfoDoneBlock { [weak self] _ in
                guard let self, !hasCapturedResult else { return }
                hasCapturedResult = true

                let used = Int(self.device.usedSpace)
                let total = Int(self.device.totalSpace)
                self.setFlashSnapshot(usedBytes: used, totalBytes: total)

                print("💾 [\(self.address)] Snapshot: \(used)/\(total) (\(String(format: "%.1f", self.storagePercentageUsed))%)")
                self.device.setFlashInfoDoneBlock(nil)
                completion(true)
            }

            self.device.getFlashInfo()
        }

        if Thread.isMainThread { run() }
        else { DispatchQueue.main.async(execute: run) }
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
            self.device.startRecording(seconds)

            // Kick the SDK to report status, then poll until confirmed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.device.getRecordingStatus()
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
        device.stopRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.device.getRecordingStatus()
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
            self.device.getRecordingStatus()

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

    // MARK: - Erase

    /// Erases all recorded data on the sensor's flash storage.
    /// Refreshes the flash snapshot on completion.
    func eraseFlash(completion: @escaping (Bool) -> Void) {
        print("🗑️ [\(address)] Erasing flash...")

        device.setEraseDataDoneBlock { [weak self] success in
            let ok = success != 0
            print("🗑️ [\(self?.address ?? "?")] Erase: \(ok ? "success" : "failed")")
            self?.getFlashInfo { _ in }
            completion(ok)
        }

        device.eraseData()
    }
}

// MARK: - Equatable

extension Dot: Equatable {
    static func == (lhs: Dot, rhs: Dot) -> Bool {
        lhs.address == rhs.address
    }
}
