<#PSScriptInfo

.VERSION 1.0.0

.GUID a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d

.AUTHOR Joey Maffiola

.DESCRIPTION
    Launcher script for winget-app-install.ps1 that handles execution policy restrictions.

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES
    1.0.0 - Initial version. Launches winget-app-install.ps1 with execution policy bypass.

#>

<#
.SYNOPSIS
    Launches the winget application installer with execution policy bypass.

.DESCRIPTION
    This script bypasses execution policy restrictions to run winget-app-install.ps1.
    Use this if you encounter execution policy errors when trying to run the main script directly.

    This is necessary because PowerShell blocks unsigned scripts at the engine level before
    the main script can run. The Test-AndSetExecutionPolicy function cannot run because the
    script file itself is rejected.

.PARAMETER WhatIf
    When specified, performs all pre-flight checks and displays planned actions without making any system changes.

.EXAMPLE
    # Run with default behavior
    .\launch.ps1

    # Run in dry-run mode to see what would happen
    .\launch.ps1 -WhatIf

.NOTES
    - This script must be in the same directory as winget-app-install.ps1
    - Requires administrator privileges to install applications
    - If you still encounter issues, you can run manually:
      powershell -ExecutionPolicy Bypass -File .\winget-app-install.ps1
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

# Get the directory where this script is located
$scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$mainScript = Join-Path -Path $scriptDir -ChildPath 'winget-app-install.ps1'

# Verify the main script exists
if (-not (Test-Path -Path $mainScript)) {
    Write-Host "Error: winget-app-install.ps1 not found in $scriptDir" -ForegroundColor Red
    Write-Host "Please ensure this launcher script is in the same directory as winget-app-install.ps1" -ForegroundColor Yellow
    exit 1
}

# Build the command
$arguments = @('-ExecutionPolicy', 'Bypass', '-File', $mainScript)

# Add -WhatIf parameter if specified
if ($WhatIf) {
    $arguments += '-WhatIf'
}

# Execute the main script with execution policy bypass
try {
    & powershell @arguments
}
catch {
    Write-Host "Error launching script: $_" -ForegroundColor Red
    exit 1
}
