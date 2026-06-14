# Project Status

## What This Is

`winget-app-setup` is a Windows-only PowerShell toolkit that installs a curated list of
applications via winget, configures Windows Terminal, and manages scheduled/on-demand app
updates. End users run a single self-contained `winget-app-install.ps1`, either locally or via a
remote `irm | iex` one-liner. Internally, the installer's logic now lives in the reusable
`WingetAppSetup` module, and the single-file script is generated from it by a build step.

## Current State — 2026-06-14

`main` is clean. The install logic has been refactored from a 2,100-line monolith into a module
([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)); the distributable script is a
generated build artifact that remains byte-for-byte behaviour-equivalent to the previous monolith.

### Components

| Path | Description |
|------|-------------|
| `WingetAppSetup/` | Source-of-truth PowerShell module (`.psd1` manifest + `.psm1` loader) |
| `WingetAppSetup/Public/` | Exported functions: logging, winget core, app validation, scheduled updates, Windows Terminal config, install orchestration |
| `WingetAppSetup/Private/` | Internal helpers: environment/PATH, elevation, graphical tools |
| `build/Build-WingetInstallScript.ps1` | Concatenates the module + entry fragments into `winget-app-install.ps1` |
| `build/fragments/` | `head.ps1` (PSScriptInfo, help, `param`) and `tail.ps1` (entry-point dispatch) |
| `winget-app-install.ps1` | **Generated** single-file installer for local and `irm \| iex` use — do not edit by hand |
| `Update-InstalledApps.ps1` | Standalone scheduled-update helper task |
| `winget-app-uninstall.ps1` | Uninstall helper |
| `Test-WingetAppInstall.Tests.ps1` | Pester suite; loads the module once |

### Resolved Issues

| Issue | Description | PR |
|-------|-------------|----|
| [#106](https://github.com/J-MaFf/winget-app-setup/issues/106) | Split `winget-app-install.ps1` into a module with a generated bundle | _this PR_ |

### Open Issues

- Migrate `winget-app-uninstall.ps1` and `Update-InstalledApps.ps1` to consume the `WingetAppSetup` module (removes their duplicated logging/config functions) — follow-up to #106.
- Pre-existing test rot: orphaned `Describe` blocks for functions that no longer exist (`Test-AndSetExecutionPolicy`, `Invoke-WingetInstallWithRetry`, `Test-SystemRequirements`) should be removed or backed by real implementations.

## Natural Next Steps

- Wire `build/Build-WingetInstallScript.ps1 -Check` into CI / a pre-commit hook so the generated `winget-app-install.ps1` can never drift from the module.
- Open the two follow-up issues listed above.

## Prerequisites to Run

- Windows with PowerShell 7+ (`pwsh`) and winget (App Installer).
- Run the installer: `powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1`.
- Run tests: `Invoke-Pester ./Test-WingetAppInstall.Tests.ps1`.
- Regenerate the installer after editing the module: `pwsh -File ./build/Build-WingetInstallScript.ps1`.
