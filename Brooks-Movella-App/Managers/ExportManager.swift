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
/// file discovery, cart selection, export pipeline, and binary→CSV file writing.
///
/// **Two-phase pipeline:**
/// - Phase A (Transfer): BLE data → packed binary `.bin` file (foreground-only)
/// - Phase B (Convert): `.bin` → `.csv` (can continue in background)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
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

    /// True when an export was interrupted by leaving foreground.
    /// UI should show a prompt; user must tap Retry to resume.
    @Published private(set) var requiresForeground: Bool = false

    // MARK: - Export State (internal)

    private var currentExportCanceled = false
    private var activeWatchdog: ExportWatchdog?
    private var exportFileGeneration: Int = 0
    private var cleanupBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var conversionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// True while Phase A (BLE transfer) is active. Used by app-state handlers
    /// to decide whether to cancel on background.
    private var isTransferring = false

    private let dataTimeoutInterval: TimeInterval = 10.0

    // MARK: - App State Handling

    @objc private func appWillResignActive() {
        // Only cancel during Phase A (BLE transfer). Phase B (conversion) can continue.
        guard exportPhase == .exporting, isTransferring else { return }
        print("⚠️ App will resign active — canceling transfer with grace period")
        beginCleanupGracePeriod()
        cancelExport()
        setOnMain { self.requiresForeground = true }
    }

    @objc private func appDidEnterBackground() {
        guard exportPhase == .exporting, isTransferring else { return }
        print("⚠️ App entered background — canceling transfer with grace period")
        beginCleanupGracePeriod()
        cancelExport()
        setOnMain { self.requiresForeground = true }
    }

    @objc private func appDidBecomeActive() {
        setOnMain { self.requiresForeground = false }
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
                        timestamp: file.timeStamap
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

        guard UIApplication.shared.applicationState == .active else {
            setOnMain { self.requiresForeground = true }
            return
        }

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
        // free for binary writing dispatched from SDK callbacks.
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
            // Delete incomplete .bin files for tasks that were transferring
            if task.subphase == .transferring {
                let binPath = binURL(for: task)
                fileQueue.async {
                    try? FileManager.default.removeItem(at: binPath)
                }
            }
            setTaskStatus(task, .canceled)
        }

        setOnMain {
            self.exportPhase = .done
        }
    }

    /// Re-queue failed/canceled tasks for retry. Must be called in foreground.
    /// Uses resume logic: .csv exists → done, .bin exists → convert-only, else full pipeline.
    func retryFailed() {
        let retryable = tasks.filter { $0.status == .failed || $0.status == .canceled }
        guard !retryable.isEmpty else { return }

        guard UIApplication.shared.applicationState == .active else {
            setOnMain { self.requiresForeground = true }
            return
        }

        currentExportCanceled = false
        setOnMain { self.exportPhase = .exporting }

        // Check disk state for each task and split into categories
        var convertOnly: [ExportTask] = []
        var fullPipeline: [ExportTask] = []

        for task in retryable {
            let csv = csvURL(for: task)
            let bin = binURL(for: task)

            if FileManager.default.fileExists(atPath: csv.path) {
                // CSV already exists — mark success immediately
                setOnMain {
                    task.status = .success
                    task.subphase = .complete
                    task.progress = 1.0
                    task.outputURL = csv
                    task.error = nil
                }
            } else if FileManager.default.fileExists(atPath: bin.path) {
                // Binary exists — skip BLE, convert only
                convertOnly.append(task)
                setOnMain {
                    task.status = .running
                    task.subphase = .converting
                    task.progress = 0.80
                    task.error = nil
                }
            } else {
                // Neither exists — full pipeline
                fullPipeline.append(task)
                setTaskStatus(task, .queued)
                setOnMain { task.progress = 0; task.error = nil; task.subphase = .idle }
            }
        }

        // Dispatch convert-only tasks on fileQueue
        for task in convertOnly {
            dispatchConversion(for: task)
        }

        // Full pipeline tasks grouped by address
        let grouped = Dictionary(grouping: fullPipeline, by: { $0.cartItem.recording.dotAddress })

        guard !grouped.isEmpty else {
            // Only convert-only tasks — wait for them to finish, then mark done
            fileQueue.async { [weak self] in
                DispatchQueue.main.async {
                    // Check if all tasks are now success/failed
                    self?.checkIfAllDone()
                }
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
            }
        }
    }

    /// Reset state so the user can start a new export.
    func resetExport() {
        tasks.removeAll()
        exportPhase = recordings.isEmpty ? .idle : .ready
    }

    // MARK: - Per-Device Export (Phase A: Transfer)

    /// Export all selected files for a single dot sequentially via binary pipeline.
    private func exportFilesForDot(dot: Dot, tasks: [ExportTask], completion: @escaping () -> Void) {
        let fileIndices = tasks.map { $0.cartItem.recording.fileIndex }

        // Configure export data format: timestamp + euler + acceleration + angular velocity
        let formatBytes: [UInt8] = [
            UInt8(XSRecordingData.timestamp.rawValue),
            UInt8(XSRecordingData.eulerAngles.rawValue),
            UInt8(XSRecordingData.acceleration.rawValue),
            UInt8(XSRecordingData.angularVelocity.rawValue)
        ]

        // We export one file at a time for cleaner separation and progress tracking
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

            // Resolve output paths
            let binPath = binURL(for: task)
            let csvPath = csvURL(for: task)

            // Create writer on fileQueue, then configure SDK + start export on sdkQueue.
            fileQueue.async { [weak self] in
                guard let self else { completion(); return }

                let writer = BinaryStreamWriter(url: binPath)

                self.sdkQueue.async { [weak self] in
                    guard let self else { completion(); return }

                    // Pre-allocate scratch buffer and batch — owned and mutated only on sdkQueue
                    var scratch = Data(count: BinaryStreamWriter.recordSize)
                    var batch = Data()
                    batch.reserveCapacity(200 * BinaryStreamWriter.recordSize)

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

                        // Close writer and delete partial .bin
                        self.fileQueue.async {
                            writer.close()
                            try? FileManager.default.removeItem(at: binPath)

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

                    // Install data callback — pack raw bytes, dispatch batches to fileQueue
                    device.setDidParseExportFileDataBlock { [weak self] plotData in
                        let cbStart = CACurrentMediaTime()
                        guard let self, !exportCompleted else { return }
                        guard self.exportFileGeneration == generation else { return }

                        watchdog.beat()
                        packetsReceived += 1

                        // Pack 11 fields into 44-byte scratch buffer (reuse, no allocation)
                        scratch.withUnsafeMutableBytes { ptr in
                            let base = ptr.baseAddress!
                            var pkg = plotData.packageCounter
                            var ts  = plotData.timeStamp
                            var e0  = Float32(plotData.euler0)
                            var e1  = Float32(plotData.euler1)
                            var e2  = Float32(plotData.euler2)
                            var a0  = Float32(plotData.acc0)
                            var a1  = Float32(plotData.acc1)
                            var a2  = Float32(plotData.acc2)
                            var g0  = Float32(plotData.gyr0)
                            var g1  = Float32(plotData.gyr1)
                            var g2  = Float32(plotData.gyr2)

                            memcpy(base + 0,  &pkg, 4)
                            memcpy(base + 4,  &ts,  4)
                            memcpy(base + 8,  &e0,  4)
                            memcpy(base + 12, &e1,  4)
                            memcpy(base + 16, &e2,  4)
                            memcpy(base + 20, &a0,  4)
                            memcpy(base + 24, &a1,  4)
                            memcpy(base + 28, &a2,  4)
                            memcpy(base + 32, &g0,  4)
                            memcpy(base + 36, &g1,  4)
                            memcpy(base + 40, &g2,  4)
                        }
                        batch.append(scratch)

                        // Flush batch to fileQueue every 200 packets
                        if batch.count >= 200 * BinaryStreamWriter.recordSize {
                            let captured = batch
                            batch.removeAll(keepingCapacity: true)
                            self.fileQueue.async {
                                writer.appendData(captured)
                            }
                        }

                        // Throttled UI update: every 100 packets or 0.5s
                        // Asymptotic progress: smoothly approaches 0.80, never exceeds it
                        let now = CACurrentMediaTime()
                        if packetsReceived % 100 == 0 || (now - lastProgressUpdate) >= 0.5 {
                            lastProgressUpdate = now
                            let n = Double(packetsReceived)
                            let progress = 0.80 * n / (n + 1000.0)
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

                        // Flush remaining + close writer on fileQueue, then start Phase B
                        self.fileQueue.async {
                            if let finalChunk {
                                writer.appendData(finalChunk)
                            }
                            writer.close()

                            // Log Phase A stats
                            let pps = elapsed > 0 ? Double(finalPackets) / elapsed : 0
                            let binSize = (try? FileManager.default.attributesOfItem(atPath: binPath.path)[.size] as? Int) ?? 0
                            print("📡 [\(dot.address)] Transfer: \(finalPackets) pkts in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", pps)) pkt/s), .bin = \(binSize / 1024) KB, cb avg \(String(format: "%.2f", avgCb * 1000))ms")

                            // Advance to Phase B: conversion
                            self.setOnMain { task.subphase = .converting }

                            self.beginConversionGracePeriod()
                            self.runConversion(task: task, binPath: binPath, csvPath: csvPath) {
                                self.endConversionGracePeriod()
                                taskIndex += 1
                                exportNextFile()
                            }
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

                    // Start export — writer is already created on fileQueue
                    device.startExportFileData()
                    print("📤 [\(dot.address)] Started export for file \(fileIndex)")
                }
            }
        }

        exportNextFile()
    }

    // MARK: - Phase B: Conversion

    /// Run binary→CSV conversion for a single task. Called on fileQueue.
    private func runConversion(task: ExportTask, binPath: URL, csvPath: URL, completion: @escaping () -> Void) {
        // Already on fileQueue
        let convertStart = CACurrentMediaTime()

        do {
            _ = try BinaryToCsvConverter.convert(
                binURL: binPath,
                csvURL: csvPath
            ) { [weak self] fraction in
                // Map converter's 0.0–1.0 → task's 0.80–1.0
                let progress = 0.80 + fraction * 0.20
                self?.setOnMain { task.progress = progress }
            }

            // Log Phase B stats
            let elapsed = CACurrentMediaTime() - convertStart
            let binSize = (try? FileManager.default.attributesOfItem(atPath: binPath.path)[.size] as? Int) ?? 0
            let csvSize = (try? FileManager.default.attributesOfItem(atPath: csvPath.path)[.size] as? Int) ?? 0
            let totalRecords = max((binSize - BinaryStreamWriter.headerSize) / BinaryStreamWriter.recordSize, 0)
            let rps = elapsed > 0 ? Double(totalRecords) / elapsed : 0
            print("📄 [\(task.cartItem.recording.dotAddress)] Convert: \(totalRecords) rows in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", rps)) rows/s), .csv = \(csvSize / 1024) KB")

            // Delete .bin, mark success
            try? FileManager.default.removeItem(at: binPath)

            setOnMain {
                task.progress = 1.0
                task.outputURL = csvPath
                task.subphase = .complete
                task.status = .success
                print("✅ Exported \(task.cartItem.label) → \(csvPath.lastPathComponent)")
            }
        } catch {
            print("❌ [\(task.cartItem.recording.dotAddress)] Conversion failed: \(error)")
            // Keep .bin for retry
            setTaskStatus(task, .failed, error: "Conversion failed: \(error.localizedDescription)")
        }

        completion()
    }

    /// Dispatch conversion for a task that already has a .bin file (retry scenario).
    private func dispatchConversion(for task: ExportTask) {
        let binPath = binURL(for: task)
        let csvPath = csvURL(for: task)

        beginConversionGracePeriod()

        fileQueue.async { [weak self] in
            guard let self else { return }
            self.runConversion(task: task, binPath: binPath, csvPath: csvPath) { [weak self] in
                self?.endConversionGracePeriod()
                self?.checkIfAllDone()
            }
        }
    }

    /// Check if all tasks are terminal and transition to .done if so.
    private func checkIfAllDone() {
        let allTerminal = tasks.allSatisfy {
            $0.status == .success || $0.status == .failed || $0.status == .canceled
        }
        if allTerminal {
            setOnMain { self.exportPhase = .done }
        }
    }

    // MARK: - URL Helpers

    /// Deterministic .bin path for a task.
    private func binURL(for task: ExportTask) -> URL {
        guard let dir = exportDir() else {
            // Fallback — shouldn't happen in practice
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(task.id).bin")
        }
        let filename = uniqueStem(for: task) + ".bin"
        return dir.appendingPathComponent(filename)
    }

    /// Deterministic .csv path for a task (same stem as .bin).
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

    // MARK: - Unique Filenames (legacy, kept for compatibility)

    /// Generate a unique filename to prevent overwrites on retry or same-label exports.
    private func uniqueFilename(label: String, dotAddress: String, fileIndex: Int) -> String {
        let sanitizedLabel = sanitize(label)
        let last4 = String(dotAddress.suffix(4))
        let ts = Int(Date().timeIntervalSince1970)
        return "\(sanitizedLabel)_\(last4)_f\(fileIndex)_\(ts).csv"
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

    // MARK: - Background Grace Periods

    /// Request a short background task so cancelExport() + writer cleanup
    /// can finish before iOS suspends the app. Ends automatically after 3s.
    private func beginCleanupGracePeriod() {
        guard cleanupBackgroundTaskID == .invalid else { return }
        cleanupBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DOT Export Cleanup") { [weak self] in
            self?.endCleanupGracePeriod()
        }
        print("🔋 Cleanup grace period started (id: \(cleanupBackgroundTaskID.rawValue))")

        // Auto-end after 3 seconds — just enough for stopExportFileData + writer.close
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.endCleanupGracePeriod()
        }
    }

    /// End the cleanup background task. Safe to call multiple times.
    private func endCleanupGracePeriod() {
        let taskID = cleanupBackgroundTaskID
        guard taskID != .invalid else { return }
        cleanupBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        print("🔋 Cleanup grace period ended (id: \(taskID.rawValue))")
    }

    /// Request a background task for Phase B (conversion). iOS gives ~30s.
    private func beginConversionGracePeriod() {
        guard conversionBackgroundTaskID == .invalid else { return }
        conversionBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DOT Export Conversion") { [weak self] in
            self?.endConversionGracePeriod()
        }
        print("🔋 Conversion grace period started (id: \(conversionBackgroundTaskID.rawValue))")
    }

    /// End the conversion background task. Safe to call multiple times.
    private func endConversionGracePeriod() {
        let taskID = conversionBackgroundTaskID
        guard taskID != .invalid else { return }
        conversionBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        print("🔋 Conversion grace period ended (id: \(taskID.rawValue))")
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
