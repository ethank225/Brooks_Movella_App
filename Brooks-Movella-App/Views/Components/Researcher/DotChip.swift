import SwiftUI

struct DotChip: View {
    let dot: MockDot
    var isSelected: Bool = false
    var onUnassign: (() -> Void)? = nil

    @State private var isIdentifying = false
    @State private var blinkPhase = false

    private var storageColor: Color {
        dot.storagePercent >= 70 ? .orange : .green
    }

    private var borderColor: Color {
        if isIdentifying { return .orange }
        return isSelected ? .blue : Color.gray.opacity(0.25)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.blue.opacity(0.7))
                    .frame(width: 6, height: 6)
                Text(dot.id)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let onUnassign {
                    Button(action: onUnassign) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.25))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(storageColor)
                        .frame(width: geo.size.width * CGFloat(dot.storagePercent) / 100)
                }
            }
            .frame(height: 4)

            Text("\(dot.storagePercent)%\(dot.storagePercent >= 70 ? "!" : "")")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(storageColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 92)
        .background(
            isIdentifying
                ? Color.orange.opacity(blinkPhase ? 0.85 : 0.25)
                : Color(.tertiarySystemBackground)
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    borderColor,
                    lineWidth: (isSelected || isIdentifying) ? 2 : 1
                )
        )
        .shadow(color: isSelected ? Color.blue.opacity(0.35) : .clear, radius: 5, x: 0, y: 0)
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .gesture(
            TapGesture(count: 2).onEnded { triggerIdentify() }
        )
    }

    private func triggerIdentify() {
        guard !isIdentifying else { return }
        isIdentifying = true
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
            blinkPhase = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isIdentifying = false
            blinkPhase = false
        }
    }
}
