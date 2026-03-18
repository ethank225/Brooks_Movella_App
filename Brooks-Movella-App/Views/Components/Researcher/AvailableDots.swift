import SwiftUI

struct AvailableDots: View {
    let dots: [MockDot]
    var selectedDot: MockDot? = nil
    var onTapDot: (MockDot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedDot != nil ? "TAP AN EMPTY SLOT TO PLACE" : "AVAILABLE DOTS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(selectedDot != nil ? .blue : .secondary)
                .padding(.horizontal)
                .animation(.easeInOut(duration: 0.2), value: selectedDot != nil)

            if dots.isEmpty {
                Text("All DOTs assigned")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dots) { dot in
                            let isThisSelected = selectedDot?.id == dot.id
                            Button { onTapDot(dot) } label: {
                                DotChip(dot: dot, isSelected: isThisSelected)
                                    .opacity(
                                        selectedDot != nil && !isThisSelected ? 0.45 : 1.0
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
        }
    }
}
