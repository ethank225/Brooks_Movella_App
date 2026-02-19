import Foundation
import UIKit
import MovellaDotSdk
import Combine

// MARK: - Export Phase

enum ExportPhase: Equatable {
    case idle
    case fetching
    case ready
    case exporting
    case done
}

// MARK: - ExportManager

/// Singleton managing the recording-export lifecycle:
/// file discovery, cart selection, export pipeline, and CSV file writing.
///
/// **Pipeline:** BLE data → CSV rows written directly to disk.
///
/// **Threading:**
/// - SDK calls → `DotManager.shared.sdkQueue`
/// - File I/O  → `fileQueue`
/// - Published state → main thread
final class ExportManager: ObservableObject {

    static let shared = ExportManager()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    // MARK: - Queues

    private var sdkQueue: DispatchQueue { DotManager.shared.sdkQueue }
    private let fileQueue = DispatchQueue(label: "ExportManager.fileQueue")
    private let exportSequenceQueue = DispatchQueue(label: "ExportManager.exportSequenceQueue")

    // MARK: - Published State

    /// Recording files discovered per dot address.
    @Published private(set) var recordings: [String: [RecordingFile]] = [:]

    /// IDs of files currently selected for export.
    @Published var selectedIDs: Set<String> = []

    /// Items added to the export cart.
    @Published var cartItems: [CartItem] = []

    /// Active export tasks (created when export starts).
    @Published private(set) var tasks: [ExportTask] = []

    /// Current phase of the export flow.
    @Published private(set) var exportPhase: ExportPhase = .idle

    /// Set to true while file info is being fetched.
    @Published private(set) var isFetching: Bool = false

    // MARK: - Export State (internal)

    private var currentExportCanceled = false
    private var activeWatchdog: ExportWatchdog?
    private var exportFileGeneration: Int = 0
    private var cleanupBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// True while BLE transfer is active.
    private var isTransferring = false

    private let dataTimeoutInterval: TimeInterval = 10.0

    // MARK: - App State Handling

    @objc private func appWillResignActive() {
        // bluetooth-central background mode keeps BLE callbacks alive — no action needed
    }

    @objc private func appDidEnterBackground() {
        // bluetooth-central background mode keeps BLE callbacks alive — no action needed
    }

    // MARK: - File Discovery

    /// Fetch recording file metadata from each connected dot.
    func fetchRecordings(for dots: [Dot]) {
        guard !isFetching else { return }
        setOnMain {
            self.isFetching = true
            self.exportPhase = .fetching
            self.recordings = [:]
        }

        let group = DispatchGroup()

        for dot in dots {
            guard dot.isInitialized else { continue }

            group.enter()
            dot.getExportFileInfo { [weak self] success in
                guard let self else { group.leave(); return }

                let files = dot.recordingFiles
                var result: [RecordingFile] = []
                for (i, file) in files.enumerated() {
                    result.append(RecordingFile(
                        dotAddress: dot.address,
                        fileIndex: i,
                        fileSize: Int(file.fileSize),
                        timestamp: file.timeStamap,
                    ))
                }

                DispatchQueue.main.async {
                    self.recordings[dot.address] = result
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isFetching = false
            self.exportPhase = .ready
        }
    }

    // MARK: - Selection

    func toggleSelection(_ file: RecordingFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    func selectAll(for dotAddress: String) {
        guard let files = recordings[dotAddress] else { return }
        for file in files {
            selectedIDs.insert(file.id)
        }
    }

    func deselectAll(for dotAddress: String) {
        guard let files = recordings[dotAddress] else { return }
        for file in files {
            selectedIDs.remove(file.id)
        }
    }

    // MARK: - Cart

    /// Move selected files into the cart. Clears selection.
    func buildCart() {
        let allFiles = recordings.values.flatMap { $0 }
        let selected = allFiles.filter { selectedIDs.contains($0.id) }

        // Don't add duplicates already in cart
        let existingIDs = Set(cartItems.map { $0.id })
        let newItems = selected
            .filter { !existingIDs.contains($0.id) }
            .map { CartItem(recording: $0) }

        cartItems.append(contentsOf: newItems)
        selectedIDs.removeAll()
    }

    func removeFromCart(_ item: CartItem) {
        cartItems.removeAll { $0.id == item.id }
    }

    func clearCart() {
        cartItems.removeAll()
    }

    func updateLabel(for itemID: String, label: String) {
        if let index = cartItems.firstIndex(where: { $0.id == itemID }) {
            cartItems[index].label = label
        }
    }

    // MARK: - Export Pipeline

    /// Start exporting all cart items. Creates tasks and processes one device at a time.
    /// Must be called while app is in foreground.
    func startExport() {
        guard !cartItems.isEmpty else { return }
        guard exportPhase != .exporting else { return }

        beginExportBackgroundTask()
        currentExportCanceled = false

        // Create tasks
        let newTasks = cartItems.map { ExportTask(cartItem: $0) }
        setOnMain {
            self.tasks = newTasks
            self.exportPhase = .exporting
        }

        // Group tasks by dot address
        let grouped = Dictionary(grouping: newTasks, by: { $0.cartItem.recording.dotAddress })

        // Process devices sequentially on a dedicated queue so fileQueue stays
        // free for CSV writes dispatched from SDK callbacks.
        exportSequenceQueue.async { [weak self] in
            guard let self else { return }

            let semaphore = DispatchSemaphore(value: 0)

            let dotAddresses = Array(grouped.keys).sorted()
            for address in dotAddresses {
                guard !self.currentExportCanceled else { break }

                guard let tasksForDot = grouped[address] else { continue }
                guard let dot = DotManager.shared.dot(forUuid: address) else {
                    for task in tasksForDot {
                        self.setTaskStatus(task, .failed, error: "Sensor disconnected")
                    }
                    continue
                }

                guard dot.isConnected else {
                    for task in tasksForDot {
                        self.setTaskStatus(task, .failed, error: "Sensor disconnected")
                    }
                    continue
                }

                self.exportFilesForDot(dot: dot, tasks: tasksForDot) {
                    semaphore.signal()
                }
                semaphore.wait()
            }

            DispatchQueue.main.async {
                self.exportPhase = .done
                self.endExportBackgroundTask()
            }
        }
    }

    /// Cancel the active export.
    func cancelExport() {
        currentExportCanceled = true
        isTransferring = false
        activeWatchdog?.stop()
        activeWatchdog = nil

        // Stop export on all devices that have running tasks in transfer phase
        let runningAddresses = Set(
            tasks.filter { $0.status == .running && $0.subphase == .transferring }
                .map { $0.cartItem.recording.dotAddress }
        )
        for address in runningAddresses {
            if let dot = DotManager.shared.dot(forUuid: address) {
                sdkQueue.async {
                    dot.device.stopExportFileData()
                }
            }
        }

        for task in tasks where task.status == .running || task.status == .queued {
            // Delete incomplete .csv files for tasks that were transferring
            if task.subphase == .transferring {
                let csvPath = csvURL(for: task)
                fileQueue.async {
                    try? FileManager.default.removeItem(at: csvPath)
                }
            }
            setTaskStatus(task, .canceled)
        }

        setOnMain {
            self.exportPhase = .done
            self.endExportBackgroundTask()
        }
    }

    /// Re-queue failed/canceled tasks for retry. Must be called in foreground.
    /// Uses resume logic: .csv exists → done immediately; else full pipeline.
    func retryFailed() {
        let retryable = tasks.filter { $0.status == .failed || $0.status == .canceled }
        guard !retryable.isEmpty else { return }

        beginExportBackgroundTask()
        currentExportCanceled = false
        setOnMain { self.exportPhase = .exporting }

        var fullPipeline: [ExportTask] = []

        for task in retryable {
            let csv = csvURL(for: task)

            if FileManager.default.fileExists(atPath: csv.path) {
                // CSV already exists — mark success immediately
                setOnMain {
                    task.status = .success
                    task.subphase = .complete
                    task.progress = 1.0
                    task.outputURL = csv
                    task.error = nil
                }
            } else {
                // Neither exists — full pipeline
                fullPipeline.append(task)
                setTaskStatus(task, .queued)
                setOnMain { task.progress = 0; task.error = nil; task.subphase = .idle }
            }
        }

        let grouped = Dictionary(grouping: fullPipeline, by: { $0.cartItem.recording.dotAddress })

        guard !grouped.isEmpty else {
            DispatchQueue.main.async {
                self.exportPhase = .done
                self.endExportBackgroundTask()
            }
            return
        }

        exportSequenceQueue.async { [weak self] in
            guard let self else { return }

            let semaphore = DispatchSemaphore(value: 0)

            for (address, tasksForDot) in grouped {
                guard !self.currentExportCanceled else { break }

                guard let dot = DotManager.shared.dot(forUuid: address), dot.isConnected else {
                    for task in tasksForDot {
                        self.setTaskStatus(task, .failed, error: "Sensor disconnected")
                    }
                    continue
                }

                self.exportFilesForDot(dot: dot, tasks: tasksForDot) {
                    semaphore.signal()
                }
                semaphore.wait()
            }

            DispatchQueue.main.async {
                self.exportPhase = .done
                self.endExportBackgroundTask()
            }
        }
    }

    /// Reset state so the user can start a new export.
    func resetExport() {
        tasks.removeAll()
        exportPhase = recordings.isEmpty ? .idle : .ready
    }

    // MARK: - Per-Device Export

    /// Export all selected files for a single dot sequentially, writing CSV rows directly.
    private func exportFilesForDot(dot: Dot, tasks: [ExportTask], completion: @escaping () -> Void) {
        let fileIndices = tasks.map { $0.cartItem.recording.fileIndex }

        // Configure export data format: timestamp + euler + acceleration + angular velocity
        let formatBytes: [UInt8] = [
            UInt8(XSRecordingData.timestamp.rawValue),
            UInt8(XSRecordingData.eulerAngles.rawValue),
            UInt8(XSRecordingData.acceleration.rawValue),
            UInt8(XSRecordingData.angularVelocity.rawValue)
        ]

        var taskIndex = 0

        func exportNextFile() {
            guard taskIndex < tasks.count, !currentExportCanceled else {
                completion()
                return
            }

            let task = tasks[taskIndex]
            let fileIndex = fileIndices[taskIndex]

            setTaskStatus(task, .running)
            setOnMain { task.subphase = .transferring }
            isTransferring = true

            var packetsReceived = 0
            var exportCompleted = false

            let csvPath = csvURL(for: task)

            // Estimate total packets from file size.
            // Empirical ratio: 647 KB → 7541 packets → ~88 bytes per packet on-device.
            let estimatedTotalPackets = max(task.cartItem.recording.fileSize / 88, 1)

            // Create CSV file with header on fileQueue, then configure SDK + start export on sdkQueue.
            fileQueue.async { [weak self] in
                guard let self else { completion(); return }

                let csvHeader = "packet_counter,timestamp,euler_x,euler_y,euler_z,acc_x,acc_y,acc_z,gyr_x,gyr_y,gyr_z\n"
                FileManager.default.createFile(atPath: csvPath.path, contents: Data(csvHeader.utf8))
                guard let fileHandle = try? FileHandle(forWritingTo: csvPath) else {
                    self.setTaskStatus(task, .failed, error: "Failed to open CSV file")
                    taskIndex += 1
                    exportNextFile()
                    return
                }
                fileHandle.seekToEndOfFile()

                self.sdkQueue.async { [weak self] in
                    guard let self else { completion(); return }

                    // Batch of CSV row bytes — owned and mutated only on sdkQueue
                    var batch = Data()
                    batch.reserveCapacity(200 * 120)  // ~120 bytes per CSV row

                    let device = dot.device

                    // Reset SDK export state from previous file (no-op on first file)
                    device.stopExportFileData()

                    // Bump generation to invalidate any stale callbacks
                    self.exportFileGeneration += 1
                    let generation = self.exportFileGeneration

                    // Set export format
                    device.exportDataFormat = Data(formatBytes)

                    // Set file list (single file)
                    device.recording.exportFileList = [NSNumber(value: fileIndex)]

                    // Create watchdog for this file
                    let watchdog = ExportWatchdog(
                        timeout: self.dataTimeoutInterval,
                        queue: self.sdkQueue
                    ) { [weak self] in
                        // Timeout handler — runs on sdkQueue
                        guard let self, !exportCompleted else { return }
                        exportCompleted = true

                        print("⏰ [\(dot.address)] Export data timeout for \(task.cartItem.label)")

                        // Clear callbacks to prevent late packets leaking
                        device.setDidParseExportFileDataBlock(nil)
                        device.recording.exportFileDone = { _, _ in }
                        device.stopExportFileData()

                        self.isTransferring = false

                        // Close handle and delete partial .csv
                        self.fileQueue.async {
                            try? fileHandle.close()
                            try? FileManager.default.removeItem(at: csvPath)

                            self.setTaskStatus(task, .failed, error: "Export timed out")
                            taskIndex += 1
                            exportNextFile()
                        }
                    }
                    self.activeWatchdog = watchdog

                    // Timing for throughput measurement
                    let exportStartTime = CACurrentMediaTime()
                    var lastProgressUpdate = exportStartTime

                    // Callback instrumentation
                    var cbTimeTotal: Double = 0
                    var cbTimeMax: Double = 0

                    // Install data callback — format CSV row, dispatch batches to fileQueue
                    device.setDidParseExportFileDataBlock { [weak self] plotData in
                        let cbStart = CACurrentMediaTime()
                        guard let self, !exportCompleted else { return }
                        guard self.exportFileGeneration == generation else { return }

                        watchdog.beat()
                        packetsReceived += 1

                        let row = String(format: "%u,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                                         plotData.packageCounter, plotData.timeStamp,
                                         plotData.euler0, plotData.euler1, plotData.euler2,
                                         plotData.acc0, plotData.acc1, plotData.acc2,
                                         plotData.gyr0, plotData.gyr1, plotData.gyr2)
                        batch.append(Data(row.utf8))

                        // Flush batch to fileQueue every 200 packets
                        if packetsReceived % 200 == 0 {
                            let captured = batch
                            batch.removeAll(keepingCapacity: true)
                            self.fileQueue.async {
                                fileHandle.write(captured)
                            }
                        }

                        // Throttled UI update: every 100 packets or 0.5s
                        // Linear progress capped at 0.99 until exportFileDone sets 1.0
                        let now = CACurrentMediaTime()
                        if packetsReceived % 100 == 0 || (now - lastProgressUpdate) >= 0.5 {
                            lastProgressUpdate = now
                            let progress = min(Double(packetsReceived) / Double(estimatedTotalPackets), 0.99)
                            self.setOnMain { task.progress = progress }
                        }

                        // Instrumentation
                        let cbDuration = CACurrentMediaTime() - cbStart
                        cbTimeTotal += cbDuration
                        if cbDuration > cbTimeMax { cbTimeMax = cbDuration }
                        if packetsReceived % 500 == 0 {
                            let avg = cbTimeTotal / Double(packetsReceived)
                            print("⚡ [\(dot.address)] Callback stats @ \(packetsReceived): avg \(String(format: "%.3f", avg * 1000))ms, max \(String(format: "%.3f", cbTimeMax * 1000))ms")
                        }
                    }

                    // Install file-done callback
                    device.recording.exportFileDone = { [weak self] _, result in
                        guard let self, !exportCompleted else { return }
                        guard self.exportFileGeneration == generation else { return }
                        exportCompleted = true

                        watchdog.stop()
                        self.activeWatchdog = nil
                        self.isTransferring = false

                        // Bump generation again to invalidate any double-fire
                        self.exportFileGeneration += 1

                        device.setDidParseExportFileDataBlock(nil)
                        device.recording.exportFileDone = { _, _ in }

                        // Capture remaining batch on sdkQueue — no shared mutable Data crosses queues
                        let finalChunk: Data? = batch.isEmpty ? nil : batch
                        batch.removeAll(keepingCapacity: true)
                        let finalPackets = packetsReceived
                        let elapsed = CACurrentMediaTime() - exportStartTime
                        let avgCb = finalPackets > 0 ? cbTimeTotal / Double(finalPackets) : 0

                        // Flush remaining + close on fileQueue, then mark success
                        self.fileQueue.async {
                            if let finalChunk {
                                fileHandle.write(finalChunk)
                            }
                            try? fileHandle.close()

                            let pps = elapsed > 0 ? Double(finalPackets) / elapsed : 0
                            print("📡 [\(dot.address)] Transfer: \(finalPackets) pkts in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", pps)) pkt/s), cb avg \(String(format: "%.2f", avgCb * 1000))ms")

                            self.setOnMain {
                                task.progress = 1.0
                                task.outputURL = csvPath
                                task.subphase = .complete
                                task.status = .success
                                print("✅ Exported \(task.cartItem.label) → \(csvPath.lastPathComponent)")
                            }
                            taskIndex += 1
                            exportNextFile()
                        }
                    }

                    // Install status callback
                    device.recording.updateExportingStatus = { status in
                        switch status {
                        case .isStopExportingData:
                            print("📤 [\(dot.address)] Export status: stopped")
                        default:
                            break
                        }
                    }

                    // Start export — CSV file is already created on fileQueue
                    device.startExportFileData()
                    print("📤 [\(dot.address)] Started export for file \(fileIndex)")
                }
            }
        }

        exportNextFile()
    }

    // MARK: - URL Helpers

    /// Deterministic .csv path for a task.
    private func csvURL(for task: ExportTask) -> URL {
        guard let dir = exportDir() else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(task.id).csv")
        }
        let filename = uniqueStem(for: task) + ".csv"
        return dir.appendingPathComponent(filename)
    }

    /// Stable stem based on task identity (label + address + file index + task creation).
    /// Using task.id ensures uniqueness across retries since task objects persist.
    private func uniqueStem(for task: ExportTask) -> String {
        let sanitizedLabel = sanitize(task.cartItem.label)
        let last4 = String(task.cartItem.recording.dotAddress.suffix(4))
        let fileIndex = task.cartItem.recording.fileIndex
        // Use a hash of the task id for a short stable suffix
        let idHash = abs(task.id.hashValue) % 100000
        return "\(sanitizedLabel)_\(last4)_f\(fileIndex)_\(idHash)"
    }

    // MARK: - File Helpers

    private func exportDir() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            print("❌ Failed to create Exports directory: \(error)")
            return nil
        }
    }

    private func sanitize(_ label: String) -> String {
        label.replacingOccurrences(of: "/", with: "_")
             .replacingOccurrences(of: ":", with: "_")
             .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Exported Files

    /// Returns URLs of all successfully exported files.
    var exportedFileURLs: [URL] {
        tasks.compactMap { $0.outputURL }
    }

    // MARK: - Background Task

    /// Begin a UIBackgroundTask spanning the full export so iOS doesn't suspend
    /// the app while BLE transfers are in progress. The `bluetooth-central`
    /// background mode keeps SDK callbacks alive; this provides the formal
    /// signal to iOS that background work is ongoing.
    private func beginExportBackgroundTask() {
        guard cleanupBackgroundTaskID == .invalid else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        cleanupBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DOT Export") { [weak self] in
            // Expiration handler — iOS is about to force-suspend; end gracefully.
            self?.endExportBackgroundTask()
        }
        print("🔋 Export background task started (id: \(cleanupBackgroundTaskID.rawValue))")
    }

    /// End the export background task. Safe to call multiple times.
    private func endExportBackgroundTask() {
        let taskID = cleanupBackgroundTaskID
        guard taskID != .invalid else { return }
        cleanupBackgroundTaskID = .invalid
        UIApplication.shared.isIdleTimerDisabled = false
        UIApplication.shared.endBackgroundTask(taskID)
        print("🔋 Export background task ended (id: \(taskID.rawValue))")
    }

    // MARK: - Helpers

    private func setOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private func setTaskStatus(_ task: ExportTask, _ status: ExportStatus, error: String? = nil) {
        setOnMain {
            task.status = status
            if let error { task.error = error }
        }
    }
}

// MARK: - ExportWatchdog

/// Per-file timeout watchdog that checks a timestamp-based heartbeat.
/// Both `beat()` and the timer fire on `sdkQueue` — no lock needed.
private final class ExportWatchdog {

    private var lastPacketAt: Date
    private let timeout: TimeInterval
    private var timer: DispatchSourceTimer?

    init(timeout: TimeInterval, queue: DispatchQueue, onTimeout: @escaping () -> Void) {
        self.timeout = timeout
        self.lastPacketAt = Date()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPacketAt) > self.timeout {
                self.stop()
                onTimeout()
            }
        }
        self.timer = source
        source.resume()
    }

    /// Called from SDK data callback on sdkQueue to signal data is still flowing.
    func beat() {
        lastPacketAt = Date()
    }

    /// Cancel the timer. Safe to call multiple times.
    func stop() {
        timer?.cancel()
        timer = nil
    }
}
