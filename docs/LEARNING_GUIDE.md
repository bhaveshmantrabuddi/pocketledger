# Engineering walkthrough

Follow a single expense from a native form to local persistence, an HTTP retry, SQLite, and both calculation workers. The central design is a small financial domain with explicit integration boundaries, not a collection of isolated language demos.

## Kotlin

Read `Domain.kt`, `LedgerDatabase.kt`, `HttpLedgerApi.kt`, and `LedgerViewModel.kt`. Explain why a client-generated UUID is retained across retries, why a failed operation stays queued, and why remote snapshots must not erase concurrent local edits. Extend a category and update its validation tests and UI.

## Go

Read the model, SQLite store, HTTP handlers, and worker runner. Trace a create through validation and a SQL transaction. Compare an identical replay with a same-ID/different-payload conflict. Inspect request limits, subprocess deadlines, and output validation. Change an input boundary and write a regression test before the implementation change.

## Haskell

Find the pure calculation function and separate it from the JSON/IO main. Explain `Integer`, `Either`, record types, explicit validation, calendar lengths, and ceiling versus floor division. Examine generated conservation and boundary checks. Try a different budget projection rule and describe how its interpretation changes.

## Scala

Trace typed input validation, group aggregation, exact money serialization, day-series zero filling, and deterministic tie-breaking. Check why aggregating cents through floating point would be undesirable. Add a weekly aggregate with tests for month boundaries and empty periods.

## Swift

Read the actor-isolated `LedgerStore`, typed API, and `LedgerViewModel`. Explain actor reentrancy across `await`, per-operation acknowledgements, cancellation, and atomic file writes. Reproduce a lost-response test. Explore what happens when a user adds an expense while a remote snapshot is in flight.

## Objective-C

Read `ReceiptKit.h`, `ReceiptParser.m`, and `ReceiptScanner.m`. Explain nullable Objective-C properties, Foundation regular expressions, exact decimal conversion, the Swift import boundary, Core Graphics image lifetime, and off-main-thread Vision requests. Add a receipt fixture that distinguishes subtotal, tax, and the explicit total. Explain why the user must confirm OCR suggestions.

## System tradeoffs

- One local ledger, no account authentication: suitable for a trusted development setup, not an Internet-facing personal-finance service.
- Multiple worker processes: clear language boundaries and independently testable functions, with process-startup and deployment overhead.
- Last-write-wins shared budget and full-snapshot pulling: simple multi-client semantics; no claim of a production conflict-resolution protocol.
- Exact cents and USD-only amounts: deliberately narrower than currency conversion, tax accounting, or financial forecasting.
- On-device receipt recognition: no receipt-image upload, with language/layout limitations and mandatory user review.

See `VALIDATION.md` for the actual verification status. Build configuration or test source alone does not establish a passing result.
