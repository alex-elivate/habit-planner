import XCTest

/// Drives the Mac app against the seeded in-memory store: the routine list, and each report page.
///
/// The rules are pinned in HabitKit. This checks the wiring on the Mac: that the list's actions
/// write and undo, and that every page opens on real folded data. Screenshots of each page
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

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND value != nil", title)).firstMatch
    }

    private func expect(_ title: String, reads value: String, file: StaticString = #filePath, line: UInt = #line) {
        let met = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", value),
                                                   evaluatedWith: row(title))], timeout: 5)
        XCTAssertEqual(met, .completed, "\(title) does not read \(value)", file: file, line: line)
    }

    /// Right-click, the Mac's way to reach what a swipe does.
    private func choose(_ action: String, on title: String) {
        row(title).rightClick()
        let item = app.menuItems[action]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(action) for \(title)")
        item.click()
    }

    func testDoneSkipAndUndoFromTheList() {
        let water = "Drink a glass of water", stretch = "Stretch"
        XCTAssertTrue(row(water).waitForExistence(timeout: 10))
        keep("routine")
        expect(water, reads: "Next")

        choose("Done", on: water)
        expect(water, reads: "Done")
        expect(stretch, reads: "Next")
        choose("Skip", on: stretch)
        expect(stretch, reads: "Skipped")
        keep("after actions")

        choose("Not done", on: water)
        expect(water, reads: "Next")
        choose("Unskip", on: stretch)
        expect(stretch, reads: "To do")
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
