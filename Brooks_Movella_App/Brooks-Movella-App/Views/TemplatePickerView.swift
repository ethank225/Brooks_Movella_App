import SwiftUI

struct TemplatePickerView: View {
    @Binding var selectedTemplate: WorkoutTemplate?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var supabaseManager = SupabaseManager.shared

    @State private var searchText = ""

    private var filteredTemplates: [WorkoutTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return supabaseManager.workoutTemplates }
        return supabaseManager.workoutTemplates.filter { t in
            t.shoeBrand.lowercased().contains(query)
                || t.shoeModel.lowercased().contains(query)
                || t.shoeGeneration.lowercased().contains(query)
                || t.study.lowercased().contains(query)
                || t.test.lowercased().contains(query)
                || t.product.lowercased().contains(query)
                || t.conditionType.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationView {
            List {
                if searchText.isEmpty {
                    Button {
                        selectedTemplate = nil
                        dismiss()
                    } label: {
                        HStack {
                            Text("New template")
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedTemplate == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }

                ForEach(filteredTemplates) { template in
                    Button {
                        selectedTemplate = template
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.displayName)
                                    .foregroundColor(.primary)
                                    .font(.subheadline)
                                Text(template.conditionType)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                            if selectedTemplate == template {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }

                if !searchText.isEmpty && filteredTemplates.isEmpty {
                    Text("No templates match \"\(searchText)\"")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                        .listRowBackground(Color.clear)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search templates")
            .navigationTitle("Load Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
