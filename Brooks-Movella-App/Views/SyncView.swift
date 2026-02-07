import SwiftUI

struct SyncView: View {
    @State private var isSyncing = false
    @State private var isRecordingInProgress = false
    @State private var isStoppingRecording = false
    @State private var syncResult: String = ""
    @State private var connectedCount = 0
    @State private var isErasing = false
    @State private var dots: [Dot] = []
    @State private var showEraseConfirmation = false

    private var anyDotRecording: Bool {
        dots.contains { $0.isRecording }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // MARK: - Sensor Status

                SectionCard(title: "Sensor Status", icon: "sensor.tag.radiowaves.forward") {
                    if dots.isEmpty {
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
                        ForEach(dots, id: \.address) { dot in
                            DotStatusRow(dot: dot)
                        }
                    }
                }

                // MARK: - Synchronization

                SectionCard(title: "Synchronization", icon: "arrow.triangle.2.circlepath") {
                    HStack(spacing: 12) {
                        Button {
                            startSync()
                        } label: {
                            HStack {
                                if isSyncing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                }
                                Text(isSyncing ? "Syncing..." : "Start Sync")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isSyncing ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isSyncing || connectedCount < 2 || anyDotRecording)

                        Button {
                            stopSync()
                        } label: {
                            Text("Stop")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(!isSyncing ? Color.gray : Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(!isSyncing)
                    }
                }

                // MARK: - Recording

                SectionCard(title: "Recording", icon: "record.circle") {
                    HStack(spacing: 12) {
                        Button {
                            startRecording()
                        } label: {
                            HStack {
                                if isRecordingInProgress {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 12, height: 12)
                                }
                                Text(isRecordingInProgress ? "Starting..." : anyDotRecording ? "Recording..." : "Record")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(anyDotRecording ? Color.red : (isRecordingInProgress ? Color.gray : Color.green))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isRecordingInProgress || anyDotRecording || connectedCount == 0 || isSyncing)

                        Button {
                            stopRecording()
                        } label: {
                            HStack {
                                if isStoppingRecording {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: "stop.fill")
                                }
                                Text(isStoppingRecording ? "Stopping..." : "Stop")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isStoppingRecording ? Color.gray : Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(!anyDotRecording || isStoppingRecording)
                    }
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
                    .disabled(isErasing || connectedCount == 0 || anyDotRecording || isSyncing)
                }

                // MARK: - Status Banner

                if !syncResult.isEmpty {
                    Text(syncResult)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top)
        }
        .navigationTitle("Sync & Record")
        .onAppear {
            updateStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: DotManager.Notification.updated)) { _ in
            updateStatus()
        }
        .confirmationDialog("Erase all flash storage?", isPresented: $showEraseConfirmation, titleVisibility: .visible) {
            Button("Erase All", role: .destructive) { eraseFlash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all recorded data on every connected sensor.")
        }
    }

    // MARK: - Actions

    private func updateStatus() {
        connectedCount = DotManager.shared.connectedDots.count
        dots = DotManager.shared.connectedDots
    }

    private func startSync() {
        isSyncing = true
        syncResult = ""

        DotManager.shared.syncConnectedDots { success in
            DispatchQueue.main.async {
                isSyncing = false
                syncResult = success ? "Sync successful" : "Sync failed"
                updateStatus()
            }
        }
    }

    private func stopSync() {
        DotManager.shared.stopSync()
        isSyncing = false
        syncResult = "Sync stopped"
        updateStatus()
    }

    private func eraseFlash() {
        isErasing = true
        syncResult = "Erasing flash..."

        DotManager.shared.eraseAllFlash { success in
            DispatchQueue.main.async {
                isErasing = false
                syncResult = success ? "Flash erased" : "Erase failed"
                updateStatus()
            }
        }
    }

    private func startRecording() {
        isRecordingInProgress = true
        syncResult = "Starting recording..."

        DotManager.shared.startRecordingAll { success in
            DispatchQueue.main.async {
                isRecordingInProgress = false
                syncResult = success ? "Recording started" : "Recording failed"
                updateStatus()
            }
        }
    }

    private func stopRecording() {
        isStoppingRecording = true
        syncResult = "Stopping recording..."

        DotManager.shared.stopRecordingAll { success in
            DispatchQueue.main.async {
                isStoppingRecording = false
                syncResult = success ? "Recording stopped" : "Stop failed"
                updateStatus()
            }
        }
    }
}

// MARK: - Section Card

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)

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

    var body: some View {
        HStack {
            Circle()
                .fill(dot.isConnected ? Color.green : Color.gray)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(dot.address)
                    .font(.headline)

                HStack(spacing: 8) {
                    StatusTag(text: "Connected", isActive: dot.isConnected, color: .green)
                    StatusTag(text: "Synced", isActive: dot.sessionSynced, color: .blue)
                    StatusTag(text: "Recording", isActive: dot.isRecording, color: .red)
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
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
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
