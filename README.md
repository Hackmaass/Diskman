# ⚡ Diskman - C: Drive Trash & Smart Storage Cleaner

> A blazing-fast, modern, zero-dependency Windows C: drive trash hunter and storage cleaner built on **PowerShell + WPF (XAML)**.

---

## 🌟 Highlights

- 🚀 **Dedicated C: Drive Junk Purger**: Deeply scans 36 discrete cache and trash repositories across Windows, Gaming/GPU, Developer tools, and Applications.
- 🎮 **Massive Gaming & GPU Cache Hunter**: Reclaims tens of gigabytes of leftover DirectX shader caches (`NVIDIA DXCache`, `AMD DxCache`, `DirectX D3DSCache`), launcher caches (`Steam`, `Epic Games`, `EA App`, `Battle.net`, `Ubisoft`), and game engines (`Unreal Engine DDC`, `Unity`).
- 🛡️ **Zero-Risk Protection Engine**: Hardened `Test-PathSafety` protection barrier permanently shields core OS system roots, boot files, personal user directories (Desktop, Documents, Pictures), and browser credentials (passwords, cookies, bookmarks).
- 📂 **Seamless Windows File Explorer Integration**: Inspect any detected junk category or individual file directly in Windows File Explorer before deciding to clear it out.
- 🔍 **In-App File Inspector**: Drill down into any cleanable category within Diskman to view individual file names, paths, and sizes.
- 🧹 **1-Click Smart Cleanup**: Bulk or single-category purge with automatic Windows service lock releasing (`wuauserv`, `bits`, `DoSvc`) and non-blocking live terminal logging.
- 🎯 **C: Large Junk Hunter**: Detects oversized installers (`.exe`, `.msi`, `.iso`), large archives, and leftover dumps consuming gigabytes on `C:\`.
- 📊 **Real-time C: Drive Storage Visualizer**: Live capacity meter, used vs. free storage tracker, and estimated reclaimable space indicators.
- 🎨 **Modern Fluent Dark Design**: Sleek dark UI with responsive controls, category filtering, and real-time execution logs.

---

## ⚡ 1-Click Launch (Online Distribution)

Launch **Diskman** directly in an elevated PowerShell terminal:

```powershell
irm https://raw.githubusercontent.com/Hackmaass/Diskman/main/release/diskman.ps1 | iex
```

---

## 🛠️ Local Development & Running

### 1. Run Locally
Double-click `run.bat` (which automatically prompts for Administrator elevation) or run in PowerShell:
```powershell
powershell -STA -ExecutionPolicy Bypass -File .\src\app.ps1
```

### 2. Build the Standalone Distribution Bundle
Run the compiler script to generate the self-contained `release/diskman.ps1`:
```powershell
powershell -ExecutionPolicy Bypass -File .\Compile.ps1
```

### 3. Run Automated Tests
```powershell
powershell -ExecutionPolicy Bypass -File .\test_verify.ps1
```

---

## 📁 Project Structure

```
diskman/
├── src/
│   ├── xaml/
│   │   └── MainWindow.xaml          # Modern Fluent Dark WPF GUI (C: Cleaner & Inspector)
│   ├── modules/
│   │   ├── 00-Utils.ps1             # Formatting, metric helpers, and Test-PathSafety guard engine
│   │   ├── Get-DriveMetrics.ps1     # C: Drive live capacity and health metrics
│   │   ├── Invoke-SmartCleanup.ps1  # 36 C: Junk targets, inspection, and safe purging
│   │   ├── Invoke-ShellActions.ps1  # File Explorer reveal and safe recycle bin actions
│   │   ├── Find-LargeFiles.ps1      # C: Large files and installers seeker
│   │   └── Start-FolderScan.ps1     # High-speed directory analyzer and drilldown
│   └── app.ps1                      # Development bootstrapper and UI controller
├── release/
│   └── diskman.ps1                  # Standalone compiled distribution file
├── Compile.ps1                      # Packaging compiler
├── test_verify.ps1                  # Automated verification test suite
├── run.bat                          # 1-click Windows launcher (with auto-elevation)
└── README.md
```

---

## 🛡️ Safety & Privacy Guarantees
- **Safety First**: Deletions default to safe cache purging and the **Windows Recycle Bin**.
- **System Protection**: Critical OS roots (`C:\Windows`, `C:\Program Files`, `C:\Users`) and boot files are protected against accidental deletion.
- **Credential Privacy**: Never touches browser passwords, cookies, bookmarks, or history.
- **100% Zero-Telemetry**: No external network requests, advertising, or background daemons.
