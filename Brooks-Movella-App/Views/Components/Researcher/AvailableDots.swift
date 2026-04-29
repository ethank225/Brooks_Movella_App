import SwiftUI

struct AvailableDots: View {
    let dots: [Dot]
    /// Called when a dot is dropped on the pool area to unassign it.
    let onReturnToPool: (String) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AVAILABLE DOTS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(isDropTargeted ? .blue : .secondary)
                .padding(.horizontal)

            if dots.isEmpty {
                Text("All DOTs assigned")
                    .font(.caption)
                    .foregroundColor(isDropTargeted ? .blue : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dots, id: \.address) { dot in
                            DotChip(
                                dot: dot,
                                isDraggable: true
                            )
                            .frame(width: 100)
                            .transition(AppAnimation.chipTransition)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .animation(AppAnimation.interactive, value: dots.map(\.address))
                }
            }
        }
        // Visible highlight when dragging over
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(isDropTargeted ? 0.08 : 0))
                .padding(.horizontal, 4)
        )
        // The entire pool area is a drop target for unassigning dots
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let uuid = items.first else { return false }
            // Only accept drops of dots that are assigned (not already in pool)
            let isInPool = dots.contains { $0.address == uuid }
            guard !isInPool else { return false }
            withAnimation(AppAnimation.interactive) {
                onReturnToPool(uuid)
            }
            return true
        } isTargeted: { targeted in
            withAnimation(AppAnimation.dropFeedback) { isDropTargeted = targeted }
        }
    }
}
