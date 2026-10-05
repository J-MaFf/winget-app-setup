<#
.SYNOPSIS
    Decides whether a catalog app applies to this machine from its arch list and its condition.
.DESCRIPTION
    The one place the catalog's applicability rule lives (issue #217; review findings P3-33,
    P3-34; work-order item 38). An app applies when both of its gates allow it:
      - arch: the list of OS architectures the entry is for (for example @('Arm64', 'X86')),
        compared with Get-OSArchitecture without regard to case. No list: every architecture.
      - condition: a scriptblock; a falsy result means the app does not apply. No condition: it
        applies.
    An app that does not apply is Skipped, 'not applicable' (Get-AppNotApplicableReason words it).

    Fail open: a gate that throws or writes an error - a probe that has no answer, such as a
    CIM query that failed (Get-ComputerManufacturer), or an architecture .NET cannot report - is
    warned about and counts as met, so the installer attempts the install. A broken probe must
    never silently drop an app: the worst case of failing open is an install attempt that fails
    loudly and shows in the summary and the exit code, while failing closed would skip the app and
    still exit 0. Probes must therefore throw when they cannot answer rather than return an empty
    or default value.

    Invoke-WingetInstall calls this once per app per run, before the first pass, and carries the
    verdict into the retry pass (Install-AppWithVerification -Applicable). The uninstaller decides
    with it too (Uninstall-CatalogApp, -Purpose Uninstall): an app that does not apply is not this
    tool's to remove, and one whose condition has no answer is removed, the same rule failing open.
.PARAMETER App
    A validated app-definition hashtable with an optional 'arch' list and 'condition' scriptblock.
.PARAMETER Purpose
    What the caller does with an app that applies, for the fail-open warning only: 'Install'
    (default) or 'Uninstall'. The rule is the same.
.RETURNS
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
    Shared per-app install pipeline used by both the first pass and the retry pass of
    Invoke-WingetInstall (issue #188). It replaces the three drifted inline Start-Process
    `winget list` verify blocks with a single implementation:

      1. Applicability: if the app does not apply to this machine, it is Skipped with SkipReason
         'NotApplicable' BEFORE any winget probe runs - e.g. Dell Command Update on non-Dell
         hardware (issue #217). Invoke-WingetInstall evaluates each app's condition once per run
         and passes the verdict in -Applicable, so both passes use the same answer (review
         finding P3-34); without -Applicable the condition is evaluated here, by
         Test-AppApplicability, which fails open: a condition that throws or writes an error is
         warned about and the app is treated as applicable, so a broken probe never silently
         drops an app.
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

    The catalog entry's schema fields (work-order item 38, Get-DefaultAppCatalog):
      - scope 'any' (no scope): winget installs at machine scope, falling back to its default
        scope when the package has none, unless -MachineWide. 'machine': machine scope only,
        in every run; a package with no machine-scope installer is Failed
        (NoMachineScopeInstaller), never deferred, since installing it for one account later would
        not meet the entry either. 'user': `--scope user` in a run as the signed-in user.
      - scope 'user' or userPhase, with -MachineWide: Deferred before any winget call
        (DeferReason 'UserScope' or 'UserPhase'), left for the signed-in user's own account.
      - postInstall: once the app is installed (verified after the install, already installed,
        or provisioned for every user), its hook runs (Invoke-AppPostInstall) and the outcome
        carries the result as Configuration. A hook that fails makes the app Failed
        (PostInstallFailed); NotConfigured leaves the status as it was. Not in a dry run, which
        says that it would run the hook.

    With -MachineWide (a run as SYSTEM or under cross-user elevation; review findings P3-22, P3-24)
    the app is installed for the whole PC or not at all: a package with no machine-scope installer
    comes back Deferred, left for the signed-in user's own account, instead of being installed at
    winget's default scope for the account running this. An app that names its MSIX package
    (msixName, e.g. Windows Terminal) is also checked, before and after the install, by whether that
    package is provisioned for every user on this PC (Test-AppxPackageProvisionedForMachine) instead
    of with `winget list`, which only sees what is registered for the account running it: as SYSTEM,
    nothing, so Windows Terminal, built into Windows 11, failed on every run.

    The helper contains no prompts, no Exit, and no ReadKey — user-facing messages, summary
    bucketing, and exit-code policy stay in Invoke-WingetInstall — which is what makes the install
    pipeline unit-testable (issue #188).
.PARAMETER App
    A validated app-definition hashtable: @{ name = '<winget package id>' } with optional
    'install' (name of a self-verifying installer command), 'installerType' (winget
    --installer-type override forwarded to Install-WingetPackage), 'condition' and 'arch'
    (applicability, issue #217), 'conditionDescription' (human reason for the skip message),
    'msixName', 'scope', 'userPhase' and 'postInstall' entries (Get-DefaultAppCatalog).
.PARAMETER Applicable
    The run's applicability verdict for this app (Test-AppApplicability), evaluated once per run by
    Invoke-WingetInstall before anything is installed (review finding P3-34). $false skips the app
    as NotApplicable; $true installs it whatever its condition would say now. Not given: the
    condition is evaluated here.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (winget --silent): Invoke-WingetInstall passes its effective
    non-interactive state. Not given: Install-WingetPackage decides. A package-specific installer
    ($App.install) gets it too when it has a -Silent parameter, as Install-PowerShellLatest does.
.PARAMETER WhatIf
    Dry run: the applicability gate and the read-only pre-check still run, but no installer
    is dispatched. An app that is not yet installed reports Status 'Installed' so the caller's
    dry-run summary shows what would change, matching the pre-#188 dry-run bucket semantics; a
    not-applicable app reports the same Skipped/'NotApplicable' result as a real run. A pre-check
    that could not start winget counts as not installed here: the dry run's own winget check has
    already said that winget is unavailable, and a real run would bootstrap it first.
.PARAMETER WingetNotLaunchable
    Invoke-WingetInstall's circuit breaker found that winget cannot be started on this machine.
    The applicability gate still applies, so a not-applicable app is still Skipped; an
    applicable app is Failed ('WingetNotLaunchable') without running winget at all.
.PARAMETER MachineWide
    The run installs for the whole PC only (see the description). Invoke-WingetInstall passes it for
    a run as SYSTEM or under cross-user elevation. Forwarded to Install-WingetPackage, and to a
    package-specific installer that has it, as -MachineScopeOnly.
.PARAMETER InstallInProgressWaitSeconds
    The most the install may wait for another installation to finish (review finding P2-15):
    Invoke-WingetInstall passes what is left of the run's budget. Forwarded to Install-WingetPackage,
    and to a package-specific installer that has a parameter of that name (Install-PowerShellLatest
    does). Not given: Install-WingetPackage's default. The time waited comes back in the
    InstallResult's InstallInProgressWaitedSeconds.
.RETURNS
    [hashtable] @{
        Status        = 'Installed' | 'Failed' | 'Skipped' | 'Deferred'
        InstallResult = the Install-WingetPackage result hashtable — or the $App.install command's
                        result — returned intact so exit codes can be surfaced without
                        restructuring (issue #189); $null when no installer ran (skip, dry run,
                        pre-check timeout or launch failure)
        FailureReason = $null when Status is not 'Failed'; otherwise 'PreCheckTimeout',
                        'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed',
                        'CustomInstallFailed', 'VerifyTimeout', 'VerifyLaunchFailed',
                        'VerifyFailed', 'VerifyNotFound', 'WingetNotLaunchable',
                        'MachineCheckFailed' (with -MachineWide, the provisioned packages could not
                        be read), 'NoMachineScopeInstaller' (scope 'machine', and the package has
                        no machine-scope installer) or 'PostInstallFailed' (installed, but its
                        post-install hook failed), so the caller can keep its per-situation
                        message texts
        LaunchError   = for the three *LaunchFailed reasons, why winget could not be started;
                        otherwise $null
        CheckExitCode = for PreCheckFailed and VerifyFailed, the exit code of the `winget list`
                        that failed; otherwise $null
        SkipReason    = 'NotApplicable' when Status is 'Skipped' because the app's condition
                        evaluated falsy (issue #217); 'Provisioned' when, with -MachineWide, its
                        MSIX package is already provisioned for every user; absent/$null for an
                        already-installed skip, so the caller can tell the skip messages apart
        DeferReason   = when Status is 'Deferred', with -MachineWide: 'NoMachineScopeInstaller'
                        (the package has no installer for the whole PC, review finding P3-22),
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
        [int]$InstallInProgressWaitSeconds
    )

    # Applicability gate (issue #217): checked BEFORE any winget probe so a not-applicable app
    # (e.g. Dell Command Update on non-Dell hardware) costs nothing and cannot fail. Both the
    # first pass and the retry pass call this helper, so the gate holds everywhere -- including
    # dry runs. The verdict comes from the caller when it has one: Invoke-WingetInstall evaluates
    # every condition once per run, before Set-WindowsTerminalDefaults changes HKCU, so the retry
    # pass cannot re-decide an app the first pass attempted (review finding P3-34).
    if ($PSBoundParameters.ContainsKey('Applicable')) {
        $isApplicable = $Applicable
    }
    else {
        $isApplicable = Test-AppApplicability -App $App
    }
    if (-not $isApplicable) {
        return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' }
    }

    # Per-user work in a run for the whole PC (work-order item 38): scope 'user' would install into
    # SYSTEM's or the elevating admin's profile, and userPhase marks what needs the signed-in user's
    # own account. Deferred before any winget call, as `winget list` in this account cannot see the
    # user's per-user apps either; the run record names the reason, for a later run as the user.
    $scope = Get-AppInstallScope -App $App
    if ($MachineWide) {
        $perUserReason = Get-AppPerUserDeferReason -App $App
        if ($perUserReason) {
            return @{ Status = 'Deferred'; InstallResult = $null; FailureReason = $null; DeferReason = $perUserReason }
        }
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
        # A run for the whole PC passes -MachineScopeOnly the same way (review finding P3-22), and
        # so does an entry with scope 'machine'; scope 'user' goes to one that has -Scope.
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
        # not meet it either (work-order item 38).
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
    Install-AppWithVerification calls this wherever it has found the app installed (work-order item
    38). Without a postInstall hook the outcome is returned as it is. In a dry run the hook does not
    run: '[DRY-RUN] Would run the post-install configuration of <id>.' is printed instead. Otherwise
    Invoke-AppPostInstall runs it and the outcome gets its result as Configuration; a Failed result
    turns the outcome into Status 'Failed', FailureReason 'PostInstallFailed', so the app goes into
    the retry pass (which finds it installed and runs the hook again) and the exit code, and keeps
    the status it had in StatusBeforeHook. NotConfigured leaves the status as it was.
.PARAMETER App
    The validated catalog entry.
.PARAMETER Outcome
    The outcome Install-AppWithVerification is about to return: Installed, or Skipped because the
    app is already installed or provisioned.
.PARAMETER WhatIf
    Dry run.
.RETURNS
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
