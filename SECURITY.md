# Security & Safety Policy

Diskman operates directly on file systems to inspect and purge temporary caches, logs, and leftovers. We prioritize operating system integrity and non-destructive operations above all else.

## Safety Architecture & Defense-in-Depth

Diskman incorporates a multi-layer safety guard engine (`Test-PathSafety`) built on a **Fail-Closed** design:

1. **Hard System Servicing Boundaries**:
   - Critical servicing directories (`WinSxS`, `servicing\Packages`, `servicing\Sessions`, `System32\catroot`, `System32\catroot2`, `System32\wbem\Repository`, `System32\config`, `Boot`, `EFI`, `Recovery`, `System Volume Information`) cannot be deleted or targeted by cleanup routines.
   - Hierarchy containment checks block all child items and relative path traversal attempts (`..\`, case variations, trailing separators).
   - The parent `SoftwareDistribution` directory and metadata databases (`DataStore.edb`, logs) are strictly protected.

2. **State-Aware Windows Servicing Guard**:
   - Before allowing cleanup of downloaded update files (`SoftwareDistribution\Download`), Diskman inspects Windows servicing services (`wuauserv`, `TrustedInstaller`, `UsoSvc`, `WaaSMedicSvc`, `BITS`) and registry pending-reboot/staging keys.
   - If Windows is actively servicing, staging, installing, or awaiting a reboot, the cleanup is safely skipped without force-stopping services.
   - Diskman does **not** perform Windows Update reset operations (such as deleting catroot2 or wiping databases) during normal disk cleanup.

3. **Reparse Point & Symlink Isolation**:
   - Reparse points, symbolic links, and directory junctions are detected and never traversed recursively. Deletions never follow links into external or protected directories.

4. **User Personal Data Protection**:
   - User profile roots and personal directories (`Desktop`, `Documents`, `Downloads`, `Pictures`, `Music`, `Videos`, `OneDrive`, `Contacts`, `Favorites`, `Saved Games`) are permanently blocked from bulk deletion.

5. **Identity & Credential Guard**:
   - Browser credential and session files (`Login Data`, `Cookies`, `History`, `Bookmarks`, `Preferences`, `Web Data`, `Local State`) are explicitly safeguarded.

6. **Boot & Kernel Protection**:
   - Critical virtual memory and boot files (`pagefile.sys`, `swapfile.sys`, `hiberfil.sys`, `bootmgr`, `bootstat.dat`, `BCD`) are protected.

7. **Fail-Closed Default**:
   - Any unknown path, unresolvable path, access error, or unexpected exception causes `Test-PathSafety` to return `Safe = $false`.

---

## Supported Versions

Only the latest code on the `main` branch and the latest official releases receive active maintenance and security updates.

| Version | Supported |
| :--- | :--- |
| Latest (`main` branch) | :white_check_mark: |
| < 1.0.0 | :x: |

---

## Reporting a Vulnerability or Safety Issue

If you discover a path traversal bypass, a safety check oversight, or potential data loss risk:

1. **Do not create a public issue** with exploit steps or unsafe path demonstrations.
2. Open a private security report via GitHub's [Security Advisory feature](https://github.com/Hackmaass/Diskman/security/advisories) or contact the project maintainer directly.
3. Please include:
   - Affected function / module (e.g., `Test-PathSafety`, `Invoke-SmartCleanup`)
   - Operating System build and PowerShell version
   - Steps to reproduce or the specific path logic that caused unexpected behavior
   - Suggested remediation (if known)

We will review, acknowledge, and resolve verified safety or security issues as quickly as possible.
