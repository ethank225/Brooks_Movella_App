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

        // Prune recordings and cart items when sensors disconnect.
        DotManager.shared.$connectedDots
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.pruneDisconnectedDots(connected: connected)
            }
            .store(in: &cancellables)
    }

    // MARK: - Queues

    private var sdkQueue: DispatchQueue { DotManager.shared.sdkQueue }
    private let fileQueue = DispatchQueue(label: "ExportManager.fileQueue")
    private let exportSequenceQueue = DispatchQueue(
        label: "ExportManager.exportSequenceQueue")

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
    private var exportSequenceGeneration: Int = 0
    private var currentExportSemaphore: DispatchSemaphore?
    private var cleanupBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()

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

    // MARK: - Disconnection Pruning

    /// Called on the main thread whenever the connected-dots list changes.
    /// Removes recordings, selections, and cart items for any dot that is no
    /// longer connected. Safe to call during export — skipped while exporting
    /// so in-flight tasks are not disturbed.
    private func pruneDisconnectedDots(connected: [Dot]) {
        guard exportPhase != .exporting else { return }

        let connectedAddresses = Set(connected.map { $0.address })
        let disconnectedAddresses = Set(recordings.keys).subtracting(connectedAddresses)
        guard !disconnectedAddresses.isEmpty else { return }

        for address in disconnectedAddresses {
            recordings.removeValue(forKey: address)
        }

        // Remove selections whose file no longer appears in any recording list.
        let remainingIDs = Set(recordings.values.flatMap { $0 }.map { $0.id })
        selectedIDs = selectedIDs.intersection(remainingIDs)

        // Remove cart items whose sensor is gone.
        cartItems.removeAll { disconnectedAddresses.contains($0.recording.dotAddress) }

        // If recordings are now empty and we were in the ready state, go back to idle.
        if recordings.isEmpty && exportPhase == .ready {
            exportPhase = .idle
        }
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

            // Remove cart items and selections for files that no longer exist
            // on the sensor (e.g. erased while in the cart).
            let availableIDs = Set(self.recordings.values.flatMap { $0 }.map { $0.id })
            self.selectedIDs = self.selectedIDs.intersection(availableIDs)
            self.cartItems.removeAll { !availableIDs.contains($0.recording.id) }
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

    /// Returns distinct session UUIDs in the order they first appear in cartItems.
    var cartSessions: [UUID] {
        var seen = Set<UUID>()
        return cartItems.compactMap { seen.insert($0.sessionId).inserted ? $0.sessionId : nil }
    }

    /// Move selected files into the cart, auto-grouping into sessions by timestamp proximity.
    /// Files recorded within 60 seconds of an existing session item are assigned to that session.
    func buildCart() {
        let allFiles = recordings.values.flatMap { $0 }
        let selected = allFiles.filter { selectedIDs.contains($0.id) }

        // Don't add duplicates already in cart
        let existingIDs = Set(cartItems.map { $0.id })

        var newItems: [CartItem] = []
        for file in selected
                .filter({ !existingIDs.contains($0.id) })
                .sorted(by: { $0.timestamp < $1.timestamp }) {
            let sid = sessionForFile(file, considering: cartItems + newItems) ?? UUID()
            var item = CartItem(recording: file)
            item.sessionId = sid
            newItems.append(item)
        }

        cartItems.append(contentsOf: newItems)
        selectedIDs.removeAll()
    }

    private func sessionForFile(_ file: RecordingFile, considering items: [CartItem]) -> UUID? {
        items.first(where: { abs(Int(file.timestamp) - Int($0.recording.timestamp)) <= 60 })?.sessionId
    }

    func reassignSession(itemId: String, to sessionId: UUID) {
        guard let idx = cartItems.firstIndex(where: { $0.id == itemId }) else { return }
        cartItems[idx].sessionId = sessionId
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

        // Capture generation so only this export sequence can finalize the phase.
        exportSequenceGeneration += 1
        let myGen = exportSequenceGeneration
        let semaphore = DispatchSemaphore(value: 0)
        currentExportSemaphore = semaphore

        // Process devices sequentially on a dedicated queue so fileQueue stays
        // free for CSV writes dispatched from SDK callbacks.
        exportSequenceQueue.async { [weak self] in
            guard let self else { return }

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
                guard self.exportSequenceGeneration == myGen else { return }
                self.exportPhase = .done
                self.endExportBackgroundTask()
            }
        }
    }

    /// Cancel the active export.
    func cancelExport() {
        // Invalidate the current export generation so the sequence block's final
        // DispatchQueue.main.async doesn't overwrite state after a new export starts.
        exportSequenceGeneration += 1

        sdkQueue.async {
            self.currentExportCanceled = true
            self.isTransferring = false
        }
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

        // Unblock the exportSequenceQueue if it's blocked in semaphore.wait().
        // The SDK does NOT call exportFileDone when stopExportFileData() is called
        // during an active transfer, so the semaphore would never be signaled otherwise,
        // leaving the sequence queue hung and preventing any subsequent export.
        currentExportSemaphore?.signal()
        currentExportSemaphore = nil

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

        exportSequenceGeneration += 1
        let myGen = exportSequenceGeneration
        let semaphore = DispatchSemaphore(value: 0)
        currentExportSemaphore = semaphore

        exportSequenceQueue.async { [weak self] in
            guard let self else { return }

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
                guard self.exportSequenceGeneration == myGen else { return }
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
    
    private func validatePacketSequence(csvURL: URL) -> Bool {
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: "\n").dropFirst() // skip header
        
        var lastCounter: UInt32? = nil
        for line in lines {
            guard !line.isEmpty else { continue }
            let cols = line.components(separatedBy: ",")
            guard let counterStr = cols.first, let counter = UInt32(counterStr) else { return false }
            
            if let last = lastCounter {
                if counter != last + 1 {
                    print("⚠️ Packet gap detected: expected \(last + 1), got \(counter)")
                    return false
                }
            }
            lastCounter = counter
        }
        return true
    }

    // MARK: - Per-Device Export

    /// Export all selected files for a single dot sequentially, writing CSV rows directly.
    private func exportFilesForDot(dot: Dot, tasks: [ExportTask], completion: @escaping () -> Void) {
        let fileIndices = tasks.map { $0.cartItem.recording.fileIndex }

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

            var packetsReceived = 0
            var exportCompleted = false

            let csvPath = csvURL(for: task)
            let estimatedTotalPackets = max(task.cartItem.recording.fileSize / 88, 1)

            fileQueue.async { [weak self] in
                guard let self else { completion(); return }

                let csvHeader = "packet_counter,timestamp,euler_x,euler_y,euler_z,acc_x,acc_y,acc_z,gyr_x,gyr_y,gyr_z\n"
                FileManager.default.createFile(atPath: csvPath.path, contents: Data(csvHeader.utf8))
                guard let fileHandle = try? FileHandle(forWritingTo: csvPath) else {
                    self.setTaskStatus(task, .failed, error: "Failed to open CSV file")
                    self.sdkQueue.async {
                        taskIndex += 1
                        exportNextFile()
                    }
                    return
                }
                fileHandle.seekToEndOfFile()

                self.sdkQueue.async { [weak self] in
                    guard let self else { completion(); return }

                    var batch = Data()
                    batch.reserveCapacity(200 * 120)

                    let device = dot.device
                    device.stopExportFileData()
                    self.isTransferring = true

                    self.exportFileGeneration += 1
                    let generation = self.exportFileGeneration

                    device.exportDataFormat = Data(formatBytes)
                    device.recording.exportFileList = [NSNumber(value: fileIndex)]

                    // MARK: Watchdog — timeout just fails, no validation needed here
                    let watchdog = ExportWatchdog(
                        timeout: self.dataTimeoutInterval,
                        queue: self.sdkQueue
                    ) { [weak self] in
                        guard let self, !exportCompleted else { return }
                        exportCompleted = true

                        print("⏰ [\(dot.address)] Export data timeout for \(task.cartItem.label)")

                        device.setDidParseExportFileDataBlock(nil)
                        device.recording.exportFileDone = { _, _ in }
                        device.stopExportFileData()
                        self.isTransferring = false

                        self.fileQueue.async {
                            try? fileHandle.close()
                            try? FileManager.default.removeItem(at: csvPath)
                            self.setTaskStatus(task, .failed, error: "Export timed out")
                            self.sdkQueue.async {
                                taskIndex += 1
                                exportNextFile()
                            }
                        }
                    }
                    self.activeWatchdog = watchdog

                    let exportStartTime = CACurrentMediaTime()
                    var lastProgressUpdate = exportStartTime
                    var cbTimeTotal: Double = 0
                    var cbTimeMax: Double = 0

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

                        if packetsReceived % 200 == 0 {
                            let captured = batch
                            batch.removeAll(keepingCapacity: true)
                            self.fileQueue.async { fileHandle.write(captured) }
                        }

                        let now = CACurrentMediaTime()
                        if packetsReceived % 100 == 0 || (now - lastProgressUpdate) >= 0.5 {
                            lastProgressUpdate = now
                            let progress = min(Double(packetsReceived) / Double(estimatedTotalPackets), 0.99)
                            self.setOnMain { task.progress = progress }
                        }

                        let cbDuration = CACurrentMediaTime() - cbStart
                        cbTimeTotal += cbDuration
                        if cbDuration > cbTimeMax { cbTimeMax = cbDuration }
                        if packetsReceived % 500 == 0 {
                            let avg = cbTimeTotal / Double(packetsReceived)
                            print("⚡ [\(dot.address)] Callback stats @ \(packetsReceived): avg \(String(format: "%.3f", avg * 1000))ms, max \(String(format: "%.3f", cbTimeMax * 1000))ms")
                        }
                    }

                    // MARK: exportFileDone — validate here, log gaps and continue
                    device.recording.exportFileDone = { [weak self] _, result in
                        guard let self, !exportCompleted else { return }
                        guard self.exportFileGeneration == generation else { return }
                        exportCompleted = true

                        watchdog.stop()
                        self.activeWatchdog = nil
                        self.isTransferring = false
                        self.exportFileGeneration += 1

                        device.setDidParseExportFileDataBlock(nil)
                        device.recording.exportFileDone = { _, _ in }

                        let finalChunk: Data? = batch.isEmpty ? nil : batch
                        batch.removeAll(keepingCapacity: true)
                        let finalPackets = packetsReceived
                        let elapsed = CACurrentMediaTime() - exportStartTime
                        let avgCb = finalPackets > 0 ? cbTimeTotal / Double(finalPackets) : 0

                        self.fileQueue.async {
                            if let finalChunk { fileHandle.write(finalChunk) }
                            try? fileHandle.close()

                            let pps = elapsed > 0 ? Double(finalPackets) / elapsed : 0
                            print("📡 [\(dot.address)] Transfer: \(finalPackets) pkts in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", pps)) pkt/s), cb avg \(String(format: "%.2f", avgCb * 1000))ms")

                            // MARK: Packet gap validation
                            let isValid = self.validatePacketSequence(csvURL: csvPath)

                            if !isValid {
                                print("⚠️ [\(dot.address)] Packet loss detected in \(task.cartItem.label)")
                            }
                            self.setOnMain {
                                task.progress = 1.0
                                task.outputURL = csvPath
                                task.subphase = .complete
                                task.status = .success
                                print("✅ Exported \(task.cartItem.label) → \(csvPath.lastPathComponent)")
                            }

                            self.sdkQueue.async {
                                taskIndex += 1
                                exportNextFile()
                            }
                        }
                    }

                    device.recording.updateExportingStatus = { status in
                        switch status {
                        case .isStopExportingData:
                            print("📤 [\(dot.address)] Export status: stopped")
                        default:
                            break
                        }
                    }

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
