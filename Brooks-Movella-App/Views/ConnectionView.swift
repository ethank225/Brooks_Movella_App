import SwiftUI
import Combine      // <--- ADD THIS
import MovellaDotSdk

struct ConnectionView: View {

    private let manager = DotManager.shared

    // UUID -> DotDevice
    @State private var discoveredByUuid: [String: DotDevice] = [:]
    
    // Connected UUIDs only
    @State private var connectedUuids: Set<String> = []

    @State private var isScanning = false
    
    // NEW: UI phases
    enum DevicePhase: Equatable {
        case idle
        case connecting
        case initializing
        case ready
        case failed(String)
    }

    @State private var phaseByUuid: [String: DevicePhase] = [:]
    
    // Timer to force scan retries
    @State private var timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var discoveredList: [DotDevice] {
        discoveredByUuid.values.sorted { left, right in
            manager.displayAddress(for: left) < manager.displayAddress(for: right)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                if !connectedUuids.isEmpty {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        Text("\(connectedUuids.count) connected")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                }

                List {
                    if discoveredList.isEmpty && isScanning {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Scanning for sensors...")
                                .foregroundColor(.secondary)
                        }
                    } else if discoveredList.isEmpty {
                        Text("No sensors found. Pull to scan.")
                            .foregroundColor(.secondary)
                    }

                    ForEach(discoveredList, id: \.uuid) { device in
                        let uuid = device.uuid
                        let phase = phaseByUuid[uuid] ?? .idle

                        // Only allow navigation when initialized
                        if phase == .ready {
                            NavigationLink {
                                DotDetailView(uuid: uuid)
                            } label: {
                                DeviceRow(
                                    title: "DOT \(uuid)",
                                    subtitle: manager.displayAddress(for: device),
                                    phase: phase,
                                    onToggle: { toggleConnection(device) }
                                )
                            }
                        } else {
                            // Not ready: row is not a link
                            DeviceRow(
                                title: "DOT \(uuid)",
                                subtitle: manager.displayAddress(for: device),
                                phase: phase,
                                onToggle: { toggleConnection(device) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Optional feedback
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        startScan()
                    } label: {
                        if isScanning { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isScanning)
                }
            }
            .refreshable { startScan() }
            .onAppear {
                manager.activate()
                syncState()
            }
            .onDisappear {
                manager.stopScan()
                timer.upstream.connect().cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dotManagerUpdated)) { _ in
                syncState()
            }
            // THE FIX: Retry Timer
            .onReceive(timer) { _ in
                if !manager.isScanning {
                    // Force start
                    manager.startScan()
                    // Visual update
                    isScanning = true
                } else {
                    // It is scanning! Ensure UI matches
                    if !isScanning { isScanning = true }
                }
            }
        }
    }

    private func startScan() {
        isScanning = true
        manager.startScan()
    }

    private func toggleConnection(_ device: DotDevice) {
        let uuid = device.uuid

        // If currently busy, ignore repeated taps
        let currentPhase = phaseByUuid[uuid] ?? .idle
        if currentPhase == .connecting || currentPhase == .initializing {
            return
        }

        if connectedUuids.contains(uuid) {
            if let dot = manager.dot(forUuid: uuid) {
                manager.disconnect(dot)
            }
            phaseByUuid[uuid] = .idle
        } else {
            // Immediately show loading while SDK connect proceeds
            phaseByUuid[uuid] = .connecting
            manager.connectByUuid(uuid)
        }
    }

    private func syncState() {
        // Discovered snapshot
        var newDiscovered: [String: DotDevice] = [:]
        for d in manager.discovered where !d.uuid.isEmpty {
            newDiscovered[d.uuid] = d
        }
        discoveredByUuid = newDiscovered

        // Connected snapshot
        let dots = manager.dots
        connectedUuids = Set(dots.filter { $0.isConnected }.map { $0.address })

        // Phase snapshot
        var newPhases = phaseByUuid

        for (uuid, _) in discoveredByUuid {
            if let dot = manager.dot(forUuid: uuid) {
                if dot.isConnected {
                    newPhases[uuid] = dot.isInitialized ? .ready : .initializing
                } else {
                    if newPhases[uuid] != .connecting {
                        newPhases[uuid] = .idle
                    }
                }
            } else {
                if newPhases[uuid] != .connecting {
                    newPhases[uuid] = .idle
                }
            }
        }

        phaseByUuid = newPhases
        
        // Sync scanning state from manager source of truth
        isScanning = manager.isScanning
    }
}

// Subviews
struct DotDetailView: View {
    let uuid: String
    var body: some View {
        Text("DOT Detail for \(uuid)")
            .navigationTitle("DOT")
    }
}

struct DeviceRow: View {
    let title: String
    let subtitle: String
    let phase: ConnectionView.DevicePhase
    let onToggle: () -> Void

    private var isConnected: Bool {
        phase == .initializing || phase == .ready
    }

    private var isBusy: Bool {
        phase == .connecting || phase == .initializing
    }

    private var statusText: String? {
        switch phase {
        case .connecting: return "Connecting…"
        case .initializing: return "Initializing…"
        case .ready: return "Ready"
        case .failed(let msg): return msg
        case .idle: return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.85)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let statusText {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isConnected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }
}
