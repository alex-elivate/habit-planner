import XCTest

/// Drives the watch runner end to end against the seeded in-memory store.
///
/// The runner's rules are pinned in HabitKit, and the bridge's merge rules in HabitStore. This
/// checks the watch wiring neither can see: that a tap writes to the watch's store, that Back
/// really retracts, and that the routine list reflects what was written.
final class WatchRunnerFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-InMemoryStore", "-SeedDemoData"]
        app.launch()
    }

    private var onScreen: XCUIElement { app.staticTexts["runner.habit"] }

    private func expectOnScreen(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = expectation(for: NSPredicate(format: "label == %@", title), evaluatedWith: onScreen)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed,
                       "Expected \(title), saw \(onScreen.label)", file: file, line: line)
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Seeded morning habits due every day, in sequence order.
    private let water = "Drink a glass of water"
    private let stretch = "Stretch"

    func testDoneBackSkipAndFinish() {
        keepScreenshot("watch-routines")
        let start = app.buttons["Start morning routine"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        expectOnScreen(water)
        keepScreenshot("watch-step")
        app.buttons["Done"].tap()
        expectOnScreen(stretch)

        // Back returns to the step just passed, and retracts it.
        app.buttons["Back"].tap()
        expectOnScreen(water)
        app.buttons["Done"].tap()
        expectOnScreen(stretch)
        app.buttons["Skip"].tap()

        // Whatever else is due today, done until the routine finishes. The dog walk is only
        // due on some weekdays, so the count is not fixed.
        var guardRail = 5
        while onScreen.waitForExistence(timeout: 2), guardRail > 0 {
            app.buttons["Done"].tap()
            guardRail -= 1
        }

        XCTAssertTrue(app.staticTexts["Morning done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 skipped'")).firstMatch.exists)
        keepScreenshot("watch-finished")
        app.buttons["Finish"].tap()

        // Passed, done or skipped, so nothing is left to run this morning.
        let finished = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Morning, Done'")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 5))
    }

    func testReopeningResumesWhereYouLeft() {
        let start = app.buttons["Start morning routine"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        expectOnScreen(water)
        app.buttons["Done"].tap()
        expectOnScreen(stretch)

        // The full-screen cover's own close button. XCUITest lists it more than once.
        app.buttons["xmark"].firstMatch.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        expectOnScreen(stretch)
    }
}
