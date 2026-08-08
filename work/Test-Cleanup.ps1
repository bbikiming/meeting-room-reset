$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupScript = Join-Path $repoRoot 'cleanup.ps1'
$powerShellPath = (Get-Process -Id $PID).Path
$sandbox = Join-Path $PSScriptRoot 'cleanup-test'
$testProfile = Join-Path $sandbox 'profile with spaces'
$desktop = Join-Path $testProfile 'Desktop'
$downloads = Join-Path $testProfile 'Downloads'
$chrome = Join-Path $testProfile 'AppData/Local/Google/Chrome/User Data'
$firefox = Join-Path $testProfile 'AppData/Roaming/Mozilla/Firefox'
$logs = Join-Path $sandbox 'logs'
$configPath = Join-Path $sandbox 'config.json'

function Write-TestConfig {
    param(
        [array]$FolderRules,
        [array]$BrowserRoots,
        [string]$LogPath = $logs
    )

    $config = [ordered]@{
        TargetUser = 'test-user'
        ProfilePath = $testProfile
        LogDirectory = $LogPath
        FolderRules = $FolderRules
        BrowserDataRoots = $BrowserRoots
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
}

function Invoke-CleanupProcess {
    & $powerShellPath -NoProfile -File $cleanupScript -ConfigPath $configPath
    return $LASTEXITCODE
}

if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
New-Item -ItemType Directory -Path $desktop, $downloads, $chrome, $firefox, $logs -Force | Out-Null

# Normal cleanup, preservation rules, nested content, and multiple browser roots.
Set-Content -LiteralPath (Join-Path $desktop 'keep.lnk') 'shortcut'
Set-Content -LiteralPath (Join-Path $desktop 'keep.url') 'shortcut'
Set-Content -LiteralPath (Join-Path $desktop 'desktop.ini') 'system'
Set-Content -LiteralPath (Join-Path $desktop 'delete.txt') 'private'
New-Item -ItemType Directory -Path (Join-Path $desktop 'delete-folder/nested') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $desktop 'delete-folder/nested/file.txt') 'private'
Set-Content -LiteralPath (Join-Path $downloads 'download.pdf') 'private'
Set-Content -LiteralPath (Join-Path $chrome 'Cookies') 'private'
Set-Content -LiteralPath (Join-Path $firefox 'cookies.sqlite') 'private'

$rules = @(
    [ordered]@{ Path = $desktop; PreserveExtensions = @('.lnk', '.url'); PreserveNames = @('desktop.ini') },
    [ordered]@{ Path = $downloads; PreserveExtensions = @(); PreserveNames = @('desktop.ini') }
)
Write-TestConfig -FolderRules $rules -BrowserRoots @($chrome, $firefox)

if ((Invoke-CleanupProcess) -ne 0) { throw 'Normal cleanup returned a failure result.' }
if (-not (Test-Path -LiteralPath (Join-Path $desktop 'keep.lnk'))) { throw 'Desktop .lnk shortcut was not preserved.' }
if (-not (Test-Path -LiteralPath (Join-Path $desktop 'keep.url'))) { throw 'Desktop .url shortcut was not preserved.' }
if (-not (Test-Path -LiteralPath (Join-Path $desktop 'desktop.ini'))) { throw 'desktop.ini was not preserved.' }
if (Test-Path -LiteralPath (Join-Path $desktop 'delete.txt')) { throw 'Desktop file was not deleted.' }
if (Test-Path -LiteralPath (Join-Path $desktop 'delete-folder')) { throw 'Nested Desktop folder was not deleted.' }
if (Test-Path -LiteralPath (Join-Path $downloads 'download.pdf')) { throw 'Download was not deleted.' }
if (Test-Path -LiteralPath (Join-Path $chrome 'Cookies')) { throw 'Chromium data was not deleted.' }
if (Test-Path -LiteralPath (Join-Path $firefox 'cookies.sqlite')) { throw 'Firefox data was not deleted.' }
if ((Get-Content -LiteralPath (Get-ChildItem -LiteralPath $logs -Filter 'cleanup-*.log' | Select-Object -First 1).FullName -Raw) -match 'delete\.txt|download\.pdf|Cookies') {
    throw 'Cleanup log leaked a deleted filename.'
}

# A path outside the selected profile must never be deleted.
$outside = Join-Path $sandbox 'outside-profile'
New-Item -ItemType Directory -Path $outside -Force | Out-Null
Set-Content -LiteralPath (Join-Path $outside 'must-remain.txt') 'safe'
Write-TestConfig -FolderRules @() -BrowserRoots @($outside)
if ((Invoke-CleanupProcess) -eq 0) { throw 'Outside-profile path should have produced a failure result.' }
if (-not (Test-Path -LiteralPath (Join-Path $outside 'must-remain.txt'))) { throw 'Outside-profile data was deleted.' }

# A prefix collision must not be treated as a child of the selected profile.
$prefixCollision = "$testProfile-evil"
New-Item -ItemType Directory -Path $prefixCollision -Force | Out-Null
Set-Content -LiteralPath (Join-Path $prefixCollision 'must-remain.txt') 'safe'
Write-TestConfig -FolderRules @() -BrowserRoots @($prefixCollision)
if ((Invoke-CleanupProcess) -eq 0) { throw 'Profile-prefix collision should have produced a failure result.' }
if (-not (Test-Path -LiteralPath (Join-Path $prefixCollision 'must-remain.txt'))) { throw 'Profile-prefix collision data was deleted.' }

# Logs must stay beside the protected configuration, not at an arbitrary path.
$outsideLogs = "$sandbox-outside-logs"
if (Test-Path -LiteralPath $outsideLogs) {
    Remove-Item -LiteralPath $outsideLogs -Recurse -Force
}
Write-TestConfig -FolderRules @() -BrowserRoots @() -LogPath $outsideLogs
if ((Invoke-CleanupProcess) -eq 0) { throw 'Outside log path should have produced a failure result.' }
if (Test-Path -LiteralPath $outsideLogs) { throw 'Unsafe log directory was created.' }

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    # A junction nested inside a normal folder must be unlinked without traversing its target.
    $nestedJunctionTarget = Join-Path $outside 'nested-junction-target'
    $normalParent = Join-Path $downloads 'normal-parent'
    $nestedJunction = Join-Path $normalParent 'nested-junction'
    New-Item -ItemType Directory -Path $nestedJunctionTarget, $normalParent -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nestedJunctionTarget 'must-remain.txt') 'safe'
    New-Item -ItemType Junction -Path $nestedJunction -Target $nestedJunctionTarget | Out-Null
    Write-TestConfig -FolderRules @([ordered]@{ Path = $downloads; PreserveExtensions = @(); PreserveNames = @() }) -BrowserRoots @()
    if ((Invoke-CleanupProcess) -ne 0) { throw 'Nested junction cleanup returned a failure result.' }
    if (Test-Path -LiteralPath $normalParent) { throw 'Folder containing a nested junction was not deleted.' }
    if (-not (Test-Path -LiteralPath (Join-Path $nestedJunctionTarget 'must-remain.txt'))) { throw 'Nested junction target was deleted.' }

    # A configured path must also be rejected when an intermediate parent is a junction.
    $ancestorJunctionTarget = Join-Path $outside 'ancestor-junction-target'
    $ancestorJunction = Join-Path $testProfile 'RedirectedParent'
    $pathThroughJunction = Join-Path $ancestorJunction 'Downloads'
    New-Item -ItemType Directory -Path $ancestorJunctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $ancestorJunction -Target $ancestorJunctionTarget | Out-Null
    New-Item -ItemType Directory -Path $pathThroughJunction -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pathThroughJunction 'must-remain.txt') 'safe'
    Write-TestConfig -FolderRules @([ordered]@{ Path = $pathThroughJunction; PreserveExtensions = @(); PreserveNames = @() }) -BrowserRoots @()
    if ((Invoke-CleanupProcess) -eq 0) { throw 'Path through an ancestor junction should have produced a failure result.' }
    if (-not (Test-Path -LiteralPath (Join-Path $pathThroughJunction 'must-remain.txt'))) { throw 'Data behind an ancestor junction was deleted.' }

    # A configured junction must be rejected without touching its target.
    $junctionTarget = Join-Path $outside 'junction-target'
    $junctionRoot = Join-Path $testProfile 'RedirectedDownloads'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $junctionTarget 'must-remain.txt') 'safe'
    New-Item -ItemType Junction -Path $junctionRoot -Target $junctionTarget | Out-Null
    Write-TestConfig -FolderRules @([ordered]@{ Path = $junctionRoot; PreserveExtensions = @(); PreserveNames = @() }) -BrowserRoots @()
    if ((Invoke-CleanupProcess) -eq 0) { throw 'Configured junction should have produced a failure result.' }
    if (-not (Test-Path -LiteralPath (Join-Path $junctionTarget 'must-remain.txt'))) { throw 'Configured junction target was deleted.' }

    # A locked file should fail safely, then succeed after the lock is released.
    $lockedFile = Join-Path $downloads 'locked.txt'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    Set-Content -LiteralPath $lockedFile 'private'
    Write-TestConfig -FolderRules @([ordered]@{ Path = $downloads; PreserveExtensions = @(); PreserveNames = @() }) -BrowserRoots @()
    $lock = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ((Invoke-CleanupProcess) -eq 0) { throw 'Locked file should have produced a failure result.' }
        if (-not (Test-Path -LiteralPath $lockedFile)) { throw 'Locked file unexpectedly disappeared.' }
    }
    finally {
        $lock.Dispose()
    }
    if ((Invoke-CleanupProcess) -ne 0) { throw 'Cleanup did not recover after the file lock was released.' }
    if (Test-Path -LiteralPath $lockedFile) { throw 'Unlocked file was not deleted on retry.' }
}

Write-Host 'Cleanup scenario matrix OK'
exit 0
