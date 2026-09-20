$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$stagingRoot = Join-Path $projectRoot ('.tools/source-package/' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $stagingRoot 'CodexTop-Windows-Source'
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

# Use an empty, temporary index so .gitignore applies even before git init,
# and also excludes a locally tracked secret or build artifact from an export.
# Only the project's rules apply; personal global excludes must not change a package.
$git = (Get-Command git -ErrorAction Stop).Source
$ignoreRepository = Join-Path $stagingRoot 'ignore.git'
& $git init --bare --quiet --template= $ignoreRepository
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize source file selection.' }
$sourceFiles = @(& $git -C $projectRoot -c core.excludesFile=NUL -c core.quotePath=false --git-dir=$ignoreRepository --work-tree=$projectRoot ls-files --others --exclude-standard -- src tests scripts docs README.md NOTICE.md LICENSE Directory.Build.props global.json .gitignore .gitattributes)
if ($LASTEXITCODE -ne 0 -or $sourceFiles.Count -eq 0) { throw 'Could not enumerate source files.' }
foreach ($relative in $sourceFiles) {
    $destination = Join-Path $sourceRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $destination
}
New-Item -ItemType Directory -Path (Join-Path $projectRoot 'artifacts') -Force | Out-Null
$archivePath = Join-Path $projectRoot 'artifacts/CodexTop-Windows-Source-0.1.10.zip'
Compress-Archive -LiteralPath $sourceRoot -DestinationPath $archivePath -Force
[pscustomobject]@{ SourceDirectory = $sourceRoot; Archive = $archivePath; FileCount = $sourceFiles.Count }
