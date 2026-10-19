import XCTest

/// Presses Done on a routine reminder from Notification Centre, with the app closed, and
/// checks the list. The handler runs with the app in the background, which nothing else
/// exercises.
@MainActor
final class ReminderActionTests: XCTestCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let water = "Drink a glass of water"

    func testDoneFromTheLockScreen() throws {
        // CI's simulator runs SpringBoard slowly enough that this failed there at a different
        // step each time: the prompt, the banner, reading the lock screen, the Done button.
        // It runs on a desk machine before every merge instead. CI sets HABIT_ON_CI.
        try XCTSkipIf(ProcessInfo.processInfo.environment["HABIT_ON_CI"] == "1",
                      "Too slow to be reliable on CI's simulator. Run it locally.")
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
        // Without Allow the reminder is never scheduled. The app asks at launch, so the prompt
        // comes soon after the list, though slowly on a simulator that has just booted. Waiting
        // a fixed minute for it was wrong the other way: with the prompt already answered, the
        // reminder fired while the test was still waiting in the app. So tap Allow when it
        // shows, and move on once the list has been up ten seconds without one.
        let allow = springboard.alerts.buttons["Allow"]
        let list = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", water)).firstMatch
        var listSince: Date?
        for _ in 0..<60 {
            if allow.exists { allow.tap(); break }
            if list.exists {
                listSince = listSince ?? .now
                if let listSince, Date.now.timeIntervalSince(listSince) > 10 { break }
            }
            sleep(1)
        }
        XCTAssertTrue(list.waitForExistence(timeout: 15))

        // Leave the app once it has scheduled the reminder, and before it fires 25 seconds
        // later. It lands as a banner on the home screen, and its button runs with the app in
        // the background.
        sleep(8)
        XCUIDevice.shared.press(.home)
        let reminder = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Start with \(water)")).firstMatch
        // The banner shows for a few seconds, and a slow simulator's check can miss it. It
        // stays in Notification Centre, under a swipe up, so look there before giving up.
        if !reminder.waitForExistence(timeout: 45) {
            let at = { (y: CGFloat) in self.springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)) }
            at(0.005).press(forDuration: 0.05, thenDragTo: at(0.6))
            sleep(1)
            at(0.7).press(forDuration: 0.05, thenDragTo: at(0.35))
        }
        XCTAssertTrue(reminder.waitForExistence(timeout: 15), "The reminder never arrived")
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
