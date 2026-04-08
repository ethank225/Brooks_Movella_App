import XCTest
@testable import Brooks_Movella_App

final class ExportManagerLogicTests: XCTestCase {

    // MARK: - validateRetry

    func testRetryBlockedWhenExporting() {
        let result = ExportManagerLogic.validateRetry(
            exportPhase: .exporting, isBusy: false, retryableCount: 1
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("in progress"))
    }

    func testRetryBlockedWhenBusy() {
        let result = ExportManagerLogic.validateRetry(
            exportPhase: .done, isBusy: true, retryableCount: 1
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("busy"))
    }

    func testRetryBlockedWhenNoRetryableTasks() {
        let result = ExportManagerLogic.validateRetry(
            exportPhase: .done, isBusy: false, retryableCount: 0
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("No retryable"))
    }

    func testRetryAllowedWhenDoneWithFailedTasks() {
        let result = ExportManagerLogic.validateRetry(
            exportPhase: .done, isBusy: false, retryableCount: 3
        )
        XCTAssertNil(result)
    }

    func testRetryAllowedFromIdlePhase() {
        let result = ExportManagerLogic.validateRetry(
            exportPhase: .idle, isBusy: false, retryableCount: 1
        )
        XCTAssertNil(result)
    }

    // MARK: - triageTask

    func testFileExistsNoPacketLossMarksSuccess() {
        let action = ExportManagerLogic.triageTask(ExportTaskSnapshot(
            hasPacketLoss: false, fileExists: true
        ))
        XCTAssertEqual(action, .markSuccess)
    }

    func testFileMissingNoPacketLossAddsToPipeline() {
        let action = ExportManagerLogic.triageTask(ExportTaskSnapshot(
            hasPacketLoss: false, fileExists: false
        ))
        XCTAssertEqual(action, .addToPipeline)
    }

    func testPacketLossWithFileReturnsDeleteAndRecheck() {
        let action = ExportManagerLogic.triageTask(ExportTaskSnapshot(
            hasPacketLoss: true, fileExists: true
        ))
        XCTAssertEqual(action, .deleteAndRecheck)
    }

    func testPacketLossWithoutFileReturnsDeleteAndRecheck() {
        let action = ExportManagerLogic.triageTask(ExportTaskSnapshot(
            hasPacketLoss: true, fileExists: false
        ))
        XCTAssertEqual(action, .deleteAndRecheck)
    }

    // MARK: - triageAfterDeletion

    func testFileStillExistsAfterDeletionMarksSuccess() {
        let action = ExportManagerLogic.triageAfterDeletion(fileStillExists: true)
        XCTAssertEqual(action, .markSuccess)
    }

    func testFileGoneAfterDeletionAddsToPipeline() {
        let action = ExportManagerLogic.triageAfterDeletion(fileStillExists: false)
        XCTAssertEqual(action, .addToPipeline)
    }

    // MARK: - validateDotForRetry

    func testDotNotFoundReturnsError() {
        let result = ExportManagerLogic.validateDotForRetry(dotExists: false, dotReady: false)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not ready"))
    }

    func testDotExistsButNotReadyReturnsError() {
        let result = ExportManagerLogic.validateDotForRetry(dotExists: true, dotReady: false)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not ready"))
    }

    func testDotReadyReturnsNil() {
        let result = ExportManagerLogic.validateDotForRetry(dotExists: true, dotReady: true)
        XCTAssertNil(result)
    }
}
