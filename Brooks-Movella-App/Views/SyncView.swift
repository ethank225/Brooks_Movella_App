import SwiftUI

struct SyncView: View {
    @State private var isSyncing = false
    @State private var isRecordingInProgress = false
    @State private var isStoppingRecording = false
    @State private var syncResult: String = ""
    @State private var connectedCount = 0
    @State private var isErasing = false
    @State private var dots: [Dot] = []
    @State private var debugInfo: String = ""

    // Add computed property to check if ANY dot is recording
    private var anyDotRecording: Bool {
        let result = dots.contains { $0.isRecording }
        let debugText = "anyDotRecording: \(result), dots: \(dots.count)"
        print("🐛 \(debugText)")
        
        for (index, dot) in dots.enumerated() {
            print("🐛   Dot[\(index)] \(dot.address): isRecording=\(dot.isRecording), isConnected=\(dot.isConnected)")
        }
        
        DispatchQueue.main.async {
            debugInfo = debugText
        }
        
        return result
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                // MARK: - Debug Info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Info")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("Connected: \(connectedCount)")
                        .font(.caption)
                    Text("Dots array: \(dots.count)")
                        .font(.caption)
                    Text("Any recording: \(anyDotRecording ? "YES" : "NO")")
                        .font(.caption)
                    Text("Stop disabled: \(!anyDotRecording || isStoppingRecording ? "YES" : "NO")")
                        .font(.caption)
                        .foregroundColor(!anyDotRecording || isStoppingRecording ? .red : .green)
                }
                .padding()
                .background(Color.yellow.opacity(0.2))
                .cornerRadius(8)
                .padding(.horizontal)
                
                Divider()
                
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
                        print("🐛 Start Sync button clicked")
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
                        print("🐛 Stop Sync button clicked")
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
                    print("🐛 Erase Flash button clicked")
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
                        print("🐛 ========================================")
                        print("🐛 START RECORDING button clicked")
                        print("🐛 isRecordingInProgress: \(isRecordingInProgress)")
                        print("🐛 anyDotRecording: \(anyDotRecording)")
                        print("🐛 connectedCount: \(connectedCount)")
                        print("🐛 ========================================")
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
                    .disabled(isRecordingInProgress || anyDotRecording || connectedCount == 0)
                    
                    Button {
                        print("🐛 ========================================")
                        print("🐛 STOP RECORDING button clicked")
                        print("🐛 anyDotRecording: \(anyDotRecording)")
                        print("🐛 isStoppingRecording: \(isStoppingRecording)")
                        print("🐛 Button should be disabled: \(!anyDotRecording || isStoppingRecording)")
                        print("🐛 Dots:")
                        for dot in dots {
                            print("🐛   - \(dot.address): isRecording=\(dot.isRecording)")
                        }
                        print("🐛 ========================================")
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
                .padding(.horizontal)
                
                Divider()
                    .padding(.vertical)
                
                // MARK: - Result Section
                
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
            print("🐛 SyncView appeared")
            updateStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: DotManager.Notification.updated)) { _ in
            print("🐛 DotManager notification received")
            updateStatus()
        }
    }
    
    // MARK: - Actions
    
    private func updateStatus() {
        print("🐛 updateStatus() called")
        connectedCount = DotManager.shared.connectedDots.count
        dots = DotManager.shared.connectedDots
        
        print("🐛 Updated: connectedCount=\(connectedCount), dots.count=\(dots.count)")
        for (index, dot) in dots.enumerated() {
            print("🐛   Dot[\(index)]: \(dot.address), isRecording=\(dot.isRecording), isConnected=\(dot.isConnected)")
        }
    }
    
    private func startSync() {
        print("🐛 startSync() called")
        isSyncing = true
        syncResult = ""
        
        DotManager.shared.syncConnectedDots { success in
            DispatchQueue.main.async {
                print("🐛 Sync completed: \(success)")
                isSyncing = false
                syncResult = success ? "✅ Sync successful!" : "❌ Sync failed"
                updateStatus()
            }
        }
    }
    
    private func stopSync() {
        print("🐛 stopSync() called")
        DotManager.shared.stopSync()
        isSyncing = false
        syncResult = "⏹️ Sync stopped"
        updateStatus()
    }
    
    private func eraseFlash() {
        print("🐛 eraseFlash() called")
        isErasing = true
        syncResult = "Erasing flash..."
        
        DotManager.shared.eraseAllFlash { success in
            DispatchQueue.main.async {
                print("🐛 Erase completed: \(success)")
                isErasing = false
                syncResult = success ? "🗑️ Flash erased!" : "❌ Erase failed"
                updateStatus()
            }
        }
    }
    
    private func startRecording() {
        print("🐛 startRecording() function called")
        isRecordingInProgress = true
        syncResult = "Starting recording..."
        
        DotManager.shared.startRecordingAll { success in
            DispatchQueue.main.async {
                print("🐛 Recording started: \(success)")
                isRecordingInProgress = false
                syncResult = success ? "🔴 Recording started!" : "❌ Recording failed"
                updateStatus()
            }
        }
    }
    
    private func stopRecording() {
        print("🐛 stopRecording() function called")
        isStoppingRecording = true
        syncResult = "Stopping recording..."
        
        DotManager.shared.stopRecordingAll { success in
            DispatchQueue.main.async {
                print("🐛 Recording stopped: \(success)")
                isStoppingRecording = false
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
