# Winget App Setup

A comprehensive PowerShell automation suite for managing Windows applications using winget (Windows Package Manager). This project provides scripts to install, uninstall, and manage software packages with robust error handling and detailed reporting.

## Features

- **Automated Installation**: Install multiple applications with a single command
- **Dry-Run / WhatIf Mode**: Preview all actions without making system changes - perfect for testing and approval workflows
- **Smart Uninstallation**: Remove applications with status tracking
- **Update Management**: Automatically check for and install available updates
- **Execution Policy Bypass**: Included launcher script handles execution policy restrictions automatically
- **Admin Privilege Handling**: Automatically requests elevation when needed
- **Source Trust Management**: Verifies and trusts winget sources
- **Comprehensive Error Handling**: Detailed error reporting and result tracking
- **Formatted Output**: Clean table-based summaries using PowerShell's Format-Table
- **Interactive GUI Option**: Optional Out-GridView support for sortable, filterable results
- **Color-Coded Feedback**: Visual status indicators for operations
- **Self-Healing Winget Tooling**: Automatically installs required winget CLI and PowerShell module dependencies

## Included Scripts

### `winget-app-install.ps1`

The main installation script that:

- Installs a curated list of essential Windows applications
- Checks for administrator privileges and relaunches elevated if needed
- Verifies winget source trust status
- Handles installation failures gracefully
- Checks for and installs available updates
- Displays results using PowerShell's Format-Table for improved readability
- Optional interactive GUI summary with Out-GridView (when available)

### `launch.ps1`

Launcher script that bypasses execution policy restrictions to run the installer. Use this if you encounter execution policy errors.

Simply run:

```powershell
.\launch.ps1
```

This is useful when execution policies are defined at multiple scopes (Group Policy, User Policy) and prevent running unsigned scripts.

### `winget-app-uninstall.ps1`

Uninstallation companion script that:

- Removes the same applications installed by the install script
- Provides detailed uninstallation status
- Tracks successful, skipped, and failed operations
- Displays summary using Format-Table for consistent, readable output

### `Test-WingetAppInstall.Tests.ps1`

Comprehensive Pester test suite that validates:

- Winget CLI remediation and source trust helpers
- Environment PATH updates and command parsing utilities
- Installation workflows, including success, skip, failure, and update scenarios

## Default Application List

The scripts work with this curated list of applications:

- **7-Zip** (`7zip.7zip`) - File archiver
- **TightVNC** (`GlavSoft.TightVNC`) - Remote desktop software
- **Adobe Acrobat Reader** (`Adobe.Acrobat.Reader.64-bit`) - PDF viewer
- **Google Chrome** (`Google.Chrome`) - Web browser
- **Google Drive** (`Google.GoogleDrive`) - Cloud storage client
- **Git** (`Git.Git`) - Distributed version control system
- **Bulk Crap Uninstaller** (`Klocman.BulkCrapUninstaller`) - Bulk program uninstaller and cleanup utility
- **Dell Command Update** (`Dell.CommandUpdate.Universal`) - System updates for Dell computers
- **PowerShell** (`Microsoft.PowerShell`) - Microsoft's command-line shell
- **Windows Terminal** (`Microsoft.WindowsTerminal`) - Modern terminal application

## Prerequisites

- **Windows 10/11** with winget installed
- **Microsoft App Installer** from Microsoft Store
- **PowerShell Gallery access** to download the Microsoft.WinGet.Client module (handled automatically by the script)
- **Administrator privileges** (scripts will request elevation automatically)
- **PowerShell execution policy** allowing script execution (handled automatically by the script)

## Setup

### Option 1: Clone Repository (Recommended)

```powershell
git clone https://github.com/J-MaFf/winget-app-setup.git
cd winget-app-setup
```

### Option 2: Direct Download

Download the scripts directly from the repository.

## Usage

Run directly (requires execution policy bypass)

```powershell
powershell -ExecutionPolicy Bypass -File .\winget-app-install.ps1
```

Or with full path

```powerhsell
C:\Path\To\winget-app-setup\launch.ps1
```

The launcher script (`launch.ps1`) automatically handles execution policy restrictions, which is necessary because PowerShell blocks unsigned scripts at the engine level.

### Execution Policy Issues

Preview what the script would do without making any actual changes:

```powershell
# Run in dry-run mode to see what would be installed
.\winget-app-install.ps1 -WhatIf

# This mode will:
# - Perform all pre-flight checks
# - Show which apps would be installed
# - Display which sources would be trusted
# - Indicate PATH changes that would be made
# - List available updates without installing them
# - No system modifications will occur
```

**Use Cases for WhatIf Mode:**

- Verify the script behavior before running on production systems
- Review which applications will be installed in managed environments
- Check for available updates without installing them
- Test the script in new environments safely
- Generate reports of planned changes for approval processes

### Uninstallation (with Execution Policy Bypass)

Run the uninstallation script using the launcher:

```powershell
# Use the launcher script
powershell -ExecutionPolicy Bypass -File .\winget-app-uninstall.ps1

# Or with full path
C:\Path\To\winget-app-setup\winget-app-uninstall.ps1
```

## Script Behavior

### Execution Policy Management

**PowerShell blocks unsigned scripts at the engine level** before any script code runs. The scripts cannot modify execution policy from within themselves because they never load in the first place.

**Solution:** Use the `launch.ps1` script:

```powershell
.\launch.ps1
```

This launcher handles the `-ExecutionPolicy Bypass` flag automatically.

**Alternative:** Run directly with execution policy bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\winget-app-install.ps1
powershell -ExecutionPolicy Bypass -File .\winget-app-uninstall.ps1
```

**Why this approach?**

- **Execution policies defined at multiple scopes** (Machine Policy, User Policy, CurrentUser) can prevent scripts from running
- **Group Policy restrictions** on corporate machines block policy changes
- The launcher script bypasses the engine-level block to allow the main scripts to run
- No permanent policy changes are made; the bypass is temporary for that execution only

### Administrator Privileges

All scripts automatically check for administrator privileges and will:

- Display a message if elevation is required
- Relaunch themselves with elevated privileges (preferring Windows Terminal when available)
- Continue execution once elevated

### Source Trust

Scripts verify winget source trust for:

- `winget` (Microsoft's official source)
- `msstore` (Microsoft Store source)

### Winget Tooling Remediation

- Ensures the `Microsoft.WinGet.Client` PowerShell module is installed (installs automatically if missing)
- Validates winget CLI is present, installing Microsoft App Installer when required

### Error Handling

- **Installation failures** are tracked and reported
- **Already installed apps** are skipped with notification
- **Network issues** and **package not found** errors are handled gracefully
- **Update operations** include fallback parsing methods

### Output Format

The scripts provide:

- Real-time progress with color-coded messages
- Comprehensive summary table using PowerShell's Format-Table with automatic column sizing
- Properly aligned columns that work in standard PowerShell, Windows Terminal, and when copied to documentation
- Optional interactive GUI view using Out-GridView (when available and requested)
- Summary table showing:
  - Installed applications
  - Skipped applications (already installed)
  - Failed installations
  - Updated applications (install script only)
  - Failed updates (install script only)

**Interactive Grid View**: The scripts will automatically prompt you to view the results in an interactive grid view (Out-GridView) if it's available on your system. This provides a sortable, filterable window for easy review. The feature gracefully falls back to text output on Server Core or in remote sessions where Out-GridView is unavailable.

## Customization

### Adding Applications

To add new applications, edit the `$apps` array in the scripts:

```powershell
$apps = @(
    @{name = 'Existing.App' },
    @{name = 'New.Publisher.App' },  # Add new app here
    @{name = 'Another.App' }
);
```

### Modifying Behavior

The scripts include several configurable functions:

- `Test-Source-IsTrusted()` - Source trust verification
- `Set-Sources()` - Source trust setup
- `Write-Table()` - Result display formatting using Format-Table or Out-GridView
- `Invoke-WingetCommand()` - Winget command execution with exit code capture, mapping, and output parsing

#### Exit Code Handling

The `Invoke-WingetCommand()` function captures and maps winget exit codes to meaningful error messages:

- **Exit Code 0**: Success
- **-1978335189** (0x8A15002B): No applicable update found
- **-1978335191** (0x8A150029): No packages found matching input criteria
- **-1978335192** (0x8A150028): Package installation failed
- **-1978335212** (0x8A150014): User cancelled the operation
- **-1978335213** (0x8A150013): Package already installed
- **-1978335215** (0x8A150011): Manifest validation failed
- **-1978335216** (0x8A150010): Invalid manifest
- **-1978335221** (0x8A15000B): Package download failed
- **-1978335226** (0x8A150006): Hash mismatch
- **Unknown codes**: Generic message with the exit code

When winget exits with a non-zero code and no output pattern matches are found, the function automatically reports the failure with actionable diagnostics to the `$failedApps` array.

## Troubleshooting

### Common Issues

#### "cannot be loaded because running scripts is disabled"

**This is the most common issue.** PowerShell blocks unsigned scripts at the engine level.

**Solution:** Use the launcher script (recommended):

```powershell
.\launch.ps1
```

**Alternative:** Run with execution policy bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\winget-app-install.ps1
```

**Why you can't just change the policy:**

- Execution policies defined at multiple scopes (Machine Policy, User Policy) can prevent changes
- Group Policy restrictions on corporate machines block policy changes
- The launcher script bypasses the engine-level block, which is safer and more reliable than trying to change policies

#### "winget command not found"

- Ensure Microsoft App Installer is installed from Microsoft Store
- Restart PowerShell after installation

#### "Access denied"

- Scripts require administrator privileges
- Allow automatic elevation when prompted

#### "Package not found"

- Verify the package ID is correct
- Check if the application is available in winget

### Testing

Run the Pester suite to verify all behaviors and edge cases:

```powershell
Invoke-Pester -Path .\Test-WingetAppInstall.Tests.ps1 -Output Detailed
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly
4. Submit a pull request

## License

This project is open source. Please check the repository for license details.

## Future Plans

- PowerShell Gallery publication for easier installation
- Configuration file support for custom application lists
- GUI interface option
- Additional package managers support (Chocolatey, Scoop)
