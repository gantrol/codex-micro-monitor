param([switch]$Focused)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$output = Join-Path $root ".artifacts/keycap-tests/$runId"
New-Item -ItemType Directory -Path $output -Force | Out-Null

function Get-InputSnapshot {
    $relativePaths = @(& rg --files (Join-Path $root 'src') (Join-Path $root 'tests') (Join-Path $root 'scripts') `
        -g '!**/bin/**' -g '!**/obj/**' -g '!**/*[Tt][Rr][Aa][Ss][Hh]*/**')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate validation inputs' }
    $relativePaths += @('Directory.Build.props', 'Directory.Packages.props', 'Version.props') | ForEach-Object { Join-Path $root $_ }
    @($relativePaths | Sort-Object -Unique | ForEach-Object {
        [ordered]@{ Path = [IO.Path]::GetRelativePath($root, $_); SHA256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    })
}

$before = Get-InputSnapshot
$before | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'inputs-before.json') -Encoding utf8
$arguments = @('test', (Join-Path $root 'tests/CodexMicro.Desktop.Tests/CodexMicro.Desktop.Tests.csproj'),
    '-c', 'Release', '--settings', (Join-Path $root 'tests/keycaps.coverage.runsettings'),
    '--collect', 'Code Coverage', '--logger', 'trx;LogFileName=tests.trx', '--results-directory', $output)
if ($Focused) { $arguments += @('--filter', 'Scope=Keycaps') }
$logPath = Join-Path $output 'execution.log'
& dotnet @arguments *> $logPath
$testExit = $LASTEXITCODE
$after = Get-InputSnapshot
$after | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'inputs-after.json') -Encoding utf8
$changed = @(Compare-Object ($before | ForEach-Object { "$($_.Path):$($_.SHA256)" }) ($after | ForEach-Object { "$($_.Path):$($_.SHA256)" }))

$trxPath = Join-Path $output 'tests.trx'
if (-not (Test-Path -LiteralPath $trxPath)) {
    Get-Content -LiteralPath $logPath -Tail 30
    throw "Test execution produced no TRX. See $logPath"
}
[xml]$trx = Get-Content -LiteralPath $trxPath -Raw
$results = @($trx.TestRun.Results.UnitTestResult)
$obligations = Get-Content -LiteralPath (Join-Path $root 'tests/keycaps-obligations.json') -Raw | ConvertFrom-Json
$groups = @($obligations.groups | ForEach-Object {
    $rule = $_
    $pattern = '\.' + [regex]::Escape($rule.method) + '(\(|$)'
    $cases = @($results | Where-Object { $_.testName -match $pattern })
    $executed = @($cases | Where-Object { $_.outcome -in @('Passed', 'Failed') }).Count
    [ordered]@{
        Id = $rule.id; RequiredCases = $rule.cases; Executed = $executed
        Passed = @($cases | Where-Object outcome -eq 'Passed').Count
        Failed = @($cases | Where-Object outcome -eq 'Failed').Count
        Complete = $executed -eq $rule.cases
    }
})

$coverageFile = Get-ChildItem -LiteralPath $output -Recurse -Filter '*.cobertura.xml' | Select-Object -First 1
if ($null -eq $coverageFile) { throw "Coverage was not generated. See $logPath" }
[xml]$coverage = Get-Content -LiteralPath $coverageFile.FullName -Raw
$focusFiles = @('CodexActionCatalog.cs', 'CodexKeycapCatalog.cs', 'CodexMicroConfigWriter.cs',
    'CodexMicroLayoutObserver.cs', 'KeycapEditorWindow.xaml.cs', 'SoftwareMicroTransport.cs', 'MainWindow.Keycaps.cs')
$byFile = @($focusFiles | ForEach-Object {
    $name = $_
    $classes = @($coverage.coverage.packages.package.classes.class | Where-Object { [IO.Path]::GetFileName($_.filename) -eq $name })
    $lines = @($classes | ForEach-Object { $_.lines.line })
    $physical = @($lines | Group-Object number)
    $hit = @($physical | Where-Object { @($_.Group | Where-Object { [int]$_.hits -gt 0 }).Count -gt 0 }).Count
    $branches = 0; $coveredBranches = 0
    foreach ($line in $lines) {
        if ($line.'condition-coverage' -match '\((\d+)/(\d+)\)') {
            $coveredBranches += [int]$Matches[1]; $branches += [int]$Matches[2]
        }
    }
    [ordered]@{ File = $name; CoveredLines = $hit; Lines = $physical.Count; CoveredBranches = $coveredBranches; Branches = $branches }
})

$metadata = [ordered]@{
    RecordedAt = [DateTimeOffset]::Now.ToString('o')
    Commit = (& git -C $root rev-parse HEAD)
    Branch = (& git -C $root branch --show-current)
    Focused = [bool]$Focused
    InputsStableDuringRun = $changed.Count -eq 0
    ChangedInputs = $changed
    TestExitCode = $testExit
    Total = $results.Count
    Passed = @($results | Where-Object outcome -eq 'Passed').Count
    Failed = @($results | Where-Object outcome -eq 'Failed').Count
    Unexecuted = @($results | Where-Object { $_.outcome -notin @('Passed', 'Failed') }).Count
    Obligations = $groups
    Pending = $obligations.pending
    CoverageScope = 'Collector: complete loaded CodexMicro.Core/Windows modules; file view: seven named keycap files, physical lines deduplicated, branch records summed. This is not whole-product E2E coverage.'
    CollectorLines = [int]$coverage.coverage.'lines-valid'
    CollectorCoveredLines = [int]$coverage.coverage.'lines-covered'
    CollectorBranches = [int]$coverage.coverage.'branches-valid'
    CollectorCoveredBranches = [int]$coverage.coverage.'branches-covered'
    KeycapFiles = $byFile
    CoverageFile = $coverageFile.FullName
    Failures = @($results | Where-Object outcome -eq 'Failed' | ForEach-Object {
        [ordered]@{ Test = $_.testName; Message = $_.Output.ErrorInfo.Message }
    })
}
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'summary.json') -Encoding utf8
$complete = @($groups | Where-Object Complete -eq $true).Count
Write-Output "Tests: $($metadata.Passed) passed, $($metadata.Failed) failed, $($metadata.Unexecuted) unexecuted."
Write-Output "Isolated obligation groups exercised: $complete/$($groups.Count). Pending boundary groups: $($obligations.pending.Count)."
Write-Output "Evidence: $output"
if ($changed.Count -gt 0) { Write-Warning 'Inputs changed during this run; results are diagnostic only.' }
if ($testExit -ne 0) { exit $testExit }
if ($complete -ne $groups.Count -or $changed.Count -gt 0) { exit 2 }
exit 0
