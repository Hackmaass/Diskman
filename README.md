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
- **Windows Servicing & Update Logs** (`SoftwareDistribution\Download`, `CBS`, `DISM`, crash dumps) left behind after system updates.

The built-in Windows *Disk Cleanup* (`cleanmgr.exe`) misses most of these modern caches. Meanwhile, many third-party cleaning utilities are closed-source, require full installers, run unwanted background services, or bundle telemetry.

**Diskman** gives you full visibility and control:
- **Zero Install, Zero Bloat**: A lightweight PowerShell + WPF application that runs out-of-the-box on any Windows 10 or 11 system.
- **Total Transparency**: Inspect every detected file path and size inside the UI or reveal it directly in Windows File Explorer before deleting.
- **Safe by Design**: Built-in safety barriers prevent accidental deletion of critical OS files, user personal folders, or browser login sessions.

---

## Quick Start

### Option 1: Launch Directly in PowerShell (No Download Needed)
Open PowerShell (as Administrator for full cleanup capabilities) and run:

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

### 🧹 Smart Cache & Junk Cleaner
Scans over 36 distinct storage categories across your system:
- **Windows & System**: User Temp, System Temp, Windows Update cache, Delivery Optimization files, Crash dumps, WER telemetry logs, CBS/DISM servicing logs.
- **Gaming & GPU Caches**: NVIDIA DXCache/GLCache, AMD Radeon shader cache, Intel Graphics shader cache, Steam web cache, Epic Games cache, EA App cache, Ubisoft Connect cache, Battle.net cache, Riot Client logs, Unreal Engine DDC, Unity package cache.
- **Developer Stores**: Python `pip` cache, Node.js `npm` / `yarn` caches, NuGet package stores, Gradle build cache, Rust Cargo crate cache.
- **Applications & Browsers**: Chrome web cache, Edge web cache, Brave cache, Discord media cache, Spotify offline cache, VS Code cache, Adobe Premiere media cache, Telegram Desktop cache.
- **Recycle Bin**: Instant overview and purge of `C:\$Recycle.Bin`.

### 🔍 In-App Drilldown & Explorer Reveal
- Click any cleanable category to inspect individual file names, paths, and sizes in the item inspector.
- Jump directly to any directory in **Windows File Explorer** to inspect contents manually before deciding to purge.

### 🎯 C: Drive Large File Seeker
- Quickly scan `C:\` for oversized installer packages (`.exe`, `.msi`), disk images (`.iso`, `.vhd`), archives, media files, and large diagnostic logs.
- Filter by minimum file size (100 MB, 500 MB, 1 GB, 5 GB) and file category.
- Safely send unwanted large files to the **Windows Recycle Bin** rather than permanently destroying them.

### 🛡️ Built-in Safety Guard Engine (`Test-PathSafety`)
- **System Protection**: Hardened rules permanently block deletions targeting critical Windows roots (`C:\Windows`, `C:\Program Files`, `C:\ProgramData`, `System Volume Information`).
- **User Data Guard**: Protects personal user directories (`Desktop`, `Documents`, `Pictures`, `Music`, `Videos`, `OneDrive`).
- **Credential & Identity Guard**: Strictly protects browser logins, cookies, history, and passwords.
- **Boot File Protection**: Safeguards virtual memory files (`pagefile.sys`, `swapfile.sys`, `hiberfil.sys`, `bootmgr`).

---

## Project Structure

Diskman is organized into modular scripts for clean development and compiles into a single, self-contained release script:

```text
Diskman/
├── src/
│   ├── modules/
│   │   ├── 00-Utils.ps1             # Formatting and Test-PathSafety guard engine
│   │   ├── Get-DriveMetrics.ps1     # C: drive capacity and storage health metrics
│   │   ├── Invoke-SmartCleanup.ps1  # 36+ cleanup target definitions and purge routines
│   │   ├── Invoke-ShellActions.ps1  # File Explorer reveal and Recycle Bin actions
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
├── CONTRIBUTING.md                  # Contribution guide and tutorial on adding new targets
├── LICENSE                          # MIT License
└── SECURITY.md                      # Security and path safety policy
```

---

## Development & Testing

### Running Tests
To verify all module functions, scanner routines, shell actions, and AST syntax validity:

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

Check out our [Contributing Guide](CONTRIBUTING.md) for:
- A step-by-step tutorial on adding new cleanup targets
- Instructions on modifying the WPF UI
- Pull request workflows and coding standards

---

## License

This project is licensed under the [MIT License](LICENSE).
