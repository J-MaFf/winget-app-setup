<#
.SYNOPSIS
    Makes winget usable for this run: checks it, works out what is wrong, applies the fix for that,
    and says in one line what could not be fixed.
.DESCRIPTION
    One ladder (P3-25); each fix runs at most once a run:
      1. Group Policy (Get-WingetPolicyBlock): App Installer's policy turning winget or its source
         off, or winget answering 0x8A15003A, stops the run with exit code 2; no fix can help. The
         install run's pre-flight checks the policy first; the uninstaller relies on this check.
      2. Can winget start (Test-WingetLaunchable)? A failure that can clear on its own (an App
         Installer update, issues #253/#258) is checked for up to 75 seconds before any repair.
         Then the account fixes (Invoke-NextWingetAccountFix), each followed by two checks 5 seconds
         apart: register the App Installer already on the PC, then Repair-WinGetPackageManager. Still
         not startable: one line says why and what to do, and the run stops with exit code 2.
      3. The winget source (Invoke-WingetSourceCheck): `winget source update`, which exits 0 even
         when its update fails, then Test-WingetSourceOpen, which opens the source as the installs
         do; its answer decides. 0x8A15000F SOURCE_DATA_MISSING (winget could not deploy its source
         package for this account, e.g. under cross-user elevation) gets
         Register-WingetSourcePackage, then Repair-WinGetPackageManager from Microsoft.WinGet.Client
         1.28.190 or later if installed; another SourceBroken code gets `winget source reset
         --force` (Invoke-NextWingetSourceFix); 0x80073D19 gets the account fixes not yet run. A
         source that still answers a SourceBroken code is one ERROR line
         (Get-WingetSourceUnusableMessage) and Ready $false: every install would fail. A timeout,
         a network error or another code gets no repair (P3-28): one line, and the run goes on.
    As SYSTEM, step 2 is Test-MachineWingetAvailable, and neither an account fix nor the source
    package registration runs. With
    -SystemInstallEngine WinGetClient a run as SYSTEM first readies Microsoft.WinGet.Client
    (Initialize-WingetClientEngine): ready, it installs the apps, winget.exe is only checked for
    Winget-AutoUpdate (a warning, not exit 2) and step 3 is skipped; not ready, the run goes on with
    winget.exe as without it. Either way it prints the 'Install engine: ' line.
.PARAMETER WhatIf
    Dry run (P2-16): only the policy and `winget --version` checks run. Nothing is registered,
    repaired, updated, opened or reset, and nothing is downloaded; [DRY-RUN] lines say what a real
    run would do.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, which Invoke-WingetInstall passes; read here when not given.
.PARAMETER SystemInstallEngine
    The engine a run as SYSTEM asked for (Get-SystemInstallEngineRequest): 'Cli' (default) or
    'WinGetClient'. Ignored in any other run.
.PARAMETER Tool
    The tool that runs, for the advice lines (Get-WingetToolAdviceText): 'Installer' (default) or
    'Uninstaller', which is never told to run the machine phase.
.OUTPUTS
    [pscustomobject] Ready ([bool]: winget starts, no policy blocks it and its source is not known
    to be unusable; a real run stops with exit code 2 when it is $false) and Diagnosis: 'Ok',
    'SourceFailed' (ready, but the source check gave no clear answer or failed for another reason,
    such as the network), 'SourceUnusable' (the source cannot be opened), 'PolicyBlocked' or
    'NotLaunchable'.
#>
function Initialize-Winget {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$SystemInstallEngine = 'Cli',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Installer', 'Uninstaller')]
        [string]$Tool = 'Installer'
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
        Write-WingetPolicyBlockMessage -Detail $Detail -WhatIf:$WhatIf
        [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }

    $policy = Get-WingetPolicyBlock
    if ($policy) {
        Write-WingetPolicyBlockMessage -Block $policy -WhatIf:$WhatIf
        return [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }

    if ($AccountContext.IsCrossUserElevation) {
        Write-WarningMessage "Cross-user elevation detected: running as '$account' while '$($AccountContext.SessionUser)' owns the interactive session."
        Write-WarningMessage "winget is set up per account; setting it up for '$account'."
    }

    if ($isSystem -and $SystemInstallEngine -eq 'WinGetClient' -and -not $WhatIf) {
        $engine = Initialize-WingetClientEngine
        # winget.exe still matters for Winget-AutoUpdate, but not for the installs once the module is
        # ready.
        $machineWingetOk = Test-MachineWingetAvailable -NotRequired:([bool]$engine.Ready)
        if ($engine.Ready) {
            if (-not $machineWingetOk) {
                Write-WarningMessage 'No machine-wide winget.exe starts on this PC. This run installs with Microsoft.WinGet.Client, but Winget-AutoUpdate runs winget.exe, so automatic updates will not work until App Installer is repaired; the end-of-run check reports it.'
            }
            Write-InstallEngineLine
            return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
        }
        if (-not $machineWingetOk) {
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        Write-InstallEngineLine
    }
    elseif ($isSystem) {
        if ($SystemInstallEngine -eq 'WinGetClient') {
            $modulePin = Get-WingetClientModulePin
            Write-Info "[DRY-RUN] A real run would install the apps with Microsoft.WinGet.Client $($modulePin.Version) (pinned), downloading it from the PowerShell Gallery unless it is cached, and would use winget.exe if it is not ready."
        }
        if (-not (Test-MachineWingetAvailable -WhatIf:$WhatIf)) {
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        if ($SystemInstallEngine -ne 'WinGetClient') {
            Write-InstallEngineLine
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
            Write-ErrorMessage ("Winget cannot be started for {0}: {1}.{2} {3}" -f $who, $probe.Reason, $seen, (Get-WingetSetupAdvice -State $state -Account $account -Tool $Tool))
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        Write-Success "Winget is available ($($probe.Version))."
    }

    if ($WhatIf) {
        $sourceFixes = 'winget source reset --force for a corrupted or unconfigured source (it also removes any source added beyond the defaults)'
        if (-not $isSystem) {
            $sourceFixes = 'for missing source data (0x8A15000F), registering the winget source package (Microsoft.Winget.Source) for this account, from a download from https://cdn.winget.microsoft.com/cache that must carry a valid Microsoft signature, else from the copy already on this PC, then Repair-WinGetPackageManager if Microsoft.WinGet.Client 1.28.190 or later is installed; ' + $sourceFixes
        }
        Write-Info "[DRY-RUN] Would update the winget source for $who (winget source update --name winget), check that winget can open it (winget search --source winget), and fix it if it cannot: $sourceFixes. A real run stops with exit code 2 when the source still cannot be opened."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    Write-Info "Updating the winget source for $who (this may take a moment)..."
    $source = Invoke-WingetSourceCheck
    while (-not $source.Succeeded) {
        $fixed = $false
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $source.ExitCode
        if ($source.ExitCode -eq $sessionBlockedExitCode -and -not $isSystem) {
            $fixed = Invoke-NextWingetAccountFix -State $state
        }
        elseif ($codeInfo -and $codeInfo.Class -eq 'SourceBroken') {
            $fixed = Invoke-NextWingetSourceFix -State $state -ExitCode $source.ExitCode -IsSystem:$isSystem
        }
        if (-not $fixed) {
            break
        }
        $source = Invoke-WingetSourceCheck
    }

    if ($source.Succeeded) {
        Write-Success "The winget source opens for $who."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }
    $sourceCommand = "'winget search --source winget'"
    if ($source.Step -eq 'update') {
        $sourceCommand = "'winget source update'"
    }
    if ($source.ExitCode -eq $policyExitCode) {
        return (& $policyBlocked ('{0} answered {1}' -f $sourceCommand, (Format-WingetExitCode -ExitCode $source.ExitCode)))
    }
    if ($source.ExitCode -eq $agreementsExitCode) {
        Write-Info 'The winget source agreements are not accepted for this account yet (0x8A150046); each install accepts them.'
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }
    # The installs open the source as the check does (--source winget), so each would fail the same way.
    $codeInfo = Get-WingetExitCodeInfo -ExitCode $source.ExitCode
    if ($codeInfo -and $codeInfo.Class -eq 'SourceBroken') {
        Write-ErrorMessage (Get-WingetSourceUnusableMessage -State $state -AccountContext $AccountContext -ExitCode $source.ExitCode -Tool $Tool)
        return [pscustomobject]@{ Ready = $false; Diagnosis = 'SourceUnusable' }
    }

    $detail = "$sourceCommand did not finish in time and was stopped"
    if ($source.LaunchError) {
        $detail = "winget could not be started: $($source.LaunchError)"
    }
    elseif (-not $source.TimedOut) {
        $detail = '{0} exited with {1}' -f $sourceCommand, (Format-WingetExitCode -ExitCode $source.ExitCode)
    }
    Write-WarningMessage ('The winget source could not be set up for {0} ({1}). {2} Installations may fail.' -f $who, $detail, (Get-WingetSetupAdvice -State $state -Account $account -Source -SourceExitCode $source.ExitCode -Tool $Tool))
    return [pscustomobject]@{ Ready = $true; Diagnosis = 'SourceFailed' }
}

<#
.SYNOPSIS
    Installs a single winget package, retrying the results that clear on their own: the 0x80073d19
    session error, another installation in progress, and an app or file in use.
.DESCRIPTION
    Runs `winget install` for one package through Invoke-WingetProcess and reads winget's exit code
    from the process. Retries, by the code's class (Get-WingetExitCodeInfo):
      - 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF, an account with no logon session,
        issue #159): with an increasing backoff, up to MaxAttempts; an immediate retry hits the
        same state.
      - 0x8A150102 (Windows Installer busy with another installation, msiexec 1618): waits until it
        is idle (Wait-WindowsInstallerIdle) and retries, up to InstallInProgressRetries, within
        InstallInProgressWaitSeconds (the run's remaining budget) (P2-15).
      - 0x8A150101, 0x8A150103 and 0x8A150111 (in use): one retry after InUseRetryDelaySeconds.
    0x8A15010A (restart required first) and every other result are final; the caller verifies with
    `winget list`. RestartRequired comes from Test-WingetRestartRequiredResult.

    Each install has a time limit (WingetInstall, P2-5): when it runs out winget and its installer
    are stopped and TimedOut is set; that is not retried. winget's output goes into the transcript
    as it arrives, and its --log to the logs folder (InstallerLogPath). -Silent passes --silent, so
    MSI and WiX packages install with /quiet instead of /passive.

    While the Microsoft.WinGet.Client engine is active (a run as SYSTEM that opted in), each attempt
    is Invoke-WingetClientInstall instead of `winget install`: the same exit codes, so the same
    retries, deferral and restart rules apply.

    A launch that fails with 1920 or 32 (winget.exe locked by an antivirus scan or an App Installer
    update, issues #253/#258) is retried with its own doubling backoff, MaxLaunchAttempts times (75
    seconds by default), and costs no install attempt. Any other launch failure ends at once with
    LaunchErrorExhausted, for the caller's circuit breaker.

    Installs prefer --scope machine (issue #159): at user scope a package lands in the elevating
    account's profile, and one with both MSIX and MSI resolves to the per-user MSIX that 0x80073D19
    blocks. A package with no machine-scope installer (0x8A150010) is retried once at winget's
    default scope, unless -MachineScopeOnly or -Scope machine forbid it (NoMachineScopeInstaller).
    -UserScopeOnly (the user phase) is --scope user only, never falling back: the default scope
    could pick a machine-wide installer that asks for administrator rights.
.PARAMETER PackageId
    The winget package id to install (e.g. 'Microsoft.PowerShell').
.PARAMETER InstallerType
    Optional `--installer-type <value>`. PowerShell needs 'wix': even with --scope machine winget
    picks the MSIX, whose machine-scope provisioning fails before build 26100 with 0x8A150113
    (issue #163).
.PARAMETER MaxAttempts
    Maximum number of install attempts while the session error keeps recurring. Default 3.
.PARAMETER InitialDelaySeconds
    Seconds to wait before the first retry; the wait doubles on each subsequent retry. Default 5.
.PARAMETER MaxLaunchAttempts
    Maximum number of launches while winget.exe stays locked (1920, 32). The wait starts at
    InitialDelaySeconds and doubles. Default 5 (75 seconds in all).
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
    Never fall back to winget's default scope (a run as SYSTEM or under cross-user elevation, where
    it would install into the wrong profile, P3-22). A package with no machine-scope installer ends
    at once with NoMachineScopeInstaller, and the caller defers it.
.PARAMETER Scope
    The catalog entry's scope (Get-AppInstallScope). 'any' (default): machine scope, then the
    fallback. 'machine': as -MachineScopeOnly. 'user': --scope user from the first attempt, no
    fallback; not with -MachineScopeOnly (Install-AppWithVerification defers such an app instead).
.PARAMETER UserScopeOnly
    Install with `--scope user` and nothing else (the user phase, Invoke-WingetUserPhase). A
    package with no per-user installer that applies (0x8A150010) ends at once with
    NoUserScopeInstaller, without a retry at another scope. Cannot be combined with
    -MachineScopeOnly or -Scope machine.
.PARAMETER TimeoutSeconds
    The time limit of each winget install, in seconds. Default (or 0): Get-ProcessTimeoutSeconds
    WingetInstall. The user phase passes what is left of its time budget.
.OUTPUTS
    [hashtable] @{ ExitCode = <int|$null>; Attempts = <int>; SessionErrorExhausted = <bool>; MachineScopeFellBack = <bool>; NoMachineScopeInstaller = <bool>; NoUserScopeInstaller = <bool>; LaunchErrorExhausted = <bool>; LaunchAttempts = <int>; LaunchError = <string|$null>; TimedOut = <bool>; TimeoutSeconds = <int>; InstallerLogPath = <string|$null>; InstallInProgressWaitedSeconds = <int>; RestartRequired = <bool>; InstallerErrorCode = <long|$null>; Engine = 'Cli' | 'WinGetClient' }
    SessionErrorExhausted: every attempt failed with the session error. MachineScopeFellBack: the
    install was retried at winget's default scope. NoMachineScopeInstaller / NoUserScopeInstaller:
    no installer for the only scope allowed (ExitCode 0x8A150010). Attempts counts installs at the
    final scope, busy and in-use retries included; neither the scope fallback nor a failed launch
    counts. LaunchErrorExhausted: winget.exe could not be launched (ExitCode $null, LaunchError the
    last error). TimedOut: the last attempt was stopped at its limit (ExitCode $null).
    InstallerLogPath: the last attempt's installer log, or $null. RestartRequired: the last result
    says a restart finishes the install; the caller decides from `winget list` whether it installed.
    InstallerErrorCode: the installer's own exit code, which only the WinGet client engine reports
    ($null otherwise). Engine: which engine ran the install.
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
        [switch]$MachineScopeOnly,

        [Parameter(Mandatory = $false)]
        [ValidateSet('any', 'machine', 'user')]
        [string]$Scope = 'any',

        [Parameter(Mandatory = $false)]
        [switch]$UserScopeOnly,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0
    )

    if ($Scope -eq 'user' -and $MachineScopeOnly) {
        throw [System.ArgumentException]::new("Install-WingetPackage: -Scope user installs $PackageId for the account running this, which -MachineScopeOnly rules out.")
    }
    if ($MachineScopeOnly -and $UserScopeOnly) {
        throw 'Install-WingetPackage: -MachineScopeOnly and -UserScopeOnly cannot be used together.'
    }
    if ($UserScopeOnly -and $Scope -eq 'machine') {
        throw [System.ArgumentException]::new("Install-WingetPackage: -UserScopeOnly installs $PackageId for the account running this only, which -Scope machine rules out.")
    }

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32, which is how winget
    # reports it through Process.ExitCode.
    $sessionLogoffExitCode = -2147009255
    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32: returned when
    # the --scope requirement filters out every installer in the package's manifest.
    $noApplicableInstallerExitCode = -1978335216

    $useSilent = [bool]$Silent
    if (-not $PSBoundParameters.ContainsKey('Silent')) {
        $useSilent = [bool](Test-EffectiveNonInteractive)
    }
    $timeoutSeconds = $TimeoutSeconds
    if ($timeoutSeconds -le 0) {
        $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetInstall
    }

    $attempt = 0
    $sessionErrors = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $installInProgressRetried = 0
    $installInProgressWaited = 0
    $inUseRetried = $false
    $restartRequired = $false
    $useMachineScope = $Scope -ne 'user'
    $machineScopeFellBack = $false
    $noMachineScopeInstaller = $false
    $noUserScopeInstaller = $false
    $launchErrorExhausted = $false
    $launchAttempt = 0
    $launchDelay = $InitialDelaySeconds
    $launchError = $null
    $timedOut = $false
    $installerLogPath = $null
    $installerErrorCode = $null
    $engine = 'Cli'
    if (Test-WingetClientEngineActive) {
        $engine = 'WinGetClient'
    }

    while ($true) {
        $attempt++
        $restartRequired = $false

        # The shared agreement and interactivity flags (Get-WingetAgreementArgs), so this call can
        # never miss --disable-interactivity again (issue #230).
        $installArgs = @(
            'install', '-e'
        ) + (Get-WingetAgreementArgs) + @(
            '--source', 'winget',
            '--id', $PackageId
        )
        if ($UserScopeOnly) {
            $installArgs += @('--scope', 'user')
        }
        elseif ($useMachineScope) {
            $installArgs += @('--scope', 'machine')
        }
        elseif ($Scope -eq 'user') {
            $installArgs += @('--scope', 'user')
        }
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $installArgs += @('--installer-type', $InstallerType)
        }
        if ($useSilent) {
            # Without --silent winget runs MSI and WiX installers with /passive (a progress window)
            # rather than /quiet.
            $installArgs += '--silent'
        }

        if ($engine -eq 'WinGetClient') {
            $clientScope = 'default'
            if ($UserScopeOnly -or $Scope -eq 'user') {
                $clientScope = 'user'
            }
            elseif ($useMachineScope) {
                $clientScope = 'machine'
            }
            $run = Invoke-WingetClientInstall -PackageId $PackageId -Scope $clientScope -InstallerType $InstallerType -Silent:$useSilent -TimeoutSeconds $timeoutSeconds
        }
        else {
            $run = Invoke-WingetProcess -ArgumentList $installArgs -TimeoutSeconds $timeoutSeconds
        }
        $installerErrorCode = $null
        if ($null -ne $run.InstallerErrorCode) {
            $installerErrorCode = [long]$run.InstallerErrorCode
        }
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
            # The engine's launch is its child pwsh, not winget.exe.
            $launchVerb = 'launch winget'
            if ($engine -eq 'WinGetClient') {
                $launchVerb = 'start the WinGet client engine'
            }
            if ($transient -and $launchAttempt -lt $MaxLaunchAttempts) {
                # The usual cause is the winget.exe app-execution alias breaking while the
                # DesktopAppInstaller package is upgraded or re-registered underneath us (e.g. by
                # a background Winget-AutoUpdate run), or an antivirus scan of winget.exe.
                Write-WarningMessage "Could not $launchVerb for $PackageId - its executable appears transiently locked ($($run.LaunchError)). Waiting ${launchDelay}s before launch retry $($launchAttempt + 1) of ${MaxLaunchAttempts}..."
                Start-Sleep -Seconds $launchDelay
                $launchDelay = $launchDelay * 2
                continue
            }

            if ($transient) {
                Write-WarningMessage "Still unable to $launchVerb for $PackageId after ${MaxLaunchAttempts} launch attempts ($($run.LaunchError))."
            }
            else {
                # Not a lock that clears on its own (e.g. winget missing, or 'Access is denied'):
                # retrying would only wait.
                Write-WarningMessage "Could not $launchVerb for ${PackageId}: $($run.LaunchError)"
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

        # No per-user installer applies (the user phase): never another scope, which could pick a
        # machine-wide installer that asks for administrator rights.
        if ($UserScopeOnly -and $exitCode -eq $noApplicableInstallerExitCode) {
            Write-Info "winget found no per-user installer for $PackageId that applies to this PC, so it is not installed for this account."
            $noUserScopeInstaller = $true
            break
        }

        # No machine-scope installer (an MSIX-only package such as Windows Terminal): fall back to
        # winget's default scope once. A manifest property, not a transient error, so no attempt
        # is spent.
        if (-not $UserScopeOnly -and $useMachineScope -and $exitCode -eq $noApplicableInstallerExitCode) {
            if ($MachineScopeOnly) {
                # A run as SYSTEM or under cross-user elevation (review finding P3-22): the default
                # scope would install the app for the account running this, not for the user.
                Write-Info "winget found no machine-scope installer for $PackageId that applies to this PC, and this run installs for the whole PC only, so it is not installed at winget's default (per-user) scope."
                $noMachineScopeInstaller = $true
                break
            }
            if ($Scope -eq 'machine') {
                # The catalog entry allows only a machine-wide install.
                Write-Info "winget found no machine-scope installer for $PackageId that applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine'), so it is not installed at winget's default (per-user) scope."
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

        # Success, restart-required-first (only a restart changes it) or another failure: final.
        # The caller verifies with `winget list`.
        $restartRequired = Test-WingetRestartRequiredResult -ExitCode $exitCode -Output $run.Output -InstallerErrorCode $installerErrorCode
        break
    }

    return @{
        ExitCode                       = $exitCode
        Attempts                       = $attempt
        SessionErrorExhausted          = ($exitCode -eq $sessionLogoffExitCode)
        MachineScopeFellBack           = $machineScopeFellBack
        NoMachineScopeInstaller        = $noMachineScopeInstaller
        NoUserScopeInstaller           = $noUserScopeInstaller
        LaunchErrorExhausted           = $launchErrorExhausted
        LaunchAttempts                 = $launchAttempt
        LaunchError                    = $(if ($launchErrorExhausted) { $launchError } else { $null })
        TimedOut                       = $timedOut
        TimeoutSeconds                 = $timeoutSeconds
        InstallerLogPath               = $installerLogPath
        InstallInProgressWaitedSeconds = $installInProgressWaited
        RestartRequired                = $restartRequired
        InstallerErrorCode             = $installerErrorCode
        Engine                         = $engine
    }
}

<#
.SYNOPSIS
    Returns whether winget reports the given package id as installed for the current account.
.DESCRIPTION
    `winget list --exact --id <id> --source winget` through Invoke-WingetProcess, quietly and always
    under a time limit (issues #176, #188). It tells installed, not installed and no answer apart:
    a timeout, a winget that could not start (P2-9) or a `winget list` that failed is no answer,
    never "not installed". `winget list` exits 0 when it lists the package and 0x8A150014 when
    nothing matches; any other code without a match is CheckFailed. --source winget, the source of
    every catalog id, makes a source that cannot be opened fail the list with its code (e.g.
    0x8A15000F): without it, winget only warns, matches nothing and exits 0x8A150014. A failed
    launch is not retried here; the caller's circuit breaker decides. The id is matched as a whole
    id (Test-WingetListOutputContainsPackageId), so 'Foo.Bar' does not match 'Foo.BarBaz'. While the
    Microsoft.WinGet.Client engine is active, Invoke-WingetClientInstalledCheck answers instead.
.PARAMETER PackageId
    The winget package id to check.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for `winget list` before killing it. Required: every caller passes the
    per-app check's limit (Get-ProcessTimeoutSeconds WingetListCheck) or its own.
.OUTPUTS
    [hashtable] @{ Installed = <bool>; TimedOut = <bool>; LaunchFailed = <bool>;
    LaunchError = <string or $null>; CheckFailed = <bool>; ExitCode = <int or $null> }.
    Installed is True only when winget answered and listed the id. TimedOut, LaunchFailed and
    CheckFailed mean there was no answer: winget ran out of time, could not be started (LaunchError
    says why), or ran and failed without listing the id (ExitCode says how). ExitCode is the winget
    process exit code, or $null when winget did not run to the end.
#>
function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if (Test-WingetClientEngineActive) {
        return (Invoke-WingetClientInstalledCheck -PackageId $PackageId -TimeoutSeconds $TimeoutSeconds)
    }

    $listArgs = @('list', '--exact', '--id', $PackageId, '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    $run = Invoke-WingetProcess -ArgumentList $listArgs -TimeoutSeconds $TimeoutSeconds -Echo None
    if ($run.LaunchFailed) {
        return @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = $run.LaunchError; CheckFailed = $false; ExitCode = $null }
    }

    if ($run.TimedOut) {
        return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    }

    # Standard output only: an error message can name the id too. Joined with a newline, so the
    # boundary match cannot join the end of one line to the start of the next.
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
    A mockable wrapper around Add-AppxProvisionedPackage. Under PowerShell 7 the Appx/DISM provider
    throws 0x80131539, so it runs in Windows PowerShell 5.1. A winget-source MSIX has no Store
    license, so -SkipLicense is used when no license file was downloaded. Returns True on success.
.PARAMETER PackagePath
    Full path to the .msixbundle/.msix to provision.
.PARAMETER DependencyPackagePath
    Full paths to dependency packages (e.g. Microsoft.WindowsAppRuntime, VCLibs).
.PARAMETER LicensePath
    Optional path to a downloaded license .xml.
.PARAMETER TimeoutSeconds
    Under pwsh: a time limit for the Windows PowerShell child, run through Invoke-ExternalProcess
    (output in the transcript, read in the console's code page so a localized DISM error keeps its
    letters) and stopped at the limit. The child starts without PSModulePath, so Windows PowerShell
    builds its own instead of inheriting PowerShell 7's module folders, which it cannot load.
    0 (the default): no limit.
#>
function Invoke-AppxProvisioning {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [string[]]$DependencyPackagePath = @(),

        [Parameter(Mandatory = $false)]
        [string]$LicensePath,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0
    )

    $hasLicense = $LicensePath -and (Test-Path $LicensePath)

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Run in Windows PowerShell 5.1, where the Appx/DISM provider works. Each path goes into a
            # single-quoted literal in the -Command string, so its quotes are doubled (issue #178): an
            # apostrophe (C:\Users\O'Brien) would otherwise break out of the literal in an elevated
            # powershell.exe.
            $escapedPackagePath = $PackagePath.Replace("'", "''")
            $depClause = if ($DependencyPackagePath.Count -gt 0) {
                $escapedDependencyPaths = @($DependencyPackagePath | ForEach-Object { $_.Replace("'", "''") })
                "-DependencyPackagePath @('" + ($escapedDependencyPaths -join "','") + "')"
            }
            else { '' }
            $licClause = if ($hasLicense) { "-LicensePath '$($LicensePath.Replace("'", "''"))'" } else { '-SkipLicense' }
            $command = "Add-AppxProvisionedPackage -Online -PackagePath '$escapedPackagePath' $depClause $licClause -ErrorAction Stop | Out-Null"
            if ($TimeoutSeconds -gt 0) {
                # No progress bar: redirected, Windows PowerShell writes it as CLIXML. Its redirected
                # output is in the console's code page, not UTF-8. No PSModulePath, as when
                # `& powershell.exe` starts it.
                $run = Invoke-ExternalProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`$ProgressPreference = 'SilentlyContinue'; $command") -TimeoutSeconds $TimeoutSeconds -Encoding ([Console]::OutputEncoding) -RemoveEnvironmentVariable @('PSModulePath')
                if ($run.LaunchFailed) {
                    Write-ErrorMessage "Add-AppxProvisionedPackage failed for '$PackagePath': Windows PowerShell could not be started ($($run.LaunchError))."
                    return $false
                }
                if ($run.TimedOut) {
                    Write-ErrorMessage ("Add-AppxProvisionedPackage did not finish within {0} minutes for '{1}' and was stopped." -f [Math]::Round($TimeoutSeconds / 60), $PackagePath)
                    return $false
                }
                return ($run.ExitCode -eq 0)
            }
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
    For an MSIX-only package (PowerShell 7.7+) on Windows before build 26100, where winget cannot
    provision an MSIX machine-wide because it calls the API from a packaged process: `winget
    download` fetches the MSIX, its dependencies and license, and Add-AppxProvisionedPackage
    provisions it for all users from a non-packaged process (issue #166). Dormant until PowerShell
    7.7; covered by unit tests only, so check it on a real Windows 10 PC before relying on it.
.PARAMETER PackageId
    The winget package id to provision (e.g. 'Microsoft.PowerShell').
.PARAMETER VerifyNameLike
    Wildcard matched against provisioned package names to confirm success. Defaults to *<last id
    segment>* (e.g. '*PowerShell*').
.OUTPUTS
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
    winget's default tracks the latest PowerShell; this only chooses how to deliver it machine-wide
    (issues #163, #166):
      1. The MSI while the current line ships one (7.6 and older): machine-wide on any build.
      2. Then the MSIX: installed directly on build 26100 and later; provisioned for all users via
         DISM (Install-MsixProvisionedPackage) before, where winget's machine-scope MSIX is broken.
    The result's Installed is authoritative: a DISM-provisioned PowerShell does not show in
    `winget list` for the elevating account, so the caller must not check again with winget.
.PARAMETER PackageId
    The winget package id. Default 'Microsoft.PowerShell'.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (--silent: the MSI installs with /quiet). Not given:
    Install-WingetPackage decides.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, for another installation, shared by the MSI and MSIX attempts (what
    is left of the run's budget). Not given: Install-WingetPackage's default.
.PARAMETER MachineScopeOnly
    Forwarded to Install-WingetPackage: as SYSTEM or under cross-user elevation PowerShell is never
    installed per user. An MSIX with no machine-scope installer gives NoMachineScopeInstaller, with
    no `winget list` check, and the caller defers it.
.OUTPUTS
    [hashtable] @{ ExitCode = <int>; Installed = <bool>; Method = 'msi' | 'msix-native' | 'msix-provisioned' }
    The winget paths (msi, msix-native) return Install-WingetPackage's whole result (P3-8) with
    Installed and Method added, and the `winget list` check's outcome: VerifyTimedOut,
    VerifyLaunchFailed, VerifyLaunchError, VerifyCheckFailed and VerifyExitCode. When winget could
    not be launched for the install (LaunchErrorExhausted), the check is skipped.
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

