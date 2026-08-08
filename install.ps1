[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Install')]
    [string]$Mode = 'Install',

    [string]$TargetUser,

    [switch]$AcceptDataLoss,

    [switch]$IncludeCloudDesktop
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$taskName = 'MeetingRoomReset-OnStartup'
$installRoot = Join-Path $env:ProgramData 'MeetingRoomReset'
$configPath = Join-Path $installRoot 'config.json'
$policyBackupPath = Join-Path $installRoot 'browser-policy-backup.json'
$browserPolicies = @(
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BrowserSignin'; Value = 0 },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SyncDisabled'; Value = 1 },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'NonRemovableProfileEnabled'; Value = 0 },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'BrowserSignin'; Value = 0 },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'SyncDisabled'; Value = 1 }
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-TargetProfile {
    param([string]$RequestedUser)

    $accountName = $RequestedUser
    if ([string]::IsNullOrWhiteSpace($accountName)) {
        $accountName = (Get-CimInstance Win32_ComputerSystem).UserName
    }

    if ([string]::IsNullOrWhiteSpace($accountName)) {
        throw 'No interactive user was detected. Sign in with the meeting-room account or use -TargetUser "COMPUTER\username".'
    }

    $account = New-Object Security.Principal.NTAccount($accountName)
    $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
    $userProfile = Get-CimInstance Win32_UserProfile |
        Where-Object { $_.SID -eq $sid } |
        Select-Object -First 1

    if ($null -eq $userProfile -or [string]::IsNullOrWhiteSpace([string]$userProfile.LocalPath)) {
        throw "Windows profile not found for $accountName. Sign in once with that account and retry."
    }

    if (-not [bool]$userProfile.Loaded) {
        throw "The profile for $accountName is not loaded. Sign in with that account before installation so redirected folders can be detected safely."
    }

    return [pscustomobject]@{
        AccountName = $accountName
        Sid = $sid
        ProfilePath = [string]$userProfile.LocalPath
    }
}

function Expand-TargetUserPath {
    param(
        [string]$RawPath,
        [string]$ProfilePath,
        [string]$OneDrivePath
    )

    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return $null
    }

    $expanded = $RawPath.Replace('%USERPROFILE%', $ProfilePath)
    $expanded = $expanded.Replace('%HOMEDRIVE%%HOMEPATH%', $ProfilePath)
    if (-not [string]::IsNullOrWhiteSpace($OneDrivePath)) {
        $expanded = $expanded.Replace('%OneDrive%', $OneDrivePath)
        $expanded = $expanded.Replace('%OneDriveCommercial%', $OneDrivePath)
    }
    return [Environment]::ExpandEnvironmentVariables($expanded)
}

function Get-TargetFolderSet {
    param($TargetProfile)

    $desktop = Join-Path $TargetProfile.ProfilePath 'Desktop'
    $downloads = Join-Path $TargetProfile.ProfilePath 'Downloads'
    $userShellPath = "Registry::HKEY_USERS\$($TargetProfile.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $environmentPath = "Registry::HKEY_USERS\$($TargetProfile.Sid)\Environment"
    $oneDrive = $null

    if (Test-Path -LiteralPath $environmentPath) {
        $environmentValues = Get-ItemProperty -LiteralPath $environmentPath
        if ($environmentValues.PSObject.Properties.Name -contains 'OneDriveCommercial') {
            $oneDrive = [string]$environmentValues.OneDriveCommercial
        }
        elseif ($environmentValues.PSObject.Properties.Name -contains 'OneDrive') {
            $oneDrive = [string]$environmentValues.OneDrive
        }
    }

    if (Test-Path -LiteralPath $userShellPath) {
        $shellValues = Get-ItemProperty -LiteralPath $userShellPath
        if ($shellValues.PSObject.Properties.Name -contains 'Desktop') {
            $desktop = Expand-TargetUserPath -RawPath ([string]$shellValues.Desktop) -ProfilePath $TargetProfile.ProfilePath -OneDrivePath $oneDrive
        }

        $downloadsGuid = '{374DE290-123F-4565-9164-39C4925E467B}'
        if ($shellValues.PSObject.Properties.Name -contains $downloadsGuid) {
            $downloads = Expand-TargetUserPath -RawPath ([string]$shellValues.$downloadsGuid) -ProfilePath $TargetProfile.ProfilePath -OneDrivePath $oneDrive
        }
    }

    return [pscustomobject]@{
        Desktop = $desktop
        Downloads = $downloads
        OneDrive = $oneDrive
    }
}

function Test-IsChildPath {
    param(
        [string]$Candidate,
        [string]$Parent
    )

    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $separator = [IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($parentFull + $separator, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PathSafetyIssue {
    param(
        [string]$Path,
        [string]$ProfilePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return 'A configured path is empty.'
    }

    if (-not (Test-IsChildPath -Candidate $Path -Parent $ProfilePath)) {
        return "A configured path is outside the selected user profile: $Path"
    }

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return "A configured path is a junction or symbolic link: $Path"
        }
    }

    return $null
}

function Get-BrowserPolicyState {
    param($Policies)

    $state = @()
    foreach ($policy in $Policies) {
        $exists = $false
        $value = $null
        $kind = 'DWord'
        if (Test-Path -LiteralPath $policy.Path) {
            $key = Get-Item -LiteralPath $policy.Path
            if ($key.GetValueNames() -contains $policy.Name) {
                $exists = $true
                $value = $key.GetValue($policy.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $kind = [string]$key.GetValueKind($policy.Name)
            }
        }

        $state += [pscustomobject]@{
            Path = $policy.Path
            Name = $policy.Name
            Exists = $exists
            Value = $value
            Kind = $kind
            ManagedValue = [int]$policy.Value
        }
    }
    return $state
}

function Invoke-BrowserPolicyConfiguration {
    param($Policies)

    foreach ($policy in $Policies) {
        New-Item -Path $policy.Path -Force | Out-Null
        New-ItemProperty -Path $policy.Path -Name $policy.Name -Value ([int]$policy.Value) -PropertyType DWord -Force | Out-Null
        $key = Get-Item -LiteralPath $policy.Path
        if (-not ($key.GetValueNames() -contains $policy.Name)) {
            throw "Browser policy value was not created: $($policy.Path)\$($policy.Name)"
        }
        if ([int]$key.GetValue($policy.Name) -ne [int]$policy.Value) {
            throw "Browser policy verification failed: $($policy.Path)\$($policy.Name)"
        }
    }
}

function Restore-BrowserPolicyState {
    param($State)

    $entries = @($State | ForEach-Object { $_ })
    foreach ($entry in $entries) {
        if ($null -eq $entry) {
            Write-Warning 'An empty browser policy backup entry was skipped during rollback.'
            continue
        }
        $propertyNames = @($entry.PSObject.Properties.Name)
        if (-not ($propertyNames -contains 'Path') -or
            -not ($propertyNames -contains 'Name') -or
            -not ($propertyNames -contains 'Exists')) {
            Write-Warning 'An invalid browser policy backup entry was skipped during rollback.'
            continue
        }

        if ([bool]$entry.Exists) {
            New-Item -Path $entry.Path -Force | Out-Null
            New-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType ([string]$entry.Kind) -Force | Out-Null
        }
        elseif (Test-Path -LiteralPath $entry.Path) {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
        }
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This installer must run on Windows.'
}

if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw 'Windows PowerShell 5.1 or later is required.'
}

$requiredCommands = @(
    'Get-CimInstance',
    'New-ScheduledTaskAction',
    'New-ScheduledTaskTrigger',
    'New-ScheduledTaskPrincipal',
    'New-ScheduledTaskSettingsSet',
    'Register-ScheduledTask'
)
foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required Windows command is unavailable: $commandName"
    }
}

if ($Mode -eq 'Install' -and -not (Test-IsAdministrator)) {
    throw 'Open Windows PowerShell as Administrator and run the installer again.'
}

$target = Resolve-TargetProfile -RequestedUser $TargetUser
$folders = Get-TargetFolderSet -TargetProfile $target
$browserRoots = @(
    (Join-Path $target.ProfilePath 'AppData\Local\Google\Chrome\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Local\Microsoft\Edge\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Local\BraveSoftware\Brave-Browser\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Local\Naver\Naver Whale\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Roaming\Mozilla\Firefox'),
    (Join-Path $target.ProfilePath 'AppData\Local\Mozilla\Firefox')
)

$allCleanupPaths = @($folders.Desktop, $folders.Downloads) + $browserRoots
foreach ($cleanupPath in $allCleanupPaths) {
    $safetyIssue = Get-PathSafetyIssue -Path $cleanupPath -ProfilePath $target.ProfilePath
    if (-not [string]::IsNullOrWhiteSpace($safetyIssue)) {
        throw $safetyIssue
    }
}

$cloudDesktop = $false
if (-not [string]::IsNullOrWhiteSpace([string]$folders.OneDrive)) {
    $oneDriveRoot = [IO.Path]::GetFullPath([string]$folders.OneDrive).TrimEnd('\') + '\'
    $desktopPath = [IO.Path]::GetFullPath([string]$folders.Desktop)
    $cloudDesktop = $desktopPath.StartsWith($oneDriveRoot, [StringComparison]::OrdinalIgnoreCase)
}
if (-not $cloudDesktop -and ([string]$folders.Desktop -match '(?i)[\\/]OneDrive(?: - [^\\/]+)?[\\/]')) {
    $cloudDesktop = $true
}

$scheduleService = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
$scheduleStatus = 'Unavailable'
if ($null -ne $scheduleService) {
    $scheduleStatus = [string]$scheduleService.Status
}

Write-Host ''
Write-Host 'Meeting Room Reset audit' -ForegroundColor Cyan
Write-Host "  PowerShell  : $($PSVersionTable.PSVersion)"
Write-Host "  Target user : $($target.AccountName)"
Write-Host "  Profile     : $($target.ProfilePath)"
Write-Host "  Desktop     : $($folders.Desktop)"
Write-Host "  Downloads   : $($folders.Downloads)"
Write-Host '  Browsers    : Chrome, Edge, Brave, Naver Whale, Firefox'
Write-Host '  Sign-in     : Browser profile sign-in and sync will be disabled for Edge and Chrome'
Write-Host "  Scheduler   : $scheduleStatus"
Write-Host ''
Write-Warning 'On every Windows startup, Desktop files (except shortcuts), Downloads, and browser user data will be permanently deleted.'

if ($cloudDesktop) {
    Write-Warning 'The Desktop is inside OneDrive. Deleting it may also delete cloud files.'
}

if ($Mode -eq 'Audit') {
    Write-Host 'Audit completed. No system changes were made.' -ForegroundColor Green
    return
}

if ($null -eq $scheduleService -or $scheduleService.Status -ne 'Running') {
    throw 'Windows Task Scheduler service is not running.'
}

if ($cloudDesktop -and -not $IncludeCloudDesktop) {
    throw 'Cloud-synced Desktop detected. Rerun with -IncludeCloudDesktop only if cloud deletion is intended.'
}

foreach ($requiredFile in @('cleanup.ps1', 'uninstall.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $requiredFile) -PathType Leaf)) {
        throw "Installation package is incomplete: $requiredFile"
    }
}

if (-not $AcceptDataLoss) {
    $confirmation = Read-Host 'Type RESET to install'
    if ($confirmation -cne 'RESET') {
        throw 'Installation cancelled.'
    }
}

$stageRoot = "$installRoot.stage-$PID"
$backupRoot = "$installRoot.backup-$PID"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$existingTaskXml = $null
if ($null -ne $existingTask) {
    $existingTaskXml = Export-ScheduledTask -TaskName $taskName
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $backupRoot) {
    throw "A previous installation backup still exists: $backupRoot"
}

$rollbackPolicyState = @(Get-BrowserPolicyState -Policies $browserPolicies)
$permanentPolicyState = $rollbackPolicyState
if (Test-Path -LiteralPath $policyBackupPath -PathType Leaf) {
    $permanentPolicyState = @(Get-Content -LiteralPath $policyBackupPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
}

New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'logs') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cleanup.ps1') -Destination (Join-Path $stageRoot 'cleanup.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination (Join-Path $stageRoot 'uninstall.ps1') -Force

if (Test-Path -LiteralPath (Join-Path $installRoot 'logs')) {
    Copy-Item -Path (Join-Path $installRoot 'logs\*') -Destination (Join-Path $stageRoot 'logs') -Recurse -Force -ErrorAction SilentlyContinue
}

$config = [ordered]@{
    Version = 2
    TargetUser = $target.AccountName
    TargetSid = $target.Sid
    ProfilePath = $target.ProfilePath
    LogDirectory = (Join-Path $installRoot 'logs')
    FolderRules = @(
        [ordered]@{
            Name = 'Desktop'
            Path = $folders.Desktop
            PreserveExtensions = @('.lnk', '.url')
            PreserveNames = @('desktop.ini')
        },
        [ordered]@{
            Name = 'Downloads'
            Path = $folders.Downloads
            PreserveExtensions = @()
            PreserveNames = @('desktop.ini')
        }
    )
    BrowserDataRoots = $browserRoots
}

$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stageRoot 'config.json') -Encoding UTF8
ConvertTo-Json -InputObject @($permanentPolicyState) -Depth 5 | Set-Content -LiteralPath (Join-Path $stageRoot 'browser-policy-backup.json') -Encoding UTF8

$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installRoot\cleanup.ps1`" -ConfigPath `"$configPath`""
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

try {
    if (Test-Path -LiteralPath $installRoot) {
        Move-Item -LiteralPath $installRoot -Destination $backupRoot
    }
    Move-Item -LiteralPath $stageRoot -Destination $installRoot

    $icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $icaclsPath $installRoot '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to protect the installation directory permissions.'
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Clears meeting-room user files and browser data on Windows startup.' `
        -Force | Out-Null

    Invoke-BrowserPolicyConfiguration -Policies $browserPolicies

    $installedTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($installedTask.Actions.Execute -ne $powerShellPath -or $installedTask.Actions.Arguments -notlike '*cleanup.ps1*') {
        throw 'Scheduled task verification failed.'
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'Installed configuration verification failed.'
    }

    if (Test-Path -LiteralPath $backupRoot) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
    }
}
catch {
    $installationError = $_
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $backupRoot) {
        Move-Item -LiteralPath $backupRoot -Destination $installRoot -ErrorAction SilentlyContinue
    }

    Restore-BrowserPolicyState -State $rollbackPolicyState

    if ($null -ne $existingTaskXml) {
        Register-ScheduledTask -TaskName $taskName -Xml $existingTaskXml -Force | Out-Null
    }
    else {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    throw $installationError
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Installation completed and verified.' -ForegroundColor Green
Write-Host 'The first cleanup will run on the next Windows startup.'
Write-Host "Manual verification: Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Uninstall command: & '$installRoot\uninstall.ps1'"
