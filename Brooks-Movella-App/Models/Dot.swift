//
//  Dot.swift
//  Brooks-Movella-App
//
//  Thin wrapper around a single DotDevice.
//  Dot owns its own mutable state (isConnected, isRecording, etc.)
//  DotManager controls when these states change via SDK callbacks.
//
//  Architecture:
//  - One PERMANENT recording status handler that always keeps isRecording accurate.
//  - Operations (start/stop recording, erase) send the SDK command then poll
//    for the expected state change with a timeout. No callback swapping, no locks.
//  - DotManager calls installDefaultRecordingStatusHandler() after reconnect.
//

import Foundation
import MovellaDotSdk
import Combine

final class Dot: ObservableObject {

    // MARK: - Immutable identity

    
    private(set) var device: DotDevice



    var address: String {
        device.uuid
    }

    // MARK: - Published state

    @Published var isConnected = false
    @Published var isRecording = false
    @Published var sessionSynced = false
    @Published var storagePercentageUsed: Double = 0

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
    //
    // This is the ONLY place updateRecordingStatus is set.
    // It never gets overwritten by start/stop operations.
    // Call this again after reconnect to re-register on the (potentially new) device state.

    func installDefaultRecordingStatusHandler() {
        device.recording.updateRecordingStatus = { [weak self] status in
            guard let self else { return }
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

    // MARK: - State setters (called by DotManager)

    func setIsConnected(_ value: Bool) {
        setOnMain { self.isConnected = value }
    }

    func setSessionSynced(_ value: Bool) {
        setOnMain { self.sessionSynced = value }
    }

    // MARK: - Sync status refresh (called after reconnect + initialization)

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

    // MARK: - Recording

    func startRecording(seconds: UInt16 = 0xFFFF, completion: @escaping (Bool) -> Void) {
        getFlashInfo { [weak self] status in
            guard let self else {
                completion(false)
                return
            }

            guard status == .isReady, self.isInitialized else {
                print("❌ [\(self.address)] Cannot start recording")
                completion(false)
                return
            }

            print("🎬 [\(self.address)] Starting recording...")
            
            // Send the command
            self.device.startRecording(seconds)
            
            // Request status update immediately to trigger callback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.device.getRecordingStatus()
            }

            // Wait for state change
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
        device.getRecordingStatus()  // triggers the callback
    }

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
                self.refreshStorageInfo()
            } else {
                print("❌ [\(self.address)] Recording did not stop in time")
            }
            completion(success)
        }
    }

    // MARK: - Polling helper
    //
    // Watches isRecording until it matches the target value, or times out.
    // No callback swapping, no locks — just checking state.

    private func waitForRecordingState(
        _ target: Bool,
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()

        func check() {
            self.device.getRecordingStatus()
            
            // Check after delay, but stay on main for reading @Published state
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

    // MARK: - Flash / Storage

    func getFlashInfo(completion: @escaping (XSFlashInfoStatus) -> Void) {
        let run = { [weak self] in
            guard let self else { return }
            print("💾 [\(self.address)] Getting flash info...")

            self.device.setFlashInfoDoneBlock { [weak self] status in
                guard let self else { return }
                print("💾 [\(self.address)] Flash status: \(status.rawValue)")
                completion(status)
            }

            self.device.getFlashInfo()
        }

        if Thread.isMainThread { run() }
        else { DispatchQueue.main.async(execute: run) }
    }


    func refreshStorageInfo() {
        print("🔄 [\(address)] refreshStorageInfo called")
        getFlashInfo { [weak self] status in
            guard let self else {
                print("🔄 [?] self is nil in refreshStorageInfo callback")
                return
            }
            print("🔄 [\(self.address)] getFlashInfo returned, calling updateStorageDisplay")
            self.updateStorageDisplay()
        }
    }

    func updateStorageDisplay() {
        let total = device.totalSpace
        let percentage: Double
        if total > 0 {
            percentage = Double(device.usedSpace) / Double(total) * 100
        } else {
            percentage = 0
        }

        print("💾 [\(address)] Storage: \(String(format: "%.1f", percentage))% used")

        setOnMain {
            self.storagePercentageUsed = percentage
        }
    }

    func eraseFlash(completion: @escaping (Bool) -> Void) {
        print("🗑️ [\(address)] Erasing flash...")

        device.setEraseDataDoneBlock { [weak self] success in
            let ok = success != 0
            print("🗑️ [\(self?.address ?? "?")] Erase: \(ok ? "success" : "failed")")

            // Refresh storage after erase
            self?.refreshStorageInfo()
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
