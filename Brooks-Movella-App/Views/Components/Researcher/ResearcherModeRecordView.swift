import SwiftUI
import Combine

// MARK: - Models

enum RunnerStatus: Equatable {
    case new, ready, rec
}

struct MockDot: Identifiable {
    var id: String          // e.g. "9F1E·3C88"
    var storagePercent: Int // 0–100
}

struct RunnerModel: Identifiable {
    let id: UUID = UUID()
    var name: String
    var status: RunnerStatus
    var assignedDots: [MockDot]
}

// MARK: - Session State

final class ResearcherSessionState: ObservableObject {
    @Published var runners: [RunnerModel] = []

    @Published var availableDots: [MockDot] = [
        MockDot(id: "4DD3·B9D6", storagePercent: 12),
        MockDot(id: "23A5·F670", storagePercent: 24),
        MockDot(id: "E495·652F", storagePercent: 79),
        MockDot(id: "7B2C·A1D4", storagePercent: 8),
        MockDot(id: "9F1E·3C88", storagePercent: 5),
        MockDot(id: "C72B·04AF", storagePercent: 18)
    ]

    var liveCount: Int { runners.filter { $0.status == .rec }.count }

    func assign(_ dot: MockDot, to runnerID: UUID) {
        guard let i = runners.firstIndex(where: { $0.id == runnerID }),
              runners[i].status == .new,
              runners[i].assignedDots.count < 3 else { return }
        availableDots.removeAll { $0.id == dot.id }
        runners[i].assignedDots.append(dot)
        if runners[i].assignedDots.count == 3 {
            runners[i].status = .ready
        }
    }

    func unassign(_ dot: MockDot, from runnerID: UUID) {
        guard let i = runners.firstIndex(where: { $0.id == runnerID }),
              runners[i].status == .new || runners[i].status == .ready else { return }
        runners[i].assignedDots.removeAll { $0.id == dot.id }
        availableDots.append(dot)
        // Revert to .new if dots are now incomplete
        if runners[i].assignedDots.count < 3 {
            runners[i].status = .new
        }
    }

    func start(runnerID: UUID) {
        guard let i = runners.firstIndex(where: { $0.id == runnerID }),
              runners[i].status == .ready else { return }
        runners[i].status = .rec
    }

    func stop(runnerID: UUID) {
        guard let i = runners.firstIndex(where: { $0.id == runnerID }),
              runners[i].status == .rec else { return }
        runners[i].status = .ready
    }

    func removeRunner(id: UUID) {
        guard let i = runners.firstIndex(where: { $0.id == id }) else { return }
        availableDots.append(contentsOf: runners[i].assignedDots)
        runners.remove(at: i)
    }

    func addRunner() {
        runners.append(RunnerModel(name: "", status: .new, assignedDots: []))
    }
}

// MARK: - View

struct ResearcherModeRecordView: View {
    @ObservedObject var state: ResearcherSessionState
    @State private var selectedDot: MockDot? = nil

    var body: some View {
        VStack(spacing: 0) {
            AvailableDots(
                dots: state.availableDots,
                selectedDot: selectedDot,
                onTapDot: { dot in
                    // Re-tap selected chip → cancel; otherwise select
                    if selectedDot?.id == dot.id {
                        selectedDot = nil
                    } else {
                        selectedDot = dot
                    }
                }
            )
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($state.runners) { $runner in
                        RunnerCard(
                            runner: $runner,
                            selectedDot: selectedDot,
                            onPlaceDot: { dot in
                                state.assign(dot, to: runner.id)
                                selectedDot = nil
                            },
                            onCancelSelection: { selectedDot = nil },
                            onUnassign: { dot in state.unassign(dot, from: runner.id) },
                            onStart:    { state.start(runnerID: runner.id) },
                            onStop:     { state.stop(runnerID: runner.id) },
                            onRemove: {
                                state.removeRunner(id: runner.id)
                                selectedDot = nil
                            }
                        )
                    }

                    AddRunnerButton { state.addRunner() }
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                }
                .padding(.top, 12)
            }
            // Tapping the scroll background cancels selection
            .simultaneousGesture(TapGesture().onEnded {
                if selectedDot != nil { selectedDot = nil }
            })
        }
    }
}

#Preview {
    ResearcherModeRecordView(state: ResearcherSessionState())
}
