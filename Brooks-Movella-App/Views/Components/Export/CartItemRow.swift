import SwiftUI

struct CartItemRow: View {
    let item: CartItem
    let sessionNumber: Int
    let sessions: [UUID]
    var isCalibration: Bool = false
    let onLabelChange:   (String) -> Void
    let onRemove:        () -> Void
    let onSessionChange: (UUID) -> Void
    let onNewSession:    () -> Void
    var disabled: Bool = false

    @State private var editedLabel: String = ""

    var body: some View {
        HStack(spacing: 12) {
            sessionBadge

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("File label", text: $editedLabel)
                        .font(.subheadline.weight(.medium))
                        .textFieldStyle(.plain)
                        .disabled(disabled)
                        .onChange(of: editedLabel) { newValue in
                            onLabelChange(newValue)
                        }
                    if isCalibration {
                        Text("CAL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(3)
                    }
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
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .onAppear { editedLabel = item.label }
    }

    @ViewBuilder
    private var sessionBadge: some View {
        if !disabled {
            Menu {
                ForEach(sessions.indices, id: \.self) { i in
                    Button("Session \(i + 1)") { onSessionChange(sessions[i]) }
                }
                Divider()
                Button("New Session") { onNewSession() }
            } label: {
                badgeLabel
            }
        } else {
            badgeLabel
        }
    }

    private var badgeLabel: some View {
        Text("S\(sessionNumber)")
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(sessionColor(sessionNumber))
            .clipShape(Capsule())
    }

    private func sessionColor(_ n: Int) -> Color {
        let colors: [Color] = [.purple, .blue, .green, .orange, .pink]
        return colors[(n - 1) % colors.count]
    }
}
