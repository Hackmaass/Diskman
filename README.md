<div align="center">

# Diskman

**A lightweight Windows storage visualizer and cache cleaner, built entirely in native PowerShell and WPF.**

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078d4?style=for-the-badge&logo=windows&logoColor=white)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%20%7C%207%2B-5391fe?style=for-the-badge&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
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

Diskman analyzes drive `C:\` to identify and reclaim storage from application caches, GPU shaders, developer package stores, and system logs that standard Windows tools ignore. It runs with **zero external runtimes, no background services, and no installer**, and pairs deep file inspection with strict fail-closed safety guards.

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
| **Operating system** | Windows 10 (Build 1809+) or Windows 11 |
| **PowerShell** | Windows PowerShell 5.1 (built-in) or PowerShell 7+ |
| **Privileges** | Administrator is optional, but required to scan and clean system-level targets such as `C:\Windows\Temp` and CBS servicing logs |

> [!TIP]
> Without Administrator rights, Diskman still scans and cleans every per-user target. System-level targets are simply skipped.

---

## Features

```
+-------------------------------------------------------------------------------------------------+
| DISKMAN  |  C: Drive Storage Cleaner & Junk Purger                                              |
| C: Capacity: 476.2 GB   Used: 312.4 GB   Free: 163.8 GB   [||||||||||||||.....] 65.6% Used      |
+-------------------------------------------------------------------------------------------------+
| [ C: Drive Junk Cleaner ]  [ File Inspector ]  [ Large Files Hunter ]  [ Directory Explorer ]   |
|                                                                                                 |
|   Select Recommended | Select All | Clear All | Filter: All | System | Gaming | Dev | Apps       |
|  +----+----------------------------------+---------------+-----------+---------+-------------+  |
|  | [X]| NVIDIA DirectX Shader Cache      | Gaming & GPU  |   3.42 GB | 1,420   | SAFE        |  |
|  | [X]| Windows User Temp                | System        |   2.18 GB | 3,850   | SAFE        |  |
|  | [ ]| NuGet Package Cache              | Developer     |  12.40 GB | 18,200  | OPTIONAL    |  |
|  | [ ]| Windows Update Download Cache    | System        |   5.10 GB |   412   | ADVANCED    |  |
|  +----+----------------------------------+---------------+-----------+---------+-------------+  |
|                                                                                                 |
|  Target Files & Data        Safety & Protected Data        Post-Cleanup Impact                  |
|  Precompiled DirectX GPU    Safe: Driver-compiled cache.   Games recompile shaders on launch;   |
|  shader binaries in         Saves, settings, and profiles  may cause slight initial stutter.    |
|  %LOCALAPPDATA%\NVIDIA.     are untouched.                                                      |
+-------------------------------------------------------------------------------------------------+
| Real-time PowerShell execution log console...                                                   |
+-------------------------------------------------------------------------------------------------+
```

<table>
<tr>
<td width="50%" valign="top">

### 🧹 Storage Cleaner

Scans 36 storage categories across the operating system, developer tools, game launchers, and desktop applications. Shows file counts, disk usage, and a safety tier for each target. A three-pane inspection panel explains what will be removed, why it is safe, and what to expect afterwards.

</td>
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

### 📊 Directory Explorer

A fast folder-size profiler that maps disk usage across top-level `C:\` directories to surface unexpected space hogs.

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
│   │   ├── Invoke-SmartCleanup.ps1  # Target definitions, scanner, and cleanup routines
│   │   ├── Invoke-ShellActions.ps1  # Explorer integration and Recycle Bin operations
│   │   ├── Find-LargeFiles.ps1      # Large file search and classification
│   │   └── Start-FolderScan.ps1     # Directory tree profiler
│   ├── xaml/
│   │   └── MainWindow.xaml          # WPF UI layout and styling
│   └── app.ps1                      # Application bootstrapper and UI controller
├── release/
│   └── diskman.ps1                  # Compiled standalone distribution
├── Compile.ps1                      # Release compiler (inlines modules and XAML)
├── test_verify.ps1                  # Verification suite (AST, safety checks, unit tests)
├── run.bat                          # Launcher with auto-elevation
├── CONTRIBUTING.md                  # Contribution guidelines
├── SECURITY.md                      # Security and vulnerability policy
└── LICENSE                          # MIT License
```

---

## Development & Testing

**Run the test suite** — validates path safety barriers, servicing detection, module loading, AST syntax, and compilation:

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
