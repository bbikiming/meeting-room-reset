$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $repoRoot 'install.ps1'
$taskName = 'MeetingRoomReset-OnStartup'
$installRoot = Join-Path $env:ProgramData 'MeetingRoomReset'
$targetUser = "$env:USERDOMAIN\$env:USERNAME"
$policyDefinitions = @(
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BrowserSignin' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SyncDisabled' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'NonRemovableProfileEnabled' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'BrowserSignin' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'SyncDisabled' }
)

function Get-TestPolicyState {
    $result = @()
    foreach ($policy in $policyDefinitions) {
        $exists = $false
        $value = $null
        $kind = 'DWord'
        if (Test-Path -LiteralPath $policy.Path) {
            $key = Get-Item -LiteralPath $policy.Path
            if ($key.GetValueNames() -contains $policy.Name) {
                $exists = $true
                $value = $key.GetValue($policy.Name)
                $kind = [string]$key.GetValueKind($policy.Name)
            }
        }
        $result += [pscustomobject]@{ Path = $policy.Path; Name = $policy.Name; Exists = $exists; Value = $value; Kind = $kind }
    }
    return $result
}

function Restore-TestPolicyState {
    param($State)

    foreach ($entry in $State) {
        if ([bool]$entry.Exists) {
            New-Item -Path $entry.Path -Force | Out-Null
            New-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType ([string]$entry.Kind) -Force | Out-Null
        }
        elseif (Test-Path -LiteralPath $entry.Path) {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
        }
    }
}

function Get-TestRegistryValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return (Get-Item -LiteralPath $Path).GetValue($Name, $null)
}

function Wait-TestTask {
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        if ($task.State -ne 'Running') {
            return
        }
        Start-Sleep -Seconds 1
    }
    throw 'Scheduled cleanup task did not finish within 60 seconds.'
}

$originalPolicyState = @(Get-TestPolicyState)

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }

    # Seed existing company policy values to verify that uninstall restores them.
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BrowserSignin' -Value 1 -PropertyType DWord -Force | Out-Null
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'SyncDisabled' -Value 0 -PropertyType DWord -Force | Out-Null

    & $installScript -Mode Audit -TargetUser $targetUser

    & $installScript -Mode Install -TargetUser $targetUser -AcceptDataLoss

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) { throw 'Scheduled task is not running as SYSTEM.' }
    if ($task.Actions.Arguments -notlike '*-ExecutionPolicy Bypass*cleanup.ps1*') { throw 'Scheduled task action is incomplete.' }
    if ([int]$task.Settings.RestartCount -ne 2) { throw 'Scheduled task retry count is incorrect.' }

    $configPath = Join-Path $installRoot 'config.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ([int]$config.Version -ne 2) { throw 'Installed configuration version is incorrect.' }
    if ([string]$config.TargetSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Installer selected the wrong user SID.' }

    $edgeSignin = Get-TestRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BrowserSignin'
    $edgeSync = Get-TestRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'SyncDisabled'
    $chromeSignin = Get-TestRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'BrowserSignin'
    $chromeSync = Get-TestRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'SyncDisabled'
    if ($null -eq $edgeSignin -or [int]$edgeSignin -ne 0) { throw 'Edge browser sign-in policy was not applied.' }
    if ($null -eq $edgeSync -or [int]$edgeSync -ne 1) { throw 'Edge sync policy was not applied.' }
    if ($null -eq $chromeSignin -or [int]$chromeSignin -ne 0) { throw 'Chrome browser sign-in policy was not applied.' }
    if ($null -eq $chromeSync -or [int]$chromeSync -ne 1) { throw 'Chrome sync policy was not applied.' }

    $desktopRule = @($config.FolderRules) | Where-Object Name -eq 'Desktop' | Select-Object -First 1
    $downloadsRule = @($config.FolderRules) | Where-Object Name -eq 'Downloads' | Select-Object -First 1
    $desktop = [string]$desktopRule.Path
    $downloads = [string]$downloadsRule.Path
    New-Item -ItemType Directory -Path $desktop, $downloads -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $desktop 'codex-delete.txt') 'private'
    Set-Content -LiteralPath (Join-Path $desktop 'codex-keep.lnk') 'shortcut'
    New-Item -ItemType Directory -Path (Join-Path $downloads 'codex-folder') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $downloads 'codex-folder/file.txt') 'private'
    foreach ($browserRoot in @($config.BrowserDataRoots)) {
        $fixtureRoot = Join-Path ([string]$browserRoot) 'CodexFixture'
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'cookie.txt') 'private'
    }

    Start-ScheduledTask -TaskName $taskName
    Wait-TestTask
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
    if ([int]$taskInfo.LastTaskResult -ne 0) { throw "Scheduled cleanup returned $($taskInfo.LastTaskResult)." }
    if (Test-Path -LiteralPath (Join-Path $desktop 'codex-delete.txt')) { throw 'Scheduled cleanup left a Desktop file.' }
    if (-not (Test-Path -LiteralPath (Join-Path $desktop 'codex-keep.lnk'))) { throw 'Scheduled cleanup deleted a Desktop shortcut.' }
    if (Test-Path -LiteralPath (Join-Path $downloads 'codex-folder')) { throw 'Scheduled cleanup left a Downloads folder.' }
    foreach ($browserRoot in @($config.BrowserDataRoots)) {
        if (Test-Path -LiteralPath (Join-Path ([string]$browserRoot) 'CodexFixture')) { throw 'Scheduled cleanup left browser data.' }
    }

    # Reinstallation must be idempotent and preserve the original policy backup.
    $logMarker = Join-Path $installRoot 'logs/reinstall-marker.log'
    Set-Content -LiteralPath $logMarker 'preserve'
    & $installScript -Mode Install -TargetUser $targetUser -AcceptDataLoss
    if (-not (Test-Path -LiteralPath $logMarker)) { throw 'Reinstall discarded existing logs.' }
    $policyBackup = @(Get-Content -LiteralPath (Join-Path $installRoot 'browser-policy-backup.json') -Raw | ConvertFrom-Json)
    $edgeSigninBackup = $policyBackup | Where-Object { $_.Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -and $_.Name -eq 'BrowserSignin' }
    if (-not [bool]$edgeSigninBackup.Exists -or [int]$edgeSigninBackup.Value -ne 1) { throw 'Reinstall overwrote the original browser policy backup.' }

    # A policy changed by IT after installation must not be overwritten by uninstall.
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BrowserSignin' -Value 2
    & (Join-Path $installRoot 'uninstall.ps1')
    for ($attempt = 0; $attempt -lt 10 -and (Test-Path -LiteralPath $installRoot); $attempt++) {
        Start-Sleep -Seconds 1
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Uninstall left the scheduled task.' }
    if (Test-Path -LiteralPath $installRoot) { throw 'Uninstall left the installation directory.' }
    if ([int](Get-TestRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BrowserSignin') -ne 2) { throw 'Uninstall overwrote an externally changed browser policy.' }
    if ([int](Get-TestRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'SyncDisabled') -ne 0) { throw 'Uninstall did not restore the original Chrome policy.' }

    Write-Host 'Install, scheduled-task, reinstall, policy, and uninstall lifecycle OK'
}
finally {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Restore-TestPolicyState -State $originalPolicyState
}

exit 0
