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

## Rendering & Responsiveness Improvements

These changes should be implemented before the features above, as they establish the rendering foundation everything else builds on.

### 6. StringBuilder Buffered Rendering

**Problem:** The current `Draw-Screen` makes ~90+ individual `Write-Host` calls per frame (2-3 per row for line + color overlays). Each call flushes to the console, causing visible micro-flicker.

**Solution:** Build the entire frame as a single string using `[System.Text.StringBuilder]`, then write it in one `[Console]::Out.Write()` call.

**Implementation:**
- Replace all `Write-Host` calls in `Draw-Screen` with appends to a `StringBuilder`
- Use ANSI escape sequences (`$([char]27)[38;5;...m`) for colors instead of `Write-Host -ForegroundColor`. This is required because `Write-Host` can't write to a buffer -- it goes directly to the console host.
- Windows Terminal and modern PowerShell 5.1+ on Windows 10+ support ANSI escapes natively
- At the end of `Draw-Screen`, position cursor at 0,0 and write the entire buffer in one call
- Keep the `Write-Host` path as a fallback check: detect ANSI support via `$env:WT_SESSION` or `$PSVersionTable` and fall back to current rendering if ANSI is not supported (legacy conhost)

**ANSI color map:**
- Map existing `$cHeader`, `$cSelected`, etc. variables to ANSI escape codes
- Define a helper: `function Ansi($fg, $bg)` that returns the escape sequence for a given color pair
- `$cReset = "$([char]27)[0m"` to reset after each colored segment

**Expected impact:** Eliminates flicker entirely. Single write per frame means the console never shows a partially-drawn state.

### 7. Dirty Tracking (Skip Unnecessary Redraws)

**Problem:** The main loop redraws the entire screen every 50ms iteration, even when nothing has changed -- no key pressed, no auto-refresh triggered.

**Solution:** Track a `$script:dirty` flag. Only call `Draw-Screen` when something actually changed.

**What sets dirty to `$true`:**
- Any keypress (navigation, sort, filter, etc.)
- Auto-refresh completing (new data loaded)
- Window resize detected
- Status message appearing or expiring

**What keeps dirty `$false`:**
- Idle loop iterations with no input and no refresh due

**Implementation:**
- Add `$script:dirty = $true` to state (start dirty for initial draw)
- At the top of the main loop: `if (-not $script:dirty) { Start-Sleep -Milliseconds 50; continue }` (after checking for input)
- Each key handler and data refresh sets `$script:dirty = $true`
- `Draw-Screen` sets `$script:dirty = $false` after completing
- Check `[Console]::WindowWidth/Height` each iteration; if changed from last frame, set dirty

**Expected impact:** Reduces CPU usage from constant redrawing to event-driven rendering. The 50ms poll remains for input detection but skips the expensive draw path.

### 8. Background Data Fetch

**Problem:** `Get-NetProcesses` takes 200-500ms (WMI + network cmdlets). During this time, the UI is completely frozen -- no navigation, no key response.

**Solution:** Run data collection in a background PowerShell runspace. The main thread stays responsive for input while data loads.

**Implementation:**
- Create a persistent runspace at startup via `[runspacefactory]::CreateRunspace()`
- When a refresh is due, dispatch `Get-NetProcesses` logic to the runspace via `[PowerShell]::Create().AddScript(...).BeginInvoke()`
- Main loop continues processing input and rendering the previous data set
- Each loop iteration checks `$asyncResult.IsCompleted`; when true, swap in the new data and set dirty
- Show a non-blocking spinner in the status bar: `~ Refreshing...` (replaces the current blocking `Show-Loading`)

**Runspace lifecycle:**
- Created once at startup, reused for all refreshes
- The scriptblock passed to the runspace contains the data-fetching logic (network cmdlets + WMI)
- Only one background fetch runs at a time; if a fetch is already in progress, skip scheduling a new one
- On exit (`Q`), dispose the runspace cleanly in the `finally` block

**Data handoff:**
- The runspace returns an array of `[PSCustomObject]` -- same shape as current `Get-NetProcesses` output
- Main thread receives it via `EndInvoke()`, applies current sort/filter, and sets dirty

**Expected impact:** Navigation stays responsive at all times. The 200-500ms freeze is eliminated. User perceives instant key response even during data refresh.

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
- `$script:dirty = $true` -- whether the screen needs redrawing
- `$script:lastWidth` / `$script:lastHeight` -- previous console dimensions for resize detection
- `$script:runspace` -- persistent background runspace for data fetching
- `$script:asyncResult` -- handle for in-flight background fetch
- `$script:ansiSupported` -- whether to use ANSI rendering or Write-Host fallback

Modified data model (per process):
- `ParentPID` -- integer, parent process ID
- `ParentName` -- string, parent process name
- `CmdLine` -- string, full command line

## Implementation Order

1. Rendering improvements (6, 7, 8) -- foundation for everything else
2. Data model changes (2: parent/cmdline) -- needed by tree kill
3. Features (1, 3, 4, 5) -- can be built incrementally on top
4. README update

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
