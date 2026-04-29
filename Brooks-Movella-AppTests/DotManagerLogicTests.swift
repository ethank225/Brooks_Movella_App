import XCTest
@testable import Brooks_Movella_App

final class DotManagerLogicTests: XCTestCase {

    // MARK: - Begin Session Preconditions

    func testBeginSessionAllowedWhenIdleAndSynced() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false),
                    DotSnapshot(isReady: true, isSynced: true, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNil(result)
    }

    func testBeginSessionAllowedWithSingleUnsyncedSensor() {
        let dots = [DotSnapshot(isReady: true, isSynced: false, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNil(result)
    }

    func testBeginSessionBlockedWhenRecording() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .recording, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("busy"))
    }

    func testBeginSessionBlockedWhenSyncing() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .syncing, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
    }

    func testBeginSessionAllowedFromErrorState() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .error("previous failure"), connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNil(result)
    }

    func testBeginSessionBlockedWhenConnectionsPending() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: false, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("pending"))
    }

    func testBeginSessionBlockedWhenRunnerNotFound() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: false
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not found"))
    }

    func testBeginSessionBlockedWhenNoReadySensors() {
        let dots = [DotSnapshot(isReady: false, isSynced: false, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("No ready"))
    }

    func testBeginSessionBlockedWhenMultipleSensorsNotSynced() {
        let dots = [DotSnapshot(isReady: true, isSynced: false, isRecording: false),
                    DotSnapshot(isReady: true, isSynced: false, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not synced"))
    }

    func testBeginSessionBlockedWhenPartialSynced() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: false),
                    DotSnapshot(isReady: true, isSynced: false, isRecording: false)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not synced"))
    }

    func testBeginSessionBlockedWhenSensorAlreadyRecording() {
        let dots = [DotSnapshot(isReady: true, isSynced: true, isRecording: true)]
        let result = DotManagerLogic.validateBeginSession(
            currentPhase: .idle, connectQueueEmpty: true, dots: dots, runnerExists: true
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("already recording"))
    }

    // MARK: - Resync Preconditions

    func testResyncAllowedWhenIdleWith2Sensors() {
        let result = DotManagerLogic.validateResync(
            currentPhase: .idle, anySyncActive: false, readyDotCount: 2
        )
        XCTAssertNil(result)
    }

    func testResyncBlockedWhenNotIdle() {
        let result = DotManagerLogic.validateResync(
            currentPhase: .recording, anySyncActive: false, readyDotCount: 2
        )
        XCTAssertNotNil(result)
    }

    func testResyncBlockedWhenAnotherSyncActive() {
        let result = DotManagerLogic.validateResync(
            currentPhase: .idle, anySyncActive: true, readyDotCount: 2
        )
        XCTAssertNotNil(result)
    }

    func testResyncBlockedWithOnly1Sensor() {
        let result = DotManagerLogic.validateResync(
            currentPhase: .idle, anySyncActive: false, readyDotCount: 1
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("2+"))
    }

    func testResyncAllowedWith3Sensors() {
        let result = DotManagerLogic.validateResync(
            currentPhase: .idle, anySyncActive: false, readyDotCount: 3
        )
        XCTAssertNil(result)
    }

    // MARK: - Connect Path Selection

    func testConnectPathSyncReconnect() {
        let path = DotManagerLogic.determineConnectPath(
            syncInProgress: true, isSyncingUuid: true,
            isInConnectQueue: false, isConnectInProgress: false, hasDot: true
        )
        XCTAssertEqual(path, .syncReconnect)
    }

    func testConnectPathSyncReconnectRequiresBothFlags() {
        let path = DotManagerLogic.determineConnectPath(
            syncInProgress: true, isSyncingUuid: false,
            isInConnectQueue: false, isConnectInProgress: false, hasDot: true
        )
        XCTAssertNotEqual(path, .syncReconnect)
    }

    func testConnectPathQueuedButNotActive() {
        let path = DotManagerLogic.determineConnectPath(
            syncInProgress: false, isSyncingUuid: false,
            isInConnectQueue: true, isConnectInProgress: false, hasDot: true
        )
        XCTAssertEqual(path, .queuedButNotActive)
    }

    func testConnectPathAutoReconnect() {
        let path = DotManagerLogic.determineConnectPath(
            syncInProgress: false, isSyncingUuid: false,
            isInConnectQueue: false, isConnectInProgress: false, hasDot: true
        )
        XCTAssertEqual(path, .autoReconnect)
    }

    func testConnectPathNormalFirstTime() {
        let path = DotManagerLogic.determineConnectPath(
            syncInProgress: false, isSyncingUuid: false,
            isInConnectQueue: false, isConnectInProgress: true, hasDot: false
        )
        if case .normalConnect(let delay) = path {
            XCTAssertEqual(delay, 0, "First-time connect should have no settle delay")
        } else {
            XCTFail("Expected normalConnect, got \(path)")
        }
    }

    func testConnectPathBTResetReconnect() {
        let path = DotManagerLogic.determineConnectPath(
            syncInProgress: false, isSyncingUuid: false,
            isInConnectQueue: false, isConnectInProgress: true, hasDot: true
        )
        if case .normalConnect(let delay) = path {
            XCTAssertEqual(delay, 2.0, "BT-reset reconnect should have 2s settle delay")
        } else {
            XCTFail("Expected normalConnect, got \(path)")
        }
    }

    // MARK: - Sync Result Parsing

    func testParseSyncResultsAllSuccess() {
        let dots: [DotManagerLogic.DotIdentifier] = [
            .init(address: "uuid1", macAddress: "D4:22:CD:00:00:01"),
            .init(address: "uuid2", macAddress: "D4:22:CD:00:00:02"),
        ]
        let rawResults: [[String: Any]] = [
            ["address": "D4:22:CD:00:00:01", "success": true, "status": 0],
            ["address": "D4:22:CD:00:00:02", "success": true, "status": 0],
        ]
        let result = DotManagerLogic.parseSyncResults(rawResults: rawResults, dots: dots)
        XCTAssertTrue(result.allSuccess)
        XCTAssertEqual(result.succeededUuids, ["uuid1", "uuid2"])
        XCTAssertTrue(result.failedUuids.isEmpty)
        XCTAssertNil(result.errorMsg)
    }

    func testParseSyncResultsPartialFailure() {
        let dots: [DotManagerLogic.DotIdentifier] = [
            .init(address: "uuid1", macAddress: "D4:22:CD:00:00:01"),
            .init(address: "uuid2", macAddress: "D4:22:CD:00:00:02"),
        ]
        let rawResults: [[String: Any]] = [
            ["address": "D4:22:CD:00:00:01", "success": true, "status": 0],
            ["address": "D4:22:CD:00:00:02", "success": false, "status": -1],
        ]
        let result = DotManagerLogic.parseSyncResults(rawResults: rawResults, dots: dots)
        XCTAssertFalse(result.allSuccess)
        XCTAssertEqual(result.succeededUuids, ["uuid1"])
        XCTAssertEqual(result.failedUuids, ["uuid2"])
        XCTAssertNotNil(result.errorMsg)
    }

    func testParseSyncResultsNilResults() {
        let dots: [DotManagerLogic.DotIdentifier] = [
            .init(address: "uuid1", macAddress: "mac1"),
        ]
        let result = DotManagerLogic.parseSyncResults(rawResults: nil, dots: dots)
        XCTAssertFalse(result.allSuccess)
        XCTAssertEqual(result.failedUuids, ["uuid1"])
        XCTAssertTrue(result.errorMsg!.contains("no results"))
    }

    func testParseSyncResultsMissingDotCountsAsFailed() {
        let dots: [DotManagerLogic.DotIdentifier] = [
            .init(address: "uuid1", macAddress: "D4:22:CD:00:00:01"),
            .init(address: "uuid2", macAddress: "D4:22:CD:00:00:02"),
            .init(address: "uuid3", macAddress: "D4:22:CD:00:00:03"),
        ]
        let rawResults: [[String: Any]] = [
            ["address": "D4:22:CD:00:00:01", "success": true, "status": 0],
            ["address": "D4:22:CD:00:00:02", "success": true, "status": 0],
        ]
        let result = DotManagerLogic.parseSyncResults(rawResults: rawResults, dots: dots)
        XCTAssertFalse(result.allSuccess)
        XCTAssertEqual(result.succeededUuids, ["uuid1", "uuid2"])
        XCTAssertEqual(result.failedUuids, ["uuid3"])
    }

    func testParseSyncResultsMatchesByUuidFallback() {
        let dots: [DotManagerLogic.DotIdentifier] = [
            .init(address: "uuid1", macAddress: "mac1"),
        ]
        let rawResults: [[String: Any]] = [
            ["address": "uuid1", "success": true, "status": 0],
        ]
        let result = DotManagerLogic.parseSyncResults(rawResults: rawResults, dots: dots)
        XCTAssertTrue(result.allSuccess)
        XCTAssertEqual(result.succeededUuids, ["uuid1"])
    }

    func testParseSyncResultsEmptyResults() {
        let dots: [DotManagerLogic.DotIdentifier] = [
            .init(address: "uuid1", macAddress: "mac1"),
        ]
        let result = DotManagerLogic.parseSyncResults(rawResults: [], dots: dots)
        XCTAssertFalse(result.allSuccess)
        XCTAssertEqual(result.failedUuids, ["uuid1"])
    }

    // MARK: - Phase Transition Effects

    func testSyncingPhaseSetsSyncInProgress() {
        let phases = ["r1": SessionPhase.syncing, "r2": SessionPhase.idle]
        let effects = DotManagerLogic.computePhaseEffects(
            newPhase: .syncing, allPhases: phases
        )
        XCTAssertTrue(effects.syncInProgress)
        XCTAssertFalse(effects.shouldClearSyncingUuids)
        XCTAssertFalse(effects.shouldClearExportCart)
    }

    func testIdlePhaseClearsSyncInProgress() {
        let phases = ["r1": SessionPhase.idle, "r2": SessionPhase.idle]
        let effects = DotManagerLogic.computePhaseEffects(
            newPhase: .idle, allPhases: phases
        )
        XCTAssertFalse(effects.syncInProgress)
        XCTAssertTrue(effects.shouldClearSyncingUuids)
        XCTAssertTrue(effects.shouldPurgeStaleConnections)
    }

    func testRecordingPhaseClearsExportCart() {
        let phases = ["r1": SessionPhase.recording]
        let effects = DotManagerLogic.computePhaseEffects(
            newPhase: .recording, allPhases: phases
        )
        XCTAssertTrue(effects.shouldClearExportCart)
        XCTAssertFalse(effects.shouldPurgeStaleConnections)
    }

    func testSyncInProgressTrueIfAnyRunnerSyncing() {
        let phases = ["r1": SessionPhase.idle, "r2": SessionPhase.syncing]
        let effects = DotManagerLogic.computePhaseEffects(
            newPhase: .idle, allPhases: phases
        )
        XCTAssertTrue(effects.syncInProgress)
    }

    func testErrorPhaseClearsSyncState() {
        let phases = ["r1": SessionPhase.error("fail")]
        let effects = DotManagerLogic.computePhaseEffects(
            newPhase: .error("fail"), allPhases: phases
        )
        XCTAssertFalse(effects.syncInProgress)
        XCTAssertTrue(effects.shouldClearSyncingUuids)
    }

    // MARK: - isBusy Derivation

    func testIsBusyWhenSyncing() {
        XCTAssertTrue(Self.isBusy(from: ["r1": .syncing]))
    }

    func testIsBusyWhenRecording() {
        XCTAssertTrue(Self.isBusy(from: ["r1": .recording]))
    }

    func testIsBusyWhenStarting() {
        XCTAssertTrue(Self.isBusy(from: ["r1": .startingRecording]))
    }

    func testIsBusyWhenStopping() {
        XCTAssertTrue(Self.isBusy(from: ["r1": .stoppingRecording]))
    }

    func testNotBusyWhenIdle() {
        XCTAssertFalse(Self.isBusy(from: ["r1": .idle]))
    }

    func testNotBusyWhenError() {
        XCTAssertFalse(Self.isBusy(from: ["r1": .error("x")]))
    }

    func testBusyIfAnyRunnerActive() {
        XCTAssertTrue(Self.isBusy(from: ["r1": .idle, "r2": .recording, "r3": .idle]))
    }

    // MARK: - Helpers

    private static func isBusy(from phases: [String: SessionPhase]) -> Bool {
        phases.values.contains {
            switch $0 {
            case .syncing, .startingRecording, .recording, .stoppingRecording:
                return true
            default:
                return false
            }
        }
    }
}
