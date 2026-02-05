import SwiftUI

struct SyncView: View {
    @State private var isSyncing = false
    @State private var isRecording = false
    @State private var syncResult: String = ""
    @State private var connectedCount = 0
    @State private var isErasing = false
    @State private var dots: [Dot] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                // MARK: - Dot Status Section
                
                Text("Sensor Status")
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                if dots.isEmpty {
                    Text("No dots connected")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    ForEach(dots, id: \.address) { dot in
                        DotStatusRow(dot: dot)
                    }
                    .padding(.horizontal)
                }
                
                Divider()
                    .padding(.vertical)
                
                // MARK: - Sync Section
                
                Text("Synchronization")
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
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
                    .disabled(isSyncing || connectedCount < 2)
                    
                    Button {
                        stopSync()
                    } label: {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
                
                // MARK: - Flash Section
                
                Button {
                    eraseFlash()
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
                .disabled(isErasing || connectedCount == 0)
                .padding(.horizontal)
                
                Divider()
                    .padding(.vertical)
                
                // MARK: - Recording Section
                
                Text("Recording")
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                HStack(spacing: 12) {
                    Button {
                        startRecording()
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            Text(isRecording ? "Recording..." : "Record")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isRecording ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(isRecording || connectedCount == 0)
                    
                    Button {
                        stopRecording()
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!isRecording)
                }
                .padding(.horizontal)
                
                Divider()
                    .padding(.vertical)
                
                // MARK: - Debug Section
                
                Button {
                    DotManager.shared.printStatus()
                } label: {
                    HStack {
                        Image(systemName: "terminal")
                        Text("Print Status to Console")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
                
                // Result
                if !syncResult.isEmpty {
                    Text(syncResult)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
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
                syncResult = success ? "✅ Sync successful!" : "❌ Sync failed"
                updateStatus()
            }
        }
    }
    
    private func stopSync() {
        DotManager.shared.stopSync()
        isSyncing = false
        syncResult = "⏹️ Sync stopped"
        updateStatus()
    }
    
    private func eraseFlash() {
        isErasing = true
        syncResult = "Erasing flash..."
        
        DotManager.shared.eraseAllFlash { success in
            DispatchQueue.main.async {
                isErasing = false
                syncResult = success ? "🗑️ Flash erased!" : "❌ Erase failed"
                updateStatus()
            }
        }
    }
    
    private func startRecording() {
        syncResult = "Starting recording..."
        
        DotManager.shared.startRecordingAll { success in
            DispatchQueue.main.async {
                isRecording = success
                syncResult = success ? "🔴 Recording started!" : "❌ Recording failed"
                updateStatus()
            }
        }
    }
    
    private func stopRecording() {
        syncResult = "Stopping recording..."
        
        DotManager.shared.stopRecordingAll { success in
            DispatchQueue.main.async {
                isRecording = false
                syncResult = success ? "⏹️ Recording stopped" : "❌ Stop failed"
                updateStatus()
            }
        }
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
            }
            
            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
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
