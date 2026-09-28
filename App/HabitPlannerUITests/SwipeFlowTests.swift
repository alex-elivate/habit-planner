import XCTest

/// Drives the Today list's swipes end to end against the seeded in-memory store.
///
/// The rules are pinned in HabitKit and HabitStore. This checks the wiring those tests cannot
/// see: that a swipe writes to the store, and that the row reads back what the store says.
final class SwipeFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-InMemoryStore", "-SeedDemoData"]
        app.launch()
    }

    /// Seeded morning habits that are due every day, in sequence order.
    private let water = "Drink a glass of water"
    private let stretch = "Stretch"

    private func row(_ title: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func expect(_ title: String, reads value: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = row(title)
        let predicate = NSPredicate(format: "value == %@", value)
        let met = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5)
        XCTAssertEqual(met, .completed, "\(title) reads \(String(describing: element.value)), not \(value)",
                       file: file, line: line)
    }

    /// A swipe across the whole row, which is what a full swipe needs. XCUITest's own swipes
    /// are too short to trigger one.
    private func fullSwipe(_ title: String, right: Bool) {
        let element = row(title)
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.1 : 0.9, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: right ? 1.0 : 0.0, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSwipeRightDoesLeftSkipsAndBothUndo() {
        XCTAssertTrue(row(water).waitForExistence(timeout: 10))
        expect(water, reads: "Next")
        expect(stretch, reads: "To do")

        // A full swipe right does the habit, and next moves on.
        fullSwipe(water, right: true)
        expect(water, reads: "Done")
        expect(stretch, reads: "Next")

        // A full swipe left skips it.
        fullSwipe(stretch, right: false)
        expect(stretch, reads: "Skipped")
        keepScreenshot("swiped")

        // A skipped habit can still be done.
        fullSwipe(stretch, right: true)
        expect(stretch, reads: "Done")

        // Swiping a done habit left offers Not done, which puts it back.
        row(water).swipeLeft()
        let notDone = app.buttons["Not done.\(water)"]
        XCTAssertTrue(notDone.waitForExistence(timeout: 5))
        notDone.tap()
        expect(water, reads: "Next")
    }

    func testUnskipPutsTheHabitBack() {
        XCTAssertTrue(row(water).waitForExistence(timeout: 10))
        fullSwipe(water, right: false)
        expect(water, reads: "Skipped")
        expect(stretch, reads: "Next")

        row(water).swipeLeft()
        let unskip = app.buttons["Unskip.\(water)"]
        XCTAssertTrue(unskip.waitForExistence(timeout: 5))
        unskip.tap()
        expect(water, reads: "Next")
    }

    func testTapStillOpensTheHabit() {
        XCTAssertTrue(row(water).waitForExistence(timeout: 10))
        row(water).tap()
        XCTAssertTrue(app.navigationBars[water].waitForExistence(timeout: 5)
                      || app.staticTexts[water].waitForExistence(timeout: 1))
    }

    func testChoosingAnIcon() {
        XCTAssertTrue(row(water).waitForExistence(timeout: 10))
        row(water).tap()
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let icon = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Icon'")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        icon.tap()
        let teal = app.buttons["Teal"]
        XCTAssertTrue(teal.waitForExistence(timeout: 5))
        teal.tap()
        app.buttons["cup and saucer"].tap()
        XCTAssertTrue(app.buttons["cup and saucer"].isSelected)
        keepScreenshot("icon-picker")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Saving did not close the editor")
    }

    /// A widget's link, from inside a habit's page: back to Today, at that routine.
    func testALinkOpensTodayAtTheRoutine() {
        XCTAssertTrue(row(water).waitForExistence(timeout: 10))
        row(water).tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Today"].exists)

        app.open(URL(string: "habitplanner://run/evening")!)
        let reading = row("Read ten pages")
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        let shown = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isHittable == true"),
                                                     evaluatedWith: reading)], timeout: 5)
        XCTAssertEqual(shown, .completed, "The evening routine is not on screen")
        XCTAssertTrue(app.navigationBars["Today"].exists, "Still on the habit's page")
    }
}
