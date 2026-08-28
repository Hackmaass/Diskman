---
name: New Cleanup Target Proposal
about: Suggest a new cache, log, or junk directory for Diskman to clean
title: '[TARGET] '
labels: ['target-proposal', 'enhancement']
assignees: ''
---

## Application / Tool Name
What application, game launcher, developer tool, or system component creates this cache? (e.g. *Docker Desktop, IntelliJ IDEA, DaVinci Resolve, Epic Games*)

## Cache / Junk Directory Path
What path(s) does the application store its temporary/cache data in?
- Example: `%LOCALAPPDATA%\Docker\wsl\data\cache` or `%APPDATA%\JetBrains\...\caches`

## Safety Verification
- [ ] Is it 100% safe to delete this folder while the application is closed?
- [ ] Does the application automatically rebuild or recreate these files when needed?
- [ ] Does deleting this folder preserve user settings, logins, projects, and saved data?

## Typical Space Reclaimable
Approximately how much space does this cache consume on a typical system? (e.g., 500 MB – 20+ GB)

## Target Group
Which category does this target belong to?
- [ ] Windows & System
- [ ] Gaming & GPU
- [ ] Developer Caches
- [ ] Browser & App Caches
- [ ] Other

## Additional Information
Any notes on whether specific processes need to be closed first, or if administrator elevation is required:
