import SwiftUI
import Charts
import PhotosUI
import UniformTypeIdentifiers
import LedgerCore

struct LedgerRootView: View {
    @ObservedObject var model: LedgerViewModel
    @State private var showingAdd = false
    @State private var exporting = false
    var body: some View {
        TabView {
            NavigationStack { overview }.tabItem { Label("Overview", systemImage: "chart.pie.fill") }
            NavigationStack { transactions }.tabItem { Label("Expenses", systemImage: "list.bullet.rectangle") }
            NavigationStack { LedgerSettingsView(model: model) }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .sheet(isPresented: $showingAdd) { AddExpenseView(model: model) }
        .fileExporter(isPresented: $exporting, document: ExpenseCSVDocument(text: CSVExporter.export(model.expenses)),
                      contentType: .commaSeparatedText, defaultFilename: "PocketLedger-\(model.month).csv") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .alert("PocketLedger", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var monthPicker: some View {
        HStack {
            Button { model.changeMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
            Spacer(); Text(model.monthTitle).font(.headline); Spacer()
            Button { model.changeMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
                .disabled(model.month == String(LedgerDates.format(LedgerDates.today()).prefix(7)))
        }
    }
    private var syncButton: some View {
        Button { Task { await model.synchronize() } } label: {
            if model.busy { ProgressView() } else { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }.disabled(model.busy).accessibilityIdentifier("syncButton")
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                monthPicker
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR MONTH, IN FOCUS").font(.caption.weight(.semibold)).tracking(2)
                    Text(Money.display(abs(model.snapshot.monthlyLimitCents - model.spent)))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                        .accessibilityIdentifier("remainingAmount")
                    Text(model.spent > model.snapshot.monthlyLimitCents ? "over your monthly budget" : "left in your monthly budget")
                        .font(.subheadline)
                    ProgressView(value: min(Double(model.spent) / Double(model.snapshot.monthlyLimitCents), 1))
                        .tint(.ledgerLime)
                    HStack {
                        Text("Spent \(Money.display(model.spent))")
                        Spacer(); Text("Budget \(Money.display(model.snapshot.monthlyLimitCents))")
                    }.font(.caption)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [.ledgerTeal, Color(red: 0.02, green: 0.24, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 10) {
                    Image(systemName: model.snapshot.pending.isEmpty ? "checkmark.circle" : "icloud.and.arrow.up")
                    VStack(alignment: .leading) {
                        Text(model.status).font(.subheadline.weight(.medium))
                        Text("\(model.snapshot.pending.count) pending changes · USD only").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { showingAdd = true } label: {
                    Label("Add expense", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("addExpenseButton")
                if !model.categories.isEmpty {
                    Text("Where it went").font(.title3.bold())
                    Chart(model.categories, id: \.0) { category, cents in
                        BarMark(x: .value("USD", Double(cents) / 100), y: .value("Category", category))
                            .foregroundStyle(Color.ledgerTeal.gradient).cornerRadius(4)
                    }.frame(height: max(100, CGFloat(model.categories.count) * 36))
                    ForEach(model.categories, id: \.0) { category, cents in
                        HStack { Text(category); Spacer(); Text(Money.display(cents)).monospacedDigit() }.font(.subheadline)
                    }
                } else {
                    ContentUnavailableView("A fresh start", systemImage: "leaf", description: Text("Add your first expense to see this month's spending."))
                }
                if let report = model.report {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Spending pace", systemImage: "waveform.path").font(.headline)
                        metric("Month-end pace estimate", report.summary.projectedCents)
                        metric("Per remaining day", report.summary.dailyAllowanceCents)
                        Text("Based on spending through \(report.asOf). A simple pace estimate, not a prediction.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Calculated by Haskell · analytics by Scala").font(.caption2).foregroundStyle(.secondary)
                    }.padding().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Label("Sync to calculate your spending pace.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.background(Color(.systemGroupedBackground))
            .navigationTitle("PocketLedger")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { syncButton } }
            .refreshable { await model.synchronize() }
    }
    private func metric(_ title: String, _ cents: Int64) -> some View {
        HStack { Text(title).font(.subheadline); Spacer(); Text(Money.display(cents)).font(.subheadline.bold()).monospacedDigit() }
    }
    private var transactions: some View {
        List {
            Section { monthPicker }
            if model.expenses.isEmpty {
                ContentUnavailableView("No expenses this month", systemImage: "tray", description: Text("Expenses are saved on your device, even offline."))
            }
            ForEach(model.expenses) { expense in
                HStack(spacing: 14) {
                    Image(systemName: "creditcard").foregroundStyle(Color.ledgerTeal)
                        .frame(width: 36, height: 36).background(Color.ledgerTeal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(expense.note.isEmpty ? expense.category.title : expense.note).font(.body.weight(.medium))
                        Text("\(expense.category.title) · \(expense.date)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Text(Money.display(expense.amountCents)).font(.body.weight(.semibold)).monospacedDigit()
                }.padding(.vertical, 3)
                    .swipeActions { Button("Delete", role: .destructive) { Task { await model.delete(expense) } } }
            }
        }.navigationTitle("Expenses")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export month as CSV") }
                ToolbarItem(placement: .topBarTrailing) { Button { showingAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add expense") }
            }
    }
}

private struct ExpenseCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct LedgerSettingsView: View {
    @ObservedObject var model: LedgerViewModel
    @State private var budget = ""
    @State private var endpoint = ""
    var body: some View {
        Form {
            Section("Monthly budget · USD") {
                TextField("Budget amount", text: $budget).keyboardType(.decimalPad).accessibilityIdentifier("budgetInput")
                Button("Save budget") { Task { await model.saveBudget(budget) } }
            }
            Section("Sync server") {
                TextField("http://127.0.0.1:8080", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save server address") { Task { await model.saveEndpoint(endpoint) } }
                    .disabled(model.busy)
                Button("Sync now") { Task { await model.synchronize() } }.disabled(model.busy)
                Text("The local demo API has no account protection. Use it only on your computer or a trusted private network.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("After syncing, changing servers clears the previous server's cached expenses, budget, and report on this device. Sync pending changes first. Initial server setup keeps unsent offline edits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About your ledger") {
                LabeledContent("Currency", value: "USD")
                LabeledContent("Pending changes", value: String(model.snapshot.pending.count))
                Text("Expenses stay on this device until you choose to sync. Receipt recognition runs on-device. Suggestions require your confirmation.")
                    .font(.footnote)
            }
        }.navigationTitle("Settings")
            .onAppear { budget = Money.input(model.snapshot.monthlyLimitCents); endpoint = model.snapshot.endpoint }
            .onChange(of: model.snapshot.endpoint) { _, address in
                endpoint = address
                budget = Money.input(model.snapshot.monthlyLimitCents)
            }
    }
}

private struct AddExpenseView: View {
    @ObservedObject var model: LedgerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var note = ""
    @State private var date = LedgerDates.today()
    @State private var category = ExpenseCategory.food
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var scanning = false
    @State private var receiptMessage: String?
    @State private var localError: String?
    @FocusState private var focusedField: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Expense · USD") {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("expenseAmount").focused($focusedField, equals: "amount")
                    TextField("What was it for?", text: $note).accessibilityIdentifier("expenseNote").focused($focusedField, equals: "note")
                    Picker("Category", selection: $category) { ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.title).tag($0) } }
                    DatePicker("Date", selection: $date, in: LedgerDates.parse("2000-01-01")!...min(LedgerDates.today(), LedgerDates.parse("2100-12-31")!), displayedComponents: .date)
                        .environment(\.calendar, LedgerDates.calendar)
                        .environment(\.timeZone, LedgerDates.calendar.timeZone)
                }
                Section("Receipt helper") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Read a receipt photo", systemImage: "doc.text.viewfinder") }
                        .disabled(scanning)
                    if scanning { ProgressView("Reading on this device…") }
                    if let receiptMessage { Text(receiptMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("Check the suggested merchant, date, and total before saving. No photo is uploaded or kept in the ledger.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Save expense") {
                        Task {
                            do { try await model.add(amount: amount, category: category, note: note, date: date); dismiss() }
                            catch { localError = error.localizedDescription }
                        }
                    }.font(.headline).accessibilityIdentifier("saveExpenseButton")
                }
            }.navigationTitle("Add expense")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil } }
                }
                .alert("Check your expense", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                    Button("OK", role: .cancel) { localError = nil }
                } message: { Text(localError ?? "") }
                .onChange(of: selectedPhoto) { _, photo in
                    guard let photo else { return }
                    Task {
                        scanning = true; defer { scanning = false }
                        do {
                            guard let data = try await photo.loadTransferable(type: Data.self), data.count <= 20_000_000 else {
                                throw LedgerError.invalid("Choose an image smaller than 20 MB.")
                            }
                            let receipt = try await model.recognize(data)
                            if let total = receipt.totalCents { amount = Money.input(total.int64Value) }
                            if let merchant = receipt.merchant { note = merchant }
                            if let text = receipt.dateString, let parsed = LedgerDates.parse(text) { date = parsed }
                            receiptMessage = receipt.totalCents == nil ? "No explicit total was found. Enter the amount manually." : "Suggestions filled in. Please review them before saving."
                        } catch { receiptMessage = error.localizedDescription }
                    }
                }
        }
    }
}
