# PocketLedger for Android

A native Kotlin and Jetpack Compose expense tracker with a persistent local ledger. Add expenses, browse months, inspect local category totals, delete entries, set a monthly USD budget and explicitly sync with the Go API. The app opens with an empty ledger; use synthetic demo expenses.

## Build

Prerequisites: JDK 17, Android SDK platform 35 and build-tools 35.0.0. Set `ANDROID_HOME` to your SDK, or set `sdk.dir` in an untracked `local.properties`. Android Studio can install the required SDK packages. The checked-in Gradle wrapper pins Gradle 8.11.1 and verifies its distribution SHA-256. AGP 8.9.2, Kotlin/Compose compiler 2.1.20 and Compose BOM 2025.04.01 are pinned stable releases.

From this directory:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest
```

On Windows, use `gradlew.bat` with the same tasks. The debug APK is generated under `app/build/outputs/apk/debug/`. Install it on an API 26+ Android device/emulator:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

With a running emulator or connected device, execute the device tests:

```sh
./gradlew :app:connectedDebugAndroidTest
```

For the optional wire test, point the suite at a disposable local Go server with both real workers configured:

```sh
./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.pocketledger.testServer=http://10.0.2.2:18080
```

Without that argument the wire test is skipped. It creates and removes a synthetic expense, verifies identical POST replay and conflicting-ID rejection, exercises budget PUTs, and checks real Haskell/Scala dashboard output. It temporarily changes the disposable server's budget and restores it in cleanup; it never touches the app's SQLite ledger.

The app requires no accounts, keys or bank integrations. Build outputs, SDKs, dependency caches and local SDK paths are ignored. No signing key is checked in; the debug build uses the Android toolchain's local development keystore.

## Connect the server

Settings defaults to `http://10.0.2.2:8080`, which reaches the host computer from Android Emulator. Start the Go API as documented at repository root. On a physical device, use the computer's LAN address and explicitly bind the development server to a reachable interface. HTTP is enabled for this local demo; the endpoint also accepts HTTPS. The single-ledger API has no authentication and is intended for local development.

Tap **Sync** to send changes and refresh the snapshot. There is no automatic background sync. Before the first acknowledged operation or applied server snapshot, endpoint setup preserves all offline expenses and queued operations. After that first server binding, pending operations must be sent before switching to another origin. Switching a bound ledger clears the synced cache so data from different servers is not mixed.

**Export CSV** opens Android's share chooser for the selected month's records. Only an app-cache export directory is exposed through FileProvider; sharing is user-initiated. Fields are quoted, embedded quotes/newlines are preserved, and spreadsheet-formula prefixes in user text are escaped.

## Persistence and replay behavior

`LedgerDatabase` uses Android SQLite, including a transactionally written expense row and ordered operation queue. Deletes become local tombstones until acknowledged. Budget edits update the local limit and enqueue a persistent PUT operation. The queue, endpoint and last successful server dashboard survive app restarts.

`SyncEngine` sends the queue in sequence. Each successful operation is acknowledged separately. A partial failure leaves all unacknowledged operations intact and prevents replacing the device ledger with a server snapshot. If the server committed a request but its response was lost, the original UUID/payload is replayed; the API's identical POST replay, repeated DELETE and budget PUT semantics make retries safe. Local changes made during a snapshot fetch prevent replacement through an atomic queue-empty check.

The overview's spending and category bars are explicitly on-device totals through the selected reporting day. Cached server pace estimates are separately labeled with their as-of date and Haskell/Scala source. Pending changes are not included in cached server analytics. A worker failure does not erase acknowledged expenses or invent replacement analytics.

Money is parsed directly into integer cents; extra decimal places, negative/zero amounts, exponent notation and out-of-range values are rejected. Dates use strict Gregorian parsing for 2000–2100. Notes are limited to 140 Unicode code points.

## CSV sharing

Use **Export CSV** for the selected month's expenses. The native Android share sheet receives a temporary UTF-8 CSV through a cache-scoped FileProvider with read permission; no file is sent until the user chooses a destination. Columns include integer `amount_cents` and `currency=USD`. The exporter quotes cells, doubles embedded quotes, preserves commas/newlines/Unicode and prefixes spreadsheet-formula-like text with an apostrophe. Tests exercise these cases. Device verification does not share anything with an external app.

## Tests

JVM tests exercise exact monetary parsing/formatting, limits, leap dates, Unicode notes, partial acknowledgement, a committed POST with lost response, create-then-delete ordering, repeated deletes, budget retries, ID conflicts, cancellation and local writes racing a snapshot pull, plus CSV escaping/formula protection. Device tests exercise SQLite queue persistence across close/reopen, endpoint-switch protection and a Compose form/settings smoke flow.

Device tests require an emulator/device; compiling their APK is not evidence that they were executed. See repository root verification notes for the actual commands and results from this environment.

The optional `LiveApiIntegrationTest` uses the `pocketledger.testServer` instrumentation argument to exercise the real HTTP client. Without that argument, that one test is skipped. The recorded validation supplied the argument and executed all five tests with no skips. Allow a newly created emulator to finish initial boot/package setup before starting instrumentation.

## Wrapper attribution

The unmodified Gradle wrapper bootstrap JAR and scripts come from Gradle 8.11.1. The official Apache 2.0 license is retained in `gradle/wrapper/LICENSE`; `NOTICE` records the source, and the wrapper JAR checksum is checked against the official release checksum.

## Version references

- [AGP 8.9 compatibility and patch releases](https://developer.android.com/build/releases/agp-8-9-0-release-notes)
- [Compose compiler plugin setup](https://developer.android.com/develop/ui/compose/compiler)
- [Compose BOM version mapping](https://developer.android.com/jetpack/compose/bom/bom-mapping)
