import Foundation
import MovellaDotSdk

// Notification used by all views to refresh UI when BLE state changes
extension Notification.Name {
    static let dotManagerUpdated = Notification.Name("dotManagerUpdated")
}

final class DotManager: NSObject {

    // Singleton: one BLE brain for the entire app
    static let shared = DotManager()

    // MARK: - Per-device model

    /// App-level state for a single sensor, keyed by UUID
    struct DotState {
        var device: DotDevice      // Latest SDK handle from scanning
        var dot: Dot?              // Our wrapper, exists only after a successful connect
        var isConnected: Bool      // App belief about connection state
        var lastSeen: Date         // Used to order discovered list
    }

    // MARK: - Source of truth

    /// All known sensors, indexed by UUID
    /// This is the ONLY place sensor state lives
    /// This creates a dictionary where the key is the UUID and the value is the DotState
    /// Dot State contains the DotDevice object, isConnected, and lastSeen
    private var byUuid: [String: DotState] = [:]

    /// Whether a scan is currently running
    private(set) var isScanning = false

    // MARK: - Connection serialization

    /// Queue of UUIDs waiting to be connected
    /// Prevents multiple simultaneous connects
    private var connectQueue: [String] = []

    /// UUID currently in a connect attempt
    private var connectInProgress: String?

    private override init() {
        super.init()
    }

    /// Must be called once (e.g. on first view appear)
    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
    }

    // MARK: - Read-only views for UI

    /// Devices to show in the Connect screen
    /// Derived from dictionary, never stored separately
    var discovered: [DotDevice] {
        byUuid.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { $0.device }
    }

    /// All Dot wrappers we have ever created
    var dots: [Dot] {
        byUuid.values.compactMap { $0.dot }
    }

    /// Only currently connected dots
    var connectedDots: [Dot] {
        byUuid.values.compactMap { state in
            guard state.isConnected else { return nil }
            return state.dot
        }
    }

    /// Lookup helper for UI / other screens
    func dot(forUuid uuid: String) -> Dot? {
        byUuid[uuid]?.dot
    }

    /// Human-readable identifier for display only
    /// UUID is identity, MAC is cosmetic
    func displayAddress(for device: DotDevice) -> String {
        if !device.macAddress.isEmpty { return device.macAddress }
        if !device.uuid.isEmpty { return device.uuid }
        return "?"
    }

    // MARK: - Scanning

    /// Starts a BLE scan if not already scanning
    /// Scanning is required to obtain valid DotDevice references
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

    /// Stops an active scan
    func stopScan() {
        DotConnectionManager.stopScan()
        isScanning = false
        print("🔍 Scan stopped")
        notify()
    }

    // MARK: - Connect / Disconnect API

    /// Request a connection by UUID
    /// Actual connect happens later when DotDevice is available
    func connectByUuid(_ uuid: String) {
        let u = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }

        // Avoid duplicate queue entries
        if !connectQueue.contains(u) && connectInProgress != u {
            connectQueue.append(u)
        }

        // Scanning is required to resolve UUID -> DotDevice
        startScan()

        // Attempt connection if possible
        attemptNextConnect()
        notify()
    }

    /// Disconnects an already-connected Dot
    func disconnect(_ dot: Dot) {
        DotConnectionManager.disconnect(dot.device)
    }

    // MARK: - Internal connection scheduler

    /// Starts the next connect if:
    /// - nothing is currently connecting
    /// - a queued UUID has been discovered
    private func attemptNextConnect() {
        guard connectInProgress == nil else { return }

        // Find next UUID whose DotDevice we already have
        guard let nextIndex = connectQueue.firstIndex(where: { byUuid[$0] != nil }) else {
            return
        }

        let u = connectQueue.remove(at: nextIndex)
        guard let state = byUuid[u] else { return }

        connectInProgress = u
        print("🔗 Connecting to \(displayAddress(for: state.device)) (uuid=\(u))")
        DotConnectionManager.connect(state.device)
    }

    /// Notify all views that state changed
    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dotManagerUpdated, object: nil)
        }
    }
}

// MARK: - SDK Callbacks

extension DotManager: DotConnectionDelegate {

    /// Bluetooth power / readiness updates
    func onManagerStateUpdate(_ managerState: XSDotManagerState) {
        print("📡 Bluetooth state: \(managerState.rawValue)")
        notify()
    }

    /// Fired whenever a device is seen during a scan
    func onDiscover(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        let u = device.uuid
        let now = Date()

        // Update existing entry or create a new one
        if var existing = byUuid[u] {
            existing.device = device
            existing.lastSeen = now
            byUuid[u] = existing
        } else {
            byUuid[u] = DotState(
                device: device,
                dot: nil,
                isConnected: false,
                lastSeen: now
            )
        }

        // If this UUID was queued for connection, try now
        attemptNextConnect()
        notify()
    }

    /// Fired when the SDK finishes a scan cycle
    func onScanCompleted() {
        isScanning = false
        print("🔍 Scan completed — known devices: \(byUuid.count)")
        notify()

        // If we are still waiting to connect to something,
        // restart scanning to find it
        if !connectQueue.isEmpty {
            startScan()
        }
    }

    /// Fired after a successful connection
    func onDeviceConnectSucceeded(_ device: DotDevice) {
        guard !device.uuid.isEmpty else {
            connectInProgress = nil
            attemptNextConnect()
            notify()
            return
        }

        let u = device.uuid

        // Ensure state exists
        var state = byUuid[u] ?? DotState(
            device: device,
            dot: nil,
            isConnected: false,
            lastSeen: Date()
        )

        state.device = device
        state.lastSeen = Date()

        // Create or reuse Dot wrapper
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

        // Advance connection queue
        connectInProgress = nil
        attemptNextConnect()
        notify()
    }

    /// Fired if a connection attempt fails
    func onDeviceConnectFailed(_ device: DotDevice) {
        let u = device.uuid
        print("❌ Connection failed (uuid=\(u))")

        connectInProgress = nil
        attemptNextConnect()
        notify()
    }

    /// Fired when an existing connection drops
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
