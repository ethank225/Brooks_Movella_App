import SwiftUI
import Combine
import MovellaDotSdk

struct ConnectionView: View {

    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var runnerStore = RunnerStore.shared
    @ObservedObject private var nameStore = SensorNameStore.shared

    @State private var identifyingUuid: String?
    @State private var showModeToggleAlert = false
    @State private var modeToggleAlertMessage = ""
    @State private var editingUuid: String?
    @State private var editText: String = ""

    // Timer to force scan retries
    @State private var timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // Erase state
    @State private var eraseTargetUuid: String?
    @State private var showEraseConfirmation = false
    @State private var showEraseAllConfirmation = false
    @State private var erasingUuids: Set<String> = []

    private var canEraseAll: Bool {
        manager.connectedDots.contains { $0.connectionPhase == .ready }
        && !manager.isBusy
        && !manager.isErasing
    }

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

    // MARK: - Extracted Subviews

    private var controlBar: some View {
        HStack {
            // Research Mode toggle
            Button {
                if !runnerStore.isMultiRunnerMode {
                    if runnerStore.runners.contains(where: { $0.id == DotManager.singleRunnerID }) {
                        let newId = UUID().uuidString
                        manager.promoteSingleRunner(to: newId, label: "Runner A")
                    }
                    runnerStore.isMultiRunnerMode = true
                } else {
                    let hasRealRunners = runnerStore.runners.contains { $0.id != DotManager.singleRunnerID }
                    let hasActivePhase = manager.runnerPhases.contains { $0.key != DotManager.singleRunnerID && $0.value != .idle }
                    if hasRealRunners || hasActivePhase {
                        modeToggleAlertMessage = "Remove all runners before switching to single runner mode."
                        showModeToggleAlert = true
                    } else {
                        runnerStore.isMultiRunnerMode = false
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: runnerStore.isMultiRunnerMode
                          ? "person.2.fill" : "person.2")
                        .font(.subheadline)
                    Text("Research")
                        .font(.subheadline)
                }
                .foregroundColor(runnerStore.isMultiRunnerMode ? .blue : .secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .disabled(manager.sessionPhase != .idle)

            Spacer()

            // Erase All
            Button {
                showEraseAllConfirmation = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                    Text("Erase All")
                        .font(.subheadline)
                }
                .foregroundColor(.red)
            }
            .disabled(!canEraseAll)
            .opacity(canEraseAll ? 1 : 0.4)
            .frame(minWidth: 0, maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
        }
        .padding(.horizontal)
    }

    private var sensorSection: some View {
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
                    let dot = manager.dot(forUuid: uuid)
                    let displayTitle = dot?.displayName
                        ?? nameStore.names[uuid]
                        ?? Self.shortMac(from: manager.displayAddress(for: device))
                    DeviceRow(
                        title: displayTitle,
                        phase: phase,
                        isIdentifying: identifyingUuid == uuid,
                        dot: dot,
                        sessionBusy: manager.isBusy,
                        isErasing: erasingUuids.contains(uuid),
                        isEditing: editingUuid == uuid,
                        editText: editingUuid == uuid ? $editText : nil,
                        onToggle: { toggleConnection(device) },
                        onErase: {
                            eraseTargetUuid = uuid
                            showEraseConfirmation = true
                        },
                        onRepairErase: { repairErase(uuid: uuid) },
                        onNameTap: phase.isConnected ? {
                            editingUuid = uuid
                            editText = nameStore.names[uuid] ?? ""
                        } : nil,
                        onNameCommit: {
                            nameStore.setName(editText, for: uuid)
                            editingUuid = nil
                        },
                        onIdentify: phase == .ready ? {
                            triggerIdentify(uuid: uuid)
                        } : nil
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
                }
                .animation(AppAnimation.interactive, value: discoveredList.map(\.uuid))
            }
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    controlBar

                    // MARK: - Session Busy Banner

                    if manager.isBusy {
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

                    sensorSection

                    Spacer()
                }
                .padding(.top)
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
                    .disabled(manager.isScanning || manager.isBusy || manager.isErasing)
                }
            }
            .alert("Cannot Switch Modes", isPresented: $showModeToggleAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(modeToggleAlertMessage)
            }
            .onChange(of: editText) { newValue in
                if let uuid = editingUuid {
                    nameStore.setName(newValue, for: uuid)
                }
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
            .confirmationDialog("Erase flash storage?", isPresented: $showEraseConfirmation, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { eraseSingle() }
                Button("Cancel", role: .cancel) { eraseTargetUuid = nil }
            } message: {
                Text("This will permanently delete all recorded data on this sensor.")
            }
            .confirmationDialog("Erase all flash storage?", isPresented: $showEraseAllConfirmation, titleVisibility: .visible) {
                Button("Erase All", role: .destructive) { eraseAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all recorded data on every connected sensor.")
            }
        }
    }

    private static func shortMac(from mac: String) -> String {
        let octets = mac.split(separator: ":")
        if octets.count >= 3 {
            return octets.suffix(3).joined(separator: ":")
        }
        return mac
    }

    private func toggleConnection(_ device: DotDevice) {
        let uuid = device.uuid
        let phase = manager.connectionPhase(forUuid: uuid)

        // If currently busy, ignore repeated taps
        if phase.isBusy { return }
        if manager.isBusy { return }

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

    private func repairErase(uuid: String) {
        guard let dot = manager.dot(forUuid: uuid) else { return }
        erasingUuids.insert(uuid)
        dot.eraseFlash { _ in
            DispatchQueue.main.async {
                self.erasingUuids.remove(uuid)
            }
        }
    }

    private func eraseSingle() {
        guard let uuid = eraseTargetUuid,
              let dot = manager.dot(forUuid: uuid) else { return }
        erasingUuids.insert(uuid)
        dot.eraseFlash { _ in
            DispatchQueue.main.async {
                self.erasingUuids.remove(uuid)
            }
        }
        eraseTargetUuid = nil
    }

    private func eraseAll() {
        let readyUuids = manager.connectedDots
            .filter { $0.connectionPhase == .ready }
            .map(\.address)
        erasingUuids.formUnion(readyUuids)
        manager.eraseAllFlash { _ in
            DispatchQueue.main.async { erasingUuids.removeAll() }
        }
    }
}

// MARK: - Corrupted Sensor Row

// MARK: - Observed Dot Content

/// Sub-view that observes a Dot's @Published flags and reactively switches
/// between the alternate row layouts (corrupted, erasing, clearing, normal).
private struct ObservedDotContent: View {
    @ObservedObject var dot: Dot
    let title: String
    let phase: ConnectionPhase
    var isIdentifying: Bool
    var isUserErasing: Bool
    var sessionBusy: Bool
    var isEditing: Bool
    var editText: Binding<String>?
    let onToggle: () -> Void
    var onErase: (() -> Void)?
    var onRepairErase: (() -> Void)?
    var onNameTap: (() -> Void)?
    var onNameCommit: (() -> Void)?

    @FocusState private var isFieldFocused: Bool
    @State private var eraseBreathe = false

    private var isBusy: Bool { phase.isBusy }
    private var isErasing: Bool { isUserErasing || dot.isErasingFromPreviousSession }
    private var canErase: Bool {
        phase == .ready
            && !dot.isRecording
            && !isUserErasing
            && !dot.isErasingFromPreviousSession
            && !sessionBusy
    }

    // MARK: - Background

    @ViewBuilder
    private var rowBackgroundView: some View {
        if isErasing && dot.flashCorrupted {
            Color.pink
                .opacity(eraseBreathe ? 0.25 : 0.06)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        eraseBreathe = true
                    }
                }
        } else if dot.flashCorrupted {
            Color.orange.opacity(0.12)
        } else if isErasing {
            Color.pink
                .opacity(eraseBreathe ? 0.25 : 0.06)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        eraseBreathe = true
                    }
                }
        } else if isIdentifying {
            Color.orange.opacity(0.08)
        } else if phase.isFailed {
            Color.orange.opacity(0.06)
        } else if phase.isConnected {
            Color.green.opacity(0.06)
        } else {
            Color.gray.opacity(0.1)
        }
    }

    // MARK: - Normal Row

    private var normalRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isIdentifying {
                    Image(systemName: "light.beacon.max.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                        .symbolEffect(.pulse)
                } else if phase.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                } else {
                    Circle()
                        .fill(phase.isConnected && !isBusy ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                }

                if isEditing, let editText {
                    TextField("e.g. Left Foot", text: editText)
                        .font(.headline)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                        .onSubmit { onNameCommit?() }
                } else {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                        .onTapGesture { onNameTap?() }

                    if onNameTap != nil && !isBusy {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .onTapGesture { onNameTap?() }
                    }
                }

                if isBusy {
                    ProgressView()
                        .scaleEffect(0.75)
                        .fixedSize()
                }

                Spacer()

                if phase.isConnected {
                    Button {
                        onErase?()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(canErase ? .red : .gray.opacity(0.4))
                    }
                    .disabled(!canErase)
                    .buttonStyle(.plain)
                }

                Toggle("", isOn: Binding(
                    get: { phase.isConnected },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .disabled(isBusy || sessionBusy || isErasing)
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

            HStack(spacing: 12) {
                LiveMiniBar(
                    label: "Storage",
                    dot: dot,
                    valueKeyPath: \.storagePercentageUsed,
                    colorFor: { pct in
                        if pct > 90 { return .red }
                        if pct > 70 { return .orange }
                        return .blue
                    },
                    isConnected: phase.isConnected,
                    dataAvailable: dot.flashTotalBytes > 1
                )
                LiveMiniBar(
                    label: "Battery",
                    dot: dot,
                    valueKeyPath: \.batteryPercentage,
                    colorFor: { pct in
                        if pct < 10 { return .red }
                        if pct < 20 { return .orange }
                        return .green
                    },
                    isConnected: phase.isConnected,
                    dataAvailable: dot.batteryLevel > 0
                )
            }
        }
    }

    var body: some View {
        VStack {
            if dot.flashCorrupted {
                CorruptedSensorRow(
                    displayName: title,
                    isRepairing: isErasing,
                    onErase: { onRepairErase?() }
                )
                .transition(.asymmetric(
                    insertion: .push(from: .bottom),
                    removal: .push(from: .top)
                ))
            } else if dot.isErasingFromPreviousSession {
                ErasingSensorRow(displayName: title)
                    .transition(.asymmetric(
                        insertion: .push(from: .bottom),
                        removal: .push(from: .top)
                    ))
            } else if isUserErasing {
                ClearingSensorRow(displayName: title)
                    .transition(.asymmetric(
                        insertion: .push(from: .bottom),
                        removal: .push(from: .top)
                    ))
            } else {
                normalRow
                    .transition(.asymmetric(
                        insertion: .push(from: .top),
                        removal: .push(from: .bottom)
                    ))
            }
        }
        .padding()
        .background(rowBackgroundView)
        .cornerRadius(10)
        .animation(AppAnimation.deviceState, value: dot.flashCorrupted)
        .animation(AppAnimation.deviceState, value: dot.isErasingFromPreviousSession)
        .animation(AppAnimation.deviceState, value: isUserErasing)
        .onChange(of: isErasing) { erasing in
            if !erasing { eraseBreathe = false }
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let title: String
    let phase: ConnectionPhase
    var isIdentifying: Bool = false
    var dot: Dot? = nil
    var sessionBusy: Bool = false
    var isErasing: Bool = false
    var isEditing: Bool = false
    var editText: Binding<String>? = nil
    let onToggle: () -> Void
    var onErase: (() -> Void)? = nil
    var onRepairErase: (() -> Void)? = nil
    var onNameTap: (() -> Void)? = nil
    var onNameCommit: (() -> Void)? = nil
    var onIdentify: (() -> Void)? = nil

    @ViewBuilder
    private var disconnectedBackground: some View {
        if isIdentifying {
            Color.orange.opacity(0.08)
        } else if phase.isFailed {
            Color.orange.opacity(0.06)
        } else if phase.isBusy {
            Color.green.opacity(0.06)
        } else {
            Color.gray.opacity(0.1)
        }
    }

    @ViewBuilder
    private var disconnectedNormalRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isIdentifying {
                    Image(systemName: "light.beacon.max.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                        .symbolEffect(.pulse)
                } else if phase.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                }

                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if phase == .connecting {
                    ProgressView()
                        .scaleEffect(0.75)
                        .fixedSize()
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { phase.isBusy },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .disabled(sessionBusy || phase.isBusy)
            }

            HStack(spacing: 12) {
                MiniBarPlaceholder(label: "Storage")
                MiniBarPlaceholder(label: "Battery")
            }
        }
    }

    var body: some View {
        Group {
            if let dot = dot {
                ObservedDotContent(
                    dot: dot,
                    title: title,
                    phase: phase,
                    isIdentifying: isIdentifying,
                    isUserErasing: isErasing,
                    sessionBusy: sessionBusy,
                    isEditing: isEditing,
                    editText: editText,
                    onToggle: onToggle,
                    onErase: onErase,
                    onRepairErase: onRepairErase,
                    onNameTap: onNameTap,
                    onNameCommit: onNameCommit
                )
            } else {
                disconnectedNormalRow
                    .padding()
                    .background(disconnectedBackground)
                    .cornerRadius(10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onIdentify?() }
        .animation(AppAnimation.phase, value: isIdentifying)
    }
}

