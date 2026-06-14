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
| `WingetAppSetup/` | **Source of truth** — PowerShell module (`.psd1` manifest + `.psm1` loader) holding all install logic in `Public/` and `Private/` |
| `winget-app-install.ps1` | **Generated** single-file installer (local + `irm \| iex`). Do not edit by hand — edit the module and rebuild |
| `build/Build-WingetInstallScript.ps1` | Regenerates `winget-app-install.ps1` from the module (`-Check` verifies it is in sync) |
| `Update-InstalledApps.ps1` | Scheduled update helper, runs as a standalone task |
| `winget-app-uninstall.ps1` | Uninstall helper |
| `Test-WingetAppInstall.Tests.ps1` | Pester test suite; loads the module once |

---

## Module → script build

- All install logic lives in `WingetAppSetup/Public/*.ps1` and `WingetAppSetup/Private/*.ps1`.
- `winget-app-install.ps1` is assembled from those files plus `build/fragments/{head,tail}.ps1`. Never hand-edit it.
- After changing the module, run `pwsh -File ./build/Build-WingetInstallScript.ps1` to regenerate, and commit both.

---

## Testing

- Run tests with Pester: `Invoke-Pester ./Test-WingetAppInstall.Tests.ps1`
- The suite mocks all external/Windows calls, so it runs on Linux/macOS too — though winget/`Get-WinGetPackage`/`Test-NetConnection`-dependent tests only pass on Windows where those cmdlets exist.
- The top-level `BeforeAll` dot-sources the module's function files once; do not re-declare production functions inline in `Describe` blocks (that reintroduces drift). Short test-double stubs for orchestration tests are fine.
- Mock all external calls (winget, scheduled task cmdlets, registry) — never rely on real system state in unit tests
- Use unconditional `Mock` in `BeforeEach`, not conditional `if (-not (Get-Command...))` stubs

---

## Winget Notes

- Exit code `0x80073d19` is a transient Windows session error. It is mitigated by initializing winget sources in the user context before elevation (`Initialize-WingetSourcesForUser`, issues #104/#105); any install that still fails is retried once in the final retry pass of `Invoke-WingetInstall`. (There is no dedicated backoff-retry function.)
- Always capture `$LASTEXITCODE` immediately after a winget call — it goes stale fast
- Validate package IDs with regex before trusting winget output: `^[\w][\w.\-]+\.[\w][\w.\-]+`
