import XCTest

@MainActor final class ClipboardUITests: XCTestCase {
    func testFixtureHistoryAndImmediateEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures"]
        app.launch()
        let table = app.tables["Clipboard history"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertTrue(table.cells.firstMatch.waitForExistence(timeout: 5))
        table.cells.firstMatch.click()
        let editor = app.textViews["Editable clipboard text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Edit"].exists)
        app.popUpButtons["Date filter"].click()
        app.menuItems["Today"].click()
        XCTAssertTrue(app.tables["Clipboard history"].exists)
        app.terminate()
    }
    func testPopupDismissesWhenSettingsOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures"]
        app.launch()
        let history = app.windows["Clipboard"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Resume recording"].exists)
        app.buttons["Settings"].click()
        XCTAssertTrue(app.windows["Clipboard Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(history.waitForNonExistence(timeout: 5))
        app.terminate()
    }
    func testListSelectAllShowsBulkActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures"]
        app.launch()
        let table = app.tables["Clipboard history"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        table.cells.firstMatch.click()
        table.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Copy selected"].waitForExistence(timeout: 5))
        let editor = app.textViews["Combined clipboard text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Edited combined copy")
        XCTAssertEqual(editor.value as? String, "Edited combined copy")
        let copy = app.buttons["Copy selected"]
        let dates = app.popUpButtons["Date filter"]
        XCTAssertLessThan(copy.frame.maxX, dates.frame.minX)
        XCTAssertEqual(copy.frame.midY, dates.frame.midY, accuracy: 4)
        app.buttons["Revert"].click()
        XCTAssertNotEqual(editor.value as? String, "Edited combined copy")
        app.terminate()
    }
}
