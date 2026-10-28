# PocketLedger implementation contract

PocketLedger is an educational, USD-only expense tracker. Synthetic demo data only. It does not connect to banks, make investments, or provide financial advice. Keep implementation in this repository; never import internship/coursework sources.

## Components

- `server/`: Go HTTP API, SQLite storage, worker invocation.
- `workers/`: Scala analytics and Haskell budget engine, behavioral tests, build scripts.
- `android/`: Kotlin/Jetpack Compose native Android app with persistent offline queue and unit tests.
- `ios/`: Swift/SwiftUI app and Objective-C receipt extraction library, tests and XcodeGen configuration.
- `contracts/`, `scripts/`, `.github/`: schema, integration verification, development launcher, and manual hosted checks.

Keep each implementation consistent with this contract when changing public interfaces.

## Canonical transaction

```json
{"id":"b5a5bd60-4cec-4297-af3a-c980b7c3b97b","amount_cents":1250,"category":"food","note":"Lunch","date":"2026-10-27"}
```

IDs are UUIDs generated on the client. Amounts are integer USD cents, inclusive range 1..100000000. Categories: `food`, `transport`, `housing`, `shopping`, `health`, `entertainment`, `other`. Note maximum 140 Unicode code points. Dates are valid Gregorian YYYY-MM-DD in years 2000..2100. Clients must reject excess decimal places rather than silently rounding. Money fields use integer JSON literals, without decimal points or exponent notation. Budget range 1..100000000 cents. Default monthly limit is 200000 cents. Single local ledger; no user accounts or production/authentication claims. API binds to 127.0.0.1 by default.

## HTTP API

- `GET /health`: `{ "status":"ok", "storage":"sqlite", "workers":{"haskell":true,"scala":true} }`.
- `GET /v1/transactions`: `{ "transactions":[...] }`, descending date and stable ID.
- `POST /v1/transactions`: canonical transaction; 201 new, 200 identical replay, 409 same ID/different content. Full validation, JSON errors, reject unknown fields/trailing JSON, bounded request size.
- `DELETE /v1/transactions/{id}`: 204, including a repeated delete. Validate UUID.
- `GET /v1/budget`: `{ "monthly_limit_cents":200000, "currency":"USD" }`.
- `PUT /v1/budget`: `{ "monthly_limit_cents":200000 }`; return budget object.
- `GET /v1/dashboard?month=2026-10&as_of=2026-10-27`: dashboard described below. Default current local calendar month/date if omitted. `as_of` must fall within requested month. Exclude transactions later than as_of. Return 503 with actionable JSON error if real worker unavailable; no silent Go fallback.
- Error shape `{ "error":"readable message" }`.

## Worker protocol

Each worker consumes ONE JSON document on stdin and emits ONE JSON document on stdout, exits nonzero with diagnostic on stderr for invalid input. Never logs stdout. No network calls.

Input to both workers:
```json
{"month":"2026-10","as_of":"2026-10-27","monthly_limit_cents":200000,"transactions":[{"id":"b5a5bd60-4cec-4297-af3a-c980b7c3b97b","amount_cents":1250,"category":"food","note":"Lunch","date":"2026-10-27"}]}
```

Workers independently validate range/date/category/UUID and duplicate IDs (reject duplicates). Exclude entries outside the requested month or later than as_of. Haskell uses exact integer arithmetic; Scala guards overflow. `as_of` is an inclusive completed reporting day.

Haskell output:
```json
{"spent_cents":1250,"remaining_cents":198750,"elapsed_days":27,"days_in_month":31,"days_remaining":4,"projected_cents":1436,"daily_allowance_cents":49687,"status":"under_budget"}
```

Projection = ceiling(spent * days_in_month / elapsed_days), clearly a simple pace estimate, not a trained prediction. Remaining may be negative. Daily allowance = floor(max(0,remaining)/days_remaining), or zero at month end. Status under_budget/at_budget/over_budget compares spent with limit. Empty transactions gives zero spent/projected. Handle leap years.

Scala output:
```json
{"categories":[{"category":"food","spent_cents":1250,"count":1}],"daily":[{"date":"2026-10-01","spent_cents":0}],"largest":[{"id":"b5a5bd60-4cec-4297-af3a-c980b7c3b97b","amount_cents":1250,"category":"food","note":"Lunch","date":"2026-10-27"}]}
```

Categories include observed categories, sorted by descending spent then category. Daily includes ALL dates from month start through as_of, zero-filled. Largest is top five filtered expenses, sorting descending amount, then ascending date, then ID.

Go merges into:
```json
{"month":"2026-10","as_of":"2026-10-27","currency":"USD","monthly_limit_cents":200000,"summary":{},"analytics":{},"calculation_sources":{"summary":"haskell","analytics":"scala"}}
```

Worker launch interface: Haskell standalone executable path; Scala fat JAR invoked with `java -jar`. Go flags `-haskell-worker PATH`, `-scala-jar PATH`, `-java PATH`, `-db PATH`, `-listen ADDRESS`. Default locations `.local/workers/budget-engine[.exe]`, `.local/workers/analytics.jar`, `.local/data/ledger.db` relative to repository root.

## Mobile behavior

Persist expenses locally, mark pending creates/deletes, sync on explicit refresh. Replay POSTs safely after network failures. Pull complete server snapshot after successfully flushing pending operations; preserve pending changes on partial failure. Budget edits need a persistent pending flag too. Use localhost on iOS Simulator and 10.0.2.2 on Android Emulator. Expose endpoint configuration. Show offline/sync state clearly; cache last dashboard. Native apps must still add/view expenses while server is offline. No claim of automatic background synchronization.

Objective-C must implement real receipt-text extraction (merchant/date/total) and optional on-device Vision OCR, with structured Swift bridge and tested edge cases. Receipt values remain editable; user confirms before creating an expense. No cloud OCR/upload.

## Verification

Tests must cover behavior: idempotency/conflicts, persistence, validation, partial failures, integer money, leap dates, overspending, deterministic aggregation, native queue logic, receipt parsing. Include cross-language contract fixtures. Do not fabricate passed tests, deployment, platform coverage, awards or performance results.
