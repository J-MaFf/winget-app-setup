<#PSScriptInfo

.VERSION 1.0.0

.GUID b5b5f614-90c3-42a9-94e3-b7dd6e6de262

.AUTHOR Joey Maffiola

.EXTERNALMODULEDEPENDENCIES winget, Microsoft.WinGet.Client

.TAGS winget, installation, automation

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES Initial version

.Changelog
    1.0.0 - This is the initial version of the script. It installs a list of programs using winget.
#>


<#
.SYNOPSIS
 Installs a list of programs using winget.

.DESCRIPTION
 This script installs the following programs from winget:

 7-zip
 TightVNC
 Adobe Acrobat Reader 64 Bit
 Google Chrome
 Google Drive
 Dell Command Update (Universal)
 PowerShell
 Windows Terminal
#>

# Import required modules
try {
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    Write-Host "Successfully imported Microsoft.WinGet.Client module" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to import Microsoft.WinGet.Client module: $_"
    Write-Warning "Update functionality will use fallback CLI methods"
}

# ------------------------------------------------Functions------------------------------------------------

<#
.SYNOPSIS
    Checks if a specific winget source is trusted.
.DESCRIPTION
    This function checks if a specific winget source is trusted by listing all sources and checking if the target source is in the list.
.PARAMETER target
    The name of the source to check.
.RETURNS
    [bool] True if the source is trusted, otherwise False.
#>
function Test-Source-IsTrusted($target) {
    $sources = winget source list
    return $sources -match [regex]::Escape($target)
}

<#
.SYNOPSIS
    Adds and trusts the winget source.
.DESCRIPTION
    This function adds and trusts the winget source by adding it to the list of sources.
#>
function Set-Sources {
    winget source add -n 'winget' -s 'https://cdn.winget.microsoft.com/cache'
    winget source add -n 'msstore' -s ' https://storeedgefd.dsx.mp.microsoft.com/v9.0'
}

<#
.SYNOPSIS
    Adds a specified path to the environment PATH variable.
.DESCRIPTION
    This function adds a specified path to the environment PATH variable for either the user or the system scope.
.PARAMETER PathToAdd
    The path to add to the environment PATH variable.
.PARAMETER Scope
    The scope to which the path should be added. Valid values are 'User' and 'System'.
#>
function Add-ToEnvironmentPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PathToAdd,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    # Check if the path is already in the environment PATH variable
    if (-not (Test-PathInEnvironment -PathToCheck $PathToAdd -Scope $Scope)) {
        if ($Scope -eq 'System') {
            # Get the current system PATH
            $systemEnvPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
            # Add to system PATH
            $systemEnvPath += ";$PathToAdd"
            [System.Environment]::SetEnvironmentVariable('PATH', $systemEnvPath, [System.EnvironmentVariableTarget]::Machine)
        }
        elseif ($Scope -eq 'User') {
            # Get the current user PATH
            $userEnvPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
            # Add to user PATH
            $userEnvPath += ";$PathToAdd"
            [System.Environment]::SetEnvironmentVariable('PATH', $userEnvPath, [System.EnvironmentVariableTarget]::User)
        }

        # Update the current process environment PATH
        if (-not ($env:PATH -split ';').Contains($PathToAdd)) {
            $env:PATH += ";$PathToAdd"
        }
    }
}

<#
.SYNOPSIS
    Checks if a specified path is in the environment PATH variable.
.DESCRIPTION
    This function checks if a specified path is in the environment PATH variable for either the user or the system scope.
.PARAMETER PathToCheck
    The path to check in the environment PATH variable.
.PARAMETER Scope
    The scope in which to check the path. Valid values are 'User' and 'System'.
#>
function Test-PathInEnvironment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PathToCheck,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    if ($Scope -eq 'System') {
        $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
    }
    elseif ($Scope -eq 'User') {
        $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
    }

    return ($envPath -split ';').Contains($PathToCheck)
}

<#
.SYNOPSIS
    Parses a command string into an array of arguments, properly handling quoted arguments.
.DESCRIPTION
    This function takes a command string and splits it into individual arguments while
    correctly handling quoted strings that may contain spaces.
.PARAMETER Command
    The command string to parse
.RETURNS
    An array of parsed command arguments
#>
function Convert-CommandToArguments {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $commandArgs = @()
    $currentArg = ''
    $inQuotes = $false
    $quoteChar = ''

    for ($i = 0; $i -lt $Command.Length; $i++) {
        $char = $Command[$i]

        if ($inQuotes) {
            if ($char -eq $quoteChar) {
                $inQuotes = $false
                $quoteChar = ''
            }
            else {
                $currentArg += $char
            }
        }
        elseif ($char -eq '"' -or $char -eq "'") {
            $inQuotes = $true
            $quoteChar = $char
        }
        elseif ($char -eq ' ') {
            if ($currentArg) {
                $commandArgs += $currentArg
                $currentArg = ''
            }
        }
        else {
            $currentArg += $char
        }
    }

    if ($currentArg) {
        $commandArgs += $currentArg
    }

    return $commandArgs
}

function Show-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [string[][]]$Rows
    )

    $maxLengths = @{}
    foreach ($header in $Headers) {
        $maxLengths[$header] = $header.Length
    }

    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $row.Length; $i++) {
            if ($row[$i].Length -gt $maxLengths[$Headers[$i]]) {
                $maxLengths[$Headers[$i]] = $row[$i].Length
            }
        }
    }

    # Build table divider with proper column separators
    $dividerParts = @('+')
    foreach ($header in $Headers) {
        $columnWidth = $maxLengths[$header] + 2  # Add padding for spaces
        $dividerParts += ('-' * $columnWidth)
        $dividerParts += '+'
    }
    $divider = $dividerParts -join ''

    # Build header line
    $headerLine = ''
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $padSize = $maxLengths[$Headers[$i]] - $Headers[$i].Length
        $headerLine += '|' + ' ' + $Headers[$i] + (' ' * $padSize) + ' '
    }
    $headerLine += '|'

    Write-Host $divider
    Write-Host $headerLine
    Write-Host $divider

    foreach ($row in $Rows) {
        $rowLine = ''
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $cellValue = $row[$i]
            $padSize = $maxLengths[$Headers[$i]] - $cellValue.Length
            $rowLine += '|' + ' ' + $cellValue + (' ' * $padSize) + ' '
        }
        $rowLine += '|'

        Write-Host $rowLine
        Write-Host $divider
    }
}

<#
.SYNOPSIS
    Runs a winget command and processes its output for success/failure tracking.
.DESCRIPTION
    This function executes a winget command, displays its output naturally, and parses the results
    to track successful and failed operations.
.PARAMETER Command
    The winget command to execute (e.g., "update --all --include-unknown")
.PARAMETER SuccessPattern
    Regex pattern to match successful operations
.PARAMETER FailurePattern
    Regex pattern to match failed operations
.PARAMETER SuccessArray
    Reference to array that will store successful app names
.PARAMETER FailureArray
    Reference to array that will store failed app names
.PARAMETER SuccessIndex
    Index in the split result to extract the app name for successful operations (default: 1)
.PARAMETER FailureIndex
    Index in the split result to extract the app name for failed operations (default: 1)
#>
function Invoke-WingetCommand {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$SuccessPattern,

        [Parameter(Mandatory = $true)]
        [string]$FailurePattern,

        [Parameter(Mandatory = $true)]
        [ref]$SuccessArray,

        [Parameter(Mandatory = $true)]
        [ref]$FailureArray,

        [Parameter(Mandatory = $false)]
        [int]$SuccessIndex = 1,

        [Parameter(Mandatory = $false)]
        [int]$FailureIndex = 1
    )

    # Parse command string into arguments properly, handling quoted arguments
    $commandArgs = Convert-CommandToArguments -Command $Command

    & winget $commandArgs

    # Now run again to capture output for parsing (without progress display)
    try {
        $commandOutput = & winget $commandArgs 2>&1 | Where-Object { $_ -notmatch '^[\s\-\|\\]*$' }
    }
    catch {
        Write-Host "Error capturing winget output: $($_)" -ForegroundColor Red
        $commandOutput = @()
    }

    $commandOutput | ForEach-Object {
        if ($_ -match $SuccessPattern) {
            $SuccessArray.Value += $_.Split()[$SuccessIndex]
        }
        elseif ($_ -match $FailurePattern) {
            $FailureArray.Value += $_.Split()[$FailureIndex]
        }
    }
}

<#
.SYNOPSIS
    Formats an array of app names for display in the summary table.
.DESCRIPTION
    This function checks if an array has content and formats it as a comma-separated string.
.PARAMETER AppArray
    The array of app names to format
.RETURNS
    A formatted string of app names, or $null if the array is empty
#>
function Format-AppList {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$AppArray
    )

    if ($AppArray -and $AppArray.Count -gt 0) {
        return $AppArray -join ', '
    }
    return $null
}

<#
.SYNOPSIS
    Checks if there are any available updates for installed packages using winget.
.DESCRIPTION
    This function checks for available updates by attempting different winget commands
    and parsing their output to determine if updates are available.
.RETURNS
    [bool] True if updates are available, otherwise False.
#>
function Get-HasUpdates {
    try {
        Write-Host "Checking for available updates..." -ForegroundColor Blue

        # Try PowerShell module first
        if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
            $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable

            if ($packagesWithUpdates -and $packagesWithUpdates.Count -gt 0) {
                Write-Host "Found $($packagesWithUpdates.Count) package(s) with available updates." -ForegroundColor Green
                return $true
            }
        }
        else {
            Write-Host "PowerShell module not available, using CLI fallback..." -ForegroundColor Yellow

            # Fallback to CLI method
            $basicUpgradeResult = & winget upgrade 2>&1
            $basicOutput = $basicUpgradeResult | Out-String

            if ($basicOutput -notmatch 'No installed package found matching input criteria' -and
                $basicOutput -notmatch 'No available upgrade found') {
                return $true
            }
        }
    }
    catch {
        Write-Warning "Error checking for updates: $_"
    }

    Write-Host "No updates available." -ForegroundColor Yellow
    return $false
}

#------------------------------------------------Main Script------------------------------------------------

# Determine which PowerShell executable to use
$psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Host 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.' -ForegroundColor Red
    Pause
    # Relaunch the script with administrator privileges
    Start-Process $psExecutable -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}
else {
    Write-Host 'Starting...' -ForegroundColor Green
}

# Add the script directory to the PATH
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'

$apps = @(
    @{name = '7zip.7zip' },
    @{name = 'GlavSoft.TightVNC' },
    @{name = 'Adobe.Acrobat.Reader.64-bit' },
    @{name = 'Google.Chrome' },
    @{name = 'Google.GoogleDrive' },
    @{name = 'Dell.CommandUpdate.Universal' },
    @{name = 'Microsoft.PowerShell' },
    @{name = 'Microsoft.WindowsTerminal' }
);

Write-Host 'Installing the following Apps:' -ForegroundColor Blue
ForEach ($app in $apps) {
    Write-Host $app.name -ForegroundColor Blue
}

$installedApps = @()
$skippedApps = @()
$failedApps = @()

# Verify sources are trusted
$trustedSources = @('winget', 'msstore')
ForEach ($source in $trustedSources) {
    if (-not (Test-Source-IsTrusted -target $source)) {
        Write-Host 'Trusting source: $source' -ForegroundColor Yellow
        Set-Sources
    }
    else {
        Write-Host "Source is already trusted: $source" -ForegroundColor Green
    }
}


Foreach ($app in $apps) {
    try {
        $listApp = winget list --exact -q $app.name
        if (![String]::Join('', $listApp).Contains($app.name)) {
            Write-Host 'Installing: ' $app.name -ForegroundColor Blue
            Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
            $installResult = winget list --exact -q $app.name
            if (![String]::Join('', $installResult).Contains($app.name)) {
                Write-Host "Failed to install: $($app.name). No package found matching input criteria." -ForegroundColor Red
                $failedApps += $app.name
            }
            else {
                Write-Host 'Successfully installed: ' $app.name -ForegroundColor Green
                $installedApps += $app.name
            }
        }
        else {
            Write-Host 'Skipping: ' $app.name ' (already installed)' -ForegroundColor Yellow
            $skippedApps += $app.name
        }
    }
    catch {
        Write-Host "Failed to install: $($app.name). Error: $_" -ForegroundColor Red
        $failedApps += $app.name
    }
}

$updatedApps = @()
$failedUpdateApps = @()

# Check for updates and perform them in one step
$hasUpdates = Get-HasUpdates

if ($hasUpdates) {
    Write-Host 'Updates found. Installing updates...' -ForegroundColor Green

    # Try PowerShell module first
    if (Get-Command Update-WinGetPackage -ErrorAction SilentlyContinue) {
        $updateResults = Get-WinGetPackage | Where-Object IsUpdateAvailable | Update-WinGetPackage

        foreach ($result in $updateResults) {
            if ($result.Status -eq 'Ok') {
                $updatedApps += $result.Id
                Write-Host "Successfully updated: $($result.Id)" -ForegroundColor Green
            }
            else {
                $failedUpdateApps += $result.Id
                Write-Host "Failed to update: $($result.Id) - $($result.Status)" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "PowerShell module not available, using CLI fallback..." -ForegroundColor Yellow

        # Fallback to CLI method - get list of packages that have updates available
        $installedPackages = & winget list --source winget 2>&1 | Where-Object {
            $_ -and
            $_ -notmatch '^[\s\-\|\\]*$' -and
            $_ -notmatch '^$' -and
            $_ -notmatch '^Name\s+Id\s+Version\s+Source' -and
            $_ -notmatch '^[-]+$' -and
            $_ -notmatch 'No installed package found'
        }

        foreach ($package in $installedPackages) {
            $package = $package.Trim()
            # Split the line by multiple spaces to get columns
            # Format: Name | Id | Version | Source
            $columns = $package -split '\s{2,}'
            if ($columns.Count -ge 2) {
                $packageId = $columns[1]  # Second column is the ID

                # Skip if it's not a winget package or if it's a system component
                if ($packageId -and $packageId -notmatch '^(ARP|MSIX)') {
                    try {
                        $upgradeResult = & winget upgrade $packageId 2>&1
                        $upgradeOutput = $upgradeResult | Out-String

                        # Check if upgrade is available and successful
                        if ($upgradeOutput -match 'Successfully installed') {
                            $updatedApps += $packageId
                            Write-Host "Successfully updated: $packageId" -ForegroundColor Green
                        }
                        elseif ($upgradeOutput -notmatch 'No available upgrade found' -and
                                $upgradeOutput -notmatch 'No newer package versions are available') {
                            # Package has an update but installation may have failed
                            $failedUpdateApps += $packageId
                            Write-Host "Failed to update: $packageId" -ForegroundColor Red
                        }
                    }
                    catch {
                        $failedUpdateApps += $packageId
                        Write-Host "Error updating ${packageId}: $_" -ForegroundColor Red
                    }
                }
            }
        }
    }
}
else {
    Write-Host 'No updates available.' -ForegroundColor Yellow
}

# Display the summary of the installation
Write-Host 'Summary:' -ForegroundColor Blue

$headers = @('Status', 'Apps')
$rows = @()

$appList = Format-AppList -AppArray $installedApps
if ($appList) {
    $rows += , @('Installed', $appList)
}

$appList = Format-AppList -AppArray $skippedApps
if ($appList) {
    $rows += , @('Skipped', $appList)
}

$appList = Format-AppList -AppArray $failedApps
if ($appList) {
    $rows += , @('Failed', $appList)
}

$appList = Format-AppList -AppArray $updatedApps
if ($appList) {
    $rows += , @('Updated', $appList)
}

$appList = Format-AppList -AppArray $failedUpdateApps
if ($appList) {
    $rows += , @('Failed to Update', $appList)
}

Show-Table -Headers $headers -Rows $rows

# Keep the console window open until the user presses a key
Write-Host 'Press any key to exit...' -ForegroundColor Blue
[System.Console]::ReadKey($true) > $null
