import Foundation
import MovellaDotSdk
import Combine

final class Dot: ObservableObject, Identifiable {

    // MARK: - Immutable identity

    private(set) var device: DotDevice

    var address: String {
        device.uuid
    }
    
    var id: String {
        device.uuid
    }

    // MARK: - Published state

    @Published var isConnected = false
    @Published var isRecording = false
    @Published var sessionSynced = false
    
    // MARK: - Snapshot State (The Truth)
    // We strictly use these for UI. We do not calculate from 'device' during render.
    @Published private(set) var flashUsedBytes: Int = 0
    @Published private(set) var flashTotalBytes: Int = 1 // Prevent divide by zero default

    var storagePercentageUsed: Double {
        guard flashTotalBytes > 0 else { return 0 }
        return (Double(flashUsedBytes) / Double(flashTotalBytes)) * 100.0
    }

    // MARK: - Computed properties from device

    var isInitialized: Bool {
        device.isInitialized()
    }

    var isSynced: Bool {
        device.isSynced()
    }

    // MARK: - Init

    init(device: DotDevice) {
        self.device = device
        installDefaultRecordingStatusHandler()
    }
    
    func updateDevice(_ newDevice: DotDevice) {
        self.device = newDevice
        installDefaultRecordingStatusHandler()
        print("🔄 [\(address)] Device reference updated")
    }

    // MARK: - Permanent Recording Status Handler

    func installDefaultRecordingStatusHandler() {
        device.recording.updateRecordingStatus = { [weak self] status in
            guard let self = self else { return }
            print("📨 [\(self.address)] Recording status: \(status.rawValue)")

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

    // MARK: - Main-thread helper

    private func setOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - State setters

    func setIsConnected(_ value: Bool) {
        setOnMain { self.isConnected = value }
    }

    func setSessionSynced(_ value: Bool) {
        setOnMain { self.sessionSynced = value }
    }

    // MARK: - Sync status refresh

    func refreshSyncStatus() {
        let synced = device.isSynced()
        setOnMain { self.sessionSynced = synced }
        print("🔄 [\(address)] Sync status from device: \(synced)")
    }

    // MARK: - Configuration

    func configure(outputRate: Int = 120, filterIndex: Int = 0) {
        device.setOutputRate(Int32(outputRate), filterIndex: Int32(filterIndex))
        print("⚙️ [\(address)] Configured: \(outputRate)Hz, filter \(filterIndex)")
    }

    // MARK: - Flash / Storage (SNAPSHOT MODEL)

    /// Fetches flash info, updates the local snapshot, and returns success/failure.
    // MARK: - Flash / Storage (LATCHED SNAPSHOT)

    func getFlashInfo(completion: @escaping (Bool) -> Void) {
            let run = { [weak self] in
                guard let self = self else { return }
                print("💾 [\(self.address)] Requesting flash info...")

                // 🛑 GATEKEEPER:
                // The SDK often fires twice. Sometimes the second time is a "double count" bug
                // (e.g. 36% -> 72%). We use this flag to capture ONLY the first result.
                var hasCapturedResult = false

                // 1. Set the callback
                self.device.setFlashInfoDoneBlock { [weak self] status in
                    guard let self = self else { return }
                    
                    // If we already got our snapshot, ignore the SDK's second "correction"
                    if hasCapturedResult {
                        return
                    }
                    
                    // Lock the gate
                    hasCapturedResult = true
                    
                    // 2. IMMEDIATE SNAPSHOT
                    let used = Int(self.device.usedSpace)
                    let total = Int(self.device.totalSpace)
                    
                    self.setFlashSnapshot(usedBytes: used, totalBytes: total)
                    
                    print("💾 [\(self.address)] Snapshot: \(used)/\(total) (\(String(format: "%.1f", self.storagePercentageUsed))%)")
                    
                    // 3. Clear the block so the SDK stops pestering us (optional but clean)
                    self.device.setFlashInfoDoneBlock(nil)
                    
                    // 4. Report success once
                    completion(true)
                }

                // 5. Fire the command
                self.device.getFlashInfo()
            }

            if Thread.isMainThread { run() }
            else { DispatchQueue.main.async(execute: run) }
    }

    /// Thread-safe setter for the snapshot
    private func setFlashSnapshot(usedBytes: Int, totalBytes: Int) {
        setOnMain {
            self.flashUsedBytes = usedBytes
            self.flashTotalBytes = max(totalBytes, 1)
        }
    }

    // MARK: - Recording

    func startRecording(seconds: UInt16 = 0xFFFF, completion: @escaping (Bool) -> Void) {
        // Updated to use the new getFlashInfo signature (Bool)
        getFlashInfo { [weak self] success in
            guard let self = self else { completion(false); return }

            guard success, self.isInitialized else {
                print("❌ [\(self.address)] Cannot start recording (Not ready/init)")
                completion(false)
                return
            }

            print("🎬 [\(self.address)] Starting recording...")
            
            self.device.startRecording(seconds)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.device.getRecordingStatus()
            }

            self.waitForRecordingState(true, timeout: 5.0) { success in
                if success {
                    print("🔴 [\(self.address)] Recording confirmed started")
                } else {
                    print("❌ [\(self.address)] Recording did not start in time")
                }
                completion(success)
            }
        }
    }
    
    func refreshRecordingStatus() {
        device.getRecordingStatus()
    }

    func stopRecording(completion: @escaping (Bool) -> Void) {
        print("⏹️ [\(address)] Stopping recording...")
        
        device.stopRecording()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.device.getRecordingStatus()
        }
        
        waitForRecordingState(false, timeout: 5.0) { [weak self] success in
            guard let self = self else { completion(false); return }
            if success {
                print("⏹️ [\(self.address)] Recording confirmed stopped")
                // Update snapshot
                self.getFlashInfo { _ in }
            } else {
                print("❌ [\(self.address)] Recording did not stop in time")
            }
            completion(success)
        }
    }

    // MARK: - Polling helper

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

    func eraseFlash(completion: @escaping (Bool) -> Void) {
        print("🗑️ [\(address)] Erasing flash...")

        device.setEraseDataDoneBlock { [weak self] success in
            let ok = success != 0
            print("🗑️ [\(self?.address ?? "?")] Erase: \(ok ? "success" : "failed")")

            // Update snapshot after erase
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
