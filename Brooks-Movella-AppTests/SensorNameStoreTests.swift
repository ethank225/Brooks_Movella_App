import XCTest
@testable import Brooks_Movella_App

final class SensorNameStoreTests: XCTestCase {

    private var store: SensorNameStore!
    private var defaults: UserDefaults!
    private let suiteName = "SensorNameStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = SensorNameStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testNameReturnsUUIDWhenNoCustomNameSet() {
        XCTAssertEqual(store.name(for: "ABC-123"), "ABC-123")
    }

    func testSetNameThenNameReturnsCustomName() {
        store.setName("Left Foot", for: "ABC-123")
        XCTAssertEqual(store.name(for: "ABC-123"), "Left Foot")
    }

    func testClearNameRevertsToUUID() {
        store.setName("Left Foot", for: "ABC-123")
        store.clearName(for: "ABC-123")
        XCTAssertEqual(store.name(for: "ABC-123"), "ABC-123")
    }

}
