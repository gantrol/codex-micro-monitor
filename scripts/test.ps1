$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
dotnet test (Join-Path $root 'tests/CodexMicro.Desktop.Tests') -c Release --logger 'trx;LogFileName=standalone.trx' --results-directory (Join-Path $root '.artifacts/tests')
exit $LASTEXITCODE
