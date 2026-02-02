import Foundation
import MovellaDotSdk

extension Notification.Name {
    static let dotManagerUpdated = Notification.Name("dotManagerUpdated")
}

final class DotManager: NSObject {

    static let shared = DotManager()

    // MARK: - Model

    struct DotState {
        var device: DotDevice
        var dot: Dot?              // Present if we've wrapped/connected before
        var isConnected: Bool
        var lastSeen: Date
    }

    // MARK: - State (single source of truth)

    private var byUuid: [String: DotState] = [:]

    private(set) var isScanning = false

    // Connect queue (serialized)
    private var connectQueue: [String] = []
    private var connectInProgress: String?

    private override init() {
        super.init()
    }

    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
    }

    // MARK: - Public computed views

    var discovered: [DotDevice] {
        byUuid.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { $0.device }
    }

    var dots: [Dot] {
        byUuid.values.compactMap { $0.dot }
    }

    var connectedDots: [Dot] {
        byUuid.values.compactMap { state in
            guard state.isConnected else { return nil }
            return state.dot
        }
    }

    func dot(forUuid uuid: String) -> Dot? {
        byUuid[uuid]?.dot
    }

    func displayAddress(for device: DotDevice) -> String {
        if !device.macAddress.isEmpty { return device.macAddress }
        if !device.uuid.isEmpty { return device.uuid }
        return "?"
    }

    // MARK: - Scanning

    func startScan() {
        guard DotConnectionManager.managerStateIsPoweredOn() else {
            print("❌ Bluetooth not powered on")
            return
        }
        guard !isScanning else { return }

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

    // MARK: - Connect / Disconnect

    func connectByUuid(_ uuid: String) {
        let u = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }

        if !connectQueue.contains(u) && connectInProgress != u {
            connectQueue.append(u)
        }

        // Ensure scanning to discover the DotDevice if we do not have it yet
        startScan()
        attemptNextConnect()
        notify()
    }

    func disconnect(_ dot: Dot) {
        DotConnectionManager.disconnect(dot.device)
    }

    // MARK: - Internals

    private func attemptNextConnect() {
        guard connectInProgress == nil else { return }

        // Find next UUID where we actually have a DotDevice reference
        guard let nextIndex = connectQueue.firstIndex(where: { byUuid[$0] != nil }) else { return }
        let u = connectQueue.remove(at: nextIndex)

        guard let state = byUuid[u] else { return }

        connectInProgress = u
        print("🔗 Connecting to \(displayAddress(for: state.device)) (uuid=\(u))")
        DotConnectionManager.connect(state.device)
    }

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

    func onDiscover(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        let u = device.uuid

        let now = Date()

        if var existing = byUuid[u] {
            existing.device = device
            existing.lastSeen = now
            byUuid[u] = existing
        } else {
            byUuid[u] = DotState(device: device, dot: nil, isConnected: false, lastSeen: now)
        }

        // If we were waiting to connect this UUID, advance queue
        attemptNextConnect()
        notify()
    }

    func onScanCompleted() {
        isScanning = false
        print("🔍 Scan completed — known devices: \(byUuid.count)")
        notify()

        // If we still have queued connects, keep scanning until we discover them
        if !connectQueue.isEmpty {
            startScan()
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        guard !device.uuid.isEmpty else {
            connectInProgress = nil
            attemptNextConnect()
            notify()
            return
        }

        let u = device.uuid

        var state = byUuid[u] ?? DotState(device: device, dot: nil, isConnected: false, lastSeen: Date())
        state.device = device
        state.lastSeen = Date()

        if let dot = state.dot {
            dot.isConnected = true
            state.isConnected = true
        } else {
            let dot = Dot(device: device)
            dot.isConnected = true
            state.dot = dot
            state.isConnected = true
        }

        byUuid[u] = state

        print("✅ Connected (uuid=\(u))")
        connectInProgress = nil
        attemptNextConnect()
        notify()
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        let u = device.uuid
        print("❌ Connection failed (uuid=\(u))")

        connectInProgress = nil
        attemptNextConnect()
        notify()
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        let u = device.uuid

        if var state = byUuid[u] {
            state.isConnected = false
            state.dot?.isConnected = false
            byUuid[u] = state
        }

        print("⛓️‍💥 Disconnected (uuid=\(u))")
        notify()
    }
}
