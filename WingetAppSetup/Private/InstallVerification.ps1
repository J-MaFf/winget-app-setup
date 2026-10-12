<#
.SYNOPSIS
    Decides whether a catalog app applies to this machine from its arch list and its condition.
.DESCRIPTION
    The one place the applicability rule lives (issue #217). An app applies when both gates allow
    it: its arch list (compared with Get-OSArchitecture, case-insensitive; none means every
    architecture) and its condition scriptblock (falsy means it does not apply; none means it does).

    Fail open: a gate that throws or writes an error is warned about and counts as met. The worst
    case is then an install that fails loudly, where failing closed would silently skip the app and
    exit 0; so probes must throw rather than return an empty value when they cannot answer.
    Invoke-WingetInstall calls it once per app per run and gives both passes the verdict; the
    uninstaller uses it too.
.PARAMETER App
    A validated app-definition hashtable with an optional 'arch' list and 'condition' scriptblock.
.PARAMETER Purpose
    What the caller does with an app that applies, for the fail-open warning only: 'Install'
    (default) or 'Uninstall'. The rule is the same.
.OUTPUTS
    [bool] True when the app applies to this machine (or its condition could not be evaluated).
#>
function Test-AppApplicability {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Install', 'Uninstall')]
        [string]$Purpose = 'Install'
    )

    $attempt = 'attempting the install'
    if ($Purpose -eq 'Uninstall') {
        $attempt = 'attempting the uninstall'
    }
    # A non-terminating error inside a gate (a probe that wrote an error and returned nothing, as
    # Get-CimInstance does without -ErrorAction Stop) counts as no answer too, not as "does not
    # apply": the preference reaches the condition and the probes it calls.
    $ErrorActionPreference = 'Stop'

    if ($App.ContainsKey('arch') -and $null -ne $App['arch']) {
        try {
            $architecture = Get-OSArchitecture
            if (@($App['arch']) -notcontains $architecture) {
                return $false
            }
        }
        catch {
            Write-WarningMessage "Architecture check for $($App.name) failed ($($_.Exception.Message)); treating its arch list as met and $attempt."
        }
    }

    if (-not $App.condition) {
        return $true
    }
    try {
        return [bool](& $App.condition)
    }
    catch {
        Write-WarningMessage "Condition for $($App.name) failed to evaluate ($($_.Exception.Message)); treating as applicable and $attempt."
        return $true
    }
}

<#
.SYNOPSIS
    Installs a single curated app with pre-check and post-install verification, without prompting.
.DESCRIPTION
    The per-app install pipeline both passes of Invoke-WingetInstall share (issue #188):
      1. Applicability: an app that does not apply is Skipped (NotApplicable) before any winget call.
         The verdict comes in -Applicable; without it, Test-AppApplicability decides here.
      2. Pre-check (Test-WingetPackageInstalled, time-limited): installed is Skipped. A check that
         timed out, could not start winget or failed is Failed without an install attempt, since
         "could not check" is not "not installed" (issue #176, P2-9).
      3. Dispatch: the entry's own self-verifying installer ($App.install, e.g.
         Install-PowerShellLatest), or Install-WingetPackage. A winget that could not launch for the
         install is Failed (InstallLaunchFailed).
      4. Post-verify: a winget install is checked again; not found is VerifyNotFound, and a check
         that could not run says why (VerifyTimeout, VerifyLaunchFailed, VerifyFailed).
    The three launch-failure reasons are what the circuit breaker watches for.

    The catalog's fields: scope 'any' installs at machine scope with a fallback, except with
    -MachineWide; 'machine' never falls back and fails as NoMachineScopeInstaller; 'user' installs
    with --scope user. With -MachineWide, scope 'user' and userPhase are Deferred before any winget
    call. Once the app is installed, its postInstall hook runs (Complete-AppPostInstallStep).

    With -MachineWide (SYSTEM or cross-user elevation) the app is installed for the whole PC or not
    at all: no machine-scope installer means Deferred. An entry with msixName is checked by whether
    its package is provisioned for every user (Test-AppxPackageProvisionedForMachine), since
    `winget list` sees only the running account's packages.

    No prompts, no exit and no key press: messages, summary and exit code stay in
    Invoke-WingetInstall, which keeps this testable.
.PARAMETER App
    A validated catalog entry (see Get-DefaultAppCatalog for its fields).
.PARAMETER Applicable
    The run's applicability verdict for this app (Test-AppApplicability), decided once per run
    before anything is installed. $false skips the app as NotApplicable; $true installs it whatever
    its condition would say now. Not given: the condition is evaluated here.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (winget --silent), and to a package-specific installer with a
    -Silent parameter. Not given: Install-WingetPackage decides.
.PARAMETER WhatIf
    Dry run: the applicability gate and the read-only pre-check run, but nothing is installed. An
    app not installed yet reports 'Installed', so the summary shows what would change. A pre-check
    that could not start winget counts as not installed: the dry run already said winget is
    unavailable, and a real run would set it up first.
.PARAMETER WingetNotLaunchable
    The circuit breaker found that winget cannot be started: an applicable app is Failed
    ('WingetNotLaunchable') without running winget; a not-applicable one is still Skipped.
.PARAMETER MachineWide
    The run installs for the whole PC only (a run as SYSTEM or under cross-user elevation).
    Forwarded to Install-WingetPackage, and to a package-specific installer that has it, as
    -MachineScopeOnly.
.PARAMETER TimeBudgetSpent
    The run's time budget is used up (wgt-gq8.41): an app that applies, and that a run for the whole
    PC does not defer, is NotAttempted without running winget or its installer.
.PARAMETER InstallInProgressWaitSeconds
    The most the install may wait for another installation to finish (what is left of the run's
    budget). Forwarded to Install-WingetPackage, and to a package-specific installer with that
    parameter. The time waited comes back as InstallResult.InstallInProgressWaitedSeconds.
.OUTPUTS
    [hashtable] @{
        Status        = 'Installed' | 'Failed' | 'Skipped' | 'Deferred' | 'NotAttempted' (with
                        -TimeBudgetSpent)
        InstallResult = the Install-WingetPackage result hashtable, or the $App.install command's,
                        intact; $null when no installer ran (skip, dry run, pre-check timeout or
                        launch failure)
        FailureReason = $null when Status is not 'Failed'; otherwise 'PreCheckTimeout',
                        'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed',
                        'CustomInstallFailed', 'VerifyTimeout', 'VerifyLaunchFailed',
                        'VerifyFailed', 'VerifyNotFound', 'WingetNotLaunchable',
                        'MachineCheckFailed' (with -MachineWide, the provisioned packages could not
                        be read), 'NoMachineScopeInstaller' (scope 'machine', and the package has
                        no machine-scope installer) or 'PostInstallFailed' (installed, but its
                        post-install hook failed)
        LaunchError   = for the three *LaunchFailed reasons, why winget could not be started;
                        otherwise $null
        CheckExitCode = for PreCheckFailed and VerifyFailed, the exit code of the `winget list`
                        that failed; otherwise $null
        SkipReason    = 'NotApplicable' (the app does not apply); 'Provisioned' (with -MachineWide,
                        its MSIX package is already provisioned for every user); absent/$null for an
                        already-installed skip
        DeferReason   = when Status is 'Deferred', with -MachineWide: 'NoMachineScopeInstaller',
                        'UserScope' (catalog scope 'user') or 'UserPhase' (catalog userPhase)
        Configuration = the post-install hook's result, @{ Status = 'Configured' |
                        'NotConfigured' | 'Failed'; Reason }, when the hook ran; otherwise absent
        StatusBeforeHook = for PostInstallFailed, 'Installed' when this call installed the app
                        (InstallResult is that install's, which stands) or 'Skipped' when it was
                        already installed or provisioned; otherwise absent
    }
#>
function Install-AppWithVerification {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [bool]$Applicable,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$WingetNotLaunchable,

        [Parameter(Mandatory = $false)]
        [switch]$MachineWide,

        [Parameter(Mandatory = $false)]
        [switch]$TimeBudgetSpent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds
    )

    # Applicability first, before any winget call (issue #217), in both passes and dry runs. The
    # verdict comes from the caller when it has one, decided once per run before the Terminal step
    # changes HKCU, so the retry pass cannot re-decide an app the first pass attempted (P3-34).
    if ($PSBoundParameters.ContainsKey('Applicable')) {
        $isApplicable = $Applicable
    }
    else {
        $isApplicable = Test-AppApplicability -App $App
    }
    if (-not $isApplicable) {
        return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' }
    }

    # Per-user work in a run for the whole PC: scope 'user' would install into SYSTEM's or the
    # admin's profile, and userPhase needs the signed-in user's account. Deferred before any winget
    # call; the run record names the reason, for a later run as the user.
    $scope = Get-AppInstallScope -App $App
    if ($MachineWide) {
        $perUserReason = Get-AppPerUserDeferReason -App $App
        if ($perUserReason) {
            return @{ Status = 'Deferred'; InstallResult = $null; FailureReason = $null; DeferReason = $perUserReason }
        }
    }

    # The run's time budget is used up: nothing that takes time starts (no provisioning query, winget
    # call or post-install hook), and the next run does the app.
    if ($TimeBudgetSpent) {
        return @{ Status = 'NotAttempted'; InstallResult = $null; FailureReason = $null }
    }

    # An MSIX app in a run for the whole PC (review finding P3-24): whether its package is
    # provisioned for every user answers "is it installed", where `winget list` would only see the
    # account running this. Read without winget, so it is answered even when winget cannot start.
    $checkProvisioning = $MachineWide -and -not [string]::IsNullOrWhiteSpace([string]$App.msixName)
    if ($checkProvisioning) {
        $provisioned = Test-AppxPackageProvisionedForMachine -Name $App.msixName
        if ($provisioned -eq $true) {
            return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'Provisioned' } -WhatIf:$WhatIf)
        }
        if ($null -eq $provisioned -and -not $WhatIf) {
            # No answer is not "not installed" (as for `winget list`, P2-9): fail into the retry pass.
            return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'MachineCheckFailed' }
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

    $preCheck = @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    if (-not $checkProvisioning) {
        $preCheck = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    }
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
        return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null } -WhatIf:$WhatIf)
    }

    if ($WhatIf) {
        # Not installed and this is a dry run: report it as the install that would happen.
        return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } -WhatIf)
    }

    Write-Info "Installing: $($App.name)"

    if ($App.install) {
        # A package-specific installer that verifies its own install (PowerShell's DISM-provisioned
        # MSIX never shows under `winget list` for the elevating account). Dispatched by a name
        # string, which Get-UndefinedCatalogInstallReference checks at build time (issue #236).
        # It gets -Silent, the remaining wait budget, -MachineScopeOnly (whole-PC run or scope
        # 'machine') and -Scope when it takes them.
        $customParameters = @{}
        $forwardedValues = @{}
        foreach ($parameterName in @('Silent', 'InstallInProgressWaitSeconds')) {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $forwardedValues[$parameterName] = $PSBoundParameters[$parameterName]
            }
        }
        if ($MachineWide -or $scope -eq 'machine') {
            $forwardedValues['MachineScopeOnly'] = $true
        }
        if ($scope -ne 'any') {
            $forwardedValues['Scope'] = $scope
        }
        if ($forwardedValues.Count -gt 0 -and $App.install -is [string]) {
            $customCommand = Get-Command -Name $App.install -ErrorAction SilentlyContinue | Select-Object -First 1
            foreach ($parameterName in $forwardedValues.Keys) {
                if ($customCommand -and $customCommand.Parameters -and $customCommand.Parameters.ContainsKey($parameterName)) {
                    $customParameters[$parameterName] = $forwardedValues[$parameterName]
                }
            }
        }
        $customResult = & $App.install @customParameters
        if ($customResult.Installed) {
            return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $customResult; FailureReason = $null })
        }
        if ($customResult.NoMachineScopeInstaller) {
            if ($scope -eq 'machine') {
                return @{ Status = 'Failed'; InstallResult = $customResult; FailureReason = 'NoMachineScopeInstaller' }
            }
            return @{ Status = 'Deferred'; InstallResult = $customResult; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
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
    if ($MachineWide) {
        $installParameters['MachineScopeOnly'] = $true
    }
    if ($scope -ne 'any') {
        $installParameters['Scope'] = $scope
    }
    $installResult = Install-WingetPackage @installParameters
    if ($installResult.LaunchErrorExhausted) {
        # winget never started, so nothing was installed; a verify would only fail to launch too.
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'InstallLaunchFailed'; LaunchError = $installResult.LaunchError }
    }
    if ($installResult.NoMachineScopeInstaller) {
        # Nothing was installed: the package has no installer for the whole PC (review finding P3-22).
        # An entry that allows only a machine-wide install fails: a later per-user install would
        # not meet it either.
        if ($scope -eq 'machine') {
            return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'NoMachineScopeInstaller' }
        }
        return @{ Status = 'Deferred'; InstallResult = $installResult; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
    }

    if ($checkProvisioning) {
        $provisioned = Test-AppxPackageProvisionedForMachine -Name $App.msixName
        if ($provisioned -eq $true) {
            return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null })
        }
        if ($null -eq $provisioned) {
            return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'MachineCheckFailed' }
        }
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
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
        return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null })
    }
    return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
}

<#
.SYNOPSIS
    Runs an installed app's post-install hook, if it has one, and folds the result into its outcome.
.DESCRIPTION
    Without a hook the outcome is returned as it is; a dry run prints '[DRY-RUN] Would run the
    post-install configuration of <id>.' instead. Otherwise Invoke-AppPostInstall's result becomes
    Configuration. Failed turns the outcome into Failed (PostInstallFailed), so the retry pass runs
    the hook again, and keeps the earlier status in StatusBeforeHook; NotConfigured changes nothing.
.PARAMETER App
    The validated catalog entry.
.PARAMETER Outcome
    The outcome Install-AppWithVerification is about to return: Installed, or Skipped because the
    app is already installed or provisioned.
.PARAMETER WhatIf
    Dry run.
.OUTPUTS
    [hashtable] The outcome.
#>
function Complete-AppPostInstallStep {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [hashtable]$Outcome,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($null -eq $App['postInstall']) {
        return $Outcome
    }
    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would run the post-install configuration of $($App.name)."
        return $Outcome
    }
    $configuration = Invoke-AppPostInstall -App $App
    $Outcome['Configuration'] = $configuration
    if ($configuration.Status -eq 'Failed') {
        # What the install step found stays with the outcome: the retry pass reports the app
        # installed by this run (with this InstallResult, its restart included) or already there.
        $Outcome['StatusBeforeHook'] = $Outcome['Status']
        $Outcome['Status'] = 'Failed'
        $Outcome['FailureReason'] = 'PostInstallFailed'
        $Outcome['SkipReason'] = $null
    }
    return $Outcome
}

<#
.SYNOPSIS
    Invoke-WingetInstall's run-level circuit breaker: after an app could not launch winget, checks
    once whether winget can still be started.
.DESCRIPTION
    Without it every app spent its own launch retries, and the retry pass again: about 24 minutes on
    a wedged machine (P2-8, P2-10). When an outcome says winget could not launch (PreCheck-, Install-
    or VerifyLaunchFailed), one Test-WingetLaunchable decides: winget starts, and the run goes on; or
    it does not, the breaker trips, and the caller fails the remaining apps at once and skips the
    retry pass. A failure that can clear on its own gets six tries 15 seconds apart (75 seconds, for
    an App Installer update in progress, issues #253/#258); winget missing or 'Access is denied'
    trips it after one. While the Microsoft.WinGet.Client engine installs, the check is
    Test-WingetClientEngineLaunchable instead, with the same tries.
.PARAMETER Outcome
    The app's Install-AppWithVerification result.
.OUTPUTS
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

    if (Test-WingetClientEngineActive) {
        Write-WarningMessage 'The WinGet client engine could not be started for that app. Checking whether it can still be started...'
        $engineProbe = Test-WingetClientEngineLaunchable -Attempts 6 -RetryDelaySeconds 15
        if ($engineProbe.Launchable) {
            Write-Info "The WinGet client engine starts again ($($engineProbe.Version)); carrying on with the next app."
            return $false
        }
        Write-ErrorMessage "The WinGet client engine cannot be started on this machine ($($engineProbe.Reason)). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
        return $true
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
