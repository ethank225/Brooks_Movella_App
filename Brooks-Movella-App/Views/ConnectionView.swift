import SwiftUI
import Combine
import MovellaDotSdk

struct ConnectionView: View {

    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var runnerStore = RunnerStore.shared
    @ObservedObject private var nameStore = SensorNameStore.shared

    @State private var identifyingUuid: String?
    @State private var showModeToggleAlert = false
    @State private var editingUuid: String?
    @State private var editText: String = ""

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

    private var sessionBusyLabel: String {
        switch manager.sessionPhase {
        case .syncing:           return "Syncing — connections locked"
        case .startingRecording: return "Starting recording — connections locked"
        case .stoppingRecording: return "Stopping recording — connections locked"
        default:                 return "Session busy — connections locked"
        }
    }

    private var sessionBusyColor: Color {
        switch manager.sessionPhase {
        case .syncing:                               return .blue
        case .startingRecording, .stoppingRecording: return .red
        default:                                     return .orange
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // MARK: - Session Busy Banner

                    if manager.sessionPhase.isBusy {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: sessionBusyColor))
                                .scaleEffect(0.8)
                            Text(sessionBusyLabel)
                                .font(.subheadline)
                                .foregroundColor(sessionBusyColor)
                            Spacer()
                        }
                        .padding()
                        .background(sessionBusyColor.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    // MARK: - Sensors

                    SectionCard(
                        title: connectedCount > 0
                            ? "Sensors — \(connectedCount) connected"
                            : "Sensors",
                        icon: "sensor.tag.radiowaves.forward"
                    ) {
                        if discoveredList.isEmpty && manager.isScanning {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Scanning for sensors...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else if discoveredList.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "sensor.tag.radiowaves.forward")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("No sensors found")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Text("Pull down or tap refresh to scan")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else {
                            ForEach(discoveredList, id: \.uuid) { device in
                                let uuid = device.uuid
                                let phase = manager.connectionPhase(forUuid: uuid)
                                let hasCustomName = nameStore.names[uuid] != nil
                                let displayTitle = hasCustomName ? nameStore.name(for: uuid) : "DOT \(uuid)"

                                DeviceRow(
                                    title: displayTitle,
                                    subtitle: manager.displayAddress(for: device),
                                    phase: phase,
                                    isIdentifying: identifyingUuid == uuid,
                                    batteryLevel: manager.dot(forUuid: uuid)?.device.battery?.value as? Int,
                                    sessionBusy: manager.sessionPhase.isBusy,
                                    isEditing: editingUuid == uuid,
                                    editText: editingUuid == uuid ? $editText : nil,
                                    onToggle: { toggleConnection(device) },
                                    onNameTap: phase.isConnected ? {
                                        editingUuid = uuid
                                        editText = hasCustomName ? nameStore.name(for: uuid) : ""
                                    } : nil,
                                    onNameCommit: {
                                        nameStore.setName(editText, for: uuid)
                                        editingUuid = nil
                                    },
                                    onIdentify: phase == .ready ? {
                                        triggerIdentify(uuid: uuid)
                                    } : nil
                                )
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if manager.connectedDots.isEmpty {
                            runnerStore.isMultiRunnerMode.toggle()
                        } else {
                            showModeToggleAlert = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: runnerStore.isMultiRunnerMode
                                  ? "person.2.fill" : "person.2")
                                .font(.subheadline)
                            Text("Research")
                                .font(.caption)
                        }
                        .foregroundColor(runnerStore.isMultiRunnerMode ? .blue : .secondary)
                    }
                }
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
            .alert("Cannot Switch Modes", isPresented: $showModeToggleAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Disconnect all sensors before switching between single and multi-runner modes.")
            }
            .refreshable { manager.startScan() }
            .onAppear {
                manager.activate()
            }
            .onDisappear {
                manager.stopScan()
                timer.upstream.connect().cancel()
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
        let phase = manager.connectionPhase(forUuid: uuid)

        // If currently busy, ignore repeated taps
        if phase.isBusy { return }
        if manager.sessionPhase.isBusy { return }

        if manager.dot(forUuid: uuid)?.isConnected == true {
            if let dot = manager.dot(forUuid: uuid) {
                manager.disconnect(dot)
            }
        } else {
            manager.connectByUuid(uuid)
        }
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
}

// MARK: - Device Row

struct DeviceRow: View {
    let title: String
    let subtitle: String
    let phase: ConnectionPhase
    var isIdentifying: Bool = false
    var batteryLevel: Int? = nil
    var sessionBusy: Bool = false
    var isEditing: Bool = false
    var editText: Binding<String>? = nil
    let onToggle: () -> Void
    var onNameTap: (() -> Void)? = nil
    var onNameCommit: (() -> Void)? = nil
    var onIdentify: (() -> Void)? = nil

    @FocusState private var isFieldFocused: Bool

    private var isBusy: Bool { phase.isBusy }

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
        case .ready: return nil
        case .failed(let msg): return msg
        case .idle: return nil
        }
    }

    private var rowBackground: Color {
        if isIdentifying {
            return Color.orange.opacity(0.08)
        }
        if phase.isFailed {
            return Color.orange.opacity(0.06)
        }
        if phase.isConnected {
            return Color.green.opacity(0.06)
        }
        return Color.gray.opacity(0.1)
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
                    .fill(phase.isConnected ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 12, height: 12)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if isEditing, let editText {
                        TextField("e.g. Left Foot", text: editText)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                            .focused($isFieldFocused)
                            .onSubmit { onNameCommit?() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(onNameTap != nil ? .primary.opacity(0.8) : .primary)
                            .underline(onNameTap != nil, color: .secondary.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onNameTap?() }
                    }
                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.85)
                            .fixedSize()
                    }
                }
                .onChange(of: isEditing) { editing in
                    if editing {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isFieldFocused = true
                        }
                    }
                }
                .onChange(of: isFieldFocused) { focused in
                    if !focused && isEditing {
                        onNameCommit?()
                    }
                }

                HStack(spacing: 8) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let batteryLevel {
                        HStack(spacing: 2) {
                            Image(systemName: batteryIcon(for: batteryLevel))
                                .font(.caption2)
                                .foregroundColor(batteryColor(for: batteryLevel))
                            Text("\(batteryLevel)%")
                                .font(.caption2)
                                .foregroundColor(batteryColor(for: batteryLevel))
                        }
                    }
                }

                HStack(spacing: 8) {
                    StatusTag(
                        text: "Connected",
                        isActive: phase.isConnected,
                        color: .green
                    )

                    Text(statusText ?? "Identifying…")
                        .font(.caption)
                        .foregroundColor(isIdentifying || phase.isFailed ? .orange : .secondary)
                        .opacity(statusText != nil ? 1 : 0)
                }
                .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            if !(sessionBusy && phase.isConnected) {
                Toggle("", isOn: Binding(
                    get: { phase.isConnected },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .disabled(isBusy || sessionBusy)
            }
        }
        .padding()
        .background(rowBackground)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onIdentify?() }
        .animation(.easeInOut(duration: 0.3), value: isIdentifying)
    }
}
