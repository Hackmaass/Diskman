# Security Policy

Diskman operates directly on file systems to inspect and purge temporary caches, logs, and leftovers. We prioritize safety and non-destructive operations above all else.

## Safety Philosophy

Diskman includes an integrated safety guard engine (`Test-PathSafety`) designed to prevent accidental deletion or corruption:

1. **System Root Shielding**: Paths in core Windows roots (`C:\Windows\System32`, `C:\Windows\WinSxS`, `C:\Program Files`, etc.) cannot be deleted.
2. **User Data Protection**: User personal directories (`Desktop`, `Documents`, `Pictures`, `Music`, `Videos`, `OneDrive`, etc.) are blocked from deletion routines.
3. **Identity & Credential Guard**: Sensitive browser credential files (`Login Data`, `Cookies`, `Web Data`, `Bookmarks`, `Preferences`) are explicitly safeguarded.
4. **Boot & Kernel Protection**: Critical files such as `pagefile.sys`, `swapfile.sys`, `hiberfil.sys`, and `bootmgr` are protected.
5. **Safe Fallback**: Where applicable, large file removal uses the Windows Recycle Bin rather than immediate unrecoverable deletion.

## Supported Versions

Only the latest code on the `main` branch and the latest official releases receive active maintenance and security updates.

| Version | Supported |
| :--- | :--- |
| Latest (`main` branch) | :white_check_mark: |
| < 1.0.0 | :x: |

## Reporting a Vulnerability or Safety Issue

If you discover a path traversal bypass, a safety check oversight, or potential data loss risk:

1. **Do not create a public issue** with exploit steps or unsafe path demonstrations.
2. Open a private security report via GitHub's [Security Advisory feature](https://github.com/Hackmaass/Diskman/security/advisories) or contact the project maintainer directly.
3. Please include:
   - Affected function / module (e.g., `Test-PathSafety`, `Invoke-SmartCleanup`)
   - Operating System build and PowerShell version
   - Steps to reproduce or the specific path logic that caused unexpected behavior
   - Suggested remediation (if known)

We will review, acknowledge, and resolve any verified safety or security issues as quickly as possible.
