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

.PARAMETER SkipSystemCheck
 Bypasses the pre-flight system checks (OS version, disk space, network) for headless or automated use.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck
)

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1.
# Edit the function source under WingetAppSetup/Public and WingetAppSetup/Private, then re-run the
# build to regenerate this file. See readme.md ("Project layout") for details.
# ------------------------------------------------------------------------------------------------

# ------------------------------------------------Functions------------------------------------------------

# --- Elevation ---
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
    Returns the account name the current process is running as (DOMAIN\user), or $null.
#>
function Get-ProcessUserName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Returns the account name that owns the interactive console session (DOMAIN\user), or $null.
.DESCRIPTION
    Win32_ComputerSystem.UserName reports the interactively logged-on console user regardless of
    which account the current (possibly elevated) process runs as. Comparing it with
    Get-ProcessUserName detects cross-user elevation — running elevated as a different account
    than the logged-on user — where winget's per-user MSIX bootstrap is blocked by the AppX
    deployment service with 0x80073D19 because the process account has no interactive logon
    session (issue #159).
#>
function Get-InteractiveSessionUserName {
    try {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ([string]::IsNullOrWhiteSpace($userName)) {
            return $null
        }
        return $userName
    }
    catch {
        return $null
    }
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
.PARAMETER AdditionalArguments
    Optional switches/arguments to forward to the elevated relaunch (for example, '-WhatIf'). These
    are appended after the -File argument so the elevated session inherits the caller's intent.
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
        [string]$WindowsTerminalExecutable,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalArguments = @()
    )

    $quotedScriptPath = '"' + $ScriptPath.Replace('"', '`"') + '"'
    $commandArguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
    if ($AdditionalArguments.Count -gt 0) {
        $commandArguments += ' ' + ($AdditionalArguments -join ' ')
    }
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

# --- Environment ---
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
function Get-WindowsBuildNumber {
    <#
    .SYNOPSIS
        Returns the current Windows OS build number as an integer (e.g. 19045, 26100).
    .DESCRIPTION
        Wrapped in a function so callers (and tests) can reason about the build gate used to decide
        how to install the latest PowerShell: winget's machine-scope MSIX provisioning only works on
        build 26100 (Windows 11 24H2) and later (issue #166).
    #>
    return [int][System.Environment]::OSVersion.Version.Build
}

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

# --- GraphicalTools ---
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

# --- WingetBootstrap ---
<#
.SYNOPSIS
    Opens and updates the winget source for the current account, accepting source agreements.
.DESCRIPTION
    Runs `winget source update --name winget --accept-source-agreements --disable-interactivity`
    under a timeout guard. This is the lightest command that forces winget's per-user first-use
    bootstrap: it registers the Microsoft.Winget.Source package for the invoking account and
    persists source agreement acceptance in that account's winget state (acceptance is saved
    per-user; see microsoft/winget-cli SourceList.cpp). Exit code 0 therefore means the account is
    initialized for unattended installs from the winget source — the only source the install
    phase uses (`--source winget`).

    The probe is deliberately scoped to the winget source: msstore can fail for an account that
    has never logged on interactively even when the winget source is healthy
    (microsoft/winget-cli#5398/#6334), and probing it would report a false failure for the only
    source that matters here.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for winget before killing the process. Default 120.
.RETURNS
    [hashtable] @{ Succeeded = <bool>; ExitCode = <int or $null>; TimedOut = <bool> }
    ExitCode is $null when the process timed out or failed to start.
#>
function Invoke-WingetSourceProbe {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120
    )

    try {
        $probeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'source', 'update', '--name', 'winget', '--accept-source-agreements', '--disable-interactivity' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput "$env:TEMP\winget_source_probe_output.txt" `
            -RedirectStandardError "$env:TEMP\winget_source_probe_error.txt"

        if (-not $probeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Write-WarningMessage "Winget source update timed out after $TimeoutSeconds seconds. Terminating process..."
            try { $probeProcess.Kill() } catch { }
            return @{ Succeeded = $false; ExitCode = $null; TimedOut = $true }
        }

        return @{
            Succeeded = ($probeProcess.ExitCode -eq 0)
            ExitCode  = $probeProcess.ExitCode
            TimedOut  = $false
        }
    }
    catch {
        Write-WarningMessage "Winget source update failed to run: $_"
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false }
    }
    finally {
        Remove-Item "$env:TEMP\winget_source_probe_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\winget_source_probe_error.txt" -ErrorAction SilentlyContinue
    }
}

# --- WingetUpgrade ---
<#
.SYNOPSIS
    Upgrades a single winget package with a hard timeout so a stalled upgrade cannot hang the run.
.DESCRIPTION
    Runs `winget upgrade` for one package id as a child process and waits up to TimeoutSeconds for it
    to exit. If the process does not finish in time it is killed and reported as timed out, so the
    caller can move on to the next package instead of blocking indefinitely (issue #120). This mirrors
    the Start-Process/WaitForExit/Kill timeout pattern already used by Set-Sources.
.PARAMETER PackageId
    The exact winget package identifier to upgrade (for example, 'Warp.Warp').
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the upgrade before terminating it. Defaults to 300 (5 minutes).
.RETURNS
    [PSCustomObject] with Id, Status ('Ok' | 'NoUpgrade' | 'Failed' | 'TimedOut'), and ExitCode.
#>
function Invoke-WingetPackageUpgrade {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300
    )

    $token = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "winget_upgrade_out_$token.txt"
    $errFile = Join-Path $env:TEMP "winget_upgrade_err_$token.txt"

    try {
        $upgradeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'upgrade', '--id', $PackageId, '--exact', '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        if (-not $upgradeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Write-WarningMessage "Update for $PackageId timed out after $TimeoutSeconds seconds. Terminating..."
            try { $upgradeProcess.Kill() } catch { }
            return [PSCustomObject]@{ Id = $PackageId; Status = 'TimedOut'; ExitCode = $null }
        }

        $exitCode = $upgradeProcess.ExitCode
        $output = (Get-Content -Path $outFile -ErrorAction SilentlyContinue) -join "`n"

        if ($output -match 'No available upgrade found' -or $output -match 'No newer package versions are available') {
            return [PSCustomObject]@{ Id = $PackageId; Status = 'NoUpgrade'; ExitCode = $exitCode }
        }

        if ($exitCode -eq 0 -or $output -match 'Successfully installed') {
            return [PSCustomObject]@{ Id = $PackageId; Status = 'Ok'; ExitCode = $exitCode }
        }

        return [PSCustomObject]@{ Id = $PackageId; Status = 'Failed'; ExitCode = $exitCode }
    }
    catch {
        Write-ErrorMessage "Error updating ${PackageId}: $_"
        return [PSCustomObject]@{ Id = $PackageId; Status = 'Failed'; ExitCode = $null }
    }
    finally {
        Remove-Item -Path $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

# --- AppValidation ---
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

# --- Install ---
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
            # A dry run makes no system changes, so it never needs elevation. Relaunching
            # elevated here would (a) be a surprising side effect for a preview and (b) — if
            # the flag were ever dropped across the elevation boundary — silently turn a
            # dry run into a real install. Stay in the current session and continue the preview.
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                Write-ErrorMessage 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.'
                Pause
                # Relaunch the script with administrator privileges, forwarding -WhatIf as a
                # safety net so the elevated session can never escalate a dry run into changes.
                $elevationArgs = if ($WhatIf) { @('-WhatIf') } else { @() }
                Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs | Out-Null
                Exit
            }
        }
        else {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            Write-Info 'Exiting in 5 seconds...'
            Start-Sleep -Seconds 5
            Exit 1
        }
    }
    else {
        Write-Success 'Starting...'
    }

    # Ensure the WinGet PowerShell module is available before touching winget itself:
    # Test-AndInstallWinget and Initialize-WingetSourcesForUser use Repair-WinGetPackageManager
    # to bootstrap winget for accounts that have no interactive logon session (issue #159).
    if (-not (Test-AndInstallWingetModule)) {
        Write-Warning 'Microsoft.WinGet.Client module is not available. Update functionality will use fallback CLI methods.'
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

    # Initialize winget sources and agreements for the account performing the installs. This is
    # what prevents 0x80073d19 when the script is elevated as a different account than the
    # logged-on user (issues #104/#150, #159).
    [void](Initialize-WingetSourcesForUser -WhatIf:$WhatIf)

    if (-not (Test-AndInstallGraphicalTools)) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Verify winget sources are accessible and auto-repair if broken
    if (-not (Test-WingetSources)) {
        Write-WarningMessage 'Winget sources could not be repaired. Some installations may fail.'
    }

    # Migrate away from the old homegrown scheduled-update task if a prior version installed one;
    # ongoing updates are now handled by Winget-AutoUpdate, set up after the app installs (issue #168).
    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

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
        # PowerShell needs a version-agnostic install strategy (no pinning — always the latest):
        # winget installs PowerShell 7.6+ as an MSIX by default, which registers per-user and fails
        # to deploy in an elevated cross-user / machine-scope context ("The current system
        # configuration does not support the installation of this package"). Install-PowerShellLatest
        # prefers the MSI while it exists (<= 7.6), and once the MSI is gone (7.7+) installs the latest
        # MSIX machine-wide — natively on Windows 24H2+, or via DISM provisioning on older Windows
        # (issues #163/#166). It self-verifies, so the loop must not re-check it with `winget list`.
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
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
        if (-not (Test-WingetSourceTrusted -target $source)) {
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
                    if ($app.install) {
                        # Package-specific installer that performs its own verification (e.g.
                        # PowerShell, whose DISM-provisioned MSIX path never shows up under
                        # `winget list` for the elevating account). Trust its Installed result.
                        $installOutcome = & $app.install
                        if ($installOutcome.Installed) {
                            Write-Success "Successfully installed: $($app.name)"
                            $installedApps += $app.name
                        }
                        else {
                            Write-ErrorMessage "Failed to install: $($app.name)."
                            $failedApps += $app.name
                        }
                    }
                    else {
                        # Install through the helper so the transient 0x80073d19 session error is
                        # retried with backoff (issue #150) instead of failing on the first hit.
                        [void](Install-WingetPackage -PackageId $app.name -InstallerType $app.installerType)

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

            # Enumerate the package ids that have updates, preferring the PowerShell module.
            $updateIds = @()
            if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
                $updateIds = @(Get-WinGetPackage | Where-Object IsUpdateAvailable | ForEach-Object { $_.Id })
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
                            $updateIds += $packageId
                        }
                    }
                }
            }

            # Upgrade each package through a timeout-guarded helper so a single stalled
            # upgrade can no longer hang the entire run (issue #120).
            foreach ($packageId in $updateIds) {
                $result = Invoke-WingetPackageUpgrade -PackageId $packageId
                switch ($result.Status) {
                    'Ok' {
                        $updatedApps += $packageId
                        Write-Success "Successfully updated: $packageId"
                    }
                    'NoUpgrade' {
                        # Nothing to do; the package was already current by the time we upgraded.
                    }
                    'TimedOut' {
                        $failedUpdateApps += $packageId
                        Write-ErrorMessage "Timed out updating: $packageId (skipped to continue)"
                    }
                    default {
                        $failedUpdateApps += $packageId
                        Write-ErrorMessage "Failed to update: $packageId"
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

    # Set up ongoing automatic updates via Winget-AutoUpdate (issue #168). Best-effort: a failure
    # here warns but does not fail the install.
    [void](Install-WingetAutoUpdate -WhatIf:$WhatIf)

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
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1
                    if ($appDef.install) {
                        # Package-specific self-verifying installer (e.g. PowerShell). Trust its result.
                        $retryOutcome = & $appDef.install
                        if ($retryOutcome.Installed) {
                            Write-Success "Retry succeeded: $appName"
                            $installedApps += $appName
                        }
                        else {
                            Write-ErrorMessage "Retry failed: $appName"
                            $failedApps += $appName
                        }
                    }
                    else {
                        # Route the final retry through the same helper so a lingering 0x80073d19
                        # session error gets its backoff retries here too (issue #150).
                        [void](Install-WingetPackage -PackageId $appName -InstallerType $appDef.installerType)

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

# --- Logging ---
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
        [AllowNull()]
        [string[]]$AppArray
    )

    if ($AppArray -and $AppArray.Count -gt 0) {
        return $AppArray -join ', '
    }
    return $null
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
        [AllowEmptyCollection()]
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

# --- SystemChecks ---
<#
.SYNOPSIS
    Runs pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044, non-blocking), warns and prompts to
    continue when C: has less than 50 GB free, and blocks when cdn.winget.microsoft.com is
    unreachable (network is required for winget). In -WhatIf mode the disk-space prompt is skipped.
.PARAMETER WhatIf
    When specified, reports intended checks without prompting on low disk space.
.RETURNS
    [bool] True when it is safe to proceed; False when a blocking check fails or the user declines.
#>
function Test-SystemRequirements {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $results = @()
    $proceed = $true

    # --- OS Version (warn only, Windows 10 21H2 = build 19044) ---
    try {
        $build = [System.Environment]::OSVersion.Version.Build
        $osName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).ProductName
        if ($build -ge 19044) {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'OK'; Detail = $osName }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "$osName (build $build — Windows 10 21H2 or later recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "Could not determine OS version: $_" }
    }

    # --- Disk Space on C: (warn + prompt if under 50 GB) ---
    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $freeGB = [Math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -ge 50) {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'OK'; Detail = "${freeGB} GB free on C:" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'WARN'; Detail = "${freeGB} GB free on C: (50 GB recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'WARN'; Detail = "Could not read C: drive: $_" }
        $freeGB = 999
    }

    # --- Network (blocking — required for winget) ---
    try {
        $netTest = Test-NetConnection -ComputerName 'cdn.winget.microsoft.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
        if ($netTest) {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = 'Connected to cdn.winget.microsoft.com' }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = 'Cannot reach cdn.winget.microsoft.com — network is required' }
            $proceed = $false
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = "Network check failed: $_" }
        $proceed = $false
    }

    # --- Display results ---
    Write-Host ''
    Write-Info 'Pre-flight System Checks:'
    foreach ($r in $results) {
        $icon = switch ($r.Status) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'FAIL' { '[FAIL]' } }
        $msg = "$icon $($r.Check): $($r.Detail)"
        switch ($r.Status) {
            'OK' { Write-Success $msg }
            'WARN' { Write-WarningMessage $msg }
            'FAIL' { Write-ErrorMessage $msg }
        }
    }
    Write-Host ''

    if (-not $proceed) {
        return $false
    }

    # Prompt on low disk space (skip prompt in WhatIf mode)
    $diskResult = $results | Where-Object { $_.Check -eq 'Disk Space' }
    if ($diskResult.Status -eq 'WARN' -and -not $WhatIf) {
        $choice = Read-Host 'Disk space is below the 50 GB recommendation. Continue anyway? (Y/N)'
        if ($choice -notin @('Y', 'y')) {
            Write-WarningMessage 'Installation cancelled by user due to low disk space.'
            return $false
        }
    }

    return $true
}

# --- WindowsTerminal ---
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

# --- WingetAutoUpdate ---
<#
.SYNOPSIS
    Returns the pinned Winget-AutoUpdate (WAU) release metadata.
.DESCRIPTION
    We deploy a specific, SHA256-verified WAU release rather than tracking latest, and disable WAU's
    own self-update, so an upstream change can never roll out to managed machines unreviewed. Bump
    all fields together to move to a newer WAU (verify the new SHA256 against the winget-pkgs manifest
    for that version). See issue #168.
#>
function Get-WauPin {
    return @{
        Version     = '2.12.0'
        MsiUrl      = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi'
        Sha256      = 'F5AB2303FDF82FBFCB2248CCA4F96479FE17D74584A528B0F86B3DBE9F9E9718'
        ProductCode = '{FB0EB14E-95AC-45D7-A951-432316FFCBD4}'
    }
}

<#
.SYNOPSIS
    Returns true when Winget-AutoUpdate appears to be installed on this machine.
.DESCRIPTION
    WAU records its configuration under HKLM and registers a scheduled task 'Winget-AutoUpdate' under
    the '\WAU\' task path. Either is a reliable indicator that WAU is already set up, so the installer
    can leave an existing (possibly customized) WAU configuration untouched.
#>
function Test-WauInstalled {
    if (Test-Path 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate') {
        return $true
    }
    try {
        if (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction Stop) {
            return $true
        }
    }
    catch { }
    return $false
}

<#
.SYNOPSIS
    Installs and configures Winget-AutoUpdate (WAU) to keep installed apps current.
.DESCRIPTION
    Downloads the pinned WAU MSI, verifies its SHA256, and installs it silently with the configuration
    this project standardizes on (issue #168):
      - Weekly updates at 02:00 (WAU runs as SYSTEM for machine-scope packages and spawns a user-context
        task in the logged-on session for user-scope packages, which avoids the cross-user 0x80073d19
        class the homegrown updater fought).
      - USERCONTEXT=1 so user-scope apps update in the real interactive session.
      - DISABLEWAUAUTOUPDATE=1 so WAU stays on this pinned version until we bump it deliberately.
      - Full notifications; skip on metered connections.
    Best-effort: any failure warns and returns $false rather than aborting the install. If WAU is
    already present, its configuration is left as-is.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when WAU is installed (or already present), otherwise False.
#>
function Install-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $pin = Get-WauPin

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would install Winget-AutoUpdate $($pin.Version) (weekly updates at 02:00, Full notifications, self-update disabled)."
        return $true
    }

    if (Test-WauInstalled) {
        Write-Success 'Winget-AutoUpdate is already installed; leaving its configuration unchanged.'
        return $true
    }

    Write-Info "Setting up automatic app updates via Winget-AutoUpdate $($pin.Version)..."
    $msiPath = Join-Path $env:TEMP "WAU-$($pin.Version).msi"

    try {
        Invoke-WebRequest -Uri $pin.MsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

        $actualHash = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash
        if ($actualHash -ne $pin.Sha256) {
            Write-ErrorMessage "Winget-AutoUpdate MSI hash mismatch (expected $($pin.Sha256), got $actualHash). Skipping installation."
            return $false
        }

        # Bake the configuration in via MSI properties (the winget-package install path allows no
        # install-time customization). Single quoted-path argument string for reliable msiexec parsing.
        $msiArgs = "/i `"$msiPath`" /qn /norestart RUN_WAU=YES USERCONTEXT=1 DISABLEWAUAUTOUPDATE=1 UPDATESINTERVAL=Weekly UPDATESATTIME=02:00:00 NOTIFICATIONLEVEL=Full DONOTRUNONMETERED=1"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED — still a success.
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Success "Winget-AutoUpdate $($pin.Version) installed. Apps will update weekly at 2 AM."
            return $true
        }

        Write-ErrorMessage "Winget-AutoUpdate install failed (msiexec exit code $($proc.ExitCode))."
        return $false
    }
    catch {
        Write-ErrorMessage "Failed to install Winget-AutoUpdate: $_"
        return $false
    }
    finally {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Uninstalls Winget-AutoUpdate (WAU) via its pinned MSI product code.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when WAU was removed (or was not installed), otherwise False.
#>
function Uninstall-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if (-not (Test-WauInstalled)) {
        Write-WarningMessage 'Winget-AutoUpdate is not installed; nothing to remove.'
        return $true
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would uninstall Winget-AutoUpdate.'
        return $true
    }

    $pin = Get-WauPin
    Write-Info 'Uninstalling Winget-AutoUpdate...'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $($pin.ProductCode) /qn /norestart" -Wait -PassThru

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Success 'Winget-AutoUpdate uninstalled.'
        return $true
    }

    Write-ErrorMessage "Winget-AutoUpdate uninstall failed (msiexec exit code $($proc.ExitCode))."
    return $false
}

<#
.SYNOPSIS
    Removes the legacy homegrown scheduled-update task and its %APPDATA% data.
.DESCRIPTION
    Auto-updates are now handled by Winget-AutoUpdate (issue #168). Earlier versions registered a
    Windows scheduled task 'WingetAppSetup-ScheduledUpdates' (under '\winget-app-setup\') that ran a
    helper deployed to %APPDATA%\winget-app-setup — a helper that self-downloads from the repo and
    would break once removed. This migration unregisters that task and deletes the data directory so
    already-deployed machines transition cleanly. Safe to call when nothing is present (no-op).
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when something was removed, otherwise False.
#>
function Remove-LegacyScheduledUpdates {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'
    $appDataDir = Join-Path $env:APPDATA 'winget-app-setup'
    $removed = $false

    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    }
    catch {
        $task = $null
    }
    if ($task) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy scheduled task '$taskPath$taskName'."
        }
        else {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            Write-Info 'Removed the legacy scheduled-update task (updates are now handled by Winget-AutoUpdate).'
        }
        $removed = $true
    }

    if (Test-Path $appDataDir) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy update data directory '$appDataDir'."
        }
        else {
            Remove-Item -Path $appDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $removed = $true
    }

    return $removed
}

# --- WingetCore ---
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
        # Prefer Repair-WinGetPackageManager when the WinGet PowerShell module is available: it
        # registers the App Installer package for the current account even without an interactive
        # logon session, where a plain Add-AppxPackage is blocked with 0x80073D19
        # (microsoft/winget-cli#3862, issue #159).
        if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
            Write-WarningMessage 'Winget is not available. Bootstrapping it via Repair-WinGetPackageManager...'
            try {
                Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    Write-Success 'Winget bootstrapped successfully via Repair-WinGetPackageManager.'
                    return $true
                }
                Write-WarningMessage 'Repair-WinGetPackageManager completed but winget is still unavailable. Falling back to App Installer download...'
            }
            catch {
                Write-WarningMessage "Repair-WinGetPackageManager failed: $_. Falling back to App Installer download..."
            }
        }

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
    Checks if a specific winget source is trusted.
.DESCRIPTION
    This function checks if a specific winget source is trusted by listing all sources and checking if the target source is in the list.
    Automatically accepts source agreements to prevent the script from hanging on first run.
.PARAMETER target
    The name of the source to check.
.RETURNS
    [bool] True if the source is trusted, otherwise False.
#>
function Test-WingetSourceTrusted($target) {
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
    Initializes winget sources and agreements for the account performing the installs.
.DESCRIPTION
    Winget state — source registration and agreement acceptance — is per-user. When the script is
    elevated as a different account than the interactively logged-on user (e.g. an admin-* account
    entered at the UAC prompt), that account has no interactive logon session, and winget's
    first-use bootstrap (registering the Microsoft.Winget.Source MSIX package for the account) is
    blocked by the AppX deployment service with 0x80073D19
    (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF). Every install then fails, and no amount of
    retrying helps because the missing per-user state is persistent (issues #81/#104/#150, #159).

    This function probes with `winget source update --accept-source-agreements` (which both forces
    the bootstrap and persists agreement acceptance for the account). When the probe fails, it
    bootstraps winget for the account via Repair-WinGetPackageManager — which registers the App
    Installer and Microsoft.Winget.Source packages even without an interactive logon session
    (microsoft/winget-cli#6334) — and probes again.
.PARAMETER WhatIf
    When specified, only reports intended actions without executing.
.RETURNS
    [bool] True when sources are initialized and agreements accepted for the current account,
    otherwise False.
#>
function Initialize-WingetSourcesForUser {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would initialize winget sources and agreements for the current account'
        return $true
    }

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32.
    $deploymentBlockedExitCode = -2147009255
    # 0x8A150046 (APPINSTALLER_CLI_ERROR_SOURCE_AGREEMENTS_NOT_ACCEPTED) as a signed Int32.
    $agreementsNotAcceptedExitCode = -1978335162

    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    $isCrossUserElevation = ($processUser -and $sessionUser -and ($processUser -ne $sessionUser))
    if ($isCrossUserElevation) {
        Write-WarningMessage "Cross-user elevation detected: running as '$processUser' while '$sessionUser' owns the interactive session."
        Write-WarningMessage "Winget sources and agreements are per-user; initializing them for '$processUser'."
    }

    Write-Info 'Initializing winget sources for the current account (this may take a moment)...'
    $probe = Invoke-WingetSourceProbe
    if ($probe.Succeeded) {
        Write-Success 'Winget sources are initialized and agreements accepted for this account.'
        return $true
    }

    if ($probe.ExitCode -eq $deploymentBlockedExitCode) {
        Write-WarningMessage 'Winget source bootstrap was blocked by the AppX deployment service (0x80073D19): this account has no interactive logon session.'
    }
    elseif ($probe.ExitCode -eq $agreementsNotAcceptedExitCode) {
        Write-WarningMessage 'Winget source agreements are not yet accepted for this account (0x8A150046).'
    }
    elseif ($null -ne $probe.ExitCode) {
        Write-WarningMessage "Winget source update failed with exit code: $($probe.ExitCode)"
    }

    # Bootstrap via the WinGet PowerShell module: unlike winget's own first-use bootstrap (and
    # unlike a plain Add-AppxPackage), Repair-WinGetPackageManager registers the App Installer and
    # Microsoft.Winget.Source packages for the current account even without an interactive logon
    # session (microsoft/winget-cli#6334).
    if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
        Write-Info 'Bootstrapping winget for this account via Repair-WinGetPackageManager...'
        try {
            Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
        }
        catch {
            Write-WarningMessage "Repair-WinGetPackageManager failed: $_"
        }

        $probe = Invoke-WingetSourceProbe
        if ($probe.Succeeded) {
            Write-Success 'Winget sources initialized for this account after repair.'
            return $true
        }
    }
    else {
        Write-WarningMessage 'Repair-WinGetPackageManager is unavailable (Microsoft.WinGet.Client module missing); skipping winget bootstrap repair.'
    }

    Write-WarningMessage "Winget sources could not be initialized for '$processUser'. Installations may fail with 0x80073D19."
    if ($isCrossUserElevation) {
        Write-WarningMessage "Fix: log on to Windows interactively as '$processUser' once (this registers winget for that account), or run 'winget source update' from any session running as '$processUser', then re-run this script."
    }
    return $false
}

<#
.SYNOPSIS
    Installs a single winget package, retrying the transient 0x80073d19 session error with backoff.
.DESCRIPTION
    Runs `winget install` for one package id and captures winget's real process exit code via
    Start-Process -PassThru -Wait. Exit code 0x80073d19 (ERROR_INSTALL_USER_LOGOFF — "an error
    occurred because a user was logged off") is a transient MSIX/session-deployment race: an
    immediate retry simply hits the same race, which is why issues #81/#100/#102 left it unresolved.
    When that specific code is seen, this function waits with an increasing backoff and retries, up
    to MaxAttempts. Any other exit code (success or a real failure) is returned immediately so the
    caller can verify the result with `winget list` as before.

    winget's output is intentionally left unredirected so its native progress is still shown to the
    user; the session error is identified purely from the exit code, which winget reports as
    0x80073d19 for this failure.

    Installs prefer `--scope machine` (issue #159): user-scope installs land in the elevated
    account's profile rather than the logged-on user's, and packages that ship both MSIX and MSI
    installers (e.g. Microsoft.PowerShell) resolve at user scope to the MSIX — whose per-user AppX
    deployment is exactly what 0x80073D19 blocks under cross-user elevation. When a package has no
    machine-scope installer (e.g. the MSIX-only Microsoft.WindowsTerminal), winget returns
    0x8A150010 (NO_APPLICABLE_INSTALLER) and the install is retried once at winget's default scope.
.PARAMETER PackageId
    The winget package id to install (e.g. 'Microsoft.PowerShell').
.PARAMETER InstallerType
    Optional winget installer-type override (e.g. 'wix' to force the MSI), passed as
    `--installer-type <value>`. Needed for PowerShell: even with --scope machine, winget's
    installer-type precedence still selects the default MSIX, whose machine-scope provisioning fails
    as a packaged app on Windows < build 26100 with 0x8A150113 ("system configuration does not
    support"). Forcing 'wix' installs the machine-wide MSI instead (issue #163).
.PARAMETER MaxAttempts
    Maximum number of install attempts while the session error keeps recurring. Default 3.
.PARAMETER InitialDelaySeconds
    Seconds to wait before the first retry; the wait doubles on each subsequent retry. Default 5.
.RETURNS
    [hashtable] @{ ExitCode = <int>; Attempts = <int>; SessionErrorExhausted = <bool>; MachineScopeFellBack = <bool> }
    SessionErrorExhausted is True only when every attempt failed with the session error.
    MachineScopeFellBack is True when the package had no machine-scope installer and the install
    was retried at winget's default scope. Attempts counts install attempts at the finally
    selected scope; the one-time scope fallback does not consume a session-error attempt.
#>
function Install-WingetPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5
    )

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32, which is how winget
    # reports it through Process.ExitCode.
    $sessionLogoffExitCode = -2147009255
    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32: returned when
    # the --scope machine requirement filters out every installer in the package's manifest.
    $noApplicableInstallerExitCode = -1978335216

    $attempt = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $useMachineScope = $true
    $machineScopeFellBack = $false

    while ($attempt -lt $MaxAttempts) {
        $attempt++

        $installArgs = @(
            'install', '-e',
            '--accept-source-agreements', '--accept-package-agreements',
            '--source', 'winget',
            '--id', $PackageId
        )
        if ($useMachineScope) {
            $installArgs += @('--scope', 'machine')
        }
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $installArgs += @('--installer-type', $InstallerType)
        }

        $proc = Start-Process -FilePath 'winget' -ArgumentList $installArgs -NoNewWindow -Wait -PassThru
        $exitCode = $proc.ExitCode

        # No installer matched the machine-scope requirement (e.g. MSIX-only packages such as
        # Microsoft.WindowsTerminal, which only install per-user). Fall back to winget's default
        # scope once; this is a manifest property, not a transient error, so it does not consume
        # one of the session-error attempts.
        if ($useMachineScope -and $exitCode -eq $noApplicableInstallerExitCode) {
            Write-Info "$PackageId has no machine-scope installer. Retrying with winget's default scope..."
            $useMachineScope = $false
            $machineScopeFellBack = $true
            $attempt--
            continue
        }

        # Anything other than the transient session error (success or a real failure) is final here;
        # the caller verifies the actual install state with `winget list`.
        if ($exitCode -ne $sessionLogoffExitCode) {
            break
        }

        if ($attempt -lt $MaxAttempts) {
            Write-WarningMessage "Install of $PackageId hit transient session error 0x80073D19 (a user was logged off). Waiting ${delay}s before retry $($attempt + 1) of ${MaxAttempts}..."
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
        else {
            Write-WarningMessage "Install of $PackageId still failing with session error 0x80073D19 after ${MaxAttempts} attempts."
        }
    }

    return @{
        ExitCode              = $exitCode
        Attempts              = $attempt
        SessionErrorExhausted = ($exitCode -eq $sessionLogoffExitCode)
        MachineScopeFellBack  = $machineScopeFellBack
    }
}

<#
.SYNOPSIS
    Returns true when winget reports the given package id as installed for the current account.
.PARAMETER PackageId
    The winget package id to check.
#>
function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    try {
        $output = winget list --exact --id $PackageId --accept-source-agreements --disable-interactivity 2>&1
        return ([String]::Join('', $output)).Contains($PackageId)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns true when an MSIX/Appx package matching the given DisplayName/PackageName pattern is
    provisioned for all users on this machine.
.PARAMETER NameLike
    A wildcard pattern matched against provisioned packages' DisplayName and PackageName.
#>
function Test-AppxPackageProvisioned {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NameLike
    )

    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction Stop
        return [bool]($provisioned | Where-Object { $_.DisplayName -like $NameLike -or $_.PackageName -like $NameLike })
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Provisions a downloaded MSIX package (and its dependencies) for all users via DISM.
.DESCRIPTION
    Thin, mockable wrapper around Add-AppxProvisionedPackage. The Appx/DISM provider is unreliable
    under PowerShell 7 (it throws 0x80131539 "Operation is not supported on this platform"), so when
    running under pwsh the provisioning is delegated to Windows PowerShell 5.1. Returns True on
    success. A winget-source MSIX has no Store license, so -SkipLicense is used when no license file
    was downloaded alongside it.
.PARAMETER PackagePath
    Full path to the .msixbundle/.msix to provision.
.PARAMETER DependencyPackagePath
    Full paths to dependency packages (e.g. Microsoft.WindowsAppRuntime, VCLibs).
.PARAMETER LicensePath
    Optional path to a downloaded license .xml.
#>
function Invoke-AppxProvisioning {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [string[]]$DependencyPackagePath = @(),

        [Parameter(Mandatory = $false)]
        [string]$LicensePath
    )

    $hasLicense = $LicensePath -and (Test-Path $LicensePath)

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Delegate to Windows PowerShell 5.1, where the Appx/DISM provider works.
            $depClause = if ($DependencyPackagePath.Count -gt 0) {
                "-DependencyPackagePath @('" + ($DependencyPackagePath -join "','") + "')"
            }
            else { '' }
            $licClause = if ($hasLicense) { "-LicensePath '$LicensePath'" } else { '-SkipLicense' }
            $command = "Add-AppxProvisionedPackage -Online -PackagePath '$PackagePath' $depClause $licClause -ErrorAction Stop | Out-Null"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
            return ($LASTEXITCODE -eq 0)
        }

        $params = @{ Online = $true; PackagePath = $PackagePath; ErrorAction = 'Stop' }
        if ($DependencyPackagePath.Count -gt 0) { $params.DependencyPackagePath = $DependencyPackagePath }
        if ($hasLicense) { $params.LicensePath = $LicensePath } else { $params.SkipLicense = $true }
        Add-AppxProvisionedPackage @params | Out-Null
        return $true
    }
    catch {
        Write-ErrorMessage "Add-AppxProvisionedPackage failed for '$PackagePath': $_"
        return $false
    }
}

<#
.SYNOPSIS
    Installs the latest MSIX build of a winget package machine-wide by provisioning it via DISM.
.DESCRIPTION
    Used for the holdout case where a package is MSIX-only (e.g. PowerShell 7.7+) AND the machine is
    Windows older than build 26100, where winget cannot machine-scope-provision an MSIX because it
    calls the provisioning API from a packaged process. This function instead downloads the latest
    MSIX (plus dependencies and license) with `winget download`, then provisions it for all users
    with Add-AppxProvisionedPackage from a NON-packaged process, which is not subject to that bug
    (issue #166).

    VALIDATION NOTE: the DISM path is dormant until a package's winget default becomes MSIX-only
    (PowerShell 7.7 GA). It is covered by unit tests with mocked external calls, but the end-to-end
    behavior (winget download layout, license handling, all-users provisioning under cross-user
    elevation) should be validated on a real Windows 10 machine before it is relied upon.
.PARAMETER PackageId
    The winget package id to provision (e.g. 'Microsoft.PowerShell').
.PARAMETER VerifyNameLike
    Wildcard matched against provisioned package names to confirm success. Defaults to *<last id
    segment>* (e.g. '*PowerShell*').
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool> }
#>
function Install-MsixProvisionedPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$VerifyNameLike
    )

    if (-not $VerifyNameLike) {
        $VerifyNameLike = '*' + ($PackageId -split '\.')[-1] + '*'
    }

    $downloadDir = Join-Path $env:TEMP ('winget-msix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    try {
        Write-Info "Downloading the latest MSIX for $PackageId to provision it machine-wide..."
        $downloadArgs = @(
            'download', '-e', '--id', $PackageId, '--source', 'winget', '--installer-type', 'msix',
            '--accept-source-agreements', '--accept-package-agreements',
            '--download-directory', $downloadDir
        )
        $download = Start-Process -FilePath 'winget' -ArgumentList $downloadArgs -NoNewWindow -Wait -PassThru
        if ($download.ExitCode -ne 0) {
            Write-ErrorMessage "winget download failed for $PackageId (exit code $($download.ExitCode))."
            return @{ ExitCode = $download.ExitCode; Installed = $false }
        }

        $downloaded = Get-ChildItem -Path $downloadDir -Recurse -File -ErrorAction SilentlyContinue
        $bundle = $downloaded |
            Where-Object { $_.Extension -in '.msixbundle', '.appxbundle', '.msix', '.appx' -and $_.FullName -notmatch '[\\/]Dependencies[\\/]' } |
            Select-Object -First 1
        if (-not $bundle) {
            Write-ErrorMessage "No MSIX package was found in the winget download for $PackageId."
            return @{ ExitCode = -1; Installed = $false }
        }
        $dependencies = @($downloaded |
                Where-Object { $_.Extension -in '.msix', '.appx' -and $_.FullName -match '[\\/]Dependencies[\\/]' } |
                ForEach-Object { $_.FullName })
        $license = $downloaded | Where-Object { $_.Extension -eq '.xml' -and $_.Name -match 'License' } | Select-Object -First 1

        Write-Info "Provisioning $($bundle.Name) for all users..."
        $provisioned = Invoke-AppxProvisioning -PackagePath $bundle.FullName -DependencyPackagePath $dependencies -LicensePath $license.FullName

        $installed = $provisioned -and (Test-AppxPackageProvisioned -NameLike $VerifyNameLike)
        if ($installed) {
            Write-Success "$PackageId provisioned machine-wide via DISM."
        }
        else {
            Write-ErrorMessage "Failed to provision $PackageId machine-wide."
        }
        return @{ ExitCode = if ($installed) { 0 } else { -1 }; Installed = $installed }
    }
    finally {
        Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Installs the newest available PowerShell, choosing a delivery that works in an elevated
    cross-user / machine-scope context (no version pinning).
.DESCRIPTION
    winget's default already tracks the latest PowerShell, so this never pins a version. It only
    chooses HOW to deliver the latest so the install works machine-wide when the script is elevated
    as a different account than the logged-on user (issues #163/#166):

      1. Prefer the MSI while the current line still ships one (<= 7.6). The MSI installs machine-wide,
         works on any Windows build, and is runnable under Task Scheduler.
      2. Once the MSI is gone (7.7+), winget offers only the MSIX:
         - Windows 24H2+ (build >= 26100): winget can machine-scope-provision the MSIX, so install the
           default package directly.
         - Older Windows: winget's machine-scope MSIX provisioning is broken (it calls the provisioning
           API from a packaged process), so provision the MSIX for all users via DISM instead.

    The result's Installed flag is authoritative — the DISM-provisioned path does not appear under
    `winget list` for the elevating account, so the caller must not re-verify PowerShell with winget.
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool>; Method = 'msi' | 'msix-native' | 'msix-provisioned' }
#>
function Install-PowerShellLatest {
    param (
        [Parameter(Mandatory = $false)]
        [string]$PackageId = 'Microsoft.PowerShell'
    )

    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32 — what winget
    # returns for `--installer-type wix` once the manifest no longer ships an MSI.
    $noApplicableInstallerExitCode = -1978335216

    # 1. Prefer the MSI while the latest version still ships one.
    $result = Install-WingetPackage -PackageId $PackageId -InstallerType 'wix'
    if ($result.ExitCode -ne $noApplicableInstallerExitCode) {
        return @{ ExitCode = $result.ExitCode; Installed = (Test-WingetPackageInstalled -PackageId $PackageId); Method = 'msi' }
    }

    # 2. No MSI for the latest version (7.7+): install the latest MSIX machine-wide.
    Write-Info "No MSI is available for the latest $PackageId; installing the MSIX package instead."
    if ((Get-WindowsBuildNumber) -ge 26100) {
        $result = Install-WingetPackage -PackageId $PackageId
        return @{ ExitCode = $result.ExitCode; Installed = (Test-WingetPackageInstalled -PackageId $PackageId); Method = 'msix-native' }
    }

    $provision = Install-MsixProvisionedPackage -PackageId $PackageId
    return @{ ExitCode = $provision.ExitCode; Installed = $provision.Installed; Method = 'msix-provisioned' }
}

# ------------------------------------------------Main Script------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $SkipSystemCheck) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run pre-flight system checks (OS version, disk space, network).'
        }
        elseif (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
            exit 1
        }
    }

    Invoke-WingetInstall -WhatIf:$WhatIf
}
