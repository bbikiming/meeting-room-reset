[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator and run the uninstaller again.'
}

$taskName = 'MeetingRoomReset-OnStartup'
$installRoot = Join-Path $env:ProgramData 'MeetingRoomReset'
$policyBackupPath = Join-Path $installRoot 'browser-policy-backup.json'

function Restore-BrowserPolicyState {
    param($State)

    foreach ($entry in @($State)) {
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            continue
        }

        $currentKey = Get-Item -LiteralPath $entry.Path
        if (-not ($currentKey.GetValueNames() -contains $entry.Name)) {
            continue
        }

        $currentValue = $currentKey.GetValue($entry.Name)
        if ([int]$currentValue -ne [int]$entry.ManagedValue) {
            Write-Warning "A browser policy changed after installation and was left untouched: $($entry.Path)\$($entry.Name)"
            continue
        }

        if ([bool]$entry.Exists) {
            New-ItemProperty `
                -Path $entry.Path `
                -Name $entry.Name `
                -Value $entry.Value `
                -PropertyType ([string]$entry.Kind) `
                -Force | Out-Null
        }
        else {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
        }
    }
}

if (Test-Path -LiteralPath $policyBackupPath -PathType Leaf) {
    $policyState = @(Get-Content -LiteralPath $policyBackupPath -Raw | ConvertFrom-Json)
    Restore-BrowserPolicyState -State $policyState
}
else {
    Write-Warning 'Browser policy backup was not found. Browser policies were left untouched.'
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

try {
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
}
catch {
    $escapedRoot = $installRoot.Replace('"', '""')
    $delayedDelete = "timeout /t 2 /nobreak >nul & rmdir /s /q `"$escapedRoot`""
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d', '/c', $delayedDelete -WindowStyle Hidden
}

Write-Host 'Meeting Room Reset was removed. Deleted user data cannot be restored.' -ForegroundColor Green
