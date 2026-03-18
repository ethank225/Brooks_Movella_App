import SwiftUI

struct AddRunnerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("Add runner")
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundColor(Color.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}
