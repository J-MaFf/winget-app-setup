# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Documented the repository's commit, PR, and metadata rules plus working GitHub CLI commands for labels and assignees inside `.github/copilot-instructions.md`.

### Changed

- Simplified the README to a two-step guide that starts with `Set-ExecutionPolicy Unrestricted -Scope Process -Force` followed by running `powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1`.
- Configured the workspace's local Memory MCP storage plus `.gitignore` and `.vscode` settings so auto-generated knowledge graph data stays in the repo scope.

### Removed

- Dropped `launch.ps1`; the installer now runs directly when the required execution policy is temporarily relaxed.

### Fixed (Unreleased)

- Cleaned up `Test-WingetAppInstall.Tests.ps1` so it no longer defines unused variables and satisfies the linter.

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
