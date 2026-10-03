param(
    [Parameter(Mandatory, ParameterSetName='Controls')]
    [Parameter(Mandatory, ParameterSetName='Lights')][guid]$ThreadId,
    [Parameter(Mandatory, ParameterSetName='Controls')][guid]$SecondThreadId,
    [Parameter(Mandatory)][guid]$RestoreThreadId,
    [Parameter(Mandatory, ParameterSetName='Draft')][switch]$Draft,
    [Parameter(Mandatory, ParameterSetName='Lights')][switch]$Lights
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
$arguments = if ($Draft) { @('--draft', $RestoreThreadId.ToString(), (Join-Path $repoRoot '.artifacts/micro-e2e/draft.json')) }
elseif ($Lights) { @('--lights', $ThreadId.ToString(), $RestoreThreadId.ToString(), (Join-Path $repoRoot '.artifacts/micro-e2e/lights.json')) }
else { @($ThreadId.ToString(), $SecondThreadId.ToString(), $RestoreThreadId.ToString(), (Join-Path $repoRoot '.artifacts/micro-e2e/live.json')) }
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
