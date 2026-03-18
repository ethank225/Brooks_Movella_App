import Foundation
import UIKit
import UserNotifications
import MovellaDotSdk
import Combine

// MARK: - ExportManager

/// Singleton managing the recording-export lifecycle:
/// file discovery, cart selection, export pipeline, and CSV file writing.
///
/// **Pipeline:** BLE data → CSV rows written directly to disk (see `ExportManager+BLETransfer.swift`).
///
/// **Threading:**
/// - SDK calls            → `DotManager.shared.sdkQueue`
/// - File I/O             → `fileQueue`
/// - Published state      → main thread
final class ExportManager: ObservableObject {

    static let shared = ExportManager()

    private init() {
        restorePersistedTasks()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
//        NotificationCenter.default.addObserver(
//            self,
//            selector: #selector(appDidEnterBackground),
//            name: UIApplication.didEnterBackgroundNotification,
//            object: nil
//        )

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

    // Internal so ExportManager+BLETransfer.swift can access them.
    var sdkQueue: DispatchQueue { DotManager.shared.sdkQueue }
    let fileQueue = DispatchQueue(label: "ExportManager.fileQueue", qos: .userInitiated)
    private let exportSequenceQueue = DispatchQueue(label: "ExportManager.exportSequenceQueue", qos: .userInitiated)

    // MARK: - Published State

    /// Recording files discovered per dot address.
    @Published private(set) var recordings: [String: [RecordingFile]] = [:]

    /// IDs of files currently selected for export.
    @Published var selectedIDs: Set<String> = []

    /// Items added to the export cart.
    @Published var cartItems: [CartItem] = []

    /// Active export tasks (one per cart item).
    @Published private(set) var tasks: [ExportTask] = []

    /// Current phase of the export flow.
    @Published private(set) var exportPhase: ExportPhase = .idle

    /// True while recording file metadata is being fetched from sensors.
    @Published private(set) var isFetching: Bool = false

    /// True when tasks were rehydrated from disk on launch (not from a live export session).
    @Published private(set) var hasRestoredTasks: Bool = false

    // MARK: - Export State

    // Internal so ExportManager+BLETransfer.swift can access them.
    var currentExportCanceled = false
    var activeWatchdogs: [String: ExportWatchdog] = [:]
    var activeExplorers: [String: DotGATTExplorer] = [:]
    var exportFileGenerations: [String: Int] = [:]
    var isTransferring = false
    let dataTimeoutInterval: TimeInterval = 10.0
    /// Currently open CSV file handles keyed by dot address. Accessed only on `fileQueue`. Closed by cancel if transfer is in progress.
    var activeFileHandles: [String: FileHandle] = [:]

    private var exportSequenceGeneration: Int = 0
    private var currentExportSemaphore: DispatchSemaphore?
    /// How many semaphore signals cancelExport() must send to unblock any pending waits.
    private var exportPendingSignals: Int = 0
    private var cancellables = Set<AnyCancellable>()
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Called on the main thread immediately after each file's BLE transfer succeeds.
    var onTaskCompleted: ((ExportTask) -> Void)?

    // MARK: - App State Handling

    @objc private func appWillResignActive() {
        // bluetooth-central background mode keeps BLE callbacks alive — no action needed.
    }

//    @objc private func appDidEnterBackground() {
//        guard exportPhase == .exporting else { return }
//        // The Movella SDK's export packet callbacks stop firing when the app is backgrounded.
//        // Cancel immediately so tasks show .canceled rather than hanging until the 10s watchdog.
//        cancelExport()
//    }

    // MARK: - Disconnection Pruning

    /// Removes recordings, selections, and cart items for any dot that is no longer connected.
    /// Skipped while exporting so in-flight tasks are not disturbed.
    private func pruneDisconnectedDots(connected: [Dot]) {
        guard exportPhase != .exporting else { return }

        let connectedAddresses = Set(connected.map { $0.address })
        let disconnectedAddresses = Set(recordings.keys).subtracting(connectedAddresses)
        guard !disconnectedAddresses.isEmpty else { return }

        for address in disconnectedAddresses {
            recordings.removeValue(forKey: address)
        }

        let remainingIDs = Set(recordings.values.flatMap { $0 }.map { $0.id })
        selectedIDs = selectedIDs.intersection(remainingIDs)
        cartItems.removeAll { disconnectedAddresses.contains($0.recording.dotAddress) }

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
            dot.getExportFileInfo { [weak self] _ in
                guard let self else { group.leave(); return }

                var result: [RecordingFile] = []
                for (i, file) in dot.recordingFiles.enumerated() {
                    result.append(RecordingFile(
                        dotAddress: dot.address,
                        macAddress: dot.device.macAddress.isEmpty ? "None" : dot.device.macAddress,
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

            // Remove selections and cart items for files that no longer exist on the sensor.
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
        recordings[dotAddress]?.forEach { selectedIDs.insert($0.id) }
    }

    func deselectAll(for dotAddress: String) {
        recordings[dotAddress]?.forEach { selectedIDs.remove($0.id) }
    }

    // MARK: - Cart

    /// Distinct session UUIDs in the order they first appear in cartItems.
    var cartSessions: [UUID] {
        var seen = Set<UUID>()
        return cartItems.compactMap { seen.insert($0.sessionId).inserted ? $0.sessionId : nil }
    }

    /// Move selected files into the cart, auto-grouping by timestamp proximity.
    /// Files recorded within 20 minutes of an existing session are assigned to that session.
    func buildCart() {
        let allFiles = recordings.values.flatMap { $0 }
        let selected = allFiles.filter { selectedIDs.contains($0.id) }
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
        items.first(where: { abs(Int(file.timestamp) - Int($0.recording.timestamp)) <= 1200 })?.sessionId
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

    /// Start exporting all cart items. All devices transfer concurrently.
    func startExport() {
        guard !cartItems.isEmpty, exportPhase != .exporting else { return }

        beginExportBackgroundTask()
        currentExportCanceled = false

        let newTasks = cartItems.map { ExportTask(cartItem: $0) }
        for task in newTasks {
            task.$status
                .filter { $0 == .success || $0 == .failed || $0 == .canceled }
                .sink { [weak self] _ in self?.persistTasks() }
                .store(in: &cancellables)
            task.$uploadStatus
                .filter { $0 == .uploaded || $0 == .failed }
                .sink { [weak self] status in
                    print("📡 uploadStatus changed to \(status) for task \(task.cartItem.label)")
                    self?.persistTasks()
                }
                .store(in: &cancellables)
        }
        setOnMain {
            self.tasks = newTasks
            self.exportPhase = .exporting
        }

        let grouped = Dictionary(grouping: newTasks, by: { $0.cartItem.recording.dotAddress })
        let deviceCount = grouped.count

        exportSequenceGeneration += 1
        let myGen = exportSequenceGeneration
        let semaphore = DispatchSemaphore(value: 0)
        currentExportSemaphore = semaphore
        exportPendingSignals = deviceCount

        // Launch all devices concurrently.
        for address in grouped.keys.sorted() {
            guard let tasksForDot = grouped[address] else {
                semaphore.signal(); continue
            }
            guard let dot = DotManager.shared.dot(forUuid: address), dot.isConnected else {
                tasksForDot.forEach { setTaskStatus($0, .failed, error: "Sensor disconnected") }
                semaphore.signal(); continue
            }
            exportFilesForDot(dot: dot, tasks: tasksForDot) { semaphore.signal() }
        }

        // Wait for all N devices to finish without blocking main.
        exportSequenceQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<deviceCount { semaphore.wait() }
            DispatchQueue.main.async {
                guard self.exportSequenceGeneration == myGen else { return }
                self.exportPendingSignals = 0
                self.exportPhase = .done
                self.sendCompletionNotification()
                self.endExportBackgroundTask()
            }
        }
    }

    /// Cancel the active export.
    func cancelExport() {
        // Bump generation so sequence block completion handlers are no-ops.
        exportSequenceGeneration += 1

        sdkQueue.async {
            for address in Array(self.exportFileGenerations.keys) {
                self.exportFileGenerations[address, default: 0] += 1
            }
            self.currentExportCanceled = true
            self.isTransferring = false
        }

        for watchdog in activeWatchdogs.values { watchdog.stop() }
        activeWatchdogs.removeAll()

        // Close all in-progress file handles (watchdogs won't fire to do it).
        fileQueue.async {
            for handle in self.activeFileHandles.values { try? handle.close() }
            self.activeFileHandles.removeAll()
        }

        for explorer in activeExplorers.values { explorer.stop() }
        activeExplorers.removeAll()

        // Tell any actively-transferring devices to stop.
        let runningAddresses = Set(
            tasks.filter { $0.status == .running && $0.subphase == .transferring }
                .map { $0.cartItem.recording.dotAddress }
        )
        for address in runningAddresses {
            if let dot = DotManager.shared.dot(forUuid: address) {
                sdkQueue.async { dot.device.stopExportFileData() }
            }
        }

        for task in tasks where task.status == .running || task.status == .queued {
            if task.subphase == .transferring {
                let url = csvURL(for: task)
                fileQueue.async { try? FileManager.default.removeItem(at: url) }
            }
            setTaskStatus(task, .canceled)
        }

        // Unblock all pending semaphore waits (one per device in parallel export).
        let pending = exportPendingSignals
        exportPendingSignals = 0
        for _ in 0..<pending { currentExportSemaphore?.signal() }
        currentExportSemaphore = nil

        setOnMain {
            self.exportPhase = .done
            self.sendCompletionNotification()
            self.endExportBackgroundTask()
        }
    }

    /// Re-queue failed/canceled tasks for retry.
    /// If the CSV already exists on disk it is marked done immediately; otherwise the full
    /// BLE pipeline reruns.
    func retryFailed() {
        let retryable = tasks.filter { $0.status == .failed || $0.status == .canceled }
        guard !retryable.isEmpty else { return }

        beginExportBackgroundTask()
        currentExportCanceled = false
        setOnMain { self.exportPhase = .exporting }

        // fullPipeline is written in two phases (see below) and read only after both
        // phases complete, so no lock is needed.
        var fullPipeline: [ExportTask] = []

        // --- Pass 1: tasks without packet loss ------------------------------------------
        // The CSV was never partially written, so disk state is stable. Check existence
        // synchronously on main — no deletion means no race.
        for task in retryable where !task.hasPacketLoss {
            let csv = csvURL(for: task)
            if FileManager.default.fileExists(atPath: csv.path) {
                setOnMain {
                    task.status = .success
                    task.subphase = .complete
                    task.progress = 1.0
                    task.outputURL = csv
                    task.error = nil
                }
            } else {
                fullPipeline.append(task)
                setTaskStatus(task, .queued)
                setOnMain { task.progress = 0; task.error = nil; task.subphase = .idle; task.hasPacketLoss = false }
            }
        }

        // --- Pass 2: tasks with packet loss ---------------------------------------------
        // The partial CSV must be deleted before we can decide whether a re-transfer is
        // needed. Run delete + existence check together inside fileQueue.async so the
        // check always sees the post-deletion state. Never call .sync on fileQueue from
        // the main thread — that deadlocks if fileQueue already has work queued.
        // All Pass-1 appends to fullPipeline are complete before any fileQueue.async
        // block is dispatched, so there is no concurrent write from two threads.
        let packetLossTasks = retryable.filter { $0.hasPacketLoss }
        let group = DispatchGroup()

        for task in packetLossTasks {
            let csv = csvURL(for: task)
            group.enter()
            fileQueue.async { [weak self] in
                guard let self else { group.leave(); return }

                try? FileManager.default.removeItem(at: csv)

                if FileManager.default.fileExists(atPath: csv.path) {
                    // Deletion failed but file is intact — treat as successfully exported.
                    self.setOnMain {
                        task.status = .success
                        task.subphase = .complete
                        task.progress = 1.0
                        task.outputURL = csv
                        task.error = nil
                    }
                } else {
                    // File is gone — needs a full BLE re-transfer.
                    // fileQueue is serial so these appends never race with each other,
                    // and group.notify fires on main only after all blocks call leave().
                    fullPipeline.append(task)
                    self.setTaskStatus(task, .queued)
                    self.setOnMain { task.progress = 0; task.error = nil; task.subphase = .idle; task.hasPacketLoss = false }
                }
                group.leave()
            }
        }

        // --- After all file operations complete, start the BLE pipeline -----------------
        // group.notify fires on main once every fileQueue.async block has left the group
        // (or immediately if packetLossTasks was empty). By that point fullPipeline is
        // fully populated from both passes and safe to read.
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            let grouped = Dictionary(grouping: fullPipeline, by: { $0.cartItem.recording.dotAddress })

            guard !grouped.isEmpty else {
                self.exportPhase = .done
                self.sendCompletionNotification()
                self.endExportBackgroundTask()
                return
            }

            self.exportSequenceGeneration += 1
            let myGen = self.exportSequenceGeneration
            let semaphore = DispatchSemaphore(value: 0)
            self.exportPendingSignals = 1
            self.currentExportSemaphore = semaphore

            self.exportSequenceQueue.async { [weak self] in
                guard let self else { return }

                for (address, tasksForDot) in grouped {
                    guard !self.currentExportCanceled else { break }

                    guard let dot = DotManager.shared.dot(forUuid: address), dot.isConnected else {
                        tasksForDot.forEach { self.setTaskStatus($0, .failed, error: "Sensor disconnected") }
                        continue
                    }

                    self.exportFilesForDot(dot: dot, tasks: tasksForDot) { semaphore.signal() }
                    semaphore.wait()
                }

                DispatchQueue.main.async {
                    guard self.exportSequenceGeneration == myGen else { return }
                    self.exportPhase = .done
                    self.sendCompletionNotification()
                    self.endExportBackgroundTask()
                }
            }
        }
    }

    /// Re-queue a single failed/canceled task for retry.
    /// If the CSV already exists on disk it is marked done immediately; otherwise the full
    /// BLE pipeline reruns for that one task.
    func retrySingleTask(_ task: ExportTask) {
        guard task.status == .failed || task.status == .canceled else { return }

        beginExportBackgroundTask()
        currentExportCanceled = false
        setOnMain { self.exportPhase = .exporting }

        let csv = csvURL(for: task)

        if task.hasPacketLoss {
            // The partial CSV must be deleted before we check whether re-transfer is needed.
            // Run delete + existence check together inside fileQueue.async so the check
            // always sees the post-deletion state (no race). Never .sync from the main
            // thread — that deadlocks if fileQueue already has work queued.
            // After the file op, dispatch back to main to mutate @Published/sequence state,
            // which must remain main-thread-only.
            fileQueue.async { [weak self] in
                guard let self else { return }

                try? FileManager.default.removeItem(at: csv)
                let stillExists = FileManager.default.fileExists(atPath: csv.path)

                DispatchQueue.main.async {
                    if stillExists {
                        // Deletion failed but file is intact — mark done without re-transferring.
                        task.status = .success
                        task.subphase = .complete
                        task.progress = 1.0
                        task.outputURL = csv
                        task.error = nil
                        self.exportPhase = .done
                        self.sendCompletionNotification()
                        self.endExportBackgroundTask()
                    } else {
                        // File is gone — run the full BLE pipeline.
                        // Sequence state mutations happen here on main, matching the contract.
                        self.setTaskStatus(task, .queued)
                        task.progress = 0; task.error = nil; task.subphase = .idle; task.hasPacketLoss = false

                        self.exportSequenceGeneration += 1
                        let myGen = self.exportSequenceGeneration
                        let semaphore = DispatchSemaphore(value: 0)
                        self.exportPendingSignals = 1
                        self.currentExportSemaphore = semaphore

                        self.exportSequenceQueue.async { [weak self] in
                            guard let self else { return }

                            let address = task.cartItem.recording.dotAddress
                            guard !self.currentExportCanceled,
                                  let dot = DotManager.shared.dot(forUuid: address), dot.isConnected else {
                                self.setTaskStatus(task, .failed, error: "Sensor disconnected")
                                DispatchQueue.main.async {
                                    guard self.exportSequenceGeneration == myGen else { return }
                                    self.exportPhase = .done
                                    self.sendCompletionNotification()
                                    self.endExportBackgroundTask()
                                }
                                return
                            }

                            self.exportFilesForDot(dot: dot, tasks: [task]) { semaphore.signal() }
                            semaphore.wait()

                            DispatchQueue.main.async {
                                guard self.exportSequenceGeneration == myGen else { return }
                                self.exportPhase = .done
                                self.sendCompletionNotification()
                                self.endExportBackgroundTask()
                            }
                        }
                    }
                }
            }
        } else {
            // No deletion needed — file state is stable. Synchronous check is safe on
            // main because the file was never touched by a partial transfer.
            if FileManager.default.fileExists(atPath: csv.path) {
                setOnMain {
                    task.status = .success
                    task.subphase = .complete
                    task.progress = 1.0
                    task.outputURL = csv
                    task.error = nil
                }
                DispatchQueue.main.async {
                    self.exportPhase = .done
                    self.sendCompletionNotification()
                    self.endExportBackgroundTask()
                }
                return
            }

            setTaskStatus(task, .queued)
            setOnMain { task.progress = 0; task.error = nil; task.subphase = .idle; task.hasPacketLoss = false }

            exportSequenceGeneration += 1
            let myGen = exportSequenceGeneration
            let semaphore = DispatchSemaphore(value: 0)
            exportPendingSignals = 1
            currentExportSemaphore = semaphore

            exportSequenceQueue.async { [weak self] in
                guard let self else { return }

                let address = task.cartItem.recording.dotAddress
                guard !self.currentExportCanceled,
                      let dot = DotManager.shared.dot(forUuid: address), dot.isConnected else {
                    self.setTaskStatus(task, .failed, error: "Sensor disconnected")
                    DispatchQueue.main.async {
                        guard self.exportSequenceGeneration == myGen else { return }
                        self.exportPhase = .done
                        self.sendCompletionNotification()
                        self.endExportBackgroundTask()
                    }
                    return
                }

                self.exportFilesForDot(dot: dot, tasks: [task]) { semaphore.signal() }
                semaphore.wait()

                DispatchQueue.main.async {
                    guard self.exportSequenceGeneration == myGen else { return }
                    self.exportPhase = .done
                    self.sendCompletionNotification()
                    self.endExportBackgroundTask()
                }
            }
        }
    }

    /// Used by ExportManager+Persistence.swift to restore task state on launch.
    func applyRestoredTasks(_ restored: [ExportTask]) {
        for task in restored where task.uploadStatus == .uploading {
            task.uploadStatus = .pending
        }
        tasks            = restored
        exportPhase      = .done
        hasRestoredTasks = true
    }

    /// Reset state so the user can start a new export.
    func resetExport() {
        clearPersistedTasks()
        tasks.removeAll()
        hasRestoredTasks = false
        exportPhase = recordings.isEmpty ? .idle : .ready
    }

    func dismissRestoredTasksBanner() {
        hasRestoredTasks = false
    }

    // MARK: - Exported File URLs

    /// URLs of all successfully exported CSV files.
    var exportedFileURLs: [URL] {
        tasks.compactMap { $0.outputURL }
    }

    // MARK: - CSV File Path Helpers

    /// Deterministic CSV output path for a task.
    func csvURL(for task: ExportTask) -> URL {
        guard let dir = exportDir() else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(task.id).csv")
        }
        return dir.appendingPathComponent(uniqueStem(for: task) + ".csv")
    }

    /// Stable filename stem: label + last 4 chars of address + file index + short task-id hash.
    private func uniqueStem(for task: ExportTask) -> String {
        let label = sanitize(task.cartItem.label)
        let last4 = String(task.cartItem.recording.dotAddress.suffix(4))
        let fileIndex = task.cartItem.recording.fileIndex
        let idHash = abs(task.id.hashValue) % 100000
        return "\(label)_\(last4)_f\(fileIndex)_\(idHash)"
    }

    func exportDir() -> URL? {
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
        label
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Background Task

    /// Disables the idle timer and registers a UIBackgroundTask so iOS grants extra time
    /// to finish or cleanly cancel an in-progress export if the app is backgrounded.
    private func beginExportBackgroundTask() {
        UIApplication.shared.isIdleTimerDisabled = true
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "BLEExport") {
            // Expiration handler — iOS is forcing us to stop.
            self.cancelExport()
            self.endExportBackgroundTask()
        }
    }

    /// Fires a local notification summarising the export result.
    /// Assumes notification authorization was already requested at app launch.
    func sendCompletionNotification() {
        let succeeded = tasks.filter { $0.status == .success }.count
        let failed = tasks.filter { $0.status == .failed || $0.status == .canceled }.count
        let content = UNMutableNotificationContent()
        content.title = "Export Complete"
        content.body = failed > 0
            ? "\(succeeded) file\(succeeded == 1 ? "" : "s") succeeded, \(failed) failed"
            : "\(succeeded) file\(succeeded == 1 ? "" : "s") exported successfully"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Re-enables the idle timer and ends the UIBackgroundTask. Safe to call multiple times.
    func endExportBackgroundTask() {
        UIApplication.shared.isIdleTimerDisabled = false
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    // MARK: - Helpers

    func setOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    func setTaskStatus(_ task: ExportTask, _ status: ExportStatus, error: String? = nil) {
        setOnMain {
            task.status = status
            if let error { task.error = error }
        }
    }
}
