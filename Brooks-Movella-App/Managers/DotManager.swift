//
//  DotManager.swift
//  Brooks-Movella-App
//
//  Full fixed version:
//  - Correctly parses DotSyncManager results (address/success/doneSuccess/status)
//  - Does NOT trust device.isSynced() to mean "sync succeeded"
//  - Tracks per-session sync result on Dot.sessionSynced
//  - Treats disconnects during sync as expected (does not remove dots)
//  - Avoids duplicate Dot objects on reconnect
//

import Foundation
import MovellaDotSdk

// MARK: - Notification

extension Notification.Name {
    static let dotManagerUpdated = Notification.Name("dotManagerUpdated")
}

final class DotManager: NSObject {

    static let shared = DotManager()

    // MARK: - State

    private(set) var discovered: [DotDevice] = []
    private(set) var dots: [Dot] = []
    private(set) var isScanning = false

    private var pendingConnectAddresses: Set<String> = []
    private var syncInProgress = false

    private override init() {
        super.init()
    }

    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
    }

    // MARK: - Scanning

    func startScan() {
        guard DotConnectionManager.managerStateIsPoweredOn() else {
            print("❌ Bluetooth not powered on")
            return
        }
        discovered.removeAll()
        isScanning = true
        DotConnectionManager.scan()
        print("🔍 Scan started")
        notify()
    }

    func stopScan() {
        DotConnectionManager.stopScan()
        isScanning = false
        print("🔍 Scan stopped")
        notify()
    }
    
    func dot(for device: DotDevice) -> Dot? {
        let addr = device.macAddress ?? device.uuid ?? ""
        return dots.first { $0.address == addr }
    }

    func dot(forAddress address: String) -> Dot? {
        dots.first { $0.address == address }
    }

    // MARK: - Connect / Disconnect

    func connectByAddress(_ address: String) {
        pendingConnectAddresses.insert(address)
        print("🔗 Queued connect for \(address) (pending: \(pendingConnectAddresses.count))")

        if !isScanning {
            print("🔍 Starting scan for pending connections...")
            startScan()
        }
    }

    func disconnect(_ dot: Dot) {
        if syncInProgress {
            print("⚠️ Ignoring disconnect during sync for \(dot.address)")
            return
        }
        DotConnectionManager.disconnect(dot.device)
    }

    func disconnectAll() {
        if syncInProgress {
            print("⚠️ Ignoring disconnectAll during sync")
            return
        }
        for dot in dots {
            DotConnectionManager.disconnect(dot.device)
        }
    }

    // MARK: - Wait helpers

    func waitForAllInitialized(
        timeout: TimeInterval = 15,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()

        func check() {
            if dots.allSatisfy({ $0.isInitialized }) {
                print("✅ All \(dots.count) dots initialized")
                completion(true)
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                let notReady = dots.filter { !$0.isInitialized }.map { $0.address }
                print("⏰ Init timeout. Not ready: \(notReady)")
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
        }

        check()
    }

    func waitForAllReconnected(
        timeout: TimeInterval = 30,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()

        func check() {
            if dots.allSatisfy({ $0.isConnected }) {
                completion(true)
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                let notConn = dots.filter { !$0.isConnected }.map { $0.address }
                print("⏰ Reconnect timeout. Not connected: \(notConn)")
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
        }

        check()
    }

    // MARK: - Configuration

    func configureAll(outputRate: Int = 60, filterIndex: Int = 0) {
        for dot in dots {
            dot.configure(outputRate: outputRate, filterIndex: filterIndex)
        }
        print("⚙️ Configured all \(dots.count) dots: \(outputRate)Hz, filter \(filterIndex)")
    }

    // MARK: - Sync ordering

    private func orderedDotsForSync() -> [Dot] {
        // Root must be first; deterministic order keeps it stable.
        // If you later want user-picked root, store rootAddress and order by that.
        dots.sorted { $0.address < $1.address }
    }

    private func orderedDevicesForSync() -> [DotDevice] {
        orderedDotsForSync().map { $0.device }
    }

    // MARK: - Debug dump

    private func dumpSyncResults(_ results: Any) {
        print("🔎 Sync results Swift type:", type(of: results))
        print("🔎 Sync results description:", String(describing: results))

        if let arr = results as? [Any] {
            print("🔎 Sync results count:", arr.count)
            for (i, item) in arr.enumerated() {
                print("   [\(i)] item type:", type(of: item))
                print("   [\(i)] item:", String(describing: item))
            }
        }
    }

    // MARK: - Synchronization

    func sync(completion: @escaping (Bool) -> Void) {
        guard !dots.isEmpty else {
            print("⚠️ No dots to sync")
            completion(false)
            return
        }

        // Pre-sync ready check and baseline logging
        for d in dots {
            print("🧪 Pre-sync \(d.address) connected=\(d.isConnected) init=\(d.isInitialized) isSynced=\(d.isSynced) recording=\(d.isRecording) busy=\(d.isBusy)")
            d.sessionSynced = false
        }

        // If any dot is busy or recording, fail fast
        if dots.contains(where: { $0.isBusy || $0.isRecording || !$0.isInitialized || !$0.isConnected }) {
            print("⚠️ Not ready for sync. Ensure all dots are connected, initialized, and idle.")
            completion(false)
            return
        }

        let orderedDots = orderedDotsForSync()
        let devices = orderedDots.map { $0.device }

        print("🧭 Sync order:")
        for (i, d) in orderedDots.enumerated() {
            print("   [\(i)] \(d.address) \(i == 0 ? "(ROOT)" : "(SCANNER)")")
        }

        syncInProgress = true

        // Force clean slate every time
        DotSyncManager.stopSync(devices)

        print("🔄 Starting sync for \(devices.count) dots (root first)...")

        let block: DotSyncResultBlock = { [weak self] results in
            guard let self = self else { return }

            self.dumpSyncResults(results)

            var successByAddress: [String: Bool] = [:]
            var allSuccess = true

            if let array = results as? [[String: Any]] {
                for item in array {
                    let addr = item["address"] as? String ?? "?"

                    let successNum = item["success"] as? NSNumber
                    let doneNum = item["doneSuccess"] as? NSNumber

                    let statusAny = item["status"]
                    let statusStr: String
                    if let s = statusAny as? String {
                        statusStr = s
                    } else if let n = statusAny as? NSNumber {
                        statusStr = "\(n.intValue)"
                    } else {
                        statusStr = "?"
                    }

                    let ok = (successNum?.intValue ?? 0) != 0
                    successByAddress[addr] = ok
                    if !ok { allSuccess = false }

                    print("🔄 Sync result — \(addr): \(ok ? "✅" : "❌")  success=\(successNum?.intValue ?? -1) done=\(doneNum?.intValue ?? -1) status=\(statusStr)")
                }
            } else {
                print("❌ Unexpected sync results format.")
                allSuccess = false
            }

            DispatchQueue.main.async {
                // Apply per-dot per-session result
                for d in self.dots {
                    if let ok = successByAddress[d.address] {
                        d.sessionSynced = ok
                    }
                }

                // Wait for reconnect if you want sequencing, but do not override success
                self.waitForAllReconnected(timeout: 30) { reconnected in
                    if !reconnected {
                        print("⚠️ Not all dots reconnected in time")
                    }

                    self.syncInProgress = false
                    self.notify()

                    // Completion is driven by SDK results, not isSynced()
                    completion(allSuccess)
                }
            }
        }

        DotSyncManager.startSync(devices, result: block)
    }

    func stopSync() {
        guard !dots.isEmpty else { return }
        let devices = orderedDevicesForSync()
        DotSyncManager.stopSync(devices)
        syncInProgress = false
        print("🔄 Sync stopped for \(devices.count) dots")
        notify()
    }

    // MARK: - Recording (optional)

    func startRecordingAll(
        seconds: UInt16 = 0xFFFF,
        completion: @escaping (Bool) -> Void
    ) {
        guard !dots.isEmpty else {
            completion(false)
            return
        }

        let group = DispatchGroup()
        var allSuccess = true

        print("🔴 Starting recording on \(dots.count) dots...")

        for dot in dots {
            group.enter()
            dot.startRecording(seconds: seconds) { success in
                if !success { allSuccess = false }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            print("🔴 Recording started on all: \(allSuccess ? "✅" : "⚠️ some failed")")
            self?.notify()
            completion(allSuccess)
        }
    }

    func stopRecordingAll(completion: @escaping (Bool) -> Void) {
        guard !dots.isEmpty else {
            completion(false)
            return
        }

        let group = DispatchGroup()
        var allSuccess = true

        print("⏹️ Stopping recording on \(dots.count) dots...")

        for dot in dots {
            group.enter()
            dot.stopRecording { success in
                if !success { allSuccess = false }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            print("⏹️ Recording stopped on all: \(allSuccess ? "✅" : "⚠️ some failed")")
            self?.notify()
            completion(allSuccess)
        }
    }

    // MARK: - Notification

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dotManagerUpdated, object: nil)
        }
    }
}

// MARK: - DotConnectionDelegate

extension DotManager: DotConnectionDelegate {

    func onManagerStateUpdate(_ managerState: XSDotManagerState) {
        print("📡 Bluetooth state: \(managerState.rawValue)")
        notify()
    }

    func onScanCompleted() {
        isScanning = false
        if !pendingConnectAddresses.isEmpty {
            print("⚠️ Scan completed without finding pending devices: \(pendingConnectAddresses)")
            pendingConnectAddresses.removeAll()
        }
        print("🔍 Scan completed — found \(discovered.count) devices")
        notify()
    }

    func onDiscover(_ device: DotDevice) {
        let addr = device.macAddress ?? device.uuid ?? ""
        let alreadyFound = discovered.contains { ($0.macAddress ?? $0.uuid ?? "") == addr }
        if !alreadyFound {
            discovered.append(device)
            print("📡 Discovered: \(addr)")
        }
        notify()

        if pendingConnectAddresses.contains(addr) {
            pendingConnectAddresses.remove(addr)
            DotConnectionManager.connect(device)
            print("🔗 Connecting to \(addr)... (remaining pending: \(pendingConnectAddresses.count))")

            if pendingConnectAddresses.isEmpty {
                DotConnectionManager.stopScan()
                isScanning = false
                print("🔍 All pending devices found, scan stopped")
            }
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        let addr = device.macAddress ?? device.uuid ?? ""

        if let existing = dots.first(where: { $0.address == addr }) {
            existing.isConnected = true
            print("✅ Reconnected: \(addr)")
        } else {
            let dot = Dot(device: device)
            dot.isConnected = true
            dots.append(dot)
            print("✅ Connected: \(addr) (Total: \(dots.count))")
        }

        notify()
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        let addr = device.macAddress ?? device.uuid ?? ""
        print("❌ Connection failed: \(addr)")
        notify()
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        let addr = device.macAddress ?? device.uuid ?? ""

        if let existing = dots.first(where: { $0.address == addr }) {
            existing.isConnected = false
        }

        if syncInProgress {
            print("🔌 Disconnected during sync (expected): \(addr)")
        } else {
            print("⛓️‍💥 Disconnected: \(addr)")
            dots.removeAll { $0.address == addr }
        }

        notify()
    }
}
