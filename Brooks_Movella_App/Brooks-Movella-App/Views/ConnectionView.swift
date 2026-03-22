import SwiftUI
import Combine
import MovellaDotSdk

struct ConnectionView: View {

    @ObservedObject private var manager = DotManager.shared

    @State private var identifyingUuid: String?

    // Timer to force scan retries
    @State private var timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // Erase state
    @State private var swipedOpenUuid: String?
    @State private var eraseTargetUuid: String?
    @State private var showEraseConfirmation = false
    @State private var showEraseAllConfirmation = false
    @State private var erasingUuids: Set<String> = []

    private var canEraseAll: Bool {
        manager.connectedDots.contains { $0.connectionPhase == .ready }
        && manager.sessionPhase == .idle
        && erasingUuids.isEmpty
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
                                let dot = manager.dot(forUuid: uuid)
                                let isErasing = erasingUuids.contains(uuid)
                                let canErase = phase == .ready
                                    && !(dot?.isRecording ?? false)
                                    && !isErasing
                                    && !manager.sessionPhase.isBusy

                                DeviceRow(
                                    title: "DOT \(uuid)",
                                    subtitle: manager.displayAddress(for: device),
                                    phase: phase,
                                    isIdentifying: identifyingUuid == uuid,
                                    batteryLevel: dot?.device.battery?.value as? Int,
                                    sessionBusy: manager.sessionPhase.isBusy,
                                    isErasing: isErasing,
                                    onToggle: { toggleConnection(device) }
                                )
                                .modifier(SwipeToReveal(
                                    isEnabled: canErase,
                                    activeId: $swipedOpenUuid,
                                    id: uuid,
                                    onAction: {
                                        eraseTargetUuid = uuid
                                        showEraseConfirmation = true
                                        swipedOpenUuid = nil
                                    }
                                ))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if swipedOpenUuid != nil { swipedOpenUuid = nil; return }
                                    if phase == .ready { triggerIdentify(uuid: uuid) }
                                }
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Erase All") {
                        showEraseAllConfirmation = true
                    }
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .disabled(!canEraseAll)

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

    private func eraseSingle() {
        guard let uuid = eraseTargetUuid,
              let dot = manager.dot(forUuid: uuid) else { return }
        erasingUuids.insert(uuid)
        dot.eraseFlash { _ in
            DispatchQueue.main.async { erasingUuids.remove(uuid) }
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

// MARK: - Device Row

struct DeviceRow: View {
    let title: String
    let subtitle: String
    let phase: ConnectionPhase
    var isIdentifying: Bool = false
    var batteryLevel: Int? = nil
    var sessionBusy: Bool = false
    var isErasing: Bool = false
    let onToggle: () -> Void

    private var isBusy: Bool { phase.isBusy }

    @State private var eraseBreathe = false

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

    @ViewBuilder
    private var rowBackgroundView: some View {
        if isErasing {
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
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    ProgressView()
                        .scaleEffect(0.85)
                        .opacity(isBusy ? 1 : 0)
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
        .background(rowBackgroundView)
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.3), value: isIdentifying)
        .onChange(of: isErasing) { erasing in
            if !erasing { eraseBreathe = false }
        }
    }
}

// MARK: - Swipe To Reveal

struct SwipeToReveal: ViewModifier {
    let isEnabled: Bool
    @Binding var activeId: String?
    let id: String
    let onAction: () -> Void

    @State private var offset: CGFloat = 0
    @State private var lockedAxis: Axis?

    private enum Axis { case horizontal, vertical }
    private let revealWidth: CGFloat = 80
    private let snapThreshold: CGFloat = 40

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            // Background erase button
            if offset < 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { offset = 0 }
                    activeId = nil
                    onAction()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.title3)
                        Text("Erase")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                }
            }

            // Foreground content
            content
                .offset(x: offset)
                .gesture(
                    isEnabled
                    ? DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            let dx = abs(value.translation.width)
                            let dy = abs(value.translation.height)

                            if lockedAxis == nil && (dx > 10 || dy > 10) {
                                lockedAxis = dx > dy ? .horizontal : .vertical
                            }

                            guard lockedAxis == .horizontal else { return }

                            let proposed = value.translation.width
                            // Only allow left swipe (negative offset)
                            offset = min(0, max(-revealWidth, proposed))
                        }
                        .onEnded { value in
                            lockedAxis = nil

                            withAnimation(.easeOut(duration: 0.2)) {
                                if -offset > snapThreshold {
                                    offset = -revealWidth
                                    activeId = id
                                } else {
                                    offset = 0
                                    if activeId == id { activeId = nil }
                                }
                            }
                        }
                    : nil
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: activeId) { newActiveId in
            if newActiveId != id && offset != 0 {
                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
            }
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled && offset != 0 {
                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                if activeId == id { activeId = nil }
            }
        }
    }
}
