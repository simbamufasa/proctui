param(
    [string]$Port = ''
)

# ================================================================
#  ProcNet TUI - Active Processes & Network Addresses
#  Run: powershell -ExecutionPolicy Bypass -File .\proctui.ps1
#  (Requires elevated/admin for full visibility)
# ================================================================

$ErrorActionPreference = 'SilentlyContinue'

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

# -- State -------------------------------------------------------
$script:selectedIndex   = 0
$script:scrollOffset    = 0
$script:sortColumn      = 'PID'
$script:sortAsc         = $true
$script:filterText      = ''
$script:confirmKill     = $false
$script:statusMsg       = ''
$script:statusTime      = [datetime]::MinValue
$script:lastRefresh     = [datetime]::MinValue
$script:refreshInterval = 3
$script:needsFullRedraw = $true

# -- Colors ------------------------------------------------------
$cHeader   = 'DarkCyan'
$cSelected = 'Black'
$cSelBg    = 'Cyan'
$cBorder   = 'DarkGray'
$cTitle    = 'White'
$cListen   = 'Green'
$cEstab    = 'Yellow'
$cOther    = 'Gray'
$cDanger   = 'Red'
$cHelp     = 'DarkYellow'
$cFilter   = 'Magenta'

# -- Gather Data -------------------------------------------------
function Get-NetProcesses {
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
            if ($states.ContainsKey($t.State)) { $states[$t.State] = $states[$t.State] + 1 } else { $states[$t.State] = 1 }
            if ($t.State -eq 'Listen') {
                $port = $t.LocalPort
                if ($listenPorts -notcontains $port) { $listenPorts += $port }
            }
            if ($t.State -eq 'Established' -and $t.RemoteAddress -and $t.RemoteAddress -ne '0.0.0.0' -and $t.RemoteAddress -ne '::') {
                $peer = "$($t.RemoteAddress):$($t.RemotePort)"
                if ($remotePeers.Count -lt 3 -and $remotePeers -notcontains $peer) { $remotePeers += $peer }
            }
        }
        $udpPorts = @()
        foreach ($u in $udpList) {
            $addrs += "UDP $($u.LocalAddress):$($u.LocalPort)"
            if ($states.ContainsKey('UDP')) { $states['UDP'] = $states['UDP'] + 1 } else { $states['UDP'] = 1 }
            $port = $u.LocalPort
            if ($udpPorts -notcontains $port) { $udpPorts += $port }
        }

        # Build a useful summary for the ADDRESS column
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

        $results += [PSCustomObject]@{
            PID         = $p
            Name        = $proc.ProcessName
            Connections = ($tcpList.Count + $udpList.Count)
            State       = $primaryState
            CPU         = [math]::Round($proc.CPU, 1)
            MemMB       = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            Addresses   = $addrs
            TopAddr     = $topAddr
        }
    }

    $prop = $script:sortColumn
    if ($script:sortAsc) {
        $results = $results | Sort-Object -Property $prop
    } else {
        $results = $results | Sort-Object -Property $prop -Descending
    }

    if ($script:filterText) {
        $ft = $script:filterText
        $results = $results | Where-Object {
            $_.Name -like "*$ft*" -or
            "$($_.PID)" -like "*$ft*" -or
            ($_.Addresses -join ' ') -like "*$ft*"
        }
    }

    return $results
}

# -- Buffered Rendering ------------------------------------------
# Write a full line at row Y, padded to screen width. No Clear needed.
function Write-Line([int]$y, [string]$text, $fg = 'Gray', $bg = $null) {
    $w = [Console]::WindowWidth
    if ($y -lt 0 -or $y -ge [Console]::BufferHeight) { return }
    $padded = $text
    if ($padded.Length -lt $w) { $padded = $padded + (' ' * ($w - $padded.Length)) }
    elseif ($padded.Length -gt $w) { $padded = $padded.Substring(0, $w) }
    [Console]::SetCursorPosition(0, $y)
    if ($bg) { Write-Host $padded -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
    else     { Write-Host $padded -ForegroundColor $fg -NoNewline }
}

# Write colored segment at specific position (for state column overlay)
function Write-Seg([int]$x, [int]$y, [string]$text, $fg = 'Gray') {
    if ($y -lt 0 -or $y -ge [Console]::BufferHeight) { return }
    if ($x -lt 0) { $x = 0 }
    [Console]::SetCursorPosition($x, $y)
    Write-Host $text -ForegroundColor $fg -NoNewline
}

function Pad([string]$s, [int]$len) {
    if ($s.Length -ge $len) { return $s.Substring(0, $len) }
    return $s.PadRight($len)
}

function PadNum($val, [int]$len) {
    $s = "$val"
    if ($s.Length -ge $len) { return $s.Substring(0, $len) }
    return $s.PadLeft($len)
}

# -- Main Draw ---------------------------------------------------
function Draw-Screen($data) {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight

    [Console]::CursorVisible = $false

    $count = 0
    if ($data) { $count = $data.Count }

    # -- Row 0: Title Bar --
    $title = "  [*] ProcNet TUI -- $count network processes "
    $ts    = " $(Get-Date -Format 'HH:mm:ss') "
    $gap   = $w - $title.Length - $ts.Length
    if ($gap -lt 0) { $gap = 0 }
    Write-Line 0 "$title$(' ' * $gap)$ts" $cTitle 'DarkCyan'

    # -- Row 1: blank spacer --
    Write-Line 1 '' $cBorder

    # -- Row 2: Column Headers --
    $sortInd = if ($script:sortAsc) { '^' } else { 'v' }
    $addrW = $w - 8 - 20 - 6 - 14 - 9 - 10 - 2
    if ($addrW -lt 10) { $addrW = 10 }
    $cols = @(
        @{ Name='PID';     W=8;  Key='PID' },
        @{ Name='PROCESS'; W=20; Key='Name' },
        @{ Name='CONN';    W=6;  Key='Connections' },
        @{ Name='STATE';   W=14; Key='State' },
        @{ Name='CPU(s)';  W=9;  Key='CPU' },
        @{ Name='MEM(MB)'; W=10; Key='MemMB' },
        @{ Name='PORTS';   W=$addrW; Key='TopAddr' }
    )

    $headerLine = ''
    foreach ($c in $cols) {
        $label = if ($c.Key -eq $script:sortColumn) { "$($c.Name)$sortInd" } else { $c.Name }
        $headerLine += Pad " $label" $c.W
    }
    Write-Line 2 $headerLine 'White' 'DarkBlue'

    # -- Row 3: separator --
    Write-Line 3 ('-' * $w) $cBorder

    # -- Rows 4..(h-6): Table Body --
    $bodyStart = 4
    $bodyEnd   = $h - 6
    $maxRows   = $bodyEnd - $bodyStart
    if ($maxRows -lt 1) { $maxRows = 1 }

    if ($count -eq 0) {
        Write-Line ($bodyStart) "  No network processes found. Try running as Administrator."  'DarkYellow'
        for ($r = $bodyStart + 1; $r -lt $bodyEnd; $r++) { Write-Line $r '' }
    } else {
        # Clamp
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
            $row = $bodyStart + $i

            if ($dataIdx -ge $count) {
                Write-Line $row ''
                continue
            }

            $item = $data[$dataIdx]
            $isSelected = ($dataIdx -eq $script:selectedIndex)

            $addr = $item.TopAddr
            if ($addr.Length -gt ($addrW - 2)) {
                $addr = $addr.Substring(0, $addrW - 4) + '...'
            }

            $line = (PadNum $item.PID 7) + ' ' +
                    (Pad $item.Name 20) +
                    (PadNum $item.Connections 5) + ' ' +
                    (Pad $item.State 14) +
                    (PadNum $item.CPU 8) + ' ' +
                    (PadNum $item.MemMB 9) + ' ' +
                    (Pad $addr $addrW)

            if ($isSelected) {
                Write-Line $row $line $cSelected $cSelBg
            } else {
                Write-Line $row $line 'Gray'
                # Overlay state with color
                $stateColor = switch ($item.State) {
                    'Established' { $cEstab }
                    'Listen'      { $cListen }
                    default       { $cOther }
                }
                $statePos = 8 + 20 + 6
                Write-Seg $statePos $row (Pad $item.State 14) $stateColor
                # Overlay address with color: green for LISTEN ports, yellow for remotes
                $addrPos = 8 + 20 + 6 + 14 + 9 + 10
                if ($addr -match 'LISTEN:') {
                    Write-Seg $addrPos $row (Pad $addr $addrW) $cListen
                } elseif ($addr -match '->') {
                    Write-Seg $addrPos $row (Pad $addr $addrW) $cEstab
                }
            }
        }
    }

    # -- Detail Pane --
    $detailY = $bodyEnd
    Write-Line $detailY ('=' * $w) $cBorder

    $sel = if ($count -gt 0) { $data[$script:selectedIndex] } else { $null }

    if ($sel) {
        Write-Line ($detailY + 1) " >> $($sel.Name) (PID $($sel.PID)) -- $($sel.Connections) connection(s)" 'White'

        $addrLines = @($sel.Addresses | Select-Object -First 2)
        for ($a = 0; $a -lt 2; $a++) {
            if ($a -lt $addrLines.Count) {
                $aColor = if ($addrLines[$a] -match 'Established') { $cEstab }
                          elseif ($addrLines[$a] -match 'Listen') { $cListen }
                          else { $cOther }
                Write-Line ($detailY + 2 + $a) "   $($addrLines[$a])" $aColor
            } else {
                Write-Line ($detailY + 2 + $a) ''
            }
        }
        if ($sel.Addresses.Count -gt 2) {
            Write-Line ($detailY + 4) "   ... +$($sel.Addresses.Count - 2) more (press A)" $cBorder
        } else {
            Write-Line ($detailY + 4) ''
        }
    } else {
        for ($r = $detailY + 1; $r -le $detailY + 4; $r++) { Write-Line $r '' }
    }

    # -- Status line --
    $statusY = $h - 2
    if ($script:statusMsg -and ([datetime]::Now - $script:statusTime).TotalSeconds -lt 4) {
        $statusColor = if ($script:statusMsg -match 'Killed|Stopped') { $cDanger } else { $cHelp }
        Write-Line $statusY "  $($script:statusMsg)" $statusColor
    } else {
        Write-Line $statusY ''
    }

    # -- Confirm Kill overlay --
    if ($script:confirmKill -and $sel) {
        $cy = [math]::Floor($h / 2) - 1
        $box = "  !!  Stop '$($sel.Name)' (PID $($sel.PID))?  [Y]es / [N]o  "
        $bpad = [math]::Max(0, [math]::Floor(($w - $box.Length - 2) / 2))
        $blank = ' ' * ($box.Length + 2)
        [Console]::SetCursorPosition($bpad, $cy)
        Write-Host $blank -ForegroundColor White -BackgroundColor DarkRed -NoNewline
        [Console]::SetCursorPosition($bpad, $cy + 1)
        Write-Host " $box " -ForegroundColor White -BackgroundColor DarkRed -NoNewline
        [Console]::SetCursorPosition($bpad, $cy + 2)
        Write-Host $blank -ForegroundColor White -BackgroundColor DarkRed -NoNewline
    }

    # -- Help Bar (last row) --
    $filterLabel = if ($script:filterText) { " | Filter: $($script:filterText)" } else { '' }
    $help = " Up/Dn Navigate | Enter/K Stop | / Filter | S Sort | R Refresh | A Addrs | Q Quit$filterLabel"
    Write-Line ($h - 1) $help $cTitle 'DarkBlue'
}

# -- Show All Addresses Popup -----------------------------------
function Show-Addresses($item) {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight

    $boxW = [math]::Min($w - 6, 90)
    $addrCount = $item.Addresses.Count
    $boxH = [math]::Min($h - 6, $addrCount + 4)
    if ($boxH -lt 5) { $boxH = 5 }
    $x0 = [math]::Floor(($w - $boxW) / 2)
    $y0 = [math]::Floor(($h - $boxH) / 2)

    # Build box lines and write over existing content
    $topLine = "+" + ('-' * ($boxW - 2)) + "+"
    $emptyLine = "|" + (' ' * ($boxW - 2)) + "|"
    $botLine = "+" + ('-' * ($boxW - 2)) + "+"

    [Console]::SetCursorPosition($x0, $y0)
    Write-Host $topLine -ForegroundColor $cBorder -NoNewline
    for ($i = 1; $i -lt $boxH - 1; $i++) {
        [Console]::SetCursorPosition($x0, $y0 + $i)
        Write-Host $emptyLine -ForegroundColor $cBorder -NoNewline
    }
    [Console]::SetCursorPosition($x0, $y0 + $boxH - 1)
    Write-Host $botLine -ForegroundColor $cBorder -NoNewline

    # Title
    $title = " $($item.Name) (PID $($item.PID)) -- All Addresses "
    [Console]::SetCursorPosition($x0 + 2, $y0)
    Write-Host $title -ForegroundColor White -NoNewline

    # Addresses
    $maxShow = $boxH - 4
    $shown = [math]::Min($addrCount, $maxShow)
    for ($i = 0; $i -lt $shown; $i++) {
        $addr = $item.Addresses[$i]
        $aColor = if ($addr -match 'Established') { $cEstab }
                  elseif ($addr -match 'Listen') { $cListen }
                  else { $cOther }
        $maxLen = $boxW - 6
        $display = if ($addr.Length -gt $maxLen) { $addr.Substring(0, $maxLen - 3) + '...' } else { $addr }
        [Console]::SetCursorPosition($x0 + 2, $y0 + 2 + $i)
        Write-Host (Pad $display ($boxW - 4)) -ForegroundColor $aColor -NoNewline
    }
    if ($addrCount -gt $maxShow) {
        [Console]::SetCursorPosition($x0 + 2, $y0 + 2 + $maxShow)
        Write-Host "... +$($addrCount - $maxShow) more" -ForegroundColor $cBorder -NoNewline
    }

    [Console]::SetCursorPosition($x0 + 2, $y0 + $boxH - 2)
    Write-Host "Press any key to close" -ForegroundColor $cHelp -NoNewline

    [Console]::ReadKey($true) | Out-Null
    $script:needsFullRedraw = $true
}

# -- Filter Input ------------------------------------------------
function Enter-FilterMode {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight

    Write-Line ($h - 1) " Filter: $($script:filterText)_  (Enter=apply, Esc=cancel)" $cFilter 'Black'
    [Console]::CursorVisible = $true

    while ($true) {
        $key = [Console]::ReadKey($true)

        if ($key.Key -eq 'Enter') { break }
        elseif ($key.Key -eq 'Escape') {
            $script:filterText = ''
            break
        }
        elseif ($key.Key -eq 'Backspace') {
            if ($script:filterText.Length -gt 0) {
                $script:filterText = $script:filterText.Substring(0, $script:filterText.Length - 1)
            }
        }
        else {
            if ($key.KeyChar -match '[\w\.\:\*]') {
                $script:filterText += $key.KeyChar
            }
        }

        Write-Line ($h - 1) " Filter: $($script:filterText)_  (Enter=apply, Esc=cancel)" $cFilter 'Black'
    }

    [Console]::CursorVisible = $false
    $script:selectedIndex = 0
    $script:scrollOffset = 0
}

# -- Cycle Sort --------------------------------------------------
function Cycle-Sort {
    $columns = @('PID', 'Name', 'Connections', 'State', 'CPU', 'MemMB')
    $idx = [array]::IndexOf($columns, $script:sortColumn)

    if ($idx -ge $columns.Count - 1) {
        $script:sortColumn = $columns[0]
        $script:sortAsc = $true
    } else {
        if (-not $script:sortAsc) {
            $script:sortColumn = $columns[$idx + 1]
            $script:sortAsc = $true
        } else {
            $script:sortAsc = $false
        }
    }

    $dir = if ($script:sortAsc) { 'ASC' } else { 'DESC' }
    $script:statusMsg  = "Sort: $($script:sortColumn) $dir"
    $script:statusTime = [datetime]::Now
}

# -- Loading Indicator -------------------------------------------
$script:spinnerFrames = @('|', '/', '-', '\')
$script:spinnerIdx    = 0

function Show-Loading([string]$msg = 'Scanning network...') {
    $h = [Console]::WindowHeight
    $w = [Console]::WindowWidth
    $statusY = $h - 2
    $frame = $script:spinnerFrames[$script:spinnerIdx % $script:spinnerFrames.Count]
    $script:spinnerIdx++
    $text = "  $frame $msg"
    if ($statusY -ge 0 -and $statusY -lt [Console]::BufferHeight) {
        $padded = $text
        if ($padded.Length -lt $w) { $padded = $padded + (' ' * ($w - $padded.Length)) }
        elseif ($padded.Length -gt $w) { $padded = $padded.Substring(0, $w) }
        [Console]::SetCursorPosition(0, $statusY)
        Write-Host $padded -ForegroundColor Cyan -NoNewline
    }
}

function Refresh-Data {
    Show-Loading 'Scanning network connections...'
    $result = @(Get-NetProcesses)
    $script:lastRefresh = [datetime]::Now
    return $result
}

# -- Re-sort cached data without re-fetching --------------------
function Sort-CachedData($dataIn) {
    $prop = $script:sortColumn
    if ($script:sortAsc) {
        $out = $dataIn | Sort-Object -Property $prop
    } else {
        $out = $dataIn | Sort-Object -Property $prop -Descending
    }
    return @($out)
}

# -- Main Loop ---------------------------------------------------
try {
    $bw = [Console]::WindowWidth
    $bh = [Console]::WindowHeight
    if ($bw -lt 80 -or $bh -lt 20) {
        Write-Host "Terminal too small. Need at least 80x20, got ${bw}x${bh}." -ForegroundColor Red
        return
    }
    try { [Console]::BufferWidth = $bw } catch {}

    [Console]::CursorVisible = $false
    [Console]::Clear()  # one-time clear at startup

    Show-Loading 'Starting up...'
    $data = Refresh-Data

    while ($true) {
        # Auto-refresh data
        if (([datetime]::Now - $script:lastRefresh).TotalSeconds -ge $script:refreshInterval) {
            Show-Loading 'Auto-refreshing...'
            $data = Refresh-Data
        }

        Draw-Screen $data

        # Poll for input - tight loop for responsiveness
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            if (-not [Console]::KeyAvailable) { continue }
        }

        $key = [Console]::ReadKey($true)

        # Drain buffered keys for rapid navigation
        while ([Console]::KeyAvailable -and ($key.Key -eq 'UpArrow' -or $key.Key -eq 'DownArrow')) {
            $key = [Console]::ReadKey($true)
        }

        # -- Confirm Kill --
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
            $script:confirmKill = $false
            continue
        }

        # -- Keys --
        switch ($key.Key) {
            'UpArrow'   { $script:selectedIndex = [math]::Max(0, $script:selectedIndex - 1) }
            'DownArrow' { $script:selectedIndex = [math]::Min($data.Count - 1, $script:selectedIndex + 1) }
            'PageUp'    { $script:selectedIndex = [math]::Max(0, $script:selectedIndex - 10) }
            'PageDown'  { $script:selectedIndex = [math]::Min($data.Count - 1, $script:selectedIndex + 10) }
            'Home'      { $script:selectedIndex = 0 }
            'End'       { $script:selectedIndex = $data.Count - 1 }
            'Enter'     { if ($data.Count -gt 0) { $script:confirmKill = $true } }
            default {
                switch ($key.KeyChar) {
                    'k' { if ($data.Count -gt 0) { $script:confirmKill = $true } }
                    'K' { if ($data.Count -gt 0) { $script:confirmKill = $true } }
                    '/' { Enter-FilterMode; $data = Refresh-Data }
                    's' { Cycle-Sort; $data = Sort-CachedData $data }
                    'S' { Cycle-Sort; $data = Sort-CachedData $data }
                    'r' { $data = Refresh-Data
                          $script:statusMsg = "~ Refreshed"; $script:statusTime = [datetime]::Now }
                    'R' { $data = Refresh-Data
                          $script:statusMsg = "~ Refreshed"; $script:statusTime = [datetime]::Now }
                    'a' { if ($data.Count -gt 0) { Show-Addresses $data[$script:selectedIndex] } }
                    'A' { if ($data.Count -gt 0) { Show-Addresses $data[$script:selectedIndex] } }
                    'q' { return }
                    'Q' { return }
                }
            }
        }
    }
}
catch {
    [Console]::CursorVisible = $true
    [Console]::ResetColor()
    Clear-Host
    Write-Host "ProcNet TUI crashed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    [Console]::CursorVisible = $true
    [Console]::ResetColor()
}