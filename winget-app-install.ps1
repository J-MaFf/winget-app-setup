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
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$EnableScheduledUpdates,
    [Parameter(Mandatory = $false)]
    [switch]$DisableScheduledUpdates,
    [Parameter(Mandatory = $false)]
    [switch]$CheckForUpdates,
    [Parameter(Mandatory = $false)]
    [switch]$AutoInstallUpdates,
    [Parameter(Mandatory = $false)]
    [ValidateSet('Weekly', 'Daily')]
    [string]$UpdateFrequency = 'Weekly'
)

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
        $sources = winget source list --disable-interactivity --accept-source-agreements 2>&1
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

        # Read error output to provide better error messages
        $errorOutput = Get-Content "$env:TEMP\winget_reset_error.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }

        # Check the exit code
        if ($resetProcess.ExitCode -eq 0) {
            Write-Success 'Winget sources reset successfully'
            return $true
        }
        else {
            # Log the error details if available
            if ($errorOutput) {
                Write-WarningMessage "Winget source reset error details: $(($errorOutput -join ', '))"
            }
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
    Detects if the script is running locally or from a remote source (e.g., via IEX).
.DESCRIPTION
    Checks if $PSScriptRoot is non-empty and represents a valid directory.
    Returns $true for local execution (file on disk), $false for remote execution (piped script).
.RETURNS
    [bool] True if running locally, False if running remotely.
#>
function Test-IsRunningLocally {
    # Check if $PSScriptRoot is non-empty and valid
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $false
    }

    # Verify it's an actual directory path
    try {
        $null = Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
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

    # Single execution: invoke winget once, capturing all output (stdout + stderr) so we
    # can both display it to the user and parse it. Running winget twice (as the previous
    # implementation did) caused duplicate prompts and spurious "already installed" failures
    # because the package state changed between the two invocations (see issue #134).
    try {
        # Capture the raw output first so $LASTEXITCODE reflects winget's own exit code,
        # not the exit code of a downstream pipeline element (e.g. Where-Object), which
        # would otherwise reset it to 0.
        $rawOutput = & winget $commandArgs 2>&1
        $exitCode = $LASTEXITCODE

        # Echo the captured output to the user so they still see winget's progress/results.
        $rawOutput | ForEach-Object { Write-Host $_ }

        # Filter out blank lines and progress-bar artifacts before pattern parsing.
        $commandOutput = $rawOutput | Where-Object { $_ -notmatch '^[\s\-\|\\]*$' }
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
            try {
                $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable

                if ($packagesWithUpdates -and $packagesWithUpdates.Count -gt 0) {
                    Write-Success "Found $($packagesWithUpdates.Count) package(s) with available updates."
                    $packagesWithUpdates | ForEach-Object {
                        Write-Host " - $($_.Id) (Current: $($_.InstalledVersion), Available: $($_.AvailableVersion))"
                    }
                    return $true
                }
                # Module succeeded but found no updates — return early without CLI fallback
                Write-WarningMessage 'No updates available.'
                return $false
            }
            catch {
                Write-Warning "PowerShell module error, falling back to CLI: $_"
            }
        }
        else {
            Write-WarningMessage 'PowerShell module not available, using CLI fallback...'
        }

        # CLI fallback (used when module is unavailable or threw an error)
        $basicUpgradeResult = & winget upgrade 2>&1
        $basicOutput = $basicUpgradeResult | Out-String

        if ($basicOutput -notmatch 'No installed package found matching input criteria' -and
            $basicOutput -notmatch 'No available upgrade found') {
            return $true
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
    Returns the filesystem paths used by scheduled update functionality.
#>
function Get-UpdateSettingsPaths {
    $basePath = Join-Path $env:APPDATA 'winget-app-setup'
    return @{
        BasePath        = $basePath
        ConfigFile      = Join-Path $basePath 'update-config.json'
        UpdateChecks    = Join-Path $basePath 'update-checks'
        RollbackScripts = Join-Path $basePath 'rollback-scripts'
        HelperScript    = Join-Path $basePath 'Update-InstalledApps.ps1'
    }
}

<#
.SYNOPSIS
    Returns the default update configuration object.
#>
function New-DefaultUpdateConfiguration {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Weekly', 'Daily')]
        [string]$UpdateFrequency = 'Weekly',
        [Parameter(Mandatory = $false)]
        [bool]$AutoInstall = $true,
        [Parameter(Mandatory = $false)]
        [bool]$EnabledScheduledUpdates = $false,
        [Parameter(Mandatory = $false)]
        [bool]$InitialPromptCompleted = $false
    )

    return @{
        EnabledScheduledUpdates = $EnabledScheduledUpdates
        UpdateFrequency         = $UpdateFrequency
        AutoInstall             = $AutoInstall
        LastCheckDate           = $null
        Enabled                 = $EnabledScheduledUpdates
        InitialPromptCompleted  = $InitialPromptCompleted
    }
}

<#
.SYNOPSIS
    Reads persisted update configuration from AppData.
#>
function Get-UpdateConfiguration {
    $paths = Get-UpdateSettingsPaths
    if (-not (Test-Path $paths.ConfigFile)) {
        return (New-DefaultUpdateConfiguration)
    }

    try {
        $raw = Get-Content -Path $paths.ConfigFile -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
        return @{
            EnabledScheduledUpdates = [bool]$config.EnabledScheduledUpdates
            UpdateFrequency         = if ($config.UpdateFrequency -in @('Weekly', 'Daily')) { [string]$config.UpdateFrequency } else { 'Weekly' }
            AutoInstall             = [bool]$config.AutoInstall
            LastCheckDate           = $config.LastCheckDate
            Enabled                 = [bool]$config.Enabled
            InitialPromptCompleted  = [bool]$config.InitialPromptCompleted
        }
    }
    catch {
        Write-WarningMessage "Failed to parse update configuration, using defaults: $_"
        return (New-DefaultUpdateConfiguration)
    }
}

<#
.SYNOPSIS
    Saves update configuration to AppData.
#>
function Save-UpdateConfiguration {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration
    )

    $paths = Get-UpdateSettingsPaths
    if (-not (Test-Path $paths.BasePath)) {
        New-Item -Path $paths.BasePath -ItemType Directory -Force | Out-Null
    }

    $Configuration | ConvertTo-Json | Set-Content -Path $paths.ConfigFile -Encoding UTF8
}

<#
.SYNOPSIS
    Returns updates available for installed packages.
.DESCRIPTION
    Output format: PackageName | CurrentVersion | AvailableVersion.
#>
function Get-UpdateReport {
    try {
        if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
            return @(Get-WinGetPackage | Where-Object IsUpdateAvailable | ForEach-Object {
                    [PSCustomObject]@{
                        PackageName      = $_.Id
                        CurrentVersion   = [string]$_.InstalledVersion
                        AvailableVersion = [string]$_.AvailableVersion
                    }
                })
        }
    }
    catch {
        Write-WarningMessage "Failed to query updates using WinGet module. Falling back to CLI: $_"
    }

    $report = @()
    try {
        $upgradeOutput = & winget upgrade --disable-interactivity --accept-source-agreements 2>&1
        foreach ($line in $upgradeOutput) {
            if (-not $line) { continue }
            if ($line -match '^\s*Name\s+Id\s+Version\s+Available') { continue }
            if ($line -match '^\s*-{3,}') { continue }
            if ($line -match 'No installed package found|No available upgrade found|No newer package versions are available') { continue }

            $columns = $line.Trim() -split '\s{2,}'
            if ($columns.Count -ge 4) {
                $report += [PSCustomObject]@{
                    PackageName      = $columns[1]
                    CurrentVersion   = $columns[2]
                    AvailableVersion = $columns[3]
                }
            }
        }
    }
    catch {
        Write-WarningMessage "Failed to query updates using winget CLI: $_"
    }

    return @($report | Sort-Object PackageName -Unique)
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
    Tests if winget sources are accessible and attempts to repair them if broken.
.DESCRIPTION
    Runs a basic winget source list command to verify the "winget" source is accessible.
    If the source is broken or missing (e.g., when running as admin on a standard user
    account), the function attempts to re-register it using Add-AppxPackage from the
    Microsoft CDN. After repair, it retries the source check once. If still failing, a
    clear error message with manual remediation guidance is displayed.
.RETURNS
    [bool] True if winget sources are accessible (or successfully repaired), otherwise False.
#>
function Test-WingetSources {
    Write-Info 'Checking winget sources...'

    # First check: verify source is listed
    try {
        $output = winget source list --disable-interactivity --accept-source-agreements 2>&1
        $sourceIsListed = $output -match 'winget'
    }
    catch {
        Write-WarningMessage "Winget source list failed: $_"
        $sourceIsListed = $false
    }

    # Second check: verify source is functional (not corrupted) by attempting a search
    $sourceIsFunctional = $false
    if ($sourceIsListed) {
        try {
            # Actually test if the source works by attempting a search
            # Use '7zip' as a known package that always exists
            $searchOutput = winget search 7zip --source winget --disable-interactivity 2>&1
            $searchExitCode = $LASTEXITCODE

            # Check for corruption error code 0x8a15000f or similar source errors
            if ($searchOutput -match '0x8a150|failed when opening|data required' -or $searchExitCode -ne 0) {
                Write-WarningMessage 'Winget source is listed but contains corrupted or missing data.'
                $sourceIsFunctional = $false
            }
            else {
                Write-Success 'Winget sources are accessible and functional.'
                $sourceIsFunctional = $true
            }
        }
        catch {
            Write-WarningMessage "Winget source functionality test failed: $_"
            $sourceIsFunctional = $false
        }
    }

    # If both checks pass, sources are good
    if ($sourceIsListed -and $sourceIsFunctional) {
        return $true
    }

    # If source is missing entirely, attempt repair
    if (-not $sourceIsListed) {
        Write-WarningMessage 'Winget source "winget" appears to be missing. Attempting to repair...'
    }
    else {
        Write-WarningMessage 'Winget source data is corrupted. Attempting to repair...'
    }

    # Attempt repair: first try source reset, then re-register package
    try {
        Write-Info 'Running winget source reset...'
        $resetOutput = winget source reset --force --disable-interactivity --accept-source-agreements 2>&1
        Write-Info 'Source reset completed.'
    }
    catch {
        Write-WarningMessage "Winget source reset failed: $_"
    }

    try {
        Write-Info 'Re-registering winget source package...'
        Add-AppxPackage -Path 'https://cdn.winget.microsoft.com/cache/source.msix' -ErrorAction Stop
        Write-Info 'Winget source package registered. Retrying source check...'
    }
    catch {
        Write-ErrorMessage "Failed to register winget source package: $_"
        Write-ErrorMessage 'Manual remediation steps:'
        Write-ErrorMessage '  1. Run as local user (not as admin): Add-AppxPackage -Path "https://cdn.winget.microsoft.com/cache/source.msix"'
        Write-ErrorMessage '  2. Or run: winget source reset --force'
        return $false
    }

    # Retry both checks after repair
    try {
        $output = winget source list --disable-interactivity --accept-source-agreements 2>&1
        $sourceIsListed = $output -match 'winget'
    }
    catch {
        Write-WarningMessage "Winget source list failed after repair: $_"
        $sourceIsListed = $false
    }

    $sourceIsFunctional = $false
    if ($sourceIsListed) {
        try {
            # Test source functionality with actual search
            $searchOutput = winget search 7zip --source winget --disable-interactivity 2>&1
            $searchExitCode = $LASTEXITCODE
            $sourceIsFunctional = -not ($searchOutput -match '0x8a150|failed when opening|data required' -or $searchExitCode -ne 0)
        }
        catch {
            $sourceIsFunctional = $false
        }
    }

    if ($sourceIsListed -and $sourceIsFunctional) {
        Write-Success 'Winget sources are now accessible and functional.'
        return $true
    }

    Write-ErrorMessage 'Winget sources are still not accessible after repair attempt.'
    Write-ErrorMessage 'Manual remediation steps:'
    Write-ErrorMessage '  1. Run as local user (not as admin): Add-AppxPackage -Path "https://cdn.winget.microsoft.com/cache/source.msix"'
    Write-ErrorMessage '  2. Or run: winget source reset --force'
    return $false
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

<#
.SYNOPSIS
    Attempts to parse Windows Terminal settings content, including JSONC variants.
.DESCRIPTION
    Tries ConvertFrom-Json first. If parsing fails, removes line/block comments and
    trailing commas to support common Windows Terminal JSONC formatting before retrying.
.PARAMETER JsonText
    Raw settings content.
.RETURNS
    Parsed settings object when successful; otherwise $null.
#>
function ConvertFrom-TerminalSettingsJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JsonText
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return [pscustomobject]@{}
    }

    try {
        # ConvertFrom-Json -Depth is unavailable in Windows PowerShell 5.1.
        return $JsonText | ConvertFrom-Json
    }
    catch {
        # Windows Terminal settings are often JSONC; strip comments and trailing commas.
        $sanitizedJson = $JsonText -replace '(?ms)/\*.*?\*/', ''
        $sanitizedJson = $sanitizedJson -replace '(?m)^\s*//.*$', ''
        $sanitizedJson = $sanitizedJson -replace ',(\s*[}\]])', '$1'

        try {
            # Keep parsing compatible with both Windows PowerShell and PowerShell 7+.
            return $sanitizedJson | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
}

<#
.SYNOPSIS
    Resolves the most likely Windows Terminal settings file path.
.DESCRIPTION
    Prefers the stable packaged path, then preview, then unpackaged path.
.RETURNS
    [string] Existing settings path when found; otherwise $null.
#>
function Get-WindowsTerminalSettingsPath {
    $settingsPaths = Get-WindowsTerminalSettingsPaths
    if ($settingsPaths.Count -gt 0) {
        return $settingsPaths[0]
    }

    return $null
}

<#
.SYNOPSIS
    Resolves all discovered Windows Terminal settings file paths.
.DESCRIPTION
    Includes packaged channels (stable/preview/dev/canary-style package names)
    and unpackaged path when present.
.RETURNS
    [string[]] Existing settings paths when found; otherwise an empty array.
#>
function Get-WindowsTerminalSettingsPaths {
    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )

    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -Path $packagesRoot) {
        try {
            $dynamicPaths = Get-ChildItem -Path $packagesRoot -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }

            if ($dynamicPaths) {
                $candidatePaths += $dynamicPaths
            }
        }
        catch {
            # Best-effort discovery only; keep static candidates if enumeration fails.
        }
    }

    $existingPaths = @()

    foreach ($path in $candidatePaths) {
        if (Test-Path -Path $path) {
            $existingPaths += $path
        }
    }

    return @($existingPaths | Select-Object -Unique)
}

<#
.SYNOPSIS
    Sets Windows Terminal default profile to a provided GUID.
.DESCRIPTION
    Reads settings.json, updates defaultProfile, and writes updated JSON.
.PARAMETER SettingsPath
    Full path to the Windows Terminal settings file.
.PARAMETER ProfileGuid
    Profile GUID to set as default. Braces are added when missing.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalDefaultProfile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileGuid
    )

    if (-not (Test-Path -Path $SettingsPath)) {
        Write-WarningMessage "Windows Terminal settings file not found at '$SettingsPath'."
        return $false
    }

    $normalizedGuid = if ($ProfileGuid.StartsWith('{') -and $ProfileGuid.EndsWith('}')) {
        $ProfileGuid
    }
    else {
        "{$ProfileGuid}"
    }

    try {
        $settingsContent = Get-Content -Path $SettingsPath -Raw -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Unable to read Windows Terminal settings: $_"
        return $false
    }

    $settingsObject = ConvertFrom-TerminalSettingsJson -JsonText $settingsContent
    if (-not $settingsObject) {
        Write-WarningMessage 'Unable to parse Windows Terminal settings.json. Skipping default profile update.'
        return $false
    }

    if ($settingsObject.defaultProfile -eq $normalizedGuid) {
        Write-Success 'Windows Terminal default profile is already set to PowerShell 7.'
        return $true
    }

    $settingsObject | Add-Member -MemberType NoteProperty -Name 'defaultProfile' -Value $normalizedGuid -Force

    try {
        $updatedJson = $settingsObject | ConvertTo-Json -Depth 100
        Set-Content -Path $SettingsPath -Value $updatedJson -Encoding UTF8 -ErrorAction Stop
        Write-Success 'Configured Windows Terminal default profile to PowerShell 7.'
        return $true
    }
    catch {
        Write-WarningMessage "Failed to update Windows Terminal settings.json: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Sets Windows Terminal as the default terminal application via registry.
.DESCRIPTION
    Writes DelegationConsole and DelegationTerminal values under HKCU:\Console\%%Startup.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalAsDefaultTerminalApplication {
    $registryPath = 'HKCU:\Console\%%Startup'
    $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

    try {
        if (-not (Test-Path -Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }

        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        if ($existingValues -and
            $existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal) {
            Write-Success 'Windows Terminal is already configured as the default terminal application.'
            return $true
        }

        New-ItemProperty -Path $registryPath -Name 'DelegationConsole' -PropertyType String -Value $delegationConsole -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name 'DelegationTerminal' -PropertyType String -Value $delegationTerminal -Force | Out-Null
        Write-Success 'Configured Windows Terminal as the default terminal application.'
        return $true
    }
    catch {
        Write-WarningMessage "Failed to set default terminal application in registry: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Configures Windows Terminal defaults for shell profile and terminal delegation.
.DESCRIPTION
    Applies both issue #74 requirements: PowerShell 7 default profile and Windows Terminal
    default terminal application setting.
.PARAMETER WhatIf
    When provided, only reports intended actions.
#>
function Set-WindowsTerminalDefaults {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $powerShell7ProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $settingsPaths = @(Get-WindowsTerminalSettingsPaths)

    if ($WhatIf) {
        if ($settingsPaths.Count -gt 0) {
            Write-Info "[DRY-RUN] Would set defaultProfile to $powerShell7ProfileGuid in $($settingsPaths.Count) Windows Terminal settings file(s)"
        }
        else {
            Write-Info '[DRY-RUN] Would set Windows Terminal defaultProfile to PowerShell 7 when settings.json is available'
        }
        Write-Info '[DRY-RUN] Would set HKCU:\Console\%%Startup DelegationConsole and DelegationTerminal to Windows Terminal values'
        return
    }

    if ($settingsPaths.Count -gt 0) {
        foreach ($settingsPath in $settingsPaths) {
            [void](Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid $powerShell7ProfileGuid)
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal settings.json was not found. Skipping default profile configuration.'
    }

    [void](Set-WindowsTerminalAsDefaultTerminalApplication)
}

<#
.SYNOPSIS
    Returns true when the scheduled updates task currently exists.
.RETURNS
    [bool]
#>
function Test-ScheduledUpdatesTaskExists {
    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'

    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        return $null -ne $task
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Copies the scheduled update helper script into AppData and returns its path.
#>
function Install-UpdateHelperScript {
    $paths = Get-UpdateSettingsPaths
    $sourceScript = Join-Path $PSScriptRoot 'Update-InstalledApps.ps1'

    if (-not (Test-Path $sourceScript)) {
        throw "Required helper script is missing: $sourceScript"
    }

    if (-not (Test-Path $paths.BasePath)) {
        New-Item -ItemType Directory -Path $paths.BasePath -Force | Out-Null
    }
    if (-not (Test-Path $paths.UpdateChecks)) {
        New-Item -ItemType Directory -Path $paths.UpdateChecks -Force | Out-Null
    }
    if (-not (Test-Path $paths.RollbackScripts)) {
        New-Item -ItemType Directory -Path $paths.RollbackScripts -Force | Out-Null
    }

    Copy-Item -Path $sourceScript -Destination $paths.HelperScript -Force
    return $paths.HelperScript
}

<#
.SYNOPSIS
    Enables automatic app update checks via Windows Scheduled Task.
.DESCRIPTION
    Creates a Windows scheduled task that runs as the current user (S4U, no elevated privileges).
.PARAMETER SkipPrompt
    When true, skips the user prompt and uses supplied parameter values.
.PARAMETER WhatIf
    When provided, only reports intended actions.
#>
function Enable-ScheduledUpdatesCheck {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Weekly', 'Daily')]
        [string]$UpdateFrequency = 'Weekly',
        [Parameter(Mandatory = $false)]
        [bool]$AutoInstall = $true,
        [Parameter(Mandatory = $false)]
        [bool]$SkipPrompt = $false,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $paths = Get-UpdateSettingsPaths
    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'

    if (-not $SkipPrompt -and -not $WhatIf) {
        $scheduleDescription = if ($UpdateFrequency -eq 'Daily') { 'every day at 2:00 AM' } else { 'every Sunday at 2:00 AM' }
        $userChoice = Read-Host "Enable $($UpdateFrequency.ToLower()) automatic update checks? Updates will be checked $scheduleDescription. (Y/N)"
        $enableScheduledUpdates = $userChoice -in @('Y', 'y')

        $config = New-DefaultUpdateConfiguration -UpdateFrequency $UpdateFrequency -AutoInstall $AutoInstall -EnabledScheduledUpdates $enableScheduledUpdates -InitialPromptCompleted $true
        Save-UpdateConfiguration -Configuration $config

        if (-not $enableScheduledUpdates) {
            Write-WarningMessage 'Scheduled updates were not enabled.'
            return $false
        }

        $autoInstallChoice = Read-Host 'Automatically install found updates? (Y/N):'
        $AutoInstall = $autoInstallChoice -in @('Y', 'y')
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would create/update scheduled task: $taskName"
        Write-Info "[DRY-RUN] Frequency: $UpdateFrequency at 2:00 AM"
        return $true
    }

    $null = Install-UpdateHelperScript

    if (Test-ScheduledUpdatesTaskExists) {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    }

    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    try {
        $taskAction = New-ScheduledTaskAction -Execute $psExecutable -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($paths.HelperScript)`""
        if ($UpdateFrequency -eq 'Daily') {
            $taskTrigger = New-ScheduledTaskTrigger -Daily -At '2:00 AM'
        }
        else {
            $taskTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '2:00 AM'
        }
        $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited

        Register-ScheduledTask -Action $taskAction `
            -Trigger $taskTrigger `
            -TaskName $taskName `
            -TaskPath $taskPath `
            -Settings $taskSettings `
            -Principal $taskPrincipal `
            -Description 'Automatically checks and installs available updates for installed applications via winget.' `
            -Force | Out-Null
    }
    catch {
        Write-ErrorMessage "Failed to create scheduled task: $_"
        return $false
    }

    $config = New-DefaultUpdateConfiguration -UpdateFrequency $UpdateFrequency -AutoInstall $AutoInstall -EnabledScheduledUpdates $true -InitialPromptCompleted $true
    Save-UpdateConfiguration -Configuration $config
    Write-Success 'Scheduled updates enabled successfully.'
    return $true
}

<#
.SYNOPSIS
    Disables and removes the scheduled updates task.
#>
function Disable-ScheduledUpdatesCheck {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would disable scheduled task: $taskPath$taskName"
        return $true
    }

    try {
        if (Test-ScheduledUpdatesTaskExists) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
        }

        $config = Get-UpdateConfiguration
        $config.EnabledScheduledUpdates = $false
        $config.Enabled = $false
        $config.InitialPromptCompleted = $true
        Save-UpdateConfiguration -Configuration $config
        Write-Success 'Scheduled updates disabled successfully.'
        return $true
    }
    catch {
        Write-ErrorMessage "Failed to disable scheduled updates: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Runs update check immediately, optionally auto-installing updates.
#>
function Invoke-OnDemandUpdateCheck {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$AutoInstallUpdates,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $report = @(Get-UpdateReport)
    if ($report.Count -eq 0) {
        Write-Info 'No updates available.'
    }
    else {
        Write-Info 'Available updates:'
        $report | Format-Table PackageName, CurrentVersion, AvailableVersion
    }

    if (-not $AutoInstallUpdates) {
        return
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would auto-install all available updates.'
        return
    }

    $helperPath = Install-UpdateHelperScript
    & $helperPath -AutoInstallOverride:$true -RunReason OnDemand
}

<#
.SYNOPSIS
    Initializes winget sources in the current user context to prevent session errors.
.DESCRIPTION
    Runs a lightweight winget command in user context (without elevation) to ensure source
    agreements are accepted by the current user. This prevents 0x80073d19 errors that occur
    when the script runs as admin but winget sources haven't been initialized for the user.
.PARAMETER WhatIf
    When specified, only reports intended actions without executing.
.RETURNS
    [bool] True if initialization succeeded or was already done, False if an error occurred.
#>
function Initialize-WingetSourcesForUser {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would initialize winget sources for current user'
        return $true
    }

    Write-Info 'Initializing winget sources for current user context...'
    Write-Info 'You may be prompted to accept source agreements.'

    try {
        $output = & winget list --disable-interactivity 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Success 'Winget sources initialized successfully for user context.'
            return $true
        }

        # Exit code -1 with "source agreements not accepted" is actually expected the first time
        # and means the user can now accept them. The next execution will work.
        if ($exitCode -eq -1 -and $output -match 'source agreement|You must accept') {
            Write-Info 'Source agreements need to be accepted. Running interactive prompt...'
            # Run again without --disable-interactivity to allow user interaction
            $output = & winget list 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Success 'Source agreements accepted. Winget is ready to use.'
                return $true
            }
        }

        if ($exitCode -eq 0) {
            Write-Success 'Winget sources are accessible.'
            return $true
        }

        Write-WarningMessage "Winget source initialization returned exit code: $exitCode"
        Write-WarningMessage 'Continuing with installation; retry logic will handle any session errors.'
        return $true
    }
    catch {
        Write-WarningMessage "Error initializing winget sources: $_"
        Write-WarningMessage 'Continuing with installation; retry logic will handle any session errors.'
        return $true
    }
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

    # Determine which PowerShell executable to use
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    # Accept msstore source agreements in the user context before elevating.
    # Agreements are per-user — they won't carry over into the elevated process.
    # Running winget source update here surfaces the interactive prompt while we
    # still have the normal user's identity.
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    if (-not $isAdmin -and (Test-IsRunningLocally)) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run winget source update to prompt for source agreement acceptance in user context'
        }
        else {
            Write-Info 'Updating winget sources — accept any prompts that appear to continue...'
            Start-Process -FilePath 'winget' -ArgumentList 'source', 'update' -Wait -NoNewWindow
        }
    }

    # Check if the script is run as administrator
    If (-NOT $isAdmin) {
        if (Test-IsRunningLocally) {
            Write-ErrorMessage 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.'
            Pause
            # Relaunch the script with administrator privileges
            Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath | Out-Null
            Exit
        }

        # IEX/remote execution has no local script path to relaunch from.
        Write-ErrorMessage 'This script requires administrator privileges.'
        Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
        Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
        Write-Info 'Exiting in 5 seconds...'
        Start-Sleep -Seconds 5
        Exit 1
    }
    else {
        Write-Success 'Starting...'
    }

    # Initialize winget sources in user context to prevent session errors (issue #104)
    [void](Initialize-WingetSourcesForUser -WhatIf:$WhatIf)

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

    # Verify winget sources are accessible and auto-repair if broken
    if (-not (Test-WingetSources)) {
        Write-WarningMessage 'Winget sources could not be repaired. Some installations may fail.'
    }

    $scheduledTaskExists = Test-ScheduledUpdatesTaskExists
    $updateConfig = Get-UpdateConfiguration
    if (-not $WhatIf -and -not $scheduledTaskExists -and -not $updateConfig.InitialPromptCompleted) {
        [void](Enable-ScheduledUpdatesCheck -UpdateFrequency $updateConfig.UpdateFrequency -AutoInstall $updateConfig.AutoInstall -WhatIf:$WhatIf)
    }

    # Add the script directory to the PATH (only if running locally)
    # Use $PSScriptRoot for reliable script directory detection (works with launcher)
    if (Test-IsRunningLocally) {
        $scriptDirectory = $PSScriptRoot
        if (-not $WhatIf) {
            Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'
        }
        else {
            Write-Info "[DRY-RUN] Would add '$scriptDirectory' to User PATH"
        }
    }
    else {
        Write-Info 'Skipping PATH update (remote execution detected)'
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
    $sourceErrors = @()
    ForEach ($source in $trustedSources) {
        if (-not (Test-Source-IsTrusted -target $source)) {
            if (-not $WhatIf) {
                Write-WarningMessage "Trusting source: $source"
                try {
                    $sourceResetSuccess = Set-Sources
                    if (-not $sourceResetSuccess) {
                        $sourceErrors += $source
                        Write-WarningMessage "Failed to reset sources for $source. Continuing with installation..."
                    }
                }
                catch {
                    $sourceErrors += $source
                    Write-WarningMessage "Error resetting sources for ${source}: ${_}. Continuing with installation..."
                }
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
                -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
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
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $($app.name)" -NoNewWindow -Wait

                    # Verify installation with timeout
                    $verifyProcess = Start-Process -FilePath 'winget' `
                        -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
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
                                $upgradeResult = & winget upgrade $packageId --source winget 2>&1
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

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    Set-WindowsTerminalDefaults -WhatIf:$WhatIf

    # Retry any failed installations once before producing the final summary
    if ($failedApps.Count -gt 0) {
        if (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                try {
                    Write-Info "Retrying: $appName"
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait

                    # Verify installation with timeout
                    $verifyProcess = Start-Process -FilePath 'winget' `
                        -ArgumentList 'list', '--exact', '--id', $appName, '--accept-source-agreements' `
                        -NoNewWindow `
                        -PassThru `
                        -RedirectStandardOutput "$env:TEMP\winget_retry_verify_output.txt" `
                        -RedirectStandardError "$env:TEMP\winget_retry_verify_error.txt"

                    if ($verifyProcess.WaitForExit(15000)) {
                        $retryResult = Get-Content "$env:TEMP\winget_retry_verify_output.txt" -ErrorAction SilentlyContinue
                        if (![String]::Join('', $retryResult).Contains($appName)) {
                            Write-ErrorMessage "Retry failed: $appName"
                            $failedApps += $appName
                        }
                        else {
                            Write-Success "Retry succeeded: $appName"
                            $installedApps += $appName
                        }
                    }
                    else {
                        Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                        try { $verifyProcess.Kill() } catch { }
                        $failedApps += $appName
                    }

                    # Cleanup temp files
                    Remove-Item "$env:TEMP\winget_retry_verify_output.txt" -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\winget_retry_verify_error.txt" -ErrorAction SilentlyContinue
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += $appName
                }
            }
        }
        else {
            Write-Host ''
            Write-Info '[DRY-RUN] Would retry the following failed installations:'
            foreach ($appName in $failedApps) {
                Write-Info "[DRY-RUN] Would retry: $appName"
            }
        }
    }

    # Display the summary of the installation
    if ($WhatIf) {
        Write-Host ''
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

    if ($failedApps.Count -gt 0) {
        Exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($EnableScheduledUpdates -and $DisableScheduledUpdates) {
        Write-ErrorMessage 'EnableScheduledUpdates and DisableScheduledUpdates cannot be used together.'
        exit 1
    }

    if ($DisableScheduledUpdates) {
        [void](Disable-ScheduledUpdatesCheck -WhatIf:$WhatIf)
        exit 0
    }

    if ($EnableScheduledUpdates) {
        $config = Get-UpdateConfiguration
        $autoInstall = if ($PSBoundParameters.ContainsKey('AutoInstallUpdates')) { [bool]$AutoInstallUpdates } else { [bool]$config.AutoInstall }
        [void](Enable-ScheduledUpdatesCheck -UpdateFrequency $UpdateFrequency -AutoInstall:$autoInstall -SkipPrompt:$true -WhatIf:$WhatIf)
        exit 0
    }

    if ($CheckForUpdates) {
        Invoke-OnDemandUpdateCheck -AutoInstallUpdates:$AutoInstallUpdates -WhatIf:$WhatIf
        exit 0
    }

    Invoke-WingetInstall -WhatIf:$WhatIf
}
