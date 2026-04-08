import SwiftUI

struct ExportView: View {
    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var exportManager = ExportManager.shared

    @State private var showCart = false
    @State private var showInitializingAlert = false
    @State private var localGroups: [RunnerRecordingGroup]?  // mutable copy for reassignment
    @State private var selectedFileIds: Set<String> = []

    private var connectedDots: [Dot] { manager.connectedDots }
    private var readyDots: [Dot] { connectedDots.filter { $0.connectionPhase == .ready } }
    private var hasInitializingSensors: Bool {
        connectedDots.contains { $0.connectionPhase != .ready }
    }
    private var cartCount: Int { exportManager.cartItems.count }
    private var isBusy: Bool { manager.isBusy }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        if exportManager.hasRestoredTasks {
                            RestoredTasksBanner(exportManager: exportManager) {
                                showCart = true
                            }
                            .padding(.horizontal)
                        }
                        recordingsContent
                        Spacer()
                    }
                    .padding(.top)
                }
                .refreshable {
                    guard !isBusy else { return }
                    if hasInitializingSensors {
                        showInitializingAlert = true
                    } else {
                        exportManager.fetchRecordings(for: connectedDots)
                    }
                }

                bottomBar
            }
            .alert("Sensors Initializing", isPresented: $showInitializingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Some sensors are still initializing. Please wait until all sensors are ready.")
            }
            .onAppear {
                // Re-open cart sheet if export was in progress/done when app was backgrounded.
                if (exportManager.exportPhase == .exporting || exportManager.exportPhase == .done)
                    && !exportManager.tasks.isEmpty
                    && UserDefaults.standard.data(forKey: "activeExportContext") != nil {
                    showCart = true
                }

                // Auto-refresh recordings whenever the Export tab becomes visible,
                // but only when it's safe: sensors connected, not mid-export, not
                // in the post-export done state (user may be about to share).
                let safeToRefresh = !readyDots.isEmpty
                    && !isBusy
                    && exportManager.exportPhase != .exporting
                    && exportManager.exportPhase != .done
                    && !manager.isErasing
                    && !manager.hasFlashIssue
                if safeToRefresh {
                    exportManager.fetchRecordings(for: readyDots)
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    CartBadgeButton(count: cartCount) { showCart = true }
                }
            }
            .sheet(isPresented: $showCart) {
                CartView()
            }
            .onChange(of: exportManager.isFetching) { fetching in
                if fetching {
                    localGroups = nil
                    selectedFileIds = []
                }
            }
        }
    }

    // MARK: - Cart Helpers

    private func addSelectedToCart() {
        let groups = localGroups ?? exportManager.runnerGroups
        let addable = selectedFileIds.subtracting(exportManager.cartFileIds)
        guard !addable.isEmpty else { return }

        var entries: [(sessionId: UUID, fileIds: Set<String>)] = []
        for group in groups {
            for session in group.sessions {
                let ids = Set(session.files.map { $0.id }).intersection(addable)
                if !ids.isEmpty {
                    entries.append((sessionId: session.id, fileIds: ids))
                }
            }
        }
        exportManager.addToCart(fromSessions: entries)
        selectedFileIds.removeAll()
    }

    private func addToCart(session: RecordingSession, fileIds: Set<String>) {
        let toAdd = fileIds.subtracting(exportManager.cartFileIds)
        guard !toAdd.isEmpty else { return }
        exportManager.addToCart(fromSessions: [(sessionId: session.id, fileIds: toAdd)])
    }

    private func removeSession(_ session: RecordingSession) {
        let ids = Set(session.files.map { $0.id })
        exportManager.removeFromCart(fileIds: ids)
    }

    private func formattedBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
        return "\(bytes) B"
    }

    private func moveFile(_ file: RecordingSession.SessionFile, to destinationSessionId: UUID?, in group: RunnerRecordingGroup) {
        // Lazily snapshot into localGroups on first reassignment.
        if localGroups == nil {
            localGroups = exportManager.runnerGroups
        }
        guard var groups = localGroups else { return }
        guard let groupIdx = groups.firstIndex(where: { $0.id == group.id }) else { return }

        // Extract sessions, mutate, then rebuild the group.
        var sessions = groups[groupIdx].sessions

        // Remove from source session.
        for sIdx in sessions.indices {
            sessions[sIdx].files.removeAll { $0.id == file.id }
        }
        // Remove empty sessions.
        sessions.removeAll { $0.files.isEmpty }

        if let destId = destinationSessionId,
           let sIdx = sessions.firstIndex(where: { $0.id == destId }) {
            sessions[sIdx].files.append(file)
        } else {
            let newSession = RecordingSession(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(file.recording.timestamp)),
                files: [file],
                expectedSensorCount: sessions.first?.expectedSensorCount ?? 1
            )
            sessions.insert(newSession, at: 0)
        }

        groups[groupIdx] = RunnerRecordingGroup(
            id: groups[groupIdx].id,
            runnerName: groups[groupIdx].runnerName,
            dotNames: groups[groupIdx].dotNames,
            sessions: sessions
        )

        localGroups = groups
    }

    @ViewBuilder
    private var recordingsContent: some View {
        if isBusy {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                    Text("Stop all recordings before exporting.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            }
        } else if connectedDots.isEmpty {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                EmptyStateView(
                    icon: "sensor.tag.radiowaves.forward",
                    headline: "No sensors connected",
                    subheadline: "Connect sensors in the Connect tab to view recordings"
                )
            }
        } else if manager.isErasing || manager.hasFlashIssue {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                if manager.isErasing {
                    ErasingBanner()
                } else {
                    FlashIssueBanner(isErasingFromPreviousSession: manager.isAnyErasingFromPreviousSession)
                }
            }
        } else if exportManager.exportPhase == .idle {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                FullWidthButton(icon: "arrow.down.doc", label: "Fetch Recordings", color: .blue) {
                    if hasInitializingSensors {
                        showInitializingAlert = true
                    } else {
                        exportManager.fetchRecordings(for: connectedDots)
                    }
                }
            }
        } else if exportManager.isFetching {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                    Text("Fetching recordings...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            }
        } else {
            sessionGroupedContent
                .contentLoadAnimation()
        }
    }

    @ViewBuilder
    private var sessionGroupedContent: some View {
        let groups = localGroups ?? exportManager.runnerGroups
        let totalFiles = groups.flatMap { $0.sessions.flatMap { $0.files } }.count
        let cartIds = exportManager.cartFileIds

        if totalFiles == 0 {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                EmptyStateView(
                    icon: "doc.on.doc",
                    headline: "No recordings found",
                    subheadline: "Record data on the Record tab, then come back here to export"
                )
            }
        } else if groups.count == 1, let group = groups.first {
            // Single runner mode — show sessions directly.
            SectionCard(
                title: "\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s") · \(totalFiles) file\(totalFiles == 1 ? "" : "s") on device",
                icon: "doc.on.doc"
            ) {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionCard(
                        session: session,
                        sessionNumber: index + 1,
                        sessionType: exportManager.sessionType(for: session.id),
                        cartItemIds: cartIds,
                        allSessions: group.sessions,
                        onAddToCart: { sess, fileIds in addToCart(session: sess, fileIds: fileIds) },
                        onRemoveSession: { removeSession($0) },
                        onToggleSessionType: { exportManager.cycleSessionType(for: $0.id) },
                        onMoveFile: { file, destination in
                            moveFile(file, to: destination, in: group)
                        },
                        selectedFileIds: $selectedFileIds
                    )
                }
            }
        } else {
            // Multi-runner mode — show runner sections.
            ForEach(groups) { group in
                RunnerRecordingSection(
                    group: group,
                    cartItemIds: cartIds,
                    sessionTypes: exportManager.sessionTypes,
                    onAddToCart: { sess, fileIds in addToCart(session: sess, fileIds: fileIds) },
                    onRemoveSession: { removeSession($0) },
                    onToggleSessionType: { exportManager.cycleSessionType(for: $0.id) },
                    onMoveFile: { file, destination, grp in
                        moveFile(file, to: destination, in: grp)
                    },
                    selectedFileIds: $selectedFileIds
                )
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        let addable = selectedFileIds.subtracting(exportManager.cartFileIds)
        let cartCount = exportManager.cartItems.count

        if exportManager.exportPhase == .ready {
            VStack(spacing: 0) {
                Divider()

                if !addable.isEmpty {
                    // Selection mode — "Add N to cart"
                    FullWidthButton(
                        icon: "cart.badge.plus",
                        label: "Add \(addable.count) to Cart",
                        color: .purple
                    ) {
                        addSelectedToCart()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                } else if cartCount > 0 {
                    // Cart summary + export button
                    let sessions = exportManager.cartSessions
                    let grouped = Dictionary(grouping: exportManager.cartItems) { $0.sessionId }
                    let runSessions = sessions.filter { exportManager.sessionType(for: $0) == .run }
                    let calSessions = sessions.filter { exportManager.sessionType(for: $0) == .calibration }
                    let runFiles = runSessions.flatMap { grouped[$0] ?? [] }.count
                    let calFiles = calSessions.flatMap { grouped[$0] ?? [] }.count
                    let runBytes = runSessions.flatMap { grouped[$0] ?? [] }.reduce(0) { $0 + $1.recording.fileSize }
                    let calBytes = calSessions.flatMap { grouped[$0] ?? [] }.reduce(0) { $0 + $1.recording.fileSize }

                    VStack(spacing: 6) {
                        VStack(spacing: 2) {
                            if !runSessions.isEmpty {
                                HStack {
                                    Text("\(runSessions.count) run (\(runFiles) file\(runFiles == 1 ? "" : "s"))")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Spacer()
                                    Text(formattedBytes(runBytes))
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            if !calSessions.isEmpty {
                                HStack {
                                    Text("\(calSessions.count) calibration (\(calFiles) file\(calFiles == 1 ? "" : "s"))")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Text(formattedBytes(calBytes))
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .padding(.horizontal)

                        Button {
                            showCart = true
                        } label: {
                            Text("Export \(cartCount) file\(cartCount == 1 ? "" : "s")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.green.opacity(0.7))
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 8)
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .animation(AppAnimation.content, value: addable.isEmpty)
            .animation(AppAnimation.content, value: cartCount)
        }
    }
}

private struct CartBadgeButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "cart")
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Cart View

struct CartView: View {

    private struct ExportContext: Codable {
        let profileId: UUID
        let dbSessionMap: [String: UUID]   // UUID keys as strings; [UUID:UUID] is not JSONEncoder-safe
        let shoeBrand: String
        let shoeModel: String
        let shoeGeneration: String
        let conditionTags: [String]
        let study: String
        let test: String
        let product: String
        let sessionMetadata: SessionMetadata?
        let sessionTypes: [String: SessionType]?  // UUID string → SessionType
    }

    @ObservedObject private var exportManager   = ExportManager.shared
    @ObservedObject private var supabaseManager = SupabaseManager.shared
    @ObservedObject private var dotManager      = DotManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showCloseBlockedAlert = false
    @State private var showInitializingAlert = false
    @State private var dbSessionMap: [UUID: UUID] = [:]

    // Run Details state
    @State private var selectedProfile: Profile?
    @State private var selectedTemplate: WorkoutTemplate?
    @State private var shoeBrand      = ""
    @State private var shoeModel      = ""
    @State private var shoeGeneration = ""
    @State private var conditionTags: [String] = []
    private var conditionType: String { conditionTags.joined(separator: ",") }
    @State private var study          = ""
    @State private var test           = ""
    @State private var product        = ""

    private var isExporting: Bool { exportManager.exportPhase == .exporting }
    private var isDone: Bool { exportManager.exportPhase == .done }

    private var emptyMetadataFields: [String] {
        var missing: [String] = []
        if shoeBrand.trimmingCharacters(in: .whitespaces).isEmpty      { missing.append("Shoe Brand") }
        if shoeModel.trimmingCharacters(in: .whitespaces).isEmpty      { missing.append("Shoe Model") }
        if shoeGeneration.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("Shoe Generation") }
        if conditionTags.isEmpty                                         { missing.append("Condition Type") }
        if study.trimmingCharacters(in: .whitespaces).isEmpty          { missing.append("Study") }
        if test.trimmingCharacters(in: .whitespaces).isEmpty           { missing.append("Test") }
        if product.trimmingCharacters(in: .whitespaces).isEmpty        { missing.append("Product") }
        return missing
    }

    private var hasInitializingSensors: Bool {
        let cartAddresses = Set(exportManager.cartItems.map { $0.recording.dotAddress })
        return cartAddresses.contains { address in
            dotManager.dot(forUuid: address)?.connectionPhase != .ready
        }
    }

    private var isBusy: Bool { dotManager.isBusy }

    private var canExport: Bool {
        !exportManager.cartItems.isEmpty && selectedProfile != nil && emptyMetadataFields.isEmpty && !isBusy && !dotManager.isErasing && !dotManager.hasFlashIssue
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if exportManager.cartItems.isEmpty && exportManager.tasks.isEmpty {
                        SectionCard(title: "Cart", icon: "cart") {
                            EmptyStateView(
                                icon: "cart",
                                headline: "Cart is empty",
                                subheadline: "Select recordings from the Export tab to add them here"
                            )
                        }
                    } else if !isDone || exportManager.tasks.isEmpty {
                        cartItemsSection

                        if !isExporting {
                            RunDetailsSection(
                                selectedProfile: $selectedProfile,
                                selectedTemplate: $selectedTemplate,
                                shoeBrand: $shoeBrand,
                                shoeModel: $shoeModel,
                                shoeGeneration: $shoeGeneration,
                                conditionTags: $conditionTags,
                                study: $study,
                                test: $test,
                                product: $product,
                                supabaseManager: supabaseManager
                            )
                        }

                        exportButtonSection
                    }

                    if !exportManager.tasks.isEmpty {
                        ExportResultsSection(
                            exportManager: exportManager,
                            onRetryUpload: { task in retryUpload(for: task) }
                        )
                    }

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Export Cart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        if isExporting {
                            showCloseBlockedAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isExporting)
            .alert("Export in Progress", isPresented: $showCloseBlockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please wait for the export to finish before closing.")
            }
            .alert("Sensors Initializing", isPresented: $showInitializingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Some sensors are still initializing. Please wait until all sensors are ready.")
            }
            .task {
                await supabaseManager.fetchProfiles()
                await supabaseManager.fetchWorkoutTemplates()
            }
            .onAppear {
                restoreExportContextIfNeeded()
            }
            .onChange(of: supabaseManager.profiles) { _ in
                // Retry profile lookup if restore ran before fetchProfiles() completed.
                if selectedProfile == nil {
                    restoreExportContextIfNeeded()
                }
            }
            .onChange(of: exportManager.exportPhase) { phase in
                if phase == .idle || phase == .ready {
                    dbSessionMap = [:]
                    exportManager.onTaskCompleted = nil
                    clearExportContext()
                }
            }
        }
    }

    @ViewBuilder
    private var cartItemsSection: some View {
        let sessions = exportManager.cartSessions
        let grouped = Dictionary(grouping: exportManager.cartItems) { $0.sessionId }

        ForEach(Array(sessions.enumerated()), id: \.element) { index, sessionId in
            let items = grouped[sessionId] ?? []
            let sessionNumber = index + 1
            let sType = exportManager.sessionType(for: sessionId)

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Label(
                        "Session \(sessionNumber) — \(items.count) file\(items.count == 1 ? "" : "s")",
                        systemImage: sType.icon
                    )
                    .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top)
                .padding(.bottom, 8)

                // Session type toggle
                if !isExporting {
                    HStack {
                        SessionTypeToggle(type: sType) {
                            exportManager.cycleSessionType(for: sessionId)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                Divider()

                // File rows
                ForEach(Array(items.enumerated()), id: \.element.id) { rowIndex, item in
                    if rowIndex > 0 { Divider() }
                    CartItemRow(
                        item: item,
                        sessionNumber: sessionNumber,
                        sessions: sessions,
                        isCalibration: sType == .calibration,
                        onLabelChange:   { exportManager.updateLabel(for: item.id, label: $0) },
                        onRemove:        { exportManager.removeFromCart(item) },
                        onSessionChange: { exportManager.reassignSession(itemId: item.id, to: $0) },
                        onNewSession:    { exportManager.reassignSession(itemId: item.id, to: UUID()) },
                        disabled: isExporting
                    )
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
            .background(sType.cardBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(sType.borderColor, lineWidth: 2)
            )
            .padding(.horizontal)
        }

        // Cart summary
        if !exportManager.cartItems.isEmpty {
            cartSummary
        }
    }

    @ViewBuilder
    private var cartSummary: some View {
        let sessions = exportManager.cartSessions
        let grouped = Dictionary(grouping: exportManager.cartItems) { $0.sessionId }
        let runSessions = sessions.filter { exportManager.sessionType(for: $0) == .run }
        let calSessions = sessions.filter { exportManager.sessionType(for: $0) == .calibration }
        let runFiles = runSessions.flatMap { grouped[$0] ?? [] }.count
        let calFiles = calSessions.flatMap { grouped[$0] ?? [] }.count
        let totalBytes = exportManager.cartItems.reduce(0) { $0 + $1.recording.fileSize }

        VStack(alignment: .leading, spacing: 4) {
            if !runSessions.isEmpty {
                Text("\(runSessions.count) run session\(runSessions.count == 1 ? "" : "s") (\(runFiles) file\(runFiles == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if !calSessions.isEmpty {
                Text("\(calSessions.count) calibration session\(calSessions.count == 1 ? "" : "s") (\(calFiles) file\(calFiles == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            Text("Total: \(formattedBytes(totalBytes))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func formattedBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
        return "\(bytes) B"
    }

    @ViewBuilder
    private var exportButtonSection: some View {
        if !isExporting && !exportManager.cartItems.isEmpty {
            FullWidthButton(
                icon: "square.and.arrow.up",
                label: "Export \(exportManager.cartItems.count) File\(exportManager.cartItems.count == 1 ? "" : "s")",
                color: canExport ? .purple : .gray
            ) {
                if hasInitializingSensors {
                    showInitializingAlert = true
                } else {
                    Task { await prepareAndStartExport() }
                }
            }
            .disabled(!canExport)
            .padding(.horizontal)

            if selectedProfile == nil {
                Text("Select a runner profile to enable export")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal)
            } else if !emptyMetadataFields.isEmpty {
                Text("Fill in: \(emptyMetadataFields.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Export Context Persistence

    private func saveExportContext() {
        guard let profile = selectedProfile else { return }
        let ctx = ExportContext(
            profileId: profile.id,
            dbSessionMap: Dictionary(uniqueKeysWithValues: dbSessionMap.map { ($0.key.uuidString, $0.value) }),
            shoeBrand: shoeBrand, shoeModel: shoeModel, shoeGeneration: shoeGeneration,
            conditionTags: conditionTags, study: study, test: test, product: product,
            sessionMetadata: exportManager.sessionMetadata,
            sessionTypes: Dictionary(uniqueKeysWithValues: exportManager.sessionTypes.map { ($0.key.uuidString, $0.value) })
        )
        if let data = try? JSONEncoder().encode(ctx) {
            UserDefaults.standard.set(data, forKey: "activeExportContext")
        }
    }

    private func clearExportContext() {
        UserDefaults.standard.removeObject(forKey: "activeExportContext")
    }

    private func restoreExportContextIfNeeded() {
        guard !exportManager.hasRestoredTasks else { return }
        guard (exportManager.exportPhase == .exporting || exportManager.exportPhase == .done),
              !exportManager.tasks.isEmpty,
              let data = UserDefaults.standard.data(forKey: "activeExportContext"),
              let ctx = try? JSONDecoder().decode(ExportContext.self, from: data)
        else { return }

        dbSessionMap = Dictionary(uniqueKeysWithValues: ctx.dbSessionMap.compactMap {
            guard let k = UUID(uuidString: $0.key) else { return nil }
            return (k, $0.value)
        })
        shoeBrand = ctx.shoeBrand; shoeModel = ctx.shoeModel; shoeGeneration = ctx.shoeGeneration
        conditionTags = ctx.conditionTags; study = ctx.study; test = ctx.test; product = ctx.product
        selectedProfile = supabaseManager.profiles.first(where: { $0.id == ctx.profileId })
        exportManager.sessionMetadata = ctx.sessionMetadata
        if let types = ctx.sessionTypes {
            exportManager.sessionTypes = Dictionary(uniqueKeysWithValues: types.compactMap {
                guard let k = UUID(uuidString: $0.key) else { return nil }
                return (k, $0.value)
            })
        }

        // Re-wire callback only if tasks are still in flight.
        if exportManager.exportPhase == .exporting {
            exportManager.onTaskCompleted = { [self] task in
                Task { await uploadTask(task) }
            }
        }
    }

    // MARK: - Upload Helpers

    private func currentTemplate() -> WorkoutTemplate {
        WorkoutTemplate(
            shoeBrand:      shoeBrand,
            shoeModel:      shoeModel,
            shoeGeneration: shoeGeneration,
            study:          study,
            test:           test,
            product:        product,
            conditionType:  conditionType
        )
    }

    /// Pre-creates one DB session per cart session group, wires per-task upload callback,
    /// then kicks off the BLE export. Uploads begin as each file finishes transferring.
    private func prepareAndStartExport() async {
        guard let profile = selectedProfile else { return }
        let template = currentTemplate()

        let sessionGroups = Dictionary(grouping: exportManager.cartItems) { $0.sessionId }
        var map: [UUID: UUID] = [:]
        do {
            for (cartSessionId, items) in sessionGroups {
                let minTimestamp = items.map { $0.recording.timestamp }.min() ?? UInt32(Date().timeIntervalSince1970)
                let recordedDate = Date(timeIntervalSince1970: TimeInterval(minTimestamp))
                let dbId = try await SupabaseManager.shared.createSession(
                    userId: profile.id, template: template, recordedDate: recordedDate
                )
                map[cartSessionId] = dbId
            }
        } catch {
            print("⚠️ Session creation failed: \(error)")
            return
        }
        dbSessionMap = map

        exportManager.sessionMetadata = SessionMetadata(
            runnerName: profile.displayName,
            shoeBrand: shoeBrand,
            shoeModel: shoeModel,
            shoeGeneration: shoeGeneration,
            conditionType: conditionType,
            study: study,
            test: test,
            product: product,
            outputRate: DotManager.shared.selectedOutputRate,
            filterIndex: DotManager.shared.selectedFilterIndex
        )
        saveExportContext()

        exportManager.onTaskCompleted = { [self] task in
            Task { await uploadTask(task) }
        }

        exportManager.startExport()
    }

    /// Upload a single completed task to Supabase using the pre-created DB session.
    /// Retries up to `maxRetries` times with exponential backoff (1s, 2s, 4s, …).
    private func uploadTask(_ task: ExportTask, maxRetries: Int = 3) async {
        guard !task.hasPacketLoss else { return }
        guard task.uploadStatus != .uploaded else { return }
        guard let profile = selectedProfile,
              let url = task.outputURL,
              let dbSessionId = dbSessionMap[task.cartItem.sessionId] else { return }
        let template = currentTemplate()
        task.uploadStatus = .uploading
        for attempt in 0..<maxRetries {
            do {
                try await SupabaseManager.shared.uploadWorkout(
                    csvURL: url,
                    userId: profile.id,
                    sessionId: dbSessionId,
                    template: template,
                    conditionType: conditionType,
                    sensorAddress: task.cartItem.recording.macAddress,
                    recordedAt: Date(timeIntervalSince1970: TimeInterval(task.cartItem.recording.timestamp))
                )
                task.uploadStatus = .uploaded
                exportManager.persistTasks()
                return
            } catch {
                if attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    task.uploadError = error.localizedDescription
                    task.uploadStatus = .failed
                    exportManager.persistTasks()
                }
            }
        }
    }

    private func retryUpload(for task: ExportTask, maxRetries: Int = 3) {
        guard let profile = selectedProfile, let url = task.outputURL else { return }
        let template = currentTemplate()
        let cartSessionId = task.cartItem.sessionId
        task.uploadStatus = .uploading
        task.uploadError = nil
        Task {
            for attempt in 0..<maxRetries {
                do {
                    // Reuse the existing DB session if still available; only create a new
                    // one if the map has been cleared (e.g. after "Clear & Start Over").
                    let sessionId: UUID
                    if let existing = dbSessionMap[cartSessionId] {
                        sessionId = existing
                    } else {
                        let recordedDate = Date(timeIntervalSince1970: TimeInterval(task.cartItem.recording.timestamp))
                        sessionId = try await SupabaseManager.shared.createSession(
                            userId: profile.id, template: template, recordedDate: recordedDate
                        )
                    }
                    try await SupabaseManager.shared.uploadWorkout(
                        csvURL: url, userId: profile.id,
                        sessionId: sessionId,
                        template: template,
                        conditionType: conditionType,
                        sensorAddress: task.cartItem.recording.macAddress,
                        recordedAt: Date(timeIntervalSince1970: TimeInterval(task.cartItem.recording.timestamp))
                    )
                    task.uploadStatus = .uploaded
                    exportManager.persistTasks()
                    return
                } catch {
                    if attempt < maxRetries - 1 {
                        let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        try? await Task.sleep(nanoseconds: delay)
                    } else {
                        task.uploadError = error.localizedDescription
                        task.uploadStatus = .failed
                        exportManager.persistTasks()
                    }
                }
            }
        }
    }
}
