import Foundation
import SwiftUI
import UIKit
import LedgerCore
import ReceiptKit

@MainActor
final class LedgerViewModel: ObservableObject {
    @Published var snapshot = LedgerSnapshot()
    @Published var busy = false
    @Published var error: String?
    @Published var status = "Saved on this device"
    @Published var selectedMonth = LedgerDates.today()
    private var store: LedgerStore?

    init() {
        do {
            let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
            let url = testing ? nil : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PocketLedger/ledger.json")
            store = try LedgerStore(fileURL: url)
            Task {
                if testing {
                    let today = LedgerDates.format(LedgerDates.today())
                    try await store?.add(Expense(amountCents: 1850, category: .food, note: "Campus lunch", date: today))
                    try await store?.add(Expense(amountCents: 4500, category: .transport, note: "Transit pass", date: today))
                }
                await reload()
            }
        } catch { self.error = "Could not open your saved ledger: \(error.localizedDescription)" }
    }
    var month: String { String(LedgerDates.format(selectedMonth).prefix(7)) }
    var asOf: String {
        let calendar = LedgerDates.calendar
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth))!
        let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
        return LedgerDates.format(min(LedgerDates.today(), end))
    }
    var monthTitle: String {
        let formatter = DateFormatter(); formatter.calendar = LedgerDates.calendar
        formatter.timeZone = LedgerDates.calendar.timeZone; formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: selectedMonth)
    }
    var expenses: [Expense] {
        snapshot.expenses.filter { $0.date.hasPrefix(month) && $0.date <= asOf }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    var spent: Int64 { expenses.reduce(0) { $0 + $1.amountCents } }
    var report: Dashboard? {
        guard let report = snapshot.cachedDashboard, report.month == month,
              report.asOf == asOf, snapshot.pending.isEmpty else { return nil }
        return report
    }
    var categories: [(String, Int64)] {
        Dictionary(grouping: expenses, by: { $0.category.title })
            .map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.amountCents }) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    func reload() async { if let store { snapshot = await store.snapshot() } }
    func changeMonth(_ amount: Int) {
        guard let next = LedgerDates.calendar.date(byAdding: .month, value: amount, to: selectedMonth),
              String(LedgerDates.format(next).prefix(7)) >= "2000-01",
              String(LedgerDates.format(next).prefix(7)) <= String(LedgerDates.format(LedgerDates.today()).prefix(7)) else { return }
        selectedMonth = next
    }
    func add(amount: String, category: ExpenseCategory, note: String, date: Date) async throws {
        guard let store else { throw LedgerError.invalid("Local storage is unavailable.") }
        let expense = try Expense(amountCents: Money.parse(amount), category: category,
                                  note: note.trimmingCharacters(in: .whitespacesAndNewlines), date: LedgerDates.format(date))
        try await store.add(expense); await reload(); status = "Expense saved offline"
    }
    func delete(_ expense: Expense) async {
        guard let store else { error = "Local storage is unavailable."; return }
        do { try await store.delete(id: expense.id); await reload() }
        catch { self.error = error.localizedDescription }
    }
    func saveBudget(_ amount: String) async {
        guard let store else { error = "Local storage is unavailable."; return }
        do { try await store.setBudget(Money.parse(amount)); await reload(); status = "Budget saved on this device" }
        catch { self.error = error.localizedDescription }
    }
    func saveEndpoint(_ endpoint: String) async {
        guard !busy else { error = LedgerError.alreadySyncing.localizedDescription; return }
        guard let store else { error = "Local storage is unavailable."; return }
        do { try await store.setEndpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)); await reload(); status = "Server address saved" }
        catch { self.error = error.localizedDescription }
    }
    func synchronize() async {
        guard !busy else { return }
        guard let store else { error = "Local storage is unavailable."; return }
        busy = true; defer { busy = false }
        do {
            let api = try HTTPAPI(endpoint: snapshot.endpoint)
            try await store.synchronize(api: api); await reload()
            status = snapshot.pending.isEmpty ? "Expenses synchronized" : "New changes are waiting to sync"
            if snapshot.pending.isEmpty {
                do { try await store.refreshDashboard(api: api, month: month, asOf: asOf); await reload(); status = "Up to date" }
                catch { self.error = "Expenses are synced. The calculated report is unavailable: \(error.localizedDescription)" }
            }
        } catch { await reload(); status = "Offline - your changes are saved"; self.error = error.localizedDescription }
    }
    func recognize(_ data: Data) async throws -> PLReceipt {
        guard let image = UIImage(data: data)?.cgImage else { throw LedgerError.invalid("Choose a supported receipt image.") }
        return try await withCheckedThrowingContinuation { continuation in
            PLReceiptScanner.recognize(image) { receipt, error in
                if let receipt { continuation.resume(returning: receipt) }
                else { continuation.resume(throwing: error ?? LedgerError.invalid("No receipt text could be read.")) }
            }
        }
    }
}
