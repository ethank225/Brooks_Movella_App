//
//  Dot.swift
//  Brooks-Movella-App
//
//  Thin wrapper around a single DotDevice.
//  Adds sessionSynced so the UI reflects THIS sync attempt (not device.isSynced()).
//

import Foundation
import MovellaDotSdk

final class Dot {

    let device: DotDevice
    private let lock = NSLock()

    var isConnected = false
    var isRecording = false
    private(set) var isBusy = false

    // This is your per-button-press sync truth
    var sessionSynced = false

    var address: String {
        device.uuid
    }

    var isInitialized: Bool {
        device.isInitialized()
    }

    // Do not use this to decide success. It can be stale/persisted.
    var isSynced: Bool {
        device.isSynced()
    }

    init(device: DotDevice) {
        self.device = device
    }

    // MARK: - Busy lock

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

    // MARK: - Flash helpers (optional)

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

extension Dot: Equatable {
    static func == (lhs: Dot, rhs: Dot) -> Bool {
        lhs.address == rhs.address
    }
}
