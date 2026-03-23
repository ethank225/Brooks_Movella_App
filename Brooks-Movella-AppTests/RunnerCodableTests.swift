import XCTest
@testable import Brooks_Movella_App

final class RunnerCodableTests: XCTestCase {

    func testRunnerRoundTripsWithAllFields() {
        let runner = Runner(id: "r1", label: "Sprinter", sensorUuids: ["s1", "s2"])
        let data = try! JSONEncoder().encode(runner)
        let decoded = try! JSONDecoder().decode(Runner.self, from: data)
        XCTAssertEqual(decoded, runner)
    }

    func testRunnerRoundTripsWithEmptySensorUuids() {
        let runner = Runner(id: "r2", label: "Empty")
        let data = try! JSONEncoder().encode(runner)
        let decoded = try! JSONDecoder().decode(Runner.self, from: data)
        XCTAssertEqual(decoded, runner)
        XCTAssertTrue(decoded.sensorUuids.isEmpty)
    }

    func testRunnerArrayRoundTrips() {
        let runners = [
            Runner(id: "a", label: "Alpha", sensorUuids: ["s1"]),
            Runner(id: "b", label: "Beta"),
            Runner(id: "c", label: "Gamma", sensorUuids: ["s2", "s3"]),
        ]
        let data = try! JSONEncoder().encode(runners)
        let decoded = try! JSONDecoder().decode([Runner].self, from: data)
        XCTAssertEqual(decoded, runners)
    }
}
