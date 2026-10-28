# Native Apple client

SwiftUI provides the native app. `PocketLedgerKit` separates the Swift financial models, actor-isolated local journal and typed HTTP client from an Objective-C receipt parser and Vision OCR wrapper. There are no external Swift package dependencies.

## Run on a Mac

Install Xcode with an iOS Simulator and [XcodeGen](https://github.com/yonaskolb/XcodeGen). From the repository root:

```sh
swift test --package-path ios/PocketLedgerKit
xcodegen generate --spec ios/project.yml
open ios/PocketLedger.xcodeproj
```

Select the `PocketLedger` scheme and an iPhone Simulator, then run. The default API address is `http://127.0.0.1:8080`; expenses can be added and viewed without the API. Start the Go API and its compiled workers to synchronize and calculate a report.

## Windows and hosted validation

The source can be edited on Windows, but SwiftUI, Vision, and Objective-C Apple-framework compilation require macOS. The manual **Apple validation** workflow runs Swift/Objective-C behavior tests and an iPhone Simulator UI test, exporting screenshots and an `.xcresult` bundle. See [the validation record](../docs/VALIDATION.md) for actual results. Merely including the workflow is not a passing test claim.

## Offline synchronization

The app atomically writes expenses, the ordered pending-operation queue, budget, endpoint and cached report to its Documents directory. It acknowledges each operation only after a successful response. Lost responses replay the same client ID. A pull cannot erase a local change made during an `await`. A first server address can be configured while unsent changes exist; after a server acknowledges data, pending changes must be synchronized before switching servers. A budget is a single shared monthly limit; concurrent clients use last-write-wins updates.

Monthly charts use local expenses through the inclusive report date. A cached server report is shown only for the matching month/date with no pending edits. The projection is a simple spending-pace estimate, not a learned forecast. The CSV file exporter preserves integer cents, quotes fields, and escapes spreadsheet-formula prefixes in user text.

## Receipt scope

Choose an image through the system photo picker. Vision recognizes English receipt text on-device. The Objective-C parser suggests an explicit total, a US/ISO date and a merchant line; it does not infer a total from tax/subtotal/items. The original image is neither uploaded nor retained in the journal. Every suggestion is editable and requires confirmation. OCR accuracy varies by image orientation, lighting and receipt layout; the parser is not an expense-verification system.

## Distribution scope

Simulator builds do not need device signing. Installing on a physical iPhone requires a separate Apple signing/provisioning workflow; no App Store, TestFlight, or physical-device distribution is configured or claimed. Plain HTTP is allowed only to support the local development API; the app is not an Internet-facing authenticated finance product.
