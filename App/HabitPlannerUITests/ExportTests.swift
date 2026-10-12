import XCTest

/// Settings makes the export files and offers them to the share sheet.
@MainActor
final class ExportTests: XCTestCase {
    func testExportOpensTheShareSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-InMemoryStore", "-SeedDemoData"]
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()

        // Only shown once both files are written, so this also checks that nothing failed.
        let export = app.buttons["export"]
        XCTAssertTrue(export.waitForExistence(timeout: 20), "The export was never ready")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Your data could not'")).firstMatch.exists)
        export.tap()

        // The share sheet, with both files. Its title is sometimes a label and sometimes an
        // identifier, so either counts.
        let sheet = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'ShareSheet.RemoteContainerView' OR identifier == '2 Documents' OR label CONTAINS '2 Documents'")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "No share sheet")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "export-share-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
