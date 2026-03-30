#Requires -Version 5.1
<#
.SYNOPSIS
    Installs ProcNet TUI to your system.

.DESCRIPTION
    Copies proctui.ps1 to a persistent location, creates a launcher script
    (proctui.cmd) on your PATH, and optionally creates a Start Menu shortcut.

    Run with -Uninstall to remove everything.

.PARAMETER InstallDir
    Where to place the script. Defaults to ~\.proctui

.PARAMETER Uninstall
    Remove a previous installation.

.EXAMPLE
    # Install (run from the repo root)
    powershell -ExecutionPolicy Bypass -File .\install.ps1

    # Uninstall
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.proctui'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$BinDir      = Join-Path $env:USERPROFILE '.local\bin'
$LauncherCmd = Join-Path $BinDir 'proctui.cmd'
$LauncherPs1 = Join-Path $BinDir 'proctui.ps1'
$ScriptDest  = Join-Path $InstallDir 'proctui.ps1'
$ShortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$Shortcut    = Join-Path $ShortcutDir 'ProcNet TUI.lnk'

# ── Uninstall ────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host "`n  Uninstalling ProcNet TUI..." -ForegroundColor Cyan

    $removed = $false
    foreach ($f in @($ScriptDest, $LauncherCmd, $LauncherPs1, $Shortcut)) {
        if (Test-Path $f) {
            Remove-Item $f -Force
            Write-Host "  Removed $f" -ForegroundColor DarkGray
            $removed = $true
        }
    }
    if (Test-Path $InstallDir) {
        $remaining = Get-ChildItem $InstallDir -Force
        if ($remaining.Count -eq 0) {
            Remove-Item $InstallDir -Force
            Write-Host "  Removed $InstallDir" -ForegroundColor DarkGray
        }
    }

    # Clean PATH
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and $userPath.Split(';') -contains $BinDir) {
        $newPath = ($userPath.Split(';') | Where-Object { $_ -ne $BinDir }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Host "  Removed $BinDir from PATH" -ForegroundColor DarkGray
        $removed = $true
    }

    if ($removed) {
        Write-Host "`n  ProcNet TUI uninstalled.`n" -ForegroundColor Green
    } else {
        Write-Host "`n  Nothing to uninstall.`n" -ForegroundColor Yellow
    }
    return
}

# ── Install ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ========================================' -ForegroundColor DarkCyan
Write-Host '   ProcNet TUI Installer'                   -ForegroundColor Cyan
Write-Host '  ========================================' -ForegroundColor DarkCyan
Write-Host ''

# Locate source script
$SourceScript = Join-Path $PSScriptRoot 'proctui.ps1'
if (-not (Test-Path $SourceScript)) {
    Write-Host "  ERROR: proctui.ps1 not found next to this installer." -ForegroundColor Red
    Write-Host "  Run install.ps1 from the repository root.`n" -ForegroundColor Red
    exit 1
}

# Create directories
foreach ($dir in @($InstallDir, $BinDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "  Created $dir" -ForegroundColor DarkGray
    }
}

# Copy main script
Copy-Item $SourceScript $ScriptDest -Force
Write-Host "  Installed script to $ScriptDest" -ForegroundColor Green

# Create .cmd launcher (works from cmd.exe, PowerShell, and Windows Terminal)
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%USERPROFILE%\.proctui\proctui.ps1" %*
"@ | Set-Content $LauncherCmd -Encoding ASCII
Write-Host "  Created launcher  $LauncherCmd" -ForegroundColor Green

# Create .ps1 launcher (for pwsh / PowerShell direct invocation)
@"
# ProcNet TUI launcher
& "`$env:USERPROFILE\.proctui\proctui.ps1" @args
"@ | Set-Content $LauncherPs1 -Encoding UTF8
Write-Host "  Created launcher  $LauncherPs1" -ForegroundColor Green

# Add bin dir to user PATH if not present
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath -or -not ($userPath.Split(';') -contains $BinDir)) {
    $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "  Added $BinDir to user PATH" -ForegroundColor Green
    $pathUpdated = $true
}

# Create Start Menu shortcut
try {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($Shortcut)
    $lnk.TargetPath       = 'powershell.exe'
    $lnk.Arguments         = "-ExecutionPolicy Bypass -NoProfile -File `"$ScriptDest`""
    $lnk.WorkingDirectory  = $env:USERPROFILE
    $lnk.Description       = 'ProcNet TUI - Network Process Monitor'
    $lnk.Save()
    Write-Host "  Created Start Menu shortcut" -ForegroundColor Green
} catch {
    Write-Host "  Skipped Start Menu shortcut (non-critical)" -ForegroundColor Yellow
}

# Done
Write-Host ''
Write-Host '  Installation complete!' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Usage:' -ForegroundColor White
Write-Host '    proctui              (from any terminal)' -ForegroundColor Gray
Write-Host ''
if ($pathUpdated) {
    Write-Host '  NOTE: Restart your terminal for PATH changes to take effect.' -ForegroundColor Yellow
    Write-Host ''
}
Write-Host '  Tip: Run as Administrator for full network visibility.' -ForegroundColor DarkYellow
Write-Host ''
