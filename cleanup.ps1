[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$env:ProgramData\MeetingRoomReset\config.json"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$profileRoot = [IO.Path]::GetFullPath([string]$config.ProfilePath).TrimEnd('\', '/')
$configRoot = [IO.Path]::GetFullPath((Split-Path -Parent $ConfigPath)).TrimEnd('\', '/')
$logDirectory = [string]$config.LogDirectory

if ([string]::IsNullOrWhiteSpace($profileRoot) -or $profileRoot.Length -lt 4) {
    throw 'Unsafe or invalid profile path in configuration.'
}

$resolvedLogDirectory = [IO.Path]::GetFullPath($logDirectory).TrimEnd('\', '/')
$pathSeparator = [IO.Path]::DirectorySeparatorChar
if (-not $resolvedLogDirectory.StartsWith($configRoot + $pathSeparator, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe log directory in configuration.'
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory ("cleanup-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:removedCount = 0
$script:errorCount = 0

function Write-ResetLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Test-SafeUserPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $separator = [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($profileRoot + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $currentPath = $candidate
    while ($currentPath.Length -gt $profileRoot.Length) {
        try {
            if (Test-Path -LiteralPath $currentPath) {
                $currentItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
                if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $false
                }
            }
        }
        catch {
            return $false
        }

        $parentPath = [IO.Path]::GetDirectoryName($currentPath)
        if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath -eq $currentPath) {
            return $false
        }
        $currentPath = $parentPath.TrimEnd('\', '/')
    }

    return $currentPath.Equals($profileRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-SafeUserTreeRemoval {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $isReparsePoint = ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isReparsePoint) {
        if ($currentItem.PSIsContainer) {
            [IO.Directory]::Delete($currentItem.FullName)
        }
        else {
            [IO.File]::Delete($currentItem.FullName)
        }
        return
    }
    if (-not $currentItem.PSIsContainer) {
        Remove-Item -LiteralPath $currentItem.FullName -Force -ErrorAction Stop
        return
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $currentItem.FullName -Force -ErrorAction Stop)) {
        Invoke-SafeUserTreeRemoval -Path $child.FullName
    }
    Remove-Item -LiteralPath $currentItem.FullName -Force -ErrorAction Stop
}

function Invoke-UserItemRemoval {
    param([Parameter(Mandatory = $true)]$Item)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-SafeUserTreeRemoval -Path $Item.FullName
            return $true
        }
        catch {
            if (-not (Get-Item -LiteralPath $Item.FullName -Force -ErrorAction SilentlyContinue)) {
                return $true
            }
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds 350
            }
        }
    }

    return $false
}

function Clear-UserDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$PreserveExtensions = @(),
        [string[]]$PreserveNames = @()
    )

    if (-not (Test-SafeUserPath -Path $Path)) {
        $script:errorCount++
        Write-ResetLog 'Skipped an unsafe configured path.'
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    try {
        $directory = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $script:errorCount++
            Write-ResetLog 'Skipped a configured directory because it is a reparse point.'
            return
        }
        $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    }
    catch {
        $script:errorCount++
        Write-ResetLog 'Failed to enumerate a configured directory.'
        return
    }

    foreach ($item in $items) {
        $preserve = $false
        if (-not $item.PSIsContainer) {
            if ($PreserveNames -contains $item.Name) {
                $preserve = $true
            }
            if ($PreserveExtensions -contains $item.Extension.ToLowerInvariant()) {
                $preserve = $true
            }
        }

        if ($preserve) {
            continue
        }

        if (Invoke-UserItemRemoval -Item $item) {
            $script:removedCount++
        }
        else {
            $script:errorCount++
        }
    }
}

Write-ResetLog ("Cleanup started for {0}." -f [string]$config.TargetUser)

foreach ($rule in @($config.FolderRules)) {
    Clear-UserDirectory `
        -Path ([string]$rule.Path) `
        -PreserveExtensions @($rule.PreserveExtensions) `
        -PreserveNames @($rule.PreserveNames)
}

foreach ($browserRoot in @($config.BrowserDataRoots)) {
    Clear-UserDirectory -Path ([string]$browserRoot)
}

Get-ChildItem -LiteralPath $logDirectory -Filter 'cleanup-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-ResetLog ("Cleanup finished. Removed={0}; Errors={1}." -f $script:removedCount, $script:errorCount)

if ($script:errorCount -gt 0) {
    exit 1
}

exit 0
