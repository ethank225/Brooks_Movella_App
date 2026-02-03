import Foundation
import MovellaDotSdk

// MARK: - DotManager

/// Central coordinator for all Movella DOT sensor interactions.
/// Manages discovery, connection queue, and serves as the SDK delegate.
///
/// Usage:
///   1. Call `DotManager.shared.activate()` once at app launch
///   2. Use `startScan()` to discover nearby sensors
///   3. Use `connectByUuid(_:)` to connect (queues if not yet discovered)
///   4. Observe `.dotManagerUpdated` notification for UI updates
///
final class DotManager: NSObject {
    
    // MARK: - Singleton
    
    static let shared = DotManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Types
    
    /// Notification broadcast whenever any state changes (scan, connect, disconnect)
    enum Notification {
        static let updated = Foundation.Notification.Name("dotManagerUpdated")
    }
    
    /// Internal bookkeeping for a discovered sensor
    struct DotState {
        var device: DotDevice   // SDK handle (refreshed on each scan)
        var dot: Dot?           // App wrapper (created on first successful connect)
        var lastSeen: Date      // For sorting discovered list
    }
    
    // MARK: - State: Discovery
    
    /// All known sensors by UUID — the single source of truth for discovery
    private var byUuid: [String: DotState] = [:]
    
    /// Whether a BLE scan is currently active
    private(set) var isScanning = false
    
    // MARK: - State: Connection Queue
    
    /// UUIDs waiting to be connected (processed in order as devices are discovered)
    private var connectQueue: [String] = []
    
    /// UUID currently attempting to connect (only one at a time)
    private var connectInProgress: String?
    
    // MARK: - Lifecycle
    
    /// Call once at app startup to register as the SDK delegate
    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
    }
    
    // MARK: - Public API: Queries
    
    /// All discovered devices, sorted by most recently seen
    var discovered: [DotDevice] {
        byUuid.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { $0.device }
    }
    
    /// All Dot wrappers ever created (connected or not)
    var dots: [Dot] {
        byUuid.values.compactMap { $0.dot }
    }
    
    /// Only currently connected Dots
    var connectedDots: [Dot] {
        dots.filter { $0.isConnected }
    }
    
    /// Lookup a Dot by UUID (nil if never connected)
    func dot(forUuid uuid: String) -> Dot? {
        byUuid[uuid]?.dot
    }
    
    /// Check connection status by UUID
    func isConnected(forUuid uuid: String) -> Bool {
        byUuid[uuid]?.dot?.isConnected ?? false
    }
    
    /// Human-readable address for display (prefers MAC, falls back to UUID)
    func displayAddress(for device: DotDevice) -> String {
        if !device.macAddress.isEmpty { return device.macAddress }
        if !device.uuid.isEmpty { return device.uuid }
        return "?"
    }
    
    // MARK: - Public API: Scanning
    
    /// Start scanning for nearby sensors
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
    
    /// Stop any active scan
    func stopScan() {
        DotConnectionManager.stopScan()
        isScanning = false
        print("🔍 Scan stopped")
        notify()
    }
    
    // MARK: - Public API: Connection
    
    /// Request connection to a sensor by UUID.
    /// If not yet discovered, it will be queued and connected once found.
    func connectByUuid(_ uuid: String) {
        let u = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        
        // Avoid duplicate queue entries
        guard !connectQueue.contains(u), connectInProgress != u else { return }
        connectQueue.append(u)
        
        // Start scanning to find the device (if not already)
        startScan()
        
        // Try to connect immediately if already discovered
        processConnectQueue()
        notify()
    }
    
    /// Disconnect a connected sensor
    func disconnect(_ dot: Dot) {
        DotConnectionManager.disconnect(dot.device)
    }
    
    // MARK: - Private: Connection Queue Processing
    
    /// Attempt to connect the next queued UUID (if its device has been discovered)
    private func processConnectQueue() {
        // Only one connection attempt at a time
        guard connectInProgress == nil else { return }
        
        // Find the first queued UUID we have a device for
        guard let index = connectQueue.firstIndex(where: { byUuid[$0] != nil }) else { return }
        
        let uuid = connectQueue.remove(at: index)
        guard let state = byUuid[uuid] else { return }
        
        connectInProgress = uuid
        print("🔗 Connecting to \(displayAddress(for: state.device)) (uuid=\(uuid))")
        DotConnectionManager.connect(state.device)
    }
    
    /// Clear the in-progress flag and try the next queued connection
    private func advanceConnectQueue() {
        connectInProgress = nil
        processConnectQueue()
    }
    
    // MARK: - Private: State Updates
    
    /// Record a discovered device (called from SDK callback)
    private func recordDiscovery(_ device: DotDevice) {
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
    
    /// Create or update Dot wrapper on successful connection
    private func recordConnection(_ device: DotDevice) {
        let uuid = device.uuid
        
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device
        state.lastSeen = Date()
        
        if let dot = state.dot {
            dot.isConnected = true
        } else {
            let dot = Dot(device: device)
            dot.isConnected = true
            state.dot = dot
        }
        
        byUuid[uuid] = state
    }
    
    /// Mark a Dot as disconnected
    private func recordDisconnection(_ uuid: String) {
        byUuid[uuid]?.dot?.isConnected = false
    }
    
    // MARK: - Private: Notifications
    
    /// Broadcast state change to all observers
    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.updated, object: nil)
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
        
        recordDiscovery(device)
        processConnectQueue()  // Maybe we can now connect a queued UUID
        notify()
    }
    
    func onScanCompleted() {
        isScanning = false
        print("🔍 Scan completed — known devices: \(byUuid.count)")
        notify()
        
        // Keep scanning if we still have pending connections
        if !connectQueue.isEmpty {
            startScan()
        }
    }
    
    func onDeviceConnectSucceeded(_ device: DotDevice) {
        guard !device.uuid.isEmpty else {
            advanceConnectQueue()
            notify()
            return
        }
        
        recordConnection(device)
        print("✅ Connected (uuid=\(device.uuid))")
        
        advanceConnectQueue()
        notify()
    }
    
    func onDeviceConnectFailed(_ device: DotDevice) {
        print("❌ Connection failed (uuid=\(device.uuid))")
        
        advanceConnectQueue()
        notify()
    }
    
    func onDeviceDisconnected(_ device: DotDevice) {
        guard !device.uuid.isEmpty else { return }
        
        recordDisconnection(device.uuid)
        print("⛓️‍💥 Disconnected (uuid=\(device.uuid))")
        notify()
    }
}
