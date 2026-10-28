param([string]$Listen = '127.0.0.1:8080')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$portableGo = Join-Path $repo '.tools/go/bin/go.exe'
$goCommand = if (Test-Path -LiteralPath $portableGo) { $portableGo } else { 'go' }
$output = Join-Path $repo '.local/bin/pocketledger.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
Push-Location (Join-Path $repo 'server')
try {
    & $goCommand build -o $output ./cmd/pocketledger
    if ($LASTEXITCODE -ne 0) { throw 'API build failed' }
} finally { Pop-Location }
Push-Location $repo
try { & $output -listen $Listen }
finally { Pop-Location }
