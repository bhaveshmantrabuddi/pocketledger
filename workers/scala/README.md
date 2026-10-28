# Scala analytics worker

`Engine.parse` validates each request and every transaction before filtering. `Engine.calculate` is pure: it returns observed category totals, every completed calendar day including zeros, and the five largest expenses with deterministic tie ordering. UUIDs are validated case-insensitively and normalized to lowercase.

Scala 3.3.6, ujson 4.2.1 and MUnit 1.0.2 are pinned in `project.scala`. From the repository root with Java 17 and Scala CLI:

```text
scala-cli test workers/scala --server=false
scala-cli --power package workers/scala/project.scala workers/scala/src --assembly --server=false --main-class pocketledger.Main -o .local/workers/analytics.jar
```

The parent worker build scripts create the output directory and support the portable Scala CLI JAR. Aggregate addition checks `Long` overflow; JSON totals are emitted as exact integer literals, avoiding ujson's Double representation for aggregate values. The process explicitly reads and writes UTF-8, including on Windows.
