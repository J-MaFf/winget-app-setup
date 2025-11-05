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

# ------------------------------------------------Functions------------------------------------------------

<#
.SYNOPSIS
    Ensures the Microsoft.WinGet.Client module is available, installing it if necessary.
.DESCRIPTION
    Checks for the module locally and attempts installation via PowerShell Gallery when missing, including ensuring the NuGet provider is present.
.RETURNS
    [bool] True when the module is available (either already installed or installed successfully), otherwise False.
#>
function Test-AndInstallWingetModule {
    try {
        if (Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client') {
            return $true
        }

        Write-Host 'Microsoft.WinGet.Client module not found. Attempting installation...' -ForegroundColor Yellow
        Write-Host "Host: $($host.Name) | PS Version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-Host 'NuGet package provider not found. Installing...' -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -ErrorAction Stop

        $installedModule = Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' | Select-Object -First 1
        if ($installedModule) {
            if ($installedModule.Version) {
                Write-Host "Microsoft.WinGet.Client module installed successfully (Version: $($installedModule.Version))" -ForegroundColor Green
            }
            else {
                Write-Host 'Microsoft.WinGet.Client module installed successfully' -ForegroundColor Green
            }
            return $true
        }

        Write-Warning 'Microsoft.WinGet.Client module installation completed, but module is still not detected.'
    }
    catch {
        Write-Warning "Failed to install Microsoft.WinGet.Client module: $_"
    }

    return $false
}

<#
.SYNOPSIS
    Ensures Out-GridView is available by installing Microsoft.PowerShell.GraphicalTools when required.
.DESCRIPTION
    Checks for the Out-GridView cmdlet and, when missing, installs the Microsoft.PowerShell.GraphicalTools module including NuGet provider remediation.
.RETURNS
    [bool] True when Out-GridView can be invoked, otherwise False.
#>
function Test-AndInstallGraphicalTools {
    try {
        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            return $true
        }

        $graphicalModule = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.GraphicalTools'
        if (-not $graphicalModule) {
            Write-Host 'Microsoft.PowerShell.GraphicalTools module is missing. Installing to enable Out-GridView...' -ForegroundColor Yellow
            Write-Host "Host: $($host.Name) | PS Version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
        }
        else {
            Write-Host 'Microsoft.PowerShell.GraphicalTools module found but Out-GridView is unavailable. Importing module...' -ForegroundColor Yellow
            Write-Host "Host: $($host.Name) | PS Version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
        }

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-Host 'NuGet package provider not found. Installing...' -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        Install-Module -Name Microsoft.PowerShell.GraphicalTools -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.PowerShell.GraphicalTools -ErrorAction Stop
        
        $loadedModule = Get-Module -Name 'Microsoft.PowerShell.GraphicalTools'
        if ($loadedModule -and $loadedModule.Version) {
            Write-Host "Microsoft.PowerShell.GraphicalTools is loaded for this session (Version: $($loadedModule.Version))" -ForegroundColor Green
        }
        else {
            Write-Host 'Microsoft.PowerShell.GraphicalTools is loaded for this session.' -ForegroundColor Green
        }

        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            Write-Host 'Out-GridView is available for interactive summaries.' -ForegroundColor Green
            return $true
        }

        Write-Warning 'Microsoft.PowerShell.GraphicalTools installation completed, but Out-GridView is still unavailable.'
    }
    catch {
        Write-Warning "Failed to install Microsoft.PowerShell.GraphicalTools module: $_"
    }

    return $false
}

<#!
.SYNOPSIS
    Validates the list of application definitions before processing.
.DESCRIPTION
    Ensures each entry in the apps array is a hashtable containing a non-empty string `name` value and removes duplicates, warning about any issues.
.PARAMETER Apps
    The collection of application definition hash tables to validate.
.RETURNS
    [pscustomobject] containing ValidApps, Errors, and Warnings arrays.
#>
function Test-AppDefinitions {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Apps
    )

    $errors = @()
    $warnings = @()
    $validatedApps = @()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]
        if (-not ($app -is [hashtable])) {
            $errors += "App entry at index $i is not a hashtable."
            continue
        }

        if (-not $app.ContainsKey('name') -or -not ($app['name'] -is [string]) -or [string]::IsNullOrWhiteSpace($app['name'])) {
            $errors += "App entry at index $i is missing a valid 'name' value."
            continue
        }

        $name = $app['name'].Trim()
        if (-not $seenNames.Add($name)) {
            $warnings += "Duplicate app definition detected for '$name'. Subsequent entry ignored."
            continue
        }

        $app['name'] = $name
        $validatedApps += $app
    }

    return [pscustomobject]@{
        ValidApps = $validatedApps
        Errors    = $errors
        Warnings  = $warnings
    }
}

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
    winget source add -n 'msstore' -s 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'
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
    Converts a command string into an array of arguments, properly handling quoted arguments.
.DESCRIPTION
    This function takes a command string and splits it into individual arguments while
    correctly handling quoted strings that may contain spaces.
.PARAMETER Command
    The command string to convert
.RETURNS
    An array of parsed command arguments
#>
function ConvertTo-CommandArguments {
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

<#
.SYNOPSIS
    Relaunches the script with elevated privileges, preferring Windows Terminal when available.
.DESCRIPTION
    Attempts to restart the current script in an elevated session. When Windows Terminal is installed,
    the script is relaunched inside an elevated Windows Terminal tab running the specified PowerShell
    executable. If Windows Terminal is unavailable or fails to start, the function falls back to the
    standard Start-Process call for the provided PowerShell executable.
.PARAMETER PowerShellExecutable
    The PowerShell executable to use when relaunching (for example, pwsh.exe or powershell.exe).
.PARAMETER ScriptPath
    The full path to the script that should be relaunched.
.PARAMETER WindowsTerminalExecutable
    Optional explicit path to the Windows Terminal executable (wt.exe). When not supplied, the
    function attempts to discover it automatically.
.RETURNS
    [string] Returns 'WindowsTerminal' when the Windows Terminal relaunch path succeeds, otherwise
    returns 'PowerShell'.
#>
function Restart-WithElevation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExecutable,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string]$WindowsTerminalExecutable
    )

    $quotedScriptPath = '"' + $ScriptPath.Replace('"', '`"') + '"'
    $commandArguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
    $windowsTerminalPath = $WindowsTerminalExecutable

    if (-not $windowsTerminalPath) {
        $wtCommand = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
        if ($wtCommand) {
            $windowsTerminalPath = $wtCommand.Source
        }
    }

    if ($windowsTerminalPath) {
        Write-Host 'Attempting to relaunch script in Windows Terminal with elevated privileges...' -ForegroundColor Blue
        try {
            Start-Process $windowsTerminalPath -ArgumentList @("$PowerShellExecutable $commandArguments") -Verb RunAs
            return 'WindowsTerminal'
        }
        catch {
            Write-Warning "Failed to start Windows Terminal: $_"
        }
    }

    Write-Host 'Relaunching script in standard PowerShell window with elevated privileges...' -ForegroundColor Blue
    Start-Process $PowerShellExecutable -ArgumentList $commandArguments -Verb RunAs
    return 'PowerShell'
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
                $tableData | Out-GridView -Title 'Installation Summary' -Wait
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
    $commandArgs = ConvertTo-CommandArguments -Command $Command

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
    Tests if there are any available updates for installed packages using winget.
.DESCRIPTION
    This function tests for available updates by attempting different winget commands
    and parsing their output to determine if updates are available.
.RETURNS
    [bool] True if updates are available, otherwise False.
#>
function Test-UpdatesAvailable {
    try {
        Write-Host 'Checking for available updates...' -ForegroundColor Blue

        # Try PowerShell module first
        if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
            $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable

            if ($packagesWithUpdates -and $packagesWithUpdates.Count -gt 0) {
                Write-Host "Found $($packagesWithUpdates.Count) package(s) with available updates." -ForegroundColor Green
                $packagesWithUpdates | ForEach-Object {
                    Write-Host " - $($_.Id) (Current: $($_.InstalledVersion), Available: $($_.AvailableVersion))"
                }
                return $true
            }
        }
        else {
            Write-Host 'PowerShell module not available, using CLI fallback...' -ForegroundColor Yellow

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

    Write-Host 'No updates available.' -ForegroundColor Yellow
    return $false
}

<#
.SYNOPSIS
    Checks if winget is available and attempts to install it if not.
.DESCRIPTION
    This function verifies if winget is installed and available. If not, it attempts to install the Microsoft App Installer.
.RETURNS
    [bool] True if winget is available or successfully installed, otherwise False.
#>
function Test-AndInstallWinget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Winget is available.' -ForegroundColor Green
        return $true
    }
    else {
        Write-Host 'Winget is not available. Attempting to install Microsoft App Installer...' -ForegroundColor Yellow
        try {
            $url = 'https://aka.ms/getwinget'
            $outFile = "$env:TEMP\Microsoft.DesktopAppInstaller.appxbundle"
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
            Add-AppxPackage $outFile
            Remove-Item $outFile -ErrorAction SilentlyContinue
            Write-Host 'Microsoft App Installer installed successfully. Winget should now be available.' -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Failed to install winget: $_" -ForegroundColor Red
            Write-Host 'Please install winget manually from https://aka.ms/getwinget' -ForegroundColor Red
            return $false
        }
    }
}

#------------------------------------------------Main Script------------------------------------------------

<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
#>
function Invoke-WingetInstall {
    # Determine which PowerShell executable to use
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    # Check if the script is run as administrator
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        Write-Host 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.' -ForegroundColor Red
        Pause
        # Relaunch the script with administrator privileges
        Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath | Out-Null
        Exit
    }
    else {
        Write-Host 'Starting...' -ForegroundColor Green
    }

    # Ensure required modules are available
    if (-not (Test-AndInstallWingetModule)) {
        Write-Warning 'Microsoft.WinGet.Client module is not available. Update functionality will use fallback CLI methods.'
    }

    if (-not (Test-AndInstallGraphicalTools)) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Import required modules
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Host 'Successfully imported Microsoft.WinGet.Client module' -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to import Microsoft.WinGet.Client module: $_"
        Write-Warning 'Update functionality will use fallback CLI methods'
    }

    # Check if winget is available and install if necessary
    if (-not (Test-AndInstallWinget)) {
        Write-Host 'Winget is required for this script. Exiting.' -ForegroundColor Red
        Exit
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
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        @{name = 'Dell.CommandUpdate.Universal' },
        @{name = 'Microsoft.PowerShell' },
        @{name = 'Microsoft.WindowsTerminal' }
    );

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-Host $validationError -ForegroundColor Red
        }
        Write-Host 'No valid application definitions found. Resolve the errors and re-run the script.' -ForegroundColor Red
        Exit
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-Host 'No application definitions remain after validation. Add at least one valid entry and re-run the script.' -ForegroundColor Red
        Exit
    }

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
    $hasUpdates = Test-UpdatesAvailable

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
            Write-Host 'PowerShell module not available, using CLI fallback...' -ForegroundColor Yellow

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

    Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

    # Keep the console window open until the user presses a key
    Write-Host 'Press any key to exit...' -ForegroundColor Blue
    [System.Console]::ReadKey($true) > $null
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WingetInstall
}