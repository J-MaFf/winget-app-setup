# v1.0.0 - Initial Release

## Overview

**Winget App Setup** is a comprehensive PowerShell automation suite for managing Windows applications using the Windows Package Manager (winget). This initial release provides robust scripting for installing, uninstalling, and managing software packages with extensive error handling and detailed reporting.

## Key Features

✨ **Automated Installation & Uninstallation** - Install or remove multiple applications with a single command
🎯 **Dry-Run Mode (WhatIf)** - Preview all actions without making system changes - perfect for testing and approval workflows
⚡ **Smart Application Checking** - Detects already-installed applications and skips them automatically
🔄 **Update Management** - Automatically checks for and installs available updates
🔐 **Admin Handling** - Automatically requests elevation when needed, preferring Windows Terminal when available
🛡️ **Source Trust Management** - Verifies and trusts winget sources automatically
📊 **Formatted Output** - Clean table-based summaries with optional interactive Out-GridView support
🎨 **Color-Coded Feedback** - Visual status indicators for operations
🔧 **Self-Healing** - Automatically installs required winget CLI and PowerShell module dependencies
📜 **Execution Policy Bypass** - Included launcher script handles execution policy restrictions automatically

## Included Scripts

- **winget-app-install.ps1** - Main installation script with update management
- **winget-app-uninstall.ps1** - Companion uninstallation script
- **launch.ps1** - Launcher script for execution policy bypass
- **Test-WingetAppInstall.Tests.ps1** - Comprehensive Pester test suite

## Default Application Set

This release installs the following curated applications by default:

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

## Quick Start

### Installation

```powershell
# Clone the repository
git clone https://github.com/J-MaFf/winget-app-setup.git
cd winget-app-setup

# Run the installer (recommended - uses launcher for execution policy bypass)
.\launch.ps1

# Or preview what would be installed
.\winget-app-install.ps1 -WhatIf
```

### Uninstallation

```powershell
powershell -ExecutionPolicy Bypass -File .\winget-app-uninstall.ps1
```

## What's Included

### Comprehensive Error Handling

- Timeout protection for all winget commands (prevents hanging)
- Graceful handling of network errors and package not found scenarios
- Detailed failure tracking and reporting

### Smart Application Management

- Pre-installation checks to skip already-installed applications
- Post-installation verification to confirm successful installation
- Fallback mechanisms for update detection

### Flexible Output Options

- Text-based table output with automatic column sizing
- Interactive Out-GridView GUI when available
- Color-coded status messages for easy identification

### Developer-Friendly

- Extensive inline documentation
- Reusable utility functions
- Comprehensive Pester test suite
- Clear code patterns and conventions

## Documentation

Full documentation available in [README.md](README.md):

- Detailed feature descriptions
- Troubleshooting guide
- Customization instructions
- Script behavior explanations

## Known Limitations

- Requires Windows 10/11
- Requires administrator privileges
- Winget source trust requires source agreements
- Out-GridView support requires Windows Terminal or PowerShell with GraphicalTools module

## Testing

This release includes comprehensive Pester tests covering:

- Winget CLI remediation
- Source trust verification
- Environment PATH management
- Installation workflows
- Error scenarios

Run tests with:

```powershell
Invoke-Pester -Path .\Test-WingetAppInstall.Tests.ps1 -Output Detailed
```

## Fixes in This Release

- ✅ Fixed installation checks to use correct winget list syntax (`--id` flag)
- ✅ Added timeout protection to prevent hanging on source operations
- ✅ Implemented execution policy bypass via launcher script
- ✅ Improved error handling and reporting
- ✅ Enhanced documentation and code examples

## Future Plans

- PowerShell Gallery publication for easier installation
- Configuration file support for custom application lists
- GUI interface option
- Support for additional package managers

## Contributing

This project follows a feature-branch workflow. See [CONTRIBUTING](docs/CONTRIBUTING.md) guidelines in copilot-instructions.md.

## Support

For issues, questions, or contributions, please visit the [GitHub repository](https://github.com/J-MaFf/winget-app-setup).

---

**Release Date:** November 7, 2025  
**Author:** Joey Maffiola  
**License:** See repository for license details
