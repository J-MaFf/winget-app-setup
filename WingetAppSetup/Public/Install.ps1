<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
.PARAMETER NonInteractive
    Suppresses the interactive extras for unattended runs (RMM, CI, scheduled tasks): the summary
    grid-view window and the final "press any key to exit". Also auto-detected when the session is
    non-interactive or stdin is redirected. No path asks a yes/no question anymore (issue #230), so
    this switch is not needed to keep a run from blocking on a prompt.
.PARAMETER SkipSystemCheck
    Pass-through of the entry script's -SkipSystemCheck switch. Used only so an elevated relaunch
    inherits the caller's intent to bypass the pre-flight system checks (issue #185); the checks
    themselves run in the entry script before this function is called.
.PARAMETER Apps
    App-definition hashtables to install. Defaults to the curated catalog returned by
    Get-DefaultAppCatalog — the single source of truth shared with winget-app-uninstall.ps1
    (issue #190). Overridable so tests (and callers) can inject a custom catalog.
.NOTES
    Exit codes: 0 = success, 1 = one or more apps failed to install, 2 = winget unavailable,
    3 = app-definition validation failed or no valid apps remain.
#>
function Invoke-WingetInstall {
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

    # Determine which PowerShell executable to use
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    # Trigger the winget source's per-user first-use bootstrap in the user context before elevating.
    # Agreements are per-user and won't carry into the elevated process. Scoped to --name winget —
    # the only source this tool installs from — so it never triggers msstore's agreement/first-use
    # handshake, which fails in non-interactive/cross-user contexts (issue #172).
    #
    # --disable-interactivity (issue #230): this used to run bare, on purpose, to surface winget's
    # agreement prompt "while we still have the normal user's identity" - and -Wait meant an
    # unattended run sat on that prompt forever. It was never load-bearing: the exit code is
    # discarded (no -PassThru), so nothing here could act on the answer either way. The agreement
    # is accepted where it actually counts - every install passes --accept-source-agreements, and
    # the elevated Initialize-WingetSourcesForUser below re-probes and bootstraps the installing
    # account via Repair-WinGetPackageManager (issue #159).
    #
    # Reuses Invoke-WingetSourceProbe (WingetBootstrap.ps1) rather than calling Start-Process
    # directly: it runs this exact command already wrapped in a timeout guard (120s default),
    # which this pre-elevation call was missing entirely. A bare `-Wait` here could block the
    # whole run forever on a corrupted/unreachable source, before elevation and before any of the
    # timeout-guarded checks later in the pipeline ever ran. The return value is intentionally
    # discarded here, same as before - this call remains best-effort.
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    if (-not $isAdmin -and (Test-IsRunningLocally)) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run winget source update --name winget to bootstrap the source in user context'
        }
        else {
            Write-Info 'Updating the winget source...'
            [void](Invoke-WingetSourceProbe)
        }
    }

    # Check if the script is run as administrator
    If (-NOT $isAdmin) {
        if (Test-IsRunningLocally) {
            # A dry run makes no system changes, so it never needs elevation. Relaunching
            # elevated here would (a) be a surprising side effect for a preview and (b) — if
            # the flag were ever dropped across the elevation boundary — silently turn a
            # dry run into a real install. Stay in the current session and continue the preview.
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                # Elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the
                # imported (or dot-sourced) module, that path is WingetAppSetup/Public/Install.ps1 —
                # a functions-only file — so the elevated window would define a function and exit
                # without installing anything (issue #185). Fail fast with guidance instead.
                if (Test-InvokedFromModuleContext -InvocationModule $MyInvocation.MyCommand.Module -CommandPath $PSCommandPath) {
                    Write-ErrorMessage 'Invoke-WingetInstall was invoked from the imported module without elevation; auto-elevation cannot relaunch a module function. Run winget-app-install.ps1, or start from an already-elevated session.'
                    return
                }
                # No "press Enter to elevate" pause (issue #230): it gated the run on a keystroke
                # without offering a decision - the relaunch happens either way, and the UAC dialog
                # the relaunch raises is the actual consent gate. Announce and go.
                Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
                # Relaunch the script with administrator privileges, forwarding the caller's
                # switches so the elevated session inherits the same intent: -SkipSystemCheck so
                # the pre-flight checks the caller explicitly bypassed are not re-run in the
                # elevated session (issue #185); the effective non-interactive state because the
                # elevated child gets a fresh console and would otherwise re-detect as interactive
                # and block on prompts; and -WhatIf as a safety net so a dry run could never
                # escalate into changes (unreachable today — a dry run never relaunches — but
                # kept so the forwarding stays correct if that ever changes).
                $elevationArgs = @()
                if ($WhatIf) { $elevationArgs += '-WhatIf' }
                if ($effectiveNonInteractive) { $elevationArgs += '-NonInteractive' }
                if ($SkipSystemCheck) { $elevationArgs += '-SkipSystemCheck' }
                Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs | Out-Null
                Exit
            }
        }
        else {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            Write-Info 'Exiting in 5 seconds...'
            Start-Sleep -Seconds 5
            Exit 1
        }
    }
    else {
        Write-Success 'Starting...'
    }

    # Ensure the WinGet PowerShell module is available before touching winget itself:
    # Test-AndInstallWinget and Initialize-WingetSourcesForUser use Repair-WinGetPackageManager
    # to bootstrap winget for accounts that have no interactive logon session (issue #159).
    if (-not (Test-AndInstallWingetModule)) {
        Write-Warning 'Microsoft.WinGet.Client module is not available. Update functionality will use fallback CLI methods.'
    }

    # Import required modules
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Success 'Successfully imported Microsoft.WinGet.Client module'
    }
    catch {
        Write-Warning "Failed to import Microsoft.WinGet.Client module: $_"
        Write-Warning 'Update functionality will use fallback CLI methods'
    }

    # Check if winget is available and install if necessary
    if (-not (Test-AndInstallWinget)) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        Exit 2
    }

    # Initialize winget sources and agreements for the account performing the installs. This is
    # what prevents 0x80073d19 when the script is elevated as a different account than the
    # logged-on user (issues #104/#150, #159).
    [void](Initialize-WingetSourcesForUser -WhatIf:$WhatIf)

    if (-not (Test-AndInstallGraphicalTools)) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Verify winget sources are accessible and auto-repair if broken
    if (-not (Test-WingetSources)) {
        Write-WarningMessage 'Winget sources could not be repaired. Some installations may fail.'
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
        Exit 3
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        Exit 3
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()

    # No separate source-trust pass here: only the winget community source is used (every install
    # forces --source winget), and its health was already verified — and repaired if needed — by
    # Test-WingetSources above (issues #172, #177).

    Foreach ($app in $apps) {
        try {
            # Shared per-app pipeline — pre-check, dispatch, post-verify (issue #188). Messages,
            # summary bucketing, and exit-code policy stay here in the orchestrator.
            $outcome = Install-AppWithVerification -App $app -WhatIf:$WhatIf

            switch ($outcome.Status) {
                'Skipped' {
                    if ($outcome.SkipReason -eq 'NotApplicable') {
                        # Applicability-gated skip (issue #217): the app's catalog condition
                        # evaluated falsy on this machine (e.g. Dell Command Update on non-Dell
                        # hardware). Same summary bucket as an already-installed skip, but the
                        # message carries the condition's human-readable reason.
                        $conditionText = if ($app.conditionDescription) { $app.conditionDescription } else { 'condition not met' }
                        Write-WarningMessage "Skipping: $($app.name) (not applicable: $conditionText)"
                    }
                    else {
                        Write-WarningMessage "Skipping: $($app.name) (already installed)"
                    }
                    $skippedApps += $app.name
                }
                'Installed' {
                    if ($WhatIf) {
                        Write-Info "[DRY-RUN] Would install: $($app.name)"
                    }
                    else {
                        Write-Success "Successfully installed: $($app.name)"
                    }
                    $installedApps += $app.name
                }
                default {
                    # Surface the diagnostic detail the install pipeline already returns (winget
                    # exit code, attempts, scope fallback) instead of discarding it (issue #189).
                    $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult
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
                    # Tracked as objects, not bare names, so the failed-apps summary can render a
                    # Reason column (issue #189).
                    $failedApps += @{ Name = $app.name; Reason = $failureReason }
                }
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += @{ Name = $app.name; Reason = "Unexpected error: $_" }
        }
    }

    # Ongoing app updates are handled by Winget-AutoUpdate (set up below), which runs as SYSTEM on a
    # schedule — not an install-time pass that upgrades every installed app synchronously as the
    # elevating admin (that was slow, silent, and largely failed under cross-user elevation; issue #170).

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    Set-WindowsTerminalDefaults -WhatIf:$WhatIf

    # Set up ongoing automatic updates via Winget-AutoUpdate (issue #168). Best-effort: a failure
    # here warns but does not fail the install; the outcome is captured and surfaced next to the
    # final summary instead of being a scrolled-past warning (issue #186).
    $wauResult = Install-WingetAutoUpdate -WhatIf:$WhatIf

    # Retry any failed installations once before producing the final summary
    if ($failedApps.Count -gt 0) {
        if (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($failedApp in $appsToRetry) {
                $appName = $failedApp.Name
                try {
                    Write-Info "Retrying: $appName"
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1

                    # Same shared pipeline as the first pass (issue #188), so a lingering
                    # 0x80073d19 session error gets its backoff retries here too (issue #150).
                    $outcome = Install-AppWithVerification -App $appDef

                    if ($outcome.Status -eq 'Failed') {
                        $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult
                        if ($outcome.FailureReason -in 'PreCheckTimeout', 'VerifyTimeout') {
                            Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                        }
                        else {
                            Write-ErrorMessage "Retry failed: $appName ($failureReason)."
                        }
                        $failedApps += @{ Name = $appName; Reason = $failureReason }
                    }
                    else {
                        # 'Installed', or 'Skipped' when the first-pass install actually landed
                        # and only its verification failed — either way the app is present now.
                        Write-Success "Retry succeeded: $appName"
                        $installedApps += $appName
                    }
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += @{ Name = $appName; Reason = "Unexpected error: $_" }
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

    # Surface the auto-update outcome with the summary so a machine that finished without an update
    # mechanism is visible at the end of the run (issue #186). Deliberately does not affect the exit
    # code: the documented 0/1/2/3 contract stays scoped to app installs and winget availability.
    switch ($wauResult.Status) {
        'Configured' { Write-Success "Auto-updates: Configured (Winget-AutoUpdate v$($wauResult.Version))." }
        'AlreadyPresent' {
            if ($wauResult.Version) {
                Write-Success "Auto-updates: Already present (v$($wauResult.Version))."
            }
            else {
                Write-WarningMessage 'Auto-updates: Already present (installed version could not be determined).'
            }
        }
        'DryRun' { Write-Info "[DRY-RUN] Auto-updates: Would configure Winget-AutoUpdate v$($wauResult.Version)." }
        default { Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.' }
    }

    # Repeat the persistent transcript path next to the summary (issue #189). The variable is set
    # by the generated installer's entry script before dispatch; it is unset (and this is skipped)
    # when the function runs outside that context (module import, tests) or the transcript could
    # not be started.
    if ($script:InstallLogPath) {
        Write-Info "Full transcript of this run: $script:InstallLogPath"
    }

    # Keep the console window open until the user presses a key. Skipped in non-interactive mode
    # so unattended runs never block (and the failure exit below stays reachable).
    if (-not $effectiveNonInteractive) {
        Write-Prompt 'Press any key to exit...'
        [void][System.Console]::ReadKey($true)
    }

    if ($failedApps.Count -gt 0) {
        Exit 1
    }
}

