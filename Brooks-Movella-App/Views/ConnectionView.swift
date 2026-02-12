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

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @State private var phaseByUuid: [String: DevicePhase] = [:]
    @State private var identifyingUuid: String?
    @State private var connectTimers: [String: DispatchWorkItem] = [:]

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

                        DeviceRow(
                            title: "DOT \(uuid)",
                            subtitle: manager.displayAddress(for: device),
                            phase: phase,
                            isIdentifying: identifyingUuid == uuid,
                            batteryLevel: manager.dot(forUuid: uuid)?.device.battery?.value as? Int,
                            onToggle: { toggleConnection(device) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if phase == .ready {
                                triggerIdentify(uuid: uuid)
                            }
                        }
                        .listRowBackground(
                            identifyingUuid == uuid ? Color.orange.opacity(0.08) :
                            phase.isFailed ? Color.orange.opacity(0.06) : nil
                        )
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
            cancelConnectTimer(uuid)
            phaseByUuid[uuid] = .idle
        } else {
            phaseByUuid[uuid] = .connecting
            manager.connectByUuid(uuid)
            startConnectTimer(uuid)
        }
    }

    private func startConnectTimer(_ uuid: String) {
        cancelConnectTimer(uuid)

        let work = DispatchWorkItem { [self] in
            let phase = phaseByUuid[uuid] ?? .idle
            if phase == .connecting {
                phaseByUuid[uuid] = .failed("Connection timed out")
                manager.cancelConnect(uuid: uuid)
            }
            connectTimers.removeValue(forKey: uuid)
        }
        connectTimers[uuid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func cancelConnectTimer(_ uuid: String) {
        connectTimers[uuid]?.cancel()
        connectTimers.removeValue(forKey: uuid)
    }

    private func triggerIdentify(uuid: String) {
        guard let dot = manager.dot(forUuid: uuid) else { return }
        dot.identify()
        identifyingUuid = uuid
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if identifyingUuid == uuid {
                identifyingUuid = nil
            }
        }
    }

    private func syncPhases() {
        var newPhases = phaseByUuid

        for device in manager.discovered {
            let uuid = device.uuid
            if let dot = manager.dot(forUuid: uuid) {
                if dot.isConnected {
                    cancelConnectTimer(uuid)
                    newPhases[uuid] = dot.isInitialized ? .ready : .initializing
                } else {
                    let current = newPhases[uuid] ?? .idle
                    // Preserve .connecting and .failed states
                    if current != .connecting && !current.isFailed {
                        newPhases[uuid] = .idle
                    }
                }
            } else {
                let current = newPhases[uuid] ?? .idle
                if current != .connecting && !current.isFailed {
                    newPhases[uuid] = .idle
                }
            }
        }

        phaseByUuid = newPhases
    }
}

struct DeviceRow: View {
    let title: String
    let subtitle: String
    let phase: ConnectionView.DevicePhase
    var isIdentifying: Bool = false
    var batteryLevel: Int? = nil
    let onToggle: () -> Void

    private var isConnected: Bool {
        phase == .initializing || phase == .ready
    }

    private var isBusy: Bool {
        phase == .connecting || phase == .initializing
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 75...: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        default: return "battery.25"
        }
    }

    private func batteryColor(for level: Int) -> Color {
        if level <= 15 { return .red }
        if level <= 30 { return .orange }
        return .secondary
    }

    private var statusText: String? {
        if isIdentifying { return "Identifying…" }
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
            if isIdentifying {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                    .symbolEffect(.pulse)
            } else if phase.isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
            } else {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.85)
                    }
                }

                HStack(spacing: 4) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let batteryLevel {
                        Image(systemName: batteryIcon(for: batteryLevel))
                            .font(.caption2)
                            .foregroundColor(batteryColor(for: batteryLevel))
                        Text("\(batteryLevel)%")
                            .font(.caption2)
                            .foregroundColor(batteryColor(for: batteryLevel))
                    }
                }

                if let statusText {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(isIdentifying || phase.isFailed ? .orange : .secondary)
                }
            }
            .layoutPriority(1)

            Spacer()

            Toggle("", isOn: Binding(
                get: { isConnected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.3), value: isIdentifying)
    }
}
