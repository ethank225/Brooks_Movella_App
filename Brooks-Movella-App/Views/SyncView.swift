import SwiftUI

struct SyncView: View {
    @ObservedObject private var manager = DotManager.shared

    @State private var isErasing = false
    @State private var showEraseConfirmation = false
    @State private var eraseResult: String = ""
    @State private var researcherMode = false
    @StateObject private var researcherState = ResearcherSessionState()

    private var phase: SessionPhase { manager.sessionPhase }

    var body: some View {
        NavigationView {
            Group {
                if researcherMode {
                    ResearcherModeRecordView(state: researcherState)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {

                            // MARK: - Sensor Status

                            SectionCard(title: "Sensor Status", icon: "sensor.tag.radiowaves.forward") {
                                if manager.connectedDots.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "sensor.tag.radiowaves.forward")
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary)
                                        Text("No sensors connected")
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                        Text("Go to the Connect tab to pair your DOTs")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                                } else {
                                    ForEach(manager.connectedDots, id: \.address) { dot in
                                        DotStatusRow(dot: dot, sessionPhase: phase)
                                    }
                                }
                            }

                            // MARK: - Session (Record)

                            SectionCard(title: "Session", icon: "record.circle") {

                                // Error banner
                                if case .error(let msg) = phase {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                        Text(msg)
                                            .font(.subheadline)
                                            .foregroundColor(.orange)
                                        Spacer()
                                        Button { manager.dismissError() } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding()
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                                }

                                // Status text
                                if let statusText = phaseStatusText {
                                    HStack(spacing: 8) {
                                        if phase.isBusy {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: phaseColor))
                                                .scaleEffect(0.8)
                                        }
                                        Text(statusText)
                                            .font(.subheadline)
                                            .foregroundColor(phaseColor)
                                    }
                                    .padding(.bottom, 4)
                                }

                                // Primary button
                                Button {
                                    handlePrimaryAction()
                                } label: {
                                    HStack {
                                        if phase.isBusy {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        } else {
                                            Image(systemName: primaryButtonIcon)
                                        }
                                        Text(primaryButtonTitle)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(primaryButtonColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                                .disabled(primaryButtonDisabled)
                            }

                            // MARK: - Storage Management

                            SectionCard(title: "Storage", icon: "internaldrive") {
                                Button {
                                    showEraseConfirmation = true
                                } label: {
                                    HStack {
                                        if isErasing {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        }
                                        Image(systemName: "trash")
                                        Text(isErasing ? "Erasing..." : "Erase All Flash")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(isErasing ? Color.gray : Color.purple)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                                .disabled(isErasing || manager.connectedDots.isEmpty || phase != .idle)

                                if !eraseResult.isEmpty {
                                    Text(eraseResult)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 4)
                                }
                            }

                            Spacer()
                        }
                        .padding(.top)
                    }
                }
            }
            .navigationTitle("Record")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        LiveBadge(count: researcherState.liveCount)
                        Toggle("Researcher", isOn: $researcherMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text("Researcher")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear {
                // Recover session state after app relaunch if dots are still recording
                if manager.sessionPhase == .idle && manager.connectedDots.contains(where: { $0.isRecording }) {
                    manager.resumeRecordingSession()
                }
            }
            .confirmationDialog("Erase all flash storage?", isPresented: $showEraseConfirmation, titleVisibility: .visible) {
                Button("Erase All", role: .destructive) { eraseFlash() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all recorded data on every connected sensor.")
            }
        }
    }

    // MARK: - Button State

    private var noSensors: Bool { manager.connectedDots.isEmpty }

    private var sensorsInitializing: Bool {
        !manager.connectedDots.isEmpty
            && manager.connectedDots.contains { $0.connectionPhase != .ready }
    }

    private var primaryButtonTitle: String {
        switch phase {
        case .idle:                return noSensors ? "No Sensors Connected"
                                          : sensorsInitializing ? "Sensors Initializing..."
                                          : manager.hasPendingConnections ? "Connecting..."
                                          : "Start Recording"
        case .syncing:             return "Syncing Sensors..."
        case .startingRecording:   return "Starting..."
        case .recording:           return noSensors ? "Sensors Disconnected" : "Stop Recording"
        case .stoppingRecording:   return "Stopping..."
        case .error:               return noSensors ? "No Sensors Connected"
                                          : sensorsInitializing ? "Sensors Initializing..."
                                          : manager.hasPendingConnections ? "Connecting..."
                                          : "Start Recording"
        }
    }

    private var primaryButtonIcon: String {
        switch phase {
        case .recording:           return "stop.fill"
        default:                   return "circle.fill"
        }
    }

    private var primaryButtonColor: Color {
        switch phase {
        case .idle:                return (noSensors || sensorsInitializing || manager.hasPendingConnections) ? .gray : .green
        case .recording:           return noSensors ? .gray : .red
        case .error:               return (noSensors || sensorsInitializing || manager.hasPendingConnections) ? .gray : .green
        default:                   return .gray
        }
    }

    private var primaryButtonDisabled: Bool {
        switch phase {
        case .idle:    return noSensors || sensorsInitializing || manager.hasPendingConnections
        case .recording: return false
        case .error:   return noSensors || sensorsInitializing || manager.hasPendingConnections
        default:       return true
        }
    }

    private var phaseStatusText: String? {
        switch phase {
        case .idle:                        return nil
        case .syncing:                     return "Synchronizing sensor clocks..."
        case .startingRecording:           return "Starting recording on all sensors..."
        case .recording:                   return noSensors ? "All sensors disconnected" : "Recording in progress"
        case .stoppingRecording:           return "Stopping recording..."
        case .error:                       return nil // shown in error banner instead
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .recording:   return noSensors ? .orange : .red
        case .error:       return .orange
        default:           return .blue
        }
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        switch phase {
        case .idle, .error:
            manager.beginSession()
        case .recording:
            manager.endSession()
        default:
            break
        }
    }

    private func eraseFlash() {
        isErasing = true
        eraseResult = "Erasing flash..."

        manager.eraseAllFlash { success in
            DispatchQueue.main.async {
                isErasing = false
                eraseResult = success ? "Flash erased" : "Erase failed"
            }
        }
    }
}

// MARK: - Section Card

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    var onHeaderTap: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let onHeaderTap {
                Button(action: onHeaderTap) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Label(title, systemImage: icon)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.headline)
            }

            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - Dot Status Row

struct DotStatusRow: View {
    @ObservedObject var dot: Dot
    var sessionPhase: SessionPhase = .idle

    @State private var breathe = false
    @State private var eraseBreathe = false

    var body: some View {
        HStack {
            if sessionPhase.isSyncActive {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
                    .font(.caption)
                    .symbolEffect(.rotate)
            } else {
                Circle()
                    .fill(dot.isConnected ? (sessionPhase == .recording ? Color.red : Color.green) : Color.gray)
                    .frame(width: 12, height: 12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("DOT " + dot.address)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    StatusTag(text: "Connected", isActive: dot.isConnected, color: .green)
                    StatusTag(text: "Recording", isActive: sessionPhase == .recording, color: .red)
                }

                // Storage bar
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Storage")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Spacer()
                        Text(String(format: "%.1f%%", dot.storagePercentageUsed))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.3))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(storageColor(for: dot.storagePercentageUsed))
                                .frame(width: geo.size.width * min(dot.storagePercentageUsed / 100, 1.0))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding()
        .background(rowBackgroundView)
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.3), value: sessionPhase)
        .onChange(of: sessionPhase) { newPhase in
            if newPhase != .recording {
                breathe = false
            }
        }
        .onChange(of: dot.isErasing) { erasing in
            if !erasing {
                eraseBreathe = false
            }
        }
    }

    @ViewBuilder
    private var rowBackgroundView: some View {
        if sessionPhase == .recording {
            Color.red
                .opacity(breathe ? 0.25 : 0.06)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        breathe = true
                    }
                }
        } else if dot.isErasing {
            Color.pink
                .opacity(eraseBreathe ? 0.25 : 0.06)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        eraseBreathe = true
                    }
                }
        } else if sessionPhase.isSyncActive {
            Color.blue.opacity(0.08)
        } else {
            Color.gray.opacity(0.1)
        }
    }

    private func storageColor(for percentage: Double) -> Color {
        if percentage > 90 { return .red }
        if percentage > 70 { return .orange }
        return .blue
    }
}

// MARK: - Status Tag

struct StatusTag: View {
    let text: String
    let isActive: Bool
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? color.opacity(0.2) : Color.gray.opacity(0.2))
            .foregroundColor(isActive ? color : Color.gray)
            .cornerRadius(4)
    }
}

#Preview {
    NavigationView {
        SyncView()
    }
}
