<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
.PARAMETER NonInteractive
    Suppresses the interactive extras for unattended runs (RMM, CI, scheduled tasks): the summary
    grid-view window and the final "press any key to exit". Also turned on by
    $env:WINGET_APP_SETUP_NONINTERACTIVE (Test-NonInteractiveRequested), and auto-detected when the
    session is non-interactive or stdin is redirected. No path asks a yes/no question anymore
    (issue #230), so this switch is not needed to keep a run from blocking on a prompt. A non-interactive run that is
    not elevated returns 4 instead of raising a UAC prompt that nobody would answer (review finding
    P2-12).
.PARAMETER SkipSystemCheck
    Pass-through of the entry script's -SkipSystemCheck switch. Used only so an elevated relaunch
    inherits the caller's intent to bypass the pre-flight system checks (issue #185); the checks
    themselves run in the entry script before this function is called.
.PARAMETER Apps
    App-definition hashtables to install. Defaults to the curated catalog returned by
    Get-DefaultAppCatalog — the single source of truth shared with winget-app-uninstall.ps1
    (issue #190). Overridable so tests (and callers) can inject a custom catalog.
.OUTPUTS
    [int] The run's exit code. The function never ends the process itself: the generated entry
    script (build/fragments/tail.ps1) exits with the returned code, so every path here can be
    driven from a test and asserted on its result.
.NOTES
    Exit codes: 0 = success, 1 = one or more apps failed to install (including the apps marked
    failed when winget could no longer be launched mid-run), 2 = winget unavailable (at the start,
    where `winget --version` must run and print a version, or Group Policy turns winget or its
    source off; or no longer launchable at the end of the run), 3 = app-definition validation
    failed or no valid apps remain, 4 = administrator rights
    are required and the run was not elevated: the UAC prompt was declined or could not be shown, a
    non-interactive run (nobody to approve a prompt, so none is shown), irm | iex, or the imported
    module (review finding P2-12), 8 = the apps are installed, but automatic updates are not
    configured or unhealthy: the run's 'Auto-updates:' line is FAILED, NOT CONFIGURED (no
    Microsoft.WindowsAppRuntime.1.8, or whatever the latest winget release needs, and the installer
    could not install it), AT RISK
    or UNHEALTHY (review finding P3-36), 3010 = success,
    but a restart is required to finish (an install said so, or Windows gained a pending restart
    during the run; review finding P3-16). At the end of a run the precedence is
    1 > 2 > 8 > 3010 > 0 (Get-InstallerExitCode). Apps reported as Deferred (a run as SYSTEM or
    under cross-user elevation found no machine-wide installer for them, or the catalog marks them
    per-user: scope 'user' or userPhase) count neither as installed nor as failed and do not change
    the code. An app whose post-install hook failed counts as failed (1); one the hook could not
    configure (NotConfigured) is installed, gets its own 'Configuration: NOT DONE' line and does not
    change the code (work-order item 38). A run as SYSTEM returns 2 at the start
    when no machine-wide winget.exe can be started. A run that relaunched
    itself elevated returns the elevated run's exit code (Restart-WithElevation waits for it). The
    generated entry script also exits 1 when a blocking pre-flight check fails (before this
    function runs), 5 when the run was aborted by an unexpected error or stopped from outside, and
    6 when another run of the installer is in progress on the machine (review finding P3-41).

    After the summary of a real run, the run's outcome is reported in machine-readable form
    (Write-InstallerRunResult): one RESULT line, and last-run.json next to the transcript when the
    entry script allows it ($script:InstallerRunRecordEnabled). Then the run lock is released, before
    the final prompt. A dry run reports neither.
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
        [array]$Apps = (Get-DefaultAppCatalog)
    )

    # Effective non-interactive mode: explicit switch, a non-interactive session (e.g. service,
    # scheduled task, pwsh -NonInteractive), or redirected stdin (piped/irm|iex wrappers).
    # Shared private helper (issue #214) — Test-SystemRequirements gates its disk-space prompt
    # on the same detection.
    $effectiveNonInteractive = Test-EffectiveNonInteractive -NonInteractive:$NonInteractive

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    # Test-IsAdmin (Public/Elevation.ps1, issue #239) wraps the WindowsPrincipal/IsInRole check
    # behind a mockable command, so tests can drive the non-admin branch below deterministically
    # instead of only when Pester itself happens to run non-elevated. It also fails safe (assumes
    # elevated) if the underlying check throws — see its own docstring for why that direction is
    # the right one for this call site specifically.
    $isAdmin = Test-IsAdmin

    # Check if the script is run as administrator. The $WhatIf gate is checked once here, for
    # both execution contexts below, rather than duplicated per-branch: a dry run makes no system
    # changes, so it never needs elevation or an elevation-required exit — only which preview
    # message to print depends on how this script is being run. Every run that cannot go on without
    # administrator rights returns 4 (review finding P2-12).
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
                # Relaunching elevated here would (a) be a surprising side effect for a preview
                # and (b) — if the flag were ever dropped across the elevation boundary —
                # silently turn a dry run into a real install. Stay in the current session and
                # continue the preview.
                Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
        }
        elseif (-not (Test-IsRunningLocally)) {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            # No 'Exiting in 5 seconds' sleep any more: the entry script's Exit-Installer prints the
            # log path and build id and, when someone is at the console, waits for a key press
            # before the window closes (review finding P2-14).
            return 4
        }
        elseif (Test-InvokedFromModuleContext -InvocationModule $MyInvocation.MyCommand.Module -CommandPath $PSCommandPath) {
            # Elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the
            # imported (or dot-sourced) module, that path is WingetAppSetup/Public/Install.ps1 —
            # a functions-only file — so the elevated window would define a function and exit
            # without installing anything (issue #185). Fail fast with guidance instead.
            Write-ErrorMessage 'Invoke-WingetInstall was invoked from the imported module without elevation; auto-elevation cannot relaunch a module function. Run winget-app-install.ps1, or start from an already-elevated session.'
            return 4
        }
        elseif ($effectiveNonInteractive) {
            # Nobody is there to approve a UAC prompt (review finding P2-12): an RMM job or a
            # scheduled task running as a standard user used to raise one on the user's desktop and
            # exit 0 within seconds, with nothing installed.
            Write-ErrorMessage 'This script requires administrator privileges, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM (for example from an RMM tool).'
            return 4
        }
        else {
            # No winget call before elevating: the elevated run sets winget up for the account it
            # runs as (Initialize-Winget). A source update here set up the signed-in user's source,
            # which under cross-user elevation is not the account that installs, and was a fourth
            # source probe in the run (review finding P3-25).
            #
            # No "press Enter to elevate" pause (issue #230): the UAC dialog the relaunch raises is
            # the actual consent gate.
            Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
            # Forward the caller's switches so the elevated run inherits the same intent:
            # -SkipSystemCheck so the pre-flight checks the caller explicitly bypassed are not re-run
            # (issue #185); -WhatIf as a safety net so a dry run could never escalate into changes
            # (unreachable today — a dry run never relaunches — but kept so the forwarding stays
            # correct if that ever changes). -NonInteractive is never forwarded: a non-interactive
            # run returned 4 above.
            $elevationArgs = @()
            if ($WhatIf) { $elevationArgs += '-WhatIf' }
            if ($SkipSystemCheck) { $elevationArgs += '-SkipSystemCheck' }
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

    # Who this run installs as (review findings P2-24, P3-22, P3-23), decided once: SYSTEM, as under
    # an RMM agent such as Endpoint Central, or an admin account elevating on a signed-in user's PC.
    # Either way the run installs for the whole PC only, so an app whose package has no machine-wide
    # installer is deferred instead of being installed for the wrong account. A SYSTEM run uses the
    # machine-wide winget.exe (Initialize-Winget finds it), which Resolve-WingetExecutable
    # returns from then on; a stale path from an earlier run in this session is dropped first.
    $script:MachineWingetPath = $null
    $account = Get-InstallAccountContext
    $machineWide = [bool]($account.IsSystem -or $account.IsCrossUserElevation)
    if ($account.IsSystem) {
        Write-Info 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only, with the winget.exe that App Installer installed for this PC. An app with no machine-wide installer is not installed: it is reported as Deferred, with how it can still be installed for the user. Microsoft does not support the winget command line as SYSTEM, so a SYSTEM run can fail where a run as a user would not.'
    }

    # Pending restart before the run (review finding P3-16), read before this run changes the
    # machine: the end of the run compares against it, so a restart that this run's installs need
    # (exit code 3010) is told apart from one that was already pending, which is reported but does
    # not make the run 3010 by itself. Read-only, so a dry run reports it too.
    $restartStateBefore = $null
    try {
        $restartStateBefore = Get-PendingRestartState
    }
    catch {
        Write-WarningMessage "Could not check whether a restart is pending: $_"
    }
    $restartPendingBefore = @(Get-PendingRestartReason -State $restartStateBefore)
    if ($restartPendingBefore.Count -gt 0) {
        Write-WarningMessage ('A restart is already pending on this PC ({0}). An installer that needs a restart first fails with 0x8A15010A; if one does, restart this PC and re-run the installer.' -f ($restartPendingBefore -join '; '))
    }

    # Let a Winget-AutoUpdate run that is already in progress finish first (bounded): it
    # re-provisions App Installer, resets winget's sources and runs MSI upgrades, and racing it makes
    # healthy apps fail with launch errors or 'another installation is in progress'. Read-only, but
    # skipped in a dry run so a preview never waits.
    if (-not $WhatIf) {
        [void](Wait-WauIdle)
    }

    # Make winget usable for the account this run installs as: one probe, classify, fix ladder
    # (review finding P3-25; as SYSTEM it finds the machine-wide winget.exe, P2-24). It stops the run
    # with exit code 2 when winget cannot be started or Group Policy turns it off. A dry run only
    # probes (P2-16) and carries on whatever it finds: a real run would set winget up first, so
    # stopping here would misreport the very machine a dry run previews (cross-user elevation,
    # issue #265).
    $winget = Initialize-Winget -WhatIf:$WhatIf -AccountContext $account
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable -and -not $WhatIf) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        return 2
    }

    if (-not (Test-AndInstallGraphicalTools -WhatIf:$WhatIf) -and -not $WhatIf) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Migrate away from the old homegrown scheduled-update task if a prior version installed one;
    # ongoing updates are now handled by Winget-AutoUpdate, set up after the app installs (issue #168).
    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

    # Note: earlier versions added the script's own directory (often Downloads/) to the persistent
    # User PATH here for the homegrown updater. The updater is gone (#168) and a user-writable
    # directory on the PATH of an elevating account is a hijack surface, so no PATH changes are
    # made anymore (issue #179).

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
        return 3
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
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
    # Apps with no machine-wide installer in a run for the whole PC (review finding P3-22), or that
    # the catalog marks per-user (scope 'user' or userPhase, work-order item 38): neither installed
    # nor failed, and left for the signed-in user's own account (Write-DeferredAppsSummary). The
    # two kinds are explained apart.
    $deferredApps = @()
    $noInstallerDeferredApps = @()
    $perUserDeferredApps = @()
    # Installed apps whose post-install hook could not configure them (work-order item 38): they do
    # not change the exit code, and the summary names them with the hook's reason.
    $notConfiguredApps = @()

    # No separate source-trust pass here: only the winget community source is used (every install
    # forces --source winget), and Initialize-Winget above already updated it, and repaired it if
    # needed (issues #172, #177).

    # Run-level circuit breaker (review findings P2-8, P2-10). Set once an app could not launch
    # winget and a follow-up check (Invoke-WingetLaunchCircuitBreaker) found that winget still
    # cannot be started: every remaining app then fails at once with one reason, and the retry
    # pass is skipped. Without it, each app spent its own launch retries, twice, on a winget that
    # was not coming back (about 24 minutes before the run reported failure).
    $wingetNotLaunchable = $false

    # Run-level budget for waiting on another installation (review finding P2-15): an app whose
    # install finds Windows Installer busy (0x8A150102, msiexec 1618) waits for it and retries, and
    # every wait comes out of these 10 minutes, the Winget-AutoUpdate msiexec's included. Once it
    # is spent, a busy result fails at once with its reason, so a machine that stays busy costs the
    # run 10 minutes at most rather than 10 minutes per app.
    $installerBusyWaitSecondsLeft = 600

    # Apps whose install finished but needs a restart to complete (review finding P3-16). Apps whose
    # installer cannot run until Windows restarts (0x8A15010A) are failed apps marked RestartFirst.
    $restartRequiredApps = @()

    # Each app's catalog condition is evaluated once per run, here, before this run changes the
    # machine, and both passes use that verdict (review finding P3-34). The two passes used to
    # evaluate it separately, and Set-WindowsTerminalDefaults (between them) writes the
    # default-terminal values the Windows Terminal condition reads, so an app the first pass
    # attempted could come back 'not applicable' in the retry pass and be counted as installed.
    # Fail open: a condition with no answer counts as applicable (Test-AppApplicability).
    $applicableByName = @{}
    foreach ($app in $apps) {
        $applicableByName[$app.name] = Test-AppApplicability -App $app
    }

    # One entry per app for the run's record (last-run.json and the RESULT line, review finding
    # P3-41), in catalog order; the retry pass replaces an app's entry with its final outcome. Kept
    # in $script: scope too, so a run that stops before its summary still reports the apps it had
    # finished (build/fragments/tail.ps1).
    $appRecords = [ordered]@{}
    $script:InstallerAppRecords = $appRecords

    Foreach ($app in $apps) {
        $outcome = $null
        try {
            # Shared per-app pipeline — pre-check, dispatch, post-verify (issue #188). Messages,
            # summary bucketing, and exit-code policy stay here in the orchestrator.
            # -Silent: an unattended run installs MSI packages with /quiet, not /passive.
            $outcome = Install-AppWithVerification -App $app -Applicable $applicableByName[$app.name] -Silent:$effectiveNonInteractive -WhatIf:$WhatIf -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
            if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
            }

            switch ($outcome.Status) {
                'Skipped' {
                    if ($outcome.SkipReason -eq 'NotApplicable') {
                        # Applicability-gated skip (issue #217): the app's catalog condition or arch
                        # list rules this machine out (e.g. Dell Command Update on non-Dell
                        # hardware). Same summary bucket as an already-installed skip, but the
                        # message carries the human-readable reason.
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
                    # An installed app's post-install hook ran (work-order item 38).
                    if (Write-AppPostInstallResult -AppName $app.name -Configuration $outcome.Configuration) {
                        $notConfiguredApps += @{ Name = $app.name; Reason = [string]$outcome.Configuration.Reason }
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Skipped' -Reason $skipReason -PostInstall $outcome.Configuration
                }
                'Deferred' {
                    # No machine-wide installer (review finding P3-22), or the catalog marks the app
                    # per-user (work-order item 38), and this run installs for the whole PC only.
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
                    # Only the post-install hook failed (work-order item 38): the install itself
                    # finished, so its restart and scope notes belong to this run whatever the hook
                    # does in the retry pass.
                    if ($outcome.FailureReason -eq 'PostInstallFailed' -and $outcome.StatusBeforeHook -eq 'Installed' -and (Write-InstalledAppNote -AppName $app.name -InstallResult $outcome.InstallResult)) {
                        $restartRequiredApps += $app.name
                    }
                    # Tracked as objects, not bare names, so the failed-apps summary can render a
                    # Reason column (issue #189). RestartFirst: the installer cannot run until
                    # Windows restarts (0x8A15010A), so the retry pass leaves it alone. The rest is
                    # what the retry pass needs to know about this attempt (work-order item 38).
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
                    # A scope 'machine' app (work-order item 38): the package's manifest decides
                    # this, so another try in this run would get the same answer from winget.
                    Write-WarningMessage "Not retrying ${appName}: no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine')."
                    $failedApps += $failedApp
                    continue
                }
                $outcome = $null
                try {
                    Write-Info "Retrying: $appName"
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1

                    # Same shared pipeline as the first pass (issue #188), so a lingering
                    # 0x80073d19 session error gets its backoff retries here too (issue #150), and
                    # a busy Windows Installer gets what is left of the run's wait budget.
                    # The circuit breaker holds here too: once it trips, the rest fail at once.
                    # -Applicable: the run's verdict from before the first pass, not a new one.
                    $outcome = Install-AppWithVerification -App $appDef -Applicable $applicableByName[$appName] -Silent:$effectiveNonInteractive -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
                    if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                        $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
                    }

                    # Only its post-install hook failed in the first pass (work-order item 38): the
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
                        # A first-pass hook failure ends here once the hook succeeds (work-order
                        # item 38): the retry finds the app installed and runs its hook again.
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

    # Set up ongoing automatic updates via Winget-AutoUpdate (issue #168). Best-effort: a failure
    # here never stops the run; the outcome is captured, surfaced next to the final summary instead
    # of being a scrolled-past warning (issue #186), and decides exit code 8 (review finding P3-36).
    #
    # Runs only after every winget call this run makes (the retry pass included), and WAU is no
    # longer told to start an update pass immediately (RUN_WAU=YES was removed). Every WAU SYSTEM
    # run first calls its own Install-Prerequisites, which can re-provision App Installer and reset
    # winget's sources; letting that start mid-run is what wedged winget in the #279/#284 E2E runs
    # and what killed the console in #283. WAU's own schedule takes it from here.
    try {
        $wauResult = Install-WingetAutoUpdate -WhatIf:$WhatIf -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
    }
    catch {
        Write-ErrorMessage "Winget-AutoUpdate setup failed unexpectedly: $_"
        $wauResult = [pscustomobject]@{ Status = 'Failed'; Version = $null }
    }
    # For the record of a run that stops after this point but before its summary.
    $script:InstallerAutoUpdateResult = $wauResult

    # A run must never report success while leaving winget unusable (whatever broke it, the next
    # run of this installer and every WAU update would fail). One bounded launch check, after the
    # last thing this run does to the machine; a healthy winget answers on the first try. Up to
    # five tries 15 seconds apart (about a minute) for a failure that may clear on its own, and a
    # single one when the circuit breaker already found winget unusable. Skipped in a dry run,
    # which never touched winget's state.
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

    # Does this run need a restart to finish (review finding P3-16)? An install said so, the
    # Winget-AutoUpdate MSI returned 3010, or Windows gained a pending restart during the run (for
    # example an Inno or MSI installer queued a file replacement for the next restart, which winget
    # does not report). A restart that was already pending before the run is not this run's.
    # Skipped in a dry run, which installed nothing.
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

    # -AutoGridView opens the grid view without asking (issue #230), gated on the session actually
    # being interactive so an unattended run never leaves a window open with nobody to close it.
    # The text table prints either way, so the transcript keeps the summary regardless.
    Write-Table -Headers $headers -Rows $rows -AutoGridView (-not $effectiveNonInteractive) -Title 'Installation Summary'

    # Per-app failure reasons (issue #189): winget exit code, attempt count, and scope-fallback
    # detail, so a failure is diagnosable from the summary (and the transcript) instead of a
    # generic message. No-ops when nothing failed.
    Write-FailedAppsSummary -FailedApps $failedApps

    # Why apps were deferred, and who can install them (review findings P3-22, P3-23; work-order
    # item 38 for the per-user ones). They do not change the exit code.
    Write-DeferredAppsSummary -DeferredApps $noInstallerDeferredApps -PerUserApps $perUserDeferredApps -AccountContext $account

    # Installed apps their post-install hook could not configure (work-order item 38). They do not
    # change the exit code either; a hook that failed made its app Failed above.
    Write-NotConfiguredAppsSummary -NotConfiguredApps $notConfiguredApps

    # Surface the auto-update outcome with the summary so a machine that finished without an update
    # mechanism is visible at the end of the run (issue #186). Every outcome printed as an error
    # makes the run exit 8 when no app failed and winget still works (review finding P3-36): an RMM
    # job reads only the exit code, and used to report success for a machine that would never
    # update. Configured and Already present mean the WAU task was found ready to run.
    $autoUpdatesHealthy = $true
    # The framework winget needs (work-order item 32: read from the latest winget release).
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

    # Repeat the persistent transcript path next to the summary (issue #189). The variable is set
    # by the generated installer's entry script before dispatch; it is unset (and this is skipped)
    # when the function runs outside that context (module import, tests) or the transcript could
    # not be started.
    if ($script:InstallLogPath) {
        Write-Info "Full transcript of this run: $script:InstallLogPath"
    }

    $exitCode = Get-InstallerExitCode -FailedAppCount $failedApps.Count -WingetUsable $wingetUsableAtEnd -AutoUpdatesHealthy $autoUpdatesHealthy -RestartRequired $restartRequired
    # Recorded before the final prompt: Ctrl+C there stops a run that has already finished, and
    # the entry script's abort guard then reports this code instead of an abort (5).
    $script:InstallerPendingExitCode = $exitCode

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

