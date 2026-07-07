# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Fixed the recurring `0x80073d19` install failure ("an error occurred because a user was logged off") that persisted through #81/#104/#107/#150 on machines where the script is elevated as a different account than the interactively logged-on user. Root cause: `0x80073d19` is `ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF` — the AppX deployment service blocks winget's per-user first-use bootstrap (registering `Microsoft.Winget.Source`) for an account with no interactive logon session, so no amount of retrying could recover. `Initialize-WingetSourcesForUser` is rewritten to probe with `winget source update --accept-source-agreements` (its old probe omitted the flag and its fallback checked a wrong exit code, making it a no-op) and to bootstrap the account via `Repair-WinGetPackageManager` when the probe fails; `Test-AndInstallWinget` prefers the same bootstrap over `Add-AppxPackage`; cross-user elevation is now detected and reported with remediation guidance; and `Install-WingetPackage` prefers `--scope machine` (falling back automatically for MSIX-only packages like Windows Terminal), which both avoids per-user MSIX deployment — the layer `0x80073d19` blocks, and what Microsoft.PowerShell's default user-scope MSIX installer hit — and stops installs from landing in the elevated admin account's profile instead of machine-wide ([#159](https://github.com/J-MaFf/winget-app-setup/issues/159)).

### Added

- Wired `build/Build-WingetInstallScript.ps1 -Check` into the Windows CI workflow (`.github/workflows/windows-tests.yml`) so every push and pull request verifies the generated `winget-app-install.ps1` is byte-for-byte in sync with the `WingetAppSetup` module and passes the undefined-reference guard; drift now fails CI instead of shipping silently ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156), [#157](https://github.com/J-MaFf/winget-app-setup/pull/157)).
- Added `STATUS.md` describing the project's purpose, components, resolved/open issues, next steps, and prerequisites, per repository conventions (#136).
- Refactored the 2,100-line `winget-app-install.ps1` into a reusable `WingetAppSetup` PowerShell module (`WingetAppSetup/Public` + `WingetAppSetup/Private`, with a `.psd1` manifest). The distributable single-file `winget-app-install.ps1` is now generated from the module by `build/Build-WingetInstallScript.ps1`, preserving the `irm | iex` one-liner workflow ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- `winget-app-uninstall.ps1` and `Update-InstalledApps.ps1` now consume the `WingetAppSetup` module instead of carrying their own copies of the logging, table, config, and update-report functions. `Install-UpdateHelperScript` deploys a copy of the module into `%APPDATA%` next to the scheduled-update helper so it remains importable when the task runs without the repository present ([#110](https://github.com/J-MaFf/winget-app-setup/issues/110)).
- Documented the repository's commit, PR, and metadata rules plus working GitHub CLI commands for labels and assignees inside `.github/copilot-instructions.md`.
- Added automatic detection and repair of broken or missing winget package sources (#66).
- Added automated Windows Terminal post-install configuration to set PowerShell 7 as the default profile and register Windows Terminal as the default terminal application via `HKCU:\Console\%%Startup` delegation values (#74).
- Added Claude Code GitHub automation (`.github/workflows/claude.yml`): mention `@claude` on an issue or PR to trigger AI assistance, authenticated with a Claude Max subscription OAuth token (#125).
- Added a `windows-latest` Pester CI workflow (`.github/workflows/windows-tests.yml`) that runs the `Test-WingetAppInstall.Tests.ps1` suite on every push to `main` and on pull requests (#130).
- Restored the pre-flight system checks (OS version, disk space, network) and the `-SkipSystemCheck` switch, whose implementation was lost after #101 (#132). **Note:** the `#106` module extraction (above) subsequently dropped the `Test-SystemRequirements` function again without carrying it into `WingetAppSetup/`; it was re-restored as a module function in [#154](https://github.com/J-MaFf/winget-app-setup/issues/154).
- Adopted **beads** (`bd`) as a dependency-graph task/memory layer beneath GitHub Issues for AI-driven work. `bd init` (embedded Dolt) scaffolds `.beads/` with the issue graph; a Dolt remote is wired to `origin` for cross-machine sync via `refs/dolt/data`; Claude Code hooks run `bd prime` on SessionStart/PreCompact; and an `AGENTS.md` is generated. The CLAUDE.md beads section is reconciled with the `git-policies` skill so durability/sync stay automatic while merges to `main` remain human-gated via PR ([#147](https://github.com/J-MaFf/winget-app-setup/issues/147), [#148](https://github.com/J-MaFf/winget-app-setup/pull/148)).

### Changed

- Moved the Windows CI workflow (`.github/workflows/windows-tests.yml`) from GitHub-hosted `windows-latest` to the self-hosted win-test runner (`runs-on: [self-hosted, windows]`, Windows Server 2025, pwsh 7.6.3), keeping the existing steps and concurrency group. Added a `workflow_dispatch` trigger and a 15-minute job timeout so a hung job cannot block the shared runner. The guarded Microsoft.WinGet.Client and Pester installs persist across runs on the runner, so they are no-ops after the first run ([#161](https://github.com/J-MaFf/winget-app-setup/issues/161), [#162](https://github.com/J-MaFf/winget-app-setup/pull/162)).
- Renamed the `Test-Source-IsTrusted` function to `Test-WingetSourceTrusted` so it follows the PowerShell verb-noun convention (the old name embedded a hyphen in the noun segment and tripped a PSScriptAnalyzer warning); updated the call site and all test references (#137).
- Refactored `Test-WingetAppInstall.Tests.ps1` to dot-source the real `winget-app-install.ps1` instead of copying function bodies verbatim into `BeforeAll`/`BeforeEach` blocks, so the suite now exercises the actual implementation and no longer drifts silently when the script changes. Removed 24 inline function copies across 12 `Describe` blocks and corrected the `Format-AppList` empty-input test to match the real function's mandatory `[string[]]` contract (#135).
- `Test-WingetAppInstall.Tests.ps1` now loads the module's functions once for the whole suite instead of dot-sourcing the full script in 16 places and re-declaring 17 functions inline, eliminating copy-paste drift between tests and production code ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- `Format-AppList` now accepts `$null` (returning `$null`) in addition to empty collections, matching its documented contract and reconciling drift surfaced by the test consolidation ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- The module's `Get-UpdateReport` now validates the winget Id column against a package-id regex before parsing a row, adopting the stricter behavior that had drifted into `Update-InstalledApps.ps1` ([#110](https://github.com/J-MaFf/winget-app-setup/issues/110)).
- Simplified the README to a two-step guide that starts with `Set-ExecutionPolicy Unrestricted -Scope Process -Force` followed by running `powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1`.
- Configured the workspace's local Memory MCP storage plus `.gitignore` and `.vscode` settings so auto-generated knowledge graph data stays in the repo scope.
- `Invoke-WingetInstall` now verifies and auto-repairs the winget package source before beginning app installations.
- Claude Code automation runs on `ubuntu-latest`; Windows-native test execution moved to the dedicated Pester workflow, since the action cannot install the Claude CLI on Windows runners (#130).

### Removed

- Removed orphaned Pester `Describe` blocks that tested functions which no longer ship: `Test-AndSetExecutionPolicy` (its `launch.ps1` was already dropped), `Invoke-WingetInstallWithRetry`, and `Test-SystemRequirements` ([#111](https://github.com/J-MaFf/winget-app-setup/issues/111)).
- Dropped `launch.ps1`; the installer now runs directly when the required execution policy is temporarily relaxed.

### Fixed (Unreleased)

- Fixed `Microsoft.PowerShell` failing to install with "The current system configuration does not support the installation of this package" on elevated cross-user sessions. Since the winget package for PowerShell 7.6.0, winget installs the MSIX bundle by default, and winget's own machine-scope MSIX provisioning fails as a packaged app on Windows older than build 26100 (24H2) — deterministically, so the retry pass could not recover it. `Install-WingetPackage` now accepts an `-InstallerType` override and the PowerShell app entry forces `--installer-type wix`, installing the machine-wide MSI (which the other Win32 apps use) instead of the MSIX ([#163](https://github.com/J-MaFf/winget-app-setup/issues/163)).
- Fixed the scheduled-update setup throwing `Join-Path`/`Test-Path`/`Copy-Item` "Cannot bind argument to parameter 'Path'" errors under the `irm | iex` one-liner, where `$PSScriptRoot` is empty. The helper and module were never deployed to `%APPDATA%`, yet the weekly task was still registered pointing at the missing helper. `Install-UpdateHelperScript` now downloads the standalone helper plus the self-contained `winget-app-install.ps1` when running remotely (the helper dot-sources the self-contained script for its functions when the module folder is absent), and helper deployment is now best-effort so a failure warns and skips instead of aborting the install ([#164](https://github.com/J-MaFf/winget-app-setup/issues/164)).
- Fixed the `irm | iex` one-liner (and any local run without `-SkipSystemCheck`) failing immediately with `Test-SystemRequirements : The term 'Test-SystemRequirements' is not recognized ... CommandNotFoundException`. The installer's entry point (`build/fragments/tail.ps1`) calls `Test-SystemRequirements`, but the `#106` module extraction never carried the function into `WingetAppSetup/`, so the generated `winget-app-install.ps1` invoked an undefined command on the default path. Restored the pre-flight system-check function as `WingetAppSetup/Public/SystemChecks.ps1` (exported from the manifest), re-added its Pester coverage, and regenerated the single-file installer ([#154](https://github.com/J-MaFf/winget-app-setup/issues/154)).
- Hardened `build/Build-WingetInstallScript.ps1` to fail the build (and `-Check`) when the assembled installer invokes a hyphenated command that is neither defined in the module nor resolvable as an external cmdlet, so a fragment calling a dropped module function can no longer ship undetected. Enforced on Windows, where the installer's Windows-only cmdlets resolve; skipped with a notice on other platforms ([#154](https://github.com/J-MaFf/winget-app-setup/issues/154)).
- Reconciled the README one-line install command with the CHANGELOG: the `Set-ExecutionPolicy Unrestricted -Scope Process` snippet now includes `-Force`, matching the documented simplified form (#136).
- Fixed double winget command execution in `Invoke-WingetCommand`: the function previously ran each winget command twice (once to display output, once to capture it), causing duplicate prompts and spurious "already installed" failures. It now invokes winget a single time, reading the exit code directly before any pipeline can reset `$LASTEXITCODE` (#134).
- Fixed the post-install update phase hanging indefinitely on a stalled package upgrade. Each upgrade now runs through a timeout-guarded helper (`Invoke-WingetPackageUpgrade`) that kills a non-responsive `winget upgrade` and continues with the remaining packages, instead of piping every outdated package into a single unbounded `Update-WinGetPackage` call ([#120](https://github.com/J-MaFf/winget-app-setup/issues/120)).
- Fixed `-WhatIf` (dry-run) silently performing a real install: when run non-elevated, the script relaunched itself elevated but dropped the `-WhatIf` flag, so the admin session installed the full app list. A dry run now never elevates, and `Restart-WithElevation` forwards `-WhatIf` as a safety net ([#117](https://github.com/J-MaFf/winget-app-setup/issues/117)).
- Corrected the CLAUDE.md winget note that referenced a non-existent `Invoke-WingetInstallWithSessionRetry`; it now describes the actual `0x80073d19` mitigation (user-context source init plus the single failed-install retry pass) ([#111](https://github.com/J-MaFf/winget-app-setup/issues/111)).
- Cleaned up `Test-WingetAppInstall.Tests.ps1` so it no longer defines unused variables and satisfies the linter.
- Fixed all 17 Pester tests that failed on the new Windows CI (#132): install `Microsoft.WinGet.Client` in CI so the winget cmdlet mocks resolve, removed orphaned `Invoke-WingetInstallWithRetry` tests for the reverted retry feature (#83), and restored the missing `Test-SystemRequirements` implementation (into the then-monolithic script; the later #106 module extraction dropped it again — see #154).
- Made `Enable-ScheduledUpdatesCheck` resilient to `[WindowsIdentity]::GetCurrent()` failing in restricted execution contexts (e.g. CI or service accounts): it now falls back to environment variables for the task principal so scheduled-task creation no longer aborts (#132).
- Fixed broken winget source scenario: when running as admin on a standard user account the "winget" source registration may be missing or broken; the script now detects and auto-repairs this condition instead of silently failing (#66).
- Added Pester coverage for Windows Terminal default profile and terminal delegation configuration paths, and corrected an `IsWindows` read-only variable name collision in the test suite.
- Fixed corrupted winget source data detection: `Test-WingetSources` now verifies source functionality with `winget source update`, detects corruption errors like `0x8a15000f`, and uses `winget source reset` as part of repair attempts (#77).

## [1.0.0] - 2025-11-07

### Added (1.0.0)

- Initial PowerShell automation suite for managing Windows applications using winget
- **winget-app-install.ps1** - Main installation script with update management
- **winget-app-uninstall.ps1** - Companion uninstallation script for removing applications
- **launch.ps1** - Launcher script for execution policy bypass
- **Test-WingetAppInstall.Tests.ps1** - Comprehensive Pester test suite
- Automated installation of 10 curated Windows applications
- Dry-Run/WhatIf mode for previewing actions without making system changes
- Smart application checking to detect and skip already-installed applications
- Automatic update detection and installation
- Admin privilege handling with automatic elevation (preferring Windows Terminal when available)
- Winget source trust verification and management
- Timeout protection for all winget commands (prevents hanging)
- Formatted output with Format-Table and optional Out-GridView support
- Color-coded status messages for visual feedback
- Self-healing winget tooling (auto-installs CLI and PowerShell module dependencies)
- Execution policy bypass via launcher script
- Comprehensive inline documentation
- Reusable utility functions for common operations

### Fixed

- Installation checks now use correct winget list syntax (`--id` flag instead of `-q`)
- Timeout protection prevents hanging on source operations (30s for source ops, 15s for package ops)
- Execution policy handling via dedicated launcher script
- Robust error handling with graceful degradation
- Network error resilience and package not found scenarios

### Features

- **Comprehensive Error Handling**
  - Timeout protection for all winget commands
  - Graceful handling of network errors and package not found scenarios
  - Detailed failure tracking and reporting

- **Smart Application Management**
  - Pre-installation checks to skip already-installed applications
  - Post-installation verification to confirm successful installation
  - Fallback mechanisms for update detection

- **Flexible Output Options**
  - Text-based table output with automatic column sizing
  - Interactive Out-GridView GUI when available
  - Color-coded status messages for easy identification

- **Developer-Friendly**
  - Extensive inline documentation
  - Reusable utility functions
  - Comprehensive Pester test suite
  - Clear code patterns and conventions

### Default Applications

The following 10 applications are included in this release:

- 7-Zip (`7zip.7zip`)
- TightVNC (`GlavSoft.TightVNC`)
- Adobe Acrobat Reader 64-bit (`Adobe.Acrobat.Reader.64-bit`)
- Google Chrome (`Google.Chrome`)
- Google Drive (`Google.GoogleDrive`)
- Git (`Git.Git`)
- Bulk Crap Uninstaller (`Klocman.BulkCrapUninstaller`)
- Dell Command Update - Universal (`Dell.CommandUpdate.Universal`)
- PowerShell (`Microsoft.PowerShell`)
- Windows Terminal (`Microsoft.WindowsTerminal`)

### Requirements

- Windows 10/11
- Administrator privileges
- Winget package manager
- PowerShell 5.1+ (PowerShell 7+ recommended)

### Known Limitations

- Requires Windows 10/11
- Requires administrator privileges
- Winget source trust requires source agreements
- Out-GridView support requires Windows Terminal or PowerShell with GraphicalTools module

### Documentation

- Comprehensive README.md with feature descriptions, troubleshooting, and customization guides
- Inline code documentation with comment-based help
- Pester test suite for validation and examples

---

For detailed release information, see [release-notes.md](release-notes.md).
