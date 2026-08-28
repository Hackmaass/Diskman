# ⚡ Diskman - Modern Windows Storage Analyzer & Smart Storage Cleaner

> A blazing-fast, modern, zero-dependency Windows storage explorer and smart cleaner built on **PowerShell + WPF (XAML)**, inspired by the architecture of [`ChrisTitusTech/winutil`](https://github.com/ChrisTitusTech/winutil).

---

## 🌟 Highlights

- 🚀 **Zero Dependencies & Zero Installation**: Runs natively on 100% of Windows 10 & 11 computers out of the box (no Python, Node.js, or `.exe` installers required).
- 📊 **Real-time Drive Visualizer**: Live disk capacity meters, health indicators, and free space trackers for all mounted partitions (`C:`, `D:`, `E:`, USB drives).
- 📂 **Interactive Directory Drilldown**: Deep dive into subfolders with breadcrumb navigation, size percentages, and instant file counts.
- 🧹 **Smart One-Click Cleaner**: Safe purge of Windows temp files, developer caches (`pip`, `npm`, `yarn`, `__pycache__`), crash dumps, browser caches, and Windows Recycle Bin.
- 🎯 **Large & Stale File Hunter**: Fast seeker for gigabyte-sized files (>100MB, >500MB, >1GB, >5GB) with media categorization (Videos, AI Models, ISOs, Archives, Installers) and direct **Reveal in File Explorer** / **Safe Recycle Bin** actions.
- 🎨 **Modern Fluent Dark Design**: Custom XAML dark theme with rounded glassmorphism cards and smooth controls.

---

## ⚡ 1-Click Launch (Online Distribution)

Anyone on Windows can launch **Diskman** directly in an elevated PowerShell terminal with a single command:

```powershell
irm https://raw.githubusercontent.com/<your-username>/diskman/main/release/diskman.ps1 | iex
```

---

## 🛠️ Local Development & Running

### 1. Run Locally
Double-click `run.bat` or run in PowerShell:
```powershell
powershell -STA -ExecutionPolicy Bypass -File .\src\app.ps1
```

### 2. Build the Standalone Distribution Bundle
Run the compiler script to generate the self-contained `release/diskman.ps1`:
```powershell
powershell -ExecutionPolicy Bypass -File .\Compile.ps1
```

---

## 📁 Project Structure

```
diskman/
├── src/
│   ├── xaml/
│   │   └── MainWindow.xaml          # Modern Fluent Dark WPF GUI
│   ├── modules/
│   │   ├── Get-DriveMetrics.ps1     # Drive capacity, free space, and volume metadata
│   │   ├── Start-FolderScan.ps1     # High-speed directory analyzer and drilldown
│   │   ├── Invoke-SmartCleanup.ps1  # Smart cleaner (Temp, Pip/NPM cache, Logs, Recycle Bin)
│   │   ├── Find-LargeFiles.ps1      # Large & stale file seeker
│   │   └── Invoke-ShellActions.ps1  # Reveal in Explorer & Safe Recycle Bin integration
│   └── app.ps1                      # Development bootstrapper
├── release/
│   └── diskman.ps1                 # Standalone compiled distribution file
├── Compile.ps1                      # WinUtil-style compiler
├── run.bat                          # 1-click Windows launcher
└── README.md
```

---

## 🛡️ Safety & Privacy
- **Safe Mode**: File deletions default to the **Windows Recycle Bin**.
- **System Protection**: Critical OS roots (`C:\Windows`, `C:\Program Files`) are blacklisted from bulk deletion.
- **100% Open Source**: No telemetry, no background daemons.
