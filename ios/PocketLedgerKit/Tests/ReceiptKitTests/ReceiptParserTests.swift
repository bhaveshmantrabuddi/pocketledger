import XCTest
import ReceiptKit

final class ReceiptParserTests: XCTestCase {
    func testExplicitTotalBeatsSubtotalTaxAndSavings() {
        let result = PLReceiptParser.parse("GREEN CAFE\n2026-10-27\nSUBTOTAL $10.00\nTAX $0.80\nTOTAL SAVINGS $5.00\nTOTAL $10.80")
        XCTAssertEqual(result.merchant, "GREEN CAFE")
        XCTAssertEqual(result.dateString, "2026-10-27")
        XCTAssertEqual(result.totalCents?.int64Value, 1080)
    }
    func testGrandTotalAndThousands() {
        XCTAssertEqual(PLReceiptParser.parse("Grand total: $1,234.56").totalCents?.int64Value, 123456)
    }
    func testMissingTotalDoesNotGuessFromLineItems() {
        XCTAssertNil(PLReceiptParser.parse("Shop\nCoffee $5.00\nTAX $0.40").totalCents)
    }
    func testRejectsNegativeZeroExcessPrecisionAndOversize() {
        for text in ["TOTAL -$1.00", "TOTAL $0.00", "TOTAL $1.234", "TOTAL $1000000.01"] {
            XCTAssertNil(PLReceiptParser.parse(text).totalCents, text)
        }
    }
    func testMaximumAllowedValue() {
        XCTAssertEqual(PLReceiptParser.parse("TOTAL $1,000,000.00").totalCents?.int64Value, 100000000)
    }
    func testUSDateAndLeapYear() {
        XCTAssertEqual(PLReceiptParser.parse("Date: 02/29/2024").dateString, "2024-02-29")
        XCTAssertNil(PLReceiptParser.parse("Date: 02/29/2025").dateString)
    }
    func testRejectsImpossibleOrOutOfRangeDates() {
        for text in ["2026-02-31", "1999-12-31", "2101-01-01"] {
            XCTAssertNil(PLReceiptParser.parse(text).dateString)
        }
    }
    func testLastExplicitTotalWinsAndTextIsPreserved() {
        let text = "Market\nTOTAL $10.00\nTOTAL $12.34"
        let receipt = PLReceiptParser.parse(text)
        XCTAssertEqual(receipt.totalCents?.int64Value, 1234)
        XCTAssertEqual(receipt.rawText, text)
    }
    func testEmptyReceiptHasNoSuggestions() {
        let receipt = PLReceiptParser.parse(" \n\n")
        XCTAssertNil(receipt.merchant); XCTAssertNil(receipt.totalCents); XCTAssertNil(receipt.dateString)
    }
}
