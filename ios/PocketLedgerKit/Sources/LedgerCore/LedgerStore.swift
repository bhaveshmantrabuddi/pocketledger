import Foundation

public struct PendingOperation: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, delete, budget }
    public let id: String
    public let kind: Kind
    public let expense: Expense?
    public let transactionID: String?
    public let budgetCents: Int64?
    public init(kind: Kind, expense: Expense? = nil, transactionID: String? = nil, budgetCents: Int64? = nil) {
        self.id = UUID().uuidString; self.kind = kind; self.expense = expense
        self.transactionID = transactionID; self.budgetCents = budgetCents
    }
}

public struct LedgerSnapshot: Codable, Equatable, Sendable {
    public var expenses: [Expense] = []
    public var pending: [PendingOperation] = []
    public var monthlyLimitCents: Int64 = 200_000
    public var endpoint: String = "http://127.0.0.1:8080"
    public var cachedDashboard: Dashboard?
    public var lastSync: Date?
    public var serverHasAcknowledgedChanges: Bool = false
    public init() {}
}

public actor LedgerStore {
    private var state: LedgerSnapshot
    private let fileURL: URL?
    private var syncing = false
    private var revision: UInt64 = 0
    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 20_000_000 else { throw LedgerError.invalid("Ledger file exceeds its size limit.") }
            state = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
            _ = try state.expenses.map { try $0.validated() }
            guard Set(state.expenses.map(\.id)).count == state.expenses.count,
                  (1...Money.maximum).contains(state.monthlyLimitCents) else {
                throw LedgerError.invalid("The saved ledger contains invalid records.")
            }
        } else { state = LedgerSnapshot() }
    }
    public func snapshot() -> LedgerSnapshot { state }
    private func commit(_ updated: LedgerSnapshot) throws {
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        }
        state = updated
        revision &+= 1
    }
    public func add(_ expense: Expense) throws {
        let expense = try expense.validated()
        guard !state.expenses.contains(where: { $0.id == expense.id }) else { throw LedgerError.invalid("This expense already exists.") }
        var updated = state
        updated.expenses.append(expense)
        updated.pending.append(.init(kind: .create, expense: expense))
        updated.cachedDashboard = nil
        try commit(updated)
    }
    public func delete(id: String) throws {
        guard state.expenses.contains(where: { $0.id == id }) else { return }
        var updated = state
        updated.expenses.removeAll { $0.id == id }
        updated.pending.append(.init(kind: .delete, transactionID: id))
        updated.cachedDashboard = nil
        try commit(updated)
    }
    public func setBudget(_ cents: Int64) throws {
        guard (1...Money.maximum).contains(cents) else { throw LedgerError.invalid("Budget is outside the allowed range.") }
        var updated = state; updated.monthlyLimitCents = cents
        updated.pending.append(.init(kind: .budget, budgetCents: cents))
        updated.cachedDashboard = nil
        try commit(updated)
    }
    public func setEndpoint(_ endpoint: String) throws {
        _ = try HTTPAPI(endpoint: endpoint)
        guard !syncing else { throw LedgerError.alreadySyncing }
        // Pending local changes must never silently be sent to a different ledger.
        guard state.pending.isEmpty || state.endpoint == endpoint || !state.serverHasAcknowledgedChanges else {
            throw LedgerError.invalid("Sync pending changes before changing servers.")
        }
        var updated = state; updated.endpoint = endpoint; updated.cachedDashboard = nil
        if state.endpoint != endpoint {
            if state.serverHasAcknowledgedChanges {
                // The empty queue means these are the previous server's cache,
                // rather than unacknowledged edits belonging to this device.
                updated.expenses = []
                updated.monthlyLimitCents = 200_000
                updated.lastSync = nil
            }
            updated.serverHasAcknowledgedChanges = false
        }
        try commit(updated)
    }
    public func synchronize(api: any LedgerAPI) async throws {
        guard !syncing else { throw LedgerError.alreadySyncing }
        syncing = true
        defer { syncing = false }
        while let operation = state.pending.first {
            try Task.checkCancellation()
            switch operation.kind {
            case .create:
                guard let expense = operation.expense else { throw LedgerError.invalid("Invalid saved create operation.") }
                try await api.create(expense)
            case .delete:
                guard let id = operation.transactionID else { throw LedgerError.invalid("Invalid saved delete operation.") }
                try await api.delete(id: id)
            case .budget:
                guard let cents = operation.budgetCents else { throw LedgerError.invalid("Invalid saved budget operation.") }
                try await api.updateBudget(cents: cents)
            }
            // Save acknowledgements one at a time. A lost response replays the same UUID.
            var updated = state
            updated.pending.removeAll { $0.id == operation.id }
            updated.serverHasAcknowledgedChanges = true
            try commit(updated)
        }
        let remote = try await api.transactions()
        let budget = try await api.budget()
        // Actor methods can be re-entered during network calls. Preserve concurrent edits.
        guard state.pending.isEmpty else { return }
        var updated = state
        updated.expenses = remote; updated.monthlyLimitCents = budget.monthlyLimitCents
        updated.lastSync = Date()
        updated.serverHasAcknowledgedChanges = true
        try commit(updated)
    }
    public func refreshDashboard(api: any LedgerAPI, month: String, asOf: String) async throws {
        guard state.pending.isEmpty else { throw LedgerError.invalid("Sync local changes before refreshing the server report.") }
        let endpoint = state.endpoint
        let requestRevision = revision
        let dashboard = try await api.dashboard(month: month, asOf: asOf)
        guard state.endpoint == endpoint, revision == requestRevision, state.pending.isEmpty else {
            throw LedgerError.invalid("The ledger or server changed while loading the report. Sync again to refresh it.")
        }
        var updated = state; updated.cachedDashboard = dashboard
        try commit(updated)
    }
}
