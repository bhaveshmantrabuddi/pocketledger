import XCTest

final class PocketLedgerUITests: XCTestCase {
    func testOfflineExpenseEntryAndNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 15))
        let overview = XCTAttachment(screenshot: app.screenshot()); overview.name = "ios-overview"; overview.lifetime = .keepAlways; add(overview)
        app.buttons["addExpenseButton"].tap()
        let amount = app.textFields["expenseAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap(); amount.typeText("12.34")
        let note = app.textFields["expenseNote"]; note.tap(); note.typeText("Offline test lunch")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["saveExpenseButton"].tap()
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Expenses"].tap()
        XCTAssertTrue(app.staticTexts["Offline test lunch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$12.34"].exists)
        let expenses = XCTAttachment(screenshot: app.screenshot()); expenses.name = "ios-expenses"; expenses.lifetime = .keepAlways; add(expenses)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["budgetInput"].waitForExistence(timeout: 5))
    }
}
