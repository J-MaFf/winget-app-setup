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

