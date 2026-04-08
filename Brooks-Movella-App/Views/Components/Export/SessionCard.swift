import SwiftUI

struct SessionCard: View {
    let session: RecordingSession
    let sessionNumber: Int
    let sessionType: SessionType
    let cartItemIds: Set<String>
    let allSessions: [RecordingSession]
    let onAddToCart: (RecordingSession, Set<String>) -> Void
    let onRemoveSession: (RecordingSession) -> Void
    let onToggleSessionType: (RecordingSession) -> Void
    let onMoveFile: (RecordingSession.SessionFile, UUID?) -> Void
    @Binding var selectedFileIds: Set<String>

    @State private var isExpanded = true

    private var sessionFiles: [RecordingSession.SessionFile] { session.files }
    private var sessionFileIds: Set<String> { Set(sessionFiles.map { $0.id }) }
    private var anyInCart: Bool { !sessionFileIds.intersection(cartItemIds).isEmpty }
    private var allInCart: Bool { !sessionFiles.isEmpty && sessionFileIds.isSubset(of: cartItemIds) }
    private var isCal: Bool { sessionType == .calibration }
    private var hasSelection: Bool { !selectedFileIds.intersection(sessionFileIds).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                sessionBadge

                Text(session.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text("\(session.sensorCount)/\(session.expectedSensorCount)")
                    .font(.caption)
                    .foregroundColor(session.isComplete ? .green : .orange)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, isExpanded ? 12 : 0)

            if isExpanded {
                sessionContent
            }
        }
        .padding(16)
        .background(anyInCart ? sessionType.cardBackground : Color.gray.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(anyInCart ? sessionType.borderColor : Color.clear, lineWidth: 2)
        )
        .animation(AppAnimation.content, value: sessionType)
        .animation(AppAnimation.content, value: anyInCart)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(AppAnimation.expand) { isExpanded.toggle() }
        }
    }

    // MARK: - Session Content

    @ViewBuilder
    private var sessionContent: some View {
        // Toggle + info row (toggle grayed when nothing in cart)
        HStack(spacing: 10) {
            SessionTypeToggle(type: sessionType) {
                onToggleSessionType(session)
            }
            .opacity(anyInCart ? 1 : 0.35)
            .disabled(!anyInCart)

            Spacer()

            Text("\(sessionFiles.count) file\(sessionFiles.count == 1 ? "" : "s") · \(formattedTotalSize)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 10)

        // File rows with rounded containers
        VStack(spacing: 8) {
            ForEach(Array(sessionFiles.enumerated()), id: \.element.id) { index, file in
                let inCart = cartItemIds.contains(file.id)
                let isSelected = selectedFileIds.contains(file.id)
                HStack(spacing: 10) {
                    Image(systemName: inCart ? "checkmark.circle.fill" : isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(inCart ? .green : isSelected ? .purple : .gray.opacity(0.5))
                        .font(.system(size: 18))
                        .animation(AppAnimation.standard, value: inCart)
                        .animation(AppAnimation.standard, value: isSelected)

                    Text(file.dot.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Text("cal")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(3)
                        .opacity(isCal && inCart ? 1 : 0)

                    Spacer()

                    Text("file \(file.recording.fileIndex) · \(file.recording.formattedSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    fileMenu(for: file)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color.gray.opacity(0.08))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.blue)
                        .frame(width: 3)
                        .opacity(isCal && inCart ? 1 : 0)
                }
                .cornerRadius(8)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !inCart else { return }
                    if isSelected {
                        selectedFileIds.remove(file.id)
                    } else {
                        selectedFileIds.insert(file.id)
                    }
                }
            }
        }

        // Add all / Remove all
        if anyInCart {
            Button {
                onRemoveSession(session)
            } label: {
                Text("Remove all")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        } else {
            Button {
                onAddToCart(session, sessionFileIds)
                selectedFileIds.subtract(sessionFileIds)
            } label: {
                Text("Add all to cart")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    // MARK: - Shared

    private func fileMenu(for file: RecordingSession.SessionFile) -> some View {
        Menu {
            ForEach(Array(allSessions.filter { $0.id != session.id }.enumerated()), id: \.element.id) { _, s in
                Button("Move to \(s.timestamp.formatted(date: .abbreviated, time: .shortened))") {
                    onMoveFile(file, s.id)
                }
            }
            if allSessions.count > 1 { Divider() }
            Button("New Session") { onMoveFile(file, nil) }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 24, height: 24)
        }
    }

    private var sessionBadge: some View {
        Text("S\(sessionNumber)")
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(sessionColor)
            .clipShape(Capsule())
    }

    private var sessionColor: Color {
        let colors: [Color] = [.purple, .blue, .green, .orange, .pink, .teal, .indigo]
        return colors[(sessionNumber - 1) % colors.count]
    }

    private var formattedTotalSize: String {
        let bytes = session.totalSize
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
        return "\(bytes) B"
    }
}
