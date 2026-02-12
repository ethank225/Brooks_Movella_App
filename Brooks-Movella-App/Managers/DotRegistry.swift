import Foundation
import MovellaDotSdk

/// Non-thread-safe state container for all DOT device bookkeeping.
/// DotManager guards every access with `stateQueue`.
final class DotRegistry {

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
    var isScanningInternal: Bool = false
    var wasRecordingBeforeDisconnect: Bool = false

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

    /// Snapshot of connection phases for all known devices.
    var connectionPhases: [String: ConnectionPhase] {
        byUuid.mapValues { $0.connectionPhase }
    }

    func setConnectionPhase(_ uuid: String, _ phase: ConnectionPhase) {
        byUuid[uuid]?.connectionPhase = phase
        byUuid[uuid]?.dot?.setConnectionPhase(phase)
    }

    // MARK: - Mutations

    func recordDiscovery(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device
        state.lastSeen = Date()
        byUuid[uuid] = state
    }

    func recordConnection(_ device: DotDevice) {
        let uuid = device.uuid
        var state = byUuid[uuid] ?? DotState(device: device, dot: nil, lastSeen: Date())
        state.device = device
//        state.connectionPhase = .initializing

        if let dot = state.dot {
            dot.updateDevice(device)
        } else {
            state.dot = Dot(device: device)
        }
        byUuid[uuid] = state
        initializationInProgress.insert(uuid)
        setConnectionPhase(uuid, .initializing)
    }

    /// Lightweight update for SDK-managed reconnections (e.g. during sync).
    /// Updates device reference and marks connected, but does NOT trigger initialization.
    func recordReconnection(_ device: DotDevice) {
        let uuid = device.uuid
        guard var state = byUuid[uuid] else { return }
        state.device = device
       // state.connectionPhase = .ready
        if let dot = state.dot {
            dot.updateDevice(device)
        }
        byUuid[uuid] = state
        setConnectionPhase(uuid, .ready)
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
        // Note: wasRecordingBeforeDisconnect is intentionally NOT cleared here
        // so it survives the BT power cycle.
    }
}
