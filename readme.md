# Winget App Setup

A comprehensive PowerShell automation suite for managing Windows applications using winget (Windows Package Manager). This project provides scripts to install, uninstall, and manage software packages with robust error handling and detailed reporting.

## Features

- **Automated Installation**: Install multiple applications with a single command
- **Smart Uninstallation**: Remove applications with status tracking
- **Update Management**: Automatically check for and install available updates
- **Execution Policy Management**: Automatically checks and adjusts PowerShell execution policy on first run
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

### Installation

Run the installation script as administrator:

```powershell
# From the script directory
.\winget-app-install.ps1

# Or with full path
C:\Path\To\winget-app-setup\winget-app-install.ps1
```

### Uninstallation

Run the uninstallation script as administrator:

```powershell
# From the script directory
.\winget-app-uninstall.ps1

# Or with full path
C:\Path\To\winget-app-setup\winget-app-uninstall.ps1
```

## Script Behavior

### Execution Policy Management

Scripts automatically check the PowerShell execution policy on first run and will:

- Detect if the current policy prevents scripts from running
- Attempt to set the policy to `RemoteSigned` for the CurrentUser scope if needed
- Provide clear feedback about policy changes
- Display helpful instructions if policy adjustment requires manual intervention

**Note**: The scripts use `RemoteSigned` policy, which is secure (requires signatures for downloaded scripts) while allowing local scripts to run without issues.

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

- The script automatically detects and attempts to fix execution policy issues
- If automatic adjustment fails, manually run: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force`
- For system-wide changes (requires admin): `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force`

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
