[CmdletBinding()]
param([string]$OutputDirectory, [string]$ConfigPath, [switch]$ComposeOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist/store/listing/v2' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'scripts/store-assets.json' }
$arguments = @((Join-Path $PSScriptRoot 'render-store-assets.py'), '--config', $ConfigPath, '--output', $OutputDirectory)
if ($ComposeOnly) { $arguments += '--compose-only' }
python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Store asset export failed.' }
