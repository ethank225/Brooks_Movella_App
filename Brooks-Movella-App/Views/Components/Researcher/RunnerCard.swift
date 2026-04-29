import SwiftUI

// MARK: - Empty Dot Slot

private struct EmptyDotSlot: View {
    var onDrop: (String) -> Void

    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isTargeted ? Color.blue.opacity(0.12) : Color.clear)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isTargeted ? Color.blue : Color.gray.opacity(0.25),
                        style: isTargeted
                            ? StrokeStyle(lineWidth: 2)
                            : StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .overlay(
                Image(systemName: isTargeted ? "plus.circle.fill" : "plus")
                    .font(.caption)
                    .foregroundColor(isTargeted ? .blue : Color.gray.opacity(0.3))
            )
            // Expand the hit area well beyond the visible slot
            .padding(12)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let uuid = items.first else { return false }
                onDrop(uuid)
                return true
            } isTargeted: { targeted in
                withAnimation(AppAnimation.dropFeedback) { isTargeted = targeted }
            }
            // Remove the extra padding from layout so slot still looks 92x52
            .padding(-12)
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
    var onAssignDot: (String) -> Void
    var onUnassign: (String) -> Void
    var onStart: () -> Void
    var onStop: () -> Void
    var onRemove: () -> Void
    var onRename: (String) -> Void
    var onDismissError: () -> Void
    var isSynced: Bool
    var isResyncing: Bool
    var onResync: () -> Void

    @State private var showDeleteConfirm = false
    @State private var showUnassignConfirm = false
    @State private var pendingUnassignUuid: String?
    @State private var syncBorderPulse = false

    private var canModify: Bool {
        phase == .idle || phase.isError
    }

    private var allDotsReady: Bool {
        !assignedDots.isEmpty && assignedDots.allSatisfy { $0.connectionPhase == .ready }
    }

    private var needsSync: Bool {
        assignedDots.count >= 2 && !assignedDots.allSatisfy { $0.sessionSynced }
    }

    // MARK: - Status Display

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

    private var isSyncingPhase: Bool {
        phase == .syncing || isResyncing
    }

    private var borderColor: Color {
        switch phase {
        case .syncing:                              return .blue
        case .startingRecording, .stoppingRecording: return .blue
        case .recording:                            return .red
        case .idle, .error:
            if assignedDots.isEmpty { return .blue.opacity(0.4) }
            if isResyncing { return .blue }
            if needsSync { return .orange }
            return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            dotsRow
            actionArea
        }
        .padding(.vertical)
        .padding(.horizontal, 20)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 1.5)
                .opacity(isSyncingPhase ? (syncBorderPulse ? 1.0 : 0.35) : 1.0)
        )
        .animation(AppAnimation.content, value: phase)
        .onChange(of: isSyncingPhase) { syncing in
            if syncing {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    syncBorderPulse = true
                }
            } else {
                syncBorderPulse = false
            }
        }
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

            // Trailing icons — always rendered to reserve space, hidden via opacity
            HStack(spacing: 16) {
                // Sync status icon
                ZStack {
                    if isResyncing {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: isSynced ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(isSynced ? .green : .orange)
                    }
                }
                .frame(width: 14, height: 14)
                .opacity(assignedDots.count >= 2 ? 1 : 0)

                // Resync button
                Button(action: onResync) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14))
                        .foregroundColor(canModify && isSynced && !isSyncingPhase ? .blue : .gray.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(!canModify || !isSynced || assignedDots.count < 2)
                .opacity(assignedDots.count >= 2 ? 1 : 0)

                // Trash button
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(isSyncingPhase ? .gray.opacity(0.3) : .red.opacity(0.6))
                }
                .buttonStyle(.plain)
                .opacity(canModify || isSyncingPhase ? 1 : 0)
                .disabled(!canModify || isSyncingPhase)
            }
        }
        .frame(height: 44)
    }

    @State private var dotsRowTargeted = false

    private var dotsRow: some View {
        let emptyCount = max(0, 3 - assignedDots.count)
        let hasEmptySlots = emptyCount > 0 && canModify
        return HStack(spacing: 8) {
            ForEach(assignedDots, id: \.address) { dot in
                DotChip(
                    dot: dot,
                    isDraggable: canModify,
                    onUnassign: canModify ? {
                        pendingUnassignUuid = dot.address
                        showUnassignConfirm = true
                    } : nil
                )
                .frame(minWidth: 0, maxWidth: .infinity)
                .transition(AppAnimation.chipTransition)
            }
            if emptyCount > 0 {
                ForEach(0..<emptyCount, id: \.self) { _ in
                    EmptyDotSlot { uuid in
                        withAnimation(AppAnimation.interactive) {
                            onAssignDot(uuid)
                        }
                    }
                    .allowsHitTesting(canModify)
                    .opacity(canModify ? 1.0 : 0.5)
                    .transition(.identity)
                    .animation(.none, value: assignedDots.map(\.address))
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Whole row is a fallback drop target when there are empty slots
        .dropDestination(for: String.self) { items, _ in
            guard hasEmptySlots, let uuid = items.first else { return false }
            // Don't re-assign a dot already on this runner
            guard !assignedDots.contains(where: { $0.address == uuid }) else { return false }
            withAnimation(AppAnimation.interactive) {
                onAssignDot(uuid)
            }
            return true
        } isTargeted: { targeted in
            guard hasEmptySlots else { return }
            withAnimation(AppAnimation.dropFeedback) { dotsRowTargeted = targeted }
        }
        .animation(AppAnimation.interactive, value: assignedDots.map(\.address))
    }

    // MARK: - Action Button State

    private var actionLabel: String {
        switch phase {
        case .idle:
            if assignedDots.isEmpty { return "No Sensors" }
            if !allDotsReady { return "Initializing..." }
            if isResyncing { return "Syncing..." }
            if needsSync { return "Sync Sensors" }
            return "Start \(runner.label.isEmpty ? "Runner" : runner.label)"
        case .syncing:             return "Syncing..."
        case .startingRecording:   return "Starting..."
        case .recording:           return "Stop \(runner.label.isEmpty ? "Runner" : runner.label)"
        case .stoppingRecording:   return "Stopping..."
        case .error:
            if needsSync { return "Sync Sensors" }
            return "Retry"
        }
    }

    private var actionIcon: String {
        switch phase {
        case .recording:    return "stop.fill"
        case .error:        return needsSync ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
        case .idle:
            if needsSync { return "arrow.triangle.2.circlepath" }
            return "play.fill"
        default:            return ""
        }
    }

    private var actionColor: Color {
        switch phase {
        case .idle:
            if assignedDots.isEmpty || !allDotsReady || isResyncing { return .gray }
            if isStartDisabled { return .gray }
            if needsSync { return .orange }
            return .green
        case .recording:
            return allDotsReady ? .red : .gray
        case .error:
            if isStartDisabled { return .gray }
            return needsSync ? .orange : .green
        default:
            return .gray
        }
    }

    private var actionDisabled: Bool {
        switch phase {
        case .idle:
            return assignedDots.isEmpty || !allDotsReady || isResyncing || isStartDisabled
        case .recording:
            return !allDotsReady
        case .error:
            return !allDotsReady || isStartDisabled
        default:
            return true
        }
    }

    private var actionShowsSpinner: Bool {
        switch phase {
        case .syncing, .startingRecording, .stoppingRecording: return true
        case .idle: return isResyncing || (!allDotsReady && !assignedDots.isEmpty)
        default: return false
        }
    }

    private func handleAction() {
        switch phase {
        case .idle:
            if needsSync { onResync() }
            else { onStart() }
        case .recording:
            onStop()
        case .error:
            if needsSync { onResync() }
            else { onStart() }
        default:
            break
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        // Error banner (above the fixed button)
        if case .error(let msg) = phase {
            SessionErrorBanner(message: msg, onDismiss: onDismissError)
        }

        // Fixed-height action button — always present
        Button(action: handleAction) {
            HStack(spacing: 6) {
                if actionShowsSpinner {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else if !actionIcon.isEmpty {
                    Image(systemName: actionIcon)
                }
                Text(actionLabel)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(actionColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(actionDisabled)
    }
}
