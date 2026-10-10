[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
[xml]$metadata = Get-Content -LiteralPath (Join-Path $root 'Version.props') -Raw
$version = [string]$metadata.Project.PropertyGroup.Version
[xml]$dependencies = Get-Content -LiteralPath (Join-Path $root 'Directory.Packages.props') -Raw
$controlVersion = [string]$dependencies.Project.PropertyGroup.CodexControlVersion
$controlPackages = foreach ($id in @('CodexControl', 'CodexControl.Windows')) {
    $path = Join-Path $root ".artifacts/control-packages/$id.$controlVersion.nupkg"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Import the pinned control packages first: $path" }
    $path
}
$controlPackageKey = ($controlPackages | ForEach-Object {
    (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
}) -join '-'
$restorePackagesPath = Join-Path $root ".artifacts/nuget-packages/$controlVersion-$controlPackageKey"
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root "dist/github/$version/compact" }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output -match '(?i)trash') { throw 'Unsupported output path.' }
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }
$payload = Join-Path $output 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null

dotnet publish (Join-Path $root 'src/CodexMicro.Desktop/CodexMicro.Desktop.csproj') `
    -c Release -r win-x64 --self-contained false -o $payload `
    -p:PublishSingleFile=true -p:DebugType=None -p:DebugSymbols=false `
    "-p:RestorePackagesPath=$restorePackagesPath" --nologo -v minimal
if ($LASTEXITCODE -ne 0) { throw 'Compact desktop publish failed.' }
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $payload
@"
Codex Micro Monitor $version - Windows x64 compact package

Requires Windows 10 build 19041+ or Windows 11 x64, .NET 10 Desktop Runtime x64,
and the Codex desktop app installed and signed in.
Runtime: https://dotnet.microsoft.com/en-us/download/dotnet/10.0
If a compatible Desktop Runtime is already installed, no runtime installation is needed.
Quit an existing Micro instance, extract the complete ZIP and run CodexMicro.exe.
This portable executable is not Authenticode-signed.

Store (includes runtime): https://apps.microsoft.com/detail/9NTVMG9QNMHC
Source and support: https://github.com/gantrol/codex-micro-monitor
License: GNU General Public License v3.0 only (GPL-3.0-only). See LICENSE.

Windows x64 精简包不包含 .NET 运行时。需要 .NET 10 Desktop Runtime x64；
已有兼容版本时无需重复安装。先退出已运行的 Micro，完整解压后运行 CodexMicro.exe。
本软件需要已安装并登录的 Codex 桌面应用。
"@ | Set-Content -LiteralPath (Join-Path $payload 'INSTALL.txt') -Encoding utf8NoBOM

$archive = Join-Path $output "codex-micro-monitor-$version-win-x64-compact.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($payload, $archive)
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($archive))" |
    Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
[pscustomobject]@{ Archive = $archive; Bytes = (Get-Item -LiteralPath $archive).Length; SHA256 = $hash }
