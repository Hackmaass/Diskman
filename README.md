# Diskman

A fast, transparent Windows `C:\` drive cleaner and storage visualizer with zero external dependencies. Built entirely in native PowerShell and WPF (XAML).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D4.svg)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2B%20%7C%207%2B-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

---

## Why Diskman?

Windows `C:\` drives fill up quickly. Even when your personal files are stored on secondary drives, hidden directories quietly accumulate tens of gigabytes of disk space:

- **GPU & DirectX Shader Caches** (`NVIDIA DXCache`, `AMD DxCache`, `D3DSCache`) that persist across game uninstalls.
- **Game Launcher Caches** (`Steam`, `Epic Games`, `EA App`, `Battle.net`, `Ubisoft Connect`) downloading web assets and temporary payloads.
- **Developer Package Stores** (`pip`, `npm`, `yarn`, `nuget`, `cargo`, `gradle`) storing duplicates of every downloaded package.
- **System & Component Logs** (`CBS`, `DISM`, crash dumps, WER error reports) left behind after system operations.
- **Windows Update Download Payloads** (Advanced, state-checked cleanup of `SoftwareDistribution\Download`).

The built-in Windows *Disk Cleanup* (`cleanmgr.exe`) misses most of these modern caches. Meanwhile, many third-party cleaning utilities are closed-source, require full installers, run unwanted background services, or bundle telemetry.

**Diskman** gives you full visibility and control:
- **Zero Install, Zero Bloat**: A lightweight PowerShell + WPF application that runs out-of-the-box on any Windows 10 or 11 system.
- **Total Transparency**: Inspect every detected file path and size inside the UI or reveal it directly in Windows File Explorer before deleting.
- **Fail-Closed Safety Engine**: Multi-layer safety engine (`Test-PathSafety`) rigorously protects OS components, servicing stores, user personal folders, and browser credentials.
- **State-Aware Windows Servicing Guard**: Windows Update caches are treated as advanced targets and are only purged when Windows servicing and update components are idle and no reboot is pending.

---

## Quick Start

### Option 1: Launch Directly in PowerShell (No Download Needed)
Open PowerShell (as Administrator for system items) and run:

```powershell
irm https://raw.githubusercontent.com/Hackmaass/Diskman/main/release/diskman.ps1 | iex
```

### Option 2: Clone and Run Locally
```powershell
git clone https://github.com/Hackmaass/Diskman.git
cd Diskman

# Double-click or run the launcher (with auto-elevation):
.\run.bat

# Or run directly via PowerShell:
powershell -STA -ExecutionPolicy Bypass -File .\src\app.ps1
```

---

## Features

### 🧹 Smart Cache & Storage Cleaner
Scans over 36 distinct storage categories categorized by safety profile:
- **Windows & System**: User Temp, System Temp, Crash dumps, WER telemetry logs, CBS/DISM servicing logs, and optional Windows Update Download cache.
- **Gaming & GPU Caches**: NVIDIA DXCache/GLCache, AMD Radeon shader cache, Intel Graphics shader cache, Steam web cache, Epic Games cache, EA App cache, Ubisoft Connect cache, Battle.net cache, Riot Client logs, Unreal Engine DDC, Unity package cache.
- **Developer Stores**: Python `pip` cache, Node.js `npm` / `yarn` caches, NuGet package stores, Gradle build cache, Rust Cargo crate cache.
- **Applications & Browsers**: Chrome web cache, Edge web cache, Brave cache, Discord media cache, Spotify offline cache, VS Code cache, Adobe Premiere media cache, Telegram Desktop cache.
- **Recycle Bin**: Instant overview and purge of `C:\$Recycle.Bin`.

### 🛡️ Safety Engine & OS Servicing Boundaries (`Test-PathSafety`)
Diskman enforces a strict, fail-closed safety model:
- **Protected Servicing Stores**: Permanently blocks access to `WinSxS`, `servicing` (`Packages`, `Sessions`), `catroot`/`catroot2`, `wbem\Repository`, `config` (Registry hives), `Boot`, and `SoftwareDistribution` metadata databases (`DataStore.edb`).
- **State-Aware Servicing Guard**: Before cleaning `SoftwareDistribution\Download`, Diskman inspects `wuauserv`, `TrustedInstaller`, `UsoSvc`, `BITS`, and CBS registry pending reboot keys. If Windows is servicing, staging, or awaiting reboot, cleanup is safely skipped without force-stopping services.
- **Reparse Point & Junction Isolation**: Symbolic links and directory junctions are detected and never traversed recursively, preventing unintended deletion into linked locations.
- **User Data Guard**: Protects personal user directories (`Desktop`, `Documents`, `Pictures`, `Music`, `Videos`, `OneDrive`).
- **Credential & Identity Guard**: Strictly protects browser logins, cookies, history, and session files (`Login Data`, `Cookies`, `Web Data`, `Bookmarks`, `Preferences`).
- **Boot File Protection**: Safeguards virtual memory and boot files (`pagefile.sys`, `swapfile.sys`, `hiberfil.sys`, `bootmgr`).

### 🔍 In-App Drilldown & Explorer Reveal
- Click any cleanable category to inspect individual file names, paths, and sizes in the item inspector.
- Jump directly to any directory in **Windows File Explorer** to inspect contents manually before deciding to purge.

### 🎯 C: Drive Large File Seeker
- Quickly scan `C:\` for oversized installer packages (`.exe`, `.msi`), disk images (`.iso`, `.vhd`), archives, media files, and large diagnostic logs.
- Filter by minimum file size (100 MB, 500 MB, 1 GB, 5 GB) and file category.
- Safely send unwanted large files to the **Windows Recycle Bin** rather than permanently destroying them.

---

## Safety Classifications

Diskman categorizes all targets into three distinct safety tiers:

| Tier | Default Selection | Description | Examples |
| :--- | :--- | :--- | :--- |
| **Safe** | Checked (`Recommended = true`) | Fully disposable caches and logs recreated automatically as needed. | User Temp, GPU Shader Caches, Web Caches, CBS Logs |
| **Optional** | Unchecked (`Recommended = false`) | Safe to remove, but may require network re-downloads (e.g. package stores, offline media). | NuGet packages, Gradle cache, Cargo cache, Spotify offline storage |
| **Advanced** | Unchecked (`Recommended = false`) | System-level update caches requiring servicing idle validation and explicit confirmation. | Windows Update Download Cache, Delivery Optimization |

---

## Project Structure

Diskman is organized into modular scripts for clean development and compiles into a single, self-contained release script:

```text
Diskman/
├── src/
│   ├── modules/
│   │   ├── 00-Utils.ps1             # Formatting, servicing inspection, and Test-PathSafety guard engine
│   │   ├── Get-DriveMetrics.ps1     # C: drive capacity and storage health metrics
│   │   ├── Invoke-SmartCleanup.ps1  # 36+ cleanup target definitions and purge routines
│   │   ├── Invoke-ShellActions.ps1  # File Explorer reveal, Recycle Bin, and safe deletion
│   │   ├── Find-LargeFiles.ps1      # Large file search and categorization
│   │   └── Start-FolderScan.ps1     # Directory analyzer and drilldown inspector
│   ├── xaml/
│   │   └── MainWindow.xaml          # Modern Dark WPF UI layout
│   └── app.ps1                      # Development bootstrapper and UI event controller
├── release/
│   └── diskman.ps1                  # Monolithic compiled standalone distribution script
├── Compile.ps1                      # Packaging script that inlines modules + XAML into release/diskman.ps1
├── test_verify.ps1                  # Automated verification and AST syntax check suite
├── run.bat                          # Launcher script with auto-elevation check
├── CONTRIBUTING.md                  # Contribution guide and target schema
├── LICENSE                          # MIT License
└── SECURITY.md                      # Security and path safety policy
```

---

## Development & Testing

### Running Tests
To verify all safety barriers, servicing detection, module functions, and AST syntax validity:

```powershell
powershell -ExecutionPolicy Bypass -File .\test_verify.ps1
```

### Compiling the Standalone Release
When modifying files in `src/`, compile the single-file distribution bundle:

```powershell
powershell -ExecutionPolicy Bypass -File .\Compile.ps1
```

This compiles all modules, embeds `MainWindow.xaml`, and packages `src/app.ps1` into `release/diskman.ps1`.

---

## Contributing

Contributions are very welcome! Diskman is designed to be easily extensible. Adding a new cache directory or application target only takes a few lines of code in `src/modules/Invoke-SmartCleanup.ps1`.

Check out our [Contributing Guide](CONTRIBUTING.md) for guidelines on target definitions and safety levels.

---

## License

This project is licensed under the [MIT License](LICENSE).
