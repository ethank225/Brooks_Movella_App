import SwiftUI

struct ExportView: View {
    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var exportManager = ExportManager.shared

    @State private var showCart = false

    private var connectedDots: [Dot] { manager.connectedDots }
    private var cartCount: Int { exportManager.cartItems.count }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // MARK: - Recordings List

                    if connectedDots.isEmpty {
                        SectionCard(title: "Recordings", icon: "doc.on.doc") {
                            EmptyStateView(
                                icon: "sensor.tag.radiowaves.forward",
                                headline: "No sensors connected",
                                subheadline: "Connect sensors in the Connect tab to view recordings"
                            )
                        }
                    } else if exportManager.exportPhase == .idle || exportManager.exportPhase == .fetching {
                        SectionCard(title: "Recordings", icon: "doc.on.doc") {
                            Button {
                                exportManager.fetchRecordings(for: connectedDots)
                            } label: {
                                HStack {
                                    if exportManager.isFetching {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: "arrow.down.doc")
                                    }
                                    Text(exportManager.isFetching ? "Fetching..." : "Fetch Recordings")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(exportManager.isFetching ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .disabled(exportManager.isFetching)
                        }
                    } else {
                        // Show per-dot recording sections
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

                        // Add to Cart button
                        if !exportManager.selectedIDs.isEmpty {
                            Button {
                                exportManager.buildCart()
                            } label: {
                                HStack {
                                    Image(systemName: "cart.badge.plus")
                                    Text("Add \(exportManager.selectedIDs.count) to Cart")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal)
                        }

                        // Refresh button
                        Button {
                            exportManager.fetchRecordings(for: connectedDots)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh")
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        }
                        .padding(.top, 4)
                    }

                    Spacer()
                }
                .padding(.top)
            }
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCart = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cart")
                            if cartCount > 0 {
                                Text("\(cartCount)")
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
            .sheet(isPresented: $showCart) {
                CartView()
            }
        }
    }
}

// MARK: - Recording List Section

private struct RecordingListSection: View {
    let dot: Dot
    let files: [RecordingFile]
    @Binding var selectedIDs: Set<String>
    let onToggle: (RecordingFile) -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    @State private var isExpanded = false

    private var allSelected: Bool {
        !files.isEmpty && files.allSatisfy { selectedIDs.contains($0.id) }
    }

    private var selectedCount: Int {
        files.filter { selectedIDs.contains($0.id) }.count
    }

    var body: some View {
        SectionCard(title: "DOT \(String(dot.id))", icon: "sensor.tag.radiowaves.forward") {
            if files.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    headline: "No recordings",
                    subheadline: "This sensor has no recorded data"
                )
            } else {
                // Expandable header row
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 16)

                        Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.primary)

                        if selectedCount > 0 {
                            Text("\(selectedCount) selected")
                                .font(.caption)
                                .foregroundColor(.purple)
                        }

                        Spacer()

                        Button(allSelected ? "Deselect All" : "Select All") {
                            if allSelected { onDeselectAll() }
                            else { onSelectAll() }
                        }
                        .font(.caption)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(files) { file in
                        RecordingRow(
                            file: file,
                            isSelected: selectedIDs.contains(file.id),
                            onToggle: { onToggle(file) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Recording Row

private struct RecordingRow: View {
    let file: RecordingFile
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .purple : .gray)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("File \(file.fileIndex)")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Text(file.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(file.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(isSelected ? Color.purple.opacity(0.08) : Color.gray.opacity(0.1))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cart View

struct CartView: View {
    @ObservedObject private var exportManager   = ExportManager.shared
    @ObservedObject private var supabaseManager = SupabaseManager.shared
    @ObservedObject private var dotManager      = DotManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showShareSheet = false
    @State private var showCloseBlockedAlert = false
    @State private var showingTemplatePicker = false

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
    private var hasFailed: Bool { exportManager.tasks.contains { $0.status == .failed } }

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
                        // Cart items
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

                        // Run Details (profile + template + metadata)
                        if !isExporting {
                            runDetailsSection
                        }

                        // Export button
                        if !isExporting && !exportManager.cartItems.isEmpty {
                            Button {
                                exportManager.startExport()
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export \(exportManager.cartItems.count) File\(exportManager.cartItems.count == 1 ? "" : "s")")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(canExport ? Color.purple : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(10)
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

                    // Export progress / results
                    if !exportManager.tasks.isEmpty {
                        SectionCard(
                            title: isDone ? "Export Results" : "Exporting...",
                            icon: isDone ? "checkmark.circle" : "arrow.up.circle"
                        ) {
                            ForEach(exportManager.tasks) { task in
                                ExportTaskRow(task: task, onRetryUpload: {
                                    retryUpload(for: task)
                                })
                            }
                        }

                        if isExporting {
                            Button {
                                exportManager.cancelExport()
                            } label: {
                                HStack {
                                    Image(systemName: "xmark.circle")
                                    Text("Cancel Export")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal)
                        }

                        if isDone {
                            VStack(spacing: 12) {
                                if hasFailed {
                                    Button {
                                        exportManager.retryFailed()
                                    } label: {
                                        HStack {
                                            Image(systemName: "arrow.clockwise")
                                            Text("Retry Failed")
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                    }
                                }

                                if !exportManager.exportedFileURLs.isEmpty {
                                    Button {
                                        showShareSheet = true
                                    } label: {
                                        HStack {
                                            Image(systemName: "square.and.arrow.up")
                                            Text("Share Exported Files")
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                    }
                                }

                                Button {
                                    exportManager.resetExport()
                                    exportManager.clearCart()
                                } label: {
                                    HStack {
                                        Image(systemName: "trash")
                                        Text("Clear & Start Over")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.gray.opacity(0.2))
                                    .foregroundColor(.primary)
                                    .cornerRadius(10)
                                }
                            }
                            .padding(.horizontal)
                        }
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
            .sheet(isPresented: $showShareSheet) {
                if !exportManager.exportedFileURLs.isEmpty {
                    ShareSheet(urls: exportManager.exportedFileURLs)
                }
            }
            .task {
                await supabaseManager.fetchProfiles()
                await supabaseManager.fetchWorkoutTemplates()
            }
            .onChange(of: exportManager.exportPhase) { phase in
                if phase == .done { triggerPendingUploads() }
            }
        }
    }

    // MARK: - Run Details Section

    private var runDetailsSection: some View {
        SectionCard(title: "Run Details", icon: "figure.run") {
            VStack(alignment: .leading, spacing: 0) {

                // Profile picker
                HStack {
                    Text("Runner Profile")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Picker("Runner Profile", selection: $selectedProfile) {
                        Text("Select…").tag(Optional<Profile>(nil))
                        ForEach(supabaseManager.profiles) { profile in
                            Text(profile.displayName).tag(Optional(profile))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)

                // Template picker (only if past workouts exist)
                if !supabaseManager.workoutTemplates.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Load Template")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            showingTemplatePicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedTemplate?.displayName ?? "New template")
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showingTemplatePicker) {
                            TemplatePickerView(selectedTemplate: $selectedTemplate)
                        }
                        .onChange(of: selectedTemplate) { template in
                            if let t = template {
                                shoeBrand      = t.shoeBrand
                                shoeModel      = t.shoeModel
                                shoeGeneration = t.shoeGeneration
                                conditionTags  = t.conditionType
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                                    .filter { tag in CartView.conditionOptions.contains { $0.label == tag } }
                                study          = t.study
                                test           = t.test
                                product        = t.product
                            } else {
                                shoeBrand      = ""
                                shoeModel      = ""
                                shoeGeneration = ""
                                conditionTags  = []
                                study          = ""
                                test           = ""
                                product        = ""
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Divider()

                // Shoe fields
                VStack(spacing: 10) {
                    metadataField("Shoe Brand",      placeholder: "Brooks",         text: $shoeBrand)
                    metadataField("Shoe Model",      placeholder: "Adrenaline GTS", text: $shoeModel)
                    metadataField("Shoe Generation", placeholder: "25",             text: $shoeGeneration)
                }
                .padding(.vertical, 10)

                Divider()

                // Condition type selector
                conditionTypeField
                    .padding(.vertical, 10)

                Divider()

                // Study / Test / Product
                VStack(spacing: 10) {
                    metadataField("Study",   placeholder: "2000 Validation Research", text: $study)
                    metadataField("Test",    placeholder: "R1",                        text: $test)
                    metadataField("Product", placeholder: "Runner Unlock",             text: $product)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private static let conditionOptions: [(label: String, color: Color)] = [
        ("RUN",   .blue),
        ("SQUAT", .orange),
        ("LUNGE", .green),
        ("WALK",  .indigo),
    ]

    private var conditionTypeField: some View {
        VStack(spacing: 8) {
            Text("Select")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 6) {
                ForEach(Self.conditionOptions, id: \.label) { option in
                    let selected = conditionTags.contains(option.label)
                    Button {
                        if selected {
                            conditionTags.removeAll { $0 == option.label }
                        } else {
                            conditionTags.append(option.label)
                        }
                    } label: {
                        Text(option.label)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                            .foregroundColor(selected ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selected ? option.color : Color(.systemGray5))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func metadataField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
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

    private func triggerPendingUploads() {
        guard let profile = selectedProfile else { return }
        let template = currentTemplate()
        let pendingTasks = exportManager.tasks.filter { $0.status == .success && $0.uploadStatus == .pending }
        guard !pendingTasks.isEmpty else { return }

        Task {
            do {
                // Group by sessionId and create one DB session per group
                let sessionGroups = Dictionary(grouping: pendingTasks) { $0.cartItem.sessionId }
                var sessionIdMap: [UUID: UUID] = [:]  // cartSessionId → DB session_id

                for cartSessionId in sessionGroups.keys {
                    let dbSessionId = try await SupabaseManager.shared.createSession(
                        userId: profile.id,
                        template: template
                    )
                    sessionIdMap[cartSessionId] = dbSessionId
                }

                // Now upload each file
                for task in pendingTasks {
                    guard let url = task.outputURL,
                          let dbSessionId = sessionIdMap[task.cartItem.sessionId] else { continue }
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
            } catch {
                print("⚠️ Session creation failed: \(error)")
            }
        }
    }

    private func retryUpload(for task: ExportTask) {
        guard let profile = selectedProfile, let url = task.outputURL else { return }
        let template = currentTemplate()
        task.uploadStatus = .uploading
        task.uploadError = nil
        Task {
            do {
                let sessionId = try await SupabaseManager.shared.createSession(
                    userId: profile.id, template: template
                )
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

// MARK: - Cart Item Row

private struct CartItemRow: View {
    let item: CartItem
    let sessionNumber: Int
    let sessions: [UUID]
    let onLabelChange:   (String) -> Void
    let onRemove:        () -> Void
    let onSessionChange: (UUID) -> Void
    let onNewSession:    () -> Void
    var disabled: Bool = false

    @State private var editedLabel: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Session badge / picker
            if !disabled {
                Menu {
                    ForEach(sessions.indices, id: \.self) { i in
                        Button("Session \(i + 1)") { onSessionChange(sessions[i]) }
                    }
                    Divider()
                    Button("New Session") { onNewSession() }
                } label: {
                    Text("S\(sessionNumber)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(sessionColor(sessionNumber))
                        .clipShape(Capsule())
                }
            } else {
                Text("S\(sessionNumber)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(sessionColor(sessionNumber))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("File label", text: $editedLabel)
                    .font(.subheadline.weight(.medium))
                    .textFieldStyle(.plain)
                    .disabled(disabled)
                    .onChange(of: editedLabel) { newValue in
                        onLabelChange(newValue)
                    }

                HStack(spacing: 8) {
                    Text(item.recording.formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.recording.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !disabled {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
        .onAppear { editedLabel = item.label }
    }

    private func sessionColor(_ n: Int) -> Color {
        let colors: [Color] = [.purple, .blue, .green, .orange, .pink]
        return colors[(n - 1) % colors.count]
    }
}

// MARK: - Export Task Row

private struct ExportTaskRow: View {
    @ObservedObject var task: ExportTask
    var onRetryUpload: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.cartItem.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                ExportSubphaseTag(status: task.status, subphase: task.subphase)
            }

            // Progress bar
            if task.status == .running || task.status == .success {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.3))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressBarColor)
                            .frame(width: geo.size.width * min(task.progress, 1.0))
                    }
                }
                .frame(height: 6)
            }

            // BLE export error
            if let error = task.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // File path
            if let url = task.outputURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Upload status
            if task.status == .success {
                uploadStatusRow
            }
        }
        .padding(10)
        .background(taskBackground)
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.3), value: task.status)
        .animation(.easeInOut(duration: 0.3), value: task.uploadStatus)
    }

    @ViewBuilder
    private var uploadStatusRow: some View {
        switch task.uploadStatus {
        case .pending:
            EmptyView()
        case .uploading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Uploading to Supabase…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .uploaded:
            Label("Uploaded", systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                if let uploadError = task.uploadError {
                    Text("Upload failed: \(uploadError)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Button("Retry Upload") { onRetryUpload?() }
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
    }

    private var progressBarColor: Color {
        switch task.subphase {
        case .transferring: return .blue
        case .complete:     return .green
        case .idle:         return task.status == .success ? .green : .blue
        }
    }

    private var taskBackground: Color {
        switch task.status {
        case .running:  return Color.blue.opacity(0.08)
        case .success:  return Color.green.opacity(0.08)
        case .failed:   return Color.red.opacity(0.08)
        case .canceled: return Color.orange.opacity(0.08)
        case .queued:   return Color.gray.opacity(0.1)
        }
    }
}

// MARK: - Export Subphase Tag

private struct ExportSubphaseTag: View {
    let status: ExportStatus
    let subphase: ExportSubphase

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var label: String {
        switch status {
        case .queued:   return "Queued"
        case .running:
            switch subphase {
            case .transferring: return "Transferring"
            default:            return "Exporting"
            }
        case .success:  return "Done"
        case .failed:   return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private var color: Color {
        switch status {
        case .queued:   return .gray
        case .running:  return .blue
        case .success:  return .green
        case .failed:   return .red
        case .canceled: return .orange
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    let icon: String
    let headline: String
    let subheadline: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(headline)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subheadline)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
