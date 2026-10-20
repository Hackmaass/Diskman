# Space Analyzer Phase 1 + Audit Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Account for every byte on C:, say what each big folder is and what to do, and fix the P1/P2 findings from the Impeccable audit.

**Architecture:** One compiled C# tree walker (`Diskman.TreeScan`) builds a directory-size tree in one parallel pass. PowerShell modules turn the tree into accounting rows, categories and rule-based insights. The WPF UI gets an Overview tab and a Space Explorer tab fed from the in-memory tree. Two background job slots (action, scan) share one UI timer; a static cancel flag stops walkers.

**Tech Stack:** PowerShell 5.1 + WPF/XAML, inline C# via `Add-Type`, existing `test_verify.ps1` harness. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-20-space-analyzer-phase1-design.md`

## Global Constraints

- Zero external dependencies; PowerShell 5.1 and 7+; single-file release built by `Compile.ps1` (LF, UTF-8 no BOM, SHA-256 file).
- Deletes only through `Test-PathSafety` (bulk gate). `Review` verdict never has a delete action. `Claude-Data` is never offered for deletion.
- Admin commands come from a fixed allow-list in code, with consent text naming side effects. Nothing runs without a confirmation click; destructive confirmations default to **No**.
- Safety words are exactly: Safe, Optional, Advanced, Review. One product name: `Diskman`; tagline `C: drive space cleaner`.
- Contrast 4.5:1 or better for text; every state also has text; layout valid at 950x700 and 1140x800.
- Cloud placeholder files (`Offline`, `RecallOnOpen`, `RecallOnDataAccess`) and reparse points are never counted or followed.

## Review Focus

- Drive with almost no free space: scan and UI must still work (no large temp writes by the app). Test: tree scan writes nothing.
- Folder names with spaces, brackets or unicode: rules match by exact path, never by pattern. Test: bracket-named sandbox folder.
- Access-denied folders: counted in `Errors`, never abort. Test: scan includes a locked directory and finishes.
- `used - scanned` negative (hard links): shown as `Windows shared files (counted once)`, rows still sum to used. Test: pure function with negative remainder.
- Cancel during scan: returns partial tree, flag resets for the next scan. Test: cancel immediately, then scan again.

---

### Task 1: Tree walker and accounting (`src/modules/Scan-DriveTree.ps1`)

**Files:** Create `src/modules/Scan-DriveTree.ps1`; Modify `test_verify.ps1`.

**Interfaces:**
- Produces C# `Diskman.Node { string Path, Name; long Bytes, OwnBytes, Files; long ModifiedTicks; bool Shared; List<Node> Children }` with the invariant `Bytes = OwnBytes + sum(Children.Bytes)`.
- Produces C# `Diskman.TreeScan`: `static Node Scan(string root)`, `static volatile bool Cancel`, `static long ScannedFiles, ScannedBytes, Errors`, `static string Current`, `static ConcurrentDictionary<string,long> Partial` (depth-1 totals as each finishes), `static void Reset()`.
- Produces `Get-SpaceAccounting -Root <Node> -UsedBytes <long> -Elevated <bool> : object[]` rows `{ Name; Path; Bytes; Percent; Kind('Folder'|'Protected'|'Shared'|'Unreadable'); Node }` summing to `UsedBytes`.
- Produces `Get-SpaceCategory -Root <Node> : hashtable` category name -> bytes for: `Apps and games`, `Developer tools`, `Windows and system`, `Your files`, `Caches and temp`, `Other`.

- [ ] Test `TreeScan sandbox totals`: sandbox with files, nested dirs, a junction to an outside dir, a bracket-named dir; assert `root.Bytes` equals independent file-size sum, junction content absent, invariant holds for every node.
- [ ] Test `small items roll-up`: 200 tiny dirs under one parent; assert parent `OwnBytes` includes them and `Children.Count` is small, totals unchanged.
- [ ] Test `cancel`: set `Cancel`, scan returns, `Reset()` then scan completes with full totals.
- [ ] Test `accounting`: positive remainder gives a `Protected` row (`Unreadable` if not elevated and 0 errors is false); negative gives a `Shared` row; rows sum to `UsedBytes` in both.
- [ ] Implement walker: recursive, depth 0-2 children via `Parallel.ForEach` (DOP 8), prune children under 1 MB into parent `OwnBytes`, skip reparse points and placeholder files, `Shared=true` for `...\Windows\WinSxS`, catch access errors into `Errors`.
- [ ] Implement `Get-SpaceAccounting` and `Get-SpaceCategory` (longest-prefix category rules, children inherit parent category).
- [ ] Run `test_verify.ps1`; commit.

### Task 2: System space, rules, allowed commands (`Get-SystemSpace.ps1`, `Get-SpaceRules.ps1`)

**Files:** Create both modules; Modify `test_verify.ps1`.

**Interfaces:**
- Produces `Get-SystemSpace : object[]` rows `{ Name; Bytes (nullable); Note; NeedsAdmin }` for swapfile, pagefile (drive, size), hibernation, shadow copies, WinSxS note, Windows.old, `$WinREAgent`, `$Windows.~BT`.
- Produces `Get-SpaceRules : hashtable[]` fields `Path, Title, What, Verdict ('Clean'|'Command'|'Uninstall'|'Review'|'System'), Safety, TargetId, CommandId, RequiresAdmin`; `Find-SpaceRule -Path <string> : hashtable|$null` (exact, case-insensitive match).
- Produces `Get-AllowedCommands : hashtable` id -> `{ Exe; Args; Title; Consent; RequiresAdmin }` for `DockerPrune`, `ComponentCleanup`, `HibernateOff`, `ShadowDelete`; `Invoke-AllowedCommand -Id <ValidateSet> -OnLine <scriptblock> : int` (exit code).

- [ ] Test `rules`: every `Clean` rule's path passes `Test-PathSafety`; `Claude-Data` has verdict `Review`; no rule path is a ProgramData/AppData parent; unknown path returns `$null`; bracketed path matches only exactly.
- [ ] Test `commands`: exact strings for the four allow-listed commands; `Consent` of `HibernateOff` mentions Fast Startup, of `ShadowDelete` mentions restore points; `Invoke-AllowedCommand` rejects an unknown id.
- [ ] Implement: auto-generate `Clean` rules from `Get-CleanableTargets`; hand-written `Command`, `Uninstall`, `Review`, `System` rules from the evidence table in the spec (RTX Remix, DockerDesktop, esp32, NVIDIA App UpdateFramework, NGX models, Claude-Data, Python local-packages, hermes-agent, npm node_modules, WinSxS, System32, Installer).
- [ ] Run tests; commit.

### Task 3: Job slots, cancel, audit log, safer confirms (`src/app.ps1`)

**Files:** Modify `src/app.ps1`, `src/modules/00-Utils.ps1` (cancel hook), `Compile.ps1` unchanged.

**Interfaces:**
- Produces `Confirm-Action -Message <string> -Title <string> -Icon <string> : bool` (default button No).
- Produces `Write-AuditLog -Message <string>` appending to `%LOCALAPPDATA%\Diskman\logs\diskman-yyyyMMdd.log`; `Log-Console` calls it.
- Produces `Start-BackgroundJob -Slot ('action'|'scan')` and `Stop-BackgroundJob -Slot`; static `Diskman.TreeScan.Cancel` is set on stop.

- [ ] Test (wiring): `app.ps1` contains no `MessageBoxButton]::YesNo` outside `Confirm-Action`; `Write-AuditLog` creates a file with the line; admin-only row checkboxes are disabled when not elevated (pure function test of the row IsEnabled flag).
- [ ] Implement two slots sharing one timer; `action` slot drives `Set-Busy`; `scan` slot only disables the scan buttons and shows Cancel.
- [ ] Implement `Confirm-Action` and replace all 7 YesNo dialogs; add `Write-AuditLog` for every deletion line and command run.
- [ ] Run tests; commit.

### Task 4: Overview and Space Explorer UI (`MainWindow.xaml`, `app.ps1`)

**Files:** Modify `src/xaml/MainWindow.xaml`, `src/app.ps1`; delete `src/modules/Start-FolderScan.ps1` (replaced), update `$workerFunctions`, `test_verify.ps1`, `Compile.ps1` needs no change.

**Interfaces:**
- Consumes Tasks 1-3 functions above.
- Produces tabs in order: `Overview`, `Cleaner`, `Space Explorer`, `Large Files`, `File Inspector`. New control names: `TxtOverviewVerdict, TxtOverviewSub, PanelScan, TxtScanProgress, BtnCancelScan, BarCategories, PanelLegend, GridTopFolders, PanelActions, BtnFreeSafely, PanelSystemSpace, PanelCrumbs, GridSpace, TxtSpaceSelected, BtnSpaceOpen, BtnSpaceCopy, BtnSpaceAction, BtnRestartAdmin`.

- [ ] Test (wiring): all `Find-Control` names exist in XAML; empty-state text exists for each grid.
- [ ] Implement scan startup chain: cleaner scan (action slot) and tree scan (scan slot) both start on open; progress block reads `TreeScan` statics; Overview renders top-level partials, then full results.
- [ ] Implement Overview: verdict (`Critically low` below 2 GB or 5% free, `Low` below 10%), stacked category bar + legend, top 12 folders with insight badge, ranked action cards, `Free X GB safely` (Safe-tier cleaner items, one confirm), collapsible system space.
- [ ] Implement Space Explorer: breadcrumb buttons, grid with size bar, drill on Enter/double-click, Backspace up, action bar (Open in Explorer, Copy path, rule action: Clean -> existing cleanup flow, Command -> consent then `Invoke-AllowedCommand` in action slot, Uninstall -> `ms-settings:appsfeatures`, Review -> Explorer).
- [ ] Implement `Restart as Administrator` (file path when present; otherwise write the running script text to temp and elevate it); banner when not elevated.
- [ ] Apply audit fixes: product name and copy, empty states, contrast (`#A1A1AA` status text, darker Advanced badge text colour), tokens extracted for repeated colours, tooltips and `AutomationProperties.Name` on interactive controls.
- [ ] Run GUI smoke harness; screenshots at 950x700 and 1140x800; read them; fix layout.
- [ ] Commit.

### Task 5: Verification on the user's drive, docs, release

**Files:** Modify `README.md`, `SECURITY.md`, `CONTRIBUTING.md`; rebuild `release/`.

- [ ] Run the spec success test on this machine: accounted-for share, unreadable/protected row, top-15 insight coverage; record numbers in the README section.
- [ ] Update README (screens, Overview, honest limits, admin) and CONTRIBUTING (rules table schema, command allow-list).
- [ ] Run `test_verify.ps1`, compile release, run release through `iex` smoke harness.
- [ ] Final advisor review; leave changes uncommitted unless asked.
