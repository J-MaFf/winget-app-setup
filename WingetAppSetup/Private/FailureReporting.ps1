# Failure reporting: turns an install result (exit code, attempts, fallbacks) into the failure
# message and the Reason column of the failed-apps summary (issue #189), and decides the exit code.

<#
.SYNOPSIS
    Ends the installer run with the given exit code, marking the exit as intended.
.DESCRIPTION
    The entry script's every deliberate exit, so its abort guard can tell a chosen exit from a stop
    from outside (Ctrl+C, a console-stop event), which unwinds without the marker and exits 5. Like
    a bare `exit` it ends the whole script (and the host process under irm | iex), so module
    functions never call it.

    A failed run that has not shown its outcome yet first prints Write-InstallerExitNotice (reason,
    log path, build id), then Complete-InstallerRun reports the RESULT line and last-run.json and
    releases the run lock, and only then does it wait for a key press when someone is at the
    console (P2-14): under irm | iex the exit closes the window. Runs under Windows PowerShell 5.1
    too, so it stays 5.1-compatible.
.PARAMETER Code
    The process exit code. Default 0.
.PARAMETER Reason
    What stopped the run, when the caller knows more than the exit code says. Optional.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch: no key press is awaited.
.PARAMETER OutcomeShown
    The run already showed its outcome and waited for a key press (Invoke-WingetInstall's summary
    and final prompt, a PowerShell 7 run the bootstrap relaunched, or the elevated run of a run that
    relaunched itself elevated), so exit without the notice.
#>
function Exit-Installer {
    param (
        [Parameter(Mandatory = $false)]
        [int]$Code = 0,
        [Parameter(Mandatory = $false)]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$OutcomeShown
    )

    $noticeShown = $false
    if ($Code -ne 0 -and -not $OutcomeShown) {
        # Recorded before the key press: Ctrl+C there still ends the run with this code, through the
        # entry script's abort guard, instead of as an abort (5).
        $script:InstallerPendingExitCode = $Code
        try {
            Write-InstallerExitNotice -Code $Code -Reason $Reason -NonInteractive:$NonInteractive -NoPause
            $noticeShown = $true
        }
        catch {
            # The notice is a courtesy; nothing may keep the run from exiting with its code.
        }
    }
    try {
        Complete-InstallerRun -ExitCode $Code
    }
    catch {
        # Best-effort as well.
    }
    if ($noticeShown) {
        try {
            Wait-InstallerExitKeyPress -NonInteractive:$NonInteractive
        }
        catch {
        }
    }
    $script:InstallerExitRequested = $true
    exit $Code
}

<#
.SYNOPSIS
    Prints why the installer is stopping early, where its log is and which build ran, then waits for
    a key press when someone is at the console.
.DESCRIPTION
    What a teammate's issue report needs (P2-14, P3-15): the exit code with the reason (or what the
    code means), the log path, the build id, where to report it with the diagnostics bundle command
    (Write-InstallerReportHint) and a privacy note, since the repository is public. Never waits in a
    non-interactive run or under CI. Runs under Windows PowerShell 5.1 too.
.PARAMETER Code
    The exit code the run is about to end with.
.PARAMETER Reason
    What stopped the run, when the caller knows more than the exit code says. Optional.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch: no key press is awaited.
.PARAMETER NoPause
    Print the notice without waiting for a key press (the console stays open anyway).
#>
function Write-InstallerExitNotice {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Code,
        [Parameter(Mandatory = $false)]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$NoPause
    )

    # What the code means for a run that stopped early. Without a reason from the caller, this is
    # the line under the specific error the run printed just above.
    $why = $Reason
    if (-not $why) {
        switch ($Code) {
            1 { $why = 'a pre-flight check failed (see above)' }
            2 { $why = 'winget is not available, could not be started, or is turned off by Group Policy (see above)' }
            3 { $why = 'the app catalog failed validation (see above)' }
            4 { $why = 'administrator rights are required, and this run was not elevated, or Group Policy''s execution policy keeps the elevated window from running the installer (see above)' }
            5 { $why = 'the run was aborted before it finished (see above)' }
            6 { $why = 'another run of the installer is in progress on this PC' }
            7 { $why = 'PowerShell 7 could not be installed, or the installer could not be relaunched under it (see above)' }
        }
    }

    Write-Host ''
    if ($why) {
        Write-ErrorMessage ('The installer stopped early with exit code {0}: {1}.' -f $Code, $why)
    }
    else {
        Write-ErrorMessage ('The installer stopped early with exit code {0}.' -f $Code)
    }
    if ($script:InstallLogPath) {
        Write-Info "Log file: $script:InstallLogPath"
    }
    else {
        Write-WarningMessage 'Log file: none - the transcript could not be started (see the warning at the start of the run).'
    }
    if ($script:InstallerBuildId) {
        Write-Info "Installer build: $script:InstallerBuildId"
    }
    Write-InstallerReportHint

    if ($NoPause) {
        return
    }
    Wait-InstallerExitKeyPress -NonInteractive:$NonInteractive
}

<#
.SYNOPSIS
    Waits for a key press before an early exit closes the window, when someone is at the console.
.DESCRIPTION
    Write-InstallerExitNotice's wait, on its own so Exit-Installer can report the run between the
    notice and the wait. Never waits in a non-interactive run or under CI. Runs under 5.1 too.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch.
#>
function Wait-InstallerExitKeyPress {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ((Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) -or (Test-IsContinuousIntegration)) {
        return
    }
    Write-Prompt 'Press any key to exit...'
    try {
        [void][System.Console]::ReadKey($true)
    }
    catch {
        # No console to read a key from after all: nothing to wait for.
    }
}

<#
.SYNOPSIS
    Decides Invoke-WingetInstall's final exit code from the run's outcome.
.DESCRIPTION
    Precedence 1 > 2 > 9 > 8 > 3010 > 0: failed apps (1); winget no longer launchable at the end (2,
    as at the start), so a run never exits 0 leaving winget broken; apps or steps not attempted
    because the run's time budget was used up (9: run it again to finish; wgt-gq8.41); apps
    installed but automatic updates not configured or unhealthy (8, P3-36); a restart needed to
    finish (3010, which RMM tools read as "succeeded, restart required", P3-16). A restart still
    shows in the run record when another code wins.
.PARAMETER FailedAppCount
    Number of apps still failed after the retry pass.
.PARAMETER WingetUsable
    Result of the end-of-run winget launch probe.
.PARAMETER WorkNotAttempted
    The time budget was used up before an app install or the Winget-AutoUpdate setup could start.
    Default False.
.PARAMETER AutoUpdatesHealthy
    False when the run's 'Auto-updates:' line is FAILED, NOT CONFIGURED, AT RISK or UNHEALTHY.
    Default True.
.PARAMETER RestartRequired
    The run's installs finished but need a restart: an install reported it, or Windows gained a
    pending restart during the run (one pending before does not count). Default False.
.OUTPUTS
    [int] 0, 1, 2, 8, 9 or 3010.
#>
function Get-InstallerExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$FailedAppCount,

        [Parameter(Mandatory = $true)]
        [bool]$WingetUsable,

        [Parameter(Mandatory = $false)]
        [bool]$WorkNotAttempted = $false,

        [Parameter(Mandatory = $false)]
        [bool]$AutoUpdatesHealthy = $true,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false
    )

    if ($FailedAppCount -gt 0) {
        return 1
    }
    if (-not $WingetUsable) {
        return 2
    }
    if ($WorkNotAttempted) {
        return 9
    }
    if (-not $AutoUpdatesHealthy) {
        return 8
    }
    if ($RestartRequired) {
        return 3010
    }
    return 0
}

<#
.SYNOPSIS
    Formats a one-line reason for a failed app install, for the failure message and the summary's
    Reason column.
.DESCRIPTION
    The pipeline's FailureReason plus what the install result carries: the winget exit code with
    its name, the attempts, whether machine scope fell back, whether the 0x80073D19 retries ran out,
    how long it waited for another installation, whether it timed out, and the installer log.

    When the package is missing after an install winget reported as failed (VerifyNotFound,
    CustomInstallFailed), the reason starts with what the exit code means, e.g. 'another
    installation was in progress (Windows Installer was busy) - re-run the installer once it has
    finished', or 'winget install failed' for an unknown code (P2-15). A PostInstallFailed app is
    installed: 'installed, but its post-install configuration failed (<reason>)'.
.PARAMETER FailureReason
    The FailureReason string from the shared install pipeline ('PreCheckTimeout',
    'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed', 'VerifyTimeout',
    'VerifyLaunchFailed', 'VerifyFailed', 'VerifyNotFound', 'CustomInstallFailed',
    'WingetNotLaunchable', 'MachineCheckFailed', 'NoMachineScopeInstaller', 'PostInstallFailed', and
    the user phase's 'NoUserScopeInstaller'). Unknown or empty values fall back to a generic 'install
    failed'.
.PARAMETER InstallResult
    The pipeline's InstallResult (Install-WingetPackage's or a custom installer's), or $null when no
    installer ran. Keys are read one by one, so a partial result shows what it carries.
.PARAMETER LaunchError
    Why winget could not be started, shown last for the launch-failure reasons (P2-9).
.PARAMETER CheckExitCode
    The exit code of the `winget list` check that failed, for PreCheckFailed and VerifyFailed.
.PARAMETER PostInstallReason
    Why the post-install hook failed, for PostInstallFailed (the pipeline's Configuration.Reason).
.PARAMETER InstallEngine
    'Cli' or 'WinGetClient': which engine the texts name. Default: InstallResult.Engine, else
    WinGetClient while that engine is active (Test-WingetClientEngineActive), else Cli. With
    WinGetClient the code reads 'WinGet client result ...', followed by the installer's own exit
    code when it is not 0.
.OUTPUTS
    [string] e.g. 'another installation was in progress (Windows Installer was busy) - re-run the
    installer once it has finished; winget exit 0x8A150102 INSTALL_INSTALL_IN_PROGRESS, 4 attempts,
    machine-scope fallback: no, waited 600 seconds for another installation'. Never $null or empty.
#>
function Format-InstallFailureReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FailureReason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$InstallResult,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LaunchError,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$CheckExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PostInstallReason,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$InstallEngine
    )

    if ($FailureReason -eq 'PostInstallFailed') {
        # The app is installed: the install's details would describe a success.
        $hookReason = 'no reason given'
        if (-not [string]::IsNullOrWhiteSpace($PostInstallReason)) {
            $hookReason = $PostInstallReason.Trim()
        }
        return ('installed, but its post-install configuration failed ({0})' -f $hookReason)
    }

    if (-not $InstallEngine) {
        $InstallEngine = 'Cli'
        if ($InstallResult -and $InstallResult.ContainsKey('Engine') -and $InstallResult.Engine -eq 'WinGetClient') {
            $InstallEngine = 'WinGetClient'
        }
        elseif (-not ($InstallResult -and $InstallResult.ContainsKey('Engine')) -and (Test-WingetClientEngineActive)) {
            $InstallEngine = 'WinGetClient'
        }
    }
    $clientEngine = $InstallEngine -eq 'WinGetClient'

    $base = switch ($FailureReason) {
        { $clientEngine -and $_ -eq 'PreCheckTimeout' } { 'Get-WinGetPackage timed out during the pre-install check'; break }
        { $clientEngine -and $_ -eq 'PreCheckLaunchFailed' } { 'the WinGet client engine could not be started for the pre-install check'; break }
        { $clientEngine -and $_ -eq 'PreCheckFailed' } { 'Get-WinGetPackage failed during the pre-install check'; break }
        { $clientEngine -and $_ -eq 'InstallLaunchFailed' } { 'the WinGet client engine could not be started to install it'; break }
        { $clientEngine -and $_ -eq 'VerifyLaunchFailed' } { 'the WinGet client engine could not be started to verify the install'; break }
        { $clientEngine -and $_ -eq 'VerifyFailed' } { 'Get-WinGetPackage failed during the post-install check'; break }
        { $clientEngine -and $_ -eq 'WingetNotLaunchable' } { 'not attempted: the WinGet client engine cannot be started on this machine (see above)'; break }
        'PreCheckTimeout' { 'winget list timed out during the pre-install check' }
        'PreCheckLaunchFailed' { 'winget could not be launched for the pre-install check' }
        'PreCheckFailed' { 'winget list failed during the pre-install check' }
        'InstallLaunchFailed' { 'winget could not be launched to install it' }
        'VerifyTimeout' { 'post-install verification timed out' }
        'VerifyLaunchFailed' { 'winget could not be launched to verify the install' }
        'VerifyFailed' { 'winget list failed during the post-install check' }
        'VerifyNotFound' { 'package not found after install' }
        'CustomInstallFailed' { 'installer reported failure' }
        'WingetNotLaunchable' { 'not attempted: winget cannot be launched on this machine (see above)' }
        'MachineCheckFailed' { 'could not check whether it is provisioned for every user on this PC (see the warning above)' }
        'NoMachineScopeInstaller' { "no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine')" }
        'NoUserScopeInstaller' { 'winget found no per-user installer for it that applies to this PC (0x8A150010 NO_APPLICABLE_INSTALLER with --scope user)' }
        default { 'install failed' }
    }
    if ($null -ne $CheckExitCode -and @('PreCheckFailed', 'VerifyFailed') -contains $FailureReason) {
        # The list's own exit code (review finding P2-9), kept apart from the install's 'winget exit'.
        $base = '{0} with exit {1}' -f $base, (Format-WingetExitCode -ExitCode $CheckExitCode)
    }

    $installExitCode = $null
    if ($InstallResult -and $InstallResult.ContainsKey('ExitCode') -and $null -ne $InstallResult.ExitCode) {
        $installExitCode = [int]$InstallResult.ExitCode
    }
    if ($null -ne $installExitCode -and $installExitCode -ne 0 -and @('VerifyNotFound', 'CustomInstallFailed') -contains $FailureReason) {
        # winget said the install failed, and the package is indeed missing: what winget's code
        # means is the reason, not 'package not found after install' (review finding P2-15).
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $installExitCode
        if ($codeInfo) {
            $base = $codeInfo.Meaning
        }
        elseif ($FailureReason -eq 'VerifyNotFound') {
            $base = 'winget install failed'
            if ($clientEngine) {
                $base = 'Install-WinGetPackage failed'
            }
        }
    }

    $detailParts = @()
    if ($InstallResult) {
        if ($null -ne $installExitCode -and $clientEngine) {
            $detailParts += ('WinGet client result {0}' -f (Format-WingetExitCode -ExitCode $installExitCode))
            if ($InstallResult.ContainsKey('InstallerErrorCode') -and $null -ne $InstallResult.InstallerErrorCode -and [long]$InstallResult.InstallerErrorCode -ne 0) {
                $detailParts += ('installer exit code {0}' -f $InstallResult.InstallerErrorCode)
            }
        }
        elseif ($null -ne $installExitCode) {
            $detailParts += ('winget exit {0}' -f (Format-WingetExitCode -ExitCode $installExitCode))
        }
        if ($InstallResult.ContainsKey('Attempts') -and $InstallResult.Attempts) {
            $attemptWord = if ([int]$InstallResult.Attempts -eq 1) { 'attempt' } else { 'attempts' }
            $detailParts += ('{0} {1}' -f $InstallResult.Attempts, $attemptWord)
        }
        if ($InstallResult.ContainsKey('MachineScopeFellBack')) {
            $detailParts += ('machine-scope fallback: {0}' -f $(if ($InstallResult.MachineScopeFellBack) { 'yes' } else { 'no' }))
        }
        if ($InstallResult.ContainsKey('SessionErrorExhausted') -and $InstallResult.SessionErrorExhausted) {
            $detailParts += 'session error 0x80073D19 persisted through every retry'
        }
        if ($InstallResult.ContainsKey('InstallInProgressWaitedSeconds') -and $InstallResult.InstallInProgressWaitedSeconds) {
            $detailParts += ('waited {0} seconds for another installation' -f [int]$InstallResult.InstallInProgressWaitedSeconds)
        }
        if ($InstallResult.ContainsKey('LaunchErrorExhausted') -and $InstallResult.LaunchErrorExhausted) {
            # issue #253: winget.exe could not be launched, so no install ever actually ran (the
            # 'InstallLaunchFailed' reason says so); this counts the launches that failed.
            $launchAttempts = 0
            if ($InstallResult.ContainsKey('LaunchAttempts') -and $InstallResult.LaunchAttempts) {
                $launchAttempts = [int]$InstallResult.LaunchAttempts
            }
            if ($launchAttempts -gt 0) {
                $launchWord = if ($launchAttempts -eq 1) { 'failed launch' } else { 'failed launches' }
                $detailParts += ('{0} {1}' -f $launchAttempts, $launchWord)
            }
        }
        if ($InstallResult.ContainsKey('TimedOut') -and $InstallResult.TimedOut) {
            # Review finding P2-5: the install ran out of time and was stopped, so there is no exit
            # code to show.
            $limit = 'its time limit'
            if ($InstallResult.ContainsKey('TimeoutSeconds') -and $InstallResult.TimeoutSeconds) {
                $limit = '{0} minutes' -f [Math]::Round([int]$InstallResult.TimeoutSeconds / 60)
            }
            $stoppedWhat = 'winget install'
            if ($clientEngine) {
                $stoppedWhat = 'the WinGet client install'
            }
            $detailParts += ('{0} stopped after {1}' -f $stoppedWhat, $limit)
        }
        if ($InstallResult.ContainsKey('InstallerLogPath') -and $InstallResult.InstallerLogPath) {
            # Review finding P2-6: the installer's own log, next to the transcript.
            $detailParts += ('installer log: {0}' -f $InstallResult.InstallerLogPath)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($LaunchError)) {
        $detailParts += ('launch error: {0}' -f $LaunchError.Trim().TrimEnd('.'))
    }

    if ($detailParts.Count -gt 0) {
        return ('{0}; {1}' -f $base, ($detailParts -join ', '))
    }
    return $base
}

<#
.SYNOPSIS
    Prints what an installed app's install result adds to 'Successfully installed', and returns
    whether the install needs a restart to finish.
.DESCRIPTION
    An app counts as installed when `winget list` finds it, whatever winget's exit code (P3-16), so
    after the success line this prints:
      - '<app> has no machine-wide installer, so it was installed for this account only.' after a
        fallback to winget's default scope (MachineScopeFellBack);
      - '<app> needs a restart to finish installing (<why>).' when RestartRequired is set;
      - 'winget reported <code> for <app>, but it is installed.' for another non-zero exit code,
        with the installer log when there is one.
    Nothing for a plain success, or when there is no install result. With Engine 'WinGetClient'
    the texts name Install-WinGetPackage's result, and a restart on success names the installer's
    own exit code (3010), since the module prints no restart warning.
.PARAMETER AppName
    The winget package id.
.PARAMETER InstallResult
    The app's Install-AppWithVerification InstallResult, or $null.
.OUTPUTS
    [bool] True when the install needs a restart to finish.
#>
function Write-InstalledAppNote {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult
    )

    if ($null -eq $InstallResult) {
        return $false
    }
    $exitCode = $null
    if ($null -ne $InstallResult.ExitCode) {
        $exitCode = [int]$InstallResult.ExitCode
    }

    if ($InstallResult.MachineScopeFellBack) {
        Write-Info ('{0} has no machine-wide installer, so it was installed for this account only.' -f $AppName)
    }

    # Microsoft.WinGet.Client prints no restart warning: its restart is the installer's own exit code.
    $clientEngine = $InstallResult.Engine -eq 'WinGetClient'
    if ($InstallResult.RestartRequired) {
        $why = "winget printed 'Restart your PC to finish installation.'"
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            $why = 'winget exit {0}' -f (Format-WingetExitCode -ExitCode $exitCode)
            if ($clientEngine) {
                $why = 'WinGet client result {0}' -f (Format-WingetExitCode -ExitCode $exitCode)
            }
        }
        elseif ($clientEngine -and $null -ne $InstallResult.InstallerErrorCode) {
            $why = 'the installer exited {0}' -f $InstallResult.InstallerErrorCode
            if ([long]$InstallResult.InstallerErrorCode -eq 3010) {
                $why += ', ERROR_SUCCESS_REBOOT_REQUIRED'
            }
        }
        Write-WarningMessage ('{0} needs a restart to finish installing ({1}).' -f $AppName, $why)
        return $true
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $logNote = ''
        if ($InstallResult.InstallerLogPath) {
            $logNote = '; installer log: {0}' -f $InstallResult.InstallerLogPath
        }
        $reporter = 'winget'
        if ($clientEngine) {
            $reporter = 'Install-WinGetPackage'
        }
        Write-WarningMessage ('{0} reported {1} for {2}, but it is installed{3}.' -f $reporter, (Format-WingetExitCode -ExitCode $exitCode), $AppName, $logNote)
    }
    return $false
}

<#
.SYNOPSIS
    Words why an app was deferred, for its 'Deferred: <id> (...)' line and its run record:
    'UserScope' (catalog scope 'user'), 'UserPhase' (catalog userPhase), or otherwise 'winget found
    no machine-wide installer for it'.
.PARAMETER DeferReason
    Install-AppWithVerification's DeferReason.
.OUTPUTS
    [string]
#>
function Get-AppDeferReasonText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DeferReason
    )

    switch ($DeferReason) {
        'UserScope' { return "per-user app (catalog scope 'user'): it installs only into the signed-in user's own account" }
        'UserPhase' { return "per-user setup (catalog userPhase): it needs the signed-in user's own account" }
    }
    return 'winget found no machine-wide installer for it'
}

<#
.SYNOPSIS
    Explains, under the installation summary, why apps were deferred and who can install them.
.DESCRIPTION
    A run as SYSTEM or under cross-user elevation installs for the whole PC only, so an app with no
    machine-wide installer is Deferred: neither installed nor failed, exit code unchanged (P3-22,
    P3-23). This says so once, and that only the signed-in user's own account can install them:
    this installer run as that user works only for an administrator (a standard user's UAC prompt
    elevates as another account), otherwise the user phase does it (Invoke-WingetUserPhase). It does
    not claim a per-user installer exists: winget answers 0x8A150010 also when no installer applies.
    Apps the catalog marks per-user get a line of their own. No-op when nothing was deferred.
.PARAMETER DeferredApps
    The package ids of the apps deferred because winget found no machine-wide installer for them.
.PARAMETER PerUserApps
    The package ids of the apps deferred because the catalog marks them per-user.
.PARAMETER AccountContext
    Get-InstallAccountContext's result for the run.
.PARAMETER InstallEngine
    The engine that installed the apps: 'Cli' (default; '... with --scope machine') or
    'WinGetClient' ('... with -Scope System').
#>
function Write-DeferredAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DeferredApps,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PerUserApps,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$InstallEngine = 'Cli'
    )

    $noInstallerApps = @($DeferredApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $perUserAppIds = @($PerUserApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($noInstallerApps.Count -eq 0 -and $perUserAppIds.Count -eq 0) {
        return
    }

    $why = 'this run installs for the whole PC only'
    $account = "the signed-in user's own account"
    $who = 'the signed-in user'
    if ($AccountContext -and $AccountContext.IsSystem) {
        $why = 'a run as SYSTEM installs for the whole PC only'
    }
    elseif ($AccountContext -and $AccountContext.IsCrossUserElevation) {
        $why = "installing per-user here would install for '$($AccountContext.ProcessUser)' instead of '$($AccountContext.SessionUser)'"
        $account = "the account '$($AccountContext.SessionUser)'"
        $who = "'$($AccountContext.SessionUser)'"
    }
    if ($noInstallerApps.Count -gt 0) {
        $pronoun = 'them'
        if ($noInstallerApps.Count -eq 1) {
            $pronoun = 'it'
        }
        $scopeOption = '--scope machine'
        if ($InstallEngine -eq 'WinGetClient') {
            $scopeOption = '-Scope System'
        }
        Write-WarningMessage ('Deferred: {0} - winget found no machine-wide installer for {1} that applies to this PC ({2} with {6}), and {3}. Not installed and not counted as failed. A per-user app can only be installed in {4}: by this installer run as {5} when that account is an administrator, otherwise by a per-user deployment: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs the apps a run deferred, or the Microsoft Store.' -f ($noInstallerApps -join ', '), $pronoun, (Format-WingetExitCode -ExitCode -1978335216), $why, $account, $who, $scopeOption)
    }
    if ($perUserAppIds.Count -gt 0) {
        $subject = 'they'
        $object = 'them'
        if ($perUserAppIds.Count -eq 1) {
            $subject = 'it'
            $object = 'it'
        }
        Write-WarningMessage ("Deferred: {0} - the catalog marks {1} per-user (scope 'user' or userPhase), so {2} can be installed or set up only in {3}, and {4}. Not installed and not counted as failed. This installer run as {5} installs {1} when that account is an administrator; otherwise a per-user deployment does: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs and sets up the apps a run deferred, or the Microsoft Store." -f ($perUserAppIds -join ', '), $object, $subject, $account, $why, $who)
    }
}

<#
.SYNOPSIS
    Prints an installed app's post-install configuration result after its install line.
.DESCRIPTION
    'Configured: <id>', or 'Not configured: <id> (<reason>)', which leaves the app installed and the
    exit code as it was. Nothing for a failed hook (the failure line says why) or when none ran.
.PARAMETER AppName
    The winget package id.
.PARAMETER Configuration
    The app's Install-AppWithVerification Configuration, or $null.
.OUTPUTS
    [bool] True when the app is installed but not configured (NotConfigured), for the summary's
    'Configuration: NOT DONE' line (Write-NotConfiguredAppsSummary).
#>
function Write-AppPostInstallResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Configuration
    )

    if ($null -eq $Configuration) {
        return $false
    }
    switch ([string]$Configuration.Status) {
        'Configured' {
            Write-Success "Configured: $AppName"
        }
        'NotConfigured' {
            Write-WarningMessage "Not configured: $AppName ($($Configuration.Reason))"
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Says, under the installation summary, which installed apps are not configured, and why:
    'Configuration: NOT DONE for <id> (<reason>); ... - ...'. No-op when every hook configured its app.
.PARAMETER NotConfiguredApps
    @{ Name = <winget package id>; Reason = <string> } for each app.
#>
function Write-NotConfiguredAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$NotConfiguredApps
    )

    if (-not $NotConfiguredApps -or $NotConfiguredApps.Count -eq 0) {
        return
    }
    $entries = @($NotConfiguredApps | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Reason })
    Write-WarningMessage ('Configuration: NOT DONE for {0} - installed, but the post-install configuration did not finish. Not counted as failed; re-run the installer once the reason is fixed.' -f ($entries -join '; '))
}

<#
.SYNOPSIS
    Prints the failure-reason table under the installation summary: one row per failed app with its
    Format-InstallFailureReason text. No-op when nothing failed.
.PARAMETER FailedApps
    Array of @{ Name = <winget package id>; Reason = <string> } hashtables tracked by
    Invoke-WingetInstall (or Invoke-WingetUninstall).
.PARAMETER Title
    The table's title. Default 'Failed Installations'; the uninstaller passes 'Failed Uninstalls'.
#>
function Write-FailedAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$FailedApps,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'Failed Installations'
    )

    if (-not $FailedApps -or $FailedApps.Count -eq 0) {
        return
    }

    $failedRows = @(foreach ($failedApp in $FailedApps) {
            , @([string]$failedApp.Name, [string]$failedApp.Reason)
        })
    Write-Table -Headers @('App', 'Reason') -Rows $failedRows -Title $Title
}
