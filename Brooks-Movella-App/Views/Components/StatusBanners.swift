import SwiftUI

/// Pink spinner + "Erasing flash storage…" banner.
/// Parent controls visibility via `if manager.isErasing { ErasingBanner() }`.
struct ErasingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .pink))
                .scaleEffect(0.8)
            Text("Erasing flash storage…")
                .font(.subheadline)
                .foregroundColor(.pink)
            Spacer()
        }
        .padding()
        .background(Color.pink.opacity(0.1))
        .cornerRadius(8)
    }
}

/// Banner for flash issues — shows context-appropriate message for
/// mid-erase (pink spinner) or corruption (orange warning).
struct FlashIssueBanner: View {
    var isErasingFromPreviousSession: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isErasingFromPreviousSession {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .pink))
                    .scaleEffect(0.8)
                Text("Sensor finishing erase — please wait")
                    .font(.subheadline)
                    .foregroundColor(.pink)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Sensor storage corrupted — go to Connect to repair")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .padding()
        .background((isErasingFromPreviousSession ? Color.pink : Color.orange).opacity(0.1))
        .cornerRadius(8)
    }
}

/// Orange error banner with dismiss button.
struct SessionErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.orange)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}
