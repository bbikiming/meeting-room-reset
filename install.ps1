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
        throw 'No interactive user was detected. Run again with -TargetUser "COMPUTER\username".'
    }

    $account = New-Object Security.Principal.NTAccount($accountName)
    $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
    $userProfile = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Select-Object -First 1

    if ($null -eq $userProfile -or [string]::IsNullOrWhiteSpace([string]$userProfile.LocalPath)) {
        throw "Windows profile not found for $accountName. Sign in once with that account and retry."
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

if (-not (Test-IsAdministrator)) {
    throw 'Open Windows PowerShell as Administrator and run the installer again.'
}

$target = Resolve-TargetProfile -RequestedUser $TargetUser
$folders = Get-TargetFolderSet -TargetProfile $target

$browserRoots = @(
    (Join-Path $target.ProfilePath 'AppData\Local\Google\Chrome\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Local\Microsoft\Edge\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Local\BraveSoftware\Brave-Browser\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Local\Naver\Naver Whale\User Data'),
    (Join-Path $target.ProfilePath 'AppData\Roaming\Mozilla\Firefox\Profiles'),
    (Join-Path $target.ProfilePath 'AppData\Local\Mozilla\Firefox\Profiles')
)

Write-Host ''
Write-Host 'Meeting Room Reset audit' -ForegroundColor Cyan
Write-Host "  Target user : $($target.AccountName)"
Write-Host "  Profile     : $($target.ProfilePath)"
Write-Host "  Desktop     : $($folders.Desktop)"
Write-Host "  Downloads   : $($folders.Downloads)"
Write-Host '  Browsers    : Chrome, Edge, Brave, Naver Whale, Firefox'
Write-Host ''
Write-Warning 'On every Windows startup, Desktop files (except shortcuts), Downloads, and browser user data will be deleted.'

$cloudDesktop = $false
if (-not [string]::IsNullOrWhiteSpace([string]$folders.OneDrive)) {
    $oneDriveRoot = [IO.Path]::GetFullPath([string]$folders.OneDrive).TrimEnd('\') + '\'
    $desktopPath = [IO.Path]::GetFullPath([string]$folders.Desktop)
    $cloudDesktop = $desktopPath.StartsWith($oneDriveRoot, [StringComparison]::OrdinalIgnoreCase)
}
if (-not $cloudDesktop -and ([string]$folders.Desktop -match '(?i)[\\/]OneDrive(?: - [^\\/]+)?[\\/]')) {
    $cloudDesktop = $true
}

if ($cloudDesktop) {
    Write-Warning 'The Desktop is inside OneDrive. Deleting it may also delete cloud files.'
}

if ($Mode -eq 'Audit') {
    Write-Host 'Audit completed. No system changes were made.' -ForegroundColor Green
    exit 0
}

if ($cloudDesktop -and -not $IncludeCloudDesktop) {
    throw 'Cloud-synced Desktop detected. Review the Audit output, then rerun with -IncludeCloudDesktop only if cloud deletion is intended.'
}

if (-not $AcceptDataLoss) {
    $confirmation = Read-Host 'Type RESET to install'
    if ($confirmation -cne 'RESET') {
        throw 'Installation cancelled.'
    }
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $installRoot 'logs') -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cleanup.ps1') -Destination (Join-Path $installRoot 'cleanup.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination (Join-Path $installRoot 'uninstall.ps1') -Force

$config = [ordered]@{
    Version = 1
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

$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = "-NoLogo -NoProfile -NonInteractive -File `"$installRoot\cleanup.ps1`" -ConfigPath `"$configPath`""
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Clears meeting-room user files and browser data on Windows startup.' | Out-Null

Write-Host 'Installation completed.' -ForegroundColor Green
Write-Host 'The first cleanup will run on the next Windows startup.'
Write-Host "Uninstall command: & '$installRoot\uninstall.ps1'"
