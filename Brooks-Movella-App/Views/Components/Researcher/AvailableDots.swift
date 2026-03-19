import SwiftUI

struct AvailableDots: View {
    let dots: [Dot]
    let selectedDotId: String?
    /// True when the selected dot is currently assigned to a runner (not in the pool).
    let selectedIsAssigned: Bool
    /// True when an empty slot in a runner card is waiting for a dot to be tapped.
    let slotIsActive: Bool
    let onTapDot: (Dot) -> Void
    /// Called when the user taps the pool area to return an assigned dot.
    let onReturnToPool: () -> Void

    init(
        dots: [Dot],
        selectedDotId: String? = nil,
        selectedIsAssigned: Bool = false,
        slotIsActive: Bool = false,
        onTapDot: @escaping (Dot) -> Void,
        onReturnToPool: @escaping () -> Void = {}
    ) {
        self.dots = dots
        self.selectedDotId = selectedDotId
        self.selectedIsAssigned = selectedIsAssigned
        self.slotIsActive = slotIsActive
        self.onTapDot = onTapDot
        self.onReturnToPool = onReturnToPool
    }

    private var headerText: String {
        if slotIsActive {
            return "TAP A DOT TO ASSIGN"
        } else if selectedIsAssigned {
            return "TAP HERE TO UNASSIGN"
        } else if selectedDotId != nil {
            return "TAP AN EMPTY SLOT TO PLACE"
        }
        return "AVAILABLE DOTS"
    }

    private var headerColor: Color {
        (selectedDotId != nil || slotIsActive) ? .blue : .secondary
    }

    /// Show the pool as a drop target when a runner-assigned dot is selected.
    private var isDropTarget: Bool {
        selectedIsAssigned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerText)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(headerColor)
                .padding(.horizontal)
                .animation(.easeInOut(duration: 0.2), value: selectedDotId != nil)
                .animation(.easeInOut(duration: 0.2), value: selectedIsAssigned)
                .animation(.easeInOut(duration: 0.2), value: slotIsActive)

            if dots.isEmpty && !isDropTarget && !slotIsActive {
                Text("All DOTs assigned")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            } else if dots.isEmpty && slotIsActive {
                Text("No available DOTs to assign")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if isDropTarget {
                            returnToPoolSlot
                        }
                        ForEach(dots, id: \.address) { dot in
                            let isThisSelected = selectedDotId == dot.address
                            DotChip(
                                dot: dot,
                                isSelected: isThisSelected || slotIsActive,
                                onTap: { onTapDot(dot) }
                            )
                            .opacity(
                                selectedDotId != nil && !isThisSelected ? 0.45 : 1.0
                            )
                            .transition(.asymmetric(
                                insertion: .scale.combined(with: .opacity),
                                removal: .scale.combined(with: .opacity)
                            ))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dots.map(\.address))
                }
            }
        }
    }

    private var returnToPoolSlot: some View {
        Button(action: onReturnToPool) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.08))
                .frame(width: 92, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.blue, lineWidth: 2)
                )
                .overlay(
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("Unassign")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                )
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}
