# PocketLedger workers

Two independent JSON-in/JSON-out workers implement the root contract. Haskell computes budgets with unbounded `Integer` arithmetic; Scala computes deterministic category, calendar-day and top-five analytics. Both validate all transactions before filtering, reject duplicate UUID identities (including mixed-case duplicates), use Gregorian dates in 2000–2100, and accept only the specified categories/fields. Notes are limited by Unicode code points. Standard input is bounded to 16 MiB. Invalid input produces a nonzero exit with diagnostics only on stderr.

## Build and test

Use GHC 9.6.7 with Cabal, Java 17, and Scala CLI. Scala sources pin Scala 3.3.6, ujson 4.2.1 and MUnit 1.0.2. Cabal pins Aeson and a package-index snapshot so dependency resolution does not float with each build. Tools can be installed externally or kept in the ignored root `.tools` directory. `SCALA_CLI_JAR` can select a bootstrapped Scala CLI JAR; otherwise the scripts use `.tools/scala-cli.jar` or `scala-cli` on PATH.

On a fresh Unix Haskell environment, run `cabal update` once before building. The Windows script initializes its project-local Cabal cache if needed, detects `.tools/cabal/cabal.exe` and `.tools/ghc/*/bin/ghc.exe`, and uses existing NTFS short paths when the compiler directory contains spaces. `GHC` can explicitly select the compiler path.

From the repository root:

```powershell
./workers/build.ps1
```

```sh
sh workers/build.sh
```

These run the component tests and produce `.local/workers/budget-engine.exe` on Windows (without `.exe` on Unix) and the standalone `.local/workers/analytics.jar`. Haskell tests combine boundary/validation examples with 784 generated exact-arithmetic cases, including values beyond fixed-width integers. Scala tests cover ordering ties, zero filling, exclusion, Unicode, overflow and 300 seeded generated conservation/order-invariance cases. The pure `calculate` functions are separate from stdin/stdout mains.

To test components separately:

```text
cd workers/haskell
cabal test budget-tests --test-show-details=direct
```

```text
scala-cli test workers/scala --server=false
```

CLI example in a shell supporting input redirection:

```sh
.local/workers/budget-engine < workers/fixtures/reporting.json
java -jar .local/workers/analytics.jar < workers/fixtures/reporting.json
```

The JSON fixtures cover the contract example and leap-month-end overspending. Pace projection is the ceiling of completed-day spending pace, an arithmetic estimate; it is not trained forecasting. Scala uses checked `Long` accumulation and writes totals as exact JSON integer literals rather than converting aggregate cents through floating point. Haskell uses Aeson for parsing/encoding. Neither worker makes network calls at runtime. Build-time dependencies are fetched by Cabal and Scala CLI.

After building, `python workers/test_protocol.py` runs the actual executable/JAR against success fixtures and invalid-input cases, checking stderr/exit behavior and conservation across both workers. This script uses only Python's standard library.

Official tool sources: [GHC releases](https://downloads.haskell.org/), [Cabal releases](https://downloads.haskell.org/~cabal/), and [Scala CLI installation](https://scala-cli.virtuslab.org/install/).
