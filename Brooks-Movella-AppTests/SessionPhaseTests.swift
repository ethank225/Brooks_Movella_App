import XCTest
@testable import Brooks_Movella_App

final class SessionPhaseTests: XCTestCase {

    // MARK: - isBusy

    func testIsBusyTrueForSyncing() {
        XCTAssertTrue(SessionPhase.syncing.isBusy)
    }

    func testIsBusyTrueForStartingRecording() {
        XCTAssertTrue(SessionPhase.startingRecording.isBusy)
    }

    func testIsBusyTrueForStoppingRecording() {
        XCTAssertTrue(SessionPhase.stoppingRecording.isBusy)
    }

    func testIsBusyFalseForIdle() {
        XCTAssertFalse(SessionPhase.idle.isBusy)
    }

    func testIsBusyFalseForRecording() {
        XCTAssertFalse(SessionPhase.recording.isBusy)
    }

    func testIsBusyFalseForError() {
        XCTAssertFalse(SessionPhase.error("oops").isBusy)
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
