import SwiftUI

struct ExportView: View {
    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var exportManager = ExportManager.shared

    @State private var showCart = false
    #if DEBUG
    @State private var showMockTest = false
    #endif

    private var connectedDots: [Dot] { manager.connectedDots }
    private var cartCount: Int { exportManager.cartItems.count }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    recordingsContent
                    Spacer()
                }
                .padding(.top)
            }
            .refreshable { exportManager.fetchRecordings(for: connectedDots) }
            .onAppear {
                // Auto-refresh recordings whenever the Export tab becomes visible,
                // but only when it's safe: sensors connected, not mid-export, not
                // in the post-export done state (user may be about to share).
                let safeToRefresh = !connectedDots.isEmpty
                    && exportManager.exportPhase != .exporting
                    && exportManager.exportPhase != .done
                if safeToRefresh {
                    exportManager.fetchRecordings(for: connectedDots)
                }
            }
            .navigationTitle("Export")
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showMockTest = true
                    } label: {
                        Label("Mock Upload", systemImage: "flask")
                    }
                }
                #endif
                ToolbarItem(placement: .navigationBarTrailing) {
                    CartBadgeButton(count: cartCount) { showCart = true }
                }
            }
            .sheet(isPresented: $showCart) {
                CartView()
            }
            #if DEBUG
            .sheet(isPresented: $showMockTest) {
                MockUploadTestView()
            }
            #endif
        }
    }

    @ViewBuilder
    private var recordingsContent: some View {
        if connectedDots.isEmpty {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                EmptyStateView(
                    icon: "sensor.tag.radiowaves.forward",
                    headline: "No sensors connected",
                    subheadline: "Connect sensors in the Connect tab to view recordings"
                )
            }
        } else if exportManager.exportPhase == .idle {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                FullWidthButton(icon: "arrow.down.doc", label: "Fetch Recordings", color: .blue) {
                    exportManager.fetchRecordings(for: connectedDots)
                }
            }
        } else if exportManager.exportPhase == .fetching {
            SectionCard(title: "Recordings", icon: "doc.on.doc") {
                FetchingStateView(dots: connectedDots, loadedAddresses: Set(exportManager.recordings.keys))
            }
        } else {
            ForEach(connectedDots, id: \.address) { dot in
                let files = exportManager.recordings[dot.address] ?? []
                RecordingListSection(
                    dot: dot,
                    files: files,
                    selectedIDs: $exportManager.selectedIDs,
                    onToggle: { file in exportManager.toggleSelection(file) },
                    onSelectAll: { exportManager.selectAll(for: dot.address) },
                    onDeselectAll: { exportManager.deselectAll(for: dot.address) }
                )
            }

            if !exportManager.selectedIDs.isEmpty {
                FullWidthButton(
                    icon: "cart.badge.plus",
                    label: "Add \(exportManager.selectedIDs.count) to Cart",
                    color: .purple
                ) {
                    exportManager.buildCart()
                }
                .padding(.horizontal)
            }
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
    @ObservedObject private var exportManager   = ExportManager.shared
    @ObservedObject private var supabaseManager = SupabaseManager.shared
    @ObservedObject private var dotManager      = DotManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showCloseBlockedAlert = false
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

    private var canExport: Bool {
        !exportManager.cartItems.isEmpty && selectedProfile != nil && emptyMetadataFields.isEmpty
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
            .task {
                await supabaseManager.fetchProfiles()
                await supabaseManager.fetchWorkoutTemplates()
            }
            .onChange(of: exportManager.exportPhase) { phase in
                if phase == .idle {
                    dbSessionMap = [:]
                    exportManager.onTaskCompleted = nil
                }
            }
        }
    }

    @ViewBuilder
    private var cartItemsSection: some View {
        SectionCard(title: "Cart — \(exportManager.cartItems.count) item\(exportManager.cartItems.count == 1 ? "" : "s")", icon: "cart") {
            let sessions = exportManager.cartSessions
            ForEach(exportManager.cartItems) { item in
                let sessionNumber = (sessions.firstIndex(of: item.sessionId) ?? 0) + 1
                CartItemRow(
                    item: item,
                    sessionNumber: sessionNumber,
                    sessions: sessions,
                    onLabelChange:   { exportManager.updateLabel(for: item.id, label: $0) },
                    onRemove:        { exportManager.removeFromCart(item) },
                    onSessionChange: { exportManager.reassignSession(itemId: item.id, to: $0) },
                    onNewSession:    { exportManager.reassignSession(itemId: item.id, to: UUID()) },
                    disabled: isExporting
                )
            }
        }
    }

    @ViewBuilder
    private var exportButtonSection: some View {
        if !isExporting && !exportManager.cartItems.isEmpty {
            FullWidthButton(
                icon: "square.and.arrow.up",
                label: "Export \(exportManager.cartItems.count) File\(exportManager.cartItems.count == 1 ? "" : "s")",
                color: canExport ? .purple : .gray
            ) {
                Task { await prepareAndStartExport() }
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
            for cartSessionId in sessionGroups.keys {
                let dbId = try await SupabaseManager.shared.createSession(
                    userId: profile.id, template: template
                )
                map[cartSessionId] = dbId
            }
        } catch {
            print("⚠️ Session creation failed: \(error)")
            return
        }
        dbSessionMap = map

        exportManager.onTaskCompleted = { [self] task in
            Task { await uploadTask(task) }
        }

        exportManager.startExport()
    }

    /// Upload a single completed task to Supabase using the pre-created DB session.
    private func uploadTask(_ task: ExportTask) async {
        guard let profile = selectedProfile,
              let url = task.outputURL,
              let dbSessionId = dbSessionMap[task.cartItem.sessionId] else { return }
        let template = currentTemplate()
        task.uploadStatus = .uploading
        do {
            try await SupabaseManager.shared.uploadWorkout(
                csvURL: url,
                userId: profile.id,
                sessionId: dbSessionId,
                template: template,
                conditionType: conditionType
            )
            task.uploadStatus = .uploaded
        } catch {
            task.uploadError = error.localizedDescription
            task.uploadStatus = .failed
        }
    }

    private func retryUpload(for task: ExportTask) {
        guard let profile = selectedProfile, let url = task.outputURL else { return }
        let template = currentTemplate()
        let cartSessionId = task.cartItem.sessionId
        task.uploadStatus = .uploading
        task.uploadError = nil
        Task {
            do {
                // Reuse the existing DB session if still available; only create a new
                // one if the map has been cleared (e.g. after "Clear & Start Over").
                let sessionId: UUID
                if let existing = dbSessionMap[cartSessionId] {
                    sessionId = existing
                } else {
                    sessionId = try await SupabaseManager.shared.createSession(
                        userId: profile.id, template: template
                    )
                }
                try await SupabaseManager.shared.uploadWorkout(
                    csvURL: url, userId: profile.id,
                    sessionId: sessionId,
                    template: template,
                    conditionType: conditionType
                )
                task.uploadStatus = .uploaded
            } catch {
                task.uploadError = error.localizedDescription
                task.uploadStatus = .failed
            }
        }
    }
}
