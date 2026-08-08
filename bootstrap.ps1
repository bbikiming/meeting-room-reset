[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Install')]
    [string]$Mode = 'Install',

    [string]$TargetUser,

    [switch]$AcceptDataLoss,

    [switch]$IncludeCloudDesktop,

    [string]$Version = 'v0.1.1'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repository = 'bbikiming/meeting-room-reset'
$assetName = "meeting-room-reset-$Version.zip"
$baseUrl = "https://github.com/$repository/releases/download/$Version"
$workRoot = Join-Path $env:TEMP "MeetingRoomReset-$Version"
$zipPath = Join-Path $workRoot $assetName
$hashPath = "$zipPath.sha256"
$packageRoot = Join-Path $workRoot 'package'

if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

Write-Host "Downloading Meeting Room Reset $Version..." -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$assetName" -OutFile $zipPath
Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$assetName.sha256" -OutFile $hashPath

$expectedHash = ((Get-Content -LiteralPath $hashPath -Raw).Trim().Split(' ')[0]).ToUpperInvariant()
$actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($expectedHash -ne $actualHash) {
    throw 'Package hash verification failed. Installation stopped.'
}

Expand-Archive -LiteralPath $zipPath -DestinationPath $packageRoot -Force
Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Unblock-File

$installParameters = @{
    Mode = $Mode
}
if (-not [string]::IsNullOrWhiteSpace($TargetUser)) {
    $installParameters.TargetUser = $TargetUser
}
if ($AcceptDataLoss) {
    $installParameters.AcceptDataLoss = $true
}
if ($IncludeCloudDesktop) {
    $installParameters.IncludeCloudDesktop = $true
}

& (Join-Path $packageRoot 'install.ps1') @installParameters
