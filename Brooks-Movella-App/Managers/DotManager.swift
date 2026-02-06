import Foundation
import MovellaDotSdk

// MARK: - DotManager
//
// Full fixed version:
// - Makes DotManager state thread-safe (serial stateQueue)
// - Serializes *all* SDK calls (sdkQueue) to avoid concurrent SDK operations
// - Prevents sync from starting while connecting/initializing/refreshing
// - Prevents post-connect refresh (flash info) from running while syncing
// - Uses snapshots when iterating to avoid dictionary mutation crashes
// - Keeps notifications on main thread for SwiftUI
//

final class DotManager: NSObject {

    // MARK: - Singleton

    static let shared = DotManager()

    private override init() {
        super.init()
    }

    // MARK: - Notification

    enum Notification {
        static let updated = Foundation.Notification.Name("dotManagerUpdated")
    }

    // MARK: - Types

    struct DotState {
        var device: DotDevice
        var dot: Dot?
        var lastSeen: Date

        // App-owned intent: what we expect this dot to be doing for the session
        var sessionWantsRecording: Bool = false

        // If we ended session while it was away, stop it as soon as it returns
        var pendingStopOnReconnect: Bool = false
    }


    // MARK: - Queues

    /// Serializes DotManager state (byUuid/connectQueue flags, etc.)
    private let stateQueue = DispatchQueue(label: "DotManager.stateQueue")

    /// Serializes all SDK calls (connect, scan, sync, etc.)
    private let sdkQueue = DispatchQueue(label: "DotManager.sdkQueue")

    // MARK: - State (ONLY touch on stateQueue)

    private var byUuid: [String: DotState] = [:]

    private var connectQueue: [String] = []
    private var connectInProgress: String?

    private var syncInProgress: Bool = false
    private var refreshInProgress: Bool = false

    private var isScanningInternal: Bool = false

    // MARK: - Lifecycle

    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
        DotReconnectManager.setEnable(true)
    }

    // MARK: - Thread-safe snapshots for UI

    var isScanning: Bool {
        stateQueue.sync { isScanningInternal }
    }

    var discovered: [DotDevice] {
        stateQueue.sync {
            byUuid.values
                .sorted { $0.lastSeen > $1.lastSeen }
                .map { $0.device }
        }
    }

    var dots: [Dot] {
        stateQueue.sync { byUuid.values.compactMap { $0.dot } }
    }

    var connectedDots: [Dot] {
        stateQueue.sync { byUuid.values.compactMap { $0.dot }.filter { $0.isConnected } }
    }

    func dot(forUuid uuid: String) -> Dot? {
        stateQueue.sync { byUuid[uuid]?.dot }
    }

    func isConnected(forUuid uuid: String) -> Bool {
        stateQueue.sync { byUuid[uuid]?.dot?.isConnected ?? false }
    }

    func displayAddress(for device: DotDevice) -> String {
        if !device.macAddress.isEmpty { return device.macAddress }
        if !device.uuid.isEmpty { return device.uuid }
        return "?"
    }

    // MARK: - Scanning

    func startScan() {
        stateQueue.async {
            if self.isScanningInternal { return }

            // Check powered on on sdkQueue (SDK call)
            self.sdkQueue.async {
                guard DotConnectionManager.managerStateIsPoweredOn() else {
                    print("❌ Bluetooth not powered on")
                    self.notify()
                    return
                }

                self.stateQueue.async {
                    if self.isScanningInternal { return }
                    self.isScanningInternal = true
                    print("🔍 Scan started")
                    self.notify()
                }

                DotConnectionManager.scan()
            }
        }
    }

    func stopScan() {
        stateQueue.async {
            if !self.isScanningInternal { return }
            self.isScanningInternal = false
            print("🔍 Scan stopped")
            self.notify()

            self.sdkQueue.async {
                DotConnectionManager.stopScan()
            }
        }
    }

    // MARK: - Connection

    func connectByUuid(_ uuid: String) {
        let u = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }

        stateQueue.async {
            // Avoid duplicate queue entries
            if self.connectQueue.contains(u) || self.connectInProgress == u { return }
            self.connectQueue.append(u)

            // Start scanning to find the device
            self.startScan()

            // Try to connect if already discovered
            self.processConnectQueue_locked()
            self.notify()
        }
    }

    func disconnect(_ dot: Dot) {
        // Do not mutate state in here; this is an SDK call
        sdkQueue.async {
            DotDevicePool.unbindDevice(dot.device)
            DotConnectionManager.disconnect(dot.device)
        }
    }
    
    

    // MARK: - Sync

    func syncConnectedDots(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Hard gate: no sync while connecting or refreshing
            if self.connectInProgress != nil || !self.connectQueue.isEmpty {
                print("⚠️ Cannot sync while connecting. Wait until idle.")
                DispatchQueue.main.async { completion(false) }
                return
            }

            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }
            let devices = dotsSnapshot.map { $0.device }

            guard devices.count >= 2 else {
                print("⚠️ Need at least 2 connected dots to sync")
                DispatchQueue.main.async { completion(false) }
                return
            }

            self.syncInProgress = true
            print("🔄 Starting sync with \(devices.count) devices...")
            self.notify()

            // Serialize SDK call
            self.sdkQueue.async { [weak self] in
                guard let self else { return }

                DotSyncManager.startSync(devices) { results in
                    // Hop back to stateQueue for state changes
                    self.stateQueue.async {
                        self.syncInProgress = false

                        guard let results = results as? [[String: Any]] else {
                            print("❌ Sync failed - no results")
                            for d in dotsSnapshot { d.sessionSynced = false }
                            self.notify()
                            DispatchQueue.main.async { completion(false) }
                            return
                        }

                        var allSuccess = true
                        for result in results {
                            let address = result["address"] as? String ?? "?"
                            let success = result["success"] as? Bool ?? false
                            print("   \(success ? "✅" : "❌") \(address)")
                            if !success { allSuccess = false }
                        }

                        for d in dotsSnapshot {
                            d.setSessionSynced(allSuccess)
                        }

                        print(allSuccess ? "✅ Sync completed" : "❌ Sync failed")
                        self.notify()
                        DispatchQueue.main.async { completion(allSuccess) }
                    }
                }
            }
        }
    }

    func stopSync() {
        stateQueue.async {
            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }
            let devices = dotsSnapshot.map { $0.device }

            for d in dotsSnapshot { d.setSessionSynced(false)}

            self.syncInProgress = false
            print("⏹️ Sync stopped")
            self.notify()

            self.sdkQueue.async {
                DotSyncManager.stopSync(devices)
            }
        }
    }

    // MARK: - Sequential helper (runs operations one-by-one)

    private func executeSequentially<T>(
        items: [T],
        operation: @escaping (T, @escaping (Bool) -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        var index = 0
        var allSuccess = true

        func next() {
            guard index < items.count else {
                completion(allSuccess)
                return
            }

            let item = items[index]
            operation(item) { success in
                if !success { allSuccess = false }
                index += 1
                next()
            }
        }

        next()
    }

    // MARK: - Recording / Flash (gated during sync)

    func startRecordingAll(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }

            self.sdkQueue.async {
                self.executeSequentially(
                    items: dotsSnapshot,
                    operation: { dot, done in
                        print("🎬 Starting recording on \(dot.address)...")
                        dot.startRecording(seconds: 0xFFFF, completion: done)
                    },
                    completion: { ok in
                        DispatchQueue.main.async { completion(ok) }
                    }
                )
            }
        }
    }

    func stopRecordingAll(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            // Debug: Check all dots
            print("🔍 Checking all dots in dictionary:")
            for (uuid, state) in self.byUuid {
                let isConnected = state.dot?.isConnected ?? false
                let isRecording = state.dot?.isRecording ?? false
                print("🔍   UUID: \(uuid)")
                print("🔍     isConnected: \(isConnected)")
                print("🔍     isRecording: \(isRecording)")
            }
            
            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }
            
            print("🔍 Filtered connected dots: \(dotsSnapshot.count)")
            for dot in dotsSnapshot {
                print("🔍   - \(dot.address): isConnected=\(dot.isConnected), isRecording=\(dot.isRecording)")
            }

            self.sdkQueue.async {
                self.executeSequentially(
                    items: dotsSnapshot,
                    operation: { dot, done in
                        print("⏹️ Stopping recording on \(dot.address)...")
                        dot.stopRecording(completion: done)
                    },
                    completion: { ok in
                        print("✅ stopRecordingAll completed: \(ok)")
                        DispatchQueue.main.async { completion(ok) }
                    }
                )
            }
        }
    }

    func eraseAllFlash(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }

            self.sdkQueue.async {
                self.executeSequentially(
                    items: dotsSnapshot,
                    operation: { dot, done in
                        print("🗑️ Erasing flash on \(dot.address)...")
                        dot.eraseFlash(completion: done)
                    },
                    completion: { ok in
                        DispatchQueue.main.async { completion(ok) }
                    }
                )
            }
        }
    }

    // MARK: - Refresh storage info (also gated)

    private func refreshAllStorageInfo_locked() {
        // Must be called on stateQueue
        if syncInProgress { return }
        if refreshInProgress { return }

        let dotsSnapshot = byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }
        if dotsSnapshot.isEmpty { return }

        refreshInProgress = true
        print("💾 Refreshing storage info for \(dotsSnapshot.count) dots...")

        sdkQueue.async { [weak self] in
            guard let self else { return }

            self.executeSequentially(
                items: dotsSnapshot,
                operation: { dot, done in
                    dot.getFlashInfo { _ in
                        dot.updateStorageDisplay()
                        done(true)
                    }
                },
                completion: { _ in
                    self.stateQueue.async {
                        self.refreshInProgress = false
                        print("💾 All storage info refreshed")
                        self.notify()
                    }
                }
            )
        }
    }

    // MARK: - Connection Queue Processing (LOCKED)

    private func processConnectQueue_locked() {
        // Must be called on stateQueue
        guard connectInProgress == nil else { return }
        guard !syncInProgress else { return } // do not start connects mid-sync

        guard let index = connectQueue.firstIndex(where: { byUuid[$0] != nil }) else { return }

        let uuid = connectQueue.remove(at: index)
        guard let state = byUuid[uuid] else { return }

        connectInProgress = uuid
        print("🔗 Connecting to \(displayAddress(for: state.device)) (uuid=\(uuid))")

        // SDK call serialized
        sdkQueue.async {
            DotConnectionManager.connect(state.device)
        }
    }

    private func advanceConnectQueue_locked() {
        // Must be called on stateQueue
        connectInProgress = nil
        processConnectQueue_locked()
    }

    // MARK: - State Updates (LOCKED)

    private func recordDiscovery_locked(_ device: DotDevice) {
        // Must be called on stateQueue
        let uuid = device.uuid
        let now = Date()

        if var existing = byUuid[uuid] {
            existing.device = device
            existing.lastSeen = now
            byUuid[uuid] = existing
        } else {
            byUuid[uuid] = DotState(device: device, dot: nil, lastSeen: now)
        }
    }

    private func recordConnection_locked(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device
        state.lastSeen = Date()

        if let dot = state.dot {
            // CRITICAL: Update the device reference so BLE writes work
            dot.updateDevice(device)
            dot.setIsConnected(true)
        } else {
            let dot = Dot(device: device)
            dot.setIsConnected(true)
            state.dot = dot
        }

        byUuid[uuid] = state
    }
    
    private func recordDisconnection_locked(_ uuid: String) {
        // Must be called on stateQueue
        byUuid[uuid]?.dot?.setIsConnected(false)
    }

    // MARK: - Notifications

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.updated, object: nil)
        }
    }

    // MARK: - Debug

    func printStatus() {
        stateQueue.sync {
            print("═══════════════════════════════════")
            print("DotManager Status")
            print("───────────────────────────────────")
            print("Discovered: \(byUuid.count)")
            print("Dots created: \(byUuid.values.compactMap { $0.dot }.count)")
            print("Connected: \(byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }.count)")
            print("Scanning: \(isScanningInternal)")
            print("Connect queue: \(connectQueue.count)")
            print("Connect in progress: \(connectInProgress ?? "nil")")
            print("Sync in progress: \(syncInProgress)")
            print("Refresh in progress: \(refreshInProgress)")
            print("───────────────────────────────────")

            for (uuid, state) in byUuid {
                let connected = state.dot?.isConnected ?? false
                let symbol = connected ? "✅" : "⚪️"
                print("\(symbol) \(state.device.macAddress) (uuid=\(uuid)) connected=\(connected)")
            }

            let boundDevices = DotDevicePool.allBoundDevices() ?? []
            print("───────────────────────────────────")
            print("DotDevicePool bound: \(boundDevices.count)")
            for device in boundDevices {
                print("   🔗 \(device.macAddress)")
            }
            print("═══════════════════════════════════")
        }
    }
}

// MARK: - SDK Delegate

extension DotManager: DotConnectionDelegate {

    func onManagerStateUpdate(_ managerState: XSDotManagerState) {
        print("📡 Bluetooth state: \(managerState.rawValue)")
        notify()
    }

    func onDiscover(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }

        stateQueue.async {
            self.recordDiscovery_locked(device)
            self.processConnectQueue_locked()
            self.notify()
        }
    }

    func onScanCompleted() {
        stateQueue.async {
            self.isScanningInternal = false
            print("🔍 Scan completed — known devices: \(self.byUuid.count)")
            self.notify()

            // Keep scanning if we still have pending connections
            if !self.connectQueue.isEmpty {
                self.startScan()
            }
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        guard !device.uuid.isEmpty else {
            stateQueue.async {
                self.advanceConnectQueue_locked()
                self.notify()
            }
            return
        }

        stateQueue.async {
            self.recordConnection_locked(device)

            // SDK call serialized
            self.sdkQueue.async {
                DotDevicePool.bindDevice(device)
            }
            
//            if (device.uuid).count > 0 {
//                print("This is the UUID: " + device.uuid)
//            } else {
//                print("NOOOO THERE IS NO UUID")
//            }
            
            

            self.advanceConnectQueue_locked()
            self.notify()

            // If idle (no sync, no connects), refresh storage
            if !self.syncInProgress && self.connectQueue.isEmpty && self.connectInProgress == nil {
                self.waitForAllInitialized_thenRefresh_locked()
            }
        }
    }
    
    private func pingRecordingStatus_locked(uuid: String) {
        // Must be called on stateQueue
        guard let state = byUuid[uuid], let dot = state.dot, dot.isConnected else { return }

        sdkQueue.async {
            state.device.getRecordingStatus()
        }
    }

    private func waitForAllInitialized_thenRefresh_locked() {
        // Must be called on stateQueue
        let dotsSnapshot = byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }

        func allInitialized() -> Bool {
            dotsSnapshot.allSatisfy { $0.isInitialized }
        }

        if allInitialized() {
            print("✅ All devices initialized")

            for (uuid, s) in byUuid {
                if let dot = s.dot, dot.isConnected {
                    dot.installDefaultRecordingStatusHandler()  // ← MOVE IT HERE
                    pingRecordingStatus_locked(uuid: uuid)
                    dot.refreshSyncStatus()
                }
            }

            refreshAllStorageInfo_locked()
            return
        }


        let pending = dotsSnapshot.filter { !$0.isInitialized }.count
        print("⏳ Waiting for \(pending) device(s) to initialize...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                // Do not refresh if sync started in the meantime
                if self.syncInProgress { return }
                self.waitForAllInitialized_thenRefresh_locked()
            }
        }
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        print("❌ Connection failed (uuid=\(device.uuid))")
        stateQueue.async {
            self.advanceConnectQueue_locked()
            self.notify()
        }
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }

        stateQueue.async {
            self.recordDisconnection_locked(device.uuid)
            print("⛓️‍💥 Disconnected (uuid=\(device.uuid))")
            self.notify()
        }
    }
}
