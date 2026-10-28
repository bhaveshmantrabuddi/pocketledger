# Third-party software

The MIT license at repository root applies to original PocketLedger source. Third-party tools and dependencies retain their own licenses; source dependencies are declared rather than vendored.

| Component | Dependency / tool | License / source |
|---|---|---|
| Go API | modernc.org/sqlite 1.61.0 and its Go module dependencies | [modernc SQLite module](https://pkg.go.dev/modernc.org/sqlite); see module license and `server/go.sum` |
| Haskell engine | Aeson 2.2.3.0 | BSD-3-Clause; [Aeson](https://hackage.haskell.org/package/aeson-2.2.3.0) |
| Haskell engine | scientific 0.3.8.0 | BSD-3-Clause; [scientific](https://hackage.haskell.org/package/scientific-0.3.8.0) |
| Haskell engine | GHC standard packages | Their respective GHC/BSD licenses; [GHC licensing](https://www.haskell.org/ghc/license) |
| Scala worker | Scala 3.3.6 and Scala library 2.13.16 | Apache-2.0; [Scala](https://github.com/scala/scala3) |
| Scala worker | ujson / upickle-core 4.2.1, geny 1.1.1 | MIT; [uPickle](https://github.com/com-lihaoyi/upickle), [geny](https://github.com/com-lihaoyi/geny) |
| Scala tests | MUnit 1.0.2 | Apache-2.0; [MUnit](https://github.com/scalameta/munit) |
| Android | Kotlin, AndroidX, Compose, coroutines | Primarily Apache-2.0; declared versions are in Android Gradle files |
| Android tests | JUnit 4.13.2 | EPL-1.0; [JUnit](https://github.com/junit-team/junit4) |
| Android wrapper | Gradle wrapper 8.11.1 | Apache-2.0; the distribution checksum and wrapper license/notice are included under `android/gradle/wrapper/` |
| Apple clients | Swift standard libraries / Foundation, Apple SwiftUI, Vision, Core Graphics | Swift runtime licenses and Apple SDK terms; no Apple SDK binaries are committed |

Downloaded SDKs, compilers, caches, databases, and generated application binaries are ignored. When distributing generated binaries separately, include the applicable dependency notices with those artifacts; root MIT does not relicense third-party dependencies.
