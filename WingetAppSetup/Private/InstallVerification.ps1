<#
.SYNOPSIS
    Installs a single curated app with pre-check and post-install verification, without prompting.
.DESCRIPTION
    Shared per-app install pipeline used by both the first pass and the retry pass of
    Invoke-WingetInstall (issue #188). It replaces the three drifted inline Start-Process
    `winget list` verify blocks with a single implementation:

      1. Applicability: if the app declares a condition scriptblock and it evaluates falsy, the
         app is Skipped with SkipReason 'NotApplicable' BEFORE any winget probe runs — e.g.
         Dell Command Update on non-Dell hardware (issue #217). Evaluated once per call (so once
         per pass). Fail-open: a condition that throws is warned about and treated as applicable,
         because a broken probe must never silently drop an app.
      2. Pre-check: Test-WingetPackageInstalled under a timeout guard. Already installed maps to
         Skipped; a hung `winget list` maps to Failed so the app flows into the retry pass and
         the non-zero exit code instead of being silently dropped (issue #176). A winget that
         could not be started maps to Failed too (PreCheckLaunchFailed), without an install
         attempt: "could not check" is not "not installed" (review finding P2-9). So does a
         `winget list` that ran but failed (PreCheckFailed, with its exit code).
      3. Dispatch: a package-specific self-verifying installer named in $App.install (e.g.
         Install-PowerShellLatest, whose DISM-provisioned MSIX path never shows up under
         `winget list` for the elevating account), or the default Install-WingetPackage, which
         retries the transient 0x80073d19 session error with backoff (issue #150). When winget
         could not be launched for the install, the app is Failed (InstallLaunchFailed) without a
         post-verify.
      4. Post-verify: winget installs are re-checked with Test-WingetPackageInstalled; an install
         that reported success but does not show up under `winget list` is Failed, and a check
         that could not start winget says so (VerifyLaunchFailed) instead of 'package not found
         after install', and so does a check that ran but failed (VerifyFailed).

    The three launch-failure reasons are what Invoke-WingetInstall's circuit breaker
    (Invoke-WingetLaunchCircuitBreaker) watches for.

    The helper contains no prompts, no Exit, and no ReadKey — user-facing messages, summary
    bucketing, and exit-code policy stay in Invoke-WingetInstall — which is what makes the install
    pipeline unit-testable (issue #188).
.PARAMETER App
    A validated app-definition hashtable: @{ name = '<winget package id>' } with optional
    'install' (name of a self-verifying installer command), 'installerType' (winget
    --installer-type override forwarded to Install-WingetPackage), 'condition' (applicability
    scriptblock, issue #217), and 'conditionDescription' (human reason for the skip message)
    entries.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (winget --silent): Invoke-WingetInstall passes its effective
    non-interactive state. Not given: Install-WingetPackage decides. A package-specific installer
    ($App.install) gets it too when it has a -Silent parameter, as Install-PowerShellLatest does.
.PARAMETER WhatIf
    Dry run: the applicability condition and the read-only pre-check still run, but no installer
    is dispatched. An app that is not yet installed reports Status 'Installed' so the caller's
    dry-run summary shows what would change, matching the pre-#188 dry-run bucket semantics; a
    not-applicable app reports the same Skipped/'NotApplicable' result as a real run. A pre-check
    that could not start winget counts as not installed here: the dry run's own winget check has
    already said that winget is unavailable, and a real run would bootstrap it first.
.PARAMETER WingetNotLaunchable
    Invoke-WingetInstall's circuit breaker found that winget cannot be started on this machine.
    The applicability condition still runs, so a not-applicable app is still Skipped; an
    applicable app is Failed ('WingetNotLaunchable') without running winget at all.
.PARAMETER InstallInProgressWaitSeconds
    The most the install may wait for another installation to finish (review finding P2-15):
    Invoke-WingetInstall passes what is left of the run's budget. Forwarded to Install-WingetPackage,
    and to a package-specific installer that has a parameter of that name (Install-PowerShellLatest
    does). Not given: Install-WingetPackage's default. The time waited comes back in the
    InstallResult's InstallInProgressWaitedSeconds.
.RETURNS
    [hashtable] @{
        Status        = 'Installed' | 'Failed' | 'Skipped'
        InstallResult = the Install-WingetPackage result hashtable — or the $App.install command's
                        result — returned intact so exit codes can be surfaced without
                        restructuring (issue #189); $null when no installer ran (skip, dry run,
                        pre-check timeout or launch failure)
        FailureReason = $null when Status is not 'Failed'; otherwise 'PreCheckTimeout',
                        'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed',
                        'CustomInstallFailed', 'VerifyTimeout', 'VerifyLaunchFailed',
                        'VerifyFailed', 'VerifyNotFound' or 'WingetNotLaunchable', so the caller
                        can keep its per-situation message texts
        LaunchError   = for the three *LaunchFailed reasons, why winget could not be started;
                        otherwise $null
        CheckExitCode = for PreCheckFailed and VerifyFailed, the exit code of the `winget list`
                        that failed; otherwise $null
        SkipReason    = 'NotApplicable' when Status is 'Skipped' because the app's condition
                        evaluated falsy (issue #217); absent/$null for an already-installed skip,
                        so the caller can distinguish the two skip messages
    }
#>
function Install-AppWithVerification {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$WingetNotLaunchable,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds
    )

    # Applicability gate (issue #217): evaluated BEFORE any winget probe so a not-applicable app
    # (e.g. Dell Command Update on non-Dell hardware) costs nothing and cannot fail. Both the
    # first pass and the retry pass call this helper, so the gate holds everywhere -- including
    # dry runs. Fail-open on a throwing condition: warn and proceed with the install, because a
    # broken probe must never silently drop an app.
    if ($App.condition) {
        $conditionMet = $true
        $conditionEvaluated = $true
        try {
            $conditionMet = [bool](& $App.condition)
        }
        catch {
            Write-WarningMessage "Condition for $($App.name) failed to evaluate ($($_.Exception.Message)); treating as applicable."
            $conditionEvaluated = $false
        }
        if ($conditionEvaluated -and -not $conditionMet) {
            return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' }
        }
    }

    if ($WingetNotLaunchable) {
        # The run already found that winget cannot be started (Invoke-WingetInstall's circuit
        # breaker): another launch attempt per app is what made a wedged winget cost 24 minutes.
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'WingetNotLaunchable'; LaunchError = $null }
    }

    # Same 15-second guard the inlined blocks used: `winget list` can hang indefinitely on broken
    # sources or first-use prompts, and a hung check must not stall the whole install loop.
    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck

    $preCheck = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    if ($preCheck.TimedOut) {
        # Failed, not skipped: the app then flows through the retry pass, appears in the summary,
        # and drives the non-zero exit code (issue #176).
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' }
    }
    if ($preCheck.LaunchFailed -and -not $WhatIf) {
        # No answer is not "not installed" (P2-9): installing would run winget again, which just
        # failed to start, and its verify would then report an installed app as not found.
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckLaunchFailed'; LaunchError = $preCheck.LaunchError }
    }
    if ($preCheck.CheckFailed) {
        # winget ran but `winget list` failed (P2-9): no answer either. Like a timed-out check,
        # the app fails into the retry pass instead of being installed blind.
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckFailed'; CheckExitCode = $preCheck.ExitCode }
    }
    if ($preCheck.Installed) {
        return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
    }

    if ($WhatIf) {
        # Not installed and this is a dry run: report it as the install that would happen.
        return @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null }
    }

    Write-Info "Installing: $($App.name)"

    if ($App.install) {
        # Package-specific installer that performs its own verification (e.g. PowerShell, whose
        # DISM-provisioned MSIX path never shows up under `winget list` for the elevating
        # account). Trust its Installed result instead of re-checking with winget.
        #
        # This is indirect dispatch on a catalog-carried function-name string, which
        # build/Build-WingetInstallScript.ps1's AST-based undefined-reference guards cannot see
        # through a generic CommandAst walk (issue #236) - Get-UndefinedCatalogInstallReference
        # exists specifically to validate this 'install' field against the module's defined
        # functions. If AppCatalog.ps1 ever gains another string-carried function-name field
        # (e.g. 'uninstall' or 'verify') dispatched the same way, extend that guard to cover it too.
        #
        # -Silent goes to the custom installer when it takes one (Install-PowerShellLatest does), so
        # an explicit -NonInteractive installs PowerShell's MSI with /quiet like every other app. So
        # does the run's remaining wait budget for another installation (review finding P2-15).
        $customParameters = @{}
        $forwardedParameters = @()
        foreach ($parameterName in @('Silent', 'InstallInProgressWaitSeconds')) {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $forwardedParameters += $parameterName
            }
        }
        if ($forwardedParameters.Count -gt 0 -and $App.install -is [string]) {
            $customCommand = Get-Command -Name $App.install -ErrorAction SilentlyContinue | Select-Object -First 1
            foreach ($parameterName in $forwardedParameters) {
                if ($customCommand -and $customCommand.Parameters -and $customCommand.Parameters.ContainsKey($parameterName)) {
                    $customParameters[$parameterName] = $PSBoundParameters[$parameterName]
                }
            }
        }
        $customResult = & $App.install @customParameters
        if ($customResult.Installed) {
            return @{ Status = 'Installed'; InstallResult = $customResult; FailureReason = $null }
        }
        # Install-PowerShellLatest says why its own check failed (review finding P3-8), so a
        # launch failure or a timeout reads the same as for every other app.
        $customReason = 'CustomInstallFailed'
        $customLaunchError = $null
        $customCheckExitCode = $null
        if ($customResult.LaunchErrorExhausted) {
            $customReason = 'InstallLaunchFailed'
            $customLaunchError = $customResult.LaunchError
        }
        elseif ($customResult.VerifyLaunchFailed) {
            $customReason = 'VerifyLaunchFailed'
            $customLaunchError = $customResult.VerifyLaunchError
        }
        elseif ($customResult.VerifyTimedOut) {
            $customReason = 'VerifyTimeout'
        }
        elseif ($customResult.VerifyCheckFailed) {
            $customReason = 'VerifyFailed'
            $customCheckExitCode = $customResult.VerifyExitCode
        }
        return @{ Status = 'Failed'; InstallResult = $customResult; FailureReason = $customReason; LaunchError = $customLaunchError; CheckExitCode = $customCheckExitCode }
    }

    # Install through the helper so the transient 0x80073d19 session error is retried with
    # backoff (issue #150) instead of failing on the first hit.
    $installParameters = @{ PackageId = $App.name; InstallerType = $App.installerType }
    if ($PSBoundParameters.ContainsKey('Silent')) {
        $installParameters['Silent'] = $Silent
    }
    if ($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds')) {
        $installParameters['InstallInProgressWaitSeconds'] = $InstallInProgressWaitSeconds
    }
    $installResult = Install-WingetPackage @installParameters
    if ($installResult.LaunchErrorExhausted) {
        # winget never started, so nothing was installed; a verify would only fail to launch too.
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'InstallLaunchFailed'; LaunchError = $installResult.LaunchError }
    }

    $verify = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    if ($verify.TimedOut) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyTimeout' }
    }
    if ($verify.LaunchFailed) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyLaunchFailed'; LaunchError = $verify.LaunchError }
    }
    if ($verify.CheckFailed) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyFailed'; CheckExitCode = $verify.ExitCode }
    }
    if ($verify.Installed) {
        return @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null }
    }
    return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
}

<#
.SYNOPSIS
    Invoke-WingetInstall's run-level circuit breaker: after an app could not launch winget, checks
    once whether winget can still be started.
.DESCRIPTION
    Review findings P2-8 and P2-10. With winget unable to start, every app used to spend its own
    launch retries (5 launches and 75 seconds of backoff for the install, plus the pre-check and
    verify), and the retry pass then did it all again: about 24 minutes on an already provisioned
    machine before the run reported failure, and every app named as 'package not found after
    install'. A detector for one specific AppX state (two DesktopAppInstaller versions in the
    current user's view) was meant to stop that and never fired on the real wedge.

    This is the generic replacement. When an outcome says winget could not be launched
    (PreCheckLaunchFailed, InstallLaunchFailed or VerifyLaunchFailed), one Test-WingetLaunchable
    check decides: winget starts again, so the run carries on with the next app (and the failed
    app gets its retry-pass attempt), or it still cannot be started, so the breaker trips. The
    caller then fails every remaining app at once with one reason and skips the retry pass.

    A failure that can clear on its own (winget.exe locked, a timeout, a non-zero exit) gets up to
    six tries 15 seconds apart: the same 75 seconds Install-WingetPackage's launch retries cover,
    because the most common cause is an App Installer update in progress (issues #253/#258), which
    outlasts a short check. The pre-check and the post-install check do not retry a failed launch
    themselves, so this wait is all the tolerance a lock that starts at one of them gets. winget
    missing or 'Access is denied' trips the breaker after one try: waiting does not change it.
.PARAMETER Outcome
    The app's Install-AppWithVerification result.
.RETURNS
    [bool] True when the breaker tripped: winget cannot be started on this machine.
#>
function Invoke-WingetLaunchCircuitBreaker {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Outcome
    )

    if (@('PreCheckLaunchFailed', 'InstallLaunchFailed', 'VerifyLaunchFailed') -notcontains $Outcome.FailureReason) {
        return $false
    }

    Write-WarningMessage 'winget could not be launched for that app. Checking whether winget can still be started...'
    $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
    if ($probe.Launchable) {
        Write-Info "winget starts again ($($probe.Version)); carrying on with the next app."
        return $false
    }

    Write-ErrorMessage "winget cannot be launched on this machine ($($probe.Reason)). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
    return $true
}
