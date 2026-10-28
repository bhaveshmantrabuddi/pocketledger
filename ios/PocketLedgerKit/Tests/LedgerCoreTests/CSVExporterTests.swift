import XCTest
@testable import LedgerCore

final class CSVExporterTests: XCTestCase {
    func testQuotesCommasNewlinesAndUnicodeArePreserved() throws {
        let record = try Expense(amountCents: 1234, category: .food, note: "Café, \"tea\"\nLunch", date: "2026-10-27")
        let csv = CSVExporter.export([record])
        XCTAssertTrue(csv.contains("\"Café, \"\"tea\"\"\nLunch\""))
        XCTAssertTrue(csv.contains("\"1234\",\"USD\""))
    }
    func testSpreadsheetFormulaPrefixesAreEscaped() throws {
        for note in ["=1+1", " +SUM(A1)", "-5", "@function"] {
            let record = try Expense(amountCents: 1, category: .other, note: note, date: "2026-01-01")
            XCTAssertTrue(CSVExporter.export([record]).contains("\"'" + note + "\""))
        }
    }
    func testEmptyExportStillHasHeader() {
        XCTAssertEqual(CSVExporter.export([]), "id,date,category,amount_cents,currency,note\r\n")
    }
}
