//
//  Dot.swift
//  Brooks-Movella-App
//
//  Thin wrapper around a single DotDevice.
//  Dot owns its own mutable state (isConnected, isRecording, etc.)
//  DotManager controls when these states change via SDK callbacks.
//

import Foundation
import MovellaDotSdk

final class Dot {

    // MARK: - Immutable identity
    
    let device: DotDevice
    
    var address: String {
        device.uuid
    }

    // MARK: - Mutable state (owned by Dot, controlled by DotManager)
    
    var isConnected = false
    var isRecording = false
    
    /// Per-session sync flag - reset each sync attempt
    var sessionSynced = false

    // MARK: - Busy lock for async operations
    
    private let lock = NSLock()
    private(set) var isBusy = false

    // MARK: - Computed properties from device
    
    var isInitialized: Bool {
        device.isInitialized()
    }

    /// Note: This can be stale/persisted. Use sessionSynced for current sync status.
    var isSynced: Bool {
        device.isSynced()
    }

    // MARK: - Init

    init(device: DotDevice) {
        self.device = device
    }

    // MARK: - Busy lock helpers

    private func acquireLock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isBusy { return false }
        isBusy = true
        return true
    }

    private func releaseLock() {
        lock.lock()
        defer { lock.unlock() }
        isBusy = false
    }

    func forceRelease() {
        releaseLock()
        print("⚠️ [\(address)] Force released lock")
    }

    // MARK: - Configuration

    func configure(outputRate: Int = 60, filterIndex: Int = 0) {
        device.setOutputRate(Int32(outputRate), filterIndex: Int32(filterIndex))
        print("⚙️ [\(address)] Configured: \(outputRate)Hz, filter \(filterIndex)")
    }

    // MARK: - Recording

    func startRecording(seconds: UInt16 = 0xFFFF, completion: @escaping (Bool) -> Void) {
        guard acquireLock() else {
            print("⚠️ [\(address)] Busy, skipping startRecording")
            completion(false)
            return
        }
        guard isInitialized else {
            print("⚠️ [\(address)] Not initialized, skipping startRecording")
            releaseLock()
            completion(false)
            return
        }

        device.recording.updateRecordingStatus = { [weak self] (status: XSRecordingStatus) in
            guard let self = self else { return }

            switch status {
            case .isRecording:
                self.isRecording = true
                self.releaseLock()
                print("🔴 [\(self.address)] Recording started")
                completion(true)

            case .isRecordingStopped:
                self.isRecording = false
                self.releaseLock()
                print("❌ [\(self.address)] Recording failed to start")
                completion(false)

            default:
                break
            }
        }

        device.startRecording(seconds)
    }

    func stopRecording(completion: @escaping (Bool) -> Void) {
        guard acquireLock() else {
            print("⚠️ [\(address)] Busy, skipping stopRecording")
            completion(false)
            return
        }
        guard isRecording else {
            releaseLock()
            completion(true)
            return
        }

        device.recording.updateRecordingStatus = { [weak self] (status: XSRecordingStatus) in
            guard let self = self else { return }
            if status == .isRecordingStopped {
                self.isRecording = false
                self.releaseLock()
                print("⏹️ [\(self.address)] Recording stopped")
                completion(true)
            }
        }

        device.stopRecording()
    }

    // MARK: - Flash helpers

    func getFlashInfo(completion: @escaping (XSFlashInfoStatus) -> Void) {
        guard acquireLock() else {
            print("⚠️ [\(address)] Busy, skipping getFlashInfo")
            completion(.isUninitialized)
            return
        }

        device.setFlashInfoDoneBlock { [weak self] status in
            self?.releaseLock()
            print("💾 [\(self?.address ?? "?")] Flash status: \(status)")
            completion(status)
        }

        device.getFlashInfo()
    }

    func eraseFlash(completion: @escaping (Bool) -> Void) {
        guard acquireLock() else {
            print("⚠️ [\(address)] Busy, skipping eraseFlash")
            completion(false)
            return
        }

        device.setEraseDataDoneBlock { [weak self] success in
            self?.releaseLock()
            let ok = success != 0
            print("🗑️ [\(self?.address ?? "?")] Erase: \(ok ? "success" : "failed")")
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
