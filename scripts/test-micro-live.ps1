param(
    [Parameter(Mandatory, ParameterSetName='Controls')]
    [Parameter(Mandatory, ParameterSetName='Lights')][guid]$ThreadId,
    [Parameter(Mandatory, ParameterSetName='Controls')][guid]$SecondThreadId,
    [Parameter(Mandatory, ParameterSetName='Controls')]
    [Parameter(Mandatory, ParameterSetName='Lights')]
    [Parameter(Mandatory, ParameterSetName='Draft')][guid]$RestoreThreadId,
    [Parameter(Mandatory, ParameterSetName='Draft')][switch]$Draft,
    [Parameter(Mandatory, ParameterSetName='Lights')][switch]$Lights,
    [Parameter(Mandatory, ParameterSetName='StartupFast')][switch]$StartupFast,
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'tests/CodexMicro.LiveSmoke/CodexMicro.LiveSmoke.csproj'
dotnet build $project -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $repoRoot 'tests/CodexMicro.LiveSmoke/bin/Release/net10.0-windows10.0.19041.0/CodexMicro.Desktop.Tests.exe'))
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
if (-not $ReportPath) {
    $name = if ($StartupFast) { 'startup-fast' } elseif ($Draft) { 'draft' } elseif ($Lights) { 'lights' } else { 'live' }
    $ReportPath = Join-Path $repoRoot ".artifacts/micro-e2e/$name.json"
}
$arguments = if ($StartupFast) { @('--startup-fast', $ReportPath) }
elseif ($Draft) { @('--draft', $RestoreThreadId.ToString(), $ReportPath) }
elseif ($Lights) { @('--lights', $ThreadId.ToString(), $RestoreThreadId.ToString(), $ReportPath) }
else { @($ThreadId.ToString(), $SecondThreadId.ToString(), $RestoreThreadId.ToString(), $ReportPath) }
foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    Write-Output $stdout.GetAwaiter().GetResult()
    Write-Output $stderr.GetAwaiter().GetResult()
    exit $process.ExitCode
} finally { $process.Dispose() }
