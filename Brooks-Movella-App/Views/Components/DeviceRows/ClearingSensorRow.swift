import SwiftUI

/// Shown when the user initiates an erase and it's actively clearing flash storage.
struct ClearingSensorRow: View {
    let displayName: String

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top line — icon + name
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.system(size: 11))
                    .symbolEffect(.pulse)

                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }

            // Bottom line — message + indeterminate progress bar
            VStack(alignment: .leading, spacing: 6) {
                Text("Clearing flash storage")
                    .font(.caption)
                    .foregroundColor(.red)

                GeometryReader { geo in
                    let barWidth = geo.size.width * 0.3
                    Capsule()
                        .fill(Color.red.opacity(0.15))
                        .frame(height: 4)
                        .overlay(
                            Capsule()
                                .fill(Color.red.opacity(0.5))
                                .frame(width: barWidth, height: 4)
                                .offset(x: shimmerOffset * (geo.size.width - barWidth))
                        )
                        .clipShape(Capsule())
                }
                .frame(height: 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        shimmerOffset = 1
                    }
                }
            }
            .padding(.leading, 21)
        }
    }
}
