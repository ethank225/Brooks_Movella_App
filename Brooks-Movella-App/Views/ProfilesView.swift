import SwiftUI

// MARK: - ProfileFormMode

enum ProfileFormMode {
    case add
    case edit(Profile)
}

// MARK: - ProfilesView

struct ProfilesView: View {
    @ObservedObject private var manager = SupabaseManager.shared

    @State private var showingAddSheet  = false
    @State private var editingProfile: Profile?
    @State private var profileToDelete: Profile?
    @State private var showingDeleteAlert = false
    @State private var searchText = ""

    private var filteredProfiles: [Profile] {
        guard !searchText.isEmpty else { return manager.profiles }
        let query = searchText.lowercased()
        return manager.profiles.filter {
            $0.firstName.lowercased().contains(query) ||
            $0.lastName.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if manager.isLoading && manager.profiles.isEmpty {
                    ProgressView("Loading profiles…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = manager.errorMessage, manager.profiles.isEmpty {
                    errorState(error)
                } else if manager.profiles.isEmpty {
                    emptyState
                } else {
                    profileList
                }
            }
            .searchable(text: $searchText, prompt: "Search by name")
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
                Button("Delete", role: .destructive) {
                    Task { try? await manager.deleteProfile(id: profile.id) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { profile in
                Text("Remove \(profile.displayName)? This cannot be undone.")
            }
            .sheet(isPresented: $showingAddSheet) {
                ProfileFormView(mode: .add)
            }
            .sheet(item: $editingProfile) { profile in
                ProfileFormView(mode: .edit(profile))
            }
            .task {
                await manager.fetchProfiles()
            }
        }
    }

    // MARK: Profile list

    private var profileList: some View {
        List {
            if let error = manager.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            ForEach(filteredProfiles) { profile in
                ProfileRow(profile: profile)
                    .contentShape(Rectangle())
                    .onTapGesture { editingProfile = profile }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            profileToDelete = profile
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            editingProfile = profile
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await manager.fetchProfiles()
        }
    }

    // MARK: Error state

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundColor(.orange)
            Text("Failed to Load")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                Task { await manager.fetchProfiles() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("No Profiles")
                .font(.headline)
            Text("Tap + to add a profile.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ProfileRow

private struct ProfileRow: View {
    let profile: Profile

    private var birthYear: String {
        profile.birthDateAsDate.map { date in
            date.formatted(.dateTime.year())
        } ?? "—"
    }

    var body: some View {
        HStack {
            Text(profile.displayName)
                .font(.body)
            Spacer()
            Text(birthYear)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

}

// MARK: - ProfileFormView

struct ProfileFormView: View {
    let mode: ProfileFormMode

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SupabaseManager.shared

    // Form state
    @State private var firstName    = ""
    @State private var lastName     = ""
    @State private var gender       = "Male"
    @State private var heightInches = 66.0   // 5′ 6″ default
    @State private var weightLbs    = 150.0
    @State private var birthDate    = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    @State private var shoeSize     = 10.0
    @State private var shoeWidth    = "D"

    @State private var isSaving     = false
    @State private var saveError: String?

    private let genders     = ["Male", "Female", "Non-binary", "Prefer not to say"]
    private let shoeSizes   = stride(from: 4.0, through: 17.0, by: 0.5).map { $0 }
    private let shoeWidths  = ["B", "D", "2E", "4E"]
    private let shoeWidthLabels: [String: String] = [
        "B":  "Narrow (B)",
        "D":  "Medium (D)",
        "2E": "Wide (2E)",
        "4E": "Extra Wide (4E)"
    ]

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var heightLabel: String {
        let total = Int(heightInches)
        return "\(total / 12)′ \(total % 12)″"
    }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                // Personal Info
                Section("Personal Info") {
                    TextField("First Name", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Last Name", text: $lastName)
                        .textContentType(.familyName)
                    Picker("Gender", selection: $gender) {
                        ForEach(genders, id: \.self) { Text($0) }
                    }
                    DatePicker(
                        "Birth Date",
                        selection: $birthDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                }

                // Body Measurements
                Section("Body Measurements") {
                    Stepper("Height: \(heightLabel)", value: $heightInches, in: 36...96, step: 1)
                    Stepper("Weight: \(Int(weightLbs)) lbs", value: $weightLbs, in: 50...500, step: 1)
                }

                // Shoe Info
                Section("Shoe Info") {
                    Picker("Size", selection: $shoeSize) {
                        ForEach(shoeSizes, id: \.self) { size in
                            let isWhole = size.truncatingRemainder(dividingBy: 1) == 0
                            Text(isWhole ? String(Int(size)) : String(size))
                                .tag(size)
                        }
                    }
                    Picker("Width", selection: $shoeWidth) {
                        ForEach(shoeWidths, id: \.self) { width in
                            Text(shoeWidthLabels[width] ?? width).tag(width)
                        }
                    }
                }

                // Error (if save failed)
                if let error = saveError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Helpers

    private func populate() {
        guard case .edit(let profile) = mode else { return }
        firstName    = profile.firstName
        lastName     = profile.lastName
        gender       = profile.gender
        heightInches = profile.heightInches
        weightLbs    = profile.weightLbs
        shoeSize     = profile.shoeSize
        shoeWidth    = profile.shoeWidth

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        birthDate = fmt.date(from: profile.birthDate) ?? birthDate
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let payload = ProfilePayload(
            firstName:    firstName.trimmingCharacters(in: .whitespaces),
            lastName:     lastName.trimmingCharacters(in: .whitespaces),
            gender:       gender,
            heightInches: heightInches,
            weightLbs:    weightLbs,
            birthDate:    fmt.string(from: birthDate),
            shoeSize:     shoeSize,
            shoeWidth:    shoeWidth
        )

        isSaving  = true
        saveError = nil

        Task {
            do {
                switch mode {
                case .add:
                    try await manager.createProfile(payload)
                case .edit(let profile):
                    try await manager.updateProfile(id: profile.id, payload: payload)
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving  = false
            }
        }
    }
}
