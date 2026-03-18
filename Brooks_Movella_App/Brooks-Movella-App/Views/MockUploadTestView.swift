#if DEBUG
import SwiftUI

struct MockUploadTestView: View {
    @ObservedObject private var supabaseManager = SupabaseManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tasks: [ExportTask] = []
    @State private var selectedProfile: Profile?
    @State private var isGenerating = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // Profile picker
                    SectionCard(title: "Runner Profile", icon: "person.circle") {
                        Menu {
                            Button("Select…") { selectedProfile = nil }
                            ForEach(supabaseManager.profiles) { profile in
                                Button(profile.displayName) { selectedProfile = profile }
                            }
                        } label: {
                            HStack {
                                Text(selectedProfile?.displayName ?? "Select a profile…")
                                    .font(.subheadline)
                                    .foregroundColor(selectedProfile == nil ? .secondary : .primary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Generate button
                    Button {
                        Task { await generateAndUpload() }
                    } label: {
                        HStack {
                            if isGenerating {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "waveform.badge.plus")
                            }
                            Text(isGenerating ? "Uploading…" : "Generate & Upload")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(selectedProfile == nil || isGenerating ? Color.gray : Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(selectedProfile == nil || isGenerating)
                    .padding(.horizontal)

                    // Task rows
                    if !tasks.isEmpty {
                        SectionCard(title: "Mock Tasks", icon: "flask") {
                            ForEach(tasks) { task in
                                ExportTaskRow(task: task)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Mock Upload Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await supabaseManager.fetchProfiles()
            }
        }
    }

    private func generateAndUpload() async {
        guard let profile = selectedProfile else { return }
        isGenerating = true
        defer { isGenerating = false }

        let clean = MockExportGenerator.makeTask(label: "mock_clean", packetCount: 1000)
        let lossy = MockExportGenerator.makeTask(label: "mock_lossy", packetCount: 1000, dropping: [200, 201, 500])

        tasks = [clean, lossy].compactMap { $0 }

        // Use a simple default template for mock uploads.
        let template = WorkoutTemplate(
            shoeBrand:      "Mock",
            shoeModel:      "Test",
            shoeGeneration: "0",
            study:          "Mock Study",
            test:           "Mock Test",
            product:        "Mock Product",
            conditionType:  "RUN",
        )

        for task in tasks {
            guard let url = task.outputURL else { continue }
            task.uploadStatus = .uploading
            do {
                let sessionId = try await SupabaseManager.shared.createSession(
                    userId: profile.id,
                    template: template,
                    recordedDate: Date()
                )
                try await SupabaseManager.shared.uploadWorkout(
                    csvURL: url,
                    userId: profile.id,
                    sessionId: sessionId,
                    template: template,
                    conditionType: template.conditionType,
                    sensorAddress: "mock-sensor",
                    recordedAt: Date()
                )
                task.uploadStatus = .uploaded
            } catch {
                task.uploadError = error.localizedDescription
                task.uploadStatus = .failed
            }
        }
    }
}
#endif
