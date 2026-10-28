#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.local/workers"
cd "$ROOT/workers/haskell"
cabal build budget-engine
if [ "${SKIP_TESTS:-0}" != 1 ]; then
  cabal test budget-tests --test-show-details=direct
fi
cp "$(cabal list-bin budget-engine -v0)" "$ROOT/.local/workers/budget-engine"
cd "$ROOT"
scala_cli() {
  if [ -n "${SCALA_CLI_JAR:-}" ]; then
    java -jar "$SCALA_CLI_JAR" "$@"
  elif [ -f "$ROOT/.tools/scala-cli.jar" ]; then
    java -jar "$ROOT/.tools/scala-cli.jar" "$@"
  else
    scala-cli "$@"
  fi
}
if [ "${SKIP_TESTS:-0}" != 1 ]; then
  scala_cli test workers/scala --server=false
fi
scala_cli --power package workers/scala/project.scala workers/scala/src --assembly --server=false --main-class pocketledger.Main --force -o "$ROOT/.local/workers/analytics.jar"
printf '%s\n' 'Built .local/workers/budget-engine and .local/workers/analytics.jar'
