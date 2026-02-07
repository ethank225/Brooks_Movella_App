import SwiftUI
import Combine
import MovellaDotSdk

struct ConnectionView: View {

    @ObservedObject private var manager = DotManager.shared

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
        manager.discovered.sorted { left, right in
            manager.displayAddress(for: left) < manager.displayAddress(for: right)
        }
    }

    private var connectedCount: Int {
        manager.connectedDots.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                if connectedCount > 0 {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        Text("\(connectedCount) connected")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                }

                List {
                    if discoveredList.isEmpty && manager.isScanning {
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
                        manager.startScan()
                    } label: {
                        if manager.isScanning { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(manager.isScanning)
                }
            }
            .refreshable { manager.startScan() }
            .onAppear {
                manager.activate()
                syncPhases()
            }
            .onDisappear {
                manager.stopScan()
                timer.upstream.connect().cancel()
            }
            .onReceive(manager.objectWillChange) { _ in
                DispatchQueue.main.async { syncPhases() }
            }
            // Retry Timer
            .onReceive(timer) { _ in
                if !manager.isScanning {
                    manager.startScan()
                }
            }
        }
    }

    private func toggleConnection(_ device: DotDevice) {
        let uuid = device.uuid

        // If currently busy, ignore repeated taps
        let currentPhase = phaseByUuid[uuid] ?? .idle
        if currentPhase == .connecting || currentPhase == .initializing {
            return
        }

        if manager.dot(forUuid: uuid)?.isConnected == true {
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

    private func syncPhases() {
        var newPhases = phaseByUuid

        for device in manager.discovered {
            let uuid = device.uuid
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
