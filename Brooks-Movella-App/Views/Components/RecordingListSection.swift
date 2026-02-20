import SwiftUI

struct RecordingListSection: View {
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
