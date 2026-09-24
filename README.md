# Diskman

A lightweight Windows storage visualizer and cache cleaner built entirely in native PowerShell and WPF.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078d4?style=flat-square)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%20%7C%207%2B-5391fe?style=flat-square)](https://learn.microsoft.com/powershell/)
[![Dependencies](https://img.shields.io/badge/dependencies-none%20(native%20WPF)-2ea44f?style=flat-square)](#architecture)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

Diskman analyzes drive `C:\` to identify and reclaim storage from application caches, GPU shaders, developer package stores, and system logs that standard Windows tools ignore. It runs with zero external runtimes, no background services, and no installers—delivering full transparency with deep file inspection and strict fail-closed safety guards.

---

## Quick Start

### Run Directly in PowerShell (No Download Required)

Open PowerShell as Administrator (recommended for system-level caches) and execute:

```powershell
irm https://raw.githubusercontent.com/Hackmaass/Diskman/main/release/diskman.ps1 | iex
```

### Clone and Run Locally

```powershell
git clone https://github.com/Hackmaass/Diskman.git
cd Diskman

# Launch with automatic elevation prompt
.\run.bat

# Or run directly via PowerShell (STA mode required for WPF)
powershell -STA -ExecutionPolicy Bypass -File .\src\app.ps1
```

### Requirements

- **Operating System**: Windows 10 (Build 1809+) or Windows 11
- **PowerShell**: Windows PowerShell 5.1 (built-in) or PowerShell 7+
- **Privileges**: Administrator rights are optional, but required to scan and clean system-level targets (such as `C:\Windows\Temp` and CBS servicing logs).

---

## Key Features

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
|  | [ ]| NuGet Package Cache             | Developer     |  12.40 GB | 18,200  | OPTIONAL    |  |
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

### Storage Cleaner
Scans 36 distinct storage categories across your operating system, developer tools, game launchers, and desktop applications. Displays file counts, disk consumption, and safety classifications for each target. A built-in three-pane inspection panel details what will be removed, why the operation is safe, and what post-cleanup behavior to expect.

### File Inspector
Allows file-by-file inspection for any cleanable category. Review individual file paths, sizes, and modification timestamps. Select any file to open its enclosing directory in Windows File Explorer via `explorer.exe /select,` or delete individual items selectively.

### Large Files Hunter
Scans drive `C:\` for large files (configurable thresholds: 100 MB, 500 MB, 1 GB, 5 GB). Automatically categorizes files into Installers, Disk Images, Archives, Media, AI Models/Weights, and VM Images. Unwanted files can be sent to the Windows Recycle Bin with undo capability, or permanently deleted.

### Directory Explorer
Fast, lightweight folder size profiler that maps disk usage across top-level `C:\` directories to locate unexpected space hogs.

---

## Cleanable Categories

Diskman categorizes cleanup targets into three safety levels:

| Safety Tier | Default | Description |
| :--- | :--- | :--- |
| **Safe** | Checked | Disposable temporary files, scratch buffers, and driver-generated caches that regenerate automatically. |
| **Optional** | Unchecked | Build artifacts and package repositories. Safe to delete, but re-downloading or compiling them consumes network bandwidth or CPU time. |
| **Advanced** | Unchecked | Operating system servicing caches. Purged only after verifying that Windows Update and CBS services are idle. |

### Target Breakdown

| Group | Target / Category | Default Tier | Path / Description |
| :--- | :--- | :--- | :--- |
| **System** | Windows User Temp | Safe | `%LOCALAPPDATA%\Temp` |
| | Windows System Temp | Safe | `C:\Windows\Temp` |
| | Crash Dumps & Minidumps | Safe | `%LOCALAPPDATA%\CrashDumps` |
| | Windows Error Reports (WER) | Safe | `%LOCALAPPDATA%\Microsoft\Windows\WER` |
| | Windows CBS Servicing Logs | Safe | `C:\Windows\Logs\CBS` |
| | DISM Servicing Logs | Safe | `C:\Windows\Logs\DISM` |
| | Windows Update Download Cache | Advanced | `C:\Windows\SoftwareDistribution\Download` |
| | Delivery Optimization Chunks | Advanced | `C:\Windows\SoftwareDistribution\DeliveryOptimization` |
| **Gaming & GPU** | NVIDIA DXCache & GLCache | Safe | DirectX and OpenGL/Vulkan shader caches |
| | DirectX Shader Cache (D3DSCache) | Safe | Global Direct3D shader cache |
| | AMD Radeon Shader Cache | Safe | `%LOCALAPPDATA%\AMD\DxCache` |
| | Intel Graphics Shader Cache | Safe | `%LOCALAPPDATA%\Intel\ShaderCache` |
| | Steam Web & HTTP Cache | Safe | Embedded Chromium assets (`htmlcache`) |
| | Epic Games Launcher Cache | Safe | Storefront assets and web views |
| | EA Desktop / Origin Cache | Safe | UI media and temporary store cache |
| | Ubisoft Connect Cache | Safe | Client cache and store artwork |
| | Battle.net Agent Cache | Safe | Patcher cache and staging metadata |
| | Riot Client Logs | Safe | Diagnostic session logs (League of Legends, Valorant) |
| | Unreal Engine DDC | Optional | Derived Data Cache (textures, compiled shaders) |
| | Unity Package Cache | Optional | Asset store downloads and package manager tarballs |
| **Developer** | Python pip Cache | Safe | Downloaded wheel binaries and tarballs |
| | Node.js npm Cache | Safe | `%APPDATA%\npm-cache` |
| | Yarn Package Cache | Safe | `%LOCALAPPDATA%\Yarn\Cache` |
| | NuGet Package Cache | Optional | Global package store (`%USERPROFILE%\.nuget\packages`) |
| | Gradle Build Cache | Optional | Dependency jars and wrapper zip archives |
| | Rust Cargo Registry Cache | Optional | Downloaded `.crate` archives |
| **Apps & Web** | Google Chrome Cache | Safe | Web assets only; credentials and cookies are protected |
| | Microsoft Edge Cache | Safe | Web assets only; credentials and cookies are protected |
| | Brave Browser Cache | Safe | Web assets only; wallets and keys are protected |
| | Discord Media Cache | Safe | Server emojis, avatars, and voice buffers |
| | Spotify Track Storage | Optional | Cached audio streams and offline track downloads |
| | VS Code Cache | Safe | V8 code cache and webview buffers |
| | Adobe Media Cache | Safe | Premiere / After Effects peak and conformed audio files |
| | Telegram Desktop Cache | Optional | Media cache (all media remains available in cloud) |
| **Recycle Bin** | Windows Recycle Bin | Safe | Empty recycle bin on drive `C:\` |

---

## Safety Architecture

Diskman is designed with a strict fail-closed safety model implemented in `Test-PathSafety` and `Get-WindowsServicingStatus`:

- **Protected System Boundaries**: Absolute deny-lists prevent targeting or descending into critical OS paths, including `WinSxS`, `servicing` (`Packages`, `Sessions`), `System32` (and subdirectories such as `catroot`, `catroot2`, `wbem\Repository`, `config`), `Boot`, `EFI`, and `System Volume Information`.
- **Reparse Point & Junction Isolation**: Directory junctions and symbolic links are detected via `[System.IO.FileAttributes]::ReparsePoint`. Scans and deletions never traverse across links, eliminating the risk of recursive deletion into linked directories.
- **Windows Servicing State Verification**: Before touching `SoftwareDistribution\Download`, Diskman queries the active state of `wuauserv`, `TrustedInstaller`, `UsoSvc`, and `BITS`, and inspects CBS reboot-pending registry keys (`CBS\RebootPending`, `CBS\RebootInProgress`, `WindowsUpdate\RebootRequired`). If servicing or installation is active, the cleanup is safely bypassed without stopping services.
- **User Profile & Credential Protection**: User document libraries (`Documents`, `Desktop`, `Pictures`, `Music`, `Videos`, `OneDrive`) are permanently excluded. Browser credentials, session tokens, passwords, cookies, and history databases (`Login Data`, `Cookies`, `Web Data`, `Local State`) are strictly blocked.
- **Non-Destructive Recycler**: The Large Files Hunter utilizes the shell-level Windows Recycle Bin API (`Microsoft.VisualBasic.FileIO.FileSystem`) by default, ensuring deletions remain recoverable unless permanent deletion is explicitly selected.
- **Fail-Closed Default**: Any path resolution failure, permission exception, or unhandled check immediately causes the safety engine to reject the target (`Safe = $false`).

---

## Architecture

Diskman is built entirely with built-in Windows components:

- **Logic**: Native PowerShell (PowerShell 5.1 / 7+)
- **Interface**: Windows Presentation Foundation (WPF) with XAML
- **Packaging**: Self-contained single-file compiler (`Compile.ps1`)

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
│   └── diskman.ps1                  # Compiled standalone distribution (169 KB)
├── Compile.ps1                      # Release compiler (inlines modules and XAML)
├── test_verify.ps1                  # Verification test suite (AST, safety checks, unit tests)
├── run.bat                          # Launcher script with auto-elevation
├── CONTRIBUTING.md                  # Contribution guidelines
├── SECURITY.md                      # Security and vulnerability policy
└── LICENSE                          # MIT License
```

---

## Development & Testing

### Running Tests

The test suite validates path safety barriers, servicing detection, module ingestion, AST syntax, and compilation:

```powershell
powershell -ExecutionPolicy Bypass -File .\test_verify.ps1
```

### Compiling the Standalone Distribution

When updating source files in `src/`, recompile the monolithic release bundle:

```powershell
powershell -ExecutionPolicy Bypass -File .\Compile.ps1
```

The script inlines all modules from `src/modules/`, embeds `MainWindow.xaml`, attaches the controller logic from `src/app.ps1`, and generates `release/diskman.ps1` as a standalone, zero-dependency script.

---

## Contributing

Contributions are welcome. Adding a new cache target or application profile requires only adding a target definition block to `Get-CleanableTargets` in `src/modules/Invoke-SmartCleanup.ps1`.

Please review [CONTRIBUTING.md](CONTRIBUTING.md) for details on target schemas, testing requirements, and coding conventions.

---

## License

This project is licensed under the [MIT License](LICENSE).
