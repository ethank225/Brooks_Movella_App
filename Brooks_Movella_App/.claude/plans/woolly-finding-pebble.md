# Plan: Export Task Persistence Layer

## Context
iOS kills the app in the background after export completes. All in-memory ExportTask state is lost on relaunch, but CSV files in `Documents/Exports/` survive. This adds a persistence layer that writes task records to a JSON file at each terminal state change, restores them on launch, verifies CSVs still exist, and deletes orphaned files from mid-export kills.

## Files to Modify / Create

| File | Change |
|---|---|
| `Models/ExportTask.swift` | Add `Codable` to `ExportStatus` and `UploadStatus` |
| `Managers/ExportManager.swift` | `exportDir()` → internal; call `restorePersistedTasks()` in `init()`; add task subscriptions in `startExport()`; call `clearPersistedTasks()` in `resetExport()` |
| `Managers/ExportManager+Persistence.swift` | **New file** — `CodableExportRecord`, `persistTasks()`, `restorePersistedTasks()`, `clearPersistedTasks()` |

---

## Change 1: ExportTask.swift — Add Codable to enums

```swift
// Before
nonisolated enum ExportStatus: Equatable, Sendable { ... }
nonisolated enum UploadStatus: Equatable, Sendable { ... }

// After
nonisolated enum ExportStatus: Codable, Equatable, Sendable { ... }
nonisolated enum UploadStatus: Codable, Equatable, Sendable { ... }
```

Synthesized `Codable` works because neither enum has associated values.

---

## Change 2: ExportManager.swift

**a) `exportDir()` — remove `private` so the persistence extension can use it:**
```swift
// private func exportDir() → func exportDir()
```

**b) `init()` — restore persisted tasks on launch:**
```swift
private init() {
    restorePersistedTasks()   // ← ADD (before NotificationCenter setup)
    NotificationCenter.default.addObserver(...)
    ...
}
```

**c) `startExport()` — subscribe each new task to persist on terminal state:**
After `let newTasks = cartItems.map { ExportTask(cartItem: $0) }`, add:
```swift
for task in newTasks {
    task.$status
        .filter { $0 == .success || $0 == .failed || $0 == .canceled }
        .sink { [weak self] _ in self?.persistTasks() }
        .store(in: &cancellables)
    task.$uploadStatus
        .filter { $0 == .uploaded || $0 == .failed }
        .sink { [weak self] _ in self?.persistTasks() }
        .store(in: &cancellables)
}
```
These fire on main (all status mutations go through `setOnMain`). For `.success`, `outputURL` is set on the line before `status = .success` in the same `setOnMain` block, so it's available when the subscriber fires.

**d) `resetExport()` — clear persisted records when user starts over:**
```swift
func resetExport() {
    clearPersistedTasks()     // ← ADD
    tasks.removeAll()
    exportPhase = recordings.isEmpty ? .idle : .ready
}
```

---

## Change 3: ExportManager+Persistence.swift (new file)

```swift
import Foundation

extension ExportManager {

    // MARK: - Record Model

    struct CodableExportRecord: Codable {
        let id: String
        let status: ExportStatus
        let hasPacketLoss: Bool
        let error: String?
        let outputPath: String?      // absolute path; nil for non-success tasks
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
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("export_records.json")
    }

    // MARK: - Persist

    /// Serialises all terminal-state tasks to disk atomically.
    /// Called on main thread from Combine subscribers; file write dispatched to fileQueue.
    func persistTasks() {
        let records: [CodableExportRecord] = tasks.compactMap { task in
            guard task.status == .success || task.status == .failed || task.status == .canceled
            else { return nil }
            return CodableExportRecord(
                id:           task.id,
                status:       task.status,
                hasPacketLoss: task.hasPacketLoss,
                error:        task.error,
                outputPath:   task.outputURL?.path,
                uploadStatus: task.uploadStatus,
                uploadError:  task.uploadError,
                sessionId:    task.cartItem.sessionId,
                label:        task.cartItem.label,
                dotAddress:   task.cartItem.recording.dotAddress,
                macAddress:   task.cartItem.recording.macAddress,
                fileIndex:    task.cartItem.recording.fileIndex,
                fileSize:     task.cartItem.recording.fileSize,
                timestamp:    task.cartItem.recording.timestamp
            )
        }
        guard let url = exportRecordsURL,
              let data = try? JSONEncoder().encode(records) else { return }
        fileQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Restore

    /// Called once from init(). Rehydrates tasks from the JSON file if it exists.
    /// Verifies CSVs exist for success tasks; deletes orphaned CSVs.
    func restorePersistedTasks() {
        guard let url = exportRecordsURL,
              let data = try? Data(contentsOf: url),
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
                    return nil   // CSV gone — drop the record
                }
            } else {
                task.status = record.status
            }
            return task
        }

        guard !restored.isEmpty else { return }

        // Delete orphaned CSVs (incomplete transfers from a mid-export kill).
        if let dir = exportDir() {
            let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for csv in all where csv.pathExtension == "csv" {
                if !knownPaths.contains(csv.path) {
                    try? fm.removeItem(at: csv)
                }
            }
        }

        tasks       = restored
        exportPhase = .done
    }

    // MARK: - Clear

    func clearPersistedTasks() {
        guard let url = exportRecordsURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
```

---

## Key Design Decisions

- **Timing of persist for `.success`**: In BLETransfer's `setOnMain` block, `outputURL` is assigned *before* `status = .success`. `@Published` fires the `$status` subscriber after the value is set, so `outputURL` is already populated when `persistTasks()` reads it. No race.
- **`uploadStatus` subscriptions**: Persists again when upload completes (`.uploaded`) or fails, so the restored view shows correct upload state rather than `.pending` for everything.
- **Orphan deletion**: Only paths referenced by a `.success` record are kept. Failed/canceled task paths are not in `knownPaths`, so their (already-deleted) partial CSVs are never falsely kept. If a CSV exists but wasn't in the JSON (mid-export kill), it gets deleted.
- **`exportDir()` visibility**: Changed from `private` to `internal` so the persistence extension can call it.
- **`clearPersistedTasks()` in `resetExport()`**: Ensures stale records don't re-appear after the user resets.

## Verification
1. Start an export, wait for completion, then force-quit the app from the switcher
2. Relaunch → ExportManager.init() calls `restorePersistedTasks()` → tasks array populated → `exportPhase = .done`
3. Open the Export tab → auto-present logic in ExportView opens CartView sheet → results are visible
4. Mid-export kill: force-quit while transferring → relaunch → Exports/ directory is empty (orphans deleted) → no stale results shown
