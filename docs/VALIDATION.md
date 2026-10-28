# Validation record

Verified locally on Windows on October 27, 2026. All records used in tests and screenshots are synthetic. Source review, compilation, unit testing, device execution, and production deployment are distinguished below.

| Component | Completed verification |
|---|---|
| Go API / SQLite / subprocess runner | `go test ./...` and `go vet ./...` passed; HTTP validation/replay/conflict behavior, SQLite persistence/concurrent operations, and actual subprocess failure/timeout/output limits |
| Haskell worker | Compiled with GHC 9.6.7/Cabal 3.12.1.0; focused validation/boundary checks and 784 generated exact-arithmetic cases passed |
| Scala worker | Compiled standalone JAR with Scala 3.3.6/Scala CLI 1.9.1; 8 test groups passed, including 300 generated conservation/order cases |
| Worker wire protocols | 43 actual subprocess cases passed against the final executable/JAR, including invalid UTF-8/trailing input, strict integer literals, tiny fractional values, quoted numeric-looking notes, UUIDs and calendar boundaries |
| Live HTTP / cross-language path | 26 assertions passed using the actual Go server and both workers; verifies leap-month cutoffs, exact cents, aggregation conservation, replay/conflict behavior, invalid input, repeated deletes, and restart persistence |
| Kotlin Android JVM tests | 18 passed: 6 money/validation, 9 synchronization, 3 CSV escaping; zero failures/errors/skips |
| Android packaging | Debug app and instrumentation APKs compiled successfully with JDK 17, SDK 35, AGP 8.9.2, Gradle 8.11.1 and Kotlin 2.1.20 |
| Android Emulator / device tests | 5 passed on API 35 with WHPX; zero failures/skips. Includes Compose form/settings interaction, three actual SQLite persistence/server-binding tests, and the native HTTP client talking to Go/Haskell/Scala |
| Swift core / Objective-C | Static review and regression source written; **not compiled or executed**. Includes 33 unit-test functions covering money, persistence, races, CSV and receipt parsing |
| SwiftUI app | Source and manual macOS workflow provided; **iOS build, simulator UI test, physical-iPhone execution and OCR accuracy validation remain pending** |
| Hosted GitHub Actions | **No jobs run**; workflows are manual-only. No billing settings were changed |

## Commands and evidence

- Go: from `server/`, `go test ./...` followed by `go vet ./...`.
- Workers: `workers/build.ps1`, then `python workers/test_protocol.py`.
- End to end: `python scripts/verify.py`; its report is regenerated under `.local/integration-result.json`.
- Android: `gradlew.bat testDebugUnitTest assembleDebug assembleDebugAndroidTest`.
- Device: `connectedDebugAndroidTest` with the documented `pocketledger.testServer` argument against an isolated local API ledger. Android XML reports are generated under `android/app/build/outputs/androidTest-results/connected/debug/`.

The first instrumentation attempt on the newly booted emulator hit a startup ANR before test execution. After first-boot setup and APK warm-up, both direct instrumentation and the standard Gradle device run passed all five tests. No tests were skipped and no replacement/fake analytics was introduced.

The Go race detector was not run on Windows. Unix worker scripts were reviewed but not executed in this Windows validation. No production deployment, measured scalability, app-store release, or physical-iPhone testing is claimed.

## Android debug artifact

The generated APK is `android/app/build/outputs/apk/debug/app-debug.apk` (10,821,812 bytes), deliberately ignored by Git along with SDKs, caches, local ledgers and raw machine-specific reports.

SHA-256: `a71c88fd0a2b18271812d63adf6b10716f53fd829ea3cd5728ade94a6a0f6bd2`.

The debug artifact is for development and emulator/device testing; its existence is not an app-store publication claim.
