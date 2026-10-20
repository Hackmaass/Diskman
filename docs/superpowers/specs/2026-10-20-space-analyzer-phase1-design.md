# Diskman Phase 1: Space Analyzer, System-Space View, Guided Actions

Date: 2026-10-20. Status: draft for review. Scope: Phase 1 of 3 (see "Phases").

## 1. Intent

**Said by the user:** C: is full and Diskman does not help much. Make it the most effective C: cleaning tool that detects everything. Focus on UI/UX too.

**Measured on the user's machine (read-only, non-admin session):**

| Fact | Value |
| :-- | :-- |
| Drive | 220.4 GB, about 219 GB used, 0.76 GB free and still falling |
| What the Cleaner explains today | about 13 GB (6%) |
| `C:\Users` | 109.5 GB (`AppData` 94.8 GB) |
| `C:\Windows` | 42.1 GB (`WinSxS` 17.9, `SoftwareDistribution` 5.0) |
| `Program Files` + `(x86)` | 32.9 GB (`NVIDIA Corporation` 11.4, of which `RTX Remix` 10.0) |
| `ProgramData` | 17.4 GB (`NVIDIA Corporation\NVIDIA App\UpdateFramework` 8.4, `NVIDIA\NGX\models` 4.0, `NVIDIA\Streamline` 3.9) |
| Biggest `AppData\Local` items | Docker 16.4 (`docker_data.vhdx` 16.3), `Claude-Data` 10.6, Packages 8.9 (Store Python `local-packages` 5.5, Spotify 1.9), Programs 7.2, Temp 6.9, Arduino15 6.6 (`esp32` 6.3), Python 5.3, hermes 4.4 |
| Not on C: | pagefile is on `D:`; hibernation is off; `swapfile.sys` is 256 MB |
| Unreadable without admin | about 16 GB gap, probably `System Volume Information` (shadow copies) |

**Conclusion:** the gap is not missing cache paths. It is large folders nobody has classified plus admin-only system space. Phase 1 therefore accounts for the space first and attaches an honest action to each big item second.

**Assumptions (correct me):** the owner is a developer using Windows 11 with WSL/Docker; one drive (C:) matters; the app stays PowerShell + WPF with zero external dependencies; the existing dark theme is kept (refinement, not redesign).

## 2. Success test (run on the user's machine)

After one scan:
1. Every byte of used space is shown in exactly one row. Rows are measured folders or one of three labelled remainders: `Protected areas (needs administrator)`, `Windows shared files (counted once)`, `Unreadable`. By construction the rows sum to "used".
2. Elevated, the unexplained remainder is at most 5% of used space. Non-elevated, it may be larger but is labelled with its cause and a "Restart as Administrator" button.
3. At least 10 of the 15 biggest folders on this machine show an insight (what it is, what to do). The remainder show "Review", never "Delete".
4. The first useful result (top folders) appears while the scan is still running.

## 3. Phases

1. **Phase 1 (this spec):** accounting scan, Overview screen, Space Explorer, System-space panel, Restart as Administrator, rules table with verified actions.
2. **Phase 2:** stale developer folders (`node_modules`, `.venv`, `target`, `build` older than N days), Docker and WSL disk compaction.
3. **Phase 3:** duplicate-file finder.

## 4. Architecture

### 4.1 Scan engine (`src/modules/Scan-DriveTree.ps1` plus a compiled C# type)

- One pass. A C# type `Diskman.TreeScan` walks C: and returns a tree of directories only: path, total bytes, own-file bytes, file count, newest modified time, children. Files are never stored.
- To bound memory, a directory keeps children of at least 1 MB; the rest roll into one `(small items)` child.
- Skips: reparse points (junctions, symlinks), and files whose attributes include `Offline`, `RecallOnDataAccess` or `RecallOnOpen` (cloud placeholders report full length but use no disk).
- Top-level files of `C:\` are enumerated with `DirectoryInfo`, so `swapfile.sys` and similar show up.
- Windows: walked like any folder, but `C:\Windows\WinSxS` is marked `SharedFiles` (hard-linked with System32, so its file-size sum overstates real use). It is never shown as reclaimable. See 4.3.
- Progress: a shared object with `Files`, `Bytes`, `CurrentTopFolder`, `Errors` fields, read by the UI timer; a cancel flag. Partial top-level totals are published about once per second so the Overview can render before the scan ends.
- Runs in the existing background-runspace machinery (`Start-BackgroundJob`), with its busy gate, plus a Cancel button.
- Parallelism: first measure one single-threaded full pass on the user's drive and record it in the plan. Add a parallel walk only if that pass is too slow (target: usable in about 2 minutes warm).

### 4.2 Insight rules (`src/modules/Get-SpaceRules.ps1`)

A data table, one entry per known folder. Fields: `Path` (env vars resolved at runtime), `Title`, `What` (one sentence), `Verdict`, `Safety`, `Action`, `RequiresAdmin`, `Evidence`.

Verdicts and their actions:

| Verdict | Action | Example rules from this machine |
| :-- | :-- | :-- |
| `Clean` | Delete contents through the existing cleanup pipeline and the bulk safety gate | `Temp` 6.9 GB, Software Distribution `Download`, `Packages\SpotifyAB...\LocalCache\Spotify` (Optional), `NVIDIA\NGX\models` (Optional; re-downloaded as needed) |
| `Command` | Run one allow-listed command, elevated if needed, after a consent dialog naming side effects | `docker system prune` (Docker data), `Dism /Online /Cleanup-Image /StartComponentCleanup` (WinSxS), `powercfg /h off` when `hiberfil.sys` exists, `vssadmin delete shadows /for=C: /oldest` |
| `Uninstall` | Open `ms-settings:appsfeatures` | `Program Files\NVIDIA Corporation\RTX Remix` 10.0 GB, `Programs\DockerDesktop` 3.3 GB, `Arduino15\packages\esp32` 6.3 GB |
| `Review` | Reveal in Explorer; no delete button | `Claude-Data` (never offered), Store Python `local-packages`, `NVIDIA App\UpdateFramework` 8.4 GB (update staging, unverified), `hermes-agent`, `Roaming\npm\node_modules` |
| `System` | Explain only | `WinSxS`, `System32`, `Installer`, `System Volume Information` |

Rules:
- Anything not verified on a real machine is `Review`. A `Clean` rule's target must be the specific cache subfolder (never a ProgramData or AppData parent) and must pass `Test-PathSafety` (bulk gate). Delete targets are added to `Get-CleanableTargets` so they also appear in the Cleaner tab.
- `Command` actions are an allow-list of exact strings in code. The UI never builds a command from scanned data.
- A rule matches a scanned folder when the paths are equal. The matching rule's data is attached to that tree node for the UI.

### 4.3 System-space panel (`src/modules/Get-SystemSpace.ps1`)

Reports, each with size and a plain-English line: `swapfile.sys`; pagefile (location from `Win32_PageFileUsage`, flagged "not on C:" when so); hibernation on/off (`powercfg /a`) and `hiberfil.sys` size; shadow copy storage (`vssadmin list shadowstorage`, administrator only, otherwise "needs administrator"); `WinSxS` (file-size sum, labelled as shared; real size via `Dism /Online /Cleanup-Image /AnalyzeComponentStore` on demand, administrator only); presence of `Windows.old`, `$Windows.~BT`, `$WinREAgent`.

Reconciliation: `used − Σ(top-level rows)` is the remainder. If positive it is `Protected areas`; if negative it is `Windows shared files (counted once)` (hard-link overlap). The remainder is never hidden.

### 4.4 Restart as Administrator

Button (and a banner when non-elevated and an admin-only action is relevant). Re-launches the same script elevated with `Start-Process powershell -Verb RunAs`. Under `irm | iex` there is no script path: the release writes its own text to a temp file first. Verify this works in a spike before building on it; if it fails, fall back to a message that shows the exact command to run.

### 4.5 Action execution and consent

Every action shows one confirmation that states what changes, what cannot be undone, and side effects (for example, `powercfg /h off` also disables Fast Startup; deleting shadow copies removes restore points). Commands run in the background job; their output streams to the Activity log. Nothing runs without a click on the confirmation.

## 5. UX design (Operate mode; incumbent dark Fluent theme retained)

**Job and audience:** a developer whose C: is nearly full, stressed, wanting the biggest safe win in under a minute, and a way to understand the rest. Success is freeing space with confidence and knowing where the remainder is.

**Information architecture:** tabs become **Overview** (new default), **Cleaner**, **Space Explorer** (replaces Directory Explorer), **Large Files**, **File Inspector**. The drive strip stays above all tabs.

**Overview** (answers "why is it full and what can I do now"):
1. A one-line verdict under the drive strip, for example `0.76 GB free. Critically low. About 12 GB can be freed safely right now.` (plain text, severity shown by words and an icon-free badge, not colour alone).
2. **Where your space went:** a single stacked horizontal bar of categories (Apps and games, Developer tools, Windows and system, Your files, Caches and temp, Protected or unreadable) with a legend carrying size and percent. Each segment filters the list below.
3. **Biggest folders:** top 12 rows: name, size, percent of C:, a thin bar, an insight badge (`Clean`, `Command`, `Uninstall`, `Review`, `System`).
4. **Recommended actions** (right column): cards ranked by reclaimable size times safety: title, size, safety badge, one line of why, one button. A primary button `Free X GB safely` runs only `Safe` cleans after one confirmation.
5. **Windows-managed space** (collapsible): the panel from 4.3.

**Scan states:**
- First run: scan starts on open. A progress block shows files scanned, GB scanned, current top folder, elapsed time and a Cancel button; rows appear as top-level totals stream in; skeleton bars for pending sections, not spinners.
- Done: summary line and reconciliation (`Accounted for 96% of used space`).
- Cancelled or partial: the same screens with a visible `Partial result` line.
- Unreadable folders: `N folders could not be read (needs administrator)` with the Restart as Administrator button.
- Empty or healthy drive: `Nothing large to clean. 62% free.` plus how to rescan.

**Space Explorer:** breadcrumb bar (each segment clickable), grid sorted by size (columns: name, size, bar, percent of parent, items, modified, insight), bottom action bar for the selected row (`Open in Explorer`, `Copy path`, plus the rule's one action). Keyboard: Enter drills in, Backspace goes up, arrow keys move; the focus ring already exists.

**Copy and tone:** plain verbs, sizes with units, no marketing words. Safety words are fixed: Safe, Optional, Advanced, Review. `Review` never has a delete button.

**Components:** reuse existing button, badge and DataGrid styles. New: Card (bordered panel), StackedBar (Grid with star-width columns), InsightBadge (same pill as the safety badge), ScanProgress block. Colour: accent for primary action and selection only; semantic colours for safety badges. Motion: 150 ms state changes only.

**Accessibility and layout:** text contrast 4.5:1 or better; every state also has text; layout verified at the 950 by 700 minimum and at 1140 by 800.

## 6. Safety

Unchanged: strict bulk gate for deletes, fail-closed behaviour, reparse points never followed, cloud placeholders skipped. New: command allow-list, `Review` never deletes, admin-only actions disabled with a reason when not elevated, `Claude-Data` rule is `Review` and explicitly never offered for deletion.

## 7. Testing

- Unit tests (sandbox): tree totals equal an independent sum; junctions and nested links not followed; the `(small items)` roll-up preserves totals; reconciliation rows always sum to used; negative remainder becomes the shared-files row.
- Rules tests: each `Clean` target passes the bulk gate and is not a protected parent; the `Command` allow-list matches exact strings; paths resolve with env vars; unknown folders get no insight.
- Action gating tests: admin-only actions disabled when non-elevated, with a reason; consent text names the side effects for the powercfg, DISM and vssadmin actions. Commands are verified by string only; they cannot be run in a non-admin session and the report says so.
- GUI wiring test extended to new controls; screenshots at both window sizes; the success test in section 2 run on the user's drive and recorded.
- Performance: one single-threaded full pass timed cold and warm and recorded in the plan.

## 8. Out of scope for Phase 1

Stale developer folder finder, Docker and WSL compaction (only `docker system prune` as a command), duplicate detection, MFT/USN fast scanning, scheduled cleaning, other drives.

## 9. Risks and open points

- Cold full scan time is unknown until measured; mitigated by streaming partial results and Cancel.
- Elevation under `irm | iex` needs a spike (4.4).
- `NVIDIA App\UpdateFramework` and `NGX\models` are marked `Review` / `Optional` until their re-download behaviour is confirmed on a real update cycle.
- `DISM /AnalyzeComponentStore` is slow; it runs only on request.
- No `PRODUCT.md` exists; Impeccable `init` can be run later to capture it, and this spec stands in as the product brief for now.

## 10. Build notes and measured results (2026-10-20, non-elevated, this machine)

Deviations from the design above, decided during the build:
- `Arduino15\packages\esp32` is `Review`, not `Uninstall`: it is managed by the Arduino IDE's Boards Manager, not Windows Settings.
- The category bar legend is informational. Clicking a segment does not filter the folder list (cut as not worth the extra state).
- Windows High Contrast mode is not supported yet (custom templates use fixed colours). Listed as a known gap.
- Restart as Administrator relaunches the file when there is one. From `irm | iex` there is no recoverable script text (verified), so it asks first and re-runs the current release from GitHub elevated.
- Two job slots (`action`, `scan`) instead of one, so cleaning stays available while the long drive scan runs.

Success test results:
- Scan: 1.4-1.5 million files, 195-204 GB scanned in about 2.5-3 minutes cold (8-way parallel walk, 96 unreadable folders counted, not fatal). Top-level folders stream into the Overview while it runs and Cancel returns the partial tree.
- Accounting: 92.7-93.0% of used space is measured; the remaining 15.3 GB is shown as `Protected areas (restart as administrator to break down)`. Rows sum to used space by construction (tested, including the negative "shared files" case). The elevated figure (target: unexplained at most 5%) could not be measured because no elevated session was available.
- Advice coverage: 12 of the 12 biggest folders shown on the Overview have an insight (target was 10 of 15). 3 are `Clean`/`Command` with a one-click path, 2 are `Uninstall`, the rest `Review`/`System`.
- Not run: any admin-only command (component cleanup, hibernation off, shadow copy delete). Their exact command strings, consent text and non-admin refusal are tested; their effect is not.

## 11. Phase 2 build notes (2026-10-20)

Scope delivered, chosen from measurements on the same machine:
- **App cache detector** (`Find-AppCaches.ps1`): 19 apps and 2.55 GB found in about 2 s on top of the drive scan. Structure signatures only; Claude-Data, Store packages and fixed targets excluded; one Cleaner row per app (several folders) cleaned through `Invoke-ExecuteCleanup` with its existing safety code.
- **Docker/WSL disk compaction** (`Invoke-DiskCompact.ps1`): found the 16.26 GB Docker disk and a 1.2 GB WSL disk by registration; Claude's 7.85 GB VM disk is refused by design. Effect unverified: it needs administrator and Docker Desktop stopped.
- **npm cache path fixed** (`%LOCALAPPDATA%\npm-cache`, previously `%APPDATA%`), Electron download cache target added.
- **Honest numbers:** real before/after C: free space after every clean or command; admin-unlock hint when not elevated; scan results are re-queued instead of dropped when a clean happens during a scan.

Deliberately not built, and why:
- Stale dev-artifact finder: every `node_modules`/`venv`/`dist` found on this C: belongs to a tool (npm global, hermes, Codex); none is a project that can be safely deleted.
- Installed-apps tab: registry sizes here are dominated by games on another drive; the large C: apps already appear on the Overview.
- Extra Windows targets (Minidump, LiveKernelReports, WER ProgramData, MEMORY.DMP): all empty or absent on this machine.

## 12. Making it work for everyone (2026-10-20)

Audit of assumptions that only held on the author's PC, and what changed:
- **Windows drive:** the drive strip, Hunter, scan, status text and command arguments now use the Windows system drive instead of a literal `C:`. `ShadowDelete` used `/for=C:`, which on a PC with Windows on another letter would have deleted restore points on the wrong drive.
- **Language:** shadow-copy size is read from WMI (`Win32_ShadowStorage`, elevated) instead of parsing English `vssadmin` text (which also mis-read decimal commas); diskpart success is judged by exit code only.
- **Unknown folders:** location-based guidance (`Get-GenericAdvice`) for installed programs, game libraries, user folders, Store app data, tool folders and Windows. Verdicts are limited to Uninstall, Review and System, with a keep-list so Windows components and GPU/audio/chipset driver software are never suggested for removal.
- **Common big items made visible:** `MEMORY.DMP` and Windows upgrade leftovers with Settings links, iTunes device backups, and the OneDrive folder (Review only).
- **Temp cleaning keeps files changed in the last 24 hours** (behaviour change; Disk Cleanup and Storage Sense do the same).
- **Disk type:** scan parallelism is 2 on a spinning disk, 8 on SSD/NVMe, 4 when unknown.
- **Docs:** README now states what was tested (Windows 11, Windows PowerShell 5.1) instead of claiming Windows 10 and PowerShell 7.
- **Safety net:** `DISKMAN_DRY_RUN=1`, set by the test suite and smoke tool, makes every allow-listed command report instead of run, so an elevated test run cannot change the machine.

Still unverified beyond one machine: Windows 10, PowerShell 7, non-English Windows, HDD scanning speed, any elevated flow, WMI shadow storage size, and machines with Windows on a drive other than C:.
