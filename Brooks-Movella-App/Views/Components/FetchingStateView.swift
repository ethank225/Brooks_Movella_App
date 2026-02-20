import SwiftUI

struct FetchingStateView: View {
    let dots: [Dot]
    let loadedAddresses: Set<String>

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.1)
                Text("Fetching recordings…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            if dots.count > 1 {
                VStack(spacing: 8) {
                    ForEach(dots, id: \.address) { dot in
                        let loaded = loadedAddresses.contains(dot.address)
                        HStack(spacing: 8) {
                            if loaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.subheadline)
                            } else {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                    .frame(width: 16, height: 16)
                            }
                            Text("DOT \(String(dot.id))")
                                .font(.subheadline)
                                .foregroundColor(loaded ? .primary : .secondary)
                            Spacer()
                            Text(loaded ? "Ready" : "Loading…")
                                .font(.caption)
                                .foregroundColor(loaded ? .green : .secondary)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 8)
    }
}
