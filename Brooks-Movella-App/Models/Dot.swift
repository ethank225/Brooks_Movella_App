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
import Combine  // ← Add this


final class Dot: ObservableObject {

    // MARK: - Immutable identity
    
    let device: DotDevice
    
    var address: String {
        device.uuid
    }

    // MARK: - Mutable state (owned by Dot, controlled by DotManager)
    
    @Published var isConnected = false      // ← Add @Published
    @Published var isRecording = false      // ← Add @Published
    @Published var sessionSynced = false    // ← Add @Published

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

    func configure(outputRate: Int = 120, filterIndex: Int = 0) {
        device.setOutputRate(Int32(outputRate), filterIndex: Int32(filterIndex))
        print("⚙️ [\(address)] Configured: \(outputRate)Hz, filter \(filterIndex)")
    }

    // MARK: - Recording

    // MARK: - Recording

    func startRecording(seconds: UInt16 = 0xFFFF, completion: @escaping (Bool) -> Void) {
        // First get flash info to ensure flash is ready
        getFlashInfo { [weak self] status in
            guard let self = self else {
                completion(false)
                return
            }
            
            guard status == .isReady else {
                print("❌ [\(self.address)] Flash not ready: \(status.rawValue)")
                completion(false)
                return
            }
            
            self.actuallyStartRecording(seconds: seconds, completion: completion)
        }
    }
    
    func getFlashInfo(completion: @escaping (XSFlashInfoStatus) -> Void) {
        // Don't require lock for flash info check
        print("💾 [\(address)] Getting flash info...")
        
        device.setFlashInfoDoneBlock { [weak self] status in
            print("💾 [\(self?.address ?? "?")] Flash status: \(status.rawValue)")
            completion(status)
        }
        
        device.getFlashInfo()
    }

    private func actuallyStartRecording(seconds: UInt16, completion: @escaping (Bool) -> Void) {
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
        
        var didComplete = false
        
        print("🎬 [\(address)] Starting recording...")
        
        device.recording.updateRecordingStatus = { [weak self] (status: XSRecordingStatus) in
            guard let self = self else { return }
            
            print("📨 [\(self.address)] Status: \(status.rawValue)")
            
            guard !didComplete else { return }
            
            switch status {
            case .isRecording:
                didComplete = true
                self.isRecording = true
                self.releaseLock()
                print("🔴 [\(self.address)] Recording started")
                completion(true)
                
            case .isRecordingStopped:
                // Only treat as failure if we weren't already recording
                if !self.isRecording {
                    didComplete = true
                    self.releaseLock()
                    print("❌ [\(self.address)] Recording failed to start")
                    completion(false)
                }
                
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
            print("⚠️ [\(address)] Not recording, nothing to stop")
            releaseLock()
            completion(true)
            return
        }
        
        var didComplete = false
        
        print("⏹️ [\(address)] Stopping recording...")
        
        device.recording.updateRecordingStatus = { [weak self] (status: XSRecordingStatus) in
            guard let self = self else { return }
            
            print("📨 [\(self.address)] Status: \(status.rawValue)")
            
            guard !didComplete else { return }
            
            if status == .isRecordingStopped {
                didComplete = true
                self.isRecording = false
                self.releaseLock()
                print("⏹️ [\(self.address)] Recording stopped")
                completion(true)
            }
        }
        
        device.stopRecording()
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
