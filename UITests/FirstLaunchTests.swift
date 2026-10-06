import XCTest

@MainActor final class FirstLaunchTests: XCTestCase {
    func testFreshInstallAndRelaunchFinishStorageSetupWithoutWarning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // CI creates a new simulator, so this first launch has no pre-existing App data.
        app.launch()
        assertReadyWithoutStorageError(app)
        app.terminate()
        app.launch()
        assertReadyWithoutStorageError(app)
    }

    private func assertReadyWithoutStorageError(_ app: XCUIApplication) {
        let start = app.buttons["start-recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in start.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["system-warning"].exists)
    }
}
