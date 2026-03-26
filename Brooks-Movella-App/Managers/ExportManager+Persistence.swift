import Foundation

// MARK: - Export Task Persistence

extension ExportManager {

    // MARK: - Record Model

    struct CodableExportRecord: Codable {
        let id: String
        let status: ExportStatus
        let hasPacketLoss: Bool
        let error: String?
        let outputPath: String?         // absolute path to CSV; nil for non-success tasks
        let uploadStatus: UploadStatus
        let uploadError: String?
        // CartItem fields
        let sessionId: UUID
        let label: String
        // RecordingFile fields
        let dotAddress: String
        let macAddress: String
        let fileIndex: Int
        let fileSize: Int
        let timestamp: UInt32
    }

    // MARK: - Storage URL

    private var exportRecordsURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("export_records.json")
    }

    // MARK: - Persist

    /// Serialises all terminal-state tasks to disk atomically.
    /// Must be called on the main thread; file write is dispatched to fileQueue.
    func persistTasks() {
        let records: [CodableExportRecord] = tasks.compactMap { task in
            guard task.status == .success || task.status == .failed || task.status == .canceled
            else { return nil }
            return CodableExportRecord(
                id:            task.id,
                status:        task.status,
                hasPacketLoss: task.hasPacketLoss,
                error:         task.error,
                outputPath:    task.outputURL?.path,
                uploadStatus:  task.uploadStatus,
                uploadError:   task.uploadError,
                sessionId:     task.cartItem.sessionId,
                label:         task.cartItem.label,
                dotAddress:    task.cartItem.recording.dotAddress,
                macAddress:    task.cartItem.recording.macAddress,
                fileIndex:     task.cartItem.recording.fileIndex,
                fileSize:      task.cartItem.recording.fileSize,
                timestamp:     task.cartItem.recording.timestamp
            )
        }
        print("💾 persisting: \(records.map { "\($0.label): status=\($0.status), upload=\($0.uploadStatus)" })")
        guard let url = exportRecordsURL,
              let data = try? JSONEncoder().encode(records) else { return }
        fileQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Restore

    /// Called once from init(). Rehydrates tasks from the JSON file if it exists.
    /// Verifies CSVs still exist for success tasks; deletes orphaned CSVs from mid-export kills.
    func restorePersistedTasks() {
        guard let url = exportRecordsURL else { return }

        var data = try? Data(contentsOf: url)

        // Fallback: check old Documents path if file doesn't exist at new Application Support path.
        if data == nil,
           let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
               .appendingPathComponent("export_records.json") {
            data = try? Data(contentsOf: docsURL)
        }

        guard let data,
              let records = try? JSONDecoder().decode([CodableExportRecord].self, from: data),
              !records.isEmpty
        else { return }

        let fm = FileManager.default
        var knownPaths = Set<String>()

        let restored: [ExportTask] = records.compactMap { record in
            let recording = RecordingFile(
                dotAddress: record.dotAddress,
                macAddress: record.macAddress,
                fileIndex:  record.fileIndex,
                fileSize:   record.fileSize,
                timestamp:  record.timestamp
            )
            var item = CartItem(recording: recording)
            item.sessionId = record.sessionId
            item.label     = record.label

            let task = ExportTask(cartItem: item)
            task.hasPacketLoss = record.hasPacketLoss
            task.error         = record.error
            task.uploadStatus  = record.uploadStatus
            task.uploadError   = record.uploadError

            if record.status == .success, let path = record.outputPath {
                if fm.fileExists(atPath: path) {
                    task.outputURL = URL(fileURLWithPath: path)
                    task.progress  = 1.0
                    task.subphase  = .complete
                    task.status    = .success
                    knownPaths.insert(path)
                } else {
                    return nil   // CSV gone — drop this record
                }
            } else {
                task.status = record.status
            }
            return task
        }

        guard !restored.isEmpty else { return }

        // Delete orphaned flat CSVs in ExportCache/ (Application Support).
        // Session folders in Documents/Exports/ are permanent user data — never deleted by the app.
        if let cacheDir = exportDir() {
            let cacheItems = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
            for item in cacheItems where item.pathExtension == "csv" && !knownPaths.contains(item.path) {
                try? fm.removeItem(at: item)
            }
        }

        applyRestoredTasks(restored)
    }

    // MARK: - Clear

    /// Removes the persisted JSON file. Called from resetExport().
    func clearPersistedTasks() {
        if let url = exportRecordsURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
