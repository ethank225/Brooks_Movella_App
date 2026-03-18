import SwiftUI

// MARK: - Empty Dot Slot

private struct EmptyDotSlot: View {
    var isHighlighted: Bool
    var onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isHighlighted
                  ? Color.blue.opacity(pulse ? 0.12 : 0.04)
                  : Color.clear)
            .frame(width: 92, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isHighlighted ? Color.blue : Color.gray.opacity(0.25),
                        style: isHighlighted
                            ? StrokeStyle(lineWidth: 2)
                            : StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .overlay(
                Image(systemName: isHighlighted ? "plus.circle.fill" : "plus")
                    .font(.caption)
                    .foregroundColor(isHighlighted ? .blue : Color.gray.opacity(0.3))
            )
            .onTapGesture(perform: onTap)
            .onAppear {
                if isHighlighted { startPulse() }
            }
            .onChange(of: isHighlighted) { highlighted in
                if highlighted { startPulse() } else { pulse = false }
            }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Runner Card

struct RunnerCard: View {
    @Binding var runner: RunnerModel
    var selectedDot: MockDot?
    var onPlaceDot: (MockDot) -> Void
    var onCancelSelection: () -> Void
    var onUnassign: (MockDot) -> Void
    var onStart: () -> Void
    var onStop: () -> Void
    var onRemove: () -> Void

    private var isValidPlacementTarget: Bool {
        selectedDot != nil && runner.status == .new && runner.assignedDots.count < 3
    }

    private var borderColor: Color {
        if isValidPlacementTarget { return .blue }
        switch runner.status {
        case .new:   return Color.blue.opacity(0.4)
        case .ready: return .green
        case .rec:   return .red
        }
    }

    private var avatarColor: Color {
        switch runner.status {
        case .new:   return .blue
        case .ready: return .green
        case .rec:   return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            dotsRow
            actionArea
        }
        .padding()
        .background(
            isValidPlacementTarget
                ? Color.blue.opacity(0.04)
                : Color(.secondarySystemBackground)
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: isValidPlacementTarget ? 2 : 1.5)
        )
        .animation(.easeInOut(duration: 0.25), value: runner.status)
        .animation(.easeInOut(duration: 0.2), value: isValidPlacementTarget)
        .padding(.horizontal)
        // Tapping a non-valid-target card while a dot is selected cancels selection
        .onTapGesture {
            if selectedDot != nil && !isValidPlacementTarget {
                onCancelSelection()
            }
        }
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                Text(runner.name.isEmpty ? "?" : String(runner.name.prefix(1)).uppercased())
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(avatarColor)
            }

            if runner.status == .new {
                TextField("Runner name", text: $runner.name)
                    .font(.headline)
            } else {
                Text(runner.name.isEmpty ? "Runner" : runner.name)
                    .font(.headline)
            }

            Spacer()

            if runner.status != .rec {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            statusBadge
        }
    }

    private var dotsRow: some View {
        HStack(spacing: 8) {
            ForEach(runner.assignedDots) { dot in
                DotChip(
                    dot: dot,
                    onUnassign: (runner.status == .new || runner.status == .ready) ? { onUnassign(dot) } : nil
                )
            }
            ForEach(runner.assignedDots.count..<3, id: \.self) { _ in
                EmptyDotSlot(isHighlighted: isValidPlacementTarget) {
                    if let dot = selectedDot, runner.status == .new {
                        onPlaceDot(dot)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch runner.status {
        case .new:   StatusTag(text: "new",   isActive: true, color: .blue)
        case .ready: StatusTag(text: "ready", isActive: true, color: .green)
        case .rec:   StatusTag(text: "rec",   isActive: true, color: .red)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch runner.status {
        case .new:
            Text(runner.assignedDots.isEmpty
                 ? "Select a DOT above, then tap an empty slot"
                 : "\(3 - runner.assignedDots.count) more DOT\(3 - runner.assignedDots.count == 1 ? "" : "s") needed")
                .font(.caption)
                .foregroundColor(.secondary)
        case .ready:
            Button(action: onStart) {
                Label(
                    "Start \(runner.name.isEmpty ? "Runner" : runner.name)",
                    systemImage: "play.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        case .rec:
            Button(action: onStop) {
                Label(
                    "Stop \(runner.name.isEmpty ? "Runner" : runner.name)",
                    systemImage: "stop.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }
}
