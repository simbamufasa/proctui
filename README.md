# ProcNet TUI

A terminal-based process monitor for Windows that shows **only processes with active network connections** -- their ports, remote peers, protocol states, CPU, and memory usage. Built entirely in PowerShell with no external dependencies.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Windows](https://img.shields.io/badge/platform-Windows-0078D6)
![License](https://img.shields.io/badge/license-MIT-green)

```
  [*] ProcNet TUI -- 24 network processes                    14:32:07

  PID     PROCESS              CONN  STATE          CPU(s)  MEM(MB)  CMD
  -------------------------------------------------------------------------
   1284   chrome               42    Established     312.4   1024.3  chrome.exe --type=...
   5920   node                  8    Listen           45.2    256.8  node ./src/server.js
   7344   svchost              12    Established       2.1     18.4  C:\Windows\system32\...
    892   spotify               3    Established      18.7    198.2  Spotify.exe --type=...
  =========================================================================
  >> chrome (PID 1284) -- 42 connection(s)  |  Parent: explorer (PID 5520)
     TCP 0.0.0.0:443 -> 142.250.80.46:443 (Established)
     TCP 0.0.0.0:443 -> 142.250.80.78:443 (Established)

  Up/Dn Navigate | Enter/K Stop | / Filter | P Port | L Listen | S Sort | R Refresh | A Addrs | Q Quit
```

## Features

- **Network-focused** -- Filters to processes that have TCP/UDP connections, hiding everything else
- **Live auto-refresh** -- Updates every 3 seconds with a loading spinner; background runspaces keep the UI responsive during data collection
- **Sortable columns** -- Cycle through PID, Process, Connections, State, CPU, Memory (ascending/descending)
- **Text filter** -- Press `/` to filter by process name, PID, or address
- **Port search** -- Press `P` or launch with `proctui 3000` to filter by port number
- **Listen view** -- Press `L` to toggle a view showing only processes with listening ports
- **Process control** -- Select a process and press Enter or K to stop it; choose `[Y] Process` or `[T] Tree` to also kill all children
- **Detail pane** -- Shows connection details and parent process info for the selected process
- **Command line column** -- See the full command line that started each process
- **Address popup** -- Press A to see all connections for a process in a scrollable overlay
- **Color-coded states** -- Green for Listen, Yellow for Established, Gray for other
- **Flicker-free rendering** -- Single-buffer ANSI screen updates; no screen clearing or visible redraws
- **Zero dependencies** -- Pure PowerShell, no modules or external tools required

## Requirements

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1+ (pre-installed on Windows 10+) or PowerShell 7+
- Terminal at least 80 columns x 20 rows
- **Administrator** recommended for full network visibility (non-admin will see a subset of connections)

## Installation

### Quick install (recommended)

```powershell
git clone https://github.com/simbamufasa/proctui.git
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

```
proctui
proctui 3000
```

### Keyboard Controls

| Key            | Action                                                      |
| -------------- | ----------------------------------------------------------- |
| `Up` / `Down`  | Navigate process list                                       |
| `Page Up/Dn`   | Jump 10 entries                                             |
| `Home` / `End` | Jump to first / last entry                                  |
| `Enter` / `K`  | Stop selected process -- then choose `[Y] Process` or `[T] Tree` |
| `/`            | Enter filter mode (by name, PID, or address)                |
| `P`            | Enter port search (filter by port number)                   |
| `L`            | Toggle listen-first view (show only listening processes)    |
| `S`            | Cycle sort column and direction                             |
| `R`            | Force refresh                                               |
| `A`            | Show all addresses for selected process                     |
| `Q`            | Quit                                                        |

### Filter mode

Press `/` to enter filter mode. Type a search term and press Enter to apply. The filter matches against process name, PID, and address strings. Press Escape to cancel and clear the filter.

Examples:
- `/chrome` -- show only Chrome processes
- `/443` -- show anything on port 443
- `/192.168` -- show connections to local network addresses

### Port search

Press `P` to enter port search mode. Type digits and press Enter to filter the list to processes that have a connection on that port. Press Escape to cancel and clear the port filter.

You can also launch directly into port search mode from the command line:

```
proctui 3000
```

The port filter and text filter are independent -- both can be active at the same time.

### Listen view

Press `L` to toggle listen-first view. When active, the list is restricted to processes that have at least one port in the Listening state. This is useful for quickly auditing what services are accepting inbound connections. Listen view stacks with both the text filter and the port filter.

### Sorting

Press `S` to cycle through sort columns: PID, Name, Connections, State, CPU, Memory. Each column toggles between ascending and descending before moving to the next.

### Stopping processes

Select a process with arrow keys, then press `Enter` or `K`. A red confirmation dialog will appear with two options:

- `[Y] Process` -- kill only the selected process
- `[T] Tree` -- kill the selected process **and all its children** recursively

Tree kill is useful for parent processes that spawn children (e.g. `nodemon`, shell wrappers, or build watchers) where killing only the parent would leave orphaned children running.

Press `N` or Escape to cancel. Requires appropriate permissions (admin for system processes).

## How it works

ProcNet TUI uses built-in Windows PowerShell cmdlets:

1. `Get-NetTCPConnection` -- enumerates all TCP connections
2. `Get-NetUDPEndpoint` -- enumerates all UDP endpoints
3. `Get-Process` -- retrieves process details (name, CPU, memory, command line, parent PID)

Connections are grouped by owning process ID. Data collection runs in a background PowerShell runspace so the UI stays responsive and the spinner keeps ticking during refresh. The TUI renders using single-buffer ANSI escape sequences -- the entire frame is composed in memory and written in one shot, eliminating flicker without requiring any special terminal modes.

## Troubleshooting

**"No network processes found"** -- Run as Administrator. Non-elevated sessions can only see connections owned by the current user.

**"Terminal too small"** -- Resize your terminal to at least 80x20. Windows Terminal, ConEmu, or any modern terminal emulator works best.

**Flickering** -- Use Windows Terminal instead of the legacy `conhost.exe`. Windows Terminal handles ANSI rendering much better.

**Missing columns** -- Ensure your terminal is wide enough. The CMD column shrinks dynamically but needs at least 80 columns total.

## License

MIT
