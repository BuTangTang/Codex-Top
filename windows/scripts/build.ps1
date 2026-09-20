param([switch]$Publish, [switch]$WindowTests)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$localSdk = Join-Path $projectRoot '.tools/dotnet/dotnet.exe'
$dotnetCommand = if (Test-Path -LiteralPath $localSdk) { $localSdk } else { (Get-Command dotnet -ErrorAction Stop).Source }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
Push-Location -LiteralPath $projectRoot
try {
    & $dotnetCommand run --project tests/CodexTop.Core.Tests/CodexTop.Core.Tests.csproj -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
    & $dotnetCommand build src/CodexTop.Windows/CodexTop.Windows.csproj -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    if ($WindowTests) {
        & $dotnetCommand run --project tests/CodexTop.Windows.Tests/CodexTop.Windows.Tests.csproj -c Release
        if ($LASTEXITCODE -ne 0) { throw 'Windows display tests failed.' }
    }
    if ($Publish) {
        & $dotnetCommand publish src/CodexTop.Windows/CodexTop.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o artifacts/CodexTop-Windows-x64 --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
        foreach ($name in @('LICENSE','NOTICE.md','README.md')) { Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $projectRoot 'artifacts/CodexTop-Windows-x64') }
        Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination (Join-Path $projectRoot 'artifacts/CodexTop-Windows-x64') -Recurse -Force
        Compress-Archive -Path (Join-Path $projectRoot 'artifacts/CodexTop-Windows-x64') -DestinationPath (Join-Path $projectRoot 'artifacts/CodexTop-Windows-x64-0.1.8.zip') -Force
        & (Join-Path $PSScriptRoot 'package-source.ps1')
        Get-FileHash -LiteralPath (Join-Path $projectRoot 'artifacts/CodexTop-Windows-x64-0.1.8.zip') -Algorithm SHA256
    }
} finally { Pop-Location }
