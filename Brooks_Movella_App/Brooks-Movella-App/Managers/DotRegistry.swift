import Foundation
import MovellaDotSdk

/// Non-thread-safe state container for all DOT device bookkeeping.
/// DotManager guards every access with `stateQueue`.
final class DotRegistry {

    let sdkQueue: DispatchQueue

    init(sdkQueue: DispatchQueue) {
        self.sdkQueue = sdkQueue
    }

    struct DotState {
        var device: DotDevice
        var dot: Dot?
        var lastSeen: Date
        var connectionPhase: ConnectionPhase = .idle
    }

    // MARK: - State

    var byUuid: [String: DotState] = [:]

    var connectQueue: [String] = []
    var connectInProgress: String?

    var initializationInProgress: Set<String> = []
    var syncInProgress: Bool = false
    var syncingUuids: Set<String> = []
    var isScanningInternal: Bool = false
    /// UUIDs of every dot that was part of the most recently started recording session.
    /// Set at recording-start success; cleared when the session ends normally.
    /// Survives BT resets so that every reconnecting dot can take the skip-flash path.
    var activeRecordingUuids: Set<String> = []
    /// UUIDs of devices that individually disconnected while recording
    /// (per-device disconnect, not a BT manager reset). Consumed on reconnect.
    var uuidsRecordingOnDisconnect: Set<String> = []

    // MARK: - Snapshots

    var discovered: [DotDevice] {
        byUuid.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { $0.device }
    }

    var dots: [Dot] {
        byUuid.values.compactMap { $0.dot }
    }

    var connectedDots: [Dot] {
        byUuid.values.filter { $0.connectionPhase.isConnected }.compactMap { $0.dot }
    }

    func dot(forUuid uuid: String) -> Dot? {
        byUuid[uuid]?.dot
    }

    /// UUIDs of devices that have been connected at least once this session.
    var previouslyConnectedUuids: [String] {
        byUuid.compactMap { $0.value.dot != nil ? $0.key : nil }
    }

    func setConnectionPhase(_ uuid: String, _ phase: ConnectionPhase) {
        byUuid[uuid]?.connectionPhase = phase
        byUuid[uuid]?.dot?.setConnectionPhase(phase)
    }

    // MARK: - Mutations

    func recordDiscovery(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        if !syncingUuids.contains(uuid) {
            state.device = device
        }
        state.lastSeen = Date()
        byUuid[uuid] = state
    }

    func recordConnection(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device

        if let dot = state.dot {
            dot.updateDevice(device)
        } else {
            state.dot = Dot(device: device, sdkQueue: sdkQueue)
        }
        byUuid[uuid] = state
        initializationInProgress.insert(uuid)
        setConnectionPhase(uuid, .initializing)
    }

    /// Lightweight update for SDK-managed reconnections (e.g. during sync).
    /// Updates device reference but does NOT change the connection phase.
    /// When sync is in progress, freezes existing device references so
    /// `DotSyncManager` keeps working with the originals it was given.
    func recordReconnection(_ device: DotDevice) {
        let uuid = device.uuid
        guard var state = byUuid[uuid] else { return }
        if syncingUuids.contains(uuid) {
            print("🧊 Freeze active for \(uuid), ignoring device ref update")
        } else {
            state.device = device
            if let dot = state.dot {
                dot.updateDevice(device)
            }
        }
        state.lastSeen = Date()
        byUuid[uuid] = state
    }

    func recordDisconnection(_ uuid: String) {
        setConnectionPhase(uuid, .idle)
        byUuid[uuid]?.dot?.setSessionSynced(false)
        initializationInProgress.remove(uuid)
    }

    /// Returns the next device to connect, or nil if none ready.
    /// Removes it from the queue and sets `connectInProgress`.
    func dequeueNextConnection() -> DotDevice? {
        guard connectInProgress == nil else { return nil }
        guard !syncInProgress else { return nil }

        guard let index = connectQueue.firstIndex(where: { byUuid[$0] != nil }) else { return nil }
        let uuid = connectQueue.remove(at: index)
        guard let state = byUuid[uuid] else { return nil }

        connectInProgress = uuid
        return state.device
    }

    func advanceConnectQueue() {
        connectInProgress = nil
    }

    func markAllDisconnected() {
        for uuid in byUuid.keys {
            setConnectionPhase(uuid, .idle)
        }
    }

    func clearBusyFlags() {
        isScanningInternal = false
        connectInProgress = nil
        initializationInProgress.removeAll()
        syncInProgress = false
        syncingUuids.removeAll()
        // Per-device recording flags are irrelevant after a full BT reset —
        // activeRecordingUuids covers all devices for that case.
        uuidsRecordingOnDisconnect.removeAll()
        // Note: activeRecordingUuids is intentionally NOT cleared here —
        // every reconnecting dot needs to find its UUID in the set.
    }
}
