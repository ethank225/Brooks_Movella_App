import XCTest
@testable import Brooks_Movella_App

final class SessionPhaseTests: XCTestCase {

    // MARK: - isTransitioning

    func testIsTransitioningTrueForSyncing() {
        XCTAssertTrue(SessionPhase.syncing.isTransitioning)
    }

    func testIsTransitioningTrueForStartingRecording() {
        XCTAssertTrue(SessionPhase.startingRecording.isTransitioning)
    }

    func testIsTransitioningTrueForStoppingRecording() {
        XCTAssertTrue(SessionPhase.stoppingRecording.isTransitioning)
    }

    func testIsTransitioningFalseForIdle() {
        XCTAssertFalse(SessionPhase.idle.isTransitioning)
    }

    func testIsTransitioningFalseForRecording() {
        XCTAssertFalse(SessionPhase.recording.isTransitioning)
    }

    func testIsTransitioningFalseForError() {
        XCTAssertFalse(SessionPhase.error("oops").isTransitioning)
    }

    // MARK: - isError

    func testIsErrorTrueOnlyForErrorCase() {
        XCTAssertTrue(SessionPhase.error("fail").isError)
        XCTAssertFalse(SessionPhase.idle.isError)
        XCTAssertFalse(SessionPhase.syncing.isError)
        XCTAssertFalse(SessionPhase.recording.isError)
    }

    // MARK: - isSyncActive

    func testIsSyncActiveTrueOnlyForSyncing() {
        XCTAssertTrue(SessionPhase.syncing.isSyncActive)
        XCTAssertFalse(SessionPhase.idle.isSyncActive)
        XCTAssertFalse(SessionPhase.recording.isSyncActive)
        XCTAssertFalse(SessionPhase.error("x").isSyncActive)
    }
}
