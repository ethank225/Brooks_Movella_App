import SwiftUI

struct ResearcherModeRecordView: View {
    @ObservedObject private var manager = DotManager.shared
    @ObservedObject private var runnerStore = RunnerStore.shared

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
                onReturnToPool: { uuid in
                    // Find which runner owns this dot and unassign
                    if let source = runners.first(where: { $0.sensorUuids.contains(uuid) }) {
                        runnerStore.unassignSensor(uuid: uuid, from: source.id)
                    }
                }
            )
            .padding(.top, 8)

            if manager.isErasing {
                ErasingBanner()
                    .padding(.horizontal)
                    .transition(AppAnimation.bannerTransition)
            } else if manager.hasFlashIssue {
                FlashIssueBanner(isErasingFromPreviousSession: manager.isAnyErasingFromPreviousSession)
                    .padding(.horizontal)
                    .transition(AppAnimation.bannerTransition)
            }

            runnerList
        }
        .animation(AppAnimation.phase, value: manager.hasFlashIssue)
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
                        .transition(AppAnimation.cardTransition)
                }

                AddRunnerButton {
                    withAnimation(AppAnimation.interactive) {
                        _ = runnerStore.addRunner(label: "")
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
        }
    }

    private func runnerCard(for runner: Runner) -> some View {
        RunnerCard(
            runner: runner,
            phase: phase(for: runner),
            assignedDots: assignedDots(for: runner),
            hasAvailableDots: !availableDots.isEmpty,
            isStartDisabled: (manager.isAnySyncing && phase(for: runner) != .syncing) || manager.isErasing || manager.hasFlashIssue,
            onAssignDot: { uuid in
                runnerStore.assignSensor(uuid: uuid, to: runner.id)
            },
            onUnassign: { uuid in
                withAnimation(AppAnimation.interactive) {
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
                withAnimation(AppAnimation.interactive) {
                    runnerStore.removeRunner(id: runner.id)
                }
            },
            onRename: { newName in
                runnerStore.updateLabel(runnerId: runner.id, label: newName)
            },
            onDismissError: {
                manager.dismissError(runnerId: runner.id)
            },
            isSynced: assignedDots(for: runner).count >= 2 && assignedDots(for: runner).allSatisfy { $0.sessionSynced },
            isResyncing: phase(for: runner) == .syncing,
            onResync: {
                manager.resyncRunner(runnerId: runner.id)
            }
        )
    }
}

#Preview {
    ResearcherModeRecordView()
}
