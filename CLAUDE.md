# winget-app-setup — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

---

## Platform

This repo targets **Windows only**. All scripts are PowerShell.

- Use PowerShell 7+ syntax
- Use Pester for all unit tests (`Test-WingetAppInstall.Tests.ps1`)
- Claude Code runs on macOS — it cannot execute these scripts directly; test on Windows or a VM

---

## Key Files

| File | Purpose |
|------|---------|
| `winget-app-install.ps1` | Main install script — installs apps via winget, sets up scheduled updates |
| `Update-InstalledApps.ps1` | Scheduled update helper, runs as a standalone task |
| `winget-app-uninstall.ps1` | Uninstall helper |
| `Test-WingetAppInstall.Tests.ps1` | Pester test suite for the main install script |

---

## Testing

- Run tests with Pester: `Invoke-Pester ./Test-WingetAppInstall.Tests.ps1`
- Mock all external calls (winget, scheduled task cmdlets, registry) — never rely on real system state in unit tests
- Use unconditional `Mock` in `BeforeEach`, not conditional `if (-not (Get-Command...))` stubs

---

## Winget Notes

- Exit code `0x80073d19` is a transient Windows session error — retry with backoff via `Invoke-WingetInstallWithSessionRetry`
- Always capture `$LASTEXITCODE` immediately after a winget call — it goes stale fast
- Validate package IDs with regex before trusting winget output: `^[\w][\w.\-]+\.[\w][\w.\-]+`
