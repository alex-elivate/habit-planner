import XCTest

/// First launch on an empty store: enter the habits you already do, several at once.
///
/// The gate's rules for the starting set are pinned in HabitKit. This checks that the screen
/// offers them: that more than one habit joins on day one, in the order typed, and that the
/// routine then says it is in setup.
final class SetupFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Empty and in memory, so the first-launch setup appears and nothing is kept.
        app.launchArguments = ["-InMemoryStore"]
        app.launch()
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStartingSetJoinsTogether() {
        XCTAssertTrue(app.navigationBars["Morning routine"].waitForExistence(timeout: 10),
                      "An empty store should open on setup")

        // Return moves to a new line, so a routine can be typed straight through.
        app.typeText("Drink water\n")
        app.typeText("Stretch\n")
        app.typeText("Make the bed")
        keepScreenshot("morning setup")
        app.buttons["Next"].tap()

        XCTAssertTrue(app.navigationBars["Evening routine"].waitForExistence(timeout: 10))
        app.typeText("Read ten pages")
        app.buttons["Done"].tap()

        // All four joined on day one, in the order typed.
        let water = app.staticTexts["Drink water"]
        XCTAssertTrue(water.waitForExistence(timeout: 10))
        let stretch = app.staticTexts["Stretch"], bed = app.staticTexts["Make the bed"]
        XCTAssertTrue(stretch.exists && bed.exists && app.staticTexts["Read ten pages"].exists)
        XCTAssertLessThan(water.frame.minY, stretch.frame.minY)
        XCTAssertLessThan(stretch.frame.minY, bed.frame.minY)

        // Still setup day, so the routine keeps taking habits and says why.
        XCTAssertTrue(app.buttons["Add more habits"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Setting up today'")).firstMatch.exists)
        keepScreenshot("after setup")
    }

    func testNotNowLeavesAnEmptyRoutineToSetUpLater() {
        XCTAssertTrue(app.navigationBars["Morning routine"].waitForExistence(timeout: 10))
        app.buttons["Not now"].tap()

        let setUp = app.buttons["Set up your morning routine"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 5))
        setUp.tap()
        XCTAssertTrue(app.navigationBars["Morning routine"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].isEnabled, "Nothing typed, nothing to add")
        app.typeText("Stretch")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Stretch"].waitForExistence(timeout: 5))
    }
}
