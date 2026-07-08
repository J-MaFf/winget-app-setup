# Logging helpers used only by module functions (issue #191). The externally consumed logging
# primitives (Write-Info/Success/WarningMessage/ErrorMessage, Format-AppList, Write-Table) live
# in Public/Logging.ps1 because winget-app-uninstall.ps1 imports them through the manifest.

<#
.SYNOPSIS
    Writes a prompt message in blue color.
.DESCRIPTION
    Helper function for consistent user prompt messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Prompt {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}
