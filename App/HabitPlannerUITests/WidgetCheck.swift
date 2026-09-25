import XCTest

/// Puts the widget on the home screen and checks what it shows and where it leads.
///
/// Not part of the normal run. It launches the real syncing build rather than the in-memory
/// one, because the widget reads the App Group store and nothing else, and it edits the
/// simulator's home screen through SpringBoard. Run it on purpose:
///
///     TEST_RUNNER_HABIT_WIDGET_CHECK=1 xcodebuild test -scheme HabitPlanner \
///         -only-testing:HabitPlannerUITests/WidgetCheck ...
///
/// Screenshots of each stage are kept in the result bundle, since what a widget looks like is
/// the point and no assertion can say it.
final class WidgetCheck: XCTestCase {
    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HABIT_WIDGET_CHECK"] == "1",
                          "Edits the home screen and the syncing store. Set HABIT_WIDGET_CHECK=1 to run.")
        continueAfterFailure = false
        app = XCUIApplication()
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    private func keep(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWidgetShowsTheRoutineAndOpensTheRunner() throws {
        app.launch()

        // One morning habit and a plan for the next, in the store the widget reads.
        if !app.staticTexts["Drink water"].waitForExistence(timeout: 5) {
            app.buttons["Add a habit"].firstMatch.tap()
            let title = app.textFields.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap()
            title.typeText("Drink water")
            app.buttons["Add"].tap()
            XCTAssertTrue(app.staticTexts["Drink water"].waitForExistence(timeout: 5))
        }
        let plan = app.buttons["plan.morning"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5), "A one-day-old habit should hold the gate shut")
        if !plan.label.contains("Meditate") {
            plan.tap()
            let field = app.textFields["plan.title"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("Meditate")
            app.buttons["Save"].tap()
        }
        let planned = app.buttons.matching(NSPredicate(format: "identifier == 'plan.morning' AND label CONTAINS 'Meditate'"))
        XCTAssertTrue(planned.firstMatch.waitForExistence(timeout: 5))
        keep("app", app.screenshot())

        // Onto the home screen.
        XCUIDevice.shared.press(.home)
        let existing = springboard.otherElements["Habit Planner"].firstMatch
        if !existing.waitForExistence(timeout: 3) {
            addWidget()
        }
        // The timeline can arrive a moment after the widget is placed, so wait on its content.
        XCTAssertTrue(springboard.staticTexts["Drink water"].waitForExistence(timeout: 10),
                      "The widget never showed the habit")
        keep("home screen", springboard.screenshot())

        // Tapping it opens the runner on the featured routine.
        let widget = springboard.otherElements["Habit Planner"].firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        widget.tap()
        let onScreen = app.staticTexts["runner.habit"]
        XCTAssertTrue(onScreen.waitForExistence(timeout: 10), "The widget tap did not open the runner")
        XCTAssertEqual(onScreen.label, "Drink water")
        keep("runner", app.screenshot())
    }

    /// Long press, Edit, Add Widget, find ours, add the medium size.
    private func addWidget() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 1.5)
        let edit = springboard.buttons["Edit"]
        if edit.waitForExistence(timeout: 5) {
            edit.tap()
            let add = springboard.buttons["Add Widget"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
        } else {
            let add = springboard.buttons["Add Widget"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
        }
        keep("gallery", springboard.screenshot())

        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Habit Planner")
        let result = springboard.cells.containing(.staticText, identifier: "Habit Planner").firstMatch
        if result.waitForExistence(timeout: 5) {
            result.tap()
        } else {
            springboard.staticTexts["Habit Planner"].firstMatch.tap()
        }

        // Small first, medium one swipe along.
        springboard.swipeLeft()
        keep("size picker", springboard.screenshot())
        let place = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        place.tap()

        let done = springboard.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
    }
}
