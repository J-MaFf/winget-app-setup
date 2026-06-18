# STATUS

## What This Is

`winget-app-setup` is a PowerShell automation suite for provisioning and maintaining a curated set of Windows applications with [winget](https://learn.microsoft.com/windows/package-manager/). The main installer trusts the required winget sources, self-heals broken source registrations, elevates when needed, installs or updates the curated app list, and can register a scheduled task for ongoing update checks. A companion uninstaller, an update helper, and a comprehensive Pester test suite round out the toolset. The scripts target **Windows PowerShell / PowerShell 7 on Windows**; they cannot run end-to-end on Linux or macOS because they depend on `winget`, the `Microsoft.WinGet.Client` module, and Windows-only cmdlets.

## Current State — 2026-06-16

Healthy. The `2026-review` integration branch is collecting the fixes from the 2026 code review (#134–#137). Each fix lands via its own squash-merged PR; an aggregate `2026-review → main` PR is open for human review and is intentionally **not** merged. All changed scripts parse clean under the PowerShell AST parser on pwsh 7, and the Pester suite's pass/fail set is unchanged from baseline on Linux (the only failures are pre-existing Windows-only environment limitations).

### Components

| File | Description |
| --- | --- |
| `winget-app-install.ps1` | Main installer: source trust/repair, elevation, curated app install/update, scheduled-update management, Windows Terminal configuration. |
| `winget-app-uninstall.ps1` | Companion script that uninstalls a configurable list of applications. |
| `Update-InstalledApps.ps1` | Standalone update helper invoked by the scheduled update task. |
| `Test-WingetAppInstall.Tests.ps1` | Pester 5 unit-test suite; dot-sources the installer so tests exercise the real implementation. |
| `Test-WindowsTerminalConfiguration.ps1` | Smoke-test validation for the Windows Terminal default-shell configuration. |
| `readme.md` | Quick-start run instructions (clone-and-run and one-line-run). |
| `CHANGELOG.md` | Keep a Changelog history. |

### Resolved Issues

| Issue | Description | PR |
| --- | --- | --- |
| [#134](https://github.com/J-MaFf/winget-app-setup/issues/134) | Double winget command execution in `Invoke-WingetCommand` | [#138](https://github.com/J-MaFf/winget-app-setup/pull/138) |
| [#135](https://github.com/J-MaFf/winget-app-setup/issues/135) | Pester tests copied function bodies instead of dot-sourcing the script | [#139](https://github.com/J-MaFf/winget-app-setup/pull/139) |
| [#136](https://github.com/J-MaFf/winget-app-setup/issues/136) | Missing `STATUS.md` and README/CHANGELOG execution-policy mismatch | [#140](https://github.com/J-MaFf/winget-app-setup/pull/140) |
| [#137](https://github.com/J-MaFf/winget-app-setup/issues/137) | Renamed `Test-Source-IsTrusted` to `Test-WingetSourceTrusted` for verb-noun compliance | this PR |

### Open Issues

None tracked for the 2026-review cycle beyond #134–#137 above.

## Natural Next Steps

- Review and merge the aggregate `2026-review → main` PR once all four fixes are verified on a Windows machine.
- Run the `windows-latest` Pester CI workflow (or a local Windows run) to confirm the winget-dependent tests pass — they cannot be exercised on the Linux dev VM.
- Consider expanding test coverage for the scheduled-update and source-repair paths so more of the suite is mockable cross-platform.
- Cut a tagged release and move the `[Unreleased]` CHANGELOG entries under a versioned heading.

## Prerequisites to Run

- **Windows 10/11** with [App Installer / winget](https://www.microsoft.com/p/app-installer/9nblggh4nns1) available.
- **PowerShell 7+** recommended (Windows PowerShell 5.1 also works for the installer).
- Permission to temporarily relax the execution policy for the current process, e.g.:
  ```powershell
  Set-ExecutionPolicy Unrestricted -Scope Process -Force
  ```
- To run the test suite: **Pester 5.x** (`Install-Module Pester -MinimumVersion 5.0`), then `Invoke-Pester -Path ./Test-WingetAppInstall.Tests.ps1`.
