$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $repoRoot 'install.ps1'
$taskName = 'MeetingRoomReset-OnStartup'
$installRoot = Join-Path $env:ProgramData 'MeetingRoomReset'
$targetUser = "$env:USERDOMAIN\$env:USERNAME"
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$profilePath = [Environment]::GetFolderPath('UserProfile')
$shellKeyPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
$environmentKeyPath = "Registry::HKEY_USERS\$sid\Environment"
$downloadsName = '{374DE290-123F-4565-9164-39C4925E467B}'

function Get-RegistryValueSnapshot {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ KeyExists = $false; Exists = $false; Value = $null; Kind = 'String' }
    }

    $key = Get-Item -LiteralPath $Path
    if (-not ($key.GetValueNames() -contains $Name)) {
        return [pscustomobject]@{ KeyExists = $true; Exists = $false; Value = $null; Kind = 'String' }
    }

    return [pscustomobject]@{
        KeyExists = $true
        Exists = $true
        Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind = [string]$key.GetValueKind($Name)
    }
}

function Restore-RegistryValueSnapshot {
    param(
        [string]$Path,
        [string]$Name,
        $Snapshot
    )

    if ([bool]$Snapshot.Exists) {
        New-Item -Path $Path -Force | Out-Null
        New-ItemProperty -Path $Path -Name $Name -Value $Snapshot.Value -PropertyType ([string]$Snapshot.Kind) -Force | Out-Null
    }
    elseif (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    }

    if (-not [bool]$Snapshot.KeyExists -and (Test-Path -LiteralPath $Path)) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames().Count -eq 0 -and $key.GetSubKeyNames().Count -eq 0) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
}

function Assert-InstallFailure {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Scenario
    )

    try {
        & $Action
    }
    catch {
        if ([string]$_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "$Scenario failed with an unexpected error: $($_.Exception.Message)"
        }
        return
    }

    throw "$Scenario was not blocked."
}

$desktopSnapshot = Get-RegistryValueSnapshot -Path $shellKeyPath -Name 'Desktop'
$downloadsSnapshot = Get-RegistryValueSnapshot -Path $shellKeyPath -Name $downloadsName
$oneDriveSnapshot = Get-RegistryValueSnapshot -Path $environmentKeyPath -Name 'OneDriveCommercial'
$testRoot = Join-Path $profilePath 'Meeting Room Reset Guard Test'
$cloudRoot = Join-Path $testRoot 'OneDrive - Codex Test'
$cloudDesktop = Join-Path $cloudRoot 'Desktop'
$safeDownloads = Join-Path $testRoot 'Downloads'
$junctionPath = Join-Path $testRoot 'JunctionDownloads'
$junctionTarget = Join-Path $testRoot 'JunctionTarget'

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }

    Assert-InstallFailure `
        -Action { & $installScript -Mode Audit -TargetUser "$env:COMPUTERNAME\MeetingRoomResetUserThatDoesNotExist" } `
        -ExpectedMessage 'identity reference' `
        -Scenario 'Unknown target user'

    New-Item -Path $shellKeyPath -Force | Out-Null
    New-ItemProperty -Path $shellKeyPath -Name $downloadsName -Value 'C:\MeetingRoomReset-Outside-Profile' -PropertyType ExpandString -Force | Out-Null
    Assert-InstallFailure `
        -Action { & $installScript -Mode Audit -TargetUser $targetUser } `
        -ExpectedMessage 'outside the selected user profile' `
        -Scenario 'Downloads outside the profile'

    New-Item -ItemType Directory -Path $cloudDesktop, $safeDownloads -Force | Out-Null
    New-Item -Path $environmentKeyPath -Force | Out-Null
    New-ItemProperty -Path $environmentKeyPath -Name 'OneDriveCommercial' -Value $cloudRoot -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $shellKeyPath -Name 'Desktop' -Value $cloudDesktop -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $shellKeyPath -Name $downloadsName -Value $safeDownloads -PropertyType ExpandString -Force | Out-Null
    Assert-InstallFailure `
        -Action { & $installScript -Mode Install -TargetUser $targetUser -AcceptDataLoss } `
        -ExpectedMessage 'Cloud-synced Desktop detected' `
        -Scenario 'OneDrive Desktop without explicit approval'

    & $installScript -Mode Install -TargetUser $targetUser -AcceptDataLoss -IncludeCloudDesktop
    $installedConfig = Get-Content -LiteralPath (Join-Path $installRoot 'config.json') -Raw | ConvertFrom-Json
    $installedDesktop = @($installedConfig.FolderRules | Where-Object Name -eq 'Desktop' | Select-Object -First 1).Path
    if ([IO.Path]::GetFullPath([string]$installedDesktop) -ne [IO.Path]::GetFullPath($cloudDesktop)) {
        throw 'Explicit OneDrive Desktop installation stored the wrong path.'
    }
    & (Join-Path $installRoot 'uninstall.ps1')

    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    New-ItemProperty -Path $shellKeyPath -Name 'Desktop' -Value (Join-Path $profilePath 'Desktop') -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $shellKeyPath -Name $downloadsName -Value $junctionPath -PropertyType ExpandString -Force | Out-Null
    Assert-InstallFailure `
        -Action { & $installScript -Mode Audit -TargetUser $targetUser } `
        -ExpectedMessage 'junction or symbolic link' `
        -Scenario 'Junction Downloads folder'

    Write-Host 'Install guard scenarios OK'
}
finally {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Restore-RegistryValueSnapshot -Path $shellKeyPath -Name 'Desktop' -Snapshot $desktopSnapshot
    Restore-RegistryValueSnapshot -Path $shellKeyPath -Name $downloadsName -Snapshot $downloadsSnapshot
    Restore-RegistryValueSnapshot -Path $environmentKeyPath -Name 'OneDriveCommercial' -Snapshot $oneDriveSnapshot
    if (Test-Path -LiteralPath $junctionPath) {
        Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
