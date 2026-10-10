import XCTest

/// Presses Done on a routine reminder from Notification Centre, with the app closed, and
/// checks the list. The handler runs with the app in the background, which nothing else
/// exercises.
@MainActor
final class ReminderActionTests: XCTestCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let water = "Drink a glass of water"

    func testDoneFromTheLockScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-InMemoryStore", "-SeedDemoData", "-PostTestReminder"]
        // In memory, which the suspended app keeps while the action runs in it. The permission
        // prompt belongs to SpringBoard.
        addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        app.launch()
        // The prompt can take well over ten seconds on a simulator that has just booted, and
        // without Allow the reminder is never scheduled.
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 30) { allow.tap() }
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", water))
            .firstMatch.waitForExistence(timeout: 15))

        // Leave the app once it has scheduled the reminder, and before it fires 25 seconds
        // later. It lands as a banner on the home screen, and its button runs with the app in
        // the background.
        sleep(8)
        XCUIDevice.shared.press(.home)
        let reminder = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Start with \(water)")).firstMatch
        XCTAssertTrue(reminder.waitForExistence(timeout: 45), "The reminder never arrived")
        reminder.press(forDuration: 1.2)
        let done = springboard.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The reminder has no Done button")
        done.tap()

        // The follow-up names the next habit.
        let followUp = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Next: ")).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: 20), "No follow-up after Done")
        let attachment = XCTAttachment(screenshot: springboard.screenshot())
        attachment.name = "follow-up"
        attachment.lifetime = .keepAlways
        add(attachment)

        // And the list agrees.
        XCUIDevice.shared.press(.home)
        app.activate()
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", water)).firstMatch
        let done2 = expectation(for: NSPredicate(format: "value == 'Done'"), evaluatedWith: row)
        XCTAssertEqual(XCTWaiter.wait(for: [done2], timeout: 20), .completed, "The list does not show it done")
    }
}
