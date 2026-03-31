#Requires -Version 5.1
<#
.SYNOPSIS
    Updates ProcNet TUI to the latest version from GitHub.

.DESCRIPTION
    Downloads the latest proctui.ps1 from the main branch and replaces
    the installed copy. No git required.

    Run with -Check to see if an update is available without installing it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\update.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\update.ps1 -Check
#>
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$RepoUrl    = 'https://raw.githubusercontent.com/simbamufasa/proctui/main/proctui.ps1'
$InstallDir = Join-Path $env:USERPROFILE '.proctui'
$ScriptDest = Join-Path $InstallDir 'proctui.ps1'

Write-Host ''
Write-Host '  ========================================' -ForegroundColor DarkCyan
Write-Host '   ProcNet TUI Updater'                     -ForegroundColor Cyan
Write-Host '  ========================================' -ForegroundColor DarkCyan
Write-Host ''

# Check current installation
if (-not (Test-Path $ScriptDest)) {
    Write-Host "  ProcNet TUI is not installed at $InstallDir" -ForegroundColor Red
    Write-Host "  Run install.ps1 first.`n" -ForegroundColor Red
    exit 1
}

# Download latest version
Write-Host '  Fetching latest version...' -ForegroundColor Gray
try {
    $latest = (New-Object System.Net.WebClient).DownloadString($RepoUrl)
} catch {
    Write-Host "  ERROR: Failed to download from GitHub." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)`n" -ForegroundColor DarkGray
    exit 1
}

# Compare with installed version
$current = Get-Content $ScriptDest -Raw
if ($current -eq $latest) {
    Write-Host "  Already up to date.`n" -ForegroundColor Green
    exit 0
}

if ($Check) {
    Write-Host "  Update available.`n" -ForegroundColor Yellow
    exit 0
}

# Install update
Copy-Item $ScriptDest "$ScriptDest.bak" -Force
$latest | Set-Content $ScriptDest -Encoding UTF8
Write-Host "  Updated successfully." -ForegroundColor Green
Write-Host "  Previous version backed up to $ScriptDest.bak" -ForegroundColor DarkGray
Write-Host ''
