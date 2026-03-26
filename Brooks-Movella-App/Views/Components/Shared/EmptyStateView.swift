import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let headline: String
    let subheadline: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(headline)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subheadline)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
