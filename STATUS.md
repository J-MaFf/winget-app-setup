# STATUS

## What This Is

`winget-app-setup` is a Windows-only PowerShell toolkit that installs a curated list of
applications via winget, configures Windows Terminal, and manages scheduled/on-demand app
updates. End users run a single self-contained `winget-app-install.ps1`, either locally or via a
remote `irm | iex` one-liner. Internally, the installer's logic now lives in the reusable
`WingetAppSetup` module, and the single-file script is generated from it by a build step. The
scripts target **Windows PowerShell / PowerShell 7 on Windows**; they cannot run end-to-end on
Linux or macOS because they depend on `winget`, the `Microsoft.WinGet.Client` module, and
Windows-only cmdlets.

## Current State — 2026-06-18

Healthy. The install logic has been refactored from a 2,100-line monolith into a module
([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)), and the distributable script is a
generated build artifact that remains byte-for-byte behaviour-equivalent to the previous monolith.
The 2026 code-review batch (#134–#137) has also been applied: all changed scripts parse clean under
the PowerShell AST parser on pwsh 7, and the Pester suite's pass/fail set is unchanged from
baseline on Linux (the only failures are pre-existing Windows-only environment limitations).

### Components

| Path | Description |
|------|-------------|
| `WingetAppSetup/` | Source-of-truth PowerShell module (`.psd1` manifest + `.psm1` loader) |
| `WingetAppSetup/Public/` | Exported functions: logging, winget core, app validation, scheduled updates, Windows Terminal config, install orchestration |
| `WingetAppSetup/Private/` | Internal helpers: environment/PATH, elevation, graphical tools |
| `build/Build-WingetInstallScript.ps1` | Concatenates the module + entry fragments into `winget-app-install.ps1` |
| `build/fragments/` | `head.ps1` (PSScriptInfo, help, `param`) and `tail.ps1` (entry-point dispatch) |
| `winget-app-install.ps1` | **Generated** single-file installer for local and `irm \| iex` use — do not edit by hand |
| `Update-InstalledApps.ps1` | Standalone scheduled-update helper task; imports the module deployed beside it in `%APPDATA%` |
| `winget-app-uninstall.ps1` | Uninstall helper; imports the module from the repo |
| `Test-WingetAppInstall.Tests.ps1` | Pester suite; loads the module once |
| `Test-WindowsTerminalConfiguration.ps1` | Smoke-test validation for the Windows Terminal default-shell configuration. |
| `readme.md` | Quick-start run instructions (clone-and-run and one-line-run). |
| `CHANGELOG.md` | Keep a Changelog history. |

### Resolved Issues

| Issue | Description | PR |
|-------|-------------|----|
| [#106](https://github.com/J-MaFf/winget-app-setup/issues/106) | Split `winget-app-install.ps1` into a module with a generated bundle | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#110](https://github.com/J-MaFf/winget-app-setup/issues/110) | Migrate uninstall + update-helper scripts to consume the module | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#111](https://github.com/J-MaFf/winget-app-setup/issues/111) | Remove orphaned tests for functions that no longer exist | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#117](https://github.com/J-MaFf/winget-app-setup/issues/117) | `-WhatIf` dropped the flag on elevation and ran a real install | [#116](https://github.com/J-MaFf/winget-app-setup/pull/116) |
| [#120](https://github.com/J-MaFf/winget-app-setup/issues/120) | Post-install update phase could hang indefinitely on one package | [#121](https://github.com/J-MaFf/winget-app-setup/pull/121) |
| [#134](https://github.com/J-MaFf/winget-app-setup/issues/134) | Double winget command execution in `Invoke-WingetCommand` | [#138](https://github.com/J-MaFf/winget-app-setup/pull/138) |
| [#135](https://github.com/J-MaFf/winget-app-setup/issues/135) | Pester tests copied function bodies instead of dot-sourcing the script | [#139](https://github.com/J-MaFf/winget-app-setup/pull/139) |
| [#136](https://github.com/J-MaFf/winget-app-setup/issues/136) | Missing `STATUS.md` and README/CHANGELOG execution-policy mismatch | [#140](https://github.com/J-MaFf/winget-app-setup/pull/140) |
| [#137](https://github.com/J-MaFf/winget-app-setup/issues/137) | Renamed `Test-Source-IsTrusted` to `Test-WingetSourceTrusted` for verb-noun compliance | [#142](https://github.com/J-MaFf/winget-app-setup/pull/142) |

### Open Issues

None.

## Natural Next Steps

- Wire `build/Build-WingetInstallScript.ps1 -Check` into CI / a pre-commit hook so the generated `winget-app-install.ps1` can never drift from the module.
- Run the `windows-latest` Pester CI workflow (or a local Windows run) to confirm the winget-dependent tests pass — they cannot be exercised on the Linux dev VM.
- Cut a tagged release and move the `[Unreleased]` CHANGELOG entries under a versioned heading.
- Open the follow-up migration issue listed above.

## Prerequisites to Run

- **Windows 10/11** with [App Installer / winget](https://www.microsoft.com/p/app-installer/9nblggh4nns1) available.
- **PowerShell 7+** recommended (Windows PowerShell 5.1 also works for the installer).
- Permission to temporarily relax the execution policy for the current process, e.g.:
  ```powershell
  Set-ExecutionPolicy Unrestricted -Scope Process -Force
  ```
- Run the installer: `powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1`.
- Run tests: `Invoke-Pester ./Test-WingetAppInstall.Tests.ps1`.
- Regenerate the installer after editing the module: `pwsh -File ./build/Build-WingetInstallScript.ps1`.
