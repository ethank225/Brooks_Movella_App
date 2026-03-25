import SwiftUI

/// Live-updating mini bar that observes a Dot's published properties.
struct LiveMiniBar: View {
    let label: String
    @ObservedObject var dot: Dot
    /// Key path into Dot for the percentage (0–100).
    let valueKeyPath: KeyPath<Dot, Double>
    let colorFor: (Double) -> Color
    let isConnected: Bool

    @State private var animatedPercent: Double = 0

    private var currentPercent: Double {
        dot[keyPath: valueKeyPath]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                if isConnected {
                    Text(String(format: "%.1f%%", currentPercent))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(isConnected ? 0.3 : 0.2))
                    if isConnected {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorFor(animatedPercent))
                            .frame(width: geo.size.width * min(max(animatedPercent / 100, 0), 1.0))
                    }
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: currentPercent) { newVal in
            withAnimation(.easeOut(duration: 0.6)) {
                animatedPercent = newVal
            }
        }
        .onChange(of: isConnected) { connected in
            if connected {
                withAnimation(.easeOut(duration: 0.6)) {
                    animatedPercent = currentPercent
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    animatedPercent = 0
                }
            }
        }
        .onAppear {
            if isConnected {
                withAnimation(.easeOut(duration: 0.6)) {
                    animatedPercent = currentPercent
                }
            }
        }
    }
}

/// Grayed-out placeholder bar shown when no Dot is available (disconnected, not yet created).
struct MiniBarPlaceholder: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }
}
