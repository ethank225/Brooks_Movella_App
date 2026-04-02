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
    let runner: Runner
    let phase: SessionPhase
    let assignedDots: [Dot]
    let hasAvailableDots: Bool
    /// Disables start/retry buttons (e.g. when another runner is syncing).
    let isStartDisabled: Bool
    var selectedDotId: String?
    var isSlotSelected: Bool
    var onPlaceDot: () -> Void
    var onCancelSelection: () -> Void
    var onSelectSlot: () -> Void
    var onSelectDot: (String) -> Void
    var onUnassign: (String) -> Void
    var onStart: () -> Void
    var onStop: () -> Void
    var onRemove: () -> Void
    var onRename: (String) -> Void
    var onDismissError: () -> Void

    init(
        runner: Runner,
        phase: SessionPhase,
        assignedDots: [Dot],
        hasAvailableDots: Bool,
        isStartDisabled: Bool = false,
        selectedDotId: String? = nil,
        isSlotSelected: Bool = false,
        onPlaceDot: @escaping () -> Void,
        onCancelSelection: @escaping () -> Void,
        onSelectSlot: @escaping () -> Void = {},
        onSelectDot: @escaping (String) -> Void,
        onUnassign: @escaping (String) -> Void,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onDismissError: @escaping () -> Void
    ) {
        self.runner = runner
        self.phase = phase
        self.assignedDots = assignedDots
        self.hasAvailableDots = hasAvailableDots
        self.isStartDisabled = isStartDisabled
        self.selectedDotId = selectedDotId
        self.isSlotSelected = isSlotSelected
        self.onPlaceDot = onPlaceDot
        self.onCancelSelection = onCancelSelection
        self.onSelectSlot = onSelectSlot
        self.onSelectDot = onSelectDot
        self.onUnassign = onUnassign
        self.onStart = onStart
        self.onStop = onStop
        self.onRemove = onRemove
        self.onRename = onRename
        self.onDismissError = onDismissError
    }

    @State private var showDeleteConfirm = false
    @State private var showUnassignConfirm = false
    @State private var pendingUnassignUuid: String?

    private var canModify: Bool {
        phase == .idle || phase.isError
    }

    private var allDotsReady: Bool {
        !assignedDots.isEmpty && assignedDots.allSatisfy { $0.connectionPhase == .ready }
    }

    private var isValidPlacementTarget: Bool {
        selectedDotId != nil && canModify && !selectedDotIsHere
    }

    // MARK: - Status Display

    private var statusText: String {
        switch phase {
        case .idle:
            return assignedDots.isEmpty ? "New" : "Ready"
        case .syncing:             return "Syncing"
        case .startingRecording:   return "Starting"
        case .recording:           return "Rec"
        case .stoppingRecording:   return "Stopping"
        case .error:               return "Error"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .idle:
            return assignedDots.isEmpty ? .blue : .green
        case .syncing, .startingRecording, .stoppingRecording:
            return .blue
        case .recording:           return .red
        case .error:               return .orange
        }
    }

    private var borderColor: Color {
        if isValidPlacementTarget { return .blue }
        return statusColor.opacity(phase == .idle && assignedDots.isEmpty ? 0.4 : 1.0)
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
        .animation(.easeInOut(duration: 0.25), value: phase)
        .animation(.easeInOut(duration: 0.2), value: isValidPlacementTarget)
        .padding(.horizontal)
        .alert("Delete Runner?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onRemove() }
        } message: {
            if phase == .idle {
                Text("Are you sure you want to delete this runner?")
            } else {
                Text("This runner has an active session. Deleting it may orphan recordings. Are you sure?")
            }
        }
        .alert("Remove Sensor?", isPresented: $showUnassignConfirm) {
            Button("Cancel", role: .cancel) { pendingUnassignUuid = nil }
            Button("Remove", role: .destructive) {
                if let uuid = pendingUnassignUuid {
                    onUnassign(uuid)
                    pendingUnassignUuid = nil
                }
            }
        } message: {
            if phase == .idle {
                Text("Are you sure you want to remove this sensor?")
            } else {
                Text("This runner has an active session. Removing the sensor may orphan its recording.")
            }
        }
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                Text(runner.label.isEmpty ? "?" : String(runner.label.prefix(1)).uppercased())
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(statusColor)
            }

            if canModify {
                TextField("Runner name", text: Binding(
                    get: { runner.label },
                    set: { onRename($0) }
                ))
                .font(.headline)
            } else {
                Text(runner.label.isEmpty ? "Runner" : runner.label)
                    .font(.headline)
            }

            Spacer()

            if canModify {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            StatusTag(text: statusText, isActive: true, color: statusColor)
        }
    }

    /// Whether the selected dot is assigned to this runner.
    private var selectedDotIsHere: Bool {
        guard let id = selectedDotId else { return false }
        return assignedDots.contains { $0.address == id }
    }

    /// Whether the empty slot should show a highlighted state.
    private var slotHighlighted: Bool {
        isValidPlacementTarget || isSlotSelected
    }

    private var dotsRow: some View {
        let emptyCount = max(0, 3 - assignedDots.count)
        return HStack(spacing: 8) {
            ForEach(assignedDots, id: \.address) { dot in
                let isThisSelected = selectedDotId == dot.address
                DotChip(
                    dot: dot,
                    isSelected: isThisSelected,
                    onTap: canModify ? { onSelectDot(dot.address) } : nil,
                    onUnassign: canModify ? {
                        pendingUnassignUuid = dot.address
                        showUnassignConfirm = true
                    } : nil
                )
                .opacity(selectedDotId != nil && !isThisSelected ? 0.45 : 1.0)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
            }
            if emptyCount > 0 {
                ForEach(0..<emptyCount, id: \.self) { _ in
                    EmptyDotSlot(
                        isHighlighted: canModify && slotHighlighted && !selectedDotIsHere
                    ) {
                        if selectedDotId != nil {
                            onPlaceDot()
                        } else {
                            onSelectSlot()
                        }
                    }
                    .allowsHitTesting(canModify && !selectedDotIsHere)
                    .opacity(canModify ? 1.0 : 0.5)
                    .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: assignedDots.map(\.address))
    }

    @ViewBuilder
    private var actionArea: some View {
        switch phase {
        case .idle:
            if assignedDots.isEmpty {
                Text("Select a DOT above, then tap an empty slot")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !allDotsReady {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Waiting for sensors to initialize...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: onStart) {
                    Label(
                        "Start \(runner.label.isEmpty ? "Runner" : runner.label)",
                        systemImage: "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isStartDisabled ? Color.gray : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isStartDisabled)
            }

        case .syncing:
            busyRow("Syncing clocks...")

        case .startingRecording:
            busyRow("Starting recording...")

        case .recording:
            Button(action: onStop) {
                Label(
                    "Stop \(runner.label.isEmpty ? "Runner" : runner.label)",
                    systemImage: "stop.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(allDotsReady ? Color.red : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(!allDotsReady)

        case .stoppingRecording:
            busyRow("Stopping recording...")

        case .error(let msg):
            VStack(spacing: 8) {
                SessionErrorBanner(message: msg, onDismiss: onDismissError)
                if allDotsReady {
                    Button(action: onStart) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isStartDisabled ? Color.gray : Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isStartDisabled)
                }
            }
        }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}
