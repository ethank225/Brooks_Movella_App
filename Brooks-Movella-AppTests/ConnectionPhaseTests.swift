import XCTest
@testable import Brooks_Movella_App

final class ConnectionPhaseTests: XCTestCase {

    // MARK: - isBusy

    func testIsBusyTrueForConnecting() {
        XCTAssertTrue(ConnectionPhase.connecting.isBusy)
    }

    func testIsBusyTrueForInitializing() {
        XCTAssertTrue(ConnectionPhase.initializing.isBusy)
    }

    func testIsBusyFalseForIdle() {
        XCTAssertFalse(ConnectionPhase.idle.isBusy)
    }

    func testIsBusyFalseForReady() {
        XCTAssertFalse(ConnectionPhase.ready.isBusy)
    }

    func testIsBusyFalseForFailed() {
        XCTAssertFalse(ConnectionPhase.failed("timeout").isBusy)
    }

    // MARK: - isFailed

    func testIsFailedTrueOnlyForFailedCase() {
        XCTAssertTrue(ConnectionPhase.failed("err").isFailed)
        XCTAssertFalse(ConnectionPhase.idle.isFailed)
        XCTAssertFalse(ConnectionPhase.connecting.isFailed)
        XCTAssertFalse(ConnectionPhase.initializing.isFailed)
        XCTAssertFalse(ConnectionPhase.ready.isFailed)
    }

    // MARK: - isConnected

    func testIsConnectedTrueForInitializing() {
        XCTAssertTrue(ConnectionPhase.initializing.isConnected)
    }

    func testIsConnectedTrueForReady() {
        XCTAssertTrue(ConnectionPhase.ready.isConnected)
    }

    func testIsConnectedFalseForIdle() {
        XCTAssertFalse(ConnectionPhase.idle.isConnected)
    }

    func testIsConnectedFalseForConnecting() {
        XCTAssertFalse(ConnectionPhase.connecting.isConnected)
    }

    func testIsConnectedFalseForFailed() {
        XCTAssertFalse(ConnectionPhase.failed("err").isConnected)
    }
}
