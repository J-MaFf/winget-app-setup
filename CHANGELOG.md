# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `STATUS.md` describing the project's purpose, components, resolved/open issues, next steps, and prerequisites, per repository conventions (#136).
- Refactored the 2,100-line `winget-app-install.ps1` into a reusable `WingetAppSetup` PowerShell module (`WingetAppSetup/Public` + `WingetAppSetup/Private`, with a `.psd1` manifest). The distributable single-file `winget-app-install.ps1` is now generated from the module by `build/Build-WingetInstallScript.ps1`, preserving the `irm | iex` one-liner workflow ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- `winget-app-uninstall.ps1` and `Update-InstalledApps.ps1` now consume the `WingetAppSetup` module instead of carrying their own copies of the logging, table, config, and update-report functions. `Install-UpdateHelperScript` deploys a copy of the module into `%APPDATA%` next to the scheduled-update helper so it remains importable when the task runs without the repository present ([#110](https://github.com/J-MaFf/winget-app-setup/issues/110)).
- Documented the repository's commit, PR, and metadata rules plus working GitHub CLI commands for labels and assignees inside `.github/copilot-instructions.md`.
- Added automatic detection and repair of broken or missing winget package sources (#66).
- Added automated Windows Terminal post-install configuration to set PowerShell 7 as the default profile and register Windows Terminal as the default terminal application via `HKCU:\Console\%%Startup` delegation values (#74).
- Added Claude Code GitHub automation (`.github/workflows/claude.yml`): mention `@claude` on an issue or PR to trigger AI assistance, authenticated with a Claude Max subscription OAuth token (#125).
- Added a `windows-latest` Pester CI workflow (`.github/workflows/windows-tests.yml`) that runs the `Test-WingetAppInstall.Tests.ps1` suite on every push to `main` and on pull requests (#130).
- Restored the pre-flight system checks (OS version, disk space, network) and the `-SkipSystemCheck` switch, whose implementation was lost after #101 (#132).

### Changed

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

- Dropped `launch.ps1`; the installer now runs directly when the required execution policy is temporarily relaxed.

### Fixed (Unreleased)

- Reconciled the README one-line install command with the CHANGELOG: the `Set-ExecutionPolicy Unrestricted -Scope Process` snippet now includes `-Force`, matching the documented simplified form (#136).
- Fixed double winget command execution in `Invoke-WingetCommand`: the function previously ran each winget command twice (once to display output, once to capture it), causing duplicate prompts and spurious "already installed" failures. It now invokes winget a single time, reading the exit code directly before any pipeline can reset `$LASTEXITCODE` (#134).
- Cleaned up `Test-WingetAppInstall.Tests.ps1` so it no longer defines unused variables and satisfies the linter.
- Fixed all 17 Pester tests that failed on the new Windows CI (#132): install `Microsoft.WinGet.Client` in CI so the winget cmdlet mocks resolve, removed orphaned `Invoke-WingetInstallWithRetry` tests for the reverted retry feature (#83), and restored the missing `Test-SystemRequirements` implementation.
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
