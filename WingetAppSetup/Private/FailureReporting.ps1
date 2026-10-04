# Failure-reporting helpers (issue #189). Install-WingetPackage returns a rich diagnostic
# hashtable (ExitCode, Attempts, SessionErrorExhausted, MachineScopeFellBack) built precisely
# because the 0x80073D19-era failures were only diagnosable by hex exit code — but both
# Invoke-WingetInstall call sites used to discard it, reporting every failure as a generic
# "No package found matching input criteria." These helpers turn that result into the failure
# messages and the per-app Reason column of the failed-apps summary.

<#
.SYNOPSIS
    Ends the installer run with the given exit code, marking the exit as intended.
.DESCRIPTION
    Used by the generated entry script (build/fragments/tail.ps1) for every deliberate exit, so its
    abort guard can tell a run that chose its exit code from one stopped from outside: an outside
    stop (Ctrl+C, a console-stop event) unwinds through the entry script's finally block without
    this marker set, and is then reported as exit code 5 instead of 0. Like a bare `exit`, this ends
    the whole script (and, under irm | iex, the host process), so module functions never call it:
    Invoke-WingetInstall returns its exit code and the entry script exits with it.

    A failed run that has not shown its outcome yet - an early exit, such as a failed pre-flight
    check, another run in progress, winget missing, a declined elevation, a failed PowerShell 7
    bootstrap or an aborted run - first prints Write-InstallerExitNotice: the reason, the log path
    and the build id, then waits for a key press when someone is at the console (review finding
    P2-14). Under irm | iex the exit closes the window, which used to take the error and the log
    path with it before anyone could read them. Runs under Windows PowerShell 5.1 too (the bootstrap
    phase), so it stays 5.1-runtime compatible.

    Before that key press, Complete-InstallerRun prints the run's RESULT line, writes last-run.json
    and releases the run lock (review finding P3-41), so the RESULT line follows the notice, and a
    window left open at the prompt does not make the next run (an RMM schedule) exit 6.
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
    Review findings P2-14 and P3-15. A teammate who runs the irm | iex one-liner in an elevated
    console files a GitHub issue when a run fails. Every early exit used to print one red line and
    close the window at once, so the issue said only that the window closed. This prints, in one
    block: the exit code with the caller's reason (or what the code means), the log file path, the
    installer build id and where to report the failure, with a privacy note (the repository is
    public, and a transcript header names the computer and the accounts). Then it waits for a key
    press, unless the run is non-interactive (Test-EffectiveNonInteractive) or under CI
    (Test-IsContinuousIntegration), so an unattended or RMM run never blocks.

    Runs under Windows PowerShell 5.1 too (the bootstrap phase): 5.1-runtime compatible only.
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
            2 { $why = 'winget is not available or could not be started (see above)' }
            3 { $why = 'the app catalog failed validation (see above)' }
            4 { $why = 'administrator rights are required, and this run was not elevated (see above)' }
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
    Write-Info 'To report this, open https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml and give the exit code, the installer build and the log file.'
    Write-WarningMessage 'That repository is public, and the log names this computer and the accounts that ran the installer: remove or redact the log''s header before attaching it.'

    if ($NoPause) {
        return
    }
    Wait-InstallerExitKeyPress -NonInteractive:$NonInteractive
}

<#
.SYNOPSIS
    Waits for a key press before an early exit closes the window, when someone is at the console.
.DESCRIPTION
    Write-InstallerExitNotice's wait (review finding P2-14), on its own so Exit-Installer can report
    the run's outcome between the notice and the wait. Never waits in a non-interactive run
    (Test-EffectiveNonInteractive) or under CI (Test-IsContinuousIntegration). Runs under Windows
    PowerShell 5.1 too.
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
    Invoke-WingetInstall returns this as its exit code at the end of a run. The precedence is
    1 > 2 > 8 > 3010 > 0: failed apps first (1); then a winget that can no longer be launched at the
    end of the run (2, the same code as "winget unavailable" at the start), so a run can never exit 0
    while leaving winget broken; then apps installed, but automatic updates not configured or
    unhealthy (8, review finding P3-36: an RMM job used to report success for a machine that would
    never update); then a run that needs a restart to finish (3010, review finding P3-16: the code
    RMM tools and Intune read as "succeeded, restart required").
.PARAMETER FailedAppCount
    Number of apps still failed after the retry pass.
.PARAMETER WingetUsable
    Result of the end-of-run winget launch probe.
.PARAMETER AutoUpdatesHealthy
    False when the run's 'Auto-updates:' line is an error: Winget-AutoUpdate failed to install, was
    skipped because Microsoft.WindowsAppRuntime.1.8 is missing (NOT CONFIGURED), is installed
    without that framework (AT RISK), or is installed but its scheduled task will not run
    (UNHEALTHY). Default True.
.PARAMETER RestartRequired
    The run's installs finished but need a restart: an install reported it, or Windows gained a
    pending restart during the run. A restart that was already pending before the run does not
    count. Default False.
.RETURNS
    [int] 0, 1, 2, 8 or 3010.
#>
function Get-InstallerExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$FailedAppCount,

        [Parameter(Mandatory = $true)]
        [bool]$WingetUsable,

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
    Formats a one-line, human-readable reason for a failed app install.
.DESCRIPTION
    Combines the shared install pipeline's FailureReason bucket with the diagnostic detail the
    installer result carries: the winget exit code (hex, with its name from Get-WingetExitCodeInfo),
    the attempt count, whether the machine-scope preference fell back to winget's default scope,
    whether the 0x80073D19 session-error retries were exhausted (issue #189), how long the install
    waited for another installation to finish, whether the install ran out of time (review finding
    P2-5), and where the installer's log is (P2-6). Used both for the console failure message and
    for the Reason column in the failed-apps summary table.

    When the package is missing after an install that winget reported as failed (VerifyNotFound, or
    a package-specific installer's CustomInstallFailed), the reason starts with what the exit code
    means, for example 'another installation was in progress (Windows Installer was busy) - re-run
    the installer once it has finished', or 'winget install failed' for a code the table does not
    know (review finding P2-15). 'package not found after install' is kept for an install that
    winget reported as successful.
.PARAMETER FailureReason
    The FailureReason string from the shared install pipeline ('PreCheckTimeout',
    'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed', 'VerifyTimeout',
    'VerifyLaunchFailed', 'VerifyFailed', 'VerifyNotFound', 'CustomInstallFailed',
    'WingetNotLaunchable', 'MachineCheckFailed'). Unknown or empty values fall back to a generic
    'install failed'.
.PARAMETER InstallResult
    The InstallResult hashtable from the shared install pipeline: Install-WingetPackage's
    ExitCode/Attempts/SessionErrorExhausted/MachineScopeFellBack shape, a custom installer's
    ExitCode/Installed shape, or $null when no installer ran (timeouts, dry runs). Keys are probed
    individually, so partial shapes format whatever detail they carry.
.PARAMETER LaunchError
    Why winget could not be started, for the launch-failure reasons (the pipeline's LaunchError).
    Shown last, so the table row says what Windows reported (review finding P2-9).
.PARAMETER CheckExitCode
    The exit code of the `winget list` check that failed, for PreCheckFailed and VerifyFailed (the
    pipeline's CheckExitCode). Shown with the reason, apart from the install's own exit code.
.RETURNS
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
        [Nullable[int]]$CheckExitCode
    )

    $base = switch ($FailureReason) {
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
        }
    }

    $detailParts = @()
    if ($InstallResult) {
        if ($null -ne $installExitCode) {
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
            $detailParts += ('winget install stopped after {0}' -f $limit)
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
    Review finding P3-16. An app counts as installed when `winget list` finds it, whatever winget's
    exit code was, and the success line used to drop that code. This prints, after it:
      - '<app> has no machine-wide installer, so it was installed for this account only.' when the
        install fell back to winget's default scope (MachineScopeFellBack; review finding P3-22:
        that was shown only when the install failed);
      - '<app> needs a restart to finish installing (<why>).' when the result's RestartRequired is
        set (winget 0x8A150109 or 0x8A15010B, or winget's 'Restart your PC to finish installation.'
        warning; see Install-WingetPackage);
      - 'winget reported <code> for <app>, but it is installed.' for any other non-zero exit code,
        with the installer log when there is one, instead of dropping the code.
    Nothing for a plain success, or when there is no install result.
.PARAMETER AppName
    The winget package id.
.PARAMETER InstallResult
    The app's Install-AppWithVerification InstallResult, or $null.
.RETURNS
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

    if ($InstallResult.RestartRequired) {
        $why = "winget printed 'Restart your PC to finish installation.'"
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            $why = 'winget exit {0}' -f (Format-WingetExitCode -ExitCode $exitCode)
        }
        Write-WarningMessage ('{0} needs a restart to finish installing ({1}).' -f $AppName, $why)
        return $true
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $logNote = ''
        if ($InstallResult.InstallerLogPath) {
            $logNote = '; installer log: {0}' -f $InstallResult.InstallerLogPath
        }
        Write-WarningMessage ('winget reported {0} for {1}, but it is installed{2}.' -f (Format-WingetExitCode -ExitCode $exitCode), $AppName, $logNote)
    }
    return $false
}

<#
.SYNOPSIS
    Explains, under the installation summary, why apps were deferred and who can install them.
.DESCRIPTION
    Review findings P3-22, P3-23. A run as SYSTEM or under cross-user elevation installs for the whole
    PC only, so an app whose package has no machine-wide installer is not installed by it: it is
    reported as Deferred, neither installed nor failed, and does not change the exit code. This
    says so once, for all of them, with what can still install them. That is only the signed-in
    user's own account (named under cross-user elevation): this installer run as that user works
    only when the account is an administrator, since the installer needs administrator rights and
    a standard user's UAC prompt elevates as another account, which defers the app again; on a
    standard user's PC it takes a per-user deployment. The line does not claim a per-user installer
    exists: winget answers 0x8A150010 at --scope machine also when no installer applies to the PC
    at all. No-op when nothing was deferred.
.PARAMETER DeferredApps
    The package ids of the deferred apps.
.PARAMETER AccountContext
    Get-InstallAccountContext's result for the run.
#>
function Write-DeferredAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DeferredApps,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    if (-not $DeferredApps -or $DeferredApps.Count -eq 0) {
        return
    }

    $pronoun = 'them'
    if ($DeferredApps.Count -eq 1) {
        $pronoun = 'it'
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
    Write-WarningMessage ('Deferred: {0} - winget found no machine-wide installer for {1} that applies to this PC ({2} with --scope machine), and {3}. Not installed and not counted as failed. A per-user app can only be installed in {4}: by this installer run as {5} when that account is an administrator, otherwise by a per-user deployment (an RMM script that runs as the user, or the Microsoft Store).' -f ($DeferredApps -join ', '), $pronoun, (Format-WingetExitCode -ExitCode -1978335216), $why, $account, $who)
}

<#
.SYNOPSIS
    Renders the per-app failure-reason table shown under the installation summary.
.DESCRIPTION
    Prints one row per failed app with its Format-InstallFailureReason diagnostic (issue #189), so
    the summary — and the persistent transcript — carry the winget exit code and retry detail
    instead of just a list of failed names. No-ops when nothing failed. Kept separate from
    Invoke-WingetInstall so the rendering is unit-testable without driving the whole orchestrator.
.PARAMETER FailedApps
    Array of @{ Name = <winget package id>; Reason = <string> } hashtables tracked by
    Invoke-WingetInstall.
#>
function Write-FailedAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$FailedApps
    )

    if (-not $FailedApps -or $FailedApps.Count -eq 0) {
        return
    }

    $failedRows = @(foreach ($failedApp in $FailedApps) {
            , @([string]$failedApp.Name, [string]$failedApp.Reason)
        })
    Write-Table -Headers @('App', 'Reason') -Rows $failedRows -Title 'Failed Installations'
}
