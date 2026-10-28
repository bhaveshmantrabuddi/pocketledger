# PocketLedger Go API

This component stores one local USD ledger in SQLite and serves the native clients. It has no accounts or authentication and listens on `127.0.0.1:8080` by default. Use synthetic data. See the repository's `CONTRACT.md` for the shared schema and worker arithmetic.

## Build and run

Requires Go 1.26 or newer. SQLite uses the pure Go `modernc.org/sqlite` driver; CGO and a system SQLite installation are unnecessary. Build the real workers with the repository worker instructions first. The dashboard also requires Java for the Scala fat JAR.

From `server/`:

```sh
go mod download
go test ./...
go vet ./...
go build -o ../.local/pocketledger ./cmd/pocketledger
go run ./cmd/pocketledger
```

On Windows, name the built executable `../.local/pocketledger.exe`. The repository may provide a portable Go binary under `.tools/go/bin/`; invoke it in place of `go` when needed.

Flags:

```text
-listen          127.0.0.1:8080
-db              <repository>/.local/data/ledger.db
-haskell-worker  <repository>/.local/workers/budget-engine[.exe]
-scala-jar       <repository>/.local/workers/analytics.jar
-java            java
-worker-timeout  10s
```

Default file locations use the nearest ancestor containing `CONTRACT.md`, searching the working directory first, then the executable directory. If no marker exists, they use the working directory. Explicit paths are honored as supplied. Listening beyond loopback is an explicit opt-in; this API does not implement access control. Android Emulator accesses the host loopback through `10.0.2.2`; iOS Simulator uses `localhost`.

## Behavior

- `GET /health` checks SQLite and reports configured worker files/Java availability. Worker booleans do not certify a successful calculation; `/v1/dashboard` executes both processes.
- `GET /v1/transactions` lists descending date, then ascending ID.
- `POST /v1/transactions` returns the canonical transaction: 201 created, 200 identical replay, 409 ID conflict. UUID hexadecimal letters normalize to lowercase. All five fields, including the possibly empty note, are required.
- `DELETE /v1/transactions/{id}` returns 204, including a repeated delete.
- `GET /v1/budget` and `PUT /v1/budget` read/update integer cents. The default is 200000 cents.
- `GET /v1/dashboard?month=2024-02&as_of=2024-02-29` reads a consistent budget/transaction snapshot and merges actual Haskell/Scala results, with explicit source labels. Omitted parameters independently default to today's local month/date; specify both for historical reports.

Request JSON is limited to 16 KiB. Unknown/missing/duplicate fields, trailing JSON, invalid UTF-8, null fields, fractional amounts, invalid dates/categories/UUIDs and out-of-range values return JSON errors. Notes count Unicode code points. Budgets and transaction amounts use integer cents end to end.

SQLite uses one pooled connection, WAL mode, a busy timeout, and atomic insert-or-compare transactions. Concurrent replays cannot create duplicate rows. The database directory is created when needed. Ledger CRUD and budget access remain available when workers fail.

Dashboard workers run concurrently with request cancellation and an individual timeout. Each receives at most 16 MiB of input; each stdout is capped at 1 MiB and stderr at 32 KiB. Failed, missing, timed-out, oversized or malformed workers produce an actionable 503; no Go analytics fallback exists. The server also checks output schemas, dates, membership and total consistency before forwarding results. Calculations always originate in the workers. HTTP shutdown on interrupt/SIGTERM drains in-flight requests for up to five seconds.

## Tests

`go test ./...` covers persisted restart behavior, atomic concurrent creates, replay/conflict/deletion, stable ordering, validation, dashboard cutoff/defaults, and preservation of ledger access after worker failure. Subprocess tests launch a test child executable to exercise stdin/stdout, nonzero exits, invalid output, cancellation, timeout and output caps without requiring other language toolchains. These tests do not replace the repository's real cross-language integration checks.

On a supported host with a race-detector toolchain: `go test -race ./...`. A race test requires CGO even though the application does not. No deployment, performance, production security, automatic background synchronization or financial forecasting claims are made.
