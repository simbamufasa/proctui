# Developer-First Port Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform ProcNet TUI from a basic network process viewer into a developer-first port debugging tool with flicker-free rendering, parent/child process insight, port search, tree kill, and a listeners view.

**Architecture:** Single-file PowerShell TUI (`proctui.ps1`). All rendering moves to ANSI-escape StringBuilder buffering for flicker-free output. Data gathering moves to a background runspace for responsive UI during refresh. New features (port search, tree kill, listen view) layer on top of the existing main loop and input handler pattern.

**Tech Stack:** PowerShell 5.1+, Windows Console API (P/Invoke for VT processing), ANSI escape sequences, WMI/CIM for process tree data, PowerShell runspaces for async data fetch.

---

## File Structure

Only one code file is modified. Everything lives in `proctui.ps1`.

- **Modify:** `proctui.ps1` -- all rendering, data model, features, and async changes
- **Modify:** `README.md` -- update docs for new features and controls

---

## Task 1: ANSI Color System

**Files:**
- Modify: `proctui.ps1:1-33` (top of file, before state block)

- [ ] **Step 1: Add param block at top of file**

At the very top of `proctui.ps1` (line 1), before the header comment, add:

```powershell
param(
    [string]$Port = ''
)
```

This accepts the optional port argument for port search mode (used in Task 5). Adding it now avoids restructuring later.

- [ ] **Step 2: Add VT processing enablement and ANSI color lookup**

After the `$ErrorActionPreference` line (line 7), add the following block:

```powershell
# -- Enable ANSI/VT Processing ------------------------------------
try {
    Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -Name 'Win32' -Namespace 'ConsoleVT' -ErrorAction SilentlyContinue
    $h = [ConsoleVT.Win32]::GetStdHandle(-11)
    $m = 0
    [ConsoleVT.Win32]::GetConsoleMode($h, [ref]$m) | Out-Null
    [ConsoleVT.Win32]::SetConsoleMode($h, ($m -bor 0x0004)) | Out-Null
} catch {}

$ESC = [char]0x1b
$cReset = "$ESC[0m"

$script:AnsiFg = @{
    'Black'='30';'DarkRed'='31';'DarkGreen'='32';'DarkYellow'='33'
    'DarkBlue'='34';'DarkMagenta'='35';'DarkCyan'='36';'Gray'='37'
    'DarkGray'='90';'Red'='91';'Green'='92';'Yellow'='93'
    'Blue'='94';'Magenta'='95';'Cyan'='96';'White'='97'
}
$script:AnsiBg = @{
    'Black'='40';'DarkRed'='41';'DarkGreen'='42';'DarkYellow'='43'
    'DarkBlue'='44';'DarkMagenta'='45';'DarkCyan'='46';'Gray'='47'
    'DarkGray'='100';'Red'='101';'Green'='102';'Yellow'='103'
    'Blue'='104';'Magenta'='105';'Cyan'='106';'White'='107'
}

function Ansi([string]$fg, [string]$bg = $null) {
    $codes = @()
    if ($fg -and $script:AnsiFg[$fg]) { $codes += $script:AnsiFg[$fg] }
    if ($bg -and $script:AnsiBg[$bg]) { $codes += $script:AnsiBg[$bg] }
    if ($codes.Count -eq 0) { return '' }
    return "$ESC[$($codes -join ';')m"
}
```

- [ ] **Step 3: Verify VT processing works**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Expected: Script launches normally, colors display as before. The ANSI code is loaded but not yet used by the renderer. No errors on startup.

- [ ] **Step 4: Commit**

```bash
git add proctui.ps1
git commit -m "feat: add ANSI color system with VT processing enablement"
```

---

## Task 2: StringBuilder Buffered Rendering

**Files:**
- Modify: `proctui.ps1` -- replace `Write-Line`, `Write-Seg`, `Draw-Screen`, `Show-Loading`

- [ ] **Step 1: Replace Write-Line and Write-Seg with buffer helpers**

Replace the `Write-Line` function (currently around lines 151-160) and `Write-Seg` function (lines 163-168) with:

```powershell
function BufLine([System.Text.StringBuilder]$buf, [string]$text, [string]$fg, [string]$bg, [switch]$NoNewline) {
    $w = [Console]::WindowWidth
    $padded = $text
    if ($padded.Length -lt $w) { $padded = $padded + (' ' * ($w - $padded.Length)) }
    elseif ($padded.Length -gt $w) { $padded = $padded.Substring(0, $w) }
    [void]$buf.Append((Ansi $fg $bg))
    [void]$buf.Append($padded)
    [void]$buf.Append($cReset)
    if (-not $NoNewline) { [void]$buf.Append("`n") }
}
```

Keep `Pad` and `PadNum` functions unchanged.

- [ ] **Step 2: Rewrite Draw-Screen to use StringBuilder**

Replace the entire `Draw-Screen` function with:

```powershell
function Draw-Screen($data) {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight
    [Console]::CursorVisible = $false

    $count = if ($data) { $data.Count } else { 0 }
    $buf = [System.Text.StringBuilder]::new($w * $h * 2)

    [void]$buf.Append("$ESC[H")  # cursor home

    # -- Row 0: Title Bar --
    $title = "  [*] ProcNet TUI -- $count network processes "
    $ts    = " $(Get-Date -Format 'HH:mm:ss') "
    $gap   = [math]::Max(0, $w - $title.Length - $ts.Length)
    BufLine $buf "$title$(' ' * $gap)$ts" $cTitle 'DarkCyan'

    # -- Row 1: blank spacer --
    BufLine $buf '' 'Gray'

    # -- Row 2: Column Headers --
    $sortInd = if ($script:sortAsc) { '^' } else { 'v' }
    $cmdW = $w - 8 - 20 - 6 - 14 - 9 - 10 - 2
    if ($cmdW -lt 10) { $cmdW = 10 }
    $cols = @(
        @{ Name='PID';     W=8;  Key='PID' },
        @{ Name='PROCESS'; W=20; Key='Name' },
        @{ Name='CONN';    W=6;  Key='Connections' },
        @{ Name='STATE';   W=14; Key='State' },
        @{ Name='CPU(s)';  W=9;  Key='CPU' },
        @{ Name='MEM(MB)'; W=10; Key='MemMB' },
        @{ Name='CMD';     W=$cmdW; Key='CmdLine' }
    )
    $headerLine = ''
    foreach ($c in $cols) {
        $label = if ($c.Key -eq $script:sortColumn) { "$($c.Name)$sortInd" } else { $c.Name }
        $headerLine += Pad " $label" $c.W
    }
    BufLine $buf $headerLine 'White' 'DarkBlue'

    # -- Row 3: separator --
    BufLine $buf ('-' * $w) $cBorder

    # -- Rows 4..(h-7): Table Body --
    $bodyStart = 4
    $bodyEnd   = $h - 6
    $maxRows   = $bodyEnd - $bodyStart
    if ($maxRows -lt 1) { $maxRows = 1 }

    if ($count -eq 0) {
        BufLine $buf "  No network processes found. Try running as Administrator." 'DarkYellow'
        for ($r = 1; $r -lt $maxRows; $r++) { BufLine $buf '' 'Gray' }
    } else {
        if ($script:selectedIndex -ge $count) { $script:selectedIndex = $count - 1 }
        if ($script:selectedIndex -lt 0) { $script:selectedIndex = 0 }
        if ($script:selectedIndex -lt $script:scrollOffset) {
            $script:scrollOffset = $script:selectedIndex
        }
        if ($script:selectedIndex -ge ($script:scrollOffset + $maxRows)) {
            $script:scrollOffset = $script:selectedIndex - $maxRows + 1
        }

        for ($i = 0; $i -lt $maxRows; $i++) {
            $dataIdx = $i + $script:scrollOffset
            if ($dataIdx -ge $count) {
                BufLine $buf '' 'Gray'
                continue
            }

            $item = $data[$dataIdx]
            $isSelected = ($dataIdx -eq $script:selectedIndex)

            $cmd = if ($item.CmdLine) { $item.CmdLine } else { $item.TopAddr }
            if (-not $cmd) { $cmd = '--' }
            if ($cmd.Length -gt ($cmdW - 2)) { $cmd = $cmd.Substring(0, $cmdW - 4) + '...' }

            $line = (PadNum $item.PID 7) + ' ' +
                    (Pad $item.Name 20) +
                    (PadNum $item.Connections 5) + ' ' +
                    (Pad $item.State 14) +
                    (PadNum $item.CPU 8) + ' ' +
                    (PadNum $item.MemMB 9) + ' ' +
                    (Pad $cmd $cmdW)

            if ($line.Length -lt $w) { $line = $line + (' ' * ($w - $line.Length)) }
            elseif ($line.Length -gt $w) { $line = $line.Substring(0, $w) }

            if ($isSelected) {
                [void]$buf.Append((Ansi $cSelected $cSelBg))
                [void]$buf.Append($line)
                [void]$buf.Append("$cReset`n")
            } else {
                $stateColor = switch ($item.State) {
                    'Established' { $cEstab }
                    'Listen'      { $cListen }
                    default       { $cOther }
                }
                $preState = 8 + 20 + 6  # column offset to STATE
                if ($preState -lt $line.Length) {
                    $postState = [math]::Min($preState + 14, $line.Length)
                    [void]$buf.Append((Ansi 'Gray'))
                    [void]$buf.Append($line.Substring(0, $preState))
                    [void]$buf.Append((Ansi $stateColor))
                    [void]$buf.Append($line.Substring($preState, $postState - $preState))
                    [void]$buf.Append((Ansi 'Gray'))
                    [void]$buf.Append($line.Substring($postState))
                } else {
                    [void]$buf.Append((Ansi 'Gray'))
                    [void]$buf.Append($line)
                }
                [void]$buf.Append("$cReset`n")
            }
        }
    }

    # -- Detail Pane --
    BufLine $buf ('=' * $w) $cBorder

    $sel = if ($count -gt 0 -and $script:selectedIndex -lt $count) { $data[$script:selectedIndex] } else { $null }

    if ($sel) {
        $parentInfo = ''
        if ($sel.ParentName -and $sel.ParentName -ne '--') {
            $parentInfo = "  |  Parent: $($sel.ParentName) (PID $($sel.ParentPID))"
        }
        BufLine $buf " >> $($sel.Name) (PID $($sel.PID)) -- $($sel.Connections) connection(s)$parentInfo" 'White'

        $addrLines = @($sel.Addresses | Select-Object -First 2)
        for ($a = 0; $a -lt 2; $a++) {
            if ($a -lt $addrLines.Count) {
                $aColor = if ($addrLines[$a] -match 'Established') { $cEstab }
                          elseif ($addrLines[$a] -match 'Listen') { $cListen }
                          else { $cOther }
                BufLine $buf "   $($addrLines[$a])" $aColor
            } else {
                BufLine $buf '' 'Gray'
            }
        }
        if ($sel.Addresses.Count -gt 2) {
            BufLine $buf "   ... +$($sel.Addresses.Count - 2) more (press A)" $cBorder
        } else {
            BufLine $buf '' 'Gray'
        }
    } else {
        for ($r = 0; $r -lt 4; $r++) { BufLine $buf '' 'Gray' }
    }

    # -- Status line --
    if ($script:statusMsg -and ([datetime]::Now - $script:statusTime).TotalSeconds -lt 4) {
        $statusColor = if ($script:statusMsg -match 'Killed|Stopped') { $cDanger } else { $cHelp }
        BufLine $buf "  $($script:statusMsg)" $statusColor
    } else {
        BufLine $buf '' 'Gray'
    }

    # -- Help Bar (last row, no trailing newline) --
    $filterLabel = ''
    if ($script:filterText) { $filterLabel += " | Filter: $($script:filterText)" }
    if ($script:portFilter) { $filterLabel += " | Port: $($script:portFilter)" }
    if ($script:listenView) { $filterLabel += " | View: Listeners" }
    $help = " Up/Dn Navigate | Enter/K Stop | / Filter | P Port | L Listen | S Sort | R Refresh | A Addrs | Q Quit$filterLabel"
    BufLine $buf $help $cTitle 'DarkBlue' -NoNewline

    # Flush entire screen in one write
    [Console]::Out.Write($buf.ToString())

    # -- Confirm Kill overlay (direct write on top) --
    if ($script:confirmKill -and $sel) {
        $cy = [math]::Floor($h / 2) - 1
        $box = "  !!  Stop '$($sel.Name)' (PID $($sel.PID))?  [Y] Process | [T] Tree | [N] Cancel  "
        $bpad = [math]::Max(0, [math]::Floor(($w - $box.Length - 2) / 2))
        $blank = ' ' * ($box.Length + 2)
        $da = Ansi 'White' 'DarkRed'
        [Console]::SetCursorPosition($bpad, $cy)
        [Console]::Write("$da$blank$cReset")
        [Console]::SetCursorPosition($bpad, $cy + 1)
        [Console]::Write("$da $box $cReset")
        [Console]::SetCursorPosition($bpad, $cy + 2)
        [Console]::Write("$da$blank$cReset")
    }
}
```

Note: The kill dialog already shows `[T] Tree` for Task 6. Until Task 6 is implemented, pressing T will just close the dialog (same as N). The column header says `CMD` and falls back to `TopAddr` when `CmdLine` is not yet populated (Task 4 adds it).

- [ ] **Step 3: Update Show-Loading to use ANSI direct write**

Replace the `Show-Loading` function with:

```powershell
function Show-Loading([string]$msg = 'Scanning network...') {
    $h = [Console]::WindowHeight
    $w = [Console]::WindowWidth
    $statusY = $h - 2
    $frame = $script:spinnerFrames[$script:spinnerIdx % $script:spinnerFrames.Count]
    $script:spinnerIdx++
    $text = "  $frame $msg"
    if ($text.Length -lt $w) { $text = $text + (' ' * ($w - $text.Length)) }
    elseif ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
    if ($statusY -ge 0 -and $statusY -lt [Console]::BufferHeight) {
        [Console]::SetCursorPosition(0, $statusY)
        [Console]::Write("$(Ansi 'Cyan')$text$cReset")
    }
}
```

- [ ] **Step 4: Verify rendering**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Expected:
- Screen renders with correct colors (title bar cyan, headers blue, states colored)
- No flickering when navigating with arrow keys
- Kill dialog appears correctly when pressing Enter/K
- Help bar at bottom is correct
- Address popup (A key) still works (uses Write-Host directly)

- [ ] **Step 5: Commit**

```bash
git add proctui.ps1
git commit -m "feat: replace Write-Host rendering with ANSI StringBuilder buffer"
```

---

## Task 3: Dirty Tracking

**Files:**
- Modify: `proctui.ps1` -- state block, main loop

- [ ] **Step 1: Add dirty tracking state variables**

In the state block (around line 10), add:

```powershell
$script:dirty          = $true
$script:lastWidth      = 0
$script:lastHeight     = 0
```

- [ ] **Step 2: Modify main loop to skip draws when clean**

In the main loop (`while ($true) {`), restructure the logic to:

```powershell
    while ($true) {
        # Check for resize
        $curW = [Console]::WindowWidth
        $curH = [Console]::WindowHeight
        if ($curW -ne $script:lastWidth -or $curH -ne $script:lastHeight) {
            $script:lastWidth = $curW
            $script:lastHeight = $curH
            $script:dirty = $true
            try { [Console]::BufferWidth = $curW } catch {}
        }

        # Check if status message just expired (needs one more redraw to clear it)
        if ($script:statusMsg -and ([datetime]::Now - $script:statusTime).TotalSeconds -ge 4) {
            $script:statusMsg = ''
            $script:dirty = $true
        }

        # Auto-refresh data
        if (([datetime]::Now - $script:lastRefresh).TotalSeconds -ge $script:refreshInterval) {
            Show-Loading 'Auto-refreshing...'
            $data = Refresh-Data
            $script:dirty = $true
        }

        # Only redraw if dirty
        if ($script:dirty) {
            Draw-Screen $data
            $script:dirty = $false
        }

        # Poll for input
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            if (-not [Console]::KeyAvailable) { continue }
        }

        $key = [Console]::ReadKey($true)
        $script:dirty = $true  # any keypress triggers redraw

        # Drain buffered keys for rapid navigation
        while ([Console]::KeyAvailable -and ($key.Key -eq 'UpArrow' -or $key.Key -eq 'DownArrow')) {
            $key = [Console]::ReadKey($true)
        }

        # ... rest of key handling unchanged ...
    }
```

- [ ] **Step 3: Verify dirty tracking**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Expected:
- Screen only redraws on key press, data refresh, or window resize
- Navigation still feels responsive
- Status messages appear and clear correctly after 4 seconds
- Auto-refresh still works every 3 seconds

- [ ] **Step 4: Commit**

```bash
git add proctui.ps1
git commit -m "perf: add dirty tracking to skip unnecessary screen redraws"
```

---

## Task 4: Parent Process Info & Command Line

**Files:**
- Modify: `proctui.ps1` -- `Get-NetProcesses` function, data model

- [ ] **Step 1: Add CIM batch query to Get-NetProcesses**

Inside `Get-NetProcesses`, after the existing `$grouped` loop (after the UDP grouping, before the `$results = @()` line), add:

```powershell
    # Batch CIM query for command line and parent info
    $cimProcs = @{}
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            ForEach-Object { $cimProcs[$_.ProcessId] = $_ }
    } catch {}
```

- [ ] **Step 2: Add ParentPID, ParentName, CmdLine to data model**

Inside the `foreach ($p in $grouped.Keys)` loop, after the `$primaryState` assignment and before building the `[PSCustomObject]`, add:

```powershell
        $cim = $cimProcs[$p]
        $cmdLine = if ($cim -and $cim.CommandLine) {
            $cim.CommandLine
        } else { '' }
        $parentPid = if ($cim) { $cim.ParentProcessId } else { 0 }
        $parentName = '--'
        if ($parentPid -and $parentPid -ne 0) {
            $parentCim = $cimProcs[$parentPid]
            if ($parentCim) {
                $parentName = $parentCim.Name
            } else {
                $pp = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
                if ($pp) { $parentName = $pp.ProcessName }
            }
        }
```

Then update the `[PSCustomObject]` to include the new fields:

```powershell
        $results += [PSCustomObject]@{
            PID         = $p
            Name        = $proc.ProcessName
            Connections = ($tcpList.Count + $udpList.Count)
            State       = $primaryState
            CPU         = [math]::Round($proc.CPU, 1)
            MemMB       = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            Addresses   = $addrs
            TopAddr     = $topAddr
            CmdLine     = $cmdLine
            ParentPID   = $parentPid
            ParentName  = $parentName
        }
```

- [ ] **Step 3: Verify parent info and command line display**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Expected:
- CMD column shows command lines (e.g., `node server.js`, `chrome.exe --type=...`)
- Detail pane shows `Parent: parentName (PID xxx)` for processes with known parents
- Detail pane shows no parent info when parent is unknown

- [ ] **Step 4: Commit**

```bash
git add proctui.ps1
git commit -m "feat: add parent process info and command line column via CIM"
```

---

## Task 5: Port Search Mode

**Files:**
- Modify: `proctui.ps1` -- state block, `Get-NetProcesses`, new `Enter-PortMode` function, main loop key handler

- [ ] **Step 1: Add port filter state and CLI argument handling**

In the state block, add:

```powershell
$script:portFilter     = ''
```

Right after the state block, add the CLI argument handler:

```powershell
if ($Port) { $script:portFilter = $Port }
```

- [ ] **Step 2: Add port filtering to Get-NetProcesses**

In `Get-NetProcesses`, after the existing `filterText` block (the `if ($script:filterText)` section), add:

```powershell
    if ($script:portFilter) {
        $pf = $script:portFilter
        $results = $results | Where-Object {
            $match = $false
            foreach ($a in $_.Addresses) {
                if ($a -match ":$pf\b") { $match = $true; break }
            }
            $match
        }
    }
```

- [ ] **Step 3: Implement Enter-PortMode function**

Add after the existing `Enter-FilterMode` function:

```powershell
function Enter-PortMode {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight

    $prompt = " Port: $($script:portFilter)_  (Enter=search, Esc=cancel)"
    [Console]::SetCursorPosition(0, $h - 1)
    [Console]::Write("$(Ansi $cFilter 'Black')$(Pad $prompt $w)$cReset")
    [Console]::CursorVisible = $true

    while ($true) {
        $key = [Console]::ReadKey($true)

        if ($key.Key -eq 'Enter') { break }
        elseif ($key.Key -eq 'Escape') {
            $script:portFilter = ''
            break
        }
        elseif ($key.Key -eq 'Backspace') {
            if ($script:portFilter.Length -gt 0) {
                $script:portFilter = $script:portFilter.Substring(0, $script:portFilter.Length - 1)
            }
        }
        else {
            if ($key.KeyChar -match '[0-9]') {
                $script:portFilter += $key.KeyChar
            }
        }

        $prompt = " Port: $($script:portFilter)_  (Enter=search, Esc=cancel)"
        [Console]::SetCursorPosition(0, $h - 1)
        [Console]::Write("$(Ansi $cFilter 'Black')$(Pad $prompt $w)$cReset")
    }

    [Console]::CursorVisible = $false
    $script:selectedIndex = 0
    $script:scrollOffset = 0
}
```

- [ ] **Step 4: Wire up P hotkey in main loop**

In the `switch ($key.KeyChar)` block inside the main loop, add:

```powershell
                    'p' { Enter-PortMode; $data = Refresh-Data }
                    'P' { Enter-PortMode; $data = Refresh-Data }
```

- [ ] **Step 5: Verify port search**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Test 1: Press P, type `443`, press Enter. Only processes with port 443 should appear.
Test 2: Press P, press Escape. Filter should clear.
Test 3: Close and relaunch with: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1 -Port 80`
Expected: Launches pre-filtered to port 80.

- [ ] **Step 6: Commit**

```bash
git add proctui.ps1
git commit -m "feat: add port search mode with P hotkey and CLI argument"
```

---

## Task 6: Process Tree Kill

**Files:**
- Modify: `proctui.ps1` -- new `Get-ProcessTree` function, kill confirmation handler

- [ ] **Step 1: Implement Get-ProcessTree function**

Add before the main loop (after the `Sort-CachedData` function):

```powershell
function Get-ProcessTree([int]$rootPid) {
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $children = @{}
    foreach ($p in $allProcs) {
        if ($p.ParentProcessId) {
            if (-not $children[$p.ParentProcessId]) {
                $children[$p.ParentProcessId] = @()
            }
            $children[$p.ParentProcessId] += $p.ProcessId
        }
    }

    $tree = @()
    $queue = @($rootPid)
    $visited = @{}
    while ($queue.Count -gt 0) {
        $current = $queue[0]
        $queue = @($queue | Select-Object -Skip 1)
        if ($visited[$current]) { continue }
        $visited[$current] = $true
        $tree += $current
        if ($children[$current]) {
            $queue += $children[$current]
        }
        if ($tree.Count -ge 50) { break }
    }

    # Reverse so leaves come first (bottom-up kill order)
    [array]::Reverse($tree)
    return $tree
}
```

- [ ] **Step 2: Update kill confirmation handler for tree kill**

In the main loop, replace the existing confirm kill block:

```powershell
        if ($script:confirmKill) {
            if ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y') {
                $sel = $data[$script:selectedIndex]
                try {
                    Stop-Process -Id $sel.PID -Force -ErrorAction Stop
                    $script:statusMsg  = "X Killed '$($sel.Name)' (PID $($sel.PID))"
                    $script:statusTime = [datetime]::Now
                    Start-Sleep -Milliseconds 300
                    $data = Refresh-Data
                } catch {
                    $script:statusMsg  = "!! Failed: $($_.Exception.Message)"
                    $script:statusTime = [datetime]::Now
                }
            }
            elseif ($key.KeyChar -eq 't' -or $key.KeyChar -eq 'T') {
                $sel = $data[$script:selectedIndex]
                $tree = Get-ProcessTree $sel.PID
                $killed = 0
                $failed = 0
                foreach ($pid in $tree) {
                    try {
                        Stop-Process -Id $pid -Force -ErrorAction Stop
                        $killed++
                    } catch {
                        $failed++
                    }
                }
                if ($failed -eq 0) {
                    $script:statusMsg = "X Killed '$($sel.Name)' tree ($killed processes)"
                } else {
                    $script:statusMsg = "X Killed $killed/$($killed+$failed) in '$($sel.Name)' tree ($failed access denied)"
                }
                $script:statusTime = [datetime]::Now
                Start-Sleep -Milliseconds 300
                $data = Refresh-Data
            }
            $script:confirmKill = $false
            continue
        }
```

- [ ] **Step 3: Verify tree kill**

Run as Administrator: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Expected:
- Kill dialog shows `[Y] Process | [T] Tree | [N] Cancel`
- Pressing Y kills only the selected process
- Pressing T kills the process and its children
- Status message shows count of killed processes
- Pressing N cancels

- [ ] **Step 4: Commit**

```bash
git add proctui.ps1
git commit -m "feat: add process tree kill with T hotkey in kill dialog"
```

---

## Task 7: Listen-First View

**Files:**
- Modify: `proctui.ps1` -- state block, `Get-NetProcesses`, main loop key handler

- [ ] **Step 1: Add listen view state**

In the state block, add:

```powershell
$script:listenView     = $false
$script:prevSortColumn = 'PID'
$script:prevSortAsc    = $true
```

- [ ] **Step 2: Add listen view filtering to Get-NetProcesses**

In `Get-NetProcesses`, after the `portFilter` block (added in Task 5), add:

```powershell
    if ($script:listenView) {
        $results = $results | Where-Object { $_.State -eq 'Listen' }
    }
```

- [ ] **Step 3: Wire up L hotkey with sort override**

In the `switch ($key.KeyChar)` block inside the main loop, add:

```powershell
                    'l' {
                        $script:listenView = -not $script:listenView
                        if ($script:listenView) {
                            $script:prevSortColumn = $script:sortColumn
                            $script:prevSortAsc    = $script:sortAsc
                            $script:sortColumn     = 'PID'
                            $script:sortAsc        = $true
                            $script:statusMsg      = "View: Listeners only"
                        } else {
                            $script:sortColumn = $script:prevSortColumn
                            $script:sortAsc    = $script:prevSortAsc
                            $script:statusMsg  = "View: All processes"
                        }
                        $script:statusTime = [datetime]::Now
                        $script:selectedIndex = 0
                        $script:scrollOffset = 0
                        $data = Refresh-Data
                    }
                    'L' {
                        $script:listenView = -not $script:listenView
                        if ($script:listenView) {
                            $script:prevSortColumn = $script:sortColumn
                            $script:prevSortAsc    = $script:sortAsc
                            $script:sortColumn     = 'PID'
                            $script:sortAsc        = $true
                            $script:statusMsg      = "View: Listeners only"
                        } else {
                            $script:sortColumn = $script:prevSortColumn
                            $script:sortAsc    = $script:prevSortAsc
                            $script:statusMsg  = "View: All processes"
                        }
                        $script:statusTime = [datetime]::Now
                        $script:selectedIndex = 0
                        $script:scrollOffset = 0
                        $data = Refresh-Data
                    }
```

Note: The L/l cases are duplicated because PowerShell's `switch` on `$key.KeyChar` is case-sensitive. An alternative is to convert to lowercase first, but keeping it explicit matches the existing pattern in the codebase.

- [ ] **Step 4: Verify listen view**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Test 1: Press L. Only processes with Listen state should appear. Status bar shows `View: Listeners`.
Test 2: Press L again. All processes return. Sort restores to previous.
Test 3: Press L, then P and type a port. Both filters stack.

- [ ] **Step 5: Commit**

```bash
git add proctui.ps1
git commit -m "feat: add listen-first view toggle with L hotkey"
```

---

## Task 8: Background Data Fetch

**Files:**
- Modify: `proctui.ps1` -- extract data logic, runspace setup, main loop async polling

- [ ] **Step 1: Extract raw data gathering into a scriptblock**

Create a `$script:fetchScript` scriptblock above the main loop. This contains the core data-gathering logic from `Get-NetProcesses` but WITHOUT sort/filter (those are applied on the main thread). Copy the body of `Get-NetProcesses` up to and including building `$results`, but exclude the sort and filter sections:

```powershell
$script:fetchScript = {
    $ErrorActionPreference = 'SilentlyContinue'

    $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -ne 0 } |
        Select-Object OwningProcess, LocalAddress, LocalPort, RemoteAddress, RemotePort, State

    $udps = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -ne 0 } |
        Select-Object OwningProcess, LocalAddress, LocalPort

    $grouped = @{}
    foreach ($c in $conns) {
        $p = $c.OwningProcess
        if (-not $grouped[$p]) { $grouped[$p] = @{ TCP = @(); UDP = @() } }
        $grouped[$p].TCP += $c
    }
    foreach ($u in $udps) {
        $p = $u.OwningProcess
        if (-not $grouped[$p]) { $grouped[$p] = @{ TCP = @(); UDP = @() } }
        $grouped[$p].UDP += $u
    }

    $cimProcs = @{}
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            ForEach-Object { $cimProcs[$_.ProcessId] = $_ }
    } catch {}

    $results = @()
    foreach ($p in $grouped.Keys) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        $tcpList = $grouped[$p].TCP
        $udpList = $grouped[$p].UDP

        $addrs = @()
        $states = @{}
        $listenPorts = @()
        $remotePeers = @()
        foreach ($t in $tcpList) {
            $local  = "$($t.LocalAddress):$($t.LocalPort)"
            $remote = if ($t.RemoteAddress -and $t.RemoteAddress -ne '0.0.0.0' -and $t.RemoteAddress -ne '::') {
                "$($t.RemoteAddress):$($t.RemotePort)"
            } else { '*' }
            $addrs += "TCP $local -> $remote ($($t.State))"
            if ($states.ContainsKey($t.State)) { $states[$t.State]++ } else { $states[$t.State] = 1 }
            if ($t.State -eq 'Listen') {
                if ($listenPorts -notcontains $t.LocalPort) { $listenPorts += $t.LocalPort }
            }
            if ($t.State -eq 'Established' -and $t.RemoteAddress -and $t.RemoteAddress -ne '0.0.0.0' -and $t.RemoteAddress -ne '::') {
                $peer = "$($t.RemoteAddress):$($t.RemotePort)"
                if ($remotePeers.Count -lt 3 -and $remotePeers -notcontains $peer) { $remotePeers += $peer }
            }
        }
        $udpPorts = @()
        foreach ($u in $udpList) {
            $addrs += "UDP $($u.LocalAddress):$($u.LocalPort)"
            if ($states.ContainsKey('UDP')) { $states['UDP']++ } else { $states['UDP'] = 1 }
            if ($udpPorts -notcontains $u.LocalPort) { $udpPorts += $u.LocalPort }
        }

        $parts = @()
        if ($listenPorts.Count -gt 0) {
            $sorted = $listenPorts | Sort-Object
            $parts += "LISTEN:" + ($sorted -join ',')
        }
        if ($udpPorts.Count -gt 0) {
            $sorted = $udpPorts | Sort-Object
            if ($sorted.Count -gt 5) {
                $parts += "UDP:" + (($sorted | Select-Object -First 5) -join ',') + "+$($sorted.Count - 5)"
            } else {
                $parts += "UDP:" + ($sorted -join ',')
            }
        }
        if ($remotePeers.Count -gt 0) {
            $parts += "-> " + ($remotePeers -join ', ')
        }
        $topAddr = if ($parts.Count -gt 0) { $parts -join ' | ' } else { '--' }

        $primaryState = if ($states['Established']) { 'Established' }
                        elseif ($states['Listen'])  { 'Listen' }
                        elseif ($states['UDP'])     { 'UDP' }
                        else { $k = $states.Keys | Select-Object -First 1; if ($k) { $k } else { 'Unknown' } }

        $cim = $cimProcs[$p]
        $cmdLine = if ($cim -and $cim.CommandLine) { $cim.CommandLine } else { '' }
        $parentPid = if ($cim) { $cim.ParentProcessId } else { 0 }
        $parentName = '--'
        if ($parentPid -and $parentPid -ne 0) {
            $parentCim = $cimProcs[$parentPid]
            if ($parentCim) { $parentName = $parentCim.Name }
        }

        $results += [PSCustomObject]@{
            PID         = $p
            Name        = $proc.ProcessName
            Connections = ($tcpList.Count + $udpList.Count)
            State       = $primaryState
            CPU         = [math]::Round($proc.CPU, 1)
            MemMB       = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            Addresses   = $addrs
            TopAddr     = $topAddr
            CmdLine     = $cmdLine
            ParentPID   = $parentPid
            ParentName  = $parentName
        }
    }

    return $results
}
```

- [ ] **Step 2: Create Apply-SortFilter function**

Add a function that applies the current sort, text filter, port filter, and listen view to raw data:

```powershell
function Apply-SortFilter($rawData) {
    $results = $rawData

    # Sort
    if ($script:sortAsc) {
        $results = $results | Sort-Object -Property $script:sortColumn
    } else {
        $results = $results | Sort-Object -Property $script:sortColumn -Descending
    }

    # Text filter
    if ($script:filterText) {
        $ft = $script:filterText
        $results = $results | Where-Object {
            $_.Name -like "*$ft*" -or
            "$($_.PID)" -like "*$ft*" -or
            ($_.Addresses -join ' ') -like "*$ft*"
        }
    }

    # Port filter
    if ($script:portFilter) {
        $pf = $script:portFilter
        $results = $results | Where-Object {
            $match = $false
            foreach ($a in $_.Addresses) {
                if ($a -match ":$pf\b") { $match = $true; break }
            }
            $match
        }
    }

    # Listen view
    if ($script:listenView) {
        $results = $results | Where-Object { $_.State -eq 'Listen' }
    }

    return @($results)
}
```

- [ ] **Step 3: Add runspace setup and async functions**

Add before the main loop:

```powershell
# -- Background Fetch Setup ----------------------------------------
$script:bgRunspace  = $null
$script:bgPipeline  = $null
$script:bgResult    = $null
$script:bgRawData   = @()

function Start-BackgroundFetch {
    if ($script:bgResult) { return }  # already in progress
    $script:bgPipeline = [PowerShell]::Create()
    $script:bgPipeline.Runspace = $script:bgRunspace
    [void]$script:bgPipeline.AddScript($script:fetchScript)
    $script:bgResult = $script:bgPipeline.BeginInvoke()
}

function Poll-BackgroundFetch {
    if (-not $script:bgResult) { return $false }
    if (-not $script:bgResult.IsCompleted) { return $false }

    try {
        $script:bgRawData = @($script:bgPipeline.EndInvoke($script:bgResult))
    } catch {
        $script:bgRawData = @()
    }
    $script:bgPipeline.Dispose()
    $script:bgPipeline = $null
    $script:bgResult   = $null
    $script:lastRefresh = [datetime]::Now
    return $true
}

# Create persistent runspace
$script:bgRunspace = [runspacefactory]::CreateRunspace()
$script:bgRunspace.Open()
```

- [ ] **Step 4: Update main loop to use async data fetch**

Replace the synchronous `Refresh-Data` calls and auto-refresh logic in the main loop:

```powershell
    # Initial synchronous fetch (startup)
    Show-Loading 'Starting up...'
    $script:bgRawData = @(& $script:fetchScript)
    $script:lastRefresh = [datetime]::Now
    $data = Apply-SortFilter $script:bgRawData

    while ($true) {
        # Check resize
        $curW = [Console]::WindowWidth
        $curH = [Console]::WindowHeight
        if ($curW -ne $script:lastWidth -or $curH -ne $script:lastHeight) {
            $script:lastWidth = $curW
            $script:lastHeight = $curH
            $script:dirty = $true
            try { [Console]::BufferWidth = $curW } catch {}
        }

        # Check status expiry
        if ($script:statusMsg -and ([datetime]::Now - $script:statusTime).TotalSeconds -ge 4) {
            $script:statusMsg = ''
            $script:dirty = $true
        }

        # Poll for completed background fetch
        if (Poll-BackgroundFetch) {
            $data = Apply-SortFilter $script:bgRawData
            $script:dirty = $true
        }

        # Schedule background fetch if due
        if (([datetime]::Now - $script:lastRefresh).TotalSeconds -ge $script:refreshInterval) {
            Start-BackgroundFetch
        }

        # Only redraw if dirty
        if ($script:dirty) {
            Draw-Screen $data
            $script:dirty = $false
        }

        # Poll for input
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            if (-not [Console]::KeyAvailable) { continue }
        }

        $key = [Console]::ReadKey($true)
        $script:dirty = $true

        while ([Console]::KeyAvailable -and ($key.Key -eq 'UpArrow' -or $key.Key -eq 'DownArrow')) {
            $key = [Console]::ReadKey($true)
        }

        # ... key handlers ...
```

Update the `R`/`r` (manual refresh) key handler to:

```powershell
                    'r' {
                        $script:bgRawData = @(& $script:fetchScript)
                        $script:lastRefresh = [datetime]::Now
                        $data = Apply-SortFilter $script:bgRawData
                        $script:statusMsg = "~ Refreshed"; $script:statusTime = [datetime]::Now
                    }
```

Update the `s`/`S` (sort) handler to re-apply sort from cached raw data:

```powershell
                    's' { Cycle-Sort; $data = Apply-SortFilter $script:bgRawData }
```

Update the `/` (filter) handler similarly:

```powershell
                    '/' { Enter-FilterMode; $data = Apply-SortFilter $script:bgRawData }
```

Update the `p`/`P` handler:

```powershell
                    'p' { Enter-PortMode; $data = Apply-SortFilter $script:bgRawData }
```

Update the `l`/`L` handler to use `Apply-SortFilter` instead of `Refresh-Data`:

```powershell
                        $data = Apply-SortFilter $script:bgRawData
```

Update the kill handlers (both Y and T) to do a synchronous refresh after kill:

```powershell
                        $script:bgRawData = @(& $script:fetchScript)
                        $script:lastRefresh = [datetime]::Now
                        $data = Apply-SortFilter $script:bgRawData
```

- [ ] **Step 5: Clean up runspace in finally block**

Update the `finally` block at the end of the script:

```powershell
finally {
    if ($script:bgPipeline) { $script:bgPipeline.Dispose() }
    if ($script:bgRunspace) { $script:bgRunspace.Dispose() }
    [Console]::CursorVisible = $true
    [Console]::ResetColor()
}
```

- [ ] **Step 6: Remove old Get-NetProcesses and Refresh-Data functions**

Delete the original `Get-NetProcesses` function and `Refresh-Data` function -- they are fully replaced by `$script:fetchScript` + `Apply-SortFilter`. Also remove `Sort-CachedData` -- it is replaced by `Apply-SortFilter`.

- [ ] **Step 7: Verify background fetch**

Run: `powershell -ExecutionPolicy Bypass -File .\proctui.ps1`

Expected:
- UI launches and shows data
- Arrow key navigation is responsive even during the 3-second auto-refresh
- Manual refresh (R) works
- Sort (S), filter (/), port search (P), and listen view (L) all work
- Kill (Y) and tree kill (T) work and data refreshes after

- [ ] **Step 8: Commit**

```bash
git add proctui.ps1
git commit -m "perf: move data fetching to background runspace for responsive UI"
```

---

## Task 9: README Update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Update the feature list, keyboard controls table, usage section, and example display to reflect all new features:

1. Update the ASCII art example to show `CMD` column instead of `PORTS`
2. Add new features to the feature list:
   - Port search mode (`P` hotkey and CLI argument)
   - Parent process info in detail pane
   - Command line column
   - Process tree kill
   - Listen-first view
   - Flicker-free ANSI rendering
   - Background data refresh
3. Update keyboard controls table with new keys: `P`, `L`, `T` (in kill dialog)
4. Add "Port search" section under Usage
5. Add "Listen view" section under Usage
6. Update "Stopping processes" section to mention tree kill
7. Update usage example: `proctui 3000` for direct port lookup
8. Update "How it works" section to mention ANSI rendering and background runspaces

- [ ] **Step 2: Verify README renders correctly**

Read the updated README and check that all sections are consistent and accurate.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README with new features and keyboard controls"
```
