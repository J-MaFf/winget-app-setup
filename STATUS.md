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

## Current State — 2026-07-07

Healthy. **Removed the install-time inline update pass** ([#170](https://github.com/J-MaFf/winget-app-setup/issues/170)):
it upgraded every installed app synchronously as the elevating admin (slow, silent, mostly failing
under cross-user elevation) and is redundant now that WAU handles updates. The installer just installs
the curated apps and sets up WAU (which runs once immediately via `RUN_WAU=YES`, then weekly as SYSTEM).

**Auto-updates outsourced to Winget-AutoUpdate (WAU)** ([#168](https://github.com/J-MaFf/winget-app-setup/issues/168)):
the homegrown scheduled/on-demand updater (which ran non-elevated as the elevating admin and couldn't
do machine-scope updates) is removed — ~700 lines across `ScheduledUpdates.ps1`, `Update-InstalledApps.ps1`,
`Get-UpdateReport`, five one-liner switches, and ~10 tests. The installer now bootstraps a pinned,
SHA256-verified WAU 2.12.0 (weekly, SYSTEM + user-context, self-update disabled), and installer/uninstaller
run `Remove-LegacyScheduledUpdates` to migrate machines that already had the old task. The curated
cross-user install flow and install-time inline update pass are untouched.

**PowerShell now installs the latest version, version-agnostically** ([#166](https://github.com/J-MaFf/winget-app-setup/issues/166)):
`Install-PowerShellLatest` prefers the MSI while the current line ships one (≤ 7.6), and once the MSI
is gone (7.7+) installs the latest MSIX machine-wide — natively on Windows 24H2+ (build ≥ 26100) or via
`Add-AppxProvisionedPackage` DISM provisioning on older Windows (a non-packaged process, so it dodges
winget's packaged-context provisioning bug). No version is ever pinned. The scheduled-update task now
runs under Windows PowerShell 5.1 so an MSIX-only pwsh can't break it. The DISM path is dormant until
7.7 GA and needs validation on a real Windows 10 machine before it is relied upon.

**Cross-user PowerShell install fixed** ([#163](https://github.com/J-MaFf/winget-app-setup/issues/163)):
on an elevated session whose interactive desktop belongs to a different user, `Microsoft.PowerShell`
still failed with "The current system configuration does not support the installation of this package"
even after #159. winget installs PowerShell 7.6+ as an MSIX by default, and — even with `--scope machine`
— winget's installer-type precedence still selects the MSIX, whose machine-scope provisioning fails as a
packaged app on Windows < build 26100. The PowerShell entry now forces `--installer-type wix` (the
machine-wide MSI) via a new `-InstallerType` parameter on `Install-WingetPackage`. Also fixed the
scheduled-update setup erroring under `irm | iex` (empty `$PSScriptRoot`) and registering a weekly task
whose helper was never deployed ([#164](https://github.com/J-MaFf/winget-app-setup/issues/164)): the
remote path now downloads the helper plus the self-contained script, and deployment is best-effort.

Earlier, the **cross-user `0x80073d19` root cause was fixed** ([#159](https://github.com/J-MaFf/winget-app-setup/issues/159)):
the error that persisted through #81/#104/#107/#150 is `ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF` —
when the script is elevated as a different account than the logged-on user, winget's per-user MSIX
bootstrap is blocked because that account has no interactive logon session. The installer now
bootstraps the account via `Repair-WinGetPackageManager`, persists source agreements with a proper
probe, detects cross-user elevation, and installs with `--scope machine` (auto-fallback for
MSIX-only packages such as Windows Terminal).

**One-liner install fixed** ([#154](https://github.com/J-MaFf/winget-app-setup/issues/154)):
the `#106` module extraction had dropped `Test-SystemRequirements` without carrying it into the
module, so the default `irm | iex` path threw `CommandNotFoundException`. The function is restored as
`WingetAppSetup/Public/SystemChecks.ps1`, and the build now fails when the generated installer calls
a hyphenated command that resolves to neither a module function nor an external cmdlet, closing the
drift class that let this ship.

**Beads (`bd`) adopted** as the dependency-graph task/memory layer beneath GitHub
Issues ([#147](https://github.com/J-MaFf/winget-app-setup/issues/147), PR merged) — `.beads/`
holds the issue graph, a Dolt remote is wired to `origin` for cross-machine sync, and the
CLAUDE.md beads section is reconciled with `git-policies` (merges stay human-gated).

The install logic has been refactored from a 2,100-line monolith into a module
([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)), and the distributable script is a
generated build artifact that remains byte-for-byte behaviour-equivalent to the previous monolith.
The 2026 code-review batch (#134–#137) has also been applied: all changed scripts parse clean under
the PowerShell AST parser on pwsh 7, and the Pester suite's pass/fail set is unchanged from
baseline on Linux (the only failures are pre-existing Windows-only environment limitations).

CI now runs `build/Build-WingetInstallScript.ps1 -Check` on every push and pull request, so the
generated `winget-app-install.ps1` can no longer drift from the module (and the installer's
undefined-reference guard runs automatically) ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156)).
The Windows CI workflow runs on the self-hosted **win-test** runner (Windows Server 2025,
pwsh 7.6.3) instead of GitHub-hosted `windows-latest`; the guarded Microsoft.WinGet.Client and
Pester installs persist across runs there ([#161](https://github.com/J-MaFf/winget-app-setup/issues/161)).

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
| [#170](https://github.com/J-MaFf/winget-app-setup/issues/170) | Remove the install-time inline update pass (redundant with WAU) | [#171](https://github.com/J-MaFf/winget-app-setup/pull/171) |
| [#168](https://github.com/J-MaFf/winget-app-setup/issues/168) | Outsource auto-updates to Winget-AutoUpdate (WAU); remove homegrown updater | [#169](https://github.com/J-MaFf/winget-app-setup/pull/169) |
| [#166](https://github.com/J-MaFf/winget-app-setup/issues/166) | Always-latest PowerShell install strategy for the MSIX-only (7.7+) future; harden scheduled task for MSIX | [#167](https://github.com/J-MaFf/winget-app-setup/pull/167) |
| [#163](https://github.com/J-MaFf/winget-app-setup/issues/163) | PowerShell fails to install on elevated cross-user sessions (winget picks MSIX over MSI for 7.6+) | [#165](https://github.com/J-MaFf/winget-app-setup/pull/165) |
| [#164](https://github.com/J-MaFf/winget-app-setup/issues/164) | Scheduled-update setup errors under `irm \| iex` (empty `$PSScriptRoot`); weekly task registered but never deployed | [#165](https://github.com/J-MaFf/winget-app-setup/pull/165) |
| [#106](https://github.com/J-MaFf/winget-app-setup/issues/106) | Split `winget-app-install.ps1` into a module with a generated bundle | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#110](https://github.com/J-MaFf/winget-app-setup/issues/110) | Migrate uninstall + update-helper scripts to consume the module | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#111](https://github.com/J-MaFf/winget-app-setup/issues/111) | Remove orphaned tests for functions that no longer exist | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#117](https://github.com/J-MaFf/winget-app-setup/issues/117) | `-WhatIf` dropped the flag on elevation and ran a real install | [#116](https://github.com/J-MaFf/winget-app-setup/pull/116) |
| [#120](https://github.com/J-MaFf/winget-app-setup/issues/120) | Post-install update phase could hang indefinitely on one package | [#121](https://github.com/J-MaFf/winget-app-setup/pull/121) |
| [#134](https://github.com/J-MaFf/winget-app-setup/issues/134) | Double winget command execution in `Invoke-WingetCommand` | [#138](https://github.com/J-MaFf/winget-app-setup/pull/138) |
| [#135](https://github.com/J-MaFf/winget-app-setup/issues/135) | Pester tests copied function bodies instead of dot-sourcing the script | [#139](https://github.com/J-MaFf/winget-app-setup/pull/139) |
| [#136](https://github.com/J-MaFf/winget-app-setup/issues/136) | Missing `STATUS.md` and README/CHANGELOG execution-policy mismatch | [#140](https://github.com/J-MaFf/winget-app-setup/pull/140) |
| [#137](https://github.com/J-MaFf/winget-app-setup/issues/137) | Renamed `Test-Source-IsTrusted` to `Test-WingetSourceTrusted` for verb-noun compliance | [#142](https://github.com/J-MaFf/winget-app-setup/pull/142) |
| [#154](https://github.com/J-MaFf/winget-app-setup/issues/154) | One-liner install failed: `Test-SystemRequirements` undefined on the default path; build now guards undefined references | [#155](https://github.com/J-MaFf/winget-app-setup/pull/155) |
| [#156](https://github.com/J-MaFf/winget-app-setup/issues/156) | Wire build-script `-Check` into CI so the installer can't drift | [#157](https://github.com/J-MaFf/winget-app-setup/pull/157) |
| [#161](https://github.com/J-MaFf/winget-app-setup/issues/161) | Run Windows CI on the self-hosted win-test runner instead of `windows-latest` | [#162](https://github.com/J-MaFf/winget-app-setup/pull/162) |

### Open Issues

None.

## Natural Next Steps

- Add a local pre-commit hook that runs `build/Build-WingetInstallScript.ps1 -Check` — CI already runs it on every push/PR (as of [#156](https://github.com/J-MaFf/winget-app-setup/issues/156)), so this just moves the same guard earlier and catches drift before pushing.
- Watch the first Windows CI runs on the self-hosted win-test runner for environment drift — module versions now persist across runs instead of starting from a fresh `windows-latest` image (as of [#161](https://github.com/J-MaFf/winget-app-setup/issues/161)).
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
