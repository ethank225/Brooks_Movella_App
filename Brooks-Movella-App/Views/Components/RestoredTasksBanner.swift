import SwiftUI

struct RestoredTasksBanner: View {
    @ObservedObject var exportManager: ExportManager
    var onTap: () -> Void

    private var tasks: [ExportTask] { exportManager.tasks }

    private var total: Int    { tasks.filter { $0.status == .success }.count }
    private var uploaded: Int { tasks.filter { $0.uploadStatus == .uploaded }.count }
    private var failed: Int   { tasks.filter { $0.status == .failed }.count }
    private var pending: Int  { tasks.filter { $0.status == .success && $0.uploadStatus == .pending }.count }

    private var detailText: String {
        var parts: [String] = []
        if total > 0    { parts.append("\(total) exported") }
        if uploaded > 0 { parts.append("\(uploaded) uploaded") }
        if pending > 0  { parts.append("\(pending) pending upload") }
        if failed > 0   { parts.append("\(failed) failed") }
        return parts.isEmpty ? "No results" : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Icon
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Text stack
                VStack(alignment: .leading, spacing: 2) {
                    Text("Previous Session Restored")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(detailText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // View results hint + dismiss
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        exportManager.dismissRestoredTasksBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.secondary)
                            .padding(5)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

//                    HStack(spacing: 2) {
//                        Text("View")
//                            .font(.caption.weight(.medium))
//                        Image(systemName: "chevron.right")
//                            .font(.caption2.weight(.semibold))
//                    }
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.08),
                            Color.purple.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.25), Color.purple.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .cornerRadius(15)
            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}
