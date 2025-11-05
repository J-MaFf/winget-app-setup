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

.PARAMETER WhatIf
 When specified, performs all pre-flight checks and displays planned actions without making any system changes.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

# ------------------------------------------------Functions------------------------------------------------

<#
.SYNOPSIS
    Checks and adjusts PowerShell execution policy to allow script execution.
.DESCRIPTION
    Verifies the current execution policy for the CurrentUser scope and attempts to set it to RemoteSigned if it's too restrictive.
.RETURNS
    [bool] True when the execution policy allows script execution, otherwise False.
#>
function Test-AndSetExecutionPolicy {
    try {
        $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser

        # Check if policy is already permissive
        $permissivePolicies = @('RemoteSigned', 'Unrestricted', 'Bypass')
        if ($permissivePolicies -contains $currentPolicy) {
            return $true
        }

        # Try to set to RemoteSigned
        Write-WarningMessage "Current execution policy ($currentPolicy) prevents script execution. Attempting to set to RemoteSigned..."
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

            # Verify the change
            $newPolicy = Get-ExecutionPolicy -Scope CurrentUser
            if ($permissivePolicies -contains $newPolicy) {
                Write-Success "Execution policy successfully set to $newPolicy"
                return $true
            }
            else {
                Write-Warning "Execution policy change may not have taken effect. Current policy: $newPolicy"
                return $false
            }
        }
        catch {
            Write-Warning "Failed to set execution policy: $_"
            Write-Warning 'You may need to manually set the execution policy using:'
            Write-Warning '  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force'
            Write-Warning 'Or run PowerShell as Administrator and use:'
            Write-Warning '  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force'
            return $false
        }
    }
    catch {
        Write-Warning "Error checking execution policy: $_"
        return $false
    }
}

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

        Write-WarningMessage 'Microsoft.WinGet.Client module not found. Attempting installation...'

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-WarningMessage 'NuGet package provider not found. Installing...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -ErrorAction Stop

        $installedModule = Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' | Select-Object -First 1
        if ($installedModule) {
            if ($installedModule.Version) {
                Write-Success "Microsoft.WinGet.Client module installed successfully (Version: $($installedModule.Version))"
            }
            else {
                Write-Success 'Microsoft.WinGet.Client module installed successfully'
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
            Write-WarningMessage 'Microsoft.PowerShell.GraphicalTools module is missing. Installing to enable Out-GridView...'
        }
        else {
            Write-WarningMessage 'Microsoft.PowerShell.GraphicalTools module found but Out-GridView is unavailable. Importing module...'
        }

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-WarningMessage 'NuGet package provider not found. Installing...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        Install-Module -Name Microsoft.PowerShell.GraphicalTools -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.PowerShell.GraphicalTools -ErrorAction Stop
        Write-Success 'Microsoft.PowerShell.GraphicalTools is loaded for this session.'

        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            Write-Success 'Out-GridView is available for interactive summaries.'
            return $true
        }

        Write-Warning 'Microsoft.PowerShell.GraphicalTools installation completed, but Out-GridView is still unavailable.'
    }
    catch {
        Write-Warning "Failed to install Microsoft.PowerShell.GraphicalTools module: $_"
    }

    return $false
}

<#
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
    Automatically accepts source agreements to prevent the script from hanging on first run.
.PARAMETER target
    The name of the source to check.
.RETURNS
    [bool] True if the source is trusted, otherwise False.
#>
function Test-Source-IsTrusted($target) {
    try {
        $sources = winget source list --disable-interactivity 2>&1
        return $sources -match [regex]::Escape($target)
    }
    catch {
        Write-Warning "Error checking source trust for ${target}: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Adds and trusts the winget source.
.DESCRIPTION
    This function adds and trusts the winget source by resetting sources to defaults.
    Automatically accepts source agreements to prevent prompts.
    Uses a timeout mechanism to prevent the function from hanging indefinitely.
#>
function Set-Sources {
    try {
        Write-Info 'Resetting winget sources (this may take a moment)...'

        # Run winget source reset with a timeout to prevent hanging
        # Using Start-Process with a timeout to handle potential hangs
        # Both --disable-interactivity and --accept-source-agreements are required:
        # --disable-interactivity prevents prompts, --accept-source-agreements auto-accepts terms
        $resetProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'source', 'reset', '--force', '--disable-interactivity', '--accept-source-agreements' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput "$env:TEMP\winget_reset_output.txt" `
            -RedirectStandardError "$env:TEMP\winget_reset_error.txt"

        # Wait up to 30 seconds for the process to complete
        $timeout = 30
        if (-not $resetProcess.WaitForExit($timeout * 1000)) {
            # Process timed out, kill it
            Write-WarningMessage "Winget source reset timed out after $timeout seconds. Terminating process..."
            $resetProcess.Kill()
            Write-WarningMessage 'Consider running "winget source reset --force" manually if sources are not properly configured.'
            return $false
        }

        # Check the exit code
        if ($resetProcess.ExitCode -eq 0) {
            Write-Success 'Winget sources reset successfully'
            return $true
        }
        else {
            # Non-zero exit code, but not critical since script continues
            Write-Info "Winget source reset completed with exit code: $($resetProcess.ExitCode) (this is often not critical)"
            return $false
        }
    }
    catch {
        Write-WarningMessage "Could not reset sources (this is usually okay): $_"
        return $false
    }
    finally {
        # Clean up temp files
        Remove-Item "$env:TEMP\winget_reset_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\winget_reset_error.txt" -ErrorAction SilentlyContinue
    }
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

        # Update the current process environment PATH (with length check to avoid Windows PATH limit of 2048)
        if (-not ($env:PATH -split ';').Contains($PathToAdd)) {
            $newPath = "$env:PATH;$PathToAdd"
            # Only update if it won't exceed the Windows PATH limit
            if ($newPath.Length -le 2048) {
                $env:PATH = $newPath
            }
            else {
                Write-WarningMessage 'Current process PATH would exceed Windows limit (2048 chars). Path added to persistent environment but not to current session.'
            }
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
        Write-Info 'Attempting to relaunch script in Windows Terminal with elevated privileges...'
        try {
            Start-Process $windowsTerminalPath -ArgumentList @("$PowerShellExecutable $commandArguments") -Verb RunAs
            return 'WindowsTerminal'
        }
        catch {
            Write-Warning "Failed to start Windows Terminal: $_"
        }
    }

    Write-Info 'Relaunching script in standard PowerShell window with elevated privileges...'
    Start-Process $PowerShellExecutable -ArgumentList $commandArguments -Verb RunAs
    return 'PowerShell'
}

<#
.SYNOPSIS
    Checks if Out-GridView is available in the current session.
.DESCRIPTION
    Determines whether Out-GridView can be used by checking if the session is
    interactive and if the Out-GridView command is available. This is used to
    decide whether to offer or use the interactive grid view functionality.
.OUTPUTS
    Returns $true if Out-GridView is available, $false otherwise.
#>
function Test-CanUseGridView {
    # Check if we're in an interactive session
    if (-not [Environment]::UserInteractive) {
        return $false
    }

    # Check if Out-GridView is available
    try {
        Get-Command Out-GridView -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
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
        [bool]$PromptForGridView = $false,
        [Parameter(Mandatory = $false)]
        [string]$Title = 'Summary'
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
        if (Test-CanUseGridView) {
            Write-Host ''
            $response = Read-Host 'Would you like to view the results in an interactive grid view? (Y/N)'
            if ($response -match '^[Yy]') {
                $shouldUseGridView = $true
            }
        }
    }

    # Try to use Out-GridView if requested and available
    if ($shouldUseGridView) {
        if (-not (Test-CanUseGridView)) {
            Write-WarningMessage 'Out-GridView is not available. Falling back to text output.'
        }
        else {
            try {
                $tableData | Out-GridView -Title $Title -Wait
                return
            }
            catch {
                Write-WarningMessage "Failed to display grid view: $_. Falling back to text output."
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
    This function executes a winget command, displays its output naturally, captures exit codes,
    and parses the results to track successful and failed operations. When winget exits with a
    non-zero exit code, it maps the code to a meaningful error message.
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
.RETURNS
    [hashtable] containing ExitCode and ExitMessage for the winget command execution
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

    # First execution: Display output to user with natural progress indicators
    & winget $commandArgs

    # Second execution: Capture output for parsing (suppresses progress bars and extra formatting)
    # We use the second execution's exit code because it represents the final, complete state
    try {
        $commandOutput = & winget $commandArgs 2>&1 | Where-Object { $_ -notmatch '^[\s\-\|\\]*$' }
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-ErrorMessage "Error capturing winget output: $($_)"
        $commandOutput = @()
        $exitCode = -1
    }

    # Map exit code to meaningful message
    $exitMessage = switch ($exitCode) {
        0 { 'Success' }
        -1978335189 { 'No applicable update found' }
        -1978335191 { 'No packages found matching input criteria' }
        -1978335192 { 'Package installation failed' }
        -1978335212 { 'User cancelled the operation' }
        -1978335213 { 'Package already installed' }
        -1978335215 { 'Manifest validation failed' }
        -1978335216 { 'Invalid manifest' }
        -1978335221 { 'Package download failed' }
        -1978335226 { 'Hash mismatch' }
        default { "Winget exited with code: $exitCode" }
    }

    $commandOutput | ForEach-Object {
        if ($_ -match $SuccessPattern) {
            $SuccessArray.Value += $_.Split()[$SuccessIndex]
        }
        elseif ($_ -match $FailurePattern) {
            $FailureArray.Value += $_.Split()[$FailureIndex]
        }
    }

    # If exit code indicates failure but no failures were captured via pattern matching,
    # report a generic failure
    if ($exitCode -ne 0 -and $FailureArray.Value.Count -eq 0 -and $SuccessArray.Value.Count -eq 0) {
        Write-ErrorMessage "Winget command failed: $exitMessage"
        # Add a generic failure entry to indicate the command failed
        $FailureArray.Value += "Command failed with exit code $exitCode"
    }

    return @{
        ExitCode    = $exitCode
        ExitMessage = $exitMessage
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
        Write-Info 'Checking for available updates...'

        # Try PowerShell module first
        if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
            $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable

            if ($packagesWithUpdates -and $packagesWithUpdates.Count -gt 0) {
                Write-Success "Found $($packagesWithUpdates.Count) package(s) with available updates."
                $packagesWithUpdates | ForEach-Object {
                    Write-Host " - $($_.Id) (Current: $($_.InstalledVersion), Available: $($_.AvailableVersion))"
                }
                return $true
            }
        }
        else {
            Write-WarningMessage 'PowerShell module not available, using CLI fallback...'

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

    Write-WarningMessage 'No updates available.'
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
        Write-Success 'Winget is available.'
        return $true
    }
    else {
        Write-WarningMessage 'Winget is not available. Attempting to install Microsoft App Installer...'
        try {
            $url = 'https://aka.ms/getwinget'
            $outFile = "$env:TEMP\Microsoft.DesktopAppInstaller.appxbundle"
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
            Add-AppxPackage $outFile
            Remove-Item $outFile -ErrorAction SilentlyContinue
            Write-Success 'Microsoft App Installer installed successfully. Winget should now be available.'
            return $true
        }
        catch {
            Write-ErrorMessage "Failed to install winget: $_"
            Write-ErrorMessage 'Please install winget manually from https://aka.ms/getwinget'
            return $false
        }
    }
}

<#
.SYNOPSIS
    Writes an informational message in blue color.
.DESCRIPTION
    Helper function for consistent informational and action messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Info {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Writes a success message in green color.
.DESCRIPTION
    Helper function for consistent success messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Success {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Green
}

<#
.SYNOPSIS
    Writes a warning message in yellow color.
.DESCRIPTION
    Helper function for consistent warning and skip messages throughout the script.
    Named Write-WarningMessage to avoid conflict with built-in Write-Warning cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-WarningMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Yellow
}

<#
.SYNOPSIS
    Writes an error message in red color.
.DESCRIPTION
    Helper function for consistent error messages throughout the script.
    Named Write-ErrorMessage to avoid conflict with built-in Write-Error cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Red
}

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

#------------------------------------------------Main Script------------------------------------------------

<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
#>
function Invoke-WingetInstall {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    # Check and set execution policy if needed (before any other checks)
    if (-not $WhatIf) {
        if (Get-Command Test-AndSetExecutionPolicy -ErrorAction SilentlyContinue) {
            if (-not (Test-AndSetExecutionPolicy)) {
                Write-WarningMessage 'Warning: Execution policy could not be verified or adjusted. Script may fail.'
                Write-Prompt 'Press any key to continue anyway...'
                [void][System.Console]::ReadKey($true)
            }
        }
    }
    else {
        Write-Info '[DRY-RUN] Would check and set execution policy if needed'
    }

    # Determine which PowerShell executable to use
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    # Check if the script is run as administrator
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        Write-ErrorMessage 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.'
        Pause
        # Relaunch the script with administrator privileges
        Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath | Out-Null
        Exit
    }
    else {
        Write-Success 'Starting...'
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
        Write-Success 'Successfully imported Microsoft.WinGet.Client module'
    }
    catch {
        Write-Warning "Failed to import Microsoft.WinGet.Client module: $_"
        Write-Warning 'Update functionality will use fallback CLI methods'
    }

    # Check if winget is available and install if necessary
    if (-not (Test-AndInstallWinget)) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        Exit
    }

    # Add the script directory to the PATH
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not $WhatIf) {
        Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'
    }
    else {
        Write-Info "[DRY-RUN] Would add '$scriptDirectory' to User PATH"
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

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'No valid application definitions found. Resolve the errors and re-run the script.'
        Exit
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        Exit
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()

    # Verify sources are trusted
    $trustedSources = @('winget', 'msstore')
    ForEach ($source in $trustedSources) {
        if (-not (Test-Source-IsTrusted -target $source)) {
            if (-not $WhatIf) {
                Write-WarningMessage "Trusting source: $source"
                Set-Sources
            }
            else {
                Write-Info "[DRY-RUN] Would trust source: $source"
            }
        }
        else {
            Write-Success "Source is already trusted: $source"
        }
    }

    Foreach ($app in $apps) {
        try {
            # Run winget list with timeout to prevent hanging
            $listProcess = Start-Process -FilePath 'winget' `
                -ArgumentList 'list', '--exact', '-q', '--accept-source-agreements', $app.name `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput "$env:TEMP\winget_list_output.txt" `
                -RedirectStandardError "$env:TEMP\winget_list_error.txt"

            # Wait up to 15 seconds for the list command
            if (-not $listProcess.WaitForExit(15000)) {
                Write-WarningMessage "Winget list timed out for $($app.name). Skipping..."
                $listProcess.Kill()
                Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\winget_list_error.txt" -ErrorAction SilentlyContinue
                continue
            }

            $listApp = Get-Content "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue

            # Cleanup temp files
            Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\winget_list_error.txt" -ErrorAction SilentlyContinue

            if (![String]::Join('', $listApp).Contains($app.name)) {
                if (-not $WhatIf) {
                    Write-Info "Installing: $($app.name)"
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait

                    # Verify installation with timeout
                    $verifyProcess = Start-Process -FilePath 'winget' `
                        -ArgumentList 'list', '--exact', '-q', '--accept-source-agreements', $app.name `
                        -NoNewWindow `
                        -PassThru `
                        -RedirectStandardOutput "$env:TEMP\winget_verify_output.txt" `
                        -RedirectStandardError "$env:TEMP\winget_verify_error.txt"

                    if ($verifyProcess.WaitForExit(15000)) {
                        $installResult = Get-Content "$env:TEMP\winget_verify_output.txt" -ErrorAction SilentlyContinue
                        if (![String]::Join('', $installResult).Contains($app.name)) {
                            Write-ErrorMessage "Failed to install: $($app.name). No package found matching input criteria."
                            $failedApps += $app.name
                        }
                        else {
                            Write-Success "Successfully installed: $($app.name)"
                            $installedApps += $app.name
                        }
                    }
                    else {
                        Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
                        $verifyProcess.Kill()
                        $failedApps += $app.name
                    }

                    # Cleanup temp files
                    Remove-Item "$env:TEMP\winget_verify_output.txt" -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\winget_verify_error.txt" -ErrorAction SilentlyContinue
                }
                else {
                    Write-Info "[DRY-RUN] Would install: $($app.name)"
                    $installedApps += $app.name
                }
            }
            else {
                Write-WarningMessage "Skipping: $($app.name) (already installed)"
                $skippedApps += $app.name
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += $app.name
        }
    }

    $updatedApps = @()
    $failedUpdateApps = @()

    # Check for updates and perform them in one step
    $hasUpdates = Test-UpdatesAvailable

    if ($hasUpdates) {
        if (-not $WhatIf) {
            Write-Success 'Updates found. Installing updates...'

            # Try PowerShell module first
            if (Get-Command Update-WinGetPackage -ErrorAction SilentlyContinue) {
                $updateResults = Get-WinGetPackage | Where-Object IsUpdateAvailable | Update-WinGetPackage

                foreach ($result in $updateResults) {
                    if ($result.Status -eq 'Ok') {
                        $updatedApps += $result.Id
                        Write-Success "Successfully updated: $($result.Id)"
                    }
                    else {
                        $failedUpdateApps += $result.Id
                        Write-ErrorMessage "Failed to update: $($result.Id) - $($result.Status)"
                    }
                }
            }
            else {
                Write-WarningMessage 'PowerShell module not available, using CLI fallback...'

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
                                    Write-Success "Successfully updated: $packageId"
                                }
                                elseif ($upgradeOutput -notmatch 'No available upgrade found' -and
                                    $upgradeOutput -notmatch 'No newer package versions are available') {
                                    # Package has an update but installation may have failed
                                    $failedUpdateApps += $packageId
                                    Write-ErrorMessage "Failed to update: $packageId"
                                }
                            }
                            catch {
                                $failedUpdateApps += $packageId
                                Write-ErrorMessage "Error updating ${packageId}: $_"
                            }
                        }
                    }
                }
            }
        }
        else {
            Write-Info '[DRY-RUN] Updates are available. Would install the following updates:'
            # Try PowerShell module first for listing
            if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
                $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable
                foreach ($pkg in $packagesWithUpdates) {
                    Write-Info "[DRY-RUN] Would update: $($pkg.Id) (Current: $($pkg.InstalledVersion), Available: $($pkg.AvailableVersion))"
                    $updatedApps += $pkg.Id
                }
            }
            else {
                Write-Info '[DRY-RUN] Would update available packages (using CLI fallback)'
            }
        }
    }
    else {
        Write-WarningMessage 'No updates available.'
    }

    # Display the summary of the installation
    if ($WhatIf) {
        Write-Info ''
        Write-Info '=== DRY-RUN SUMMARY ==='
        Write-Info 'The following actions would have been performed:'
    }
    else {
        Write-Info 'Summary:'
    }

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

    Write-Table -Headers $headers -Rows $rows -PromptForGridView $true -Title 'Installation Summary'

    # Keep the console window open until the user presses a key
    Write-Prompt 'Press any key to exit...'
    [void][System.Console]::ReadKey($true)
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WingetInstall -WhatIf:$WhatIf
}