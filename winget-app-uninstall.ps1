# 1. Make sure the Microsoft App Installer is installed:
#    https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1
# 2. Edit the list of apps to uninstall.
# 3. Run this script as administrator.

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Host 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.' -ForegroundColor Red
    Pause
    # Relaunch the script with administrator privileges
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}
else {
    Write-Host 'Starting...' -ForegroundColor Green
}

$apps = @(
    @{name = '7zip.7zip' },
    @{name = 'GlavSoft.TightVNC' },
    @{name = 'Adobe.Acrobat.Reader.64-bit' },
    @{name = 'Google.Chrome' },
    @{name = 'Google.GoogleDrive' },
    @{name = 'Git.Git' },
    @{name = 'Klocman.BulkCrapUninstaller' },
    @{name = 'Dell.CommandUpdate.Universal' },
    @{name = 'Microsoft.PowerShell' },
    @{name = 'Microsoft.WindowsTerminal' }
);

Write-Host 'Uninstalling the following Apps:' -ForegroundColor Blue
ForEach ($app in $apps) {
    Write-Host $app.name -ForegroundColor Blue
}

$uninstalledApps = @()
$skippedApps = @()
$failedApps = @()

Foreach ($app in $apps) {
    try {
        $listApp = winget list --exact -q $app.name
        if ([String]::Join('', $listApp).Contains($app.name)) {
            Write-Host 'Uninstalling: ' $app.name -ForegroundColor Blue
            $uninstallResult = winget uninstall -e --id $app.name
            if ($uninstallResult -match 'No installed package found matching input criteria.') {
                Write-Host "Failed to uninstall: $($app.name). No installed package found matching input criteria." -ForegroundColor Red
                $failedApps += $app.name
            }
            elseif ($uninstallResult -match 'Successfully uninstalled') {
                Write-Host 'Successfully uninstalled: ' $app.name -ForegroundColor Green
                $uninstalledApps += $app.name
            }
            else {
                throw "Failed to uninstall: $($app.name). Error: $uninstallResult"
            }
        }
        else {
            Write-Host 'Skipping: ' $app.name ' (not installed)' -ForegroundColor Yellow
            $skippedApps += $app.name
        }
    }
    catch {
        Write-Host "Failed to uninstall: $($app.name). Error: $_" -ForegroundColor Red
        $failedApps += $app.name
    }
}

<#
.SYNOPSIS
    Displays a formatted table of results, with optional interactive GUI view.
.DESCRIPTION
    Renders a summary table using PowerShell's built-in Format-Table for improved
    readability and alignment. Optionally displays the data in Out-GridView when
    running in an interactive session with GUI support.
.PARAMETER Headers
    Array of column header names
.PARAMETER Rows
    Array of row data (each row is an array matching the header count)
.PARAMETER UseGridView
    When set to $true and Out-GridView is available, displays results interactively
.PARAMETER PromptForGridView
    When set to $true, asks the user if they want to use Out-GridView (if available)
#>
function Write-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [string[][]]$Rows,
        [Parameter(Mandatory = $false)]
        [bool]$UseGridView = $false,
        [Parameter(Mandatory = $false)]
        [bool]$PromptForGridView = $false
    )

    # Convert rows to objects for Format-Table
    $tableData = @()
    foreach ($row in $Rows) {
        $obj = New-Object PSObject
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $obj | Add-Member -MemberType NoteProperty -Name $Headers[$i] -Value $row[$i]
        }
        $tableData += $obj
    }

    $shouldUseGridView = $UseGridView

    # Prompt user if requested and Out-GridView is available
    if ($PromptForGridView -and -not $UseGridView) {
        $canUseGridView = $false
        
        # Check if we're in an interactive session
        if ([Environment]::UserInteractive) {
            # Check if Out-GridView is available
            try {
                Get-Command Out-GridView -ErrorAction Stop | Out-Null
                $canUseGridView = $true
            }
            catch {
                # Out-GridView not available, no need to prompt
            }
        }
        
        if ($canUseGridView) {
            Write-Host ''
            $response = Read-Host 'Would you like to view the results in an interactive grid view? (Y/N)'
            if ($response -match '^[Yy]') {
                $shouldUseGridView = $true
            }
        }
    }

    # Try to use Out-GridView if requested and available
    if ($shouldUseGridView) {
        $canUseGridView = $false
        
        # Check if we're in an interactive session
        if ([Environment]::UserInteractive) {
            # Check if Out-GridView is available
            try {
                Get-Command Out-GridView -ErrorAction Stop | Out-Null
                $canUseGridView = $true
            }
            catch {
                Write-Host 'Out-GridView is not available. Falling back to text output.' -ForegroundColor Yellow
            }
        }
        
        if ($canUseGridView) {
            try {
                $tableData | Out-GridView -Title 'Uninstallation Summary' -Wait
                return
            }
            catch {
                Write-Host "Failed to display grid view: $_. Falling back to text output." -ForegroundColor Yellow
            }
        }
    }

    # Use Format-Table for text output
    $output = $tableData | Format-Table -AutoSize | Out-String
    Write-Host $output.TrimEnd()
}

<#
.SYNOPSIS
    Formats an array of app names into a comma-separated string.
.PARAMETER AppArray
    Array of app names to format
#>
function Format-AppList {
    param (
        [Parameter(Mandatory = $false)]
        [array]$AppArray
    )
    
    if ($AppArray -and $AppArray.Count -gt 0) {
        return $AppArray -join ', '
    }
    return $null
}

Write-Host 'Summary:' -ForegroundColor Blue

$headers = @('Status', 'Apps')
$rows = @()

$appList = Format-AppList -AppArray $uninstalledApps
if ($appList) {
    $rows += , @('Uninstalled', $appList)
}

$appList = Format-AppList -AppArray $skippedApps
if ($appList) {
    $rows += , @('Skipped', $appList)
}

$appList = Format-AppList -AppArray $failedApps
if ($appList) {
    $rows += , @('Failed', $appList)
}

Write-Table -Headers $headers -Rows $rows -PromptForGridView $true