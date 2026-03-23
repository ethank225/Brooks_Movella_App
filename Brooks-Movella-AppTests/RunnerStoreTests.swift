import XCTest
@testable import Brooks_Movella_App

final class RunnerStoreTests: XCTestCase {

    private var store: RunnerStore!
    private var tempFileURL: URL!

    override func setUp() {
        super.setUp()
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        store = RunnerStore(fileURL: tempFileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFileURL)
        store = nil
        super.tearDown()
    }

    // MARK: - addRunner

    func testAddRunnerCreatesRunnerWithCorrectLabel() {
        let runner = store.addRunner(label: "Sprinter")
        XCTAssertEqual(runner.label, "Sprinter")
        XCTAssertEqual(store.runners.count, 1)
    }

    // MARK: - removeRunner

    func testRemoveRunnerDeletesTheRunner() {
        let runner = store.addRunner(label: "Runner1")
        store.removeRunner(id: runner.id)
        XCTAssertTrue(store.runners.isEmpty)
    }

    // MARK: - assignSensor

    func testAssignSensorAddsUUIDToRunner() {
        let runner = store.addRunner(label: "R1")
        store.assignSensor(uuid: "sensor-A", to: runner.id)
        XCTAssertTrue(store.runners[0].sensorUuids.contains("sensor-A"))
    }

    func testAssignSensorRemovesUUIDFromPreviousRunner() {
        let r1 = store.addRunner(label: "R1")
        let r2 = store.addRunner(label: "R2")
        store.assignSensor(uuid: "sensor-A", to: r1.id)
        store.assignSensor(uuid: "sensor-A", to: r2.id)

        let updatedR1 = store.runners.first { $0.id == r1.id }!
        XCTAssertFalse(updatedR1.sensorUuids.contains("sensor-A"))
    }

    // MARK: - unassignSensor

    func testUnassignSensorRemovesUUIDFromRunner() {
        let runner = store.addRunner(label: "R1")
        store.assignSensor(uuid: "sensor-A", to: runner.id)
        store.unassignSensor(uuid: "sensor-A", from: runner.id)
        XCTAssertTrue(store.runners[0].sensorUuids.isEmpty)
    }


    // MARK: - runner(forSensorUuid:)

    func testRunnerForSensorUuidReturnsCorrectRunner() {
        let runner = store.addRunner(label: "R1")
        store.assignSensor(uuid: "sensor-A", to: runner.id)
        let found = store.runner(forSensorUuid: "sensor-A")
        XCTAssertEqual(found?.id, runner.id)
    }

    func testRunnerForSensorUuidReturnsNilForUnassignedUUID() {
        XCTAssertNil(store.runner(forSensorUuid: "nonexistent"))
    }

    // MARK: - Persistence

    func testSaveAndLoadRoundTrip() {
        let r1 = store.addRunner(label: "Alpha")
        store.assignSensor(uuid: "s1", to: r1.id)
        store.addRunner(label: "Beta")

        // Verify by decoding the file directly instead of creating a second
        // RunnerStore instance (which causes concurrent access issues).
        let data = try! Data(contentsOf: tempFileURL)
        let decoded = try! JSONDecoder().decode([Runner].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].label, "Alpha")
        XCTAssertEqual(decoded[0].sensorUuids, ["s1"])
        XCTAssertEqual(decoded[1].label, "Beta")
    }

    // MARK: - clearAll

    func testClearAllRemovesEverything() {
        store.addRunner(label: "R1")
        store.addRunner(label: "R2")
        store.clearAll()
        XCTAssertTrue(store.runners.isEmpty)
    }
}
