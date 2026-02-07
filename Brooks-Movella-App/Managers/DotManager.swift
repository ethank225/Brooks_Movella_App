import Foundation
import Combine
import MovellaDotSdk

final class DotManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = DotManager()

    private override init() {
        super.init()
    }

    // MARK: - Queues

    private let stateQueue = DispatchQueue(label: "DotManager.stateQueue")
    private let sdkQueue = DispatchQueue(label: "DotManager.sdkQueue")

    // MARK: - Components

    private let registry = DotRegistry()
    private lazy var scanner = DotScanner(sdkQueue: sdkQueue)
    private lazy var operations = DotOperationRunner(sdkQueue: sdkQueue)

    // MARK: - Lifecycle

    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
        DotReconnectManager.setEnable(true)
    }

    // MARK: - Published state for UI

    @Published private(set) var isScanning: Bool = false
    @Published private(set) var discovered: [DotDevice] = []
    @Published private(set) var dots: [Dot] = []
    @Published private(set) var connectedDots: [Dot] = []

    func dot(forUuid uuid: String) -> Dot? {
        stateQueue.sync { registry.dot(forUuid: uuid) }
    }

    // MARK: - Scanning

    func startScan() {
        stateQueue.async {
            if self.registry.isScanningInternal { return }

            self.scanner.scan { [weak self] in
                self?.stateQueue.async {
                    guard let self, !self.registry.isScanningInternal else { return }
                    self.registry.isScanningInternal = true
                    print("🔍 Scan started")
                    self.notify()
                }
            }
        }
    }

    func stopScan() {
        stateQueue.async {
            if !self.registry.isScanningInternal { return }
            self.registry.isScanningInternal = false
            print("🔍 Scan stopped")
            self.notify()

            self.scanner.stopScan()
        }
    }

    // MARK: - Connection

    func connectByUuid(_ uuid: String) {
        let u = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }

        stateQueue.async {
            if self.registry.connectQueue.contains(u) || self.registry.connectInProgress == u { return }
            self.registry.connectQueue.append(u)

            self.startScan()

            self.processConnectQueue()
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
            if self.registry.syncInProgress || !self.registry.initializationInProgress.isEmpty {
                print("⚠️ Cannot sync: busy initializing or syncing")
                DispatchQueue.main.async { completion(false) }
                return
            }

            let dotsSnapshot = self.registry.connectedDots
            let devices = dotsSnapshot.map { $0.device }

            guard devices.count >= 2 else {
                print("⚠️ Need at least 2 connected dots to sync")
                DispatchQueue.main.async { completion(false) }
                return
            }

            self.registry.syncInProgress = true
            print("🔄 Starting sync with \(devices.count) devices...")
            self.notify()

            self.sdkQueue.async { [weak self] in
                guard let self else { return }

                DotSyncManager.startSync(devices) { results in
                    self.stateQueue.async {
                        self.registry.syncInProgress = false

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

                        self.refreshStorage(dots: dotsSnapshot)

                        self.notify()
                        DispatchQueue.main.async { completion(allSuccess) }
                    }
                }
            }
        }
    }

    func stopSync() {
        stateQueue.async {
            let dotsSnapshot = self.registry.connectedDots
            let devices = dotsSnapshot.map { $0.device }

            dotsSnapshot.forEach { $0.setSessionSynced(false) }
            self.registry.syncInProgress = false
            self.notify()

            self.sdkQueue.async {
                DotSyncManager.stopSync(devices)
            }
        }
    }

    // MARK: - Operations (Recording / Flash)

    func startRecordingAll(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.registry.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.registry.connectedDots

            self.operations.runAll(
                dots: dotsSnapshot,
                operation: { dot, done in dot.startRecording(seconds: 0xFFFF, completion: done) },
                completion: completion
            )
        }
    }

    func stopRecordingAll(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.registry.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.registry.connectedDots

            self.operations.runAll(
                dots: dotsSnapshot,
                operation: { dot, done in dot.stopRecording(completion: done) },
                completion: completion
            )
        }
    }

    func eraseAllFlash(completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            if self.registry.syncInProgress {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dotsSnapshot = self.registry.connectedDots

            self.operations.runAll(
                dots: dotsSnapshot,
                operation: { dot, done in dot.eraseFlash(completion: done) },
                completion: completion
            )
        }
    }

    // MARK: - Internal Helpers

    /// Must be called on stateQueue.
    private func processConnectQueue() {
        guard let device = registry.dequeueNextConnection() else { return }
        print("🔗 Connecting to \(displayAddress(for: device))")

        sdkQueue.async {
            DotConnectionManager.connect(device)
        }
    }

    /// Must be called on stateQueue.
    private func refreshStorage(dots: [Dot]) {
        operations.refreshStorage(dots: dots) { [weak self] dot, _ in
            self?.stateQueue.async {
                self?.registry.initializationInProgress.remove(dot.device.uuid)
                self?.notify()
            }
        } completion: {}
    }

    /// Must be called on stateQueue.
    private func notify() {
        let scanning = registry.isScanningInternal
        let disc = registry.discovered
        let all = registry.dots
        let connected = registry.connectedDots

        DispatchQueue.main.async {
            self.isScanning = scanning
            self.discovered = disc
            self.dots = all
            self.connectedDots = connected
        }
    }

    // MARK: - Debug

    func printStatus() {
        stateQueue.sync {
            print("--- DotManager Status ---")
            print("Dots: \(registry.byUuid.count) | Connected: \(registry.connectedDots.count)")
            print("Connect Queue: \(registry.connectQueue.count)")
            print("Init Queue: \(registry.initializationInProgress)")
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
            self.registry.recordDiscovery(device)
            self.processConnectQueue()
            self.notify()
        }
    }

    func onScanCompleted() {
        stateQueue.async {
            self.registry.isScanningInternal = false
            print("🔍 Scan completed")
            self.notify()
            if !self.registry.connectQueue.isEmpty { self.startScan() }
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        stateQueue.async {
            guard !device.uuid.isEmpty else {
                self.registry.advanceConnectQueue()
                self.processConnectQueue()
                return
            }

            // During sync, the SDK reconnects devices internally.
            // Update device reference but skip re-bind, refresh, and UI notify
            // since dots were never shown as disconnected.
            if self.registry.syncInProgress {
                self.registry.recordReconnection(device)
                return
            }

            self.registry.recordConnection(device)

            self.sdkQueue.async {
                DotDevicePool.bindDevice(device)
            }

            if let dot = self.registry.dot(forUuid: device.uuid) {
                print("⏳ [\(device.uuid)] Queuing initialization & storage refresh...")

                self.refreshStorage(dots: [dot])

                self.registry.advanceConnectQueue()
                self.processConnectQueue()
                self.notify()
            }
        }
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        print("❌ Connect failed: \(device.uuid)")
        stateQueue.async {
            if self.registry.syncInProgress { return }
            self.registry.advanceConnectQueue()
            self.processConnectQueue()
            self.notify()
        }
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        print("⛓️‍💥 Disconnected: \(device.uuid)")
        stateQueue.async {
            if self.registry.syncInProgress {
                // SDK-managed disconnect during sync — ignore entirely.
                // The dots remain visually "connected" throughout the sync process.
                return
            }
            self.registry.recordDisconnection(device.uuid)
            self.notify()
        }
    }

    func onManagerStateUpdate(_ managerState: XSDotManagerState) {
        stateQueue.async {
            switch managerState {
            case .poweredOn:
                print("✅ Bluetooth powered ON")

                // Re-queue all previously connected devices for reconnection
                for uuid in self.registry.previouslyConnectedUuids {
                    if !self.registry.connectQueue.contains(uuid) {
                        self.registry.connectQueue.append(uuid)
                    }
                }

                if !self.registry.connectQueue.isEmpty {
                    print("🔄 Resuming connection logic for \(self.registry.connectQueue.count) pending devices...")
                    self.registry.isScanningInternal = false
                    self.startScan()
                }

            case .poweredOff, .resetting:
                print("⚠️ Bluetooth powered OFF/RESET")
                self.registry.clearBusyFlags()
                self.registry.markAllDisconnected()
                self.notify()

            case .unauthorized, .unsupported:
                print("❌ Bluetooth Error: \(managerState.rawValue)")

            @unknown default:
                break
            }
        }
    }
}
