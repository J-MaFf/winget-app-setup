# Winget App Setup

A comprehensive PowerShell automation suite for managing Windows applications using winget (Windows Package Manager). This project provides scripts to install, uninstall, and manage software packages with robust error handling and detailed reporting.

## Features

- **Automated Installation**: Install multiple applications with a single command
- **Smart Uninstallation**: Remove applications with status tracking
- **Update Management**: Automatically check for and install available updates
- **Admin Privilege Handling**: Automatically requests elevation when needed
- **Source Trust Management**: Verifies and trusts winget sources
- **Comprehensive Error Handling**: Detailed error reporting and result tracking
- **Formatted Output**: Clean table-based summaries of all operations
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
- Displays results in a formatted ASCII table

### `winget-app-uninstall.ps1`

Uninstallation companion script that:

- Removes the same applications installed by the install script
- Provides detailed uninstallation status
- Tracks successful, skipped, and failed operations

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
- **Dell Command Update** (`Dell.CommandUpdate.Universal`) - System updates for Dell computers
- **PowerShell** (`Microsoft.PowerShell`) - Microsoft's command-line shell
- **Windows Terminal** (`Microsoft.WindowsTerminal`) - Modern terminal application

## Prerequisites

- **Windows 10/11** with winget installed
- **Microsoft App Installer** from Microsoft Store
- **PowerShell Gallery access** to download the Microsoft.WinGet.Client module (handled automatically by the script)
- **Administrator privileges** (scripts will request elevation automatically)
- **PowerShell execution policy** allowing script execution

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

The main installation script provides:

- Real-time progress with color-coded messages
- Comprehensive summary table showing:
  - Installed applications
  - Skipped applications (already installed)
  - Failed installations
  - Updated applications
  - Failed updates

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
- `Write-Table()` - Result display formatting
- `Invoke-WingetCommand()` - Winget command execution with parsing

## Troubleshooting

### Common Issues

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
