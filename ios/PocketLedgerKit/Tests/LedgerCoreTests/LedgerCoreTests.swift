import XCTest
@testable import LedgerCore

private actor MockAPI: LedgerAPI {
    var records: [String: Expense] = [:]
    var limit: Int64 = 200000
    var createAttempts = 0
    var loseFirstCreateResponse = false
    var failAfterCreates: Int?
    var pullHook: (@Sendable () async throws -> Void)?
    var dashboardAvailable = false
    var dashboardHook: (@Sendable () async throws -> Void)?
    func setLoseResponse() { loseFirstCreateResponse = true }
    func setFailure(after: Int?) { failAfterCreates = after }
    func setPullHook(_ hook: @escaping @Sendable () async throws -> Void) { pullHook = hook }
    func enableDashboard(hook: (@Sendable () async throws -> Void)? = nil) {
        dashboardAvailable = true; dashboardHook = hook
    }
    func count() -> Int { records.count }
    func attempts() -> Int { createAttempts }
    func create(_ expense: Expense) async throws {
        createAttempts += 1
        if let threshold = failAfterCreates, createAttempts > threshold { throw URLError(.notConnectedToInternet) }
        if let existing = records[expense.id], existing != expense { throw LedgerError.server(409, "Conflict") }
        records[expense.id] = expense
        if loseFirstCreateResponse { loseFirstCreateResponse = false; throw URLError(.networkConnectionLost) }
    }
    func delete(id: String) async throws { records.removeValue(forKey: id) }
    func updateBudget(cents: Int64) async throws { limit = cents }
    func transactions() async throws -> [Expense] {
        if let hook = pullHook { pullHook = nil; try await hook() }
        return Array(records.values)
    }
    func budget() async throws -> Budget { Budget(monthlyLimitCents: limit) }
    func dashboard(month: String, asOf: String) async throws -> Dashboard {
        guard dashboardAvailable else { throw LedgerError.server(503, "Workers unavailable") }
        if let hook = dashboardHook { dashboardHook = nil; try await hook() }
        return Dashboard(month: month, asOf: asOf, currency: "USD", monthlyLimitCents: limit,
                         summary: BudgetSummary(spentCents: 0, remainingCents: limit, projectedCents: 0,
                                                dailyAllowanceCents: 0, elapsedDays: 27, daysInMonth: 31,
                                                daysRemaining: 4, status: "under_budget"),
                         analytics: Analytics(categories: [], daily: [], largest: []),
                         calculationSources: ["summary": "haskell", "analytics": "scala"])
    }
}

final class LedgerCoreTests: XCTestCase {
    private func expense(amount: Int64 = 1250, note: String = "Lunch", date: String = "2026-10-27") throws -> Expense {
        try Expense(amountCents: amount, category: .food, note: note, date: date)
    }
    func testMoneyUsesExactCents() throws {
        XCTAssertEqual(try Money.parse("0.01"), 1)
        XCTAssertEqual(try Money.parse("12.3"), 1230)
        XCTAssertEqual(try Money.parse(" 12.34 "), 1234)
        XCTAssertEqual(try Money.parse("1000000"), 100000000)
    }
    func testMoneyRejectsRoundingNegativeScientificAndOverflow() {
        for text in ["0", "-1", "1.005", "NaN", "1e3", "$5.00", "1000000.01", "9999999999999999999999"] {
            XCTAssertThrowsError(try Money.parse(text), text)
        }
    }
    func testDateValidationIsStrictAndLeapAware() {
        XCTAssertNotNil(LedgerDates.parse("2024-02-29"))
        for date in ["2025-02-29", "2026-02-31", "1999-01-01", "2101-01-01", "2026-2-01"] {
            XCTAssertNil(LedgerDates.parse(date), date)
        }
    }
    func testLocalTodayPreservesCalendarDayAcrossUTCMidnight() throws {
        let formatter = ISO8601DateFormatter()
        let cases: [(String, Int, String)] = [
            ("2026-11-01T01:30:00Z", -4, "2026-10-31"),
            ("2026-01-01T00:30:00Z", -5, "2025-12-31"),
            ("2024-03-01T01:00:00Z", -5, "2024-02-29"),
            ("2026-10-27T23:30:00Z", 9, "2026-10-28")
        ]
        for (instant, offsetHours, expected) in cases {
            let now = try XCTUnwrap(formatter.date(from: instant))
            let zone = try XCTUnwrap(TimeZone(secondsFromGMT: offsetHours * 3600))
            let day = LedgerDates.today(now: now, timeZone: zone)
            XCTAssertEqual(LedgerDates.format(day), expected)
            XCTAssertEqual(day, try XCTUnwrap(LedgerDates.parse(expected)))
            let components = LedgerDates.calendar.dateComponents([.hour, .minute, .second], from: day)
            XCTAssertEqual(components.hour, 0); XCTAssertEqual(components.minute, 0); XCTAssertEqual(components.second, 0)
        }
    }
    func testExpenseValidationAndUnicodeNotes() throws {
        XCTAssertThrowsError(try expense(amount: 0))
        XCTAssertThrowsError(try expense(note: String(repeating: "é", count: 141)))
        XCTAssertEqual(try expense(note: String(repeating: "é", count: 140)).note.count, 140)
    }
    func testJSONUsesContractKeys() throws {
        let record = try expense()
        let data = try JSONCoding.encoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["amount_cents"] as? Int, 1250)
        XCTAssertNil(object["amountCents"])
        XCTAssertEqual(try JSONCoding.decoder().decode(Expense.self, from: data), record)
    }
    func testOfflineQueuePersistsAcrossRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ledger.json")
        let store = try LedgerStore(fileURL: file)
        let record = try expense()
        try await store.add(record); try await store.setBudget(100000)
        let restarted = try LedgerStore(fileURL: file)
        let snapshot = await restarted.snapshot()
        XCTAssertEqual(snapshot.expenses, [record]); XCTAssertEqual(snapshot.pending.count, 2)
        XCTAssertEqual(snapshot.monthlyLimitCents, 100000)
    }
    func testCorruptedFileIsReportedNotOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("not json".utf8); try data.write(to: file)
        XCTAssertThrowsError(try LedgerStore(fileURL: file))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testFailedFileWriteDoesNotAcknowledgeOrChangeMemory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blockedParent = folder.appendingPathComponent("not-a-directory")
        let original = Data("preserve this file".utf8); try original.write(to: blockedParent)
        let store = try LedgerStore(fileURL: blockedParent.appendingPathComponent("ledger.json"))
        let record = try expense()
        do { try await store.add(record); XCTFail("The parent is a file, so saving must fail") } catch {}
        let state = await store.snapshot()
        XCTAssertTrue(state.expenses.isEmpty); XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(try Data(contentsOf: blockedParent), original)
    }
    func testDuplicateLocalExpenseIsRejected() async throws {
        let store = try LedgerStore(); let record = try expense(); try await store.add(record)
        do { try await store.add(record); XCTFail("Duplicate accepted") } catch {}
        let snapshot = await store.snapshot(); XCTAssertEqual(snapshot.pending.count, 1)
    }
    func testLostResponseReplaysSameIDWithoutDuplication() async throws {
        let store = try LedgerStore(); let api = MockAPI(); try await store.add(expense())
        await api.setLoseResponse()
        do { try await store.synchronize(api: api); XCTFail("Lost response should propagate") } catch {}
        let failed = await store.snapshot(); XCTAssertEqual(failed.pending.count, 1)
        try await store.synchronize(api: api)
        let synced = await store.snapshot(); let count = await api.count(); let attempts = await api.attempts()
        XCTAssertEqual(synced.pending.count, 0); XCTAssertEqual(count, 1); XCTAssertEqual(attempts, 2)
    }
    func testPartialFailureOnlyAcknowledgesCompletedOperations() async throws {
        let store = try LedgerStore(); let api = MockAPI()
        try await store.add(expense()); try await store.add(expense(amount: 2200))
        await api.setFailure(after: 1)
        do { try await store.synchronize(api: api); XCTFail("Should fail") } catch {}
        let failed = await store.snapshot(); XCTAssertEqual(failed.pending.count, 1); XCTAssertEqual(failed.expenses.count, 2)
        await api.setFailure(after: nil); try await store.synchronize(api: api)
        let restored = await store.snapshot(); let count = await api.count()
        XCTAssertTrue(restored.pending.isEmpty); XCTAssertEqual(count, 2)
    }
    func testCreateThenDeleteOfflineSyncsInOrder() async throws {
        let store = try LedgerStore(); let api = MockAPI(); let record = try expense()
        try await store.add(record); try await store.delete(id: record.id)
        let offline = await store.snapshot(); XCTAssertTrue(offline.expenses.isEmpty); XCTAssertEqual(offline.pending.count, 2)
        try await store.synchronize(api: api)
        let count = await api.count(); let synced = await store.snapshot()
        XCTAssertEqual(count, 0); XCTAssertTrue(synced.pending.isEmpty)
    }
    func testEditsDuringPullArePreserved() async throws {
        let store = try LedgerStore(); let api = MockAPI(); let later = try expense(note: "Added during network request")
        await api.setPullHook { try await store.add(later) }
        try await store.synchronize(api: api)
        let state = await store.snapshot()
        XCTAssertEqual(state.expenses, [later]); XCTAssertEqual(state.pending.count, 1)
    }
    func testInitialEndpointCanBeConfiguredWithUnsentExpenses() async throws {
        let store = try LedgerStore(); try await store.add(expense()); try await store.setBudget(123456)
        try await store.setEndpoint("http://192.168.1.20:8080")
        let state = await store.snapshot(); XCTAssertEqual(state.pending.count, 2)
        XCTAssertEqual(state.expenses.count, 1); XCTAssertEqual(state.monthlyLimitCents, 123456)
        XCTAssertEqual(state.endpoint, "http://192.168.1.20:8080")
    }
    func testChangingBoundEndpointClearsOnlyOldServerCache() async throws {
        let store = try LedgerStore(); let api = MockAPI()
        try await store.add(expense()); try await store.setBudget(123456)
        try await store.synchronize(api: api)
        await api.enableDashboard()
        try await store.refreshDashboard(api: api, month: "2026-10", asOf: "2026-10-27")
        let before = await store.snapshot()
        XCTAssertNotNil(before.lastSync); XCTAssertNotNil(before.cachedDashboard)
        XCTAssertTrue(before.serverHasAcknowledgedChanges)
        try await store.setEndpoint("http://127.0.0.1:9090")
        let after = await store.snapshot()
        XCTAssertTrue(after.expenses.isEmpty); XCTAssertTrue(after.pending.isEmpty)
        XCTAssertEqual(after.monthlyLimitCents, 200000)
        XCTAssertNil(after.lastSync); XCTAssertNil(after.cachedDashboard)
        XCTAssertFalse(after.serverHasAcknowledgedChanges)
        let remoteCount = await api.count(); XCTAssertEqual(remoteCount, 1)
    }
    func testChangingBoundEndpointWithPendingChangesIsRejected() async throws {
        let store = try LedgerStore(); let api = MockAPI()
        try await store.add(expense()); try await store.synchronize(api: api)
        try await store.add(expense(note: "Still pending"))
        do { try await store.setEndpoint("http://127.0.0.1:9090"); XCTFail("Pending edits belong to the bound server") } catch {}
        let state = await store.snapshot()
        XCTAssertEqual(state.endpoint, "http://127.0.0.1:8080")
        XCTAssertEqual(state.expenses.count, 2); XCTAssertEqual(state.pending.count, 1)
    }
    func testReportFromPreviousEndpointIsDiscardedAfterAwait() async throws {
        let store = try LedgerStore(); let api = MockAPI()
        try await store.synchronize(api: api)
        await api.enableDashboard {
            try await store.setEndpoint("http://127.0.0.1:9090")
        }
        do { try await store.refreshDashboard(api: api, month: "2026-10", asOf: "2026-10-27"); XCTFail("Old server report must not be cached") } catch {}
        let state = await store.snapshot()
        XCTAssertEqual(state.endpoint, "http://127.0.0.1:9090"); XCTAssertNil(state.cachedDashboard)
    }
    func testReportIsDiscardedWhenConcurrentEditHasAlreadySynced() async throws {
        let store = try LedgerStore(); let api = MockAPI(); let later = try expense(note: "Newer than report")
        await api.enableDashboard {
            try await store.add(later)
            try await store.synchronize(api: api)
        }
        do { try await store.refreshDashboard(api: api, month: "2026-10", asOf: "2026-10-27"); XCTFail("The completed sync changed the report snapshot") } catch {}
        let state = await store.snapshot()
        XCTAssertEqual(state.expenses, [later]); XCTAssertTrue(state.pending.isEmpty)
        XCTAssertNil(state.cachedDashboard)
    }
    func testInvalidEndpointsAreRejected() {
        for endpoint in ["file:///private/data", "http://user:password@example.com", "https://example.com/path", "not a URL"] {
            XCTAssertThrowsError(try HTTPAPI(endpoint: endpoint), endpoint)
        }
    }
    func testDashboardFailureDoesNotDeleteExpenses() async throws {
        let store = try LedgerStore(); let api = MockAPI(); try await store.add(expense())
        try await store.synchronize(api: api)
        do { try await store.refreshDashboard(api: api, month: "2026-10", asOf: "2026-10-27"); XCTFail("Expected worker error") } catch {}
        let state = await store.snapshot(); XCTAssertEqual(state.expenses.count, 1); XCTAssertNil(state.cachedDashboard)
    }
}
