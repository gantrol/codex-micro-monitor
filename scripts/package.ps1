param([ValidateSet('win-x64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
[xml]$versionFile = Get-Content (Join-Path $root 'Version.props') -Raw
$version = [string]$versionFile.Project.PropertyGroup.Version
$destination = Join-Path $root "dist/$version"
$desktop = Join-Path $destination $Runtime
$plugin = Join-Path $destination 'plugins/codex-micro-keypad'
if (Test-Path -LiteralPath $destination) {
    throw "Package directory already exists: $destination. Move it aside before rebuilding this version."
}
New-Item -ItemType Directory -Force $desktop, $plugin | Out-Null
foreach ($entry in @(
    @{ Project='src/CodexMicro.Desktop/CodexMicro.Desktop.csproj'; Output=$desktop },
    @{ Project='src/CodexMicro.Plugin/CodexMicro.Plugin.csproj'; Output=(Join-Path $plugin 'bin') }
)) {
    dotnet publish (Join-Path $root $entry.Project) -c Release -r $Runtime --self-contained false -o $entry.Output -p:PublishSingleFile=true --nologo -v minimal
    if ($LASTEXITCODE -ne 0) { throw "Publish failed: $($entry.Project)" }
}
Copy-Item -Path (Join-Path $root 'plugins/codex-micro-keypad/*') -Destination $plugin -Recurse
$metadataPath = Join-Path $plugin 'plugin.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$metadata.version = $version
$metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
foreach ($name in @('LICENSE','README.md','README.zh-CN.md')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $desktop
}
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $plugin
$marketplace = Join-Path $destination '.agents/plugins'
New-Item -ItemType Directory -Force $marketplace | Out-Null
Copy-Item -LiteralPath (Join-Path $root '.agents/plugins/marketplace.json') -Destination $marketplace
dotnet pack (Join-Path $root 'src/CodexMicro.Codex/CodexMicro.Codex.csproj') -c Release -o (Join-Path $destination 'packages') --nologo -v minimal
if ($LASTEXITCODE -ne 0) { throw 'Component pack failed.' }
Compress-Archive -Path "$desktop/*" -DestinationPath (Join-Path $destination "codex-micro-monitor-$version-$Runtime.zip")
$pluginArchive = Join-Path $destination "codex-micro-monitor-plugin-$version-$Runtime.zip"
# ZipFile includes the dot-prefixed marketplace directory as well as the plugin.
$zip = [IO.Compression.ZipFile]::Open($pluginArchive, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($directory in @($plugin, $marketplace)) {
        foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse -Force) {
            $relative = [IO.Path]::GetRelativePath($destination, $file.FullName).Replace('\','/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $relative) | Out-Null
        }
    }
} finally { $zip.Dispose() }
Get-ChildItem -LiteralPath $destination -File -Filter '*.zip' |
    Get-FileHash -Algorithm SHA256 |
    Select-Object @{Name='file';Expression={Split-Path -Leaf $_.Path}}, Hash |
    ConvertTo-Json | Set-Content (Join-Path $destination 'SHA256.json') -Encoding utf8NoBOM
Write-Output $destination
