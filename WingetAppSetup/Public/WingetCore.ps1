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
            # Validate the Id column looks like a real winget package id before trusting it,
            # so wrapped descriptions or stray output rows are not parsed as packages.
            if ($columns.Count -ge 4 -and $columns[1] -match '^[\w][\w.\-]+\.[\w][\w.\-]+$') {
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

