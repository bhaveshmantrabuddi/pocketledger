import Foundation

public enum LedgerError: Error, LocalizedError, Equatable {
    case invalid(String), server(Int, String), alreadySyncing
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .server(let status, let message): return "API \(status): \(message)"
        case .alreadySyncing: return "A synchronization is already running."
        }
    }
}

public enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case food, transport, housing, shopping, health, entertainment, other
    public var title: String { rawValue.capitalized }
}

public enum Money {
    public static let maximum: Int64 = 100_000_000
    public static func parse(_ text: String) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil else {
            throw LedgerError.invalid("Enter a positive amount with at most two decimal places.")
        }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let dollars = Int64(pieces[0]) else { throw LedgerError.invalid("Amount is too large.") }
        let (whole, overflow) = dollars.multipliedReportingOverflow(by: 100)
        let fraction = pieces.count == 2 ? String(pieces[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        let (cents, addedOverflow) = whole.addingReportingOverflow(Int64(fraction) ?? 0)
        guard !overflow, !addedOverflow, cents > 0, cents <= maximum else {
            throw LedgerError.invalid("Amount must be between $0.01 and $1,000,000.00.")
        }
        return cents
    }
    public static func input(_ cents: Int64) -> String {
        String(format: "%lld.%02lld", cents / 100, abs(cents % 100))
    }
    public static func display(_ cents: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSDecimalNumber(value: cents).dividing(by: NSDecimalNumber(value: 100))) ?? "$0.00"
    }
}

public enum LedgerDates {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    /// Represent the user's local calendar day at UTC midnight. This is a
    /// date-only value, not a conversion of the original instant to UTC.
    public static func today(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let components = local.dateComponents([.year, .month, .day], from: now)
        return calendar.date(from: components)!
    }
    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public static func parse(_ text: String) -> Date? {
        guard text.range(of: "^(20[0-9]{2}|2100)-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), format(date) == text else { return nil }
        return date
    }
}

public struct Expense: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var amountCents: Int64
    public var category: ExpenseCategory
    public var note: String
    public var date: String
    public init(id: String = UUID().uuidString.lowercased(), amountCents: Int64, category: ExpenseCategory, note: String, date: String) throws {
        guard UUID(uuidString: id) != nil else { throw LedgerError.invalid("Expense ID must be a UUID.") }
        guard amountCents > 0 && amountCents <= Money.maximum else { throw LedgerError.invalid("Expense amount is outside the allowed range.") }
        guard note.unicodeScalars.count <= 140 else { throw LedgerError.invalid("Notes can contain at most 140 characters.") }
        guard LedgerDates.parse(date) != nil else { throw LedgerError.invalid("Choose a valid date between 2000 and 2100.") }
        self.id = id.lowercased(); self.amountCents = amountCents; self.category = category
        self.note = note; self.date = date
    }
    public func validated() throws -> Expense {
        try Expense(id: id, amountCents: amountCents, category: category, note: note, date: date)
    }
}

public struct Budget: Codable, Equatable, Sendable {
    public var monthlyLimitCents: Int64
    public var currency: String
    public init(monthlyLimitCents: Int64, currency: String = "USD") {
        self.monthlyLimitCents = monthlyLimitCents; self.currency = currency
    }
}
public struct BudgetSummary: Codable, Equatable, Sendable {
    public var spentCents, remainingCents, projectedCents, dailyAllowanceCents: Int64
    public var elapsedDays, daysInMonth, daysRemaining: Int
    public var status: String
}
public struct CategoryTotal: Codable, Equatable, Identifiable, Sendable {
    public var category: String
    public var spentCents: Int64
    public var count: Int
    public var id: String { category }
}
public struct DailyTotal: Codable, Equatable, Identifiable, Sendable {
    public var date: String
    public var spentCents: Int64
    public var id: String { date }
}
public struct Analytics: Codable, Equatable, Sendable {
    public var categories: [CategoryTotal]
    public var daily: [DailyTotal]
    public var largest: [Expense]
}
public struct Dashboard: Codable, Equatable, Sendable {
    public var month, asOf, currency: String
    public var monthlyLimitCents: Int64
    public var summary: BudgetSummary
    public var analytics: Analytics
    public var calculationSources: [String: String]
}

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
}
