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

            # Verify the registration actually made winget available, like the Repair path above —
            # Add-AppxPackage can complete without winget landing on PATH (issue #177).
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Success 'Microsoft App Installer installed successfully. Winget is now available.'
                return $true
            }

            Write-ErrorMessage 'Microsoft App Installer was registered, but winget is still unavailable.'
            Write-ErrorMessage 'Please install winget manually from https://aka.ms/getwinget'
            return $false
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

    # Probe the source (listed + functional). The same helper is reused for the post-repair
    # re-probe below so the two checks can never diverge again (issue #177).
    $health = Test-WingetSourceHealth

    # If both checks pass, sources are good
    if ($health.Healthy) {
        return $true
    }

    # If source is missing entirely, attempt repair
    if (-not $health.Listed) {
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

    # Retry both checks after repair (quiet: this function reports the outcome itself)
    $health = Test-WingetSourceHealth -Quiet

    if ($health.Healthy) {
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
    Initializes winget sources and agreements for the account performing the installs.
.DESCRIPTION
    Winget state — source registration and agreement acceptance — is per-user. When the script is
    elevated as a different account than the interactively logged-on user (e.g. an admin-* account
    entered at the UAC prompt), that account has no interactive logon session, and winget's
    first-use bootstrap (registering the Microsoft.Winget.Source MSIX package for the account) is
    blocked by the AppX deployment service with 0x80073D19
    (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF). Every install then fails, and no amount of
    retrying helps because the missing per-user state is persistent (issues #81/#104/#150, #159).

    This function probes with `winget source update --name winget` (which forces the winget-source
    first-use bootstrap; agreements are accepted by the install commands, which pass
    `--accept-source-agreements`). When the probe fails, it bootstraps winget for the account via
    Repair-WinGetPackageManager — which registers the App Installer and Microsoft.Winget.Source
    packages even without an interactive logon session (microsoft/winget-cli#6334) — and probes
    again.
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

    Start-Process can also fail to launch winget.exe at all, throwing a terminating exception
    ("This command cannot be run due to the error: The file cannot be accessed by the system.",
    Win32 ERROR_CANT_ACCESS_FILE / 1920, or the sibling ERROR_SHARING_VIOLATION "being used by
    another process") instead of returning a process object with an exit code. This happens when
    winget.exe's own file is transiently locked — e.g. Windows Defender real-time scanning it, or
    an AppX package-registration race right after Repair-WinGetPackageManager runs. Because that
    exception is thrown before a process object ever exists, it used to bypass the exit-code-based
    retry loop below entirely: on a GitHub-hosted E2E runner this was observed to fail every
    install in a run, surviving even the caller's separate one-shot retry pass, because neither
    layer paused before retrying (issue #253). The Start-Process call is now wrapped so this
    specific class of launch exception is retried with the same backoff as the session error,
    instead of propagating out of the function on the first attempt. Any other exception (e.g.
    winget genuinely missing) is re-thrown unchanged so it is not silently swallowed.

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
    [hashtable] @{ ExitCode = <int|$null>; Attempts = <int>; SessionErrorExhausted = <bool>; MachineScopeFellBack = <bool>; LaunchErrorExhausted = <bool> }
    SessionErrorExhausted is True only when every attempt failed with the session error.
    MachineScopeFellBack is True when the package had no machine-scope installer and the install
    was retried at winget's default scope. Attempts counts install attempts at the finally
    selected scope; the one-time scope fallback does not consume a session-error attempt.
    LaunchErrorExhausted is True only when every attempt failed to launch winget.exe at all (issue
    #253); ExitCode is $null in that case, since no process ever ran to report one.
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
    # Text fragments of the Win32 errors Start-Process surfaces as a terminating exception when it
    # cannot even launch winget.exe (issue #253): ERROR_CANT_ACCESS_FILE (1920, "The file cannot be
    # accessed by the system.") and the sibling ERROR_SHARING_VIOLATION ("...being used by another
    # process."). Matched case-insensitively against the exception message; anything else is a real
    # failure (e.g. winget missing from PATH) and is re-thrown rather than retried.
    $transientLaunchErrorPattern = 'cannot be accessed by the system|being used by another process'

    $attempt = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $useMachineScope = $true
    $machineScopeFellBack = $false
    $launchErrorExhausted = $false

    while ($attempt -lt $MaxAttempts) {
        $attempt++

        # The shared agreement/interactivity flags come from Get-WingetAgreementArgs (issue #230
        # follow-up): every other winget call in the module already passed them, but this one -
        # the path every app install takes - did not, because each call site hand-duplicated the
        # literal array. Routing through the shared helper makes that omission structurally
        # impossible instead of relying on manual re-auditing.
        $installArgs = @(
            'install', '-e'
        ) + (Get-WingetAgreementArgs) + @(
            '--source', 'winget',
            '--id', $PackageId
        )
        if ($useMachineScope) {
            $installArgs += @('--scope', 'machine')
        }
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $installArgs += @('--installer-type', $InstallerType)
        }

        try {
            $proc = Start-Process -FilePath 'winget' -ArgumentList $installArgs -NoNewWindow -Wait -PassThru
            $exitCode = $proc.ExitCode
            $launchErrorExhausted = $false
        }
        catch {
            if ($_.Exception.Message -notmatch $transientLaunchErrorPattern) {
                # Not a known-transient launch failure (e.g. winget genuinely missing) — preserve
                # the prior behavior of letting it propagate instead of masking a real problem as
                # an ordinary install failure.
                throw
            }

            $launchErrorExhausted = $true
            if ($attempt -lt $MaxAttempts) {
                Write-WarningMessage "Could not launch winget for $PackageId - its executable appears transiently locked ($($_.Exception.Message)). Waiting ${delay}s before retry $($attempt + 1) of ${MaxAttempts}..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
                continue
            }

            Write-WarningMessage "Still unable to launch winget for $PackageId after ${MaxAttempts} attempts (executable transiently inaccessible on every attempt)."
            $exitCode = $null
            break
        }

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
        LaunchErrorExhausted  = $launchErrorExhausted
    }
}

<#
.SYNOPSIS
    Returns whether winget reports the given package id as installed for the current account.
.DESCRIPTION
    Without -TimeoutSeconds the check calls winget inline and returns a plain [bool], keeping the
    original contract for existing callers (e.g. Install-PowerShellLatest).

    With -TimeoutSeconds the check runs `winget list` via Start-Process with redirected output and
    a hard timeout, killing a hung winget instead of blocking the install loop — the pattern
    Invoke-WingetInstall used to inline three times before issue #188 centralized it here. Temp
    file names are unique per run so concurrent checks (or a stale locked file left by a killed
    run) cannot collide on fixed names (issue #177). In this mode a hashtable is returned so the
    caller can tell a timeout apart from "not installed": a timeout must count as a failure rather
    than being silently dropped (issue #176).

    Both modes determine "installed" via Test-WingetListOutputContainsPackageId rather than a plain
    substring .Contains check, so an unrelated listed id that merely contains $PackageId as a
    substring (e.g. target 'Foo.Bar' inside listed id 'Foo.BarBaz') cannot false-positive.
.PARAMETER PackageId
    The winget package id to check.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for `winget list` before killing it. When omitted (or 0), the original
    inline call without a timeout guard is used and a [bool] is returned.
.RETURNS
    [bool] when -TimeoutSeconds is not supplied.
    [hashtable] @{ Installed = <bool>; TimedOut = <bool>; ExitCode = <int or $null> } when it is;
    ExitCode is the winget process exit code, or $null when the process timed out or failed to
    start.
#>
function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0
    )

    if ($TimeoutSeconds -gt 0) {
        # Unique per-run temp files (issue #177): fixed names made concurrent runs (or a stale
        # locked file from a killed run) fail Start-Process.
        $tempSuffix = [System.IO.Path]::GetRandomFileName()
        $stdoutFile = Join-Path $env:TEMP "winget_list_output_$tempSuffix.txt"
        $stderrFile = Join-Path $env:TEMP "winget_list_error_$tempSuffix.txt"

        try {
            $listProcess = Start-Process -FilePath 'winget' `
                -ArgumentList 'list', '--exact', '--id', $PackageId, '--accept-source-agreements', '--disable-interactivity' `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile

            if (-not $listProcess.WaitForExit($TimeoutSeconds * 1000)) {
                try { $listProcess.Kill() } catch { }
                return @{ Installed = $false; TimedOut = $true; ExitCode = $null }
            }

            # Capture the exit code from the process object immediately; the output files are
            # only read after a confirmed non-timeout exit.
            $output = @(Get-Content $stdoutFile -ErrorAction SilentlyContinue)
            # Join with a newline, not '': Test-WingetListOutputContainsPackageId's boundary regex
            # treats anything outside [\w.\-] as a token edge, so an empty separator would let the
            # end of one line abut the start of the next and could hide a real match at that seam.
            return @{
                Installed = Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", $output)) -PackageId $PackageId
                TimedOut  = $false
                ExitCode  = $listProcess.ExitCode
            }
        }
        catch {
            return @{ Installed = $false; TimedOut = $false; ExitCode = $null }
        }
        finally {
            Remove-Item $stdoutFile -ErrorAction SilentlyContinue
            Remove-Item $stderrFile -ErrorAction SilentlyContinue
        }
    }

    try {
        $output = winget list --exact --id $PackageId --accept-source-agreements --disable-interactivity 2>&1
        return Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", $output)) -PackageId $PackageId
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
            # Every path is interpolated into a single-quoted literal inside the delegated
            # -Command string, so escape embedded single quotes by doubling them (issue #178).
            # Otherwise an apostrophe in a path (e.g. C:\Users\O'Brien\...) unbalances the
            # quoting — breaking provisioning at best, and at worst letting a crafted filename
            # break out of the literal inside an elevated powershell.exe -Command.
            $escapedPackagePath = $PackagePath.Replace("'", "''")
            $depClause = if ($DependencyPackagePath.Count -gt 0) {
                $escapedDependencyPaths = @($DependencyPackagePath | ForEach-Object { $_.Replace("'", "''") })
                "-DependencyPackagePath @('" + ($escapedDependencyPaths -join "','") + "')"
            }
            else { '' }
            $licClause = if ($hasLicense) { "-LicensePath '$($LicensePath.Replace("'", "''"))'" } else { '-SkipLicense' }
            $command = "Add-AppxProvisionedPackage -Online -PackagePath '$escapedPackagePath' $depClause $licClause -ErrorAction Stop | Out-Null"
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
            'download', '-e', '--id', $PackageId, '--source', 'winget', '--installer-type', 'msix'
        ) + (Get-WingetAgreementArgs) + @(
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

    # Matches Install-AppWithVerification's $checkTimeoutSeconds (Private/InstallVerification.ps1)
    # so a hung `winget list` during PowerShell's own self-verification fails into the retry pass
    # like every other catalog app's verification does, instead of blocking the run forever.
    $checkTimeoutSeconds = 15

    # 1. Prefer the MSI while the latest version still ships one.
    $result = Install-WingetPackage -PackageId $PackageId -InstallerType 'wix'
    if ($result.ExitCode -ne $noApplicableInstallerExitCode) {
        $installed = (Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds).Installed
        return @{ ExitCode = $result.ExitCode; Installed = $installed; Method = 'msi' }
    }

    # 2. No MSI for the latest version (7.7+): install the latest MSIX machine-wide.
    Write-Info "No MSI is available for the latest $PackageId; installing the MSIX package instead."
    if ((Get-WindowsBuildNumber) -ge 26100) {
        $result = Install-WingetPackage -PackageId $PackageId
        $installed = (Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds).Installed
        return @{ ExitCode = $result.ExitCode; Installed = $installed; Method = 'msix-native' }
    }

    $provision = Install-MsixProvisionedPackage -PackageId $PackageId
    return @{ ExitCode = $provision.ExitCode; Installed = $provision.Installed; Method = 'msix-provisioned' }
}

