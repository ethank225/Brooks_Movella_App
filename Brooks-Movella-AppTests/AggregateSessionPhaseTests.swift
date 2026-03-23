import XCTest
@testable import Brooks_Movella_App

final class AggregateSessionPhaseTests: XCTestCase {

    func testAllIdleReturnsIdle() {
        let phases = ["r1": SessionPhase.idle, "r2": .idle]
        XCTAssertEqual(DotManager.aggregateSessionPhase(from: phases), .idle)
    }

    func testOneRecordingReturnsRecording() {
        let phases = ["r1": SessionPhase.recording, "r2": .idle]
        XCTAssertEqual(DotManager.aggregateSessionPhase(from: phases), .recording)
    }

    func testOneSyncingReturnsSyncing() {
        let phases = ["r1": SessionPhase.syncing, "r2": .idle]
        XCTAssertEqual(DotManager.aggregateSessionPhase(from: phases), .syncing)
    }

    func testSyncingTakesPriorityOverRecording() {
        let phases = ["r1": SessionPhase.syncing, "r2": .recording]
        XCTAssertEqual(DotManager.aggregateSessionPhase(from: phases), .syncing)
    }

    func testErrorBubblesUp() {
        let phases = ["r1": SessionPhase.error("sensor lost"), "r2": .idle]
        XCTAssertEqual(DotManager.aggregateSessionPhase(from: phases), .error("sensor lost"))
    }

    func testEmptyDictionaryReturnsIdle() {
        let phases: [String: SessionPhase] = [:]
        XCTAssertEqual(DotManager.aggregateSessionPhase(from: phases), .idle)
    }
}
