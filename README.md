<div align="center">

# Diskman

**A lightweight Windows storage visualizer and cache cleaner, built entirely in native PowerShell and WPF.**

[![Platform](https://img.shields.io/badge/tested%20on-Windows%2011-0078d4?style=for-the-badge&logo=windows&logoColor=white)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/tested%20with-Windows%20PowerShell%205.1-5391fe?style=for-the-badge&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Dependencies](https://img.shields.io/badge/dependencies-none-2ea44f?style=for-the-badge)](#architecture)
[![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)](LICENSE)

[Quick Start](#quick-start) •
[Features](#features) •
[Cleanable Categories](#cleanable-categories) •
[Safety Architecture](#safety-architecture) •
[Development](#development--testing) •
[Contributing](#contributing)

</div>

---

Diskman scans drive `C:\` once, accounts for every byte of used space, and tells you what each big folder is and what to do about it: clean a cache, run a safe command, uninstall an app, or just review it. It also reclaims storage from application caches, GPU shaders, developer package stores, and system logs that standard Windows tools ignore. It runs with **zero external runtimes, no background services, and no installer**, and pairs deep file inspection with strict fail-closed safety guards.

<table>
<tr>
<td align="center" width="25%"><b>36</b><br><sub>cleanup targets</sub></td>
<td align="center" width="25%"><b>0</b><br><sub>external dependencies</sub></td>
<td align="center" width="25%"><b>1 file</b><br><sub>standalone release script</sub></td>
<td align="center" width="25%"><b>Fail-closed</b><br><sub>safety engine</sub></td>
</tr>
</table>

## Quick Start

### Run directly (no download)

Open PowerShell **as Administrator** (recommended for system-level caches) and run:

```powershell
irm https://raw.githubusercontent.com/Hackmaass/Diskman/main/release/diskman.ps1 | iex
```

> [!IMPORTANT]
> That command runs whatever is currently on `main`, and you are running it as Administrator. To run a reviewed copy instead, download the script, read it, then run it. The published SHA-256 only proves the download was not corrupted: it comes from the same branch as the script, so it is not proof the code is trustworthy. For that, pin a release tag in the URL and review that version.
>
> ```powershell
> $base = "https://raw.githubusercontent.com/Hackmaass/Diskman/main/release"
> Invoke-WebRequest "$base/diskman.ps1" -OutFile diskman.ps1 -UseBasicParsing
> $expected = ((Invoke-RestMethod "$base/diskman.ps1.sha256" -UseBasicParsing) -split '\s+')[0]
> if ((Get-FileHash .\diskman.ps1 -Algorithm SHA256).Hash -ieq $expected) {
>     powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\diskman.ps1
> } else { Write-Error "Hash mismatch - do not run" }
> ```

### Clone and run locally

```powershell
git clone https://github.com/Hackmaass/Diskman.git
cd Diskman

# Launch with automatic elevation prompt
.\run.bat

# Or run directly via PowerShell (STA mode required for WPF)
powershell -STA -ExecutionPolicy Bypass -File .\src\app.ps1
```

### Requirements

| Component | Requirement |
| :--- | :--- |
| **Operating system** | Tested on Windows 11. Windows 10 (build 1809 or later) uses the same Windows features and is expected to work, but has not been tested. |
| **PowerShell** | Windows PowerShell 5.1 (built in to Windows; this is what everything is tested with). PowerShell 7 is untested. |
| **Privileges** | Administrator is optional, but required to scan and clean system-level targets such as `C:\Windows\Temp` and CBS servicing logs. The elevated path is exercised by the test suite only in a dry-run mode; see Development |

> [!TIP]
> Without Administrator rights, Diskman still scans and cleans every per-user target. System-level targets are simply skipped.

---

## Features

```
+-------------------------------------------------------------------------------------------------+
| Diskman  |  C: drive space cleaner                          [Restart as Administrator] [Rescan]   |
| Total 220.4 GB   Used 211.0 GB   Free 9.4 GB   [||||||||||||||||||||.] 95.7% used - Critical       |
+-------------------------------------------------------------------------------------------------+
| [ Overview ] [ Cleaner ] [ Space Explorer ] [ Large Files ] [ File Inspector ]                    |
|                                                                                                   |
|  9.42 GB free of 220.4 GB. Critically low. About 8.8 GB can be freed safely right now.            |
|  WHERE YOUR SPACE WENT  [Apps 48%][Dev tools 21%][Windows 18%][Files 2%][Caches][Protected 7%]    |
|  BIGGEST FOLDERS                                      |  [ Free 8.8 GB safely ]                   |
|   C:\Windows\WinSxS        17.9 GB  Component cleanup  |  RECOMMENDED ACTIONS                      |
|   ~\AppData\Local\Docker   16.4 GB  Prune Docker data  |   Windows User Temp   6.9 GB  [Clean...]  |
|   ~\AppData\Local\Temp      6.9 GB  Clean (Safe)       |   Docker Desktop data 16.4 GB [Prune...]  |
|   C:\Program Files\...Remix 10.0 GB  Uninstall          |  WINDOWS-MANAGED SPACE  swapfile, ...     |
+-------------------------------------------------------------------------------------------------+
| Activity log (also saved to %LOCALAPPDATA%\Diskman\logs)                                          |
+-------------------------------------------------------------------------------------------------+
```

<table>
<tr>
<td width="50%" valign="top">

### 🧭 Overview and Space Explorer

One background pass over the whole drive builds a size tree. The Overview answers "why is my drive full": a verdict, a bar showing where the space went, the biggest folders with advice for each, and ranked actions with a one-click **Free space safely** (Safe items only, one confirmation). Space Explorer lets you drill through the same tree with a breadcrumb. Space that only an administrator can see (shadow copies, protected areas) is shown as its own labelled row, never hidden. Advice comes from a rules table: `Clean`, `Command` (fixed allow-list such as `docker system prune`), `Uninstall`, `Review`, or `System`. Unknown folders are never offered for deletion.

**Detected app caches.** After each scan Diskman also finds the cache folders of the apps installed for you: every browser profile, Electron apps and VS Code-family editors. It recognises them by what is *inside* a folder (for example `Cache_Data\index` for a Chromium cache, `User\settings.json` next to `CachedData` for an editor), never by name alone, so an unrelated folder called `Cache` stays out. They appear in the Cleaner as `<App> caches (detected)`, grouped per app. Claude's app data and Microsoft Store packages are never offered.

**Docker and WSL disks.** Docker Desktop and WSL keep data in `.vhdx` files that grow but never shrink. Diskman lists the registered ones and, as administrator with Docker Desktop and WSL stopped, can compact them to give back space that was already freed inside. Disks are found only through Docker's own paths and WSL's registration, so other apps' virtual machine disks are never touched. `docker system prune` is offered when the Docker engine is running.

**Works on any PC.** Folders no rule knows still get plain-language guidance based on where they sit (installed program, Steam game, your own files, Store app data, tool data, Windows). That guidance can only say *uninstall in Settings*, *review* or *keep*, never delete, and drivers and Windows components are on a keep-list. The Windows drive letter, language and disk type are detected rather than assumed: shadow-copy size comes from WMI instead of translated text, and a spinning disk is scanned with fewer parallel threads than an SSD.

**Honest results.** After every clean the dialog and log show how C: free space really changed (before and after), not only what Diskman counted. When not running as administrator, the Overview says how much more an administrator session would unlock.

</td>
<td width="50%" valign="top">

### 🧹 Storage Cleaner

Scans 36 storage categories across the operating system, developer tools, game launchers, and desktop applications. Shows file counts, disk usage, and a safety tier for each target. A three-pane inspection panel explains what will be removed, why it is safe, and what to expect afterwards.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🔍 File Inspector

File-by-file review for any cleanable category, with paths, sizes, and modification timestamps. Open any file's folder in Explorer (`explorer.exe /select,`) or delete individual items selectively.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 📦 Large Files Hunter

Finds large files on `C:\` using configurable thresholds (100 MB, 500 MB, 1 GB, 5 GB) and groups them into Installers, Disk Images, Archives, Media, AI Models/Weights, and VM Images. Send files to the Recycle Bin (recoverable) or delete them permanently.

</td>
<td width="50%" valign="top">

### 🧾 Audit log

Every scan, deletion and command is also appended to `%LOCALAPPDATA%\Diskman\logs\diskman-yyyyMMdd.log`, so there is a record after the window closes.

</td>
</tr>
</table>

---

## Cleanable Categories

Every target is assigned one of three safety tiers:

| Tier | Selected by default | Description |
| :--- | :---: | :--- |
| 🟢 **Safe** | ✅ | Disposable temp files, scratch buffers, and driver-generated caches that regenerate automatically. |
| 🟡 **Optional** | — | Build artifacts and package stores. Safe to delete, but rebuilding or re-downloading costs bandwidth or CPU time. |
| 🔴 **Advanced** | — | OS servicing caches. Purged only after verifying that Windows Update and CBS services are idle. |

<details>
<summary><b>🖥️ System</b> — 8 targets</summary>
<br>

| Target | Tier | Path / Description |
| :--- | :---: | :--- |
| Windows User Temp | 🟢 Safe | `%LOCALAPPDATA%\Temp` |
| Windows System Temp | 🟢 Safe | `C:\Windows\Temp` |
| Crash Dumps & Minidumps | 🟢 Safe | `%LOCALAPPDATA%\CrashDumps` |
| Windows Error Reports (WER) | 🟢 Safe | `%LOCALAPPDATA%\Microsoft\Windows\WER` |
| Windows CBS Servicing Logs | 🟢 Safe | `C:\Windows\Logs\CBS` |
| DISM Servicing Logs | 🟢 Safe | `C:\Windows\Logs\DISM` |
| Windows Update Download Cache | 🔴 Advanced | `C:\Windows\SoftwareDistribution\Download` |
| Delivery Optimization Chunks | 🔴 Advanced | `C:\Windows\SoftwareDistribution\DeliveryOptimization` |

</details>

<details>
<summary><b>🎮 Gaming & GPU</b> — 13 targets</summary>
<br>

| Target | Tier | Path / Description |
| :--- | :---: | :--- |
| NVIDIA DXCache | 🟢 Safe | NVIDIA DirectX shader cache |
| NVIDIA GLCache | 🟢 Safe | NVIDIA OpenGL/Vulkan shader cache |
| DirectX Shader Cache (D3DSCache) | 🟢 Safe | Global Direct3D shader cache |
| AMD Radeon Shader Cache | 🟢 Safe | `%LOCALAPPDATA%\AMD\DxCache` |
| Intel Graphics Shader Cache | 🟢 Safe | `%LOCALAPPDATA%\Intel\ShaderCache` |
| Steam Web & HTTP Cache | 🟢 Safe | Embedded Chromium assets (`htmlcache`) |
| Epic Games Launcher Cache | 🟢 Safe | Storefront assets and web views |
| EA Desktop / Origin Cache | 🟢 Safe | UI media and temporary store cache |
| Ubisoft Connect Cache | 🟢 Safe | Client cache and store artwork |
| Battle.net Agent Cache | 🟢 Safe | Patcher cache and staging metadata |
| Riot Client Logs | 🟢 Safe | Diagnostic session logs (League of Legends, Valorant) |
| Unreal Engine DDC | 🟡 Optional | Derived Data Cache (textures, compiled shaders) |
| Unity Package Cache | 🟡 Optional | Asset store downloads and package manager tarballs |

</details>

<details>
<summary><b>🛠️ Developer</b> — 6 targets</summary>
<br>

| Target | Tier | Path / Description |
| :--- | :---: | :--- |
| Python pip Cache | 🟢 Safe | Downloaded wheel binaries and tarballs |
| Node.js npm Cache | 🟢 Safe | `%APPDATA%\npm-cache` |
| Yarn Package Cache | 🟢 Safe | `%LOCALAPPDATA%\Yarn\Cache` |
| NuGet Package Cache | 🟡 Optional | Global package store (`%USERPROFILE%\.nuget\packages`) |
| Gradle Build Cache | 🟡 Optional | Dependency jars and wrapper zip archives |
| Rust Cargo Registry Cache | 🟡 Optional | Downloaded `.crate` archives |

</details>

<details>
<summary><b>🌐 Apps & Web</b> — 8 targets</summary>
<br>

| Target | Tier | Path / Description |
| :--- | :---: | :--- |
| Google Chrome Cache | 🟢 Safe | Web assets only; credentials and cookies are protected |
| Microsoft Edge Cache | 🟢 Safe | Web assets only; credentials and cookies are protected |
| Brave Browser Cache | 🟢 Safe | Web assets only; wallets and keys are protected |
| Discord Media Cache | 🟢 Safe | Server emojis, avatars, and voice buffers |
| Spotify Track Storage | 🟡 Optional | Cached audio streams and offline track downloads |
| VS Code Cache | 🟢 Safe | V8 code cache and webview buffers |
| Adobe Media Cache | 🟢 Safe | Premiere / After Effects peak and conformed audio files |
| Telegram Desktop Cache | 🟡 Optional | Media cache (all media remains available in the cloud) |

</details>

<details>
<summary><b>🗑️ Recycle Bin</b> — 1 target</summary>
<br>

| Target | Tier | Path / Description |
| :--- | :---: | :--- |
| Windows Recycle Bin | 🟡 Optional | Permanently empties the Recycle Bin on drive `C:\` (never pre-selected) |

</details>

---

## Safety Architecture

Diskman uses a strict **fail-closed** safety model, implemented in `Test-PathSafety` and `Test-WindowsServicingActive`.

> [!IMPORTANT]
> Any path resolution failure, permission exception, or unhandled check causes the safety engine to reject the target (`Safe = $false`). When in doubt, Diskman does nothing.

| Guard | What it does |
| :--- | :--- |
| **Protected system boundaries** | Absolute deny-lists block targeting or descending into `WinSxS`, `servicing` (`Packages`, `Sessions`), `System32` (including `catroot`, `catroot2`, `wbem\Repository`, `config`), `Boot`, `EFI`, and `System Volume Information`. |
| **Reparse point & junction isolation** | Junctions and symbolic links are detected via `[System.IO.FileAttributes]::ReparsePoint`. Scans and deletions never traverse them, eliminating recursive deletion into linked directories. |
| **Servicing state verification** | Before touching `SoftwareDistribution\Download` or Delivery Optimization, Diskman checks for active BITS transfer jobs, pending reboots (`CBS\RebootPending`, `CBS\RebootInProgress`, `CBS\PackagesPending`, `WindowsUpdate\RebootRequired`, `PostRebootReporting`), `PendingFileRenameOperations`, and `UpdateExeVolatile`. If servicing is active or cannot be verified, cleanup is skipped. Services are never stopped or inspected by name. |
| **User profile & credential protection** | Bulk cleanup never enters `Documents`, `Desktop`, `Downloads`, `Pictures`, `Music`, `Videos`, or any `OneDrive*` folder. Browser credential and history stores (`Login Data`, `Cookies`, `Web Data`, `Local State`) are always blocked. |
| **Linked folders are never followed** | A cleanup target that is itself a junction or symlink (for example a cache you moved to another drive) is skipped, and nested links are removed as links without touching what they point to. |
| **Single-file gate (Large Files Hunter)** | The Hunter may list and act on files in `Downloads`, `Videos`, `Documents` and similar folders, because you choose each file. It never offers files under `Windows`, `Program Files`, `ProgramData`, `AppData` (installed apps, WSL distros, Docker and VM disks live there), hidden tool folders such as `.vscode` (except the `.ollama`, `.cache` and `.lmstudio` AI model stores), game libraries (`steamapps`, `SteamLibrary`, `Epic Games`, `XboxGames`), VM folders, or `OneDrive*`. Use **Send to Recycle Bin** (recoverable) unless you are sure; **Permanent Delete** cannot be undone. |
| **Honest numbers** | Space freed is measured after deletion (what was there minus what remains), never estimated. Files in use are skipped and reported in the log. |

---

## Architecture

Diskman is built entirely on components that ship with Windows:

| Layer | Technology |
| :--- | :--- |
| **Logic** | Native PowerShell (5.1 / 7+) |
| **Interface** | Windows Presentation Foundation (WPF) with XAML |
| **Packaging** | Self-contained single-file compiler (`Compile.ps1`) |

```
Diskman/
├── src/
│   ├── modules/
│   │   ├── 00-Utils.ps1             # Path safety engine, servicing detection, size formatters
│   │   ├── Get-DriveMetrics.ps1     # Real-time C: drive capacity and metrics
│   │   ├── Scan-DriveTree.ps1       # One-pass size tree (compiled walker), accounting, categories, biggest folders
│   │   ├── Get-SpaceRules.ps1       # What each big folder is, the verdict, and the command allow-list
│   │   ├── Get-SystemSpace.ps1      # swapfile, paging file, hibernation, shadow copies, WinSxS
│   │   ├── Invoke-SmartCleanup.ps1  # Target definitions, scanner, and cleanup routines
│   │   ├── Invoke-ShellActions.ps1  # Explorer integration and Recycle Bin operations
│   │   └── Find-LargeFiles.ps1      # Large file search and classification
│   ├── xaml/
│   │   └── MainWindow.xaml          # WPF UI layout and styling
│   └── app.ps1                      # Application bootstrapper and UI controller
├── release/
│   └── diskman.ps1                  # Compiled standalone distribution
├── tools/
│   └── Invoke-GuiSmoke.ps1          # Launches the real app, takes screenshots of each tab, closes (read-only)
├── Compile.ps1                      # Release compiler (inlines modules and XAML)
├── test_verify.ps1                  # Verification suite (AST, safety checks, unit tests)
├── run.bat                          # Launcher with auto-elevation
├── CONTRIBUTING.md                  # Contribution guidelines
├── SECURITY.md                      # Security and vulnerability policy
└── LICENSE                          # MIT License
```

---

## Development & Testing

**Run the test suite** — validates path safety barriers, servicing detection, sandbox deletion, the space analyzer (tree, accounting, rules, command allow-list), GUI control wiring, AST syntax, and compilation:

```powershell
powershell -ExecutionPolicy Bypass -File .\test_verify.ps1
```

**Build the standalone release** — inlines every module in `src/modules/`, embeds `MainWindow.xaml`, appends the controller from `src/app.ps1`, and writes `release/diskman.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Compile.ps1
```

> [!NOTE]
> Recompile after any change under `src/`. The one-line `irm | iex` install serves `release/diskman.ps1` directly.

---

## Contributing

Contributions are welcome. Adding a new cache target only requires a target definition block in `Get-CleanableTargets` inside [`src/modules/Invoke-SmartCleanup.ps1`](src/modules/Invoke-SmartCleanup.ps1).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the target schema, testing requirements, and coding conventions. Security issues should be reported as described in [SECURITY.md](SECURITY.md).

---

<div align="center">

Released under the [MIT License](LICENSE).

</div>
