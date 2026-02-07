import Foundation
import MovellaDotSdk

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
    }

    // MARK: - Queues

    /// Serializes DotManager state (byUuid, flags, etc.)
    private let stateQueue = DispatchQueue(label: "DotManager.stateQueue")

    /// Serializes all SDK calls (connect, scan, sync, operations)
    private let sdkQueue = DispatchQueue(label: "DotManager.sdkQueue")

    // MARK: - State (ONLY touch on stateQueue)

    private var byUuid: [String: DotState] = [:]

    private var connectQueue: [String] = []
    private var connectInProgress: String?
    
    // We treat "initializing" as a busy state to prevent interfering with setup
    private var initializationInProgress: Set<String> = []

    private var syncInProgress: Bool = false
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

    // MARK: - Scanning

    func startScan() {
        stateQueue.async {
            if self.isScanningInternal { return }

            self.sdkQueue.async {
                guard DotConnectionManager.managerStateIsPoweredOn() else {
                    print("❌ Bluetooth not powered on")
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
            if self.connectQueue.contains(u) || self.connectInProgress == u { return }
            self.connectQueue.append(u)
            
            // Start scanning to find it if we haven't yet
            self.startScan()
            
            // Attempt connection
            self.processConnectQueue_locked()
            self.notify()
        }
    }

    func disconnect(_ dot: Dot) {
        sdkQueue.async {
            DotDevicePool.unbindDevice(dot.device)
            DotConnectionManager.disconnect(dot.device)
        }
    }

    // MARK: - Sync

    func syncConnectedDots(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress || !self.initializationInProgress.isEmpty {
                print("⚠️ Cannot sync: busy initializing or syncing")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            // 1. Gather devices
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

            // 2. Run on SDK Queue
            self.sdkQueue.async { [weak self] in
                guard let self else { return }

                DotSyncManager.startSync(devices) { results in
                    self.stateQueue.async {
                        self.syncInProgress = false
                        
                        guard let results = results as? [[String: Any]] else {
                            print("❌ Sync failed - no results")
                            dotsSnapshot.forEach { $0.setSessionSynced(false) }
                            self.notify()
                            DispatchQueue.main.async { completion(false) }
                            return
                        }

                        var allSuccess = true
                        for result in results {
                            let success = result["success"] as? Bool ?? false
                            if !success { allSuccess = false }
                        }

                        dotsSnapshot.forEach { $0.setSessionSynced(allSuccess) }
                        print(allSuccess ? "✅ Sync completed" : "❌ Sync failed")
                        
                        // Refresh storage for everyone after sync
                        self.queueStorageRefresh_locked(dots: dotsSnapshot)
                        
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
            
            dotsSnapshot.forEach { $0.setSessionSynced(false) }
            self.syncInProgress = false
            self.notify()

            self.sdkQueue.async {
                DotSyncManager.stopSync(devices)
            }
        }
    }

    // MARK: - Operations (Recording / Flash)
    
    func startRecordingAll(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }
            
            self.sdkQueue.async {
                self.executeSequentially(items: dotsSnapshot) { dot, done in
                    dot.startRecording(seconds: 0xFFFF, completion: done)
                } completion: { ok in
                    DispatchQueue.main.async { completion(ok) }
                }
            }
        }
    }

    func stopRecordingAll(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.byUuid.values.compactMap { $0.dot }.filter { $0.isConnected }
            
            self.sdkQueue.async {
                self.executeSequentially(items: dotsSnapshot) { dot, done in
                    dot.stopRecording(completion: done)
                } completion: { ok in
                    DispatchQueue.main.async { completion(ok) }
                }
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
                self.executeSequentially(items: dotsSnapshot) { dot, done in
                    dot.eraseFlash(completion: done)
                } completion: { ok in
                    DispatchQueue.main.async { completion(ok) }
                }
            }
        }
    }
    
    // MARK: - Storage Refresh Queueing
    
    /// Recursively fetches flash info until the value remains constant between checks.
    /// Checks `isInitialized` on the background thread before asking for storage
    // MARK: - Storage Refresh Queueing (Snapshot Version)
        
        private func queueStorageRefresh_locked(dots: [Dot]) {
            guard !dots.isEmpty else { return }

            print("💾 Queueing storage refresh for \(dots.count) dots")

            self.sdkQueue.async { [weak self] in
                guard let self = self else { return }

                self.executeSequentially(items: dots) { dot, done in
                    self.waitForInitialization(dot: dot, timeout: 5.0) { ready in
                        let uuid = dot.device.uuid

                        if !ready {
                            print("⚠️ [\(dot.address)] Not initialized, skipping storage refresh")
                            self.stateQueue.async {
                                self.initializationInProgress.remove(uuid)
                                self.notify()
                            }
                            done(false)
                            return
                        }

                        // 🚀 ONE-SHOT REFRESH
                        // The Dot object captures its own snapshot inside getFlashInfo.
                        dot.getFlashInfo { _ in
                            self.stateQueue.async {
                                self.initializationInProgress.remove(uuid)
                                self.notify()
                                done(true)
                            }
                        }
                    }
                } completion: { _ in
                    print("💾 Storage refresh queue finished")
                }
            }
        }

    
    /// Blocks the SDK queue (sleeps) briefly while waiting for a single dot to initialize.
    /// Safe because we are on a background serial queue.
    private func waitForInitialization(dot: Dot, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let start = Date()
        
        func check() {
            if dot.isInitialized {
                completion(true)
                return
            }
            
            if Date().timeIntervalSince(start) > timeout {
                completion(false)
                return
            }
            
            // Sleep briefly on sdkQueue to let the SDK work on other threads
            Thread.sleep(forTimeInterval: 0.2)
            check()
        }
        
        check()
    }

    // MARK: - Connection Queue Processing (LOCKED)

    private func processConnectQueue_locked() {
        guard connectInProgress == nil else { return }
        guard !syncInProgress else { return }

        guard let index = connectQueue.firstIndex(where: { byUuid[$0] != nil }) else { return }
        let uuid = connectQueue.remove(at: index)
        guard let state = byUuid[uuid] else { return }

        connectInProgress = uuid
        print("🔗 Connecting to \(displayAddress(for: state.device))")

        sdkQueue.async {
            DotConnectionManager.connect(state.device)
        }
    }

    private func advanceConnectQueue_locked() {
        connectInProgress = nil
        processConnectQueue_locked()
    }

    // MARK: - Internal Helpers
    
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
    
    private func recordDiscovery_locked(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device
        state.lastSeen = Date()
        byUuid[uuid] = state
    }

    private func recordConnection_locked(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device
        
        if let dot = state.dot {
            dot.updateDevice(device)
            dot.setIsConnected(true)
        } else {
            let dot = Dot(device: device)
            dot.setIsConnected(true)
            state.dot = dot
        }
        byUuid[uuid] = state
        
        // Mark as initializing
        initializationInProgress.insert(uuid)
    }
    
    private func recordDisconnection_locked(_ uuid: String) {
        byUuid[uuid]?.dot?.setIsConnected(false)
        initializationInProgress.remove(uuid)
    }
    
    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.updated, object: nil)
        }
    }
    
    // MARK: - Debug
    
    func printStatus() {
        stateQueue.sync {
            print("--- DotManager Status ---")
            print("Dots: \(byUuid.count) | Connected: \(connectedDots.count)")
            print("Connect Queue: \(connectQueue.count)")
            print("Init Queue: \(initializationInProgress)")
        }
    }
    
    func displayAddress(for device: DotDevice) -> String {
        !device.macAddress.isEmpty ? device.macAddress : device.uuid
    }
}

// MARK: - SDK Delegate

extension DotManager: DotConnectionDelegate {

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
            print("🔍 Scan completed")
            self.notify()
            if !self.connectQueue.isEmpty { self.startScan() }
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        stateQueue.async {
            guard !device.uuid.isEmpty else {
                self.advanceConnectQueue_locked()
                return
            }

            self.recordConnection_locked(device)
            
            // 1. Bind immediately on SDK queue
            self.sdkQueue.async {
                DotDevicePool.bindDevice(device)
            }
            
            // 2. Queue the "Initialize & Refresh" task on SDK queue
            //    This replaces the old "wait loop".
            if let dot = self.byUuid[device.uuid]?.dot {
                print("⏳ [\(device.uuid)] Queuing initialization & storage refresh...")
                
                self.queueStorageRefresh_locked(dots: [dot])
                
                // Once that block is submitted to sdkQueue, we can move on to connecting the next device
                // The refresh will happen in the background when this device is ready.
                self.advanceConnectQueue_locked()
                self.notify()
            }
        }
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        print("❌ Connect failed: \(device.uuid)")
        stateQueue.async {
            self.advanceConnectQueue_locked()
            self.notify()
        }
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        print("⛓️‍💥 Disconnected: \(device.uuid)")
        stateQueue.async {
            self.recordDisconnection_locked(device.uuid)
            self.notify()
        }
    }
    
    func onManagerStateUpdate(_ managerState: XSDotManagerState) {
        // Handle bluetooth power off if needed
    }
}
