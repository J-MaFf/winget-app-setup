<#
.SYNOPSIS
    Runs the installation: elevation, pre-flight, winget setup, the apps, auto-updates and the
    summary, and returns the exit code.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
.PARAMETER NonInteractive
    For unattended runs (RMM, CI, scheduled tasks): no final "press any key to exit". Also set by
    WINGET_APP_SETUP_NONINTERACTIVE, and detected when the session is non-interactive or stdin is
    redirected. Nothing asks a yes/no question (issue #230); the one prompt, TightVNC's server
    password, is never shown then, and a run that is not elevated returns 4 instead of raising a UAC
    prompt nobody would answer.
.PARAMETER SkipSystemCheck
    The entry script's -SkipSystemCheck, forwarded only to an elevated relaunch (issue #185); the
    checks themselves run in the entry script.
.PARAMETER Apps
    App-definition hashtables to install. Default: Get-DefaultAppCatalog, which the uninstaller
    shares (issue #190).
.PARAMETER MaxRuntimeMinutes
    The run's time budget in minutes, 1 to 1440 (wgt-gq8.41). Not given (or 0): the
    WINGET_APP_SETUP_MAX_RUNTIME_MINUTES environment variable decides (Resolve-InstallerRunBudget),
    and without it the run has no budget. Once the budget is used up, no app install, retry or
    Winget-AutoUpdate setup starts (one already running finishes, within its own time limit), what
    is left is reported NotAttempted, and the run returns 9. A dry run reports the budget and is not
    cut short.
.PARAMETER RunDeadlineUtc
    Internal: the deadline an earlier phase of the same run passed on (yyyy-MM-ddTHH:mm:ssZ), so
    the budget counts from the first start of the run. Set by the installer's own relaunches and by
    rmm/Invoke-WingetAppSetup.ps1.
.OUTPUTS
    [int] The run's exit code. It never ends the process: the entry script exits with it, so every
    path here can be tested.
.NOTES
    Exit codes: 0 = success; 1 = an app failed (including those failed once winget could no longer
    start mid-run, and a failed post-install hook); 2 = winget unavailable (at the start, including
    Group Policy turning it off and, as SYSTEM, no machine-wide winget.exe that starts; or no longer
    launchable at the end); 3 = the catalog failed validation or no valid apps remain; 4 =
    administrator rights are required and the run was not elevated (the prompt was declined or could
    not be shown, a non-interactive run, an execution policy that would refuse the elevated script,
    irm | iex, or the imported module); 8 = apps installed, but automatic updates are FAILED, NOT
    CONFIGURED, AT RISK or UNHEALTHY; 9 = the time budget (-MaxRuntimeMinutes) was used up, so some
    apps or the Winget-AutoUpdate setup were not attempted: run it again to finish; 3010 = success,
    but a restart finishes it. At the end of a run the precedence is 1 > 2 > 9 > 8 > 3010 > 0
    (Get-InstallerExitCode). Deferred apps and NotConfigured hooks do not change the code. A run
    that relaunched itself elevated returns the elevated run's code. The entry script also exits 1
    for a failed blocking pre-flight check, 5 for an abort or Constrained Language Mode, and 6 when
    another run is in progress.

    After the summary, a real run reports in machine-readable form (Write-InstallerRunResult: the
    RESULT line and last-run.json) and releases the run lock before the final prompt.
#>
function Invoke-WingetInstall {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,

        [Parameter(Mandatory = $false)]
        [array]$Apps = (Get-DefaultAppCatalog),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 1440)]
        [int]$MaxRuntimeMinutes = 0,

        [Parameter(Mandatory = $false)]
        [string]$RunDeadlineUtc
    )

    # Non-interactive: the switch, the environment variable, a non-interactive session, SYSTEM, or
    # redirected stdin (Test-EffectiveNonInteractive).
    $effectiveNonInteractive = Test-EffectiveNonInteractive -NonInteractive:$NonInteractive

    # The whole run's time budget (wgt-gq8.41), counted from when the entry script started (or from
    # the deadline an earlier phase passed on), and passed on to an elevated relaunch.
    $runStartedUtc = [DateTime]::UtcNow
    if ($script:InstallerRunStartedUtc -is [DateTime]) {
        $runStartedUtc = $script:InstallerRunStartedUtc
    }
    $runBudget = Resolve-InstallerRunBudget -MaxRuntimeMinutes $MaxRuntimeMinutes -RunDeadlineUtc $RunDeadlineUtc -StartedUtc $runStartedUtc
    # Latched once seen: no app install, retry or Winget-AutoUpdate setup starts after that.
    $runBudgetSpent = $false
    $runBudgetReason = $null
    if ($runBudget.DeadlineUtc) {
        $runBudgetReason = "the run's $($runBudget.Minutes)-minute time budget was used up"
    }

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    # Mockable, and assumes elevated when the check itself throws (see Test-IsAdmin).
    $isAdmin = Test-IsAdmin

    # Not elevated: a dry run only previews and never needs elevation; any other run that cannot go
    # on without administrator rights returns 4 (P2-12).
    If (-NOT $isAdmin) {
        if ($WhatIf) {
            if (-not (Test-IsRunningLocally)) {
                # IEX/remote execution has no local script path to relaunch from, but that's
                # irrelevant to a preview: same rationale as the local-file case below.
                Write-Info '[DRY-RUN] Would require administrator privileges for a real run (auto-elevation is unavailable when running through IEX/remote execution). Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            elseif ($effectiveNonInteractive) {
                # A real run stops here with 4 (review finding P2-12); the preview says so.
                Write-Info '[DRY-RUN] A real run would stop here with exit code 4: it needs administrator privileges, and a non-interactive run shows no UAC prompt. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                # A preview never relaunches elevated, which could turn it into a real install. The
                # execution-policy check is read-only, so the preview says what it would find.
                $elevationPolicyBlock = Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell
                if ($elevationPolicyBlock -and $elevationPolicyBlock.Scope -eq 'MachinePolicy') {
                    Write-Info ('[DRY-RUN] A real run would stop here with exit code 4, without a UAC prompt: {0} Continuing the preview in the current (non-elevated) session; no system changes will be made.' -f (Format-ElevationPolicyBlockMessage -Block $elevationPolicyBlock))
                }
                else {
                    Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
                    if ($elevationPolicyBlock) {
                        Write-Info ('[DRY-RUN] {0}' -f (Format-ElevationPolicyBlockMessage -Block $elevationPolicyBlock))
                    }
                }
            }
        }
        elseif (-not (Test-IsRunningLocally)) {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            # No sleep: the entry script's Exit-Installer prints the log path and build id and waits
            # for a key press when someone is at the console (P2-14).
            return 4
        }
        elseif (Test-InvokedFromModuleContext -InvocationModule $MyInvocation.MyCommand.Module -CommandPath $PSCommandPath) {
            # From the imported module, $PSCommandPath is the functions-only Public/Install.ps1, so an
            # elevated relaunch would install nothing (issue #185).
            Write-ErrorMessage 'Invoke-WingetInstall was invoked from the imported module without elevation; auto-elevation cannot relaunch a module function. Run winget-app-install.ps1, or start from an already-elevated session.'
            return 4
        }
        elseif ($effectiveNonInteractive) {
            # Nobody is there to approve a UAC prompt (P2-12), and one on the user's desktop would
            # leave the run with nothing installed.
            Write-ErrorMessage 'This script requires administrator privileges, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM (for example from an RMM tool).'
            return 4
        }
        else {
            # No winget call before elevating: the elevated run sets winget up for its own account
            # (P3-25). No "press Enter to elevate" pause (issue #230): the UAC dialog is the consent.
            Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
            # Forward -SkipSystemCheck (issue #185) and -WhatIf (a safety net; a dry run never gets
            # here). -NonInteractive never: a non-interactive run returned 4 above.
            $elevationArgs = @()
            if ($WhatIf) { $elevationArgs += '-WhatIf' }
            if ($SkipSystemCheck) { $elevationArgs += '-SkipSystemCheck' }
            # On the command line: the elevated window may not inherit this process's environment.
            $elevationArgs += @(Get-InstallerRunBudgetArgument -Budget $runBudget)
            # Waits for the elevated window and returns its exit code (review finding P2-12), and
            # runs only a checked copy of this file (P3-11): $script:InstallerScriptSha256 is the
            # file's SHA256 taken by the entry script when this run started.
            $elevation = Restart-WithElevation -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs -ExpectedSha256 $script:InstallerScriptSha256
            if (-not $elevation.Started) {
                # Restart-WithElevation has said why and what to do: a declined prompt, a file that
                # changed (5) or a command line too long all differ, and only the first had a prompt.
                Write-ErrorMessage 'No elevated run was started, so nothing was installed.'
                return [int]$elevation.ExitCode
            }
            # The elevated window showed the run's summary, or why it stopped, and waited for a key
            # press itself: recorded so the entry script exits with this code without a second
            # notice and key press here.
            $script:InstallerPendingExitCode = [int]$elevation.ExitCode
            # It also printed its own RESULT line and wrote last-run.json: this window adds no
            # second, emptier record of the same run.
            $script:InstallerRunReportPending = $false
            return [int]$elevation.ExitCode
        }
    }
    else {
        Write-Success 'Starting...'
    }

    if ($runBudget.DeadlineUtc) {
        $deadlineText = Format-RunRecordTime -Time $runBudget.DeadlineUtc
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Time budget: $($runBudget.Minutes) minutes, until $deadlineText. A real run starts no app install and no Winget-AutoUpdate setup after that, and exits 9; this preview is not cut short."
        }
        else {
            Write-Info "Time budget: $($runBudget.Minutes) minutes, until $deadlineText. No app install, retry or Winget-AutoUpdate setup starts after that (one already running finishes); what is left is reported as not attempted, and the run exits 9 so that it can be run again."
        }
    }

    # Who this run installs as, decided once: as SYSTEM or under cross-user elevation the run
    # installs for the whole PC only. A stale machine-wide winget path from an earlier run in this
    # session is dropped first.
    $script:MachineWingetPath = $null
    $account = Get-InstallAccountContext
    $machineWide = [bool]($account.IsSystem -or $account.IsCrossUserElevation)
    if ($account.IsSystem) {
        Write-Info 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only, with the winget.exe that App Installer installed for this PC. An app with no machine-wide installer is not installed: it is reported as Deferred, with how it can still be installed for the user. Microsoft does not support the winget command line as SYSTEM, so a SYSTEM run can fail where a run as a user would not.'
    }

    # Pre-flight for the account this run installs as, before it changes or waits for anything:
    # proxy and pending-restart warnings, and App Installer's Group Policy stopping a real run with 2.
    # The restart state it read lets the end of the run tell its own restart (3010) from an old one.
    $preflight = Invoke-EnvironmentPreflight -WhatIf:$WhatIf -AccountContext $account
    if ($preflight.ExitCode -ne 0) {
        return [int]$preflight.ExitCode
    }
    $restartStateBefore = $preflight.RestartState
    $restartPendingBefore = @($preflight.RestartPendingReasons)

    # TightVNC's passwords for its hook (P2-22), before winget or any installer starts: taken out of
    # the environment so no child process inherits them, or asked for now when someone is at the
    # console (at most 5 minutes, since the run holds the lock). A failure only leaves TightVNC not
    # configured. Every return below drops them (Clear-TightVncSecret), as does the entry script.
    try {
        Initialize-TightVncSecretForRun -Apps $Apps -NonInteractive:$effectiveNonInteractive -WhatIf:$WhatIf
    }
    catch {
        Write-WarningMessage "Could not read the TightVNC password for this run: $($_.Exception.Message)"
    }

    # Let a Winget-AutoUpdate run already in progress finish first (bounded): racing its App
    # Installer re-provisioning and MSI upgrades fails healthy installs. Not in a dry run.
    # Never longer than the time budget has left: once it is used up nothing is installed anyway.
    if (-not $WhatIf) {
        $budgetSecondsLeft = Get-InstallerRunBudgetSecondsLeft -Budget $runBudget
        if ($null -eq $budgetSecondsLeft) {
            [void](Wait-WauIdle)
        }
        elseif ($budgetSecondsLeft -gt 0) {
            [void](Wait-WauIdle -TimeoutSeconds ([Math]::Min(900, $budgetSecondsLeft)))
        }
    }

    # Make winget usable for this account (Initialize-Winget); a real run stops with 2 when it cannot
    # be started or Group Policy turns it off. A dry run only probes and carries on (P2-16), and skips
    # it when the pre-flight already reported the policy block.
    if ($preflight.WingetPolicyBlocked) {
        $winget = [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }
    else {
        $winget = Initialize-Winget -WhatIf:$WhatIf -AccountContext $account
    }
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable -and -not $WhatIf) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        Clear-TightVncSecret
        return 2
    }

    # Migrate away from the old homegrown scheduled-update task if a prior version installed one;
    # ongoing updates are now handled by Winget-AutoUpdate, set up after the app installs (issue #168).
    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

    # No PATH changes: a user-writable folder on an elevating account's PATH is a hijack surface
    # (issue #179).

    # The curated app list lives in Get-DefaultAppCatalog (issue #190) — the single source of
    # truth shared with winget-app-uninstall.ps1. It arrives here through the -Apps parameter,
    # which defaults to that catalog and lets tests inject a custom one.
    $apps = $Apps

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'No valid application definitions found. Resolve the errors and re-run the script.'
        Clear-TightVncSecret
        return 3
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        Clear-TightVncSecret
        return 3
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    if (-not $wingetAvailable) {
        # Only a dry run gets here without winget: its per-app `winget list` checks cannot run, so
        # each one reports the app as not installed.
        $wingetScope = 'for this account'
        if ($account.IsSystem) {
            $wingetScope = 'machine-wide'
        }
        Write-Info "[DRY-RUN] winget is not available $wingetScope, so this preview cannot tell which apps are already installed: every app that applies to this machine is listed as one a real run would install."
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()
    # Deferred apps: no machine-wide installer in a run for the whole PC, or marked per-user in the
    # catalog. Neither installed nor failed; explained apart (Write-DeferredAppsSummary).
    $deferredApps = @()
    $noInstallerDeferredApps = @()
    $perUserDeferredApps = @()
    # Installed apps whose post-install hook could not configure them: they do
    # not change the exit code, and the summary names them with the hook's reason.
    $notConfiguredApps = @()
    # Apps the time budget did not reach (wgt-gq8.41): neither installed nor failed; the run exits 9.
    $notAttemptedApps = @()

    # No separate source-trust pass here: only the winget community source is used (every install
    # forces --source winget), and Initialize-Winget above already updated it, and repaired it if
    # needed (issues #172, #177).

    # Run-level circuit breaker (P2-8, P2-10): once winget cannot be started, every remaining app
    # fails at once with one reason and the retry pass is skipped.
    $wingetNotLaunchable = $false

    # Run-level budget for waiting on a busy Windows Installer (0x8A150102, msiexec 1618; P2-15):
    # every wait, the Winget-AutoUpdate msiexec's included, comes out of these 10 minutes.
    $installerBusyWaitSecondsLeft = 600

    # Apps whose install finished but needs a restart to complete (review finding P3-16). Apps whose
    # installer cannot run until Windows restarts (0x8A15010A) are failed apps marked RestartFirst.
    $restartRequiredApps = @()

    # Applicability decided once per run, before this run changes the machine, for both passes
    # (P3-34): the Terminal step between them changes what the Terminal condition reads. Fail open.
    $applicableByName = @{}
    foreach ($app in $apps) {
        $applicableByName[$app.name] = Test-AppApplicability -App $app
    }

    # One run-record entry per app, in catalog order; the retry pass replaces an app's entry. Kept
    # in $script: scope too, so a run that stops before its summary still reports them.
    $appRecords = [ordered]@{}
    $script:InstallerAppRecords = $appRecords

    Foreach ($app in $apps) {
        $outcome = $null
        # Checked before each app; a dry run is never cut short.
        if (-not $WhatIf -and -not $runBudgetSpent -and (Test-InstallerRunBudgetSpent -Budget $runBudget)) {
            $runBudgetSpent = $true
            Write-WarningMessage "Time budget: $runBudgetReason, so no further app install starts. The apps left are reported as not attempted; run the installer again to install them."
        }
        try {
            # Shared per-app pipeline — pre-check, dispatch, post-verify (issue #188). Messages,
            # summary bucketing, and exit-code policy stay here in the orchestrator.
            # -Silent: an unattended run installs MSI packages with /quiet, not /passive.
            $outcome = Install-AppWithVerification -App $app -Applicable $applicableByName[$app.name] -Silent:$effectiveNonInteractive -WhatIf:$WhatIf -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -TimeBudgetSpent:$runBudgetSpent -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
            if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
            }

            switch ($outcome.Status) {
                'Skipped' {
                    if ($outcome.SkipReason -eq 'NotApplicable') {
                        # Not applicable (issue #217): the same summary bucket as an installed skip,
                        # with the reason in the message.
                        $conditionText = Get-AppNotApplicableReason -App $app
                        Write-WarningMessage "Skipping: $($app.name) (not applicable: $conditionText)"
                        $skipReason = "not applicable: $conditionText"
                    }
                    elseif ($outcome.SkipReason -eq 'Provisioned') {
                        # A run for the whole PC read it from the machine (review finding P3-24).
                        Write-WarningMessage "Skipping: $($app.name) (already provisioned for every user on this PC)"
                        $skipReason = 'already provisioned for every user on this PC'
                    }
                    else {
                        Write-WarningMessage "Skipping: $($app.name) (already installed)"
                        $skipReason = 'already installed'
                    }
                    $skippedApps += $app.name
                    # An installed app's post-install hook ran.
                    if (Write-AppPostInstallResult -AppName $app.name -Configuration $outcome.Configuration) {
                        $notConfiguredApps += @{ Name = $app.name; Reason = [string]$outcome.Configuration.Reason }
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Skipped' -Reason $skipReason -PostInstall $outcome.Configuration
                }
                'Deferred' {
                    # No machine-wide installer (review finding P3-22), or the catalog marks the app
                    # per-user, and this run installs for the whole PC only.
                    # Write-DeferredAppsSummary says what can install it.
                    $deferText = Get-AppDeferReasonText -DeferReason $outcome.DeferReason
                    Write-WarningMessage "Deferred: $($app.name) ($deferText)"
                    $deferredApps += $app.name
                    if (@('UserScope', 'UserPhase') -contains $outcome.DeferReason) {
                        $perUserDeferredApps += $app.name
                    }
                    else {
                        $noInstallerDeferredApps += $app.name
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Deferred' -Reason $deferText -InstallResult $outcome.InstallResult
                }
                'NotAttempted' {
                    Write-WarningMessage "Not attempted: $($app.name) ($runBudgetReason)"
                    $notAttemptedApps += $app.name
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'NotAttempted' -Reason $runBudgetReason
                }
                'Installed' {
                    if ($WhatIf) {
                        Write-Info "[DRY-RUN] Would install: $($app.name)"
                    }
                    else {
                        Write-Success "Successfully installed: $($app.name)"
                        # A restart that finishes the install, or a non-zero winget exit code
                        # behind an app that is installed anyway (review finding P3-16).
                        if (Write-InstalledAppNote -AppName $app.name -InstallResult $outcome.InstallResult) {
                            $restartRequiredApps += $app.name
                        }
                        if (Write-AppPostInstallResult -AppName $app.name -Configuration $outcome.Configuration) {
                            $notConfiguredApps += @{ Name = $app.name; Reason = [string]$outcome.Configuration.Reason }
                        }
                    }
                    $installedApps += $app.name
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Installed' -InstallResult $outcome.InstallResult -RestartRequired ($restartRequiredApps -contains $app.name) -PostInstall $outcome.Configuration
                }
                default {
                    # Surface the diagnostic detail the install pipeline already returns (winget
                    # exit code, attempts, scope fallback) instead of discarding it (issue #189).
                    $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult -LaunchError $outcome.LaunchError -CheckExitCode $outcome.CheckExitCode -PostInstallReason $outcome.Configuration.Reason
                    switch ($outcome.FailureReason) {
                        'PreCheckTimeout' {
                            # Failed instead of silently dropped: the app then flows through the
                            # retry pass, appears in the summary, and drives the non-zero exit
                            # code (issue #176).
                            Write-WarningMessage "Winget list timed out for $($app.name). Marking as failed; it will be retried."
                        }
                        'VerifyTimeout' {
                            Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
                        }
                        default {
                            Write-ErrorMessage "Failed to install: $($app.name) ($failureReason)."
                        }
                    }
                    # Only the post-install hook failed: the install itself
                    # finished, so its restart and scope notes belong to this run whatever the hook
                    # does in the retry pass.
                    if ($outcome.FailureReason -eq 'PostInstallFailed' -and $outcome.StatusBeforeHook -eq 'Installed' -and (Write-InstalledAppNote -AppName $app.name -InstallResult $outcome.InstallResult)) {
                        $restartRequiredApps += $app.name
                    }
                    # Objects, for the summary's Reason column (issue #189). RestartFirst
                    # (0x8A15010A): the retry pass leaves it alone until Windows restarts.
                    $failedApps += @{
                        Name             = $app.name
                        Reason           = $failureReason
                        RestartFirst     = (Test-RestartRequiredFirst -InstallResult $outcome.InstallResult)
                        FailureReason    = $outcome.FailureReason
                        StatusBeforeHook = $outcome.StatusBeforeHook
                        InstallResult    = $outcome.InstallResult
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Failed' -Reason $failureReason -InstallResult $outcome.InstallResult -RestartRequired ($restartRequiredApps -contains $app.name) -PostInstall $outcome.Configuration
                }
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += @{ Name = $app.name; Reason = "Unexpected error: $_" }
            $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Failed' -Reason "Unexpected error: $_"
        }

        # A dry run never launches winget beyond its read-only checks, so it never trips this.
        if (-not $WhatIf -and -not $wingetNotLaunchable -and $outcome -and (Invoke-WingetLaunchCircuitBreaker -Outcome $outcome)) {
            $wingetNotLaunchable = $true
        }
    }

    # Ongoing app updates are handled by Winget-AutoUpdate (set up below), which runs as SYSTEM on a
    # schedule — not an install-time pass that upgrades every installed app synchronously as the
    # elevating admin (that was slow, silent, and largely failed under cross-user elevation; issue #170).

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    # Best-effort and isolated: an unexpected error here must not skip the retry pass, the summary
    # or the exit-code decision below.
    try {
        Set-WindowsTerminalDefaults -WhatIf:$WhatIf
    }
    catch {
        Write-WarningMessage "Windows Terminal configuration failed unexpectedly: $_. Continuing; app installs are not affected."
    }

    # Retry any failed installations once before producing the final summary
    if ($failedApps.Count -gt 0) {
        if ($wingetNotLaunchable) {
            Write-WarningMessage 'Skipping the retry pass: winget cannot be launched on this machine (see above); retrying would not help.'
        }
        elseif (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($failedApp in $appsToRetry) {
                $appName = $failedApp.Name
                if ($failedApp.RestartFirst) {
                    # 0x8A15010A (review finding P3-16): only a restart changes it, so another try
                    # now would fail the same way.
                    Write-WarningMessage "Not retrying ${appName}: its installer cannot run until this PC restarts."
                    $failedApps += $failedApp
                    continue
                }
                if ($failedApp.FailureReason -eq 'NoMachineScopeInstaller') {
                    # A scope 'machine' app: the package's manifest decides
                    # this, so another try in this run would get the same answer from winget.
                    Write-WarningMessage "Not retrying ${appName}: no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine')."
                    $failedApps += $failedApp
                    continue
                }
                # A spent time budget leaves the app failed, as the first pass left it.
                if (-not $runBudgetSpent -and (Test-InstallerRunBudgetSpent -Budget $runBudget)) {
                    $runBudgetSpent = $true
                    Write-WarningMessage "Time budget: $runBudgetReason, so no further retry starts."
                }
                if ($runBudgetSpent) {
                    Write-WarningMessage "Not retrying ${appName}: $runBudgetReason."
                    $failedApps += $failedApp
                    continue
                }
                $outcome = $null
                try {
                    Write-Info "Retrying: $appName"
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1

                    # The same pipeline as the first pass, with what is left of the wait budget,
                    # the circuit breaker, and the run's applicability verdict.
                    $outcome = Install-AppWithVerification -App $appDef -Applicable $applicableByName[$appName] -Silent:$effectiveNonInteractive -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
                    if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                        $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
                    }

                    # Only its post-install hook failed in the first pass: the
                    # retry finds the app installed and runs no installer, so the first pass's
                    # install (its exit code; its restart was counted then) is the one to record.
                    $hookRetry = $failedApp.FailureReason -eq 'PostInstallFailed'
                    $recordInstallResult = $outcome.InstallResult
                    if ($hookRetry -and $null -eq $recordInstallResult) {
                        $recordInstallResult = $failedApp.InstallResult
                    }

                    if ($outcome.Status -eq 'Failed') {
                        $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult -LaunchError $outcome.LaunchError -CheckExitCode $outcome.CheckExitCode -PostInstallReason $outcome.Configuration.Reason
                        switch ($outcome.FailureReason) {
                            'PreCheckTimeout' {
                                Write-WarningMessage "Winget list timed out for retry: $appName. Assuming installation failed."
                            }
                            'VerifyTimeout' {
                                Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                            }
                            default {
                                Write-ErrorMessage "Retry failed: $appName ($failureReason)."
                            }
                        }
                        $failedApps += @{ Name = $appName; Reason = $failureReason; RestartFirst = (Test-RestartRequiredFirst -InstallResult $outcome.InstallResult); FailureReason = $outcome.FailureReason }
                        $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Failed' -Reason $failureReason -InstallResult $recordInstallResult -RestartRequired ($restartRequiredApps -contains $appName) -PostInstall $outcome.Configuration
                    }
                    elseif ($outcome.Status -eq 'Deferred') {
                        # The retry got as far as the install, which found no machine-wide
                        # installer (review finding P3-22): deferred, not failed.
                        $deferText = Get-AppDeferReasonText -DeferReason $outcome.DeferReason
                        Write-WarningMessage "Deferred: $appName ($deferText)"
                        $deferredApps += $appName
                        if (@('UserScope', 'UserPhase') -contains $outcome.DeferReason) {
                            $perUserDeferredApps += $appName
                        }
                        else {
                            $noInstallerDeferredApps += $appName
                        }
                        $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Deferred' -Reason $deferText -InstallResult $outcome.InstallResult
                    }
                    elseif ($outcome.SkipReason -eq 'NotApplicable') {
                        # Same bucket and message as the first pass (review finding P3-34): an app
                        # that does not apply was not installed, so it is never 'Retry succeeded'.
                        $conditionText = Get-AppNotApplicableReason -App $appDef
                        Write-WarningMessage "Skipping: $appName (not applicable: $conditionText)"
                        $skippedApps += $appName
                        $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Skipped' -Reason "not applicable: $conditionText"
                    }
                    else {
                        # 'Installed', or 'Skipped' when the first-pass install actually landed
                        # and only its verification or post-install hook failed — either way the
                        # app is present now.
                        Write-Success "Retry succeeded: $appName"
                        if ($outcome.Status -eq 'Installed' -and (Write-InstalledAppNote -AppName $appName -InstallResult $outcome.InstallResult) -and $restartRequiredApps -notcontains $appName) {
                            $restartRequiredApps += $appName
                        }
                        # A first-pass hook failure ends here once the hook succeeds: the retry
                        # finds the app installed and runs its hook again.
                        if (Write-AppPostInstallResult -AppName $appName -Configuration $outcome.Configuration) {
                            $notConfiguredApps += @{ Name = $appName; Reason = [string]$outcome.Configuration.Reason }
                        }
                        if ($hookRetry -and $outcome.Status -eq 'Skipped' -and $failedApp.StatusBeforeHook -ne 'Installed') {
                            # Installed before this run; only its hook needed the retry.
                            $skipReason = 'already installed'
                            if ($outcome.SkipReason -eq 'Provisioned') {
                                $skipReason = 'already provisioned for every user on this PC'
                            }
                            $skippedApps += $appName
                            $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Skipped' -Reason $skipReason -PostInstall $outcome.Configuration
                        }
                        else {
                            $installedApps += $appName
                            $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Installed' -InstallResult $recordInstallResult -RestartRequired ($restartRequiredApps -contains $appName) -PostInstall $outcome.Configuration
                        }
                    }
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += @{ Name = $appName; Reason = "Unexpected error: $_" }
                    $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Failed' -Reason "Unexpected error: $_"
                }

                if (-not $wingetNotLaunchable -and $outcome -and (Invoke-WingetLaunchCircuitBreaker -Outcome $outcome)) {
                    $wingetNotLaunchable = $true
                }
            }
        }
        else {
            Write-Host ''
            Write-Info '[DRY-RUN] Would retry the following failed installations:'
            foreach ($failedApp in $failedApps) {
                Write-Info "[DRY-RUN] Would retry: $($failedApp.Name)"
            }
        }
    }

    # No post-install hook runs after the retry pass: the TightVNC passwords are not kept any longer
    # (an irm | iex console stays open after the run).
    Clear-TightVncSecret

    # Automatic updates via Winget-AutoUpdate (issue #168), best-effort; the outcome is shown with
    # the summary and decides exit code 8 (P3-36). After every winget call this run makes, and WAU
    # is not told to run now: a WAU run re-provisions App Installer and resets winget's sources,
    # which mid-run wedged winget (#279, #284) and killed the console (#283).
    # A spent time budget skips the whole step, the Windows App Runtime install included: it can
    # take many minutes, and the next run does it.
    if (-not $WhatIf -and -not $runBudgetSpent -and (Test-InstallerRunBudgetSpent -Budget $runBudget)) {
        $runBudgetSpent = $true
    }
    if ($runBudgetSpent) {
        Write-WarningMessage "Not setting up Winget-AutoUpdate (or the Windows App Runtime it needs): $runBudgetReason. The next run sets it up."
        $wauResult = [pscustomobject]@{ Status = 'NotAttempted'; Version = $null; FrameworkMissing = $false; RestartRequired = $false }
    }
    else {
        try {
            $wauResult = Install-WingetAutoUpdate -WhatIf:$WhatIf -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
        }
        catch {
            Write-ErrorMessage "Winget-AutoUpdate setup failed unexpectedly: $_"
            $wauResult = [pscustomobject]@{ Status = 'Failed'; Version = $null }
        }
    }
    # For the record of a run that stops after this point but before its summary.
    $script:InstallerAutoUpdateResult = $wauResult

    # Never report success with winget unusable: one bounded launch check after the last change this
    # run makes (up to five tries 15 seconds apart, one when the breaker already tripped). Not in a
    # dry run.
    $wingetUsableAtEnd = $true
    # For the run record: $null unless the check ran and answered (a check that threw is not
    # evidence either way, although the exit code treats winget as usable then).
    $wingetUsableForRecord = $null
    $endCheckReason = $null
    if (-not $WhatIf) {
        try {
            $endCheckAttempts = 5
            if ($wingetNotLaunchable) {
                $endCheckAttempts = 1
            }
            $endCheck = Test-WingetLaunchable -Attempts $endCheckAttempts -RetryDelaySeconds 15
            $wingetUsableAtEnd = [bool]$endCheck.Launchable
            $wingetUsableForRecord = $wingetUsableAtEnd
            # Why, for the NOT USABLE line: a failure that is final at once ('Access is denied',
            # winget missing) prints no retry warning and has no winget output to show.
            $endCheckReason = $endCheck.Reason
        }
        catch {
            # A bug in the probe is not evidence that winget is broken; report it and move on.
            Write-WarningMessage "Could not run the end-of-run winget check: $_"
        }
    }

    # Does this run need a restart (P3-16)? An install said so, the WAU MSI returned 3010, or a
    # restart became pending during the run (a queued file replacement winget does not report).
    # One pending before the run is not this run's. Not in a dry run.
    $restartReasons = @()
    if ($restartRequiredApps.Count -gt 0) {
        $restartReasons += ('{0} reported that a restart finishes the installation' -f ($restartRequiredApps -join ', '))
    }
    if ($wauResult -and $wauResult.RestartRequired) {
        $restartReasons += 'the Winget-AutoUpdate installer reported that a restart finishes the installation'
    }
    if (-not $WhatIf -and $null -ne $restartStateBefore) {
        try {
            $restartReasons += @(Get-PendingRestartReason -State (Get-PendingRestartState) -Since $restartStateBefore)
        }
        catch {
            Write-WarningMessage "Could not check whether a restart is pending after the run: $_"
        }
    }
    $restartRequired = $restartReasons.Count -gt 0
    $restartFirstApps = @($failedApps | Where-Object { $_.RestartFirst } | ForEach-Object { $_.Name })

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

    $appList = Format-AppList -AppArray $deferredApps
    if ($appList) {
        $rows += , @('Deferred', $appList)
    }

    $failedAppNames = @($failedApps | ForEach-Object { $_.Name })
    $appList = Format-AppList -AppArray $failedAppNames
    if ($appList) {
        $rows += , @('Failed', $appList)
    }

    # Last, so a reader of the rows above (e2e/TranscriptAssertions.ps1) is not cut short by it.
    $appList = Format-AppList -AppArray $notAttemptedApps
    if ($appList) {
        $rows += , @('Not attempted', $appList)
    }

    Write-Table -Headers $headers -Rows $rows -Title 'Installation Summary'

    # Per-app failure reasons (issue #189): winget exit code, attempt count, and scope-fallback
    # detail, so a failure is diagnosable from the summary (and the transcript) instead of a
    # generic message. No-ops when nothing failed.
    Write-FailedAppsSummary -FailedApps $failedApps

    # Why apps were deferred, and who can install them (review findings P3-22, P3-23). They do not
    # change the exit code.
    Write-DeferredAppsSummary -DeferredApps $noInstallerDeferredApps -PerUserApps $perUserDeferredApps -AccountContext $account

    # Installed apps their post-install hook could not configure. They do not
    # change the exit code either; a hook that failed made its app Failed above.
    Write-NotConfiguredAppsSummary -NotConfiguredApps $notConfiguredApps

    # The auto-update outcome with the summary (issue #186). Every outcome printed as an error makes
    # the run exit 8 when nothing ranks above it (P3-36).
    $autoUpdatesHealthy = $true
    # The framework winget needs (read from the latest winget release).
    $wauFrameworkName = 'Microsoft.WindowsAppRuntime.1.8'
    if ($wauResult -and $wauResult.FrameworkName) {
        $wauFrameworkName = [string]$wauResult.FrameworkName
    }
    switch ($wauResult.Status) {
        'Configured' { Write-Success "Auto-updates: Configured (Winget-AutoUpdate v$($wauResult.Version))." }
        'AlreadyPresent' {
            if ($wauResult.FrameworkMissing) {
                Write-ErrorMessage "Auto-updates: AT RISK - Winget-AutoUpdate is installed but $wauFrameworkName is missing; its next run may leave winget unusable (see above)."
                if ($wauResult.FrameworkInstallError) {
                    Write-ErrorMessage "  The installer could not install it: $($wauResult.FrameworkInstallError)."
                }
                $autoUpdatesHealthy = $false
            }
            elseif ($wauResult.Version) {
                Write-Success "Auto-updates: Already present (v$($wauResult.Version))."
            }
            else {
                Write-WarningMessage 'Auto-updates: Already present (installed version could not be determined).'
            }
        }
        'Unhealthy' {
            # CheckFailed: the task could not be queried, so the outcome is unknown, not known bad.
            $autoUpdatesConsequence = 'apps will not update automatically'
            if ($wauResult.CheckFailed) {
                $autoUpdatesConsequence = 'it is not known whether apps will update automatically'
            }
            Write-ErrorMessage "Auto-updates: UNHEALTHY - Winget-AutoUpdate is installed, but $($wauResult.Problem); $autoUpdatesConsequence (see above)."
            $autoUpdatesHealthy = $false
        }
        'DryRun' { Write-Info "[DRY-RUN] Auto-updates: Would configure Winget-AutoUpdate v$($wauResult.Version)." }
        # Exit code 9 already says the run is not finished; the next run sets it up.
        'NotAttempted' { Write-WarningMessage "Auto-updates: NOT ATTEMPTED - $runBudgetReason before Winget-AutoUpdate was set up; run the installer again to set it up." }
        'FrameworkMissing' {
            $wauFrameworkRelease = $wauFrameworkName -replace 'Microsoft\.WindowsAppRuntime\.', ''
            Write-ErrorMessage "Auto-updates: NOT CONFIGURED - $wauFrameworkName is missing, and Winget-AutoUpdate would leave winget unusable without it. Install the Windows App Runtime $wauFrameworkRelease (or let the Microsoft Store update App Installer), then re-run the installer."
            # Why the installer's own attempt (Install-WindowsAppRuntimeFramework) did not help.
            if ($wauResult.FrameworkInstallError) {
                Write-ErrorMessage "  The installer could not install it: $($wauResult.FrameworkInstallError)."
            }
            $autoUpdatesHealthy = $false
        }
        default {
            Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.'
            $autoUpdatesHealthy = $false
        }
    }

    if (-not $wingetUsableAtEnd) {
        $endCheckDetail = ''
        if (-not [string]::IsNullOrWhiteSpace($endCheckReason)) {
            $endCheckDetail = " ($endCheckReason)"
        }
        Write-ErrorMessage "winget: NOT USABLE - winget did not work at the end of this run$endCheckDetail, so automatic updates and the next run of this installer will fail on this machine. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
    }

    # Restart (review finding P3-16): a run whose installs need a restart says so here and exits
    # 3010 when nothing failed; apps whose installer needs a restart first are named; a restart
    # that was pending before the run is reported, nothing more.
    if ($restartFirstApps.Count -gt 0) {
        Write-ErrorMessage ('Restart: REQUIRED before {0} can install - restart this PC, then re-run the installer.' -f ($restartFirstApps -join ', '))
    }
    if ($restartRequired) {
        Write-WarningMessage ('Restart: REQUIRED to finish this run - restart this PC before it is used ({0}).' -f ($restartReasons -join '; '))
    }
    elseif ($restartPendingBefore.Count -gt 0 -and $restartFirstApps.Count -eq 0) {
        Write-WarningMessage ('Restart: already pending before this run ({0}) - restart this PC when you can.' -f ($restartPendingBefore -join '; '))
    }

    # What the time budget left undone (wgt-gq8.41), and that another run finishes it.
    $notAttemptedSteps = @($notAttemptedApps)
    if ($wauResult.Status -eq 'NotAttempted') {
        $notAttemptedSteps += 'the Winget-AutoUpdate setup'
    }
    if ($notAttemptedSteps.Count -gt 0) {
        Write-WarningMessage ("Time budget: USED UP - the run's {0}-minute budget ran out at {1}, so these were not attempted: {2}. Run the installer again to finish." -f $runBudget.Minutes, (Format-RunRecordTime -Time $runBudget.DeadlineUtc), ($notAttemptedSteps -join ', '))
    }

    # The transcript path again, next to the summary (issue #189); unset outside the entry script.
    if ($script:InstallLogPath) {
        Write-Info "Full transcript of this run: $script:InstallLogPath"
    }

    $exitCode = Get-InstallerExitCode -FailedAppCount $failedApps.Count -WingetUsable $wingetUsableAtEnd -WorkNotAttempted ($notAttemptedSteps.Count -gt 0) -AutoUpdatesHealthy $autoUpdatesHealthy -RestartRequired $restartRequired
    # Recorded before the final prompt: Ctrl+C there stops a run that has already finished, and
    # the entry script's abort guard then reports this code instead of an abort (5).
    $script:InstallerPendingExitCode = $exitCode

    # A failed run (1, 2 or 8) says where to report it and how to make the diagnostics bundle, as an
    # early exit does.
    if (-not $WhatIf -and @(1, 2, 8) -contains $exitCode) {
        Write-InstallerReportHint
    }

    # The run's outcome in machine-readable form (review finding P3-41): last-run.json next to the
    # transcript and one RESULT line, before the final prompt so someone at the console sees it too.
    # A dry run changes nothing and reports neither.
    if (-not $WhatIf) {
        try {
            $runRecord = New-InstallerRunRecord -ExitCode $exitCode -Apps @($appRecords.Values) -AutoUpdates (Get-AutoUpdateResultStatus -WauResult $wauResult) -AutoUpdatesVersion $wauResult.Version -RestartRequired $restartRequired -WingetUsable $wingetUsableForRecord -SummaryReached
            [void](Write-InstallerRunResult -Record $runRecord)
        }
        catch {
            Write-WarningMessage "Could not report this run's result: $_"
        }
        $script:InstallerRunReportPending = $false
        # The run is over: the next one (an RMM schedule) may start while this window waits for a
        # key press.
        Unlock-InstallerRun
    }

    # Keep the console window open until the user presses a key. Skipped in non-interactive mode
    # so unattended runs never block.
    if (-not $effectiveNonInteractive) {
        Write-Prompt 'Press any key to exit...'
        [void][System.Console]::ReadKey($true)
    }

    return $exitCode
}

