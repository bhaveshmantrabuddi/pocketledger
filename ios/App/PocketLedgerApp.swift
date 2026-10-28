import SwiftUI
import LedgerCore

@main
struct PocketLedgerApp: App {
    @StateObject private var model = LedgerViewModel()
    var body: some Scene {
        WindowGroup { LedgerRootView(model: model).tint(.ledgerTeal) }
    }
}

extension Color {
    static let ledgerTeal = Color(red: 0.02, green: 0.43, blue: 0.39)
    static let ledgerLime = Color(red: 0.81, green: 0.94, blue: 0.45)
}
