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
    check, winget missing, a declined elevation, a failed PowerShell 7 bootstrap or an aborted run -
    first prints Write-InstallerExitNotice: the reason, the log path and the build id, then waits
    for a key press when someone is at the console (review finding P2-14). Under irm | iex the exit
    closes the window, which used to take the error and the log path with it before anyone could
    read them. Runs under Windows PowerShell 5.1 too (the bootstrap phase), so it stays
    5.1-runtime compatible.
.PARAMETER Code
    The process exit code. Default 0.
.PARAMETER Reason
    What stopped the run, when the caller knows more than the exit code says. Optional.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch: no key press is awaited.
.PARAMETER OutcomeShown
    The run already showed its outcome and waited for a key press (Invoke-WingetInstall's summary
    and final prompt, or a PowerShell 7 run the bootstrap relaunched), so exit without the notice.
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

    if ($Code -ne 0 -and -not $OutcomeShown) {
        # Recorded before the key press: Ctrl+C there still ends the run with this code, through the
        # entry script's abort guard, instead of as an abort (5).
        $script:InstallerPendingExitCode = $Code
        try {
            Write-InstallerExitNotice -Code $Code -Reason $Reason -NonInteractive:$NonInteractive
        }
        catch {
            # The notice is a courtesy; nothing may keep the run from exiting with its code.
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
            1 { $why = 'administrator rights were not available or a pre-flight check failed (see above)' }
            2 { $why = 'winget is not available or could not be started (see above)' }
            3 { $why = 'the app catalog failed validation (see above)' }
            5 { $why = 'the run was aborted before it finished (see above)' }
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
    Invoke-WingetInstall returns this as its exit code at the end of a run. Failed apps take
    precedence (1); otherwise a winget that can no longer be launched at the end of the run is
    reported as 2 - the same code as "winget unavailable" at the start - so a run can never exit 0
    while leaving winget broken.
.PARAMETER FailedAppCount
    Number of apps still failed after the retry pass.
.PARAMETER WingetUsable
    Result of the end-of-run winget launch probe.
.RETURNS
    [int] 0, 1 or 2.
#>
function Get-InstallerExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$FailedAppCount,

        [Parameter(Mandatory = $true)]
        [bool]$WingetUsable
    )

    if ($FailedAppCount -gt 0) {
        return 1
    }
    if (-not $WingetUsable) {
        return 2
    }
    return 0
}

<#
.SYNOPSIS
    Formats a one-line, human-readable reason for a failed app install.
.DESCRIPTION
    Combines the shared install pipeline's FailureReason bucket with the diagnostic detail the
    installer result carries: the winget exit code (hex), the attempt count, whether the
    machine-scope preference fell back to winget's default scope, whether the 0x80073D19
    session-error retries were exhausted (issue #189), whether the install ran out of time (review
    finding P2-5), and where the installer's log is (P2-6). Used both for the console failure message
    and for the Reason column in the failed-apps summary table.
.PARAMETER FailureReason
    The FailureReason string from the shared install pipeline ('PreCheckTimeout', 'VerifyTimeout',
    'VerifyNotFound', 'CustomInstallFailed'). Unknown or empty values fall back to a generic
    'install failed'.
.PARAMETER InstallResult
    The InstallResult hashtable from the shared install pipeline: Install-WingetPackage's
    ExitCode/Attempts/SessionErrorExhausted/MachineScopeFellBack shape, a custom installer's
    ExitCode/Installed shape, or $null when no installer ran (timeouts, dry runs). Keys are probed
    individually, so partial shapes format whatever detail they carry.
.RETURNS
    [string] e.g. 'package not found after install; winget exit 0x80073D19, 3 attempts,
    machine-scope fallback: no'. Never $null or empty.
#>
function Format-InstallFailureReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FailureReason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$InstallResult
    )

    $base = switch ($FailureReason) {
        'PreCheckTimeout' { 'winget list timed out during the pre-install check' }
        'VerifyTimeout' { 'post-install verification timed out' }
        'VerifyNotFound' { 'package not found after install' }
        'CustomInstallFailed' { 'installer reported failure' }
        default { 'install failed' }
    }

    $detailParts = @()
    if ($InstallResult) {
        if ($InstallResult.ContainsKey('ExitCode') -and $null -ne $InstallResult.ExitCode) {
            # Winget reports HRESULT-style codes as signed Int32 (e.g. -2147009255); the X8 format
            # renders the familiar hex form (0x80073D19) the winget docs and issues use.
            $detailParts += ('winget exit 0x{0:X8}' -f [int]$InstallResult.ExitCode)
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
        if ($InstallResult.ContainsKey('LaunchErrorExhausted') -and $InstallResult.LaunchErrorExhausted) {
            # issue #253: winget.exe could not be launched (transient file lock) on every attempt,
            # so no install ever actually ran.
            $detailParts += 'winget executable was transiently inaccessible through every retry'
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

    if ($detailParts.Count -gt 0) {
        return ('{0}; {1}' -f $base, ($detailParts -join ', '))
    }
    return $base
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
