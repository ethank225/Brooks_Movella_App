import SwiftUI

struct SyncView: View {
    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var runnerStore = RunnerStore.shared

    private var phase: SessionPhase { manager.sessionPhase }

    var body: some View {
        NavigationView {
            Group {
                if runnerStore.isMultiRunnerMode {
                    ResearcherModeRecordView()
                } else {
                    ScrollView {
                        VStack(spacing: 16) {

                            // MARK: - Erasing / Flash Issue Banner

                            if manager.isErasing {
                                ErasingBanner()
                                    .padding(.horizontal)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            } else if manager.hasFlashIssue {
                                FlashIssueBanner(isErasingFromPreviousSession: manager.isAnyErasingFromPreviousSession)
                                    .padding(.horizontal)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

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
                                    SessionErrorBanner(message: msg, onDismiss: { manager.dismissError() })
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
                                        if phase.isBusy || manager.isErasing || manager.isAnyErasingFromPreviousSession {
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

                            Spacer()
                        }
                        .padding(.top)
                        .animation(.easeInOut(duration: 0.3), value: manager.hasFlashIssue)
                    }
                }
            }
            .navigationTitle("Record")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    LiveBadge(count: manager.runnerPhases.values.filter { $0 == .recording }.count)
                }
            }
            .onAppear {
                // Recover session state after app relaunch if dots are still recording
                if manager.sessionPhase == .idle && manager.connectedDots.contains(where: { $0.isRecording }) {
                    manager.resumeRecordingSession()
                }
            }
        }
    }

    // MARK: - Button State

    private var noSensors: Bool { manager.connectedDots.isEmpty }

    private var sensorsInitializing: Bool {
        !manager.connectedDots.isEmpty
            && manager.connectedDots.contains { $0.connectionPhase != .ready }
    }

    private var flashIssueTitle: String {
        if manager.isErasing || manager.isAnyErasingFromPreviousSession {
            return "Finishing Erase..."
        }
        return "Storage Needs Repair"
    }

    private var primaryButtonTitle: String {
        switch phase {
        case .idle:                return noSensors ? "No Sensors Connected"
                                          : sensorsInitializing ? "Sensors Initializing..."
                                          : manager.hasPendingConnections ? "Connecting..."
                                          : (manager.isErasing || manager.hasFlashIssue) ? flashIssueTitle
                                          : "Start Recording"
        case .syncing:             return "Syncing Sensors..."
        case .startingRecording:   return "Starting..."
        case .recording:           return noSensors ? "Sensors Disconnected" : "Stop Recording"
        case .stoppingRecording:   return "Stopping..."
        case .error:               return noSensors ? "No Sensors Connected"
                                          : sensorsInitializing ? "Sensors Initializing..."
                                          : manager.hasPendingConnections ? "Connecting..."
                                          : (manager.isErasing || manager.hasFlashIssue) ? flashIssueTitle
                                          : "Start Recording"
        }
    }

    private var primaryButtonIcon: String {
        switch phase {
        case .recording:           return "stop.fill"
        default:                   return "circle.fill"
        }
    }

    private var flashIssueColor: Color {
        (manager.isErasing || manager.isAnyErasingFromPreviousSession) ? .pink : .orange
    }

    private var primaryButtonColor: Color {
        switch phase {
        case .idle:                return (noSensors || sensorsInitializing || manager.hasPendingConnections) ? .gray : (manager.isErasing || manager.hasFlashIssue) ? flashIssueColor : .green
        case .recording:           return noSensors ? .gray : .red
        case .error:               return (noSensors || sensorsInitializing || manager.hasPendingConnections) ? .gray : (manager.isErasing || manager.hasFlashIssue) ? flashIssueColor : .green
        default:                   return .gray
        }
    }

    private var primaryButtonDisabled: Bool {
        switch phase {
        case .idle:    return noSensors || sensorsInitializing || manager.hasPendingConnections || manager.isErasing || manager.hasFlashIssue
        case .recording: return false
        case .error:   return noSensors || sensorsInitializing || manager.hasPendingConnections || manager.isErasing || manager.hasFlashIssue
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
        VStack(alignment: .leading, spacing: 10) {
            // Top line: status dot + name + spacer + badges
            HStack(spacing: 8) {
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

                Text(dot.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text("Connected")
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(dot.isConnected ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundColor(dot.isConnected ? .green : .gray)
                    .cornerRadius(4)

                Text("Recording")
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(sessionPhase == .recording ? Color.red.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundColor(sessionPhase == .recording ? .red : .gray)
                    .cornerRadius(4)
            }

            // Bottom line: Storage + Battery mini bars (full width)
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
                    isConnected: dot.isConnected
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
                    isConnected: dot.isConnected
                )
            }
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
