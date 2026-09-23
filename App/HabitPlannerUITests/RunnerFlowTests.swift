import XCTest

/// Drives the routine runner end to end against the seeded in-memory store.
///
/// The runner's rules are pinned in HabitKit. This checks the wiring those tests cannot see:
/// that a tap writes to the store, that the list reflects it, and that Back really retracts.
final class RunnerFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-InMemoryStore", "-SeedDemoData"]
        app.launch()
    }

    /// The habit the runner is showing. Scoped to the runner, because the Today list stays in
    /// the accessibility tree underneath the full-screen cover.
    private var onScreen: XCUIElement { app.staticTexts["runner.habit"] }

    private func expectOnScreen(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = onScreen.waitForExistence(timeout: 5)
            && NSPredicate(format: "label == %@", title).evaluate(with: onScreen)
        if !shown {
            _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == %@", title),
                                                 evaluatedWith: onScreen)], timeout: 5)
        }
        XCTAssertEqual(onScreen.label, title, file: file, line: line)
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Seeded morning habits that are due every day, in sequence order.
    private let water = "Drink a glass of water"
    private let stretch = "Stretch"

    func testDoneSkipBackAndFinish() {
        let start = app.buttons["Start morning routine"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        // One habit at a time, in sequence order.
        expectOnScreen(water)
        keepScreenshot("runner-step")

        app.buttons["Done"].tap()
        expectOnScreen(stretch)

        // Back returns to the habit just passed and un-does it.
        app.buttons["Back"].tap()
        expectOnScreen(water)

        app.buttons["Done"].tap()
        expectOnScreen(stretch)
        app.buttons["Skip"].tap()

        // Walk the dog is Monday, Wednesday and Friday, so whether it appears depends on today.
        if onScreen.waitForExistence(timeout: 2), onScreen.label == "Walk the dog" {
            app.buttons["Done"].tap()
        }

        XCTAssertTrue(app.staticTexts["Morning routine done"].waitForExistence(timeout: 5))
        keepScreenshot("runner-finished")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 skipped'")).firstMatch.exists)
        app.buttons["Close"].tap()

        // The list reflects the store: water done, stretch still open for today.
        XCTAssertTrue(app.buttons["Done for today"].waitForExistence(timeout: 5)
                      || app.buttons["Resume"].exists)
        let waterRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", water)).firstMatch
        XCTAssertTrue(waterRow.exists)
        XCTAssertTrue(app.buttons["Mark not done"].exists, "Water should read as done")
        XCTAssertTrue(app.buttons["Mark done"].exists, "Skipped stretch should still be tickable today")
    }

    func testReopeningResumesWhereYouLeft() {
        let start = app.buttons["Start morning routine"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        expectOnScreen(water)
        app.buttons["Done"].tap()
        expectOnScreen(stretch)
        app.buttons["Close"].tap()

        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        expectOnScreen(stretch)
    }

    /// Back must reach the store, not only the runner. Without the retraction being recorded,
    /// the list would still show the habit as done after the runner closed.
    func testBackRetractsInTheStore() {
        let start = app.buttons["Start morning routine"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        expectOnScreen(water)
        app.buttons["Done"].tap()
        expectOnScreen(stretch)
        app.buttons["Back"].tap()
        expectOnScreen(water)
        app.buttons["Close"].tap()

        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        // Nothing seeded is complete today, so no row may offer to un-tick.
        XCTAssertFalse(app.buttons["Mark not done"].waitForExistence(timeout: 2))
    }
}
