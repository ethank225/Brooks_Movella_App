import Foundation
import UIKit
import UserNotifications
import MovellaDotSdk
import Combine

// MARK: - Session Metadata

/// Metadata captured from the CartView before export starts.
/// Written into `metadata.csv` inside each session folder.
struct SessionMetadata: Codable {
    let runnerName: String
    let shoeBrand: String
    let shoeModel: String
    let shoeGeneration: String
    let conditionType: String
    let study: String
    let test: String
    let product: String
    let outputRate: Int
    let filterIndex: Int
}

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
        cleanupSharePackages()

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

    /// File IDs currently in the cart. Single source of truth for cart membership checks.
    var cartFileIds: Set<String> { Set(cartItems.map { $0.id }) }

    /// Session-grouped recordings, organized by runner (researcher mode) or as a single group.
    @Published var runnerGroups: [RunnerRecordingGroup] = []

    /// Per-session type (run, calibration, etc.). Sessions not in the dict default to `.run`.
    @Published var sessionTypes: [UUID: SessionType] = [:]

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

    // MARK: - Session Folder State

    /// Metadata for the current export session, set by CartView before calling startExport().
    var sessionMetadata: SessionMetadata?

    /// Session folder URLs from the most recent export. Populated after organizeIntoSessionFolders().
    /// Used by the share sheet's packageForSharing(). Not persisted — session folders in
    /// Documents/Exports/ are permanent user data managed via the Files app.
    var exportedSessionFolderURLs: [URL] = []

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
        guard !DotManager.shared.isBusy else { return }
        guard !DotManager.shared.isErasing else { return }
        setOnMain {
            self.isFetching = true
            self.exportPhase = .fetching
            self.recordings = [:]
        }

        let group = DispatchGroup()

        for dot in dots {
            guard dot.connectionPhase == .ready, dot.isInitialized else { continue }

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
            self.rebuildSessionGroups()
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

        var newItems: [CartItem] = []
        for file in selected
                .filter({ !cartFileIds.contains($0.id) })
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
        pruneOrphanedSessionTypes()
    }

    func removeFromCart(fileId: String) {
        cartItems.removeAll { $0.id == fileId }
        pruneOrphanedSessionTypes()
    }

    func removeFromCart(fileIds: Set<String>) {
        cartItems.removeAll { fileIds.contains($0.id) }
        pruneOrphanedSessionTypes()
    }

    /// Remove session type entries for sessions that no longer have any cart items.
    private func pruneOrphanedSessionTypes() {
        let activeSessionIds = Set(cartItems.map { $0.sessionId })
        sessionTypes = sessionTypes.filter { activeSessionIds.contains($0.key) }
    }

    func clearCart() {
        cartItems.removeAll()
        sessionTypes.removeAll()
    }

    // MARK: - Session Type

    func sessionType(for sessionId: UUID) -> SessionType {
        sessionTypes[sessionId] ?? .run
    }

    func setSessionType(_ type: SessionType, for sessionId: UUID) {
        if type == .run {
            sessionTypes.removeValue(forKey: sessionId)
        } else {
            sessionTypes[sessionId] = type
        }
    }

    func cycleSessionType(for sessionId: UUID) {
        let current = sessionType(for: sessionId)
        let all = SessionType.allCases
        let nextIdx = (all.firstIndex(of: current)! + 1) % all.count
        setSessionType(all[nextIdx], for: sessionId)
    }

    /// Add files to the cart using pre-computed session IDs from the session-grouped browser.
    /// Each entry maps a `RecordingSession.id` to the file IDs that should be added from it.
    func addToCart(fromSessions sessionFileIds: [(sessionId: UUID, fileIds: Set<String>)]) {
        let allFiles = recordings.values.flatMap { $0 }
        let fileMap = Dictionary(uniqueKeysWithValues: allFiles.map { ($0.id, $0) })
        let existing = cartFileIds

        var newItems: [CartItem] = []
        for (sessionId, fileIds) in sessionFileIds {
            for fileId in fileIds {
                guard !existing.contains(fileId),
                      let file = fileMap[fileId] else { continue }
                var item = CartItem(recording: file)
                item.sessionId = sessionId
                newItems.append(item)
            }
        }

        cartItems.append(contentsOf: newItems)
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
        guard !DotManager.shared.isBusy else { return }

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
            guard let dot = DotManager.shared.dot(forUuid: address),
                  dot.connectionPhase == .ready else {
                tasksForDot.forEach { setTaskStatus($0, .failed, error: "Sensor not ready") }
                semaphore.signal(); continue
            }
            exportFilesForDot(dot: dot, tasks: tasksForDot) { semaphore.signal() }
        }

        // Wait for all N devices to finish without blocking main.
        exportSequenceQueue.async { [weak self] in
            guard let self else { return }
            for i in 0..<deviceCount {
                let result = semaphore.wait(timeout: .now() + 300)
                if result == .timedOut {
                    print("⚠️ Export semaphore timed out after 5 minutes (device \(i + 1)/\(deviceCount))")
                    break
                }
            }
            DispatchQueue.main.async {
                self.exportPendingSignals = 0
            }
            self.finalizeExport(generation: myGen)
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
            setOnMain { self.isTransferring = false }
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

        // Snapshot on main, then organize on fileQueue after pending close/delete ops.
        let snapshot = snapshotSuccessTasks()
        let metadata = sessionMetadata
        fileQueue.async { [weak self] in
            guard let self else { return }
            if let metadata, !snapshot.isEmpty {
                self.organizeIntoSessionFolders(snapshot: snapshot, metadata: metadata)
            }
            DispatchQueue.main.async {
                self.exportPhase = .done
                self.persistTasks()
                self.sendCompletionNotification()
                self.endExportBackgroundTask()
            }
        }
    }

    /// Re-queue failed/canceled tasks for retry.
    /// If the CSV already exists on disk it is marked done immediately; otherwise the full
    /// BLE pipeline reruns.
    func retryFailed() {
        let retryable = tasks.filter { $0.status == .failed || $0.status == .canceled }
        guard !retryable.isEmpty else { return }
        guard exportPhase != .exporting else { return }
        guard !DotManager.shared.isBusy else { return }

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
                    setOnMain {
                        task.status = .success
                        task.subphase = .complete
                        task.progress = 1.0
                        task.outputURL = csv
                        task.error = nil
                    }
                } else {
                    // File is gone — needs a full BLE re-transfer.
                    fullPipeline.append(task)
                    self.setTaskStatus(task, .queued)
                    setOnMain { task.progress = 0; task.error = nil; task.subphase = .idle; task.hasPacketLoss = false }
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
                let snapshot = self.snapshotSuccessTasks()
                let metadata = self.sessionMetadata
                self.fileQueue.async {
                    if let metadata, !snapshot.isEmpty {
                        self.organizeIntoSessionFolders(snapshot: snapshot, metadata: metadata)
                    }
                    DispatchQueue.main.async {
                        self.exportPhase = .done
                        self.persistTasks()
                        self.sendCompletionNotification()
                        self.endExportBackgroundTask()
                    }
                }
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

                    guard let dot = DotManager.shared.dot(forUuid: address), dot.connectionPhase == .ready else {
                        tasksForDot.forEach { self.setTaskStatus($0, .failed, error: "Sensor not ready") }
                        continue
                    }

                    self.exportFilesForDot(dot: dot, tasks: tasksForDot) { semaphore.signal() }
                    let result = semaphore.wait(timeout: .now() + 300)
                    if result == .timedOut {
                        print("⚠️ Export retry semaphore timed out after 5 minutes for \(address)")
                        tasksForDot.forEach { self.setTaskStatus($0, .failed, error: "Export timed out") }
                        break
                    }
                }

                self.finalizeExport(generation: myGen)
            }
        }
    }

    /// Re-queue a single failed/canceled task for retry.
    /// If the CSV already exists on disk it is marked done immediately; otherwise the full
    /// BLE pipeline reruns for that one task.
    func retrySingleTask(_ task: ExportTask) {
        guard task.status == .failed || task.status == .canceled else { return }
        guard exportPhase != .exporting else { return }

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
                        let snapshot = self.snapshotSuccessTasks()
                        let metadata = self.sessionMetadata
                        self.fileQueue.async {
                            if let metadata, !snapshot.isEmpty {
                                self.organizeIntoSessionFolders(snapshot: snapshot, metadata: metadata)
                            }
                            DispatchQueue.main.async {
                                self.exportPhase = .done
                                self.persistTasks()
                                self.sendCompletionNotification()
                                self.endExportBackgroundTask()
                            }
                        }
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
                                  let dot = DotManager.shared.dot(forUuid: address), dot.connectionPhase == .ready else {
                                self.setTaskStatus(task, .failed, error: "Sensor not ready")
                                self.finalizeExport(generation: myGen)
                                return
                            }

                            self.exportFilesForDot(dot: dot, tasks: [task]) { semaphore.signal() }
                            let result = semaphore.wait(timeout: .now() + 300)
                            if result == .timedOut {
                                print("⚠️ Single-task retry semaphore timed out after 5 minutes for \(task.cartItem.recording.dotAddress)")
                                self.setTaskStatus(task, .failed, error: "Export timed out")
                            }

                            self.finalizeExport(generation: myGen)
                        }
                    }
                }
            }
        } else {
            // No deletion needed — file state is stable. Synchronous check is safe on
            // main because the file was never touched by a partial transfer.
            if FileManager.default.fileExists(atPath: csv.path) {
                task.status = .success
                task.subphase = .complete
                task.progress = 1.0
                task.outputURL = csv
                task.error = nil
                let snapshot = snapshotSuccessTasks()
                let metadata = sessionMetadata
                fileQueue.async { [weak self] in
                    guard let self else { return }
                    if let metadata, !snapshot.isEmpty {
                        self.organizeIntoSessionFolders(snapshot: snapshot, metadata: metadata)
                    }
                    DispatchQueue.main.async {
                        self.exportPhase = .done
                        self.persistTasks()
                        self.sendCompletionNotification()
                        self.endExportBackgroundTask()
                    }
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
                      let dot = DotManager.shared.dot(forUuid: address), dot.connectionPhase == .ready else {
                    self.setTaskStatus(task, .failed, error: "Sensor not ready")
                    self.finalizeExport(generation: myGen)
                    return
                }

                self.exportFilesForDot(dot: dot, tasks: [task]) { semaphore.signal() }
                let result = semaphore.wait(timeout: .now() + 300)
                if result == .timedOut {
                    print("⚠️ Single-task retry semaphore timed out after 5 minutes for \(task.cartItem.recording.dotAddress)")
                    self.setTaskStatus(task, .failed, error: "Export timed out")
                }

                self.finalizeExport(generation: myGen)
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
        exportedSessionFolderURLs.removeAll()
        sessionMetadata = nil
        sessionTypes.removeAll()
        hasRestoredTasks = false
        exportPhase = recordings.isEmpty ? .idle : .ready
        cleanupSharePackages()
        // Clean up flat CSVs that were copied into session folders.
        fileQueue.async { self.cleanupFlatExportFiles() }
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

    /// Flat CSV cache directory (hidden from Files app). BLE transfers write here.
    func exportDir() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("ExportCache", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            print("❌ Failed to create ExportCache directory: \(error)")
            return nil
        }
    }

    /// Session folder directory (visible in Files app). Only clean session folders live here.
    func sessionExportDir() -> URL? {
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

    // MARK: - Session Folder Organization

    private static let sessionFolderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.timeZone = .current
        return f
    }()

    /// Snapshot of task data captured on the main thread for thread-safe file operations.
    struct TaskMoveInfo {
        let sourceURL: URL
        let sessionId: UUID
        let label: String
        let dotAddress: String
        let fileIndex: Int
        let timestamp: UInt32
        let taskId: String
        let sessionType: SessionType
    }

    /// Snapshots successful task data on the main thread. Must be called on main.
    func snapshotSuccessTasks() -> [TaskMoveInfo] {
        tasks.compactMap { task in
            guard task.status == .success, let url = task.outputURL else { return nil }
            return TaskMoveInfo(
                sourceURL: url,
                sessionId: task.cartItem.sessionId,
                label: task.cartItem.label,
                dotAddress: task.cartItem.recording.dotAddress,
                fileIndex: task.cartItem.recording.fileIndex,
                timestamp: task.cartItem.recording.timestamp,
                taskId: task.id,
                sessionType: sessionType(for: task.cartItem.sessionId)
            )
        }
    }

    /// Groups successful tasks into timestamped session folders with metadata.csv.
    /// Must be called on `fileQueue` with pre-snapshotted task data.
    func organizeIntoSessionFolders(snapshot: [TaskMoveInfo], metadata: SessionMetadata) {
        guard let baseDir = sessionExportDir() else { return }
        guard !snapshot.isEmpty else { return }

        let grouped = Dictionary(grouping: snapshot) { $0.sessionId }
        var folderURLs: [URL] = []

        for (sessionId, sessionItems) in grouped {
            let earliest = sessionItems
                .map { $0.timestamp }
                .min() ?? UInt32(Date().timeIntervalSince1970)
            let date = Date(timeIntervalSince1970: TimeInterval(earliest))
            let sType = sessionItems.first?.sessionType ?? .run
            let folderName = Self.sessionFolderFormatter.string(from: date) + sType.suffix

            // Reuse existing folder if its metadata.csv has the same Session ID (retry case).
            let sessionDir = resolveSessionFolder(baseName: folderName, sessionId: sessionId, in: baseDir)

            do {
                try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            } catch {
                print("Failed to create session folder: \(error)")
                continue
            }

            writeMetadataCSV(to: sessionDir, metadata: metadata, items: sessionItems, sessionId: sessionId, sessionType: sType)

            for item in sessionItems {
                let preferredName = sanitize(item.label) + sType.suffix + ".csv"
                safeCopy(from: item.sourceURL, toDirectory: sessionDir, preferredName: preferredName, taskId: item.taskId)
            }

            folderURLs.append(sessionDir)
        }

        setOnMain { self.exportedSessionFolderURLs = folderURLs }
    }

    /// Copies a file into a directory with collision checking.
    /// The original stays in place for uploads; cleaned up later via `cleanupFlatExportFiles()`.
    @discardableResult
    private func safeCopy(from source: URL, toDirectory dir: URL, preferredName: String, taskId: String) -> URL? {
        let fm = FileManager.default
        var targetURL = dir.appendingPathComponent(preferredName)

        if fm.fileExists(atPath: targetURL.path) {
            let stem = preferredName.replacingOccurrences(of: ".csv", with: "")
            let suffix = String(taskId.prefix(6))
            targetURL = dir.appendingPathComponent("\(stem)_\(suffix).csv")
        }

        do {
            try fm.copyItem(at: source, to: targetURL)
            return targetURL
        } catch {
            print("Failed to copy \(source.lastPathComponent) -> \(targetURL.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - Share Packaging

    /// Assembles all session folders into a single shareable bundle in tmp/.
    /// Returns the top-level folder URL (e.g. `tmp/BrooksExport_2026-03-22/`).
    func packageForSharing() -> URL? {
        let fm = FileManager.default
        guard !exportedSessionFolderURLs.isEmpty else { return nil }

        let dateStr = Self.shareDateFormatter.string(from: Date())
        let packageDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrooksExport_\(dateStr)", isDirectory: true)

        // Remove any stale package at this path.
        try? fm.removeItem(at: packageDir)

        do {
            try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create share package: \(error)")
            return nil
        }

        for folderURL in exportedSessionFolderURLs {
            let dest = packageDir.appendingPathComponent(folderURL.lastPathComponent, isDirectory: true)
            do {
                try fm.copyItem(at: folderURL, to: dest)
            } catch {
                print("Failed to copy session folder \(folderURL.lastPathComponent): \(error)")
            }
        }

        return packageDir
    }

    private static let shareDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// Removes any BrooksExport_* directories from the tmp directory.
    func cleanupSharePackages() {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let items = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("BrooksExport_") {
            try? fm.removeItem(at: item)
        }
    }

    /// Deletes flat CSV files in the Exports/ root that have been copied into session folders.
    /// Safe to call after all uploads complete. Must be called on `fileQueue`.
    func cleanupFlatExportFiles() {
        guard let dir = exportDir() else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.pathExtension == "csv" {
            try? fm.removeItem(at: item)
        }
    }

    /// Writes a metadata.csv file summarizing the export session.
    private func writeMetadataCSV(to dir: URL, metadata: SessionMetadata, items: [TaskMoveInfo], sessionId: UUID, sessionType: SessionType = .run) {
        var rows: [[String]] = []
        rows.append(["Key", "Value"])
        rows.append(["Session ID", sessionId.uuidString])
        rows.append(["Session Type", sessionType.rawValue])
        rows.append(["Runner Name", metadata.runnerName])
        rows.append(["Shoe Brand", metadata.shoeBrand])
        rows.append(["Shoe Model", metadata.shoeModel])
        rows.append(["Shoe Generation", metadata.shoeGeneration])
        rows.append(["Condition Type", metadata.conditionType])
        rows.append(["Study", metadata.study])
        rows.append(["Test", metadata.test])
        rows.append(["Product", metadata.product])
        rows.append(["Output Rate (Hz)", "\(metadata.outputRate)"])
        rows.append(["Filter Profile", "\(metadata.filterIndex)"])

        let sensorAddresses = Set(items.map { $0.dotAddress })
        for address in sensorAddresses.sorted() {
            let name = SensorNameStore.shared.names[address] ?? address
            rows.append(["Sensor", "\(name) (\(address))"])
        }

        let isoFormatter = ISO8601DateFormatter()
        for item in items.sorted(by: { $0.fileIndex < $1.fileIndex }) {
            let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp))
            rows.append(["Recording (\(item.label))", isoFormatter.string(from: date), sessionType.rawValue])
        }

        let csv = rows.map { row in
            row.map { field in
                // Escape fields containing commas or quotes.
                if field.contains(",") || field.contains("\"") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"

        let url = dir.appendingPathComponent("metadata.csv")
        try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Reads the Session ID value from a metadata.csv inside the given folder.
    /// Returns nil if the file doesn't exist, can't be read, or has no Session ID row.
    private func readSessionId(from folderURL: URL) -> String? {
        let metadataURL = folderURL.appendingPathComponent("metadata.csv")
        guard let contents = try? String(contentsOf: metadataURL, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: "\n") {
            let cols = line.components(separatedBy: ",")
            if cols.count >= 2, cols[0] == "Session ID" {
                return cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Resolves a session folder path, reusing an existing folder if its metadata.csv
    /// contains the same Session ID (retry case). Otherwise picks the first available suffix.
    private func resolveSessionFolder(baseName: String, sessionId: UUID, in baseDir: URL) -> URL {
        let fm = FileManager.default
        let sessionIdString = sessionId.uuidString

        let candidate = baseDir.appendingPathComponent(baseName, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        if readSessionId(from: candidate) == sessionIdString { return candidate }

        var suffix = 1
        while suffix <= 100 {
            let suffixed = baseDir.appendingPathComponent("\(baseName)_\(suffix)", isDirectory: true)
            if !fm.fileExists(atPath: suffixed.path) { return suffixed }
            if readSessionId(from: suffixed) == sessionIdString { return suffixed }
            suffix += 1
        }
        return baseDir.appendingPathComponent("\(baseName)_\(suffix)", isDirectory: true)
    }

    /// Snapshots task data on main, organizes into session folders on `fileQueue`,
    /// then transitions to `.done` on main.
    private func finalizeExport(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.exportSequenceGeneration == generation else { return }

            // Snapshot @Published task data on main thread.
            let snapshot = self.snapshotSuccessTasks()
            let metadata = self.sessionMetadata

            self.fileQueue.async {
                if let metadata, !snapshot.isEmpty {
                    self.organizeIntoSessionFolders(snapshot: snapshot, metadata: metadata)
                }
                DispatchQueue.main.async {
                    guard self.exportSequenceGeneration == generation else { return }
                    self.exportPhase = .done
                    self.persistTasks()
                    self.sendCompletionNotification()
                    self.endExportBackgroundTask()
                }
            }
        }
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


    func setTaskStatus(_ task: ExportTask, _ status: ExportStatus, error: String? = nil) {
        setOnMain {
            task.status = status
            if let error { task.error = error }
        }
    }
}

// MARK: - Testable Decision Logic

/// Lightweight snapshot of a task's retry-relevant state.
/// Avoids coupling test code to `ExportTask` (which wraps SDK objects).
struct ExportTaskSnapshot {
    let hasPacketLoss: Bool
    let fileExists: Bool
}

/// What action to take for a single task during retry.
enum RetryAction: Equatable {
    case markSuccess
    case addToPipeline
    case deleteAndRecheck
}

/// Extracted pure functions for unit testing retry logic without Bluetooth.
/// Each function mirrors a decision point inside ExportManager but takes
/// value-type inputs and returns value-type outputs — no SDK, no queues.
enum ExportManagerLogic {

    /// Validates whether a retry operation can start.
    /// Returns `nil` on success, or an error message describing why it's blocked.
    static func validateRetry(
        exportPhase: ExportPhase,
        isBusy: Bool,
        retryableCount: Int
    ) -> String? {
        guard retryableCount > 0 else { return "No retryable tasks" }
        guard exportPhase != .exporting else { return "Export already in progress" }
        guard !isBusy else { return "System busy" }
        return nil
    }

    /// Decides what to do with a single failed task based on its state.
    /// - No packet loss + file exists → markSuccess (already exported)
    /// - No packet loss + file missing → addToPipeline (needs BLE re-transfer)
    /// - Packet loss → deleteAndRecheck (delete partial CSV first, then decide)
    static func triageTask(_ snapshot: ExportTaskSnapshot) -> RetryAction {
        if snapshot.hasPacketLoss { return .deleteAndRecheck }
        return snapshot.fileExists ? .markSuccess : .addToPipeline
    }

    /// After attempting to delete a packet-loss CSV, decides the next step.
    /// - File still exists (deletion failed) → markSuccess
    /// - File gone → addToPipeline (needs full BLE re-transfer)
    static func triageAfterDeletion(fileStillExists: Bool) -> RetryAction {
        fileStillExists ? .markSuccess : .addToPipeline
    }

    /// Validates whether a dot is usable for retry export.
    /// Returns `nil` on success, or an error message.
    static func validateDotForRetry(dotExists: Bool, dotReady: Bool) -> String? {
        guard dotExists, dotReady else { return "Sensor not ready" }
        return nil
    }
}
