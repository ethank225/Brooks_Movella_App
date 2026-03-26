import SwiftUI

struct CorruptedSensorRow: View {
    let displayName: String
    var isRepairing: Bool = false
    let onErase: () -> Void

    var body: some View {
        // Matches normalRow: VStack(spacing: 10) with top line + bottom line
        VStack(alignment: .leading, spacing: 10) {
            // Top line — icon + name + erase button
            HStack(spacing: 10) {
                if isRepairing {
                    ProgressView()
                        .scaleEffect(0.75)
                        .fixedSize()
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                }

                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if !isRepairing {
                    Button(action: onErase) {
                        Text("Erase")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.orange)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Bottom line — status message, left-aligned under the name
            Text(isRepairing ? "Repairing storage..." : "Storage corrupted — tap Erase to repair")
                .font(.caption)
                .foregroundColor(isRepairing ? .pink : .orange)
                .padding(.leading, 20)
        }
    }
}
