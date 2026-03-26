import SwiftUI

// MARK: - Shimmer Bar

/// Reusable indeterminate progress bar used across banners and device rows.
private struct ShimmerBar: View {
    var color: Color
    @State private var animating = false

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * 0.3
            Capsule()
                .fill(color.opacity(0.15))
                .frame(height: 4)
                .overlay(
                    Capsule()
                        .fill(color.opacity(0.5))
                        .frame(width: barWidth, height: 4)
                        .offset(x: animating
                                ? (geo.size.width - barWidth) / 2
                                : -(geo.size.width - barWidth) / 2)
                )
                .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
        }
    }
}

// MARK: - Erasing Banner

/// Red banner shown while a user-initiated erase is in progress.
/// Parent controls visibility via `if manager.isErasing { ErasingBanner() }`.
struct ErasingBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .symbolEffect(.pulse)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Erasing Flash Storage")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Do not disconnect sensors")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            ShimmerBar(color: .red)
        }
        .padding()
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Flash Issue Banner

/// Banner for flash issues — shows context-appropriate message for
/// mid-erase (pink) or corruption (orange warning).
struct FlashIssueBanner: View {
    var isErasingFromPreviousSession: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if isErasingFromPreviousSession {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.pink)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isErasingFromPreviousSession
                         ? "Sensor Finishing Erase"
                         : "Sensor Storage Corrupted")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(isErasingFromPreviousSession
                         ? "Started in a previous session — please wait"
                         : "Go to Connect tab to repair")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if isErasingFromPreviousSession {
                ShimmerBar(color: .pink)
            }
        }
        .padding()
        .background((isErasingFromPreviousSession ? Color.pink : Color.orange).opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    (isErasingFromPreviousSession ? Color.pink : Color.orange).opacity(0.15),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Session Error Banner

/// Orange error banner with dismiss button.
struct SessionErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.orange.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }
}
