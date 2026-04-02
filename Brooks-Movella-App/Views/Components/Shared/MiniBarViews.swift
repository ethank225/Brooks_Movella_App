import SwiftUI

/// Diagonal stripe pattern used to indicate an unavailable/blocked bar state.
private struct DiagonalStripes: Shape {
    /// Spacing between stripe centers.
    let spacing: CGFloat
    /// Width of each stripe.
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Draw enough diagonal lines to cover the rect, extending beyond
        // bounds so the pattern fills even after the 45° rotation.
        let count = Int((rect.width + rect.height) / spacing) + 1
        for i in 0..<count {
            let x = CGFloat(i) * spacing - rect.height
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        }
        return path.strokedPath(.init(lineWidth: lineWidth))
    }
}

/// Live-updating mini bar that observes a Dot's published properties.
struct LiveMiniBar: View {
    let label: String
    @ObservedObject var dot: Dot
    /// Key path into Dot for the percentage (0–100).
    let valueKeyPath: KeyPath<Dot, Double>
    let colorFor: (Double) -> Color
    let isConnected: Bool
    var dataAvailable: Bool = true

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
                    if dataAvailable {
                        Text(String(format: "%.1f%%", currentPercent))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    } else {
                        Text("—")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.5))
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeOut(duration: 0.6), value: dataAvailable)

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 8)

                if isConnected && dataAvailable {
                    // Normal colored fill
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorFor(animatedPercent))
                            .frame(width: geo.size.width * min(max(animatedPercent / 100, 0), 1.0))
                    }
                    .frame(height: 8)
                    .transition(.opacity)
                } else if isConnected && !dataAvailable {
                    // Striped hatched pattern — visually distinct "blocked" state
                    DiagonalStripes(spacing: 5, lineWidth: 2)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.6), value: dataAvailable)
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
        .onChange(of: dataAvailable) { available in
            if available {
                withAnimation(.easeOut(duration: 0.6)) {
                    animatedPercent = currentPercent
                }
            }
        }
        .onAppear {
            if isConnected && dataAvailable {
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
