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
$logDirectory = [string]$config.LogDirectory

if ([string]::IsNullOrWhiteSpace($profileRoot) -or $profileRoot.Length -lt 4) {
    throw 'Unsafe or invalid profile path in configuration.'
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
    return $candidate.StartsWith($profileRoot + $separator, [StringComparison]::OrdinalIgnoreCase)
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

    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
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

        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $script:removedCount++
        }
        catch {
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
