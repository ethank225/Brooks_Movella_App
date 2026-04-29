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

    // MARK: - canRetry

    func testCanRetryFalseWhenNoFailedTasks() {
        XCTAssertFalse(ExportManagerLogic.canRetry(
            failedAddresses: [],
            readyAddresses: ["A", "B"]
        ))
    }

    func testCanRetryFalseWhenAllFailedSensorsDisconnected() {
        XCTAssertFalse(ExportManagerLogic.canRetry(
            failedAddresses: ["A", "B"],
            readyAddresses: []
        ))
    }

    func testCanRetryFalseWhenFailedAndReadySetsDisjoint() {
        XCTAssertFalse(ExportManagerLogic.canRetry(
            failedAddresses: ["A", "B"],
            readyAddresses: ["C", "D"]
        ))
    }

    func testCanRetryTrueWhenAtLeastOneFailedSensorReady() {
        XCTAssertTrue(ExportManagerLogic.canRetry(
            failedAddresses: ["A", "B", "C"],
            readyAddresses: ["B"]
        ))
    }

    func testCanRetryTrueWhenAllFailedSensorsReady() {
        XCTAssertTrue(ExportManagerLogic.canRetry(
            failedAddresses: ["A", "B"],
            readyAddresses: ["A", "B", "C"]
        ))
    }

    // MARK: - disconnectedCartSensorNames

    func testDisconnectedNamesEmptyWhenAllReady() {
        let states = [
            ExportManagerLogic.CartSensorState(address: "A", displayName: "Left", isReady: true, isInitializing: false),
            ExportManagerLogic.CartSensorState(address: "B", displayName: "Right", isReady: true, isInitializing: false),
        ]
        XCTAssertEqual(ExportManagerLogic.disconnectedCartSensorNames(states), [])
    }

    func testDisconnectedNamesExcludesInitializing() {
        let states = [
            ExportManagerLogic.CartSensorState(address: "A", displayName: "Left", isReady: false, isInitializing: true),
            ExportManagerLogic.CartSensorState(address: "B", displayName: "Right", isReady: true, isInitializing: false),
        ]
        XCTAssertEqual(ExportManagerLogic.disconnectedCartSensorNames(states), [])
    }

    func testDisconnectedNamesIncludesIdleConnectingFailed() {
        // All three of (idle, connecting, failed) come through as
        // isReady=false and isInitializing=false at this layer.
        let states = [
            ExportManagerLogic.CartSensorState(address: "A", displayName: "Left", isReady: false, isInitializing: false),
            ExportManagerLogic.CartSensorState(address: "B", displayName: "Right", isReady: true, isInitializing: false),
            ExportManagerLogic.CartSensorState(address: "C", displayName: "Hip", isReady: false, isInitializing: false),
        ]
        XCTAssertEqual(ExportManagerLogic.disconnectedCartSensorNames(states), ["Hip", "Left"])
    }

    func testDisconnectedNamesSortedAlphabetically() {
        let states = [
            ExportManagerLogic.CartSensorState(address: "A", displayName: "Zeta", isReady: false, isInitializing: false),
            ExportManagerLogic.CartSensorState(address: "B", displayName: "Alpha", isReady: false, isInitializing: false),
            ExportManagerLogic.CartSensorState(address: "C", displayName: "Mid", isReady: false, isInitializing: false),
        ]
        XCTAssertEqual(ExportManagerLogic.disconnectedCartSensorNames(states), ["Alpha", "Mid", "Zeta"])
    }

    func testDisconnectedNamesMixedInitializingAndDisconnected() {
        let states = [
            ExportManagerLogic.CartSensorState(address: "A", displayName: "Left", isReady: false, isInitializing: true),
            ExportManagerLogic.CartSensorState(address: "B", displayName: "Right", isReady: false, isInitializing: false),
        ]
        // Only the truly disconnected one ("Right") is reported.
        XCTAssertEqual(ExportManagerLogic.disconnectedCartSensorNames(states), ["Right"])
    }

    // MARK: - partitionRetryable

    func testPartitionAllSensorsReady() {
        let result = ExportManagerLogic.partitionRetryable(
            taskAddresses: ["A", "B", "C"],
            readyAddresses: ["A", "B", "C"]
        )
        XCTAssertEqual(result.retry, ["A", "B", "C"])
        XCTAssertEqual(result.failDisconnected, [])
    }

    func testPartitionAllSensorsDisconnected() {
        let result = ExportManagerLogic.partitionRetryable(
            taskAddresses: ["A", "B"],
            readyAddresses: []
        )
        XCTAssertEqual(result.retry, [])
        XCTAssertEqual(result.failDisconnected, ["A", "B"])
    }

    func testPartitionPartialReconnect() {
        // The user's example: 3 failed tasks, 2 sensors reconnected.
        // The 2 ready ones go through, the 1 disconnected stays failed.
        let result = ExportManagerLogic.partitionRetryable(
            taskAddresses: ["A", "B", "C"],
            readyAddresses: ["A", "C"]
        )
        XCTAssertEqual(result.retry, ["A", "C"])
        XCTAssertEqual(result.failDisconnected, ["B"])
    }

    func testPartitionPreservesInputOrder() {
        let result = ExportManagerLogic.partitionRetryable(
            taskAddresses: ["C", "A", "B"],
            readyAddresses: ["A", "B", "C"]
        )
        XCTAssertEqual(result.retry, ["C", "A", "B"])
    }

    func testPartitionDuplicatesEachClassifiedIndependently() {
        // Same address appearing twice (e.g. two failed tasks for one sensor)
        // should both go to the same bucket.
        let result = ExportManagerLogic.partitionRetryable(
            taskAddresses: ["A", "A", "B"],
            readyAddresses: ["A"]
        )
        XCTAssertEqual(result.retry, ["A", "A"])
        XCTAssertEqual(result.failDisconnected, ["B"])
    }
}
