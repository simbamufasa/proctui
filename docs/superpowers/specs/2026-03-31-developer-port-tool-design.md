# ProcNet TUI: Developer-First Port Tool

**Date:** 2026-03-31
**Status:** Approved
**Motivation:** Developers frequently hit "address already in use" errors and need a fast way to find what's on a port, understand process relationships, and kill the right thing -- including zombie process trees that respawn.

## Core Use Case

Reactive: "Port 3000 is in use. What's on it? Kill it." -- needs to be fast.
Secondary: Proactive dashboard kept open in a side terminal.

## Features

### 1. Port Search Mode

**Goal:** Jump straight to a specific port instead of scrolling/filtering.

**CLI argument:**
- `proctui 3000` launches with filter pre-set to port 3000
- The install.ps1 launchers pass `%*` / `@args` through to the script

**In-app hotkey:** `P`
- Prompt appears at the bottom: `Port: _  (Enter=search, Esc=cancel)`
- Input accepts digits only
- Matches against all port numbers in a process's connections (local and remote, TCP and UDP)
- Status bar shows `Port: 3000` when active
- Press `P` with empty input to clear the port filter

**Interaction with existing filter (`/`):**
- Port filter and text filter are independent. Both can be active simultaneously.
- Text filter matches name/PID/address strings; port filter matches port numbers exactly.
- Help bar shows active filters: `Filter: chrome | Port: 3000`

**Implementation:**
- Add `$script:portFilter = ''` to state
- In `Get-NetProcesses`, after existing `filterText` logic, add port filtering: check if any connection's LocalPort or RemotePort matches `$script:portFilter`
- New function `Enter-PortMode` modeled on `Enter-FilterMode`, restricted to digit input
- Modify the script's `param()` block to accept `[string]$Port` argument; if provided, set `$script:portFilter` on startup

### 2. Parent Process Info & Command Line

**Goal:** See what spawned a process (to kill the parent, not the respawning child) and distinguish between multiple instances of the same binary.

**Data retrieval:**
- During `Get-NetProcesses`, batch-query `Get-CimInstance Win32_Process` once for all relevant PIDs
- Extract `ParentProcessId` and `CommandLine` per process
- Resolve parent PID to a process name via the same CIM data or `Get-Process`

**Table layout change:**
- Remove `PORTS` (TopAddr) column from the table
- Add `CMD` column in its place, showing the truncated command line
- New column order: `PID | PROCESS | CONN | STATE | CPU(s) | MEM(MB) | CMD`

**Detail pane change:**
- Line 1: `>> name (PID x) -- N connection(s)  |  Parent: parentName (PID y)`
- Lines 2-3: Connection details (moved from PORTS column, now with more room)
- Line 4: Overflow indicator `... +N more (press A)`

**If parent is unknown** (PID 0, or parent already exited): show `Parent: --`

**Command line truncation:** Same approach as current TopAddr -- truncate with `...` when exceeding column width.

**Performance:**
- Single `Get-CimInstance Win32_Process` call per refresh, filtered to the set of PIDs with network connections
- Results cached in a hashtable keyed by PID for O(1) lookup
- The WMI call adds ~100-200ms per refresh; acceptable given the 3-second interval

### 3. Quick-Kill by Port

**Goal:** When searching for a port, get to the kill dialog with minimal keystrokes.

**Behavior:**
- When a port filter is active and the filtered list contains exactly one process, it is auto-selected (index 0)
- Pressing `K`/`Enter` immediately shows the kill confirmation
- If multiple processes share the port, the user picks from the filtered list normally

This requires no new code beyond the port filter -- it falls out naturally from filtering + existing selection/kill behavior.

### 4. Process Tree Kill

**Goal:** Kill a process and everything it spawned, solving the respawning zombie problem (e.g., kill nodemon and all its child node processes).

**Kill confirmation dialog change:**
```
  !!  Stop 'node' (PID 8820)?  [Y] Process | [T] Tree | [N] Cancel
```

- `Y` -- kill just the selected process (existing behavior via `Stop-Process -Id $pid -Force`)
- `T` -- kill the entire process tree:
  1. Query `Get-CimInstance Win32_Process` to find all descendants recursively
  2. Build a list: selected process + all descendants
  3. Kill bottom-up (children first, then parents) to prevent orphan respawn races
  4. Status message: `Killed 'nodemon' tree (3 processes)`
- `N` -- cancel

**Tree discovery function:**
```
function Get-ProcessTree($pid) -> @(pid, child1, child2, grandchild1, ...)
```
- Uses `Get-CimInstance Win32_Process | Where ParentProcessId` recursively
- Returns flattened list, ordered leaves-first for bottom-up killing
- Cap at 50 processes as a safety limit; warn if exceeded

**Edge cases:**
- Parent already dead: tree kill still works on the selected process and its children
- Access denied on some children: report partial success, e.g., `Killed 2/3 processes in tree (1 access denied)`

### 5. Listen-First View

**Goal:** At-a-glance view of "what's listening on my ports" -- the developer's port map.

**Hotkey:** `L` toggles the view on/off.

**When active:**
- Filter to processes that have at least one TCP connection in `Listen` state
- Sort by lowest listening port number (ascending), overriding the user's current sort
- Status bar shows `View: Listeners`
- All other interactions work normally (kill, filter, search, address popup)

**Implementation:**
- Add `$script:listenView = $false` to state
- When toggled on: apply an additional filter in `Get-NetProcesses` that keeps only processes with `Listen` state connections, and override sort to order by the lowest listening port
- When toggled off: restore previous sort column/direction
- The `L` key handler toggles the flag and triggers a re-sort of cached data

**Interaction with filters:**
- Listen view stacks with text filter and port filter. All three can be active.
- Example: Listen view ON + port filter 3000 = show only processes listening on port 3000

## Help Bar Update

```
Up/Dn Navigate | Enter/K Stop | / Filter | P Port | L Listen | S Sort | R Refresh | A Addrs | Q Quit
```

With active state appended: `| Filter: chrome | Port: 3000 | View: Listeners`

## State Changes Summary

New state variables:
- `$script:portFilter = ''` -- active port filter
- `$script:listenView = $false` -- listen-only view toggle
- `$script:prevSortColumn` / `$script:prevSortAsc` -- saved sort state when listen view activates

Modified data model (per process):
- `ParentPID` -- integer, parent process ID
- `ParentName` -- string, parent process name
- `CmdLine` -- string, full command line

## Files Modified

- `proctui.ps1` -- all changes are in this single file
- `install.ps1` -- no changes needed (already passes args through)
- `README.md` -- update keyboard controls table and feature list

## Non-Goals

- No external dependencies or modules
- No file-based logging or history
- No config file -- all state is runtime-only
- No multi-tab or split-pane views
- Stays a single .ps1 file
