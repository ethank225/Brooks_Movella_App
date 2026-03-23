import SwiftUI

struct ResearcherModeRecordView: View {
    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var runnerStore = RunnerStore.shared

    @State private var selectedDotId: String? = nil
    /// Runner whose empty slot was tapped (slot-first flow). Mutually exclusive with selectedDotId.
    @State private var selectedSlotRunnerId: String? = nil
    @State private var showInitializingAlert = false

    /// Runners to display — excludes the single-runner-mode ephemeral runner.
    private var runners: [Runner] {
        runnerStore.runners.filter { $0.id != DotManager.singleRunnerID }
    }

    /// Connected sensors not assigned to any multi-runner runner.
    private var availableDots: [Dot] {
        let allAssigned = Set(runners.flatMap { $0.sensorUuids })
        return manager.connectedDots.filter { !allAssigned.contains($0.address) }
    }

    /// Whether the selected dot is currently assigned to some runner (not in the pool).
    private var selectedIsAssigned: Bool {
        guard let id = selectedDotId else { return false }
        return runners.contains { $0.sensorUuids.contains(id) }
    }

    /// The runner that currently owns the selected dot, if any.
    private var sourceRunner: Runner? {
        guard let id = selectedDotId else { return nil }
        return runners.first { $0.sensorUuids.contains(id) }
    }

    /// Connected sensors assigned to a specific runner.
    private func assignedDots(for runner: Runner) -> [Dot] {
        runner.sensorUuids.compactMap { uuid in
            manager.connectedDots.first { $0.address == uuid }
        }
    }

    /// Phase for a runner, defaulting to idle.
    private func phase(for runner: Runner) -> SessionPhase {
        manager.runnerPhases[runner.id] ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            AvailableDots(
                dots: availableDots,
                selectedDotId: selectedDotId,
                selectedIsAssigned: selectedIsAssigned,
                slotIsActive: selectedSlotRunnerId != nil,
                onTapDot: { dot in
                    // Slot-first: a slot is waiting, assign this dot there
                    if let runnerId = selectedSlotRunnerId {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            runnerStore.assignSensor(uuid: dot.address, to: runnerId)
                            selectedSlotRunnerId = nil
                        }
                        return
                    }
                    // Dot-first: toggle selection
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if selectedDotId == dot.address {
                            selectedDotId = nil
                        } else {
                            selectedDotId = dot.address
                            selectedSlotRunnerId = nil
                        }
                    }
                },
                onReturnToPool: {
                    guard let uuid = selectedDotId,
                          let source = sourceRunner else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        runnerStore.unassignSensor(uuid: uuid, from: source.id)
                        selectedDotId = nil
                    }
                }
            )
            .padding(.top, 8)

            if manager.isErasing {
                ErasingBanner()
                    .padding(.horizontal)
            }

            runnerList
        }
        .alert("Sensors Initializing", isPresented: $showInitializingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Some sensors are still initializing. Please wait until all sensors are ready.")
        }
    }

    // MARK: - Runner List

    private var runnerList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                ForEach(runners) { runner in
                    runnerCard(for: runner)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }

                AddRunnerButton {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        _ = runnerStore.addRunner(label: "")
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if selectedDotId != nil { selectedDotId = nil }
                if selectedSlotRunnerId != nil { selectedSlotRunnerId = nil }
            }
        }
    }

    private func runnerCard(for runner: Runner) -> some View {
        RunnerCard(
            runner: runner,
            phase: phase(for: runner),
            assignedDots: assignedDots(for: runner),
            hasAvailableDots: !availableDots.isEmpty,
            isStartDisabled: (manager.isAnySyncing && phase(for: runner) != .syncing) || manager.isErasing,
            selectedDotId: selectedDotId,
            isSlotSelected: selectedSlotRunnerId == runner.id,
            onPlaceDot: {
                guard let uuid = selectedDotId else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    // If the dot is assigned to another runner, move it
                    if let source = sourceRunner, source.id != runner.id {
                        runnerStore.unassignSensor(uuid: uuid, from: source.id)
                    }
                    runnerStore.assignSensor(uuid: uuid, to: runner.id)
                    selectedDotId = nil
                }
            },
            onCancelSelection: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedDotId = nil
                    selectedSlotRunnerId = nil
                }
            },
            onSelectSlot: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if selectedSlotRunnerId == runner.id {
                        selectedSlotRunnerId = nil
                    } else {
                        selectedSlotRunnerId = runner.id
                        selectedDotId = nil
                    }
                }
            },
            onSelectDot: { uuid in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if selectedDotId == uuid {
                        selectedDotId = nil
                    } else {
                        selectedDotId = uuid
                        selectedSlotRunnerId = nil
                    }
                }
            },
            onUnassign: { uuid in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    runnerStore.unassignSensor(uuid: uuid, from: runner.id)
                }
            },
            onStart: {
                let allReady = assignedDots(for: runner).allSatisfy { $0.connectionPhase == .ready }
                if !allReady {
                    showInitializingAlert = true
                } else {
                    manager.beginSession(runnerId: runner.id)
                }
            },
            onStop: {
                manager.endSession(runnerId: runner.id)
            },
            onRemove: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    runnerStore.removeRunner(id: runner.id)
                    selectedDotId = nil
                    selectedSlotRunnerId = nil
                }
            },
            onRename: { newName in
                runnerStore.updateLabel(runnerId: runner.id, label: newName)
            },
            onDismissError: {
                manager.dismissError(runnerId: runner.id)
            }
        )
    }
}

#Preview {
    ResearcherModeRecordView()
}
