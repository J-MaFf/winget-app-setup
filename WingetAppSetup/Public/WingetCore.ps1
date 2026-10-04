<#
.SYNOPSIS
    Makes winget usable for this run: checks it, works out what is wrong, applies the fix for that,
    and says in one line what could not be fixed.
.DESCRIPTION
    One ladder (review finding P3-25) in place of three that ran back to back and gave one cause
    three diagnoses (Test-AndInstallWinget, Initialize-WingetSourcesForUser, Test-WingetSources),
    plus a source update before elevation that only ever set up the signed-in user's source. Each
    fix runs at most once per run.

      1. Group Policy (Get-WingetPolicyBlock, review finding P3-30). When App Installer's policy
         turns winget or its source off, no fix can help: the run stops with exit code 2 and names
         the policy. So does a winget that answers 0x8A15003A BLOCKED_BY_POLICY.
      2. Can winget start? `winget --version` must run and print a version (Test-WingetLaunchable).
         A failure that can clear on its own (winget.exe locked during an App Installer update,
         issues #253/#258) is checked for up to 75 seconds first, so an update in progress is not
         repaired underneath. Then the account fixes run (Invoke-NextWingetAccountFix), each
         followed by two checks 5 seconds apart: register the App Installer already on this PC for
         this account (the cross-user elevation fix), then Repair-WinGetPackageManager. When winget
         still cannot start, one line says why and what to do, and the run stops with exit code 2.
      3. The winget source: `winget source update --name winget` (Invoke-WingetSourceProbe). Its
         exit code picks the fix: 0x80073D19 (the account has no logon session, so Windows blocked
         registering the source for it, issue #159) gets the account fixes that have not run; a
         missing or corrupted source (class SourceBroken in Get-WingetExitCodeInfo) gets
         `winget source reset --force`. A timeout, a network error or any other code gets none: no
         repair fixes a network, and a slow proxy used to get App Installer replaced (review finding
         P3-28). A source that still fails is reported in one line, and the run carries on: each
         install then says why it failed.

    As SYSTEM (review finding P2-24) step 2 is Test-MachineWingetAvailable, which finds and checks
    the winget.exe App Installer installed for the PC, and no account fix runs: each sets winget up
    for one account, which SYSTEM cannot have.

    Two rungs were dropped. The aka.ms/getwinget download (review findings P3-25, P3-31: it also
    used a fixed file name in %TEMP%) installed the bundle Repair-WinGetPackageManager -Latest
    installs, but without the frameworks the bundle needs, and through the per-account deployment
    that 0x80073D19 blocks under cross-user elevation; the run it once rescued (issue #265) is now
    rescued by the registration rung. Registering cdn.winget.microsoft.com/cache/source.msix with
    Add-AppxPackage was that same per-account deployment, which `winget source update` and
    `winget source reset` make themselves.
.PARAMETER WhatIf
    Dry run (P2-16): only the policy and `winget --version` checks run. Nothing is registered,
    repaired, updated or reset; [DRY-RUN] lines say what a real run would do.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, which Invoke-WingetInstall passes; read here when not given.
.RETURNS
    [pscustomobject] Ready ([bool]: winget starts and no policy blocks it; a real run stops with exit
    code 2 when it is $false) and Diagnosis: 'Ok', 'SourceFailed' (ready, but the winget source
    could not be set up), 'PolicyBlocked' or 'NotLaunchable'.
#>
function Initialize-Winget {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    if ($null -eq $AccountContext) {
        $AccountContext = Get-InstallAccountContext
    }
    $isSystem = [bool]$AccountContext.IsSystem
    $account = 'SYSTEM'
    $who = 'SYSTEM'
    if (-not $isSystem) {
        $account = "$($AccountContext.ProcessUser)"
        $who = "'$account'"
    }
    # 0x8A15003A BLOCKED_BY_POLICY, 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF and
    # 0x8A150046 SOURCE_AGREEMENTS_NOT_ACCEPTED, as the signed Int32 winget exits with.
    $policyExitCode = -1978335174
    $sessionBlockedExitCode = -2147009255
    $agreementsExitCode = -1978335162
    $state = @{ ErrorCodes = @() }

    $policyBlocked = {
        param ([string]$Detail)
        $message = "Group Policy on this PC blocks winget: $Detail. This installer cannot install apps until the policy allows it; ask whoever manages this PC's policies (Computer Configuration > Administrative Templates > Windows Components > Desktop App Installer) to allow it, then re-run the installer."
        if ($WhatIf) {
            Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
        }
        else {
            Write-ErrorMessage $message
        }
        [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }

    $policy = Get-WingetPolicyBlock
    if ($policy) {
        return (& $policyBlocked ("'{0}' is Disabled ({1} = 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller)" -f $policy.Policy, $policy.Name))
    }

    if ($AccountContext.IsCrossUserElevation) {
        Write-WarningMessage "Cross-user elevation detected: running as '$account' while '$($AccountContext.SessionUser)' owns the interactive session."
        Write-WarningMessage "winget is set up per account; setting it up for '$account'."
    }

    if ($isSystem) {
        if (-not (Test-MachineWingetAvailable -WhatIf:$WhatIf)) {
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
    }
    else {
        $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
        if (-not $probe.Launchable -and -not $WhatIf) {
            Write-WarningMessage "Winget is not available: $($probe.Reason)."
            while (-not $probe.Launchable -and $probe.ExitCode -ne $policyExitCode -and (Invoke-NextWingetAccountFix -State $state)) {
                $probe = Test-WingetLaunchable -Attempts 2 -RetryDelaySeconds 5
            }
        }
        if ($probe.ExitCode -eq $policyExitCode) {
            return (& $policyBlocked ("'winget --version' answered {0}" -f (Format-WingetExitCode -ExitCode $probe.ExitCode)))
        }
        if (-not $probe.Launchable) {
            if ($WhatIf) {
                Write-Info "[DRY-RUN] Winget is not available for this account ($($probe.Reason)). A real run would set it up: register the App Installer package already on this PC for this account, then run Repair-WinGetPackageManager (installing its Microsoft.WinGet.Client module from the PowerShell Gallery first if it is missing), and stop with exit code 2 if winget still cannot be started."
                return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
            }
            $seen = ''
            $codes = @($state.ErrorCodes | Select-Object -Unique)
            if ($codes.Count -gt 0) {
                $seen = ' App Installer could not be registered or repaired ({0}).' -f (@($codes | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
            }
            Write-ErrorMessage ("Winget cannot be started for {0}: {1}.{2} {3}" -f $who, $probe.Reason, $seen, (Get-WingetSetupAdvice -State $state -Account $account))
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        Write-Success "Winget is available ($($probe.Version))."
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would update the winget source for $who (winget source update --name winget), and fix it if that fails: winget source reset --force for a missing or corrupted source, which also removes any source added beyond the defaults."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    Write-Info "Updating the winget source for $who (this may take a moment)..."
    $source = Invoke-WingetSourceProbe
    while (-not $source.Succeeded) {
        $fixed = $false
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $source.ExitCode
        if ($source.ExitCode -eq $sessionBlockedExitCode -and -not $isSystem) {
            $fixed = Invoke-NextWingetAccountFix -State $state
        }
        elseif ($codeInfo -and $codeInfo.Class -eq 'SourceBroken' -and -not $state.ContainsKey('SourceReset')) {
            $state.SourceReset = Reset-WingetSource
            $fixed = $true
        }
        if (-not $fixed) {
            break
        }
        $source = Invoke-WingetSourceProbe
    }

    if ($source.Succeeded) {
        Write-Success "The winget source is up to date for $who."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }
    if ($source.ExitCode -eq $policyExitCode) {
        return (& $policyBlocked ("'winget source update' answered {0}" -f (Format-WingetExitCode -ExitCode $source.ExitCode)))
    }
    if ($source.ExitCode -eq $agreementsExitCode) {
        Write-Info 'The winget source agreements are not accepted for this account yet (0x8A150046); each install accepts them.'
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    $detail = 'it did not finish in time and was stopped'
    if ($source.LaunchError) {
        $detail = "winget could not be started: $($source.LaunchError)"
    }
    elseif (-not $source.TimedOut) {
        $detail = 'exit code {0}' -f (Format-WingetExitCode -ExitCode $source.ExitCode)
    }
    Write-WarningMessage ('The winget source could not be set up for {0} ({1}). {2} Installations may fail.' -f $who, $detail, (Get-WingetSetupAdvice -State $state -Account $account -Source -SourceExitCode $source.ExitCode))
    return [pscustomobject]@{ Ready = $true; Diagnosis = 'SourceFailed' }
}

<#
.SYNOPSIS
    Installs a single winget package, retrying the results that clear on their own: the 0x80073d19
    session error, another installation in progress, and an app or file in use.
.DESCRIPTION
    Runs `winget install` for one package id through Invoke-WingetProcess and reads winget's real
    process exit code from the result. Exit code 0x80073d19 (ERROR_INSTALL_USER_LOGOFF — "an error
    occurred because a user was logged off") is a transient MSIX/session-deployment race: an
    immediate retry simply hits the same race, which is why issues #81/#100/#102 left it unresolved.
    When that specific code is seen, this function waits with an increasing backoff and retries, up
    to MaxAttempts.

    Two more results are retried (review finding P2-15), decided by their class in
    Get-WingetExitCodeInfo:
      - 0x8A150102 (INSTALL_INSTALL_IN_PROGRESS): Windows Installer was busy with another
        installation (msiexec 1618), which it reports at once instead of waiting. Common on a fresh
        PC whose management agent, OEM tools or Teams are still installing. This function waits
        until Windows Installer is idle (Wait-WindowsInstallerIdle, checking every 15 seconds) and
        retries, up to InstallInProgressRetries times, waiting at most InstallInProgressWaitSeconds
        in all. Invoke-WingetInstall passes what is left of the run's 10-minute budget, so a machine
        that stays busy costs the run 10 minutes at most, not 10 minutes per app.
      - 0x8A150101, 0x8A150103 and 0x8A150111 (the app or its files are in use): one retry after
        InUseRetryDelaySeconds.
    0x8A15010A (a restart is required before the installer can run) is never retried: only a restart
    changes it. Any other exit code (success or a real failure) is returned at once so the caller
    can verify the result with `winget list` as before.

    Restart required to finish (review finding P3-16): winget 1.7 and later report an MSI, WiX or
    Burn installer's 3010 as exit 0 and print 'Restart your PC to finish installation.'; winget 1.6
    and older exit 0x8A150109, and an installer that started a restart itself (MSI 1641) gives
    0x8A15010B. RestartRequired says so for any of the three. The printed warning is matched in
    English only; on other display languages the caller's pending-restart registry check is what
    notices it.

    Each install has a time limit (Get-ProcessTimeoutSeconds WingetInstall, review finding P2-5):
    when it runs out, winget and the installer it started are stopped, and the result says TimedOut
    with no exit code; a timed-out install is not retried here. winget's output is echoed into the
    console and the transcript as it arrives (P2-6), so the installer's own error text ("Installer
    failed with exit code: 1603") is in the log the teammate attaches, and winget writes the
    installer's log (--log) to the run's logs folder; InstallerLogPath points at it when the
    installer wrote one. When the run is unattended (-Silent), winget gets --silent, so MSI and
    WiX packages install with /quiet instead of /passive.

    winget can also fail to launch at all, with Win32 ERROR_CANT_ACCESS_FILE (1920, "The file cannot
    be accessed by the system.") or the sibling ERROR_SHARING_VIOLATION (32, "being used by another
    process"), instead of producing an exit code. This happens when winget.exe's own file is
    transiently locked — e.g. Windows Defender real-time scanning it, or an AppX
    package-registration race right after Repair-WinGetPackageManager runs. A failed launch used to
    bypass the exit-code-based retry loop below entirely: on a GitHub-hosted E2E runner this was
    observed to fail every install in a run, surviving even the caller's separate one-shot retry
    pass, because neither layer paused before retrying (issue #253). This class of launch failure is
    now retried, recognized by its Win32 error code rather than by its translated message (P3-6).
    Any other launch failure (e.g. winget genuinely missing, or 'Access is denied') is not retried:
    it ends the install at once with LaunchErrorExhausted and the launch error in the result, so
    the caller reports that winget could not be launched (and Invoke-WingetInstall's circuit
    breaker can stop the run) instead of an unexpected error.

    Launch failures have their own retry budget, longer than the session-error one (issue #258):
    the dominant real-world cause is a Microsoft.DesktopAppInstaller (App Installer) upgrade or
    re-registration in flight - e.g. a background Winget-AutoUpdate run - which breaks the per-user
    winget.exe app-execution alias for the whole registration window, far longer than the 15s the
    #253 backoff covered. The launch backoff doubles across MaxLaunchAttempts (default 5:
    5s+10s+20s+40s = 75s of coverage) so the retry window outlasts a typical App Installer
    registration. A failed launch never ran winget, so it does not consume one of the MaxAttempts
    install attempts. (Each retry used to launch the package's own winget.exe past the alias,
    Resolve-WingetExecutable -BypassAlias; that never worked and was removed, review finding P3-7.)

    Installs prefer `--scope machine` (issue #159): user-scope installs land in the elevated
    account's profile rather than the logged-on user's, and packages that ship both MSIX and MSI
    installers (e.g. Microsoft.PowerShell) resolve at user scope to the MSIX — whose per-user AppX
    deployment is exactly what 0x80073D19 blocks under cross-user elevation. When a package has no
    machine-scope installer (e.g. the MSIX-only Microsoft.WindowsTerminal), winget returns
    0x8A150010 (NO_APPLICABLE_INSTALLER) and the install is retried once at winget's default scope,
    unless -MachineScopeOnly says the run must not install for one account (review finding P3-22).
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
.PARAMETER MaxLaunchAttempts
    Maximum number of times to attempt launching winget.exe while the launch keeps failing with the
    transient file-lock error (issue #258). Separate from MaxAttempts because a failed launch never
    ran an install; the wait starts at InitialDelaySeconds and doubles on each launch retry.
    Default 5 (75s of total backoff at the default InitialDelaySeconds).
.PARAMETER Silent
    Pass --silent to winget. Invoke-WingetInstall passes its effective non-interactive state. When
    the parameter is not given, Test-EffectiveNonInteractive decides (e.g. for a script that calls
    the function on its own).
.PARAMETER InstallInProgressRetries
    How many times to retry after 0x8A150102 (another installation in progress). Default 3.
.PARAMETER InstallInProgressWaitSeconds
    The most this call may wait, in all, for Windows Installer to finish another installation.
    Default 600 (10 minutes). 0: no wait, so 0x8A150102 is final at once.
.PARAMETER InUseRetryDelaySeconds
    Seconds to wait before the one retry after an in-use result. Default 60.
.PARAMETER MachineScopeOnly
    Never fall back to winget's default scope (review finding P3-22). Invoke-WingetInstall passes it
    for a run as SYSTEM or under cross-user elevation, where the default scope installs into the
    wrong profile: SYSTEM's own, or the elevating admin's instead of the signed-in user's, and the
    verification, run as that same account, then reported it installed. A package with no
    machine-scope installer then ends at once with NoMachineScopeInstaller, and the caller defers
    it (leaves it for the signed-in user's own account).
.RETURNS
    [hashtable] @{ ExitCode = <int|$null>; Attempts = <int>; SessionErrorExhausted = <bool>; MachineScopeFellBack = <bool>; NoMachineScopeInstaller = <bool>; LaunchErrorExhausted = <bool>; LaunchAttempts = <int>; LaunchError = <string|$null>; TimedOut = <bool>; TimeoutSeconds = <int>; InstallerLogPath = <string|$null>; InstallInProgressWaitedSeconds = <int>; RestartRequired = <bool> }
    SessionErrorExhausted is True only when every attempt failed with the session error.
    InstallInProgressWaitedSeconds is how long this call waited for another installation to finish.
    RestartRequired is True when the last attempt's result says a restart finishes the installation
    (see the description); the caller decides from `winget list` whether the package installed.
    MachineScopeFellBack is True when the package had no machine-scope installer and the install
    was retried at winget's default scope. NoMachineScopeInstaller is True when it had none and
    -MachineScopeOnly kept it from being installed at all (ExitCode is then 0x8A150010). Attempts
    counts install attempts at the finally selected scope, the retries after another installation
    in progress or an in-use result included; the one-time scope fallback does not consume a
    session-error attempt, and neither does a failed launch (no process ran). LaunchAttempts counts failed winget launches.
    LaunchErrorExhausted is True when winget.exe could not be launched: a transient launch failure
    through every launch attempt (issues #253/#258), or any other launch failure at once; ExitCode
    is $null in that case, since no process ran to report an exit code, and LaunchError is the last
    launch error. TimedOut is True when the last attempt ran out of time
    and was stopped (ExitCode is then $null); TimeoutSeconds is the limit it had. InstallerLogPath
    is the installer log winget wrote for the last attempt, or $null when there is none.
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
        [int]$InitialDelaySeconds = 5,

        [Parameter(Mandatory = $false)]
        [int]$MaxLaunchAttempts = 5,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressRetries = 3,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600,

        [Parameter(Mandatory = $false)]
        [int]$InUseRetryDelaySeconds = 60,

        [Parameter(Mandatory = $false)]
        [switch]$MachineScopeOnly
    )

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32, which is how winget
    # reports it through Process.ExitCode.
    $sessionLogoffExitCode = -2147009255
    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32: returned when
    # the --scope machine requirement filters out every installer in the package's manifest.
    $noApplicableInstallerExitCode = -1978335216

    $useSilent = [bool]$Silent
    if (-not $PSBoundParameters.ContainsKey('Silent')) {
        $useSilent = [bool](Test-EffectiveNonInteractive)
    }
    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetInstall

    $attempt = 0
    $sessionErrors = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $installInProgressRetried = 0
    $installInProgressWaited = 0
    $inUseRetried = $false
    $restartRequired = $false
    $useMachineScope = $true
    $machineScopeFellBack = $false
    $noMachineScopeInstaller = $false
    $launchErrorExhausted = $false
    $launchAttempt = 0
    $launchDelay = $InitialDelaySeconds
    $launchError = $null
    $timedOut = $false
    $installerLogPath = $null

    while ($true) {
        $attempt++
        $restartRequired = $false

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
        if ($useSilent) {
            # Without --silent winget runs MSI and WiX installers with /passive (a progress window)
            # rather than /quiet.
            $installArgs += '--silent'
        }

        $run = Invoke-WingetProcess -ArgumentList $installArgs -TimeoutSeconds $timeoutSeconds
        $installerLogPath = $null
        if ($run.LogPath -and (Test-Path -LiteralPath $run.LogPath)) {
            $installerLogPath = $run.LogPath
        }
        if ($run.LaunchFailed) {
            # A failed launch never ran winget, so it must not consume an install attempt; launch
            # failures have their own budget (issue #258).
            $attempt--
            $launchAttempt++
            $launchError = $run.LaunchError
            $transient = Test-TransientWingetLaunchError -NativeErrorCode $run.LaunchErrorCode -Message $run.LaunchError
            if ($transient -and $launchAttempt -lt $MaxLaunchAttempts) {
                # The usual cause is the winget.exe app-execution alias breaking while the
                # DesktopAppInstaller package is upgraded or re-registered underneath us (e.g. by
                # a background Winget-AutoUpdate run), or an antivirus scan of winget.exe.
                Write-WarningMessage "Could not launch winget for $PackageId - its executable appears transiently locked ($($run.LaunchError)). Waiting ${launchDelay}s before launch retry $($launchAttempt + 1) of ${MaxLaunchAttempts}..."
                Start-Sleep -Seconds $launchDelay
                $launchDelay = $launchDelay * 2
                continue
            }

            if ($transient) {
                Write-WarningMessage "Still unable to launch winget for $PackageId after ${MaxLaunchAttempts} launch attempts ($($run.LaunchError))."
            }
            else {
                # Not a lock that clears on its own (e.g. winget missing, or 'Access is denied'):
                # retrying would only wait.
                Write-WarningMessage "Could not launch winget for ${PackageId}: $($run.LaunchError)"
            }
            $launchErrorExhausted = $true
            $exitCode = $null
            break
        }

        if ($run.TimedOut) {
            # Invoke-ExternalProcess stopped winget and the installer it was running. A hung
            # installer would most likely hang again, so this is final; the caller's verification
            # and the run's retry pass decide what happens next.
            Write-ErrorMessage ("Install of {0} did not finish within {1} minutes and was stopped." -f $PackageId, [Math]::Round($timeoutSeconds / 60))
            $timedOut = $true
            $exitCode = $null
            break
        }

        $exitCode = $run.ExitCode
        if ($exitCode -ne 0 -and $installerLogPath) {
            Write-Info "Installer log for ${PackageId}: $installerLogPath"
        }

        # No installer matched the machine-scope requirement (e.g. MSIX-only packages such as
        # Microsoft.WindowsTerminal, which only install per-user). Fall back to winget's default
        # scope once; this is a manifest property, not a transient error, so it does not consume
        # one of the session-error attempts.
        if ($useMachineScope -and $exitCode -eq $noApplicableInstallerExitCode) {
            if ($MachineScopeOnly) {
                # A run as SYSTEM or under cross-user elevation (review finding P3-22): the default
                # scope would install the app for the account running this, not for the user.
                Write-Info "winget found no machine-scope installer for $PackageId that applies to this PC, and this run installs for the whole PC only, so it is not installed at winget's default (per-user) scope."
                $noMachineScopeInstaller = $true
                break
            }
            Write-Info "$PackageId has no machine-scope installer. Retrying with winget's default scope..."
            $useMachineScope = $false
            $machineScopeFellBack = $true
            $attempt--
            continue
        }

        if ($exitCode -eq $sessionLogoffExitCode) {
            $sessionErrors++
            if ($sessionErrors -lt $MaxAttempts) {
                Write-WarningMessage "Install of $PackageId hit transient session error 0x80073D19 (a user was logged off). Waiting ${delay}s before retry $($sessionErrors + 1) of ${MaxAttempts}..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
                continue
            }
            Write-WarningMessage "Install of $PackageId still failing with session error 0x80073D19 after ${MaxAttempts} attempts."
            break
        }

        $codeClass = ''
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $exitCode
        if ($codeInfo) {
            $codeClass = $codeInfo.Class
        }

        if ($codeClass -eq 'InstallInProgress') {
            # Windows Installer returns 1618 at once while another installation holds it (review
            # finding P2-15): wait for that installation, within this call's share of the budget.
            $waitLeft = $InstallInProgressWaitSeconds - $installInProgressWaited
            if ($installInProgressRetried -lt $InstallInProgressRetries -and $waitLeft -gt 0) {
                $installInProgressRetried++
                Write-WarningMessage ("Windows Installer is busy with another installation ({0}). Waiting for it to finish (at most {1} seconds) before retry {2} of {3} for {4}..." -f (Format-WingetExitCode -ExitCode $exitCode), $waitLeft, $installInProgressRetried, $InstallInProgressRetries, $PackageId)
                $wait = Wait-WindowsInstallerIdle -MaximumSeconds $waitLeft
                $installInProgressWaited += [int]$wait.WaitedSeconds
                continue
            }
            Write-WarningMessage ("Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting; {2} was not installed." -f $installInProgressRetried, $installInProgressWaited, $PackageId)
            break
        }

        if ($codeClass -eq 'InUse' -and -not $inUseRetried) {
            $inUseRetried = $true
            Write-WarningMessage ("{0} could not be installed because it or its files are in use ({1}). Waiting {2}s before one more try..." -f $PackageId, (Format-WingetExitCode -ExitCode $exitCode), $InUseRetryDelaySeconds)
            Start-Sleep -Seconds $InUseRetryDelaySeconds
            continue
        }

        # Success, a restart-required result (0x8A15010A is never retried: only a restart changes
        # it) or another failure: final here. The caller verifies the actual install state with
        # `winget list`.
        # winget 1.7+ turns an installer's 3010 into exit 0 and says so only in its output
        # ('Restart your PC to finish installation.', English display language only).
        $restartRequired = Test-WingetRestartRequiredResult -ExitCode $exitCode -Output $run.Output
        break
    }

    return @{
        ExitCode                       = $exitCode
        Attempts                       = $attempt
        SessionErrorExhausted          = ($exitCode -eq $sessionLogoffExitCode)
        MachineScopeFellBack           = $machineScopeFellBack
        NoMachineScopeInstaller        = $noMachineScopeInstaller
        LaunchErrorExhausted           = $launchErrorExhausted
        LaunchAttempts                 = $launchAttempt
        LaunchError                    = $(if ($launchErrorExhausted) { $launchError } else { $null })
        TimedOut                       = $timedOut
        TimeoutSeconds                 = $timeoutSeconds
        InstallerLogPath               = $installerLogPath
        InstallInProgressWaitedSeconds = $installInProgressWaited
        RestartRequired                = $restartRequired
    }
}

<#
.SYNOPSIS
    Returns whether winget reports the given package id as installed for the current account.
.DESCRIPTION
    Runs `winget list --exact --id <id>` through Invoke-WingetProcess, quietly (the per-app checks
    would otherwise print a table twice for every app), and always under a time limit, killing a
    hung winget instead of blocking the install loop (issues #176, #188).

    Without -TimeoutSeconds the check uses the general `winget list` limit (Get-ProcessTimeoutSeconds
    WingetList) and returns a plain [bool], keeping the original contract for existing callers; any
    failure to get an answer reads as not installed. With -TimeoutSeconds a hashtable is returned so
    the caller can tell the three outcomes apart: installed, not installed, and no answer. A
    timeout must count as a failure rather than being silently dropped (issue #176), and so must a
    winget that could not be started (LaunchFailed, review finding P2-9): reading that as "not
    installed" made Install-AppWithVerification install apps that were already there and then
    report them as 'package not found after install'. A failed launch is not retried here; the
    caller decides (Invoke-WingetInstall's circuit breaker checks whether winget can still start).
    The same goes for a `winget list` that ran but failed (CheckFailed): it exits 0 when it lists
    the package and 0x8A150014 (APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND) when nothing matches,
    and it only warns about a source it could not search. Any other exit code with no match (for
    example 0x8A15004B, every source failed to open) means the check itself failed.

    Both modes determine "installed" via Test-WingetListOutputContainsPackageId rather than a plain
    substring .Contains check, so an unrelated listed id that merely contains $PackageId as a
    substring (e.g. target 'Foo.Bar' inside listed id 'Foo.BarBaz') cannot false-positive.
.PARAMETER PackageId
    The winget package id to check.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for `winget list` before killing it. When omitted (or 0), the general
    `winget list` limit applies and a [bool] is returned.
.RETURNS
    [bool] when -TimeoutSeconds is not supplied.
    [hashtable] @{ Installed = <bool>; TimedOut = <bool>; LaunchFailed = <bool>;
    LaunchError = <string or $null>; CheckFailed = <bool>; ExitCode = <int or $null> } when it is.
    Installed is True only when winget answered and listed the id. TimedOut, LaunchFailed and
    CheckFailed mean there was no answer: winget ran out of time, could not be started (LaunchError
    says why), or ran and failed without listing the id (ExitCode says how). ExitCode is the winget
    process exit code, or $null when winget did not run to the end.
#>
function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0
    )

    $listArgs = @('list', '--exact', '--id', $PackageId, '--accept-source-agreements', '--disable-interactivity')

    if ($TimeoutSeconds -gt 0) {
        $run = Invoke-WingetProcess -ArgumentList $listArgs -TimeoutSeconds $TimeoutSeconds -Echo None
        if ($run.LaunchFailed) {
            return @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = $run.LaunchError; CheckFailed = $false; ExitCode = $null }
        }

        if ($run.TimedOut) {
            return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
        }

        # Standard output only, as before: an error message on standard error can name the id too.
        # Join with a newline, not '': Test-WingetListOutputContainsPackageId's boundary regex
        # treats anything outside [\w.\-] as a token edge, so an empty separator would let the
        # end of one line abut the start of the next and could hide a real match at that seam.
        $installed = Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", @($run.StandardOutput))) -PackageId $PackageId

        # 0 (listed) and 0x8A150014 (APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND, as a signed
        # Int32) are the answers; any other exit code without a match is a failed check, not "not
        # installed" (review finding P2-9).
        $noApplicationsFoundExitCode = -1978335212
        $checkFailed = (-not $installed) -and ($null -ne $run.ExitCode) -and (@(0, $noApplicationsFoundExitCode) -notcontains [int]$run.ExitCode)

        return @{
            Installed    = $installed
            TimedOut     = $false
            LaunchFailed = $false
            LaunchError  = $null
            CheckFailed  = $checkFailed
            ExitCode     = $run.ExitCode
        }
    }

    $run = Invoke-WingetProcess -ArgumentList $listArgs -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetList) -Echo None
    if ($run.LaunchFailed -or $run.TimedOut) {
        return $false
    }
    return Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", @($run.Output))) -PackageId $PackageId
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
        $download = Invoke-WingetProcess -ArgumentList $downloadArgs -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetDownload)
        if ($download.LaunchFailed) {
            # As before, a winget that cannot start at all propagates to the caller.
            throw $download.LaunchException
        }
        if ($download.TimedOut) {
            Write-ErrorMessage "winget download for $PackageId did not finish in time and was stopped."
            return @{ ExitCode = $null; Installed = $false }
        }
        if ($download.ExitCode -ne 0) {
            Write-ErrorMessage ('winget download failed for {0} (exit code {1}).' -f $PackageId, (Format-WingetExitCode -ExitCode $download.ExitCode))
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
.PARAMETER PackageId
    The winget package id. Default 'Microsoft.PowerShell'.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (winget --silent, so the MSI installs with /quiet rather than
    /passive). Install-AppWithVerification passes the run's effective non-interactive state, so an
    explicit -NonInteractive reaches PowerShell's install too. Not given: Install-WingetPackage
    decides.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, for another installation to finish (Install-WingetPackage's parameter
    of the same name), shared by the MSI and MSIX attempts. Install-AppWithVerification passes what
    is left of the run's budget. Not given: Install-WingetPackage's default.
.PARAMETER MachineScopeOnly
    Forwarded to Install-WingetPackage (review finding P3-22): a run as SYSTEM or under cross-user
    elevation never installs PowerShell at winget's default (per-user) scope. When the MSIX has no
    machine-scope installer either, the result says NoMachineScopeInstaller, with no `winget list`
    check, and Install-AppWithVerification defers PowerShell.
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool>; Method = 'msi' | 'msix-native' | 'msix-provisioned' }
    The winget paths (msi, msix-native) return Install-WingetPackage's whole result with Installed
    and Method added (review finding P3-8: only ExitCode survived, so PowerShell's failure reason
    read just 'installer reported failure' while every other app's said why), plus the outcome of
    the `winget list` check: VerifyTimedOut, VerifyLaunchFailed, VerifyLaunchError, VerifyCheckFailed
    (`winget list` ran and failed) and VerifyExitCode (its exit code). When winget could not be
    launched for the install (LaunchErrorExhausted), the check is skipped: it would only fail to
    launch again.
#>
function Install-PowerShellLatest {
    param (
        [Parameter(Mandatory = $false)]
        [string]$PackageId = 'Microsoft.PowerShell',

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds,

        [Parameter(Mandatory = $false)]
        [switch]$MachineScopeOnly
    )

    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32 — what winget
    # returns for `--installer-type wix` once the manifest no longer ships an MSI.
    $noApplicableInstallerExitCode = -1978335216

    # The same limit as Install-AppWithVerification's checks (Private/InstallVerification.ps1), so a
    # hung `winget list` during PowerShell's own self-verification fails into the retry pass like
    # every other catalog app's verification does, instead of blocking the run forever.
    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck

    $installParameters = @{ PackageId = $PackageId }
    if ($PSBoundParameters.ContainsKey('Silent')) {
        $installParameters['Silent'] = $Silent
    }
    if ($MachineScopeOnly) {
        $installParameters['MachineScopeOnly'] = $true
    }

    # The wait for another installation to finish (review finding P2-15) is one budget for both
    # attempts below.
    if ($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds')) {
        $installParameters['InstallInProgressWaitSeconds'] = $InstallInProgressWaitSeconds
    }

    # 1. Prefer the MSI while the latest version still ships one.
    $method = 'msi'
    $result = Install-WingetPackage @installParameters -InstallerType 'wix'
    $installInProgressWaited = [int]$result.InstallInProgressWaitedSeconds
    if ($result.ExitCode -eq $noApplicableInstallerExitCode) {
        # 2. No MSI for the latest version (7.7+): install the latest MSIX machine-wide.
        Write-Info "No MSI is available for the latest $PackageId; installing the MSIX package instead."
        if ((Get-WindowsBuildNumber) -lt 26100) {
            $provision = Install-MsixProvisionedPackage -PackageId $PackageId
            return @{ ExitCode = $provision.ExitCode; Installed = $provision.Installed; Method = 'msix-provisioned'; InstallInProgressWaitedSeconds = $installInProgressWaited }
        }
        $method = 'msix-native'
        if ($installParameters.ContainsKey('InstallInProgressWaitSeconds')) {
            $installParameters['InstallInProgressWaitSeconds'] = [Math]::Max(0, $InstallInProgressWaitSeconds - $installInProgressWaited)
        }
        $result = Install-WingetPackage @installParameters
        $installInProgressWaited += [int]$result.InstallInProgressWaitedSeconds
    }

    # Install-WingetPackage's whole result (exit code, attempts, scope fallback, session and launch
    # errors, time limit, installer log), so Format-InstallFailureReason renders the same detail for
    # PowerShell as for every other app (review finding P3-8).
    $outcome = @{}
    if ($result -is [hashtable]) {
        foreach ($key in $result.Keys) {
            $outcome[$key] = $result[$key]
        }
    }
    else {
        $outcome['ExitCode'] = $result.ExitCode
    }
    $outcome['Method'] = $method
    $outcome['InstallInProgressWaitedSeconds'] = $installInProgressWaited
    $outcome['VerifyTimedOut'] = $false
    $outcome['VerifyLaunchFailed'] = $false
    $outcome['VerifyLaunchError'] = $null
    $outcome['VerifyCheckFailed'] = $false
    $outcome['VerifyExitCode'] = $null

    if ($outcome['LaunchErrorExhausted'] -or $outcome['NoMachineScopeInstaller']) {
        # winget never started, or found no installer this run may use, so nothing was installed,
        # and the check would only fail to launch again or say so.
        $outcome['Installed'] = $false
        return $outcome
    }

    $verify = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
    $outcome['Installed'] = [bool]$verify.Installed
    $outcome['VerifyTimedOut'] = [bool]$verify.TimedOut
    $outcome['VerifyLaunchFailed'] = [bool]$verify.LaunchFailed
    $outcome['VerifyLaunchError'] = $verify.LaunchError
    $outcome['VerifyCheckFailed'] = [bool]$verify.CheckFailed
    $outcome['VerifyExitCode'] = $verify.ExitCode
    return $outcome
}

