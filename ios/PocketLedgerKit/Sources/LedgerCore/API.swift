import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol LedgerAPI: Sendable {
    func create(_ expense: Expense) async throws
    func delete(id: String) async throws
    func updateBudget(cents: Int64) async throws
    func transactions() async throws -> [Expense]
    func budget() async throws -> Budget
    func dashboard(month: String, asOf: String) async throws -> Dashboard
}

public final class HTTPAPI: LedgerAPI, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    public init(endpoint: String, session: URLSession = .shared) throws {
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw LedgerError.invalid("Use an HTTP(S) server address without a path or embedded credentials.")
        }
        self.baseURL = url; self.session = session
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LedgerError.invalid("Server returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Request failed."
            throw LedgerError.server(http.statusCode, message)
        }
        guard data.count <= 10_000_000 else { throw LedgerError.invalid("Server response is too large.") }
        return data
    }
    public func create(_ expense: Expense) async throws {
        _ = try await request("v1/transactions", method: "POST", body: JSONCoding.encoder().encode(expense.validated()))
    }
    public func delete(id: String) async throws { _ = try await request("v1/transactions/\(id)", method: "DELETE") }
    public func updateBudget(cents: Int64) async throws {
        struct Update: Encodable { let monthlyLimitCents: Int64 }
        _ = try await request("v1/budget", method: "PUT", body: JSONCoding.encoder().encode(Update(monthlyLimitCents: cents)))
    }
    public func transactions() async throws -> [Expense] {
        struct Response: Decodable { let transactions: [Expense] }
        let data = try await request("v1/transactions")
        let expenses = try JSONCoding.decoder().decode(Response.self, from: data).transactions.map { try $0.validated() }
        guard Set(expenses.map(\.id)).count == expenses.count else { throw LedgerError.invalid("Server returned duplicate expense IDs.") }
        return expenses
    }
    public func budget() async throws -> Budget {
        let data = try await request("v1/budget")
        let result = try JSONCoding.decoder().decode(Budget.self, from: data)
        guard result.currency == "USD", (1...Money.maximum).contains(result.monthlyLimitCents) else { throw LedgerError.invalid("Server returned an invalid budget.") }
        return result
    }
    public func dashboard(month: String, asOf: String) async throws -> Dashboard {
        let data = try await request("v1/dashboard", query: [.init(name: "month", value: month), .init(name: "as_of", value: asOf)])
        return try JSONCoding.decoder().decode(Dashboard.self, from: data)
    }
}
