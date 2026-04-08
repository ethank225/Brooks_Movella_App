import SwiftUI

struct RunnerRecordingSection: View {
    let group: RunnerRecordingGroup
    let cartItemIds: Set<String>
    let sessionTypes: [UUID: SessionType]
    let onAddToCart: (RecordingSession, Set<String>) -> Void
    let onRemoveSession: (RecordingSession) -> Void
    let onToggleSessionType: (RecordingSession) -> Void
    let onMoveFile: (RecordingSession.SessionFile, UUID?, RunnerRecordingGroup) -> Void
    @Binding var selectedFileIds: Set<String>

    @State private var isExpanded = true

    private var totalFiles: Int {
        group.sessions.reduce(0) { $0 + $1.files.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Runner header
            HStack(spacing: 12) {
                runnerAvatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.runnerName)
                        .font(.headline)
                    if !group.dotNames.isEmpty {
                        Text(group.dotNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(totalFiles) file\(totalFiles == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.06))
            .cornerRadius(12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(AppAnimation.expand) { isExpanded.toggle() }
            }

            if isExpanded {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionCard(
                        session: session,
                        sessionNumber: index + 1,
                        sessionType: sessionTypes[session.id] ?? .run,
                        cartItemIds: cartItemIds,
                        allSessions: group.sessions,
                        onAddToCart: onAddToCart,
                        onRemoveSession: onRemoveSession,
                        onToggleSessionType: onToggleSessionType,
                        onMoveFile: { file, destination in
                            onMoveFile(file, destination, group)
                        },
                        selectedFileIds: $selectedFileIds
                    )
                }
            }
        }
    }

    private var runnerAvatar: some View {
        let initial = group.runnerName.prefix(1).uppercased()
        let isUnmatched = group.id == "__unmatched__"
        return Text(isUnmatched ? "?" : initial)
            .font(.caption.bold())
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(isUnmatched ? Color.gray : Color.purple)
            .clipShape(Circle())
    }
}
