$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path $PSScriptRoot 'cleanup-test'
$testProfile = Join-Path $sandbox 'profile'
$desktop = Join-Path $testProfile 'Desktop'
$downloads = Join-Path $testProfile 'Downloads'
$chrome = Join-Path $testProfile 'AppData/Local/Google/Chrome/User Data'
$logs = Join-Path $sandbox 'logs'
$configPath = Join-Path $sandbox 'config.json'

if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $desktop, $downloads, $chrome, $logs -Force | Out-Null
Set-Content (Join-Path $desktop 'keep.lnk') 'shortcut'
Set-Content (Join-Path $desktop 'delete.txt') 'private'
New-Item -ItemType Directory -Path (Join-Path $desktop 'delete-folder') | Out-Null
Set-Content (Join-Path $downloads 'download.pdf') 'private'
Set-Content (Join-Path $chrome 'Cookies') 'private'

$config = [ordered]@{
    TargetUser = 'test-user'
    ProfilePath = $testProfile
    LogDirectory = $logs
    FolderRules = @(
        [ordered]@{ Path = $desktop; PreserveExtensions = @('.lnk', '.url'); PreserveNames = @('desktop.ini') },
        [ordered]@{ Path = $downloads; PreserveExtensions = @(); PreserveNames = @('desktop.ini') }
    )
    BrowserDataRoots = @($chrome)
}
$config | ConvertTo-Json -Depth 5 | Set-Content $configPath

& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $repoRoot 'cleanup.ps1') -ConfigPath $configPath
if ($LASTEXITCODE -ne 0) { throw "Cleanup returned $LASTEXITCODE" }
if (-not (Test-Path (Join-Path $desktop 'keep.lnk'))) { throw 'Desktop shortcut was not preserved.' }
if (Test-Path (Join-Path $desktop 'delete.txt')) { throw 'Desktop file was not deleted.' }
if (Test-Path (Join-Path $desktop 'delete-folder')) { throw 'Desktop folder was not deleted.' }
if (Test-Path (Join-Path $downloads 'download.pdf')) { throw 'Download was not deleted.' }
if (Test-Path (Join-Path $chrome 'Cookies')) { throw 'Browser data was not deleted.' }

$outside = Join-Path $sandbox 'outside-profile'
New-Item -ItemType Directory -Path $outside -Force | Out-Null
Set-Content (Join-Path $outside 'must-remain.txt') 'safe'
$config.BrowserDataRoots = @($outside)
$config.FolderRules = @()
$config | ConvertTo-Json -Depth 5 | Set-Content $configPath

& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $repoRoot 'cleanup.ps1') -ConfigPath $configPath
if ($LASTEXITCODE -eq 0) { throw 'Unsafe path should have produced a failure result.' }
if (-not (Test-Path (Join-Path $outside 'must-remain.txt'))) { throw 'Unsafe outside path was deleted.' }

Write-Host 'Cleanup behavior and path safety OK'
