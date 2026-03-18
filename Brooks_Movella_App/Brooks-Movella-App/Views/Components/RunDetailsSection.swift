import SwiftUI

struct RunDetailsSection: View {
    @Binding var selectedProfile: Profile?
    @Binding var selectedTemplate: WorkoutTemplate?
    @Binding var shoeBrand: String
    @Binding var shoeModel: String
    @Binding var shoeGeneration: String
    @Binding var conditionTags: [String]
    @Binding var study: String
    @Binding var test: String
    @Binding var product: String
    @ObservedObject var supabaseManager: SupabaseManager

    @State private var showingTemplatePicker = false

    static let conditionOptions: [(label: String, color: Color)] = [
        ("RUN",   .blue),
        ("SQUAT", .orange),
        ("LUNGE", .green),
        ("WALK",  .indigo),
    ]

    var body: some View {
        SectionCard(title: "Run Details", icon: "figure.run") {
            VStack(alignment: .leading, spacing: 0) {
                profilePickerRow

                Divider()
                if !supabaseManager.hasFetchedTemplates || supabaseManager.isLoadingTemplates {
                    templateSkeletonRow
                } else if !supabaseManager.workoutTemplates.isEmpty {
                    templatePickerRow
                }

                Divider()

                VStack(spacing: 10) {
                    metadataField("Shoe Brand",      placeholder: "Brooks",         text: $shoeBrand)
                    metadataField("Shoe Model",      placeholder: "Adrenaline GTS", text: $shoeModel)
                    metadataField("Shoe Generation", placeholder: "25",             text: $shoeGeneration)
                }
                .padding(.vertical, 10)

                Divider()

                conditionTypeField
                    .padding(.vertical, 10)

                Divider()

                VStack(spacing: 10) {
                    metadataField("Study",   placeholder: "2000 Validation Research", text: $study)
                    metadataField("Test",    placeholder: "R1",                        text: $test)
                    metadataField("Product", placeholder: "Runner Unlock",             text: $product)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var profilePickerRow: some View {
        HStack {
            Text("Runner Profile")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Menu {
                Button("Select…") { selectedProfile = nil }
                ForEach(supabaseManager.profiles) { profile in
                    Button(profile.displayName) { selectedProfile = profile }
                }
            } label: {
                Text(selectedProfile?.displayName ?? "Select…")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
    }

    private var templateSkeletonRow: some View {
        HStack {
            Text("Load Template")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading templates…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private var templatePickerRow: some View {
        HStack {
            Text("Load Template")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Button {
                showingTemplatePicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(selectedTemplate?.displayName ?? "New template")
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
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
                        .filter { tag in RunDetailsSection.conditionOptions.contains { $0.label == tag } }
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
        .padding(.vertical, 8)
    }

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
}
