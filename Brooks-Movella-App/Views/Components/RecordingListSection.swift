import SwiftUI

struct RecordingListSection: View {
    let dot: Dot
    let files: [RecordingFile]
    var isLoading: Bool = false
    @Binding var selectedIDs: Set<String>
    let onToggle: (RecordingFile) -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    @ObservedObject private var nameStore = SensorNameStore.shared
    @State private var isExpanded = false

    private var allSelected: Bool {
        !files.isEmpty && files.allSatisfy { selectedIDs.contains($0.id) }
    }

    private var selectedCount: Int {
        files.filter { selectedIDs.contains($0.id) }.count
    }

    private var canExpand: Bool { !files.isEmpty && !isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Dot header row
            HStack(spacing: 12) {
                Circle()
                    .fill(dot.isConnected ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 12, height: 12)

                Text(nameStore.name(for: dot.id))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                } else if files.isEmpty {
                    Text("No recordings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // File list (expanded)
            if isExpanded && !files.isEmpty {
                HStack {
                    Spacer()
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected { onDeselectAll() }
                        else { onSelectAll() }
                    }
                    .font(.caption)
                }

                ForEach(files) { file in
                    RecordingRow(
                        file: file,
                        isSelected: selectedIDs.contains(file.id),
                        onToggle: { onToggle(file) }
                    )
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
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
