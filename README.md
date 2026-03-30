# ProcNet TUI

A terminal-based process monitor for Windows that shows **only processes with active network connections** -- their ports, remote peers, protocol states, CPU, and memory usage. Built entirely in PowerShell with no external dependencies.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Windows](https://img.shields.io/badge/platform-Windows-0078D6)
![License](https://img.shields.io/badge/license-MIT-green)

```
  [*] ProcNet TUI -- 24 network processes                    14:32:07

  PID     PROCESS              CONN  STATE          CPU(s)  MEM(MB)  PORTS
  -------------------------------------------------------------------------
   1284   chrome               42    Established     312.4   1024.3  LISTEN:443 | -> 142.250.80.46:443
   5920   node                  8    Listen           45.2    256.8  LISTEN:3000,3001
   7344   svchost              12    Established       2.1     18.4  LISTEN:135 | UDP:5353,5355
    892   spotify               3    Established      18.7    198.2  -> 35.186.224.45:4070
  =========================================================================
  >> chrome (PID 1284) -- 42 connection(s)
     TCP 0.0.0.0:443 -> 142.250.80.46:443 (Established)
     TCP 0.0.0.0:443 -> 142.250.80.78:443 (Established)

  Up/Dn Navigate | Enter/K Stop | / Filter | S Sort | R Refresh | A Addrs | Q Quit
```

## Features

- **Network-focused** -- Filters to processes that have TCP/UDP connections, hiding everything else
- **Live auto-refresh** -- Updates every 3 seconds with a loading spinner
- **Sortable columns** -- Cycle through PID, Process, Connections, State, CPU, Memory (ascending/descending)
- **Text filter** -- Press `/` to filter by process name, PID, or address
- **Process control** -- Select a process and press Enter or K to stop it (with confirmation)
- **Detail pane** -- Shows connection details for the selected process
- **Address popup** -- Press A to see all connections for a process in a scrollable overlay
- **Color-coded states** -- Green for Listen, Yellow for Established, Gray for other
- **Zero dependencies** -- Pure PowerShell, no modules or external tools required

## Requirements

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1+ (pre-installed on Windows 10+) or PowerShell 7+
- Terminal at least 80 columns x 20 rows
- **Administrator** recommended for full network visibility (non-admin will see a subset of connections)

## Installation

### Quick install (recommended)

```powershell
git clone https://github.com/your-username/proctui.git
cd proctui
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This will:
1. Copy `proctui.ps1` to `~\.proctui\`
2. Create a `proctui` command available system-wide (via `~\.local\bin`)
3. Add a Start Menu shortcut
4. Add the launcher directory to your user PATH

After installation, restart your terminal and run:

```
proctui
```

### Run without installing

```powershell
powershell -ExecutionPolicy Bypass -File .\proctui.ps1
```

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Removes the installed script, launchers, Start Menu shortcut, and PATH entry.

## Usage

### Keyboard Controls

| Key          | Action                                         |
| ------------ | ---------------------------------------------- |
| `Up` / `Down`| Navigate process list                          |
| `Page Up/Dn` | Jump 10 entries                                |
| `Home` / `End` | Jump to first / last entry                   |
| `Enter` / `K` | Stop selected process (with confirmation)     |
| `/`          | Enter filter mode (by name, PID, or address)   |
| `S`          | Cycle sort column and direction                |
| `R`          | Force refresh                                  |
| `A`          | Show all addresses for selected process        |
| `Q`          | Quit                                           |

### Filter mode

Press `/` to enter filter mode. Type a search term and press Enter to apply. The filter matches against process name, PID, and address strings. Press Escape to cancel and clear the filter.

Examples:
- `/chrome` -- show only Chrome processes
- `/443` -- show anything on port 443
- `/192.168` -- show connections to local network addresses

### Sorting

Press `S` to cycle through sort columns: PID, Name, Connections, State, CPU, Memory. Each column toggles between ascending and descending before moving to the next.

### Stopping processes

Select a process with arrow keys, then press `Enter` or `K`. A red confirmation dialog will appear. Press `Y` to confirm or `N` to cancel. Requires appropriate permissions (admin for system processes).

## How it works

ProcNet TUI uses built-in Windows PowerShell cmdlets:

1. `Get-NetTCPConnection` -- enumerates all TCP connections
2. `Get-NetUDPEndpoint` -- enumerates all UDP endpoints
3. `Get-Process` -- retrieves process details (name, CPU, memory)

Connections are grouped by owning process ID. The TUI renders directly to the console buffer using `[Console]::SetCursorPosition()` for flicker-free updates without screen clearing.

## Troubleshooting

**"No network processes found"** -- Run as Administrator. Non-elevated sessions can only see connections owned by the current user.

**"Terminal too small"** -- Resize your terminal to at least 80x20. Windows Terminal, ConEmu, or any modern terminal emulator works best.

**Flickering** -- Use Windows Terminal instead of the legacy `conhost.exe`. Windows Terminal handles cursor-based rendering much better.

**Missing columns** -- Ensure your terminal is wide enough. The PORTS column shrinks dynamically but needs at least 80 columns total.

## License

MIT
