import XCTest

/// Drives the Mac app against the seeded in-memory store: the runner, and each report page.
///
/// The rules are pinned in HabitKit. This checks the wiring on the Mac: that the runner writes
/// and Back retracts, and that every page opens on real folded data. Screenshots of each page
/// are kept, since what a report looks like is the point.
final class MacFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-InMemoryStore", "-SeedDemoData"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var onScreen: XCUIElement { app.staticTexts["runner.habit"] }

    private func expectOnScreen(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(onScreen.waitForExistence(timeout: 5), file: file, line: line)
        let matched = expectation(for: NSPredicate(format: "value == %@ OR label == %@", title, title),
                                  evaluatedWith: onScreen)
        wait(for: [matched], timeout: 5)
    }

    func testRunnerDoneBackAndClose() {
        let routine = app.buttons["Start morning routine"]
        XCTAssertTrue(routine.waitForExistence(timeout: 10))
        keep("routine")
        routine.click()

        expectOnScreen("Drink a glass of water")
        keep("runner")
        app.buttons["Done"].click()
        expectOnScreen("Stretch")
        app.buttons["Back"].click()
        expectOnScreen("Drink a glass of water")
        app.sheets.firstMatch.buttons["Close"].firstMatch.click()

        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Mark not done"].waitForExistence(timeout: 2),
                       "Back should have retracted the only tick")
    }

    func testReportPagesOpen() {
        let lockIn = app.outlines.staticTexts["Lock-in"].firstMatch
        XCTAssertTrue(lockIn.waitForExistence(timeout: 10))
        lockIn.click()
        XCTAssertTrue(app.staticTexts["Bedding in"].waitForExistence(timeout: 5)
                      || app.staticTexts["Status"].waitForExistence(timeout: 1))
        keep("lock-in")

        app.outlines.staticTexts["Completion rates"].firstMatch.click()
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 5))
        keep("rates")

        let habit = app.tables.firstMatch.buttons["Stretch"].firstMatch
        if habit.waitForExistence(timeout: 3) {
            habit.click()
        } else {
            app.tables.firstMatch.staticTexts["Stretch"].firstMatch.click()
        }
        XCTAssertTrue(app.staticTexts["Weeks"].waitForExistence(timeout: 5), "The habit's report did not open")
        keep("habit report")
    }
}
