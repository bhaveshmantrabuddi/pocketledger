import Foundation

public enum CSVExporter {
    private static func cell(_ value: String) -> String {
        let dangerous = value.trimmingCharacters(in: .whitespacesAndNewlines).first.map { "=+-@".contains($0) } ?? false
        let safe = dangerous ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func export(_ expenses: [Expense]) -> String {
        let header = "id,date,category,amount_cents,currency,note"
        let rows = expenses.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.map { expense in
            [expense.id, expense.date, expense.category.rawValue, String(expense.amountCents), "USD", expense.note]
                .map(cell).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
