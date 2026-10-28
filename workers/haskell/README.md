# Haskell budget engine

`BudgetEngine.parseRequest` validates the JSON boundary; `calculate` is a pure calculation over the validated request. It uses unbounded `Integer` values for cents, sums, multiplication and division. Calendar handling uses `time`'s Gregorian calendar. Pace uses ceiling division; future-day allowance uses floor division and becomes zero at month end or when overspent.

With GHC 9.6.7 and Cabal available:

```text
cabal update
cabal build budget-engine
cabal test budget-tests --test-show-details=direct
cabal list-bin budget-engine
```

`cabal.project` fixes the package-index snapshot and the package file pins Aeson 2.2.3.0. The executable accepts one UTF-8 JSON document on stdin and writes one UTF-8 JSON document on stdout. Parsing failure and size-limit errors go to stderr with a nonzero exit.

Use the parent worker build script to copy the executable into the server's `.local/workers` location. On Windows, a compiler installation path without spaces (or its existing NTFS short path) is required by GHC's C-tool launcher; the PowerShell build script handles that conversion.
