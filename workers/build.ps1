param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out = Join-Path $repo '.local/workers'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$scalaJar = if ($env:SCALA_CLI_JAR) { $env:SCALA_CLI_JAR } else { Join-Path $repo '.tools/scala-cli.jar' }
$cabal = if (Get-Command cabal -ErrorAction SilentlyContinue) { (Get-Command cabal).Source } else { Join-Path $repo '.tools/cabal/cabal.exe' }
$ghc = if ($env:GHC) { $env:GHC } elseif (Get-Command ghc -ErrorAction SilentlyContinue) { (Get-Command ghc).Source } else {
    (Get-ChildItem -Path (Join-Path $repo '.tools/ghc/*/bin/ghc.exe') -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not $ghc -or -not (Test-Path -LiteralPath $cabal)) { throw 'GHC and Cabal are required; put them on PATH or use .tools/ghc and .tools/cabal.' }
# GHC's Windows C-tool invocation cannot use installation paths with spaces.
# Existing NTFS short paths avoid changing drives or moving the installation.
if ($ghc.Contains(' ')) {
    if (-not ('PocketLedger.NativePaths' -as [type])) {
        Add-Type -TypeDefinition 'namespace PocketLedger { public static class NativePaths { [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint GetShortPathName(string longPath, System.Text.StringBuilder shortPath, uint size); } }'
    }
    $buffer = [System.Text.StringBuilder]::new(4096)
    if ([PocketLedger.NativePaths]::GetShortPathName($ghc, $buffer, 4096) -eq 0 -or $buffer.ToString().Contains(' ')) {
        throw 'Install GHC in a path without spaces, or set GHC to an existing NTFS short path.'
    }
    $ghc = $buffer.ToString()
}
$compilerArg = "--with-compiler=$ghc"
if (-not $env:CABAL_DIR) { $env:CABAL_DIR = Join-Path $repo '.tools/cabal-home' }
if (-not (Test-Path -LiteralPath (Join-Path $env:CABAL_DIR 'packages/hackage.haskell.org/01-index.cache'))) {
    & $cabal update
    if ($LASTEXITCODE -ne 0) { throw 'Cabal package-index update failed' }
}
function ScalaCli([string[]]$Arguments) {
    if (Test-Path -LiteralPath $scalaJar) { & java -jar $scalaJar @Arguments }
    else { & scala-cli @Arguments }
    if ($LASTEXITCODE -ne 0) { throw 'Scala CLI failed' }
}
Push-Location (Join-Path $PSScriptRoot 'haskell')
try {
    & $cabal build budget-engine $compilerArg
    if ($LASTEXITCODE -ne 0) { throw 'Haskell build failed' }
    if (-not $SkipTests) {
        & $cabal test budget-tests --test-show-details=direct $compilerArg
        if ($LASTEXITCODE -ne 0) { throw 'Haskell tests failed' }
    }
    $binary = (& $cabal list-bin budget-engine -v0 $compilerArg).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate Haskell executable' }
    Copy-Item -LiteralPath $binary -Destination (Join-Path $out 'budget-engine.exe') -Force
} finally { Pop-Location }
Push-Location $repo
try {
    if (-not $SkipTests) { ScalaCli -Arguments @('test', 'workers/scala', '--server=false') }
    ScalaCli -Arguments @('--power', 'package', 'workers/scala/project.scala', 'workers/scala/src', '--assembly', '--server=false', '--main-class', 'pocketledger.Main', '--force', '-o', (Join-Path $out 'analytics.jar'))
} finally { Pop-Location }
Write-Host "Workers built in $out"
