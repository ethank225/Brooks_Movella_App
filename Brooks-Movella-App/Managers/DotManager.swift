import Foundation
import MovellaDotSdk

// MARK: - Notifications

extension Notification.Name {
    static let dotManagerUpdated = Notification.Name("dotManagerUpdated")
}

// MARK: - DotManager (UUID-only, multi-dot safe)

final class DotManager: NSObject {

    static let shared = DotManager()

    // MARK: Public state

    /// Latest discovered devices (deduped by UUID). Persists across scans until you "fresh scan".
    private(set) var discovered: [DotDevice] = []

    /// Connected DOT wrappers. `Dot.address` is UUID.
    private(set) var dots: [Dot] = []

    private(set) var isScanning: Bool = false

    // MARK: Internal state (UUID only)

    /// Latest DotDevice per UUID (can persist across scans).
    private var discoveredByUuid: [String: DotDevice] = [:]

    /// UUIDs seen during the current scan session.
    private var seenThisScan: Set<String> = []

    /// Pending connect requests (UUIDs).
    private var pendingConnectUuids: Set<String> = []

    /// Only allow one connect attempt at a time.
    private var connectInProgressUuid: String?

    /// Whether this scan should wipe discovered first.
    private var scanIsFresh: Bool = true

    private override init() {
        super.init()
    }

    func activate() {
        DotConnectionManager.setConnectionDelegate(self)
    }

    // MARK: - Identifier helpers (UUID-only)

    private func uuid(for device: DotDevice) -> String? {
        let u = device.uuid
        return u.isEmpty ? nil : u
    }

    func displayAddress(for device: DotDevice) -> String {
        if !device.macAddress.isEmpty { return device.macAddress }
        if !device.uuid.isEmpty { return device.uuid }
        return "?"
    }

    // MARK: - Lookup

    func dot(for device: DotDevice) -> Dot? {
        guard let u = uuid(for: device) else { return nil }
        return dot(forUuid: u)
    }

    func dot(forUuid uuid: String) -> Dot? {
        dots.first { $0.address == uuid }
    }

    // MARK: - Scanning

    /// Use when you want to clear the list and rescan from scratch (pull to refresh).
    func startScanFresh() {
        scanIsFresh = true
        startScanInternal()
    }

    /// Use when you already have a dot connected and want to find more dots without wiping state.
    func startScanForMore() {
        scanIsFresh = false
        startScanInternal()
    }

    /// Backwards-compatible if you already call `startScan()` from the UI.
    /// Default to "for more" so you do not wipe state while connected.
    func startScan() {
        startScanForMore()
    }

    private func startScanInternal() {
        guard DotConnectionManager.managerStateIsPoweredOn() else {
            print("❌ Bluetooth not powered on")
            return
        }

        // Start a new scan session tracker
        seenThisScan.removeAll()

        if scanIsFresh {
            // Only wipe discovered when explicitly requested
            discoveredByUuid.removeAll()
            discovered.removeAll()
        }

        // Avoid spamming scan calls
        if isScanning {
            print("🔍 Scan already running")
            notify()
            return
        }

        isScanning = true
        DotConnectionManager.scan()

        print("🔍 Scan started (\(scanIsFresh ? "fresh" : "for more"))")
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
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let inserted = pendingConnectUuids.insert(trimmed).inserted
        if inserted {
            print("🔗 Queued connect for UUID \(trimmed) (pending: \(pendingConnectUuids.count))")
        }

        // Ensure we are scanning for more devices (do not wipe state)
        if !isScanning {
            startScanForMore()
        }

        // If already discovered, we can attempt immediately
        attemptNextConnection()
        notify()
    }

    func disconnect(_ dot: Dot) {
        DotConnectionManager.disconnect(dot.device)
    }

    func disconnectAll() {
        dots.forEach { DotConnectionManager.disconnect($0.device) }
    }

    // MARK: - Connection serialization

    private func attemptNextConnection() {
        if connectInProgressUuid != nil { return }

        // Find a pending UUID that we already have a DotDevice for
        guard let nextUuid = pendingConnectUuids.first(where: { discoveredByUuid[$0] != nil }) else {
            return
        }
        guard let device = discoveredByUuid[nextUuid] else { return }

        connectInProgressUuid = nextUuid
        pendingConnectUuids.remove(nextUuid)

        print("🔗 Connecting (serialized) to \(displayAddress(for: device)) (uuid=\(nextUuid))")
        DotConnectionManager.connect(device)
    }

    // MARK: - Configuration

    func configureAll(outputRate: Int = 60, filterIndex: Int = 0) {
        dots.forEach { $0.configure(outputRate: outputRate, filterIndex: filterIndex) }
        print("⚙️ Configured all \(dots.count) dots: \(outputRate)Hz, filter \(filterIndex)")
    }

    // MARK: - Recording

    func startRecordingAll(seconds: UInt16 = 0xFFFF,
                           completion: @escaping (Bool) -> Void) {
        guard !dots.isEmpty else { completion(false); return }

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
        guard !dots.isEmpty else { completion(false); return }

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

    // MARK: - Notifications

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

        // Update discovered list from dictionary (persists unless fresh scan cleared it)
        discovered = Array(discoveredByUuid.values)
        discovered.sort { $0.uuid < $1.uuid }

        if !pendingConnectUuids.isEmpty {
            print("⚠️ Scan completed, still pending UUIDs: \(pendingConnectUuids)")
        }

        print("🔍 Scan completed — total known devices: \(discovered.count)")
        notify()

        // If we still have pending connects, scanning ended before we found them.
        // Kick another scan for more (does not wipe).
        if !pendingConnectUuids.isEmpty {
            startScanForMore()
        }
    }

    func onDiscover(_ device: DotDevice) {
        guard let u = uuid(for: device) else {
            print("⚠️ Discovered device without UUID")
            return
        }

        seenThisScan.insert(u)

        // Persist latest device reference
        discoveredByUuid[u] = device

        // Live-update list
        discovered = Array(discoveredByUuid.values)
        discovered.sort { $0.uuid < $1.uuid }
        notify()

        // If this was pending or we are idle, attempt next serialized connection
        if pendingConnectUuids.contains(u) || connectInProgressUuid == nil {
            attemptNextConnection()
        }
    }

    func onDeviceConnectSucceeded(_ device: DotDevice) {
        guard let u = uuid(for: device) else {
            print("✅ Connected, but missing UUID")
            connectInProgressUuid = nil
            attemptNextConnection()
            notify()
            return
        }

        if let existing = dots.first(where: { $0.address == u }) {
            existing.isConnected = true
            print("✅ Reconnected: \(displayAddress(for: device)) (uuid=\(u))")
        } else {
            let dot = Dot(device: device)
            dot.isConnected = true
            dots.append(dot)
            print("✅ Connected: \(displayAddress(for: device)) (uuid=\(u)) Total: \(dots.count)")
        }

        notify()

        // Advance queue
        connectInProgressUuid = nil
        attemptNextConnection()

        // Keep scanning for more devices if user is still scanning (do not stop scan early)
        // No action needed; scan continues until SDK completes.
    }

    func onDeviceConnectFailed(_ device: DotDevice) {
        let u = uuid(for: device) ?? "?"
        print("❌ Connection failed: \(displayAddress(for: device)) (uuid=\(u))")

        notify()

        // Advance queue even on failure
        connectInProgressUuid = nil
        attemptNextConnection()
    }

    func onDeviceDisconnected(_ device: DotDevice) {
        let u = uuid(for: device) ?? "?"
        print("⛓️‍💥 Disconnected: \(displayAddress(for: device)) (uuid=\(u))")

        if let existing = dots.first(where: { $0.address == u }) {
            existing.isConnected = false
        }

        notify()

        // IMPORTANT:
        // Do NOT auto-start a scan here. The SDK is already handling teardown.
        // Let the user initiate scanning for more, or scan periodically from UI.
    }
}
