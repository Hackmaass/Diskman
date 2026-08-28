# Contributing to Diskman

Thank you for your interest in contributing to **Diskman**! We're excited to build a fast, transparent, and completely open-source storage manager for Windows.

Whether you want to add support for a new game launcher cache, add an IDE/developer junk cleaner, improve the WPF user interface, optimize scanning algorithms, or fix a bug, your contributions are welcome.

---

## Table of Contents

1. [Project Principles](#project-principles)
2. [Development Environment](#development-environment)
3. [Repository Architecture](#repository-architecture)
4. [How to Add a New Cleanup Target](#how-to-add-a-new-cleanup-target)
5. [How to Modify the UI (WPF & XAML)](#how-to-modify-the-ui-wpf--xaml)
6. [Building & Testing](#building--testing)
7. [Submitting a Pull Request](#submitting-a-pull-request)
8. [Good First Issues & Ideas](#good-first-issues--ideas)

---

## Project Principles

Before writing code, keep these core principles in mind:

- **Zero External Dependencies**: Diskman relies only on built-in Windows PowerShell (5.1+ or PowerShell 7+) and WPF (XAML). We do not bundle Node.js, Electron, Python, or third-party executables.
- **Safety First**: Accidental data loss is unacceptable. Any new deletion logic must be strictly guarded against deleting user documents, OS system roots, boot files, or browser credentials via `Test-PathSafety`.
- **Modular in Development, Single-File in Release**: We write clean, decoupled modules in `src/modules/` and compile them into a self-contained `release/diskman.ps1` for easy one-line online execution.

---

## Development Environment

### Prerequisites
- **Operating System**: Windows 10 (Build 1809+) or Windows 11
- **Shell**: PowerShell 5.1 (Built into Windows) or PowerShell 7+
- **Git**: Installed and configured on your machine
- **Editor**: VS Code (recommended with the *PowerShell* extension) or any text editor

### Setup Steps
1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```powershell
   git clone https://github.com/<your-username>/Diskman.git
   cd Diskman
   ```
3. Run Diskman locally in development mode:
   ```powershell
   # Option A: Run the launcher with auto-elevation
   .\run.bat

   # Option B: Run directly via PowerShell (STA mode required for WPF)
   powershell -STA -ExecutionPolicy Bypass -File .\src\app.ps1
   ```

---

## Repository Architecture

```text
Diskman/
├── src/
│   ├── modules/
│   │   ├── 00-Utils.ps1             # Size formatting and Test-PathSafety guard engine
│   │   ├── Get-DriveMetrics.ps1     # C: Drive live volume capacity and health metrics
│   │   ├── Invoke-SmartCleanup.ps1  # Target catalogue, category scanner, and purge routines
│   │   ├── Invoke-ShellActions.ps1  # Windows File Explorer reveal and Recycle Bin helpers
│   │   ├── Find-LargeFiles.ps1      # Large file search and classification engine
│   │   └── Start-FolderScan.ps1     # High-speed directory analyzer and drilldown
│   ├── xaml/
│   │   └── MainWindow.xaml          # Modern Dark WPF GUI markup (Fluent-inspired layout)
│   └── app.ps1                      # Development bootstrapper and UI event controller
├── release/
│   └── diskman.ps1                  # Single-file compiled standalone bundle
├── Compile.ps1                      # Packaging compiler (inlines modules & XAML into release/diskman.ps1)
├── test_verify.ps1                  # Automated verification and AST syntax check suite
├── run.bat                          # Double-click launcher with auto-elevation check
├── README.md                        # Project documentation
├── CONTRIBUTING.md                  # Contributor guidelines
├── LICENSE                          # MIT License
└── SECURITY.md                      # Safety and security policy
```

---

## How to Add a New Cleanup Target

Adding a new cache, log, or temp directory is straightforward! All targets are defined in the `$targets` array inside `src/modules/Invoke-SmartCleanup.ps1` in the `Get-CleanableTargets` function.

### Target Schema

```powershell
@{
    Id            = 'YourTargetUniqueId'                 # Unique identifier (PascalCase)
    Group         = 'Developer Caches'                   # Group: 'Windows & System', 'Gaming & GPU', 'Developer Caches', 'Browser & App Caches', 'Recycle Bin'
    Category      = 'Your Target Display Name'           # Friendly title shown in the UI
    Icon          = '[TAG]'                              # Short icon tag (e.g., [DOCKER], [RUST], [STEAM])
    Path          = (Join-Path $localAppData 'YourApp\Cache') # Absolute path to cache directory
    Description   = 'Brief description of what files are stored here'
    Type          = 'DirectoryContents'                  # 'DirectoryContents' (cleans inside folder) or 'RecycleBin'
    SafetyLevel   = '100% Safe'                          # '100% Safe', 'Safe', or 'Optional'
    Recommended   = $true                                # Whether this target is pre-selected by default
    RequiresAdmin = $false                               # True if deletion requires elevated Administrator privileges
}
```

### Important Target Rules:
1. **Always use standard environment paths**:
   - `$localAppData` -> `C:\Users\<User>\AppData\Local`
   - `$appData` -> `C:\Users\<User>\AppData\Roaming`
   - `$userProfile` -> `C:\Users\<User>`
   - `C:\ProgramData` -> System-wide program data
2. **Never hardcode username paths** (e.g. do not write `C:\Users\John\...`).
3. **Verify Safety**: Ensure the target directory only contains regenerable caches or temporary logs, and does not contain configuration files, login sessions, or user projects.

---

## How to Modify the UI (WPF & XAML)

The user interface is defined in `src/xaml/MainWindow.xaml` using standard WPF XAML.

### UI Guidelines:
- **Dark Theme Palette**: We use a dark color scheme (`#121214` background, `#1A1B23` cards, `#6366F1` indigo accent, `#10B981` emerald green for safe actions, `#EF4444` rose red for destructive/large actions).
- **Naming Controls**: Any control that needs event handling or dynamic data binding in PowerShell should have an `x:Name="YourControlName"` attribute.
- **Event Binding**: Event handlers and button click events are wired up in `src/app.ps1` using the `Find-Control` helper (e.g., `$btnClean.Add_Click({ ... })`).

---

## Building & Testing

### 1. Run the Test Suite
Diskman includes an automated test runner that validates:
- Module ingestion
- Drive metrics retrieval
- Category scanner and file inspector functions
- Shell action functions
- Full compilation and PowerShell AST parser syntax checking

Run the test suite from PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\test_verify.ps1
```

### 2. Compile the Standalone Bundle
Whenever you make changes to files in `src/modules/`, `src/xaml/`, or `src/app.ps1`, compile the updated standalone script:
```powershell
powershell -ExecutionPolicy Bypass -File .\Compile.ps1
```
This updates `release/diskman.ps1`. Verify that the build completes successfully and reports 0 errors.

---

## Submitting a Pull Request

1. **Create a feature branch**:
   ```powershell
   git checkout -b feature/add-docker-cleanup-target
   ```
2. **Make your changes** in `src/`.
3. **Test & Compile**:
   - Run `.\test_verify.ps1` to ensure all tests pass.
   - Run `.\Compile.ps1` to re-generate `release/diskman.ps1`.
4. **Commit your changes** with a clear message:
   ```powershell
   git commit -m "feat(cleanup): add Docker Desktop WSL cache target"
   ```
5. **Push to your fork and submit a PR** to the `main` branch.
6. Fill out the Pull Request template checklist.

---

## Good First Issues & Ideas

Looking for ideas on what to contribute? Here are some high-impact areas:

- [ ] **Developer Tool Caches**:
  - Docker Desktop WSL cache (`%LOCALAPPDATA%\Docker`)
  - JetBrains IDE caches (`%LOCALAPPDATA%\JetBrains\*\caches`)
  - Go module cache (`%USERPROFILE%\go\pkg\mod\cache`)
  - Conda / Anaconda package cache (`%USERPROFILE%\.conda\pkgs`)
- [ ] **Game Launchers & Engines**:
  - GOG Galaxy web & installer cache
  - Xbox App / Gaming Services package cache
  - Godot Engine shader and import cache
- [ ] **UI & Feature Improvements**:
  - Search / filter bar for cleanable targets
  - Export cleanup summary report to CSV or Markdown
  - Scheduled maintenance / CLI mode arguments (e.g. `diskman.ps1 -ScanOnly -Json`)

---

## Code of Conduct

Please note that this project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.
