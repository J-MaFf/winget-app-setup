<#
.SYNOPSIS
    Runs every automatable item of PR #285's owner test plan on a disposable Windows test machine,
    as one command, and writes one pass/fail report plus one zip to send back (bead wgt-gq8.60).
.DESCRIPTION
    An administrator runs this on a DISPOSABLE Windows 10 22H2+ or Windows 11 test machine (a VM
    with a checkpoint, or a spare PC; internet access; signed in as an administrator). It installs
    and removes apps, sets up and removes Winget-AutoUpdate, changes %ProgramData%\winget-app-setup,
    creates a temporary local user, registers one-shot scheduled tasks and writes a folder under
    C:\Users\Public. It is NOT for a work PC.

    It drives the checkout's own files: winget-app-install.ps1, winget-app-uninstall.ps1,
    rmm\Invoke-WingetAppSetup.ps1, the e2e helpers and the WingetAppSetup module (for the catalog's
    applicability). It STARTS under Windows PowerShell 5.1, which a fresh PC has (the file is 5.1-safe
    and ASCII only, like the rmm scripts); the first install pass installs PowerShell 7, and the
    pieces that need it run in a child pwsh.

    The run has a safety gate (it refuses unless elevated and unless the operator confirms the
    machine is disposable), a set of stages run in order, and a report at the end. Each stage records
    named PASS/FAIL/SKIP rows with evidence; a failing stage does not stop a later independent stage,
    and cleanup always runs. -WhatIf (or -Plan) prints the plan and changes nothing.

    Stages (0 Preflight, 1 LinkGuardSetup, 2 FirstRun, 3 ReRun, 4 System, 5 WinGetClient, 6
    TimeBudget, 7 Diagnostics, 8 Uninstaller, 9 Report), what each checks and the plan item it maps
    to, are in Get-RealPcTestPlanStage. The evaluation of each stage's checks, the stage selection
    and dependency logic, the ACL/SDDL comparison, the report and the exit-code logic are functions
    that read only what they are given, so tests/E2ERealPcTestPlan.Tests.ps1 runs them on any OS; the
    install, scheduled-task and ACL-reading work needs Windows. Dot-sourcing this file defines the
    functions and runs nothing (the main block is guarded), the way the other e2e scripts are loaded
    by their tests.

    Never prints or stores a real secret. The temporary standard user's password is random, never
    printed and never written to disk. One exception: a random TightVNC test password (for item 5's
    configuration half) is written only into the report folder's manual-steps file, clearly labelled
    as a throwaway for this test machine, so the operator can connect a viewer; the Diagnostics stage
    checks that the bundle does not contain it or the temporary user's name.
.PARAMETER Stage
    Run only these stages (by name; Preflight and Report always run). Their dependencies are added
    and the additions are explained. Default: every stage.
.PARAMETER SkipStage
    Skip these stages. A stage other stages depend on cannot be skipped while they run; the refusal
    names it. Preflight and Report cannot be skipped.
.PARAMETER TimeoutMinutes
    A per-stage time limit for the install passes it bounds (the installer's own -MaxRuntimeMinutes
    is used, so a stage that overruns ends with its own report). Default 60.
.PARAMETER ReportPath
    The report folder. Default: %PUBLIC%\winget-app-setup-testplan-<yyyyMMdd-HHmmss>.
.PARAMETER UseOneLiner
    Run the installer as 'irm <raw branch URL> | iex' (the production one-liner) instead of the
    checkout's file, for the install stages.
.PARAMETER Branch
    The branch the one-liner fetches from. Default: claude/trusting-dirac-foyiaa.
.PARAMETER IncludeWinGetClient
    Also run stage 5 (the SYSTEM pass with -SystemInstallEngine WinGetClient). Off by default.
.PARAMETER ResetProgramData
    When %ProgramData%\winget-app-setup already exists, rename it aside (never delete) so stage 1 can
    run the link guard on a fresh folder. Without it, a non-fresh machine skips stage 1 and warns.
.PARAMETER ConfirmDisposableMachine
    Confirm, without the interactive prompt, that this is a disposable test machine (for unattended
    use). Without it, the run asks the operator to type a phrase.
.PARAMETER WhatIf
    Print the plan (what would change) and change nothing. Same as -Plan.
.PARAMETER Plan
    Alias of -WhatIf.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\e2e\Invoke-RealPcTestPlan.ps1 -WhatIf
    Prints the plan and changes nothing.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\e2e\Invoke-RealPcTestPlan.ps1 -ConfirmDisposableMachine
    Runs the whole plan unattended and writes the report and zip.
.EXAMPLE
    .\e2e\Invoke-RealPcTestPlan.ps1 -Stage FirstRun, Uninstaller -ConfirmDisposableMachine
    Runs only the first-run and uninstaller stages (and their dependencies, explained on screen).
.NOTES
    Exit codes: 0 = every non-skipped row passed; 1 = at least one row failed; 2 = refused (not
    elevated, or not confirmed disposable). Runs under Windows PowerShell 5.1 and PowerShell 7: ASCII
    only, no PowerShell-7-only syntax.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string[]]$Stage,

    [Parameter(Mandatory = $false)]
    [string[]]$SkipStage,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 60,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath,

    [Parameter(Mandatory = $false)]
    [switch]$UseOneLiner,

    [Parameter(Mandatory = $false)]
    [string]$Branch = 'claude/trusting-dirac-foyiaa',

    [Parameter(Mandatory = $false)]
    [switch]$IncludeWinGetClient,

    [Parameter(Mandatory = $false)]
    [switch]$ResetProgramData,

    [Parameter(Mandatory = $false)]
    [switch]$ConfirmDisposableMachine,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$Plan
)

$script:DisposableConfirmationPhrase = 'yes destroy this machine'

# Reuse the e2e SYSTEM-pass helpers (which dot-source Invoke-InstallPass.ps1 and
# TranscriptAssertions.ps1): Get-InstallPassVerdict and the transcript parser for the install
# checks, and Get-SystemPassAppExpectation, Invoke-SystemPassTask and Get-SystemInstallPassResult
# for the SYSTEM stages. Their param blocks bind their own defaults into this scope on dot-source
# (the guarded main blocks do not run), and one name, TimeoutMinutes, collides with this script's,
# so capture it first.
$script:StageTimeoutMinutes = $TimeoutMinutes
. (Join-Path $PSScriptRoot 'Invoke-SystemInstallPass.ps1')

# ======================================================================================
# Stage registry and selection (pure)
# ======================================================================================

<#
.SYNOPSIS
    The ordered stage registry: each stage's name, number, one-line summary, the plan item it maps
    to, its dependencies, and whether it always runs or is optional.
.DESCRIPTION
    DependsOn names the stages that must run before this one for its checks to mean anything.
    AlwaysRun stages (Preflight, Report) cannot be skipped and are always included. Optional is set
    for a stage that only runs when asked (WinGetClient, by -IncludeWinGetClient).
.RETURNS
    [pscustomobject[]] in run order, with Name, Number, Summary, Item, DependsOn ([string[]]),
    AlwaysRun ([bool]) and Optional ([bool]).
#>
function Get-RealPcTestPlanStage {
    return @(
        [pscustomobject]@{ Name = 'Preflight'; Number = 0; Item = '0'; AlwaysRun = $true; Optional = $false; DependsOn = @(); Summary = 'admin, OS, PowerShell, internet, winget, disk, existing ProgramData' }
        [pscustomobject]@{ Name = 'LinkGuardSetup'; Number = 1; Item = '11'; AlwaysRun = $false; Optional = $false; DependsOn = @('Preflight'); Summary = 'plant a junction at ProgramData\winget-app-setup as a temporary standard user (only when the folder does not exist)' }
        [pscustomobject]@{ Name = 'FirstRun'; Number = 2; Item = '1+4+5+11'; AlwaysRun = $false; Optional = $false; DependsOn = @('Preflight', 'LinkGuardSetup'); Summary = 'first unattended install; verify apps, WAU, runtime, TightVNC and the link guard' }
        [pscustomobject]@{ Name = 'ReRun'; Number = 3; Item = '2'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); Summary = 're-run: everything already installed, nothing reinstalled' }
        [pscustomobject]@{ Name = 'System'; Number = 4; Item = '3'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); Summary = 'SYSTEM run through the Endpoint Central machine-phase wrapper' }
        [pscustomobject]@{ Name = 'WinGetClient'; Number = 5; Item = '10'; AlwaysRun = $false; Optional = $true; DependsOn = @('FirstRun'); Summary = 'SYSTEM run with the Microsoft.WinGet.Client engine (opt-in)' }
        [pscustomobject]@{ Name = 'TimeBudget'; Number = 6; Item = '8'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); Summary = 'uninstall one app, run with a spent budget (exit 9), then finish (exit 0/3010)' }
        [pscustomobject]@{ Name = 'Diagnostics'; Number = 7; Item = '6'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); Summary = '-CollectDiagnostics bundle; verify entries and no secret leak' }
        [pscustomobject]@{ Name = 'Uninstaller'; Number = 8; Item = '9'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); Summary = 'uninstaller -WhatIf, then a real elevated uninstall' }
        [pscustomobject]@{ Name = 'Report'; Number = 9; Item = '-'; AlwaysRun = $true; Optional = $false; DependsOn = @(); Summary = 'write report.md and report.txt and the zip to send back' }
    )
}

<#
.SYNOPSIS
    Resolves which stages run, in order, from -Stage, -SkipStage and -IncludeWinGetClient, adding any
    dependencies a requested stage needs and explaining the additions and the skips.
.DESCRIPTION
    With no -Stage, every stage runs except the optional ones that were not asked for. With -Stage,
    only those stages (plus the always-run ones and the dependencies they pull in) run. -SkipStage
    removes a stage, unless a stage that still runs depends on it; then it is refused and kept. An
    unknown name in either list is refused. The result is in the registry's order.
.PARAMETER Requested
    The -Stage value, or empty for all.
.PARAMETER Skip
    The -SkipStage value.
.PARAMETER IncludeOptional
    The optional stages to include (e.g. 'WinGetClient' for -IncludeWinGetClient).
.PARAMETER Registry
    The stage registry. Default: Get-RealPcTestPlanStage.
.RETURNS
    [pscustomobject] with Stages (the stages to run, in order), Explanations ([string[]], why a
    dependency was added or a skip refused) and Errors ([string[]], an unknown name; empty when the
    selection is valid).
#>
function Resolve-RealPcTestPlanStage {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Requested = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Skip = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$IncludeOptional = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Registry
    )

    if ($null -eq $Registry) {
        $Registry = Get-RealPcTestPlanStage
    }
    $byName = @{}
    foreach ($entry in $Registry) {
        $byName[$entry.Name] = $entry
    }
    $order = @($Registry | ForEach-Object { $_.Name })

    $explanations = @()
    $errors = @()
    $requested = @($Requested | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $skip = @($Skip | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $includeOptional = @($IncludeOptional | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($name in @($requested + $skip + $includeOptional)) {
        if (-not $byName.ContainsKey($name)) {
            $errors += "unknown stage '$name'; valid stages: $($order -join ', ')"
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ Stages = @(); Explanations = $explanations; Errors = $errors }
    }

    # The set to run: always-run stages; then either every non-optional stage (no -Stage) or the
    # requested stages; then the optional stages asked for.
    $selected = New-Object System.Collections.Generic.HashSet[string]
    foreach ($entry in $Registry) {
        if ($entry.AlwaysRun) {
            [void]$selected.Add($entry.Name)
        }
    }
    if ($requested.Count -eq 0) {
        foreach ($entry in $Registry) {
            if (-not $entry.Optional) {
                [void]$selected.Add($entry.Name)
            }
        }
    }
    else {
        foreach ($name in $requested) {
            [void]$selected.Add($name)
        }
    }
    foreach ($name in $includeOptional) {
        [void]$selected.Add($name)
    }

    # Pull in dependencies, repeatedly, so a dependency's dependency is added too.
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($name in @($selected)) {
            foreach ($dependency in $byName[$name].DependsOn) {
                if (-not $selected.Contains($dependency)) {
                    [void]$selected.Add($dependency)
                    $changed = $true
                    if ($requested.Count -gt 0 -and $requested -notcontains $dependency) {
                        $explanations += "Added '$dependency': '$name' depends on it."
                    }
                }
            }
        }
    }

    # LinkGuardSetup only makes sense with FirstRun (it verifies the guard). Keep them together.
    foreach ($name in $skip) {
        $entry = $byName[$name]
        if ($entry.AlwaysRun) {
            $explanations += "Cannot skip '$name': it always runs."
            continue
        }
        if (-not $selected.Contains($name)) {
            continue
        }
        $neededBy = @($selected | Where-Object { $_ -ne $name -and $byName[$_].DependsOn -contains $name })
        if ($neededBy.Count -gt 0) {
            $explanations += "Cannot skip '$name': $($neededBy -join ', ') depend(s) on it. It stays."
            continue
        }
        [void]$selected.Remove($name)
    }

    $stages = @($Registry | Where-Object { $selected.Contains($_.Name) })
    return [pscustomobject]@{ Stages = $stages; Explanations = $explanations; Errors = @() }
}

# ======================================================================================
# Result rows and stage accumulation (pure)
# ======================================================================================

<#
.SYNOPSIS
    One result row: a named check with PASS, FAIL or SKIP and a line of evidence.
.RETURNS
    [pscustomobject] with Check, Result ('PASS', 'FAIL' or 'SKIP') and Detail.
#>
function New-TestPlanRow {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'FAIL', 'SKIP')]
        [string]$Result,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Detail = ''
    )

    return [pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail }
}

<#
.SYNOPSIS
    A row from a boolean: PASS when Passed, otherwise FAIL.
#>
function New-TestPlanBoolRow {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Detail = ''
    )

    $result = 'FAIL'
    if ($Passed) {
        $result = 'PASS'
    }
    return (New-TestPlanRow -Check $Check -Result $result -Detail $Detail)
}

# ======================================================================================
# Install-run check evaluation (pure): items 1, 4, 5 and the re-run (item 2)
# ======================================================================================

<#
.SYNOPSIS
    Accepts a first-run install exit code: 0, 3010, or 8 with a stated reason; anything else is a
    failure.
.DESCRIPTION
    Uses the e2e install-pass policy (Get-InstallPassVerdict from e2e/Invoke-InstallPass.ps1, which
    this script dot-sources). 8 is accepted only when the pass's transcript gives the missing
    Microsoft.WindowsAppRuntime.1.8 as the reason and the installer could not try to install it.
.PARAMETER ExitCode
    The installer's exit code.
.PARAMETER Transcript
    The run's transcript (Get-InstallPassTranscript result: Name and Parsed), or $null.
.PARAMETER Pass
    'first', 'second' or 'budget', for the message.
.RETURNS
    [pscustomobject] with Passed ([bool]), Outcome ('passed', 'failed') and Message.
#>
function Get-RealPcInstallExitVerdict {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,

        [Parameter(Mandatory = $false)]
        [string]$Pass = 'first'
    )

    $verdict = Get-InstallPassVerdict -ExitCode $ExitCode -KnownPlatformIncompatible '' -Pass $Pass -Transcript $Transcript
    return [pscustomobject]@{ Passed = ($verdict.Outcome -eq 'passed'); Outcome = $verdict.Outcome; Message = $verdict.Message }
}

<#
.SYNOPSIS
    Checks a run record (last-run.json, parsed): schema 1, the run reached its summary, the recorded
    exit code matches, and no app is Failed.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER ExpectedExitCode
    The exit code the process returned, to compare with the record's. $null skips that comparison.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcRunRecordResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExpectedExitCode
    )

    if ($null -eq $RunRecord) {
        return @(New-TestPlanRow -Check 'last-run.json written' -Result 'FAIL' -Detail 'no last-run.json for this run')
    }
    $rows = @()
    $schemaOk = "$($RunRecord.schemaVersion)" -eq '1'
    $rows += New-TestPlanBoolRow -Check 'last-run.json schema 1' -Passed $schemaOk -Detail "schemaVersion '$($RunRecord.schemaVersion)'"
    $rows += New-TestPlanBoolRow -Check 'Run reached its summary' -Passed ([bool]$RunRecord.summaryReached) -Detail "summaryReached $($RunRecord.summaryReached)"

    $exitDetail = "last-run.json exitCode $($RunRecord.exitCode)"
    $exitOk = $null -ne $RunRecord.exitCode
    if ($null -ne $ExpectedExitCode) {
        $exitOk = $exitOk -and ([int]$RunRecord.exitCode -eq [int]$ExpectedExitCode)
        $exitDetail += ", process exit $ExpectedExitCode"
    }
    $rows += New-TestPlanBoolRow -Check 'last-run.json records the exit code' -Passed $exitOk -Detail $exitDetail

    $failed = @($RunRecord.apps | Where-Object { $null -ne $_ -and [string]$_.status -eq 'Failed' } | ForEach-Object { [string]$_.id })
    $failedDetail = 'no app failed'
    if ($failed.Count -gt 0) {
        $failedDetail = "failed: $($failed -join ', ')"
    }
    $rows += New-TestPlanBoolRow -Check 'No app failed' -Passed ($failed.Count -eq 0) -Detail $failedDetail
    return $rows
}

<#
.SYNOPSIS
    Checks each catalog app's entry in last-run.json for an elevated same-user first run: an app that
    applies is Installed or Skipped (already installed/provisioned); one that does not apply is
    Skipped with its not-applicable reason; a per-user app is Deferred only under cross-user
    elevation, which this run is not, so here every applicable app must be Installed or Skipped.
.DESCRIPTION
    The expectations come from Get-SystemPassAppExpectation (e2e/Invoke-SystemInstallPass.ps1) with
    the applicability decided for this PC, but without -MachineWide semantics; the caller passes the
    expectations it built. This evaluator compares last-run.json's entries with them.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result (Id, Expected, Reason, AlreadyPresentReasons).
.RETURNS
    Assertion rows (New-TestPlanRow): one per catalog app.
#>
function Get-RealPcAppResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation
    )

    if ($null -eq $RunRecord -or $null -eq $RunRecord.apps) {
        return @(New-TestPlanRow -Check 'Catalog apps recorded' -Result 'FAIL' -Detail 'no apps list in last-run.json')
    }
    if ($null -eq $AppExpectation) {
        return @(New-TestPlanRow -Check 'Catalog apps recorded' -Result 'FAIL' -Detail 'no catalog expectations to check against')
    }
    $entries = @($RunRecord.apps | Where-Object { $null -ne $_ })
    $rows = @()
    foreach ($expectation in $AppExpectation) {
        $id = [string]$expectation.Id
        $matching = @($entries | Where-Object { [string]$_.id -eq $id })
        if ($matching.Count -ne 1) {
            $rows += New-TestPlanRow -Check "App recorded: $id" -Result 'FAIL' -Detail "$($matching.Count) entries in last-run.json"
            continue
        }
        $entry = $matching[0]
        $status = [string]$entry.status
        $reason = [string]$entry.reason
        $detail = $status
        if ($reason) {
            $detail += " ($reason)"
        }
        if ($expectation.Expected -eq 'NotApplicable') {
            $passed = ($status -eq 'Skipped' -and $reason -eq $expectation.Reason)
            $rows += New-TestPlanBoolRow -Check "App not applicable, skipped: $id" -Passed $passed -Detail $detail
        }
        elseif ($expectation.Expected -eq 'Deferred') {
            $passed = ($status -eq 'Deferred' -and $reason -eq $expectation.Reason)
            $rows += New-TestPlanBoolRow -Check "App deferred to the user: $id" -Passed $passed -Detail $detail
        }
        else {
            # Installed, or already present (tolerant of an app the machine already had, so the
            # self-test runner's preinstalled Chrome/7-Zip/Git do not fail this stage): any skip
            # reason that says 'already'. A per-user Deferred, Failed or NotAttempted does not pass.
            $passed = ($status -eq 'Installed') -or ($status -eq 'Skipped' -and [string]$reason -match '(?i)already')
            $rows += New-TestPlanBoolRow -Check "App installed or present: $id" -Passed $passed -Detail $detail
        }
    }
    return $rows
}

<#
.SYNOPSIS
    Checks the auto-update, Windows App Runtime and TightVNC outcomes a first run must show.
.DESCRIPTION
    Auto-updates Configured (or Already present); the Windows App Runtime installed once or already
    there; Winget-AutoUpdate task present, enabled and with a trigger and no at-logon trigger (from
    WauTaskHealth the caller read on Windows); the Windows App Runtime present now (from the caller);
    and TightVNC's post-install Configured (when a TightVNC password was supplied).
.PARAMETER Transcript
    The run's transcript (Name, Parsed).
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER WauTaskHealth
    Get-WauTaskHealth-shaped object the caller read (Exists, Healthy, Triggers, Problem), or $null
    off Windows / when not read.
.PARAMETER WindowsAppRuntimePresent
    Whether the framework is present now (Get-WindowsAppRuntimeStatus.Present), $null when unknown.
.PARAMETER ExpectTightVncConfigured
    A TightVNC password was supplied, so its post-install must be Configured.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcAutoUpdateResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $WauTaskHealth,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WindowsAppRuntimePresent,

        [Parameter(Mandatory = $false)]
        [switch]$ExpectTightVncConfigured
    )

    $rows = @()
    $auStatus = $null
    if ($Transcript) {
        $auStatus = $Transcript.Parsed.AutoUpdatesStatus
    }
    $rows += New-TestPlanBoolRow -Check 'Auto-updates configured' -Passed (@('Configured', 'Already present') -contains $auStatus) -Detail "Auto-updates: $auStatus"

    if ($null -ne $WindowsAppRuntimePresent) {
        $rows += New-TestPlanBoolRow -Check 'Windows App Runtime present' -Passed ([bool]$WindowsAppRuntimePresent) -Detail "present: $WindowsAppRuntimePresent"
    }

    if ($null -ne $WauTaskHealth) {
        $triggerText = 'no triggers'
        if (@($WauTaskHealth.Triggers).Count -gt 0) {
            $triggerText = @($WauTaskHealth.Triggers) -join '; '
        }
        $logonTrigger = @($WauTaskHealth.Triggers | Where-Object { "$_" -match '(?i)logon' })
        $healthy = [bool]$WauTaskHealth.Exists -and [bool]$WauTaskHealth.Healthy -and $logonTrigger.Count -eq 0
        $detail = "exists $($WauTaskHealth.Exists), healthy $($WauTaskHealth.Healthy); triggers: $triggerText"
        if ($logonTrigger.Count -gt 0) {
            $detail += '; has an at-logon trigger, which the installer must remove'
        }
        $rows += New-TestPlanBoolRow -Check 'WAU task present, enabled, with a trigger and no at-logon trigger' -Passed $healthy -Detail $detail
    }

    if ($ExpectTightVncConfigured -and $null -ne $RunRecord) {
        $tightVnc = @($RunRecord.apps | Where-Object { [string]$_.id -eq 'GlavSoft.TightVNC' }) | Select-Object -First 1
        $postInstall = $null
        if ($tightVnc) {
            $postInstall = [string]$tightVnc.postInstall
        }
        $rows += New-TestPlanBoolRow -Check 'TightVNC post-install Configured' -Passed ($postInstall -eq 'Configured') -Detail "postInstall: $postInstall"
    }
    return $rows
}

<#
.SYNOPSIS
    Checks a re-run (item 2): exit 0 (or 3010 if a restart is pending), every applicable app Skipped
    as already installed or provisioned, no 'Windows App Runtime: installed' line, and WAU already
    present.
.PARAMETER ExitCode
    The re-run's exit code.
.PARAMETER Transcript
    The re-run's transcript (Name, Parsed).
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result, with -AlreadyPresent: every app the first run installed
    must now be Skipped as already there.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcReRunResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation
    )

    $rows = @()
    $rows += New-TestPlanBoolRow -Check 'Re-run exit code 0 or 3010' -Passed (@(0, 3010) -contains $ExitCode) -Detail "exit $ExitCode"

    if ($null -ne $RunRecord -and $null -ne $AppExpectation) {
        foreach ($expectation in $AppExpectation) {
            $id = [string]$expectation.Id
            $matching = @($RunRecord.apps | Where-Object { [string]$_.id -eq $id }) | Select-Object -First 1
            $status = ''
            $reason = ''
            if ($matching) {
                $status = [string]$matching.status
                $reason = [string]$matching.reason
            }
            $detail = "$status"
            if ($reason) {
                $detail += " ($reason)"
            }
            if ($expectation.Expected -eq 'AlreadyPresent') {
                $passed = ($status -eq 'Skipped' -and [string]$reason -match '(?i)already')
                $rows += New-TestPlanBoolRow -Check "Re-run skipped as present: $id" -Passed $passed -Detail $detail
            }
            elseif ($expectation.Expected -eq 'NotApplicable') {
                $passed = ($status -eq 'Skipped' -and $reason -eq $expectation.Reason)
                $rows += New-TestPlanBoolRow -Check "Re-run not applicable: $id" -Passed $passed -Detail $detail
            }
        }
    }

    if ($Transcript) {
        $rows += New-TestPlanBoolRow -Check 'Re-run did not install the Windows App Runtime again' -Passed (-not $Transcript.Parsed.WindowsAppRuntimeInstalled) -Detail $(if ($Transcript.Parsed.WindowsAppRuntimeInstalled) { "Windows App Runtime: $($Transcript.Parsed.WindowsAppRuntimeLine)" } else { 'no install line' })
        $auLine = $Transcript.Parsed.AutoUpdatesLine
        $rows += New-TestPlanBoolRow -Check 'Re-run WAU already present' -Passed ($Transcript.Parsed.AutoUpdatesStatus -eq 'Already present') -Detail "Auto-updates: $auLine"
    }
    return $rows
}

# ======================================================================================
# Time budget (item 8), diagnostics (item 6), uninstaller (item 9) (pure)
# ======================================================================================

<#
.SYNOPSIS
    Checks the spent-budget half of item 8: exit 9, the named app NotAttempted in last-run.json, and
    notattempted at least 1 in the RESULT line.
.PARAMETER ExitCode
    The budgeted run's exit code.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER ResultLine
    The RESULT line text (the installer's 'RESULT: ...'), or empty.
.PARAMETER AppId
    The app uninstalled first and expected NotAttempted. Default 7zip.7zip.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcTimeBudgetSpentResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ResultLine,

        [Parameter(Mandatory = $false)]
        [string]$AppId = '7zip.7zip'
    )

    $rows = @()
    $rows += New-TestPlanBoolRow -Check 'Spent-budget run exits 9' -Passed ($ExitCode -eq 9) -Detail "exit $ExitCode"

    $status = ''
    if ($null -ne $RunRecord) {
        $entry = @($RunRecord.apps | Where-Object { [string]$_.id -eq $AppId }) | Select-Object -First 1
        if ($entry) {
            $status = [string]$entry.status
        }
    }
    $rows += New-TestPlanBoolRow -Check "$AppId not attempted" -Passed ($status -eq 'NotAttempted') -Detail "status: $status"

    $notAttempted = $null
    if ($ResultLine -match 'notattempted=(\d+)') {
        $notAttempted = [int]$Matches[1]
    }
    $rows += New-TestPlanBoolRow -Check 'RESULT line notattempted >= 1' -Passed ($null -ne $notAttempted -and $notAttempted -ge 1) -Detail "notattempted=$notAttempted"
    return $rows
}

<#
.SYNOPSIS
    Checks the finish half of item 8: the next run (no budget) installs the app and exits 0 or 3010.
.PARAMETER ExitCode
    The unbudgeted run's exit code.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER AppId
    The app that must now be Installed. Default 7zip.7zip.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcTimeBudgetFinishResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [string]$AppId = '7zip.7zip'
    )

    $rows = @()
    $rows += New-TestPlanBoolRow -Check 'Finish run exits 0 or 3010' -Passed (@(0, 3010) -contains $ExitCode) -Detail "exit $ExitCode"
    $status = ''
    if ($null -ne $RunRecord) {
        $entry = @($RunRecord.apps | Where-Object { [string]$_.id -eq $AppId }) | Select-Object -First 1
        if ($entry) {
            $status = [string]$entry.status
        }
    }
    $rows += New-TestPlanBoolRow -Check "$AppId installed on the finish run" -Passed ($status -eq 'Installed') -Detail "status: $status"
    return $rows
}

<#
.SYNOPSIS
    The entries a diagnostics bundle must contain (item 6).
.RETURNS
    [string[]] file names, and 'logs/' for the logs folder prefix.
#>
function Get-RealPcExpectedDiagnosticsEntry {
    return @('README.txt', 'system.txt', 'winget.txt', 'appx.txt', 'wau-updates-log-tail.txt', 'logs/')
}

<#
.SYNOPSIS
    Checks a diagnostics bundle (item 6): the expected entries are present, and no entry contains a
    secret (the TightVNC test password) or the temporary user's name.
.PARAMETER EntryName
    The names of the entries in the zip (a 'logs/' entry is matched as a prefix).
.PARAMETER EntryText
    A map of entry name to its text, for the secret scan.
.PARAMETER Secret
    The strings that must not appear (the TightVNC test password, the temporary user's name).
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcDiagnosticsResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$EntryName = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$EntryText = @{},

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Secret = @()
    )

    $rows = @()
    foreach ($expected in Get-RealPcExpectedDiagnosticsEntry) {
        if ($expected.EndsWith('/')) {
            $present = @($EntryName | Where-Object { $_ -like "$expected*" }).Count -gt 0
            $rows += New-TestPlanBoolRow -Check "Bundle has a $expected folder" -Passed $present -Detail $(if ($present) { 'present' } else { 'missing' })
        }
        else {
            $present = $EntryName -contains $expected
            $rows += New-TestPlanBoolRow -Check "Bundle has $expected" -Passed $present -Detail $(if ($present) { 'present' } else { 'missing' })
        }
    }

    $leak = Get-RealPcSecretLeak -Entry $EntryText -Secret $Secret
    $leakDetail = 'no secret found in any bundle file'
    if ($leak.Count -gt 0) {
        $leakDetail = 'LEAK: ' + ($leak -join '; ')
    }
    $rows += New-TestPlanBoolRow -Check 'Bundle contains no secret or temporary user name' -Passed ($leak.Count -eq 0) -Detail $leakDetail
    return $rows
}

<#
.SYNOPSIS
    Scans text entries for any of the given secrets, case-insensitively.
.PARAMETER Entry
    A map of name to text.
.PARAMETER Secret
    The strings that must not appear; empty and whitespace-only ones are ignored.
.RETURNS
    [string[]] '<name>: <secret>' for each entry that contains a secret; empty when none do.
#>
function Get-RealPcSecretLeak {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$Entry = @{},

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Secret = @()
    )

    $secrets = @($Secret | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $leaks = @()
    if ($null -eq $Entry) {
        return $leaks
    }
    foreach ($name in @($Entry.Keys)) {
        $text = [string]$Entry[$name]
        if ([string]::IsNullOrEmpty($text)) {
            continue
        }
        $lower = $text.ToLowerInvariant()
        foreach ($secret in $secrets) {
            if ($lower.Contains($secret.ToLowerInvariant())) {
                $leaks += "$name contains '$secret'"
            }
        }
    }
    return $leaks
}

<#
.SYNOPSIS
    Checks the uninstaller (item 9).
.DESCRIPTION
    Two halves: the -WhatIf preview changed nothing (the catalog app count and the WAU task are the
    same before and after), and a real elevated uninstall exited 0 or 3010, removed the catalog apps
    except the ones the uninstaller keeps on purpose (PowerShell 7 and Windows Terminal), and removed
    Winget-AutoUpdate (its task is gone).
.PARAMETER WhatIfInstalledBefore
    The catalog ids winget listed as installed before the -WhatIf preview.
.PARAMETER WhatIfInstalledAfter
    The catalog ids winget listed as installed after the -WhatIf preview (must equal the before set).
.PARAMETER WhatIfWauBefore
    Whether the WAU task existed before the preview.
.PARAMETER WhatIfWauAfter
    Whether the WAU task existed after the preview (must equal the before value).
.PARAMETER ExitCode
    The real uninstall's exit code.
.PARAMETER InstalledAfter
    The catalog ids still installed after the real uninstall.
.PARAMETER KeptIds
    The catalog ids the uninstaller keeps on purpose (PowerShell 7, Windows Terminal).
.PARAMETER WauPresentAfter
    Whether the WAU task still exists after the real uninstall (must be false).
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcUninstallerResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$WhatIfInstalledBefore = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$WhatIfInstalledAfter = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WhatIfWauBefore,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WhatIfWauAfter,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$InstalledAfter = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$KeptIds = @('Microsoft.PowerShell', 'Microsoft.WindowsTerminal'),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WauPresentAfter
    )

    $rows = @()
    $before = @($WhatIfInstalledBefore | Sort-Object -Unique)
    $after = @($WhatIfInstalledAfter | Sort-Object -Unique)
    $sameApps = (@($before | Where-Object { $after -notcontains $_ }).Count -eq 0) -and (@($after | Where-Object { $before -notcontains $_ }).Count -eq 0)
    $sameWau = ($WhatIfWauBefore -eq $WhatIfWauAfter)
    $rows += New-TestPlanBoolRow -Check 'Uninstaller -WhatIf changed nothing' -Passed ($sameApps -and $sameWau) -Detail ("installed before: {0}; after: {1}; WAU before {2}, after {3}" -f (($before -join ', ')), (($after -join ', ')), $WhatIfWauBefore, $WhatIfWauAfter)

    $rows += New-TestPlanBoolRow -Check 'Real uninstall exits 0 or 3010' -Passed (@(0, 3010) -contains $ExitCode) -Detail "exit $ExitCode"

    $kept = @($KeptIds)
    $stillThere = @($InstalledAfter | Where-Object { $kept -notcontains $_ } | Sort-Object -Unique)
    $removedDetail = 'every removable catalog app is gone'
    if ($stillThere.Count -gt 0) {
        $removedDetail = "still installed: $($stillThere -join ', ')"
    }
    $rows += New-TestPlanBoolRow -Check 'Catalog apps removed (except PowerShell 7 and Windows Terminal)' -Passed ($stillThere.Count -eq 0) -Detail $removedDetail

    if ($null -ne $WauPresentAfter) {
        $rows += New-TestPlanBoolRow -Check 'Winget-AutoUpdate removed' -Passed (-not $WauPresentAfter) -Detail "WAU task present: $WauPresentAfter"
    }
    return $rows
}

# ======================================================================================
# ProgramData link guard (item 11) and ACL/SDDL comparison (pure)
# ======================================================================================

<#
.SYNOPSIS
    Returns why a restricted folder's access is wrong, or $null when it is right: owned by
    Administrators or SYSTEM, inheritance off, and only SYSTEM and Administrators able to change it
    (with -ReadableByUsers, standard users may also read).
.DESCRIPTION
    A pure counterpart of the module's Assert-RestrictedDirectoryAcl, over a
    Get-DirectoryAccessSummary-shaped object (OwnerSid, InheritanceProtected, AccessRules with Sid,
    AccessControlType, Rights, InheritOnly). Used to check the base and logs folders after a run.
.PARAMETER Summary
    The access summary.
.PARAMETER ReadableByUsers
    Accept read-only allow entries for BUILTIN\Users (S-1-5-32-545).
.RETURNS
    [string] what is wrong (problems joined with '; '), or $null when the folder is locked correctly.
#>
function Get-RealPcRestrictedFolderProblem {
    param (
        [Parameter(Mandatory = $true)]
        $Summary,

        [Parameter(Mandatory = $false)]
        [switch]$ReadableByUsers
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    # WriteData, AppendData, WriteExtendedAttributes, DeleteChild, WriteAttributes, Delete,
    # ChangePermissions, TakeOwnership, GENERIC_ALL, GENERIC_WRITE.
    $changeRights = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $problems = @()
    if ($allowedSids -notcontains [string]$Summary.OwnerSid) {
        $problems += "owned by $($Summary.OwnerSid), not Administrators or SYSTEM"
    }
    if (-not $Summary.InheritanceProtected) {
        $problems += 'it still inherits entries from its parent'
    }
    foreach ($rule in @($Summary.AccessRules)) {
        $sid = [string]$rule.Sid
        if ($allowedSids -contains $sid) {
            continue
        }
        if ($ReadableByUsers -and $sid -eq 'S-1-5-32-545' -and [string]$rule.AccessControlType -eq 'Allow' -and ([long]$rule.Rights -band $changeRights) -eq 0) {
            continue
        }
        $problems += ('{0} has an access entry ({1})' -f $sid, ([string]$rule.AccessControlType).ToLowerInvariant())
    }
    if ($problems.Count -eq 0) {
        return $null
    }
    return ($problems -join '; ')
}

<#
.SYNOPSIS
    Compares two ACL/SDDL snapshot sets and says whether every path's owner and SDDL are unchanged.
.DESCRIPTION
    Each snapshot is a list of objects with Path, Owner and Sddl (Get-RealPcAclSnapshotTree builds
    them on Windows). A path missing from After, or whose owner or SDDL changed, is a difference.
.PARAMETER Before
    The snapshot taken before.
.PARAMETER After
    The snapshot taken after.
.RETURNS
    [pscustomobject] with Unchanged ([bool]) and Detail ([string]).
#>
function Compare-RealPcAclSnapshot {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Before = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$After = @()
    )

    $afterByPath = @{}
    foreach ($entry in @($After)) {
        $afterByPath[[string]$entry.Path] = $entry
    }
    $differences = @()
    foreach ($entry in @($Before)) {
        $path = [string]$entry.Path
        if (-not $afterByPath.ContainsKey($path)) {
            $differences += "$path is gone"
            continue
        }
        $now = $afterByPath[$path]
        if ([string]$now.Owner -ne [string]$entry.Owner) {
            $differences += "$path owner changed ($($entry.Owner) -> $($now.Owner))"
        }
        if ([string]$now.Sddl -ne [string]$entry.Sddl) {
            $differences += "$path access list (SDDL) changed"
        }
    }
    foreach ($entry in @($After)) {
        $path = [string]$entry.Path
        if (-not (@($Before | Where-Object { [string]$_.Path -eq $path }).Count -gt 0)) {
            $differences += "$path is new"
        }
    }
    if ($differences.Count -eq 0) {
        return [pscustomobject]@{ Unchanged = $true; Detail = "$(@($Before).Count) entries unchanged (owner and SDDL)" }
    }
    return [pscustomobject]@{ Unchanged = $false; Detail = ($differences -join '; ') }
}

<#
.SYNOPSIS
    Checks the ProgramData link guard (item 11) from what a first run left behind.
.DESCRIPTION
    The base folder is now a real directory (not a reparse point) locked to SYSTEM and Administrators
    (Get-RealPcRestrictedFolderProblem), the logs folder is readable by Users, the run's transcript
    carries the 'was a link ... removed' warning, and the victim folder and everything in it kept
    their owner and SDDL (Compare-RealPcAclSnapshot).
.PARAMETER BaseIsReparsePoint
    Whether %ProgramData%\winget-app-setup is still a reparse point (must be false).
.PARAMETER BaseAcl
    Get-DirectoryAccessSummary of the base folder, or $null.
.PARAMETER LogsAcl
    Get-DirectoryAccessSummary of the logs folder, or $null.
.PARAMETER TranscriptText
    The run's transcript text (any transcript of the run), for the removed-link warning.
.PARAMETER VictimBefore
    The victim tree's ACL snapshot before the run.
.PARAMETER VictimAfter
    The victim tree's ACL snapshot after the run.
.PARAMETER PlantedAsAdmin
    The junction was planted by the admin (temporary-user creation was blocked): the row says so.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcLinkGuardResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$BaseIsReparsePoint,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $BaseAcl,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $LogsAcl,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TranscriptText = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$VictimBefore = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$VictimAfter = @(),

        [Parameter(Mandatory = $false)]
        [switch]$PlantedAsAdmin
    )

    $rows = @()
    if ($PlantedAsAdmin) {
        $rows += New-TestPlanRow -Check 'Junction planted by a standard user' -Result 'SKIP' -Detail 'creating the temporary user was blocked by policy; the junction was planted by the admin instead'
    }

    $rows += New-TestPlanBoolRow -Check 'Base folder is a real directory (not a link)' -Passed ($BaseIsReparsePoint -eq $false) -Detail "reparse point: $BaseIsReparsePoint"

    if ($null -ne $BaseAcl) {
        $problem = Get-RealPcRestrictedFolderProblem -Summary $BaseAcl
        $rows += New-TestPlanBoolRow -Check 'Base folder locked to SYSTEM and Administrators' -Passed ($null -eq $problem) -Detail $(if ($problem) { $problem } else { "owner $($BaseAcl.OwnerSid), inheritance off" })
    }
    if ($null -ne $LogsAcl) {
        $problem = Get-RealPcRestrictedFolderProblem -Summary $LogsAcl -ReadableByUsers
        $rows += New-TestPlanBoolRow -Check 'logs folder readable by Users, not writable' -Passed ($null -eq $problem) -Detail $(if ($problem) { $problem } else { "owner $($LogsAcl.OwnerSid), Users read" })
    }

    $warned = $TranscriptText -match "(?m)was a link .* removed"
    $rows += New-TestPlanBoolRow -Check "Transcript warns the link was removed" -Passed $warned -Detail $(if ($warned) { 'found the removed-link warning' } else { 'no removed-link warning in the transcript' })

    $compare = Compare-RealPcAclSnapshot -Before $VictimBefore -After $VictimAfter
    $rows += New-TestPlanBoolRow -Check 'Victim folder and contents kept their owner and SDDL' -Passed $compare.Unchanged -Detail $compare.Detail
    return $rows
}

# ======================================================================================
# Safety gate, change plan and report (pure)
# ======================================================================================

<#
.SYNOPSIS
    The lines describing exactly what the run will change, for the operator to read before it starts.
.PARAMETER Stages
    The resolved stages that will run (Resolve-RealPcTestPlanStage's Stages).
.PARAMETER ReportFolder
    Where the report and zip go.
.PARAMETER PublicVictimFolder
    The folder under C:\Users\Public the link-guard stage creates.
.RETURNS
    [string[]] one line per change.
#>
function Get-RealPcChangePlan {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Stages = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ReportFolder = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PublicVictimFolder = ''
    )

    $stageNames = @($Stages | ForEach-Object { $_.Name })
    $lines = @('This run will change this machine as follows:')
    $lines += '  - Install the curated catalog apps (7-Zip, TightVNC, Adobe Reader, Chrome, Google Drive, Git, Bulk Crap Uninstaller, Dell Command Update where applicable, PowerShell 7, Windows Terminal).'
    $lines += '  - Set up Winget-AutoUpdate and install the Windows App Runtime 1.8 for all users.'
    $lines += "  - Create and lock %ProgramData%\winget-app-setup (logs and cache)."
    if ($stageNames -contains 'LinkGuardSetup') {
        $lines += "  - Create a temporary STANDARD local user (random name and password, never printed) and a victim folder under $PublicVictimFolder, and plant a junction at %ProgramData%\winget-app-setup as that user; both are removed afterwards."
    }
    if ($stageNames -contains 'System' -or $stageNames -contains 'WinGetClient') {
        $lines += '  - Register and run one-shot SYSTEM scheduled tasks (the Endpoint Central machine phase).'
    }
    if ($stageNames -contains 'TimeBudget') {
        $lines += '  - Uninstall and reinstall 7-Zip (the time-budget stage).'
    }
    if ($stageNames -contains 'Uninstaller') {
        $lines += '  - Remove the catalog apps (except PowerShell 7 and Windows Terminal) and Winget-AutoUpdate (the uninstaller stage).'
    }
    $lines += "  - Write a report and a zip to $ReportFolder."
    $lines += 'It does NOT touch a work PC safely. Run it only on a disposable test machine.'
    return $lines
}

<#
.SYNOPSIS
    The overall exit code: 0 when every non-skipped row passed, 1 when any failed, 2 on refusal.
.PARAMETER Rows
    All the result rows.
.PARAMETER Refused
    The safety gate refused (not elevated, or not confirmed disposable).
.RETURNS
    [int]
#>
function Get-RealPcExitCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Refused
    )

    if ($Refused) {
        return 2
    }
    if (@($Rows | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) {
        return 1
    }
    return 0
}

<#
.SYNOPSIS
    The safety-gate decision: whether to run the stages, the exit code if not, and why.
.DESCRIPTION
    Plan-only (-WhatIf / -Plan) never runs the stages and exits 0. Otherwise the run proceeds only
    when it is elevated and the operator confirmed the machine is disposable; a missing confirmation
    or elevation refuses with exit code 2.
.PARAMETER Elevated
    Whether the process is elevated.
.PARAMETER Confirmed
    Whether the operator confirmed the machine is disposable (-ConfirmDisposableMachine or the typed
    phrase).
.PARAMETER PlanOnly
    -WhatIf / -Plan: print the plan and change nothing.
.RETURNS
    [pscustomobject] with Proceed ([bool]), ExitCode ([int]) and Reason ([string]).
#>
function Get-RealPcGateDecision {
    param (
        [Parameter(Mandatory = $false)]
        [bool]$Elevated = $false,

        [Parameter(Mandatory = $false)]
        [bool]$Confirmed = $false,

        [Parameter(Mandatory = $false)]
        [switch]$PlanOnly
    )

    if ($PlanOnly) {
        return [pscustomobject]@{ Proceed = $false; ExitCode = 0; Reason = 'plan only: nothing was changed' }
    }
    if (-not $Elevated) {
        return [pscustomobject]@{ Proceed = $false; ExitCode = 2; Reason = 'this harness must be run elevated (as administrator); nothing was changed' }
    }
    if (-not $Confirmed) {
        return [pscustomobject]@{ Proceed = $false; ExitCode = 2; Reason = 'the machine was not confirmed disposable; nothing was changed' }
    }
    return [pscustomobject]@{ Proceed = $true; ExitCode = 0; Reason = 'proceed' }
}

<#
.SYNOPSIS
    Builds the report text (report.md or report.txt) from the machine facts and the stage results.
.PARAMETER MachineFacts
    An ordered dictionary of fact name to value (OS, build, edition, architecture, PowerShell, ...).
.PARAMETER StageResult
    One object per stage with Name, Number, Item, DurationSeconds and Rows.
.PARAMETER ManualLeftovers
    The 'Still to do by hand' lines.
.PARAMETER Markdown
    Markdown headings and a table; otherwise plain text.
.RETURNS
    [string]
#>
function Format-RealPcReport {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$MachineFacts = @{},

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$StageResult = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ManualLeftovers = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Markdown
    )

    $allRows = @($StageResult | ForEach-Object { $_.Rows } | Where-Object { $null -ne $_ })
    $pass = @($allRows | Where-Object { $_.Result -eq 'PASS' }).Count
    $fail = @($allRows | Where-Object { $_.Result -eq 'FAIL' }).Count
    $skip = @($allRows | Where-Object { $_.Result -eq 'SKIP' }).Count
    $overall = 'PASS'
    if ($fail -gt 0) {
        $overall = 'FAIL'
    }

    $lines = @()
    if ($Markdown) {
        $lines += '# Real-PC test plan report'
        $lines += ''
        $lines += ('**Overall: {0}** - {1} passed, {2} failed, {3} skipped.' -f $overall, $pass, $fail, $skip)
        $lines += ''
        $lines += '## Machine'
        $lines += ''
        $lines += '| Fact | Value |'
        $lines += '| --- | --- |'
        foreach ($name in @($MachineFacts.Keys)) {
            $lines += ('| {0} | {1} |' -f $name, $MachineFacts[$name])
        }
    }
    else {
        $lines += 'Real-PC test plan report'
        $lines += ('Overall: {0} - {1} passed, {2} failed, {3} skipped.' -f $overall, $pass, $fail, $skip)
        $lines += ''
        $lines += 'Machine:'
        foreach ($name in @($MachineFacts.Keys)) {
            $lines += ('  {0}: {1}' -f $name, $MachineFacts[$name])
        }
    }
    $lines += ''

    foreach ($stage in $StageResult) {
        $rows = @($stage.Rows)
        $stageFail = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count
        $stageState = 'PASS'
        if ($stageFail -gt 0) {
            $stageState = 'FAIL'
        }
        elseif (@($rows | Where-Object { $_.Result -eq 'PASS' }).Count -eq 0) {
            $stageState = 'SKIP'
        }
        $heading = ('Stage {0} {1} (item {2}) - {3} [{4:N0}s]' -f $stage.Number, $stage.Name, $stage.Item, $stageState, $stage.DurationSeconds)
        if ($Markdown) {
            $lines += "## $heading"
            $lines += ''
            if ($rows.Count -gt 0) {
                $lines += '| Result | Check | Detail |'
                $lines += '| --- | --- | --- |'
                foreach ($row in $rows) {
                    $lines += ('| {0} | {1} | {2} |' -f $row.Result, $row.Check, ($row.Detail -replace '\|', '\|'))
                }
            }
            else {
                $lines += '(no checks recorded)'
            }
        }
        else {
            $lines += $heading
            foreach ($row in $rows) {
                $lines += ('  [{0}] {1}: {2}' -f $row.Result, $row.Check, $row.Detail)
            }
            if ($rows.Count -eq 0) {
                $lines += '  (no checks recorded)'
            }
        }
        $lines += ''
    }

    $heading = 'Still to do by hand'
    if ($Markdown) {
        $lines += "## $heading"
    }
    else {
        $lines += ($heading + ':')
    }
    $lines += ''
    foreach ($leftover in $ManualLeftovers) {
        if ($Markdown) {
            $lines += "- $leftover"
        }
        else {
            $lines += "  - $leftover"
        }
    }
    return ($lines -join [Environment]::NewLine)
}

<#
.SYNOPSIS
    The 'Still to do by hand' list: what the harness cannot automate.
.RETURNS
    [string[]]
#>
function Get-RealPcManualLeftover {
    return @(
        'Cross-user elevation: run the one-liner from a standard user and approve the UAC prompt as a DIFFERENT admin account; check that apps with no machine-scope installer are Deferred, not put in the admin profile.',
        'TightVNC: connect a viewer with the throwaway test password in the report folder''s manual-steps file, and confirm the server accepts it.',
        'Endpoint Central: after this branch merges and the RMM pins are set (build/Set-RmmInstallerPin.ps1), deploy the machine and user phases from Endpoint Central and watch the Remarks.',
        'ARM64 hardware: on a real Windows 11 ARM64 PC, check the 32-bit Reader installs, the 64-bit Reader and Dell Command Update are skipped, and Google Drive installs and mounts.'
    )
}

# ======================================================================================
# Side-effecting helpers (Windows only) and the stages
# ======================================================================================

# Writes a line to the host and the harness transcript.
function Write-RealPcLine {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Color = 'Gray'
    )

    Write-Host $Message -ForegroundColor $Color
}

<#
.SYNOPSIS
    Returns whether this process is elevated (an administrator).
.RETURNS
    [bool]
#>
function Test-RealPcElevated {
    try {
        $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns whether this is Windows Sandbox (the WDAGUtilityAccount), where winget is often missing.
.RETURNS
    [bool]
#>
function Test-RealPcWindowsSandbox {
    try {
        return ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -match '(?i)WDAGUtilityAccount')
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Reads a password-strength-neutral random string for the temporary user and the TightVNC test
    password: printable ASCII letters and digits, the given length.
.PARAMETER Length
    How many characters. Default 20.
.RETURNS
    [string]
#>
function New-RealPcRandomSecret {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(8, 128)]
        [int]$Length = 20
    )

    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($alphabet[$byte % $alphabet.Length])
    }
    return $builder.ToString()
}

<#
.SYNOPSIS
    Returns an ACL snapshot of a folder and everything in it: one entry per path, each with Path,
    Owner (SID) and Sddl.
.DESCRIPTION
    Windows only (Get-Acl). Used to show the victim folder's owner and access list were untouched.
.PARAMETER Path
    The folder.
.RETURNS
    [pscustomobject[]] with Path, Owner and Sddl.
#>
function Get-RealPcAclSnapshotTree {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $snapshots = @()
    $items = @($Path) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($item in $items) {
        try {
            $acl = Get-Acl -LiteralPath $item -ErrorAction Stop
            $snapshots += [pscustomobject]@{
                Path  = [string]$item
                Owner = [string]$acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                Sddl  = [string]$acl.Sddl
            }
        }
        catch {
            $snapshots += [pscustomobject]@{ Path = [string]$item; Owner = 'unreadable'; Sddl = "unreadable: $($_.Exception.Message)" }
        }
    }
    return $snapshots
}

# Runs a program, shows (and transcribes) its output, and returns its exit code, or $null when it
# could not start. The caller sets any environment variables first.
function Invoke-RealPcProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    $global:LASTEXITCODE = $null
    try {
        & $FilePath @ArgumentList 2>&1 | Out-Host
    }
    catch {
        Write-RealPcLine "Could not start ${FilePath}: $($_.Exception.Message)" 'Red'
        return $null
    }
    return $global:LASTEXITCODE
}

# The 64-bit Windows PowerShell 5.1 path, which the installer's 5.1 bootstrap relaunches from.
function Get-RealPcWindowsPowerShellPath {
    $root = $env:SystemRoot
    if (-not $root) {
        $root = 'C:\Windows'
    }
    return (Join-Path $root 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# pwsh.exe, for the module queries that must run under PowerShell 7 (the first install pass installs
# it). $null when none is found yet.
function Find-RealPcPowerShell7 {
    $command = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }
    foreach ($root in @($env:ProgramFiles, $env:ProgramW6432, $env:LOCALAPPDATA)) {
        if (-not $root) {
            continue
        }
        foreach ($candidate in @((Join-Path $root 'PowerShell\7\pwsh.exe'), (Join-Path $root 'Microsoft\WindowsApps\pwsh.exe'))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Runs a scriptblock in a child PowerShell 7 with the WingetAppSetup module imported and the e2e
    SYSTEM-pass helpers dot-sourced, and returns its JSON output parsed, or $null.
.DESCRIPTION
    Keeps the module out of this 5.1 process. The scriptblock's text runs after the module import and
    the dot-source, and must ConvertTo-Json its result. A missing pwsh, or any failure, returns $null.
.PARAMETER Body
    The scriptblock text to run in the child (it writes its result with ConvertTo-Json).
.RETURNS
    The parsed JSON, or $null.
#>
function Invoke-RealPcModuleJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $pwsh = Find-RealPcPowerShell7
    if (-not $pwsh) {
        return $null
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $manifest = Join-Path $repoRoot 'WingetAppSetup\WingetAppSetup.psd1'
    $systemPass = Join-Path $PSScriptRoot 'Invoke-SystemInstallPass.ps1'
    $preamble = @(
        "Import-Module '$manifest' -Force -ErrorAction Stop | Out-Null",
        ". '$systemPass'"
    ) -join "`n"
    $script = $preamble + "`n" + $Body
    try {
        $output = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $script 2>$null
        $text = ($output | Out-String).Trim()
        if (-not $text) {
            return $null
        }
        return (ConvertFrom-Json -InputObject $text -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

# The catalog's package ids (Get-DefaultAppCatalog), via a child pwsh; empty when pwsh is missing.
function Get-RealPcCatalogId {
    $result = Invoke-RealPcModuleJson -Body 'ConvertTo-Json -InputObject (@(Get-DefaultAppCatalog).name) -Depth 3'
    if ($null -eq $result) {
        return @()
    }
    return @($result)
}

<#
.SYNOPSIS
    Builds the per-app expectations for an install run, via the module and Get-SystemPassAppExpectation
    in a child pwsh.
.PARAMETER System
    The run is a run for the whole PC (SYSTEM): applicability is decided with Test-IsSystemAccount
    true (Get-SystemRunApplicability).
.PARAMETER AlreadyPresent
    A re-run or a run after the apps are installed: every app that would be Installed must now be
    present.
.PARAMETER RemovedApps
    The package ids removed before the run (expected freshly Installed). Default none.
.RETURNS
    [object[]] the expectation objects (Id, Expected, Reason, AlreadyPresentReasons, MustInstall), or
    an empty array when pwsh is missing.
#>
function Get-RealPcAppExpectation {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$System,

        [Parameter(Mandatory = $false)]
        [switch]$AlreadyPresent,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RemovedApps = @()
    )

    $removedJson = (@($RemovedApps) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $applicabilityLine = '$applicability = @{}; foreach ($app in $catalog) { $applicability[$app.name] = [bool](Test-AppApplicability -App $app) }'
    if ($System) {
        $applicabilityLine = '$applicability = Get-SystemRunApplicability -Catalog $catalog -Module (Get-Module WingetAppSetup)'
    }
    $alreadyPresentLine = ''
    if ($AlreadyPresent) {
        $alreadyPresentLine = '-AlreadyPresent'
    }
    $body = @"
`$catalog = @(Get-DefaultAppCatalog)
$applicabilityLine
`$expectation = @(Get-SystemPassAppExpectation -Catalog `$catalog -Applicability `$applicability -RemovedApps @($removedJson) $alreadyPresentLine)
ConvertTo-Json -InputObject `$expectation -Depth 4
"@
    $result = Invoke-RealPcModuleJson -Body $body
    if ($null -eq $result) {
        return @()
    }
    return @($result)
}

# Get-DirectoryAccessSummary-shaped read of a folder's ACL (OwnerSid, InheritanceProtected,
# AccessRules), or $null when it cannot be read. Windows only.
function Get-RealPcFolderAclSummary {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return $null
    }
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $rules = @(foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
            [pscustomobject]@{
                Sid               = [string]$rule.IdentityReference.Value
                AccessControlType = [string]$rule.AccessControlType
                Rights            = [long]$rule.FileSystemRights
                InheritOnly       = (([int]$rule.PropagationFlags) -band 2) -ne 0
            }
        })
    $ownerSid = $null
    $owner = $acl.GetOwner($sidType)
    if ($owner) {
        $ownerSid = [string]$owner.Value
    }
    return [pscustomobject]@{
        OwnerSid             = $ownerSid
        InheritanceProtected = [bool]$acl.AreAccessRulesProtected
        AccessRules          = $rules
    }
}

# Whether the path is a reparse point (a junction or symbolic link). $null when nothing is there.
function Test-RealPcReparsePoint {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
    }
    catch {
        return $null
    }
    return (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# A local read of the Winget-AutoUpdate task's health (Exists, Healthy, Triggers). Windows only.
function Get-RealPcWauTaskHealth {
    $result = [pscustomobject]@{ Exists = $false; Healthy = $false; Triggers = @() }
    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    catch {
        return $result
    }
    if (-not $task) {
        return $result
    }
    $result.Exists = $true
    $triggers = @($task.Triggers | Where-Object { $null -ne $_ })
    $result.Triggers = @($triggers | ForEach-Object {
            $text = "$($_.CimClass.CimClassName)" -replace '^MSFT_Task', '' -replace 'Trigger$', ''
            if ($_.Enabled -eq $false) {
                $text += ' (disabled)'
            }
            $text
        })
    $enabled = @($triggers | Where-Object { $_.Enabled -ne $false })
    $result.Healthy = ("$($task.State)" -ne 'Disabled') -and $enabled.Count -gt 0
    return $result
}

# Whether winget lists a package id as installed (exit 0). $LASTEXITCODE is read at once.
function Test-RealPcWingetInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    try {
        $null = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        return $false
    }
    return ($code -eq 0)
}

# The catalog ids winget currently lists as installed.
function Get-RealPcInstalledCatalogId {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$CatalogId
    )

    return @($CatalogId | Where-Object { Test-RealPcWingetInstalled -Id $_ })
}

# The RESULT line of the newest real-run transcript since a time, or empty.
function Get-RealPcResultLine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )

    $transcript = Get-InstallPassTranscript -LogDirectory $LogDirectory -Since $Since
    if (-not $transcript) {
        return ''
    }
    $files = @((Get-InstallTranscriptFile -LogDirectory $LogDirectory).RealRun | Where-Object { $_.LastWriteTime -ge $Since })
    foreach ($file in @($files | Sort-Object -Property LastWriteTime -Descending)) {
        $line = @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match '^RESULT: ' }) | Select-Object -Last 1
        if ($line) {
            return [string]$line
        }
    }
    return ''
}

# The installer command for an install pass: the one-liner piped to iex, or the checkout's -File.
function Get-RealPcInstallerInvocation {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$ExtraArgument = @()
    )

    $powerShell = Get-RealPcWindowsPowerShellPath
    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ($UseOneLiner) {
        $url = 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/{0}/winget-app-install.ps1' -f $Branch
        $command = 'Set-ExecutionPolicy Unrestricted -Scope Process -Force; $env:WINGET_APP_SETUP_NONINTERACTIVE=''1''; irm "{0}" | iex' -f $url
        return [pscustomobject]@{ FilePath = $powerShell; Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) }
    }
    $installer = Join-Path $repoRoot 'winget-app-install.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-NonInteractive') + $ExtraArgument
    return [pscustomobject]@{ FilePath = $powerShell; Arguments = $arguments }
}

# Runs the installer once with the given extra arguments and environment, and returns its exit code.
function Invoke-RealPcInstaller {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$ExtraArgument = @(),

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$Environment = @{}
    )

    $invocation = Get-RealPcInstallerInvocation -ExtraArgument $ExtraArgument
    $saved = @{}
    foreach ($name in @($Environment.Keys)) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name])
    }
    try {
        return (Invoke-RealPcProcess -FilePath $invocation.FilePath -ArgumentList $invocation.Arguments)
    }
    finally {
        foreach ($name in @($saved.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

# ---- Stages --------------------------------------------------------------------------------------

# Stage 0 Preflight: machine facts and a warning for a non-fresh machine or Windows Sandbox.
function Invoke-RealPcPreflightStage {
    $rows = @()
    $facts = $script:MachineFacts

    $osName = ''
    $build = ''
    $edition = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osName = [string]$os.Caption
        $build = [string]$os.BuildNumber
    }
    catch {
    }
    try {
        $edition = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
    }
    catch {
    }
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $facts['OS'] = $osName
    $facts['Build'] = $build
    $facts['Edition'] = $edition
    $facts['Architecture'] = $architecture
    $facts['Windows PowerShell'] = "$($PSVersionTable.PSVersion)"
    $pwsh = Find-RealPcPowerShell7
    $facts['PowerShell 7'] = $(if ($pwsh) { $pwsh } else { 'not installed yet' })
    $facts['Elevated'] = (Test-RealPcElevated)
    $facts['Report folder'] = $script:ReportFolder

    $rows += New-TestPlanBoolRow -Check 'Running elevated' -Passed (Test-RealPcElevated) -Detail 'administrator'

    $wingetPresent = [bool](Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue)
    $facts['winget present'] = $wingetPresent
    if (Test-RealPcWindowsSandbox) {
        $rows += New-TestPlanRow -Check 'Windows Sandbox detected' -Result 'SKIP' -Detail 'WDAGUtilityAccount: winget may be missing in Windows Sandbox; install App Installer first'
    }
    $rows += New-TestPlanBoolRow -Check 'winget present' -Passed $wingetPresent -Detail $(if ($wingetPresent) { 'winget found' } else { 'winget not found (a fresh PC may provision it shortly, or install App Installer)' })

    $freeGb = $null
    try {
        $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $freeGb = [Math]::Round($drive.Free / 1GB, 1)
    }
    catch {
    }
    $facts['Free disk (GB)'] = $freeGb
    $rows += New-TestPlanRow -Check 'Free disk space' -Result 'PASS' -Detail "$freeGb GB free on $env:SystemDrive"

    # A non-fresh machine: an existing ProgramData folder, or catalog apps already installed.
    $baseFolder = Join-Path $env:ProgramData 'winget-app-setup'
    $existing = Test-Path -LiteralPath $baseFolder
    $facts['ProgramData folder existed'] = $existing
    if ($existing) {
        $rows += New-TestPlanRow -Check 'Fresh ProgramData folder' -Result 'SKIP' -Detail "$baseFolder exists: results describe a non-fresh machine. -ResetProgramData renames it aside so the link-guard stage can run."
    }
    else {
        $rows += New-TestPlanRow -Check 'Fresh ProgramData folder' -Result 'PASS' -Detail "$baseFolder does not exist"
    }
    return $rows
}

# Stage 1 LinkGuardSetup: plant a junction at %ProgramData%\winget-app-setup as a temporary standard
# user (item 11). Only when the folder does not exist (or -ResetProgramData renamed it aside).
function Invoke-RealPcLinkGuardSetupStage {
    $rows = @()
    $baseFolder = Join-Path $env:ProgramData 'winget-app-setup'
    if ((Test-Path -LiteralPath $baseFolder) -and $ResetProgramData) {
        $aside = '{0}-old-{1}' -f $baseFolder, (Get-Date).ToString('yyyyMMdd-HHmmss')
        try {
            Rename-Item -LiteralPath $baseFolder -NewName (Split-Path -Leaf $aside) -ErrorAction Stop
            $rows += New-TestPlanRow -Check 'Renamed the existing ProgramData folder aside' -Result 'PASS' -Detail $aside
        }
        catch {
            $rows += New-TestPlanRow -Check 'Link guard setup' -Result 'SKIP' -Detail "could not rename $baseFolder aside: $($_.Exception.Message)"
            return $rows
        }
    }
    if (Test-Path -LiteralPath $baseFolder) {
        $rows += New-TestPlanRow -Check 'Link guard setup' -Result 'SKIP' -Detail "$baseFolder already exists; pass -ResetProgramData to rename it aside and run the link-guard stage on a fresh folder"
        return $rows
    }

    $publicRoot = Join-Path $env:PUBLIC ('winget-app-setup-victim-' + (Get-Date).ToString('yyyyMMddHHmmss'))
    [void](New-Item -ItemType Directory -Path $publicRoot -ErrorAction Stop)
    Set-Content -LiteralPath (Join-Path $publicRoot 'marker.txt') -Value 'not the installers file' -Encoding ASCII
    [void](New-Item -ItemType Directory -Path (Join-Path $publicRoot 'sub') -ErrorAction Stop)
    Set-Content -LiteralPath (Join-Path $publicRoot 'sub\inner.txt') -Value 'not the installers file either' -Encoding ASCII
    $script:LinkGuard.VictimFolder = $publicRoot
    $script:LinkGuard.VictimBefore = Get-RealPcAclSnapshotTree -Path $publicRoot
    $rows += New-TestPlanRow -Check 'Created a victim folder under C:\Users\Public' -Result 'PASS' -Detail $publicRoot

    $userName = 'wgtsetup' + (Get-Date).ToString('HHmmss')
    # A random password with a fixed complexity suffix, so New-LocalUser is not refused by a
    # complexity policy. Never printed, never written to disk.
    $password = (New-RealPcRandomSecret -Length 20) + 'Aa9!'
    $plantedAsAdmin = $false
    $createdUser = $false
    try {
        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        $null = New-LocalUser -Name $userName -Password $secure -AccountNeverExpires -ErrorAction Stop
        $createdUser = $true
        $script:LinkGuard.TempUser = $userName
        # Kept (not nulled on cleanup) so the Diagnostics stage can check the bundle does not leak it.
        $script:LinkGuard.TempUserName = $userName
        $rows += New-TestPlanRow -Check 'Created a temporary standard user' -Result 'PASS' -Detail "$userName (random password, never printed)"
    }
    catch {
        $plantedAsAdmin = $true
        $rows += New-TestPlanRow -Check 'Created a temporary standard user' -Result 'SKIP' -Detail "blocked by policy ($($_.Exception.Message)); planting the junction as the admin instead"
    }
    $script:LinkGuard.PlantedAsAdmin = $plantedAsAdmin

    # Plant the junction. As the temporary standard user through a one-shot scheduled task; when that
    # does not plant it (a CI runner has no interactive session for the user to run the task), fall
    # back to planting it as the admin and mark the row a SKIP (the guard is still exercised: the run
    # removes the link, locks the folder and leaves the victim untouched).
    if ($createdUser) {
        try {
            $taskName = 'winget-app-setup-plantjunction'
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c mklink /J "{0}" "{1}"' -f $baseFolder, $publicRoot)
            $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$userName" -LogonType Interactive -RunLevel Limited
            $null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $deadline = (Get-Date).AddMinutes(2)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $baseFolder)) {
                Start-Sleep -Seconds 2
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {
            # Fall through to the admin fallback below.
        }
    }
    if ((Test-RealPcReparsePoint -Path $baseFolder) -ne $true) {
        $plantedAsAdmin = $true
        try {
            $null = & cmd.exe /c mklink /J $baseFolder $publicRoot 2>&1
        }
        catch {
        }
    }
    $script:LinkGuard.PlantedAsAdmin = $plantedAsAdmin
    $planted = (Test-RealPcReparsePoint -Path $baseFolder) -eq $true
    $script:LinkGuard.Planted = $planted
    if (-not $planted) {
        $rows += New-TestPlanRow -Check 'Planted the junction at the ProgramData folder' -Result 'FAIL' -Detail 'the junction could not be created'
        return $rows
    }
    $how = 'as the temporary standard user'
    if ($plantedAsAdmin) {
        $how = 'as the admin (the temporary user could not run the planting task)'
    }
    $rows += New-TestPlanRow -Check 'Planted the junction at the ProgramData folder' -Result 'PASS' -Detail ("$baseFolder -> $publicRoot, $how")
    return $rows
}

# Stage 2 FirstRun: items 1 + 4 + 5, then the item-11 verification and cleanup.
function Invoke-RealPcFirstRunStage {
    $rows = @()
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $tightVncPassword = $script:TightVncPassword
    $startedAt = Get-Date
    $exitCode = Invoke-RealPcInstaller -Environment @{
        WINGET_APP_SETUP_NONINTERACTIVE    = '1'
        WINGET_APP_SETUP_TIGHTVNC_PASSWORD = $tightVncPassword
    }
    $transcript = Get-InstallPassTranscript -LogDirectory $logDirectory -Since $startedAt
    $record = (Read-SystemPassRunRecord -Path (Join-Path $logDirectory 'last-run.json')).Record
    $script:FirstRunTranscriptText = ''
    if ($transcript) {
        $files = @((Get-InstallTranscriptFile -LogDirectory $logDirectory).RealRun | Where-Object { $_.LastWriteTime -ge $startedAt })
        foreach ($file in $files) {
            $script:FirstRunTranscriptText += [string](Get-Content -LiteralPath $file.FullName -Raw)
        }
    }
    $script:FirstRunDone = $true

    # Items 1 + 4 + 5: exit code, run record, each app, auto-updates, runtime, WAU, TightVNC.
    $verdict = Get-RealPcInstallExitVerdict -ExitCode ([int]$exitCode) -Transcript $transcript -Pass 'first'
    $rows += New-TestPlanBoolRow -Check 'First run exit code acceptable (0, 3010 or 8 with reason)' -Passed $verdict.Passed -Detail $verdict.Message
    $rows += Get-RealPcRunRecordResult -RunRecord $record -ExpectedExitCode ([int]$exitCode)

    $expectation = Get-RealPcAppExpectation
    $rows += Get-RealPcAppResult -RunRecord $record -AppExpectation $expectation

    $wauHealth = Get-RealPcWauTaskHealth
    $runtimePresent = $null
    $runtimeInfo = Invoke-RealPcModuleJson -Body 'ConvertTo-Json -InputObject (Get-WindowsAppRuntimeStatus) -Depth 4'
    if ($null -ne $runtimeInfo -and $null -ne $runtimeInfo.Present) {
        $runtimePresent = [bool]$runtimeInfo.Present
    }
    $rows += Get-RealPcAutoUpdateResult -Transcript $transcript -RunRecord $record -WauTaskHealth $wauHealth -WindowsAppRuntimePresent $runtimePresent -ExpectTightVncConfigured

    # Item 11: verify the link guard, then clean up the victim folder and the temporary user.
    if ($script:LinkGuard.Planted) {
        $baseFolder = Join-Path $env:ProgramData 'winget-app-setup'
        $baseIsLink = Test-RealPcReparsePoint -Path $baseFolder
        $baseAcl = Get-RealPcFolderAclSummary -Path $baseFolder
        $logsAcl = Get-RealPcFolderAclSummary -Path $logDirectory
        $victimAfter = @()
        if ($script:LinkGuard.VictimFolder -and (Test-Path -LiteralPath $script:LinkGuard.VictimFolder)) {
            $victimAfter = Get-RealPcAclSnapshotTree -Path $script:LinkGuard.VictimFolder
        }
        $rows += Get-RealPcLinkGuardResult -BaseIsReparsePoint $baseIsLink -BaseAcl $baseAcl -LogsAcl $logsAcl -TranscriptText $script:FirstRunTranscriptText -VictimBefore $script:LinkGuard.VictimBefore -VictimAfter $victimAfter -PlantedAsAdmin:$script:LinkGuard.PlantedAsAdmin
    }
    Remove-RealPcLinkGuardArtifact
    return $rows
}

# Removes the link-guard stage's temporary user (and profile) and victim folder, best-effort.
function Remove-RealPcLinkGuardArtifact {
    if ($script:LinkGuard.TempUser) {
        try {
            Remove-LocalUser -Name $script:LinkGuard.TempUser -ErrorAction SilentlyContinue
        }
        catch {
        }
        $script:LinkGuard.TempUser = $null
    }
    if ($script:LinkGuard.VictimFolder -and (Test-Path -LiteralPath $script:LinkGuard.VictimFolder)) {
        try {
            Remove-Item -LiteralPath $script:LinkGuard.VictimFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

# Stage 3 ReRun (item 2): run the installer again; everything already present.
function Invoke-RealPcReRunStage {
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $startedAt = Get-Date
    $exitCode = Invoke-RealPcInstaller -Environment @{
        WINGET_APP_SETUP_NONINTERACTIVE    = '1'
        WINGET_APP_SETUP_TIGHTVNC_PASSWORD = $script:TightVncPassword
    }
    $transcript = Get-InstallPassTranscript -LogDirectory $logDirectory -Since $startedAt
    $record = (Read-SystemPassRunRecord -Path (Join-Path $logDirectory 'last-run.json')).Record
    $expectation = Get-RealPcAppExpectation -AlreadyPresent
    return (Get-RealPcReRunResult -ExitCode ([int]$exitCode) -Transcript $transcript -RunRecord $record -AppExpectation $expectation)
}

# Stage 4 System (item 3) and stage 5 WinGetClient (item 10): the SYSTEM pass through the RMM wrapper.
function Invoke-RealPcSystemStage {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SystemEngine
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $wrapper = Join-Path $repoRoot 'rmm\Invoke-WingetAppSetup.ps1'
    $installer = Join-Path $repoRoot 'winget-app-install.ps1'
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $sha = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    $powerShell32 = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgument = Get-SystemPassTaskArgument -WrapperPath $wrapper -InstallerPath $installer -InstallerSha256 $sha -SystemInstallEngine $SystemEngine
    $taskRun = Invoke-SystemPassTask -PowerShellPath $powerShell32 -TaskArgument $taskArgument -TimeoutMinutes $script:StageTimeoutMinutes -LogFolder $logDirectory

    if ($taskRun.StartError) {
        return @(New-TestPlanRow -Check 'SYSTEM task started' -Result 'FAIL' -Detail $taskRun.StartError)
    }
    # Every app is already installed by FirstRun, so expect them present; the framework is already
    # there, so treat the Windows App Runtime as a second run (not installed again).
    $expectation = Get-RealPcAppExpectation -System -AlreadyPresent
    $check = Get-SystemInstallPassResult -TaskExitCode $taskRun.TaskExitCode -Transcript $taskRun.Transcript -WrapperLog $taskRun.WrapperLog -RunRecord $taskRun.RunRecordRead.Record -RunRecordProblem $taskRun.RunRecordRead.Problem -NewSystemProfileEntries $taskRun.NewSystemProfileEntries -AppExpectation $expectation -SecondPass
    $rows = @($check.Results | ForEach-Object { New-TestPlanRow -Check $_.Assertion -Result $_.Result -Detail $_.Detail })

    if ($SystemEngine -eq 'WinGetClient') {
        # Both outcomes are acceptable: the engine ran, or it was NOT READY and winget.exe took over.
        $engine = $null
        $engineReason = ''
        if ($taskRun.Transcript) {
            $engine = $taskRun.Transcript.Parsed.InstallEngine
            $engineReason = [string]$taskRun.Transcript.Parsed.WingetClientModuleNotReadyReason
        }
        if ($engine -eq 'WinGetClient') {
            $rows += New-TestPlanRow -Check 'Install engine outcome' -Result 'PASS' -Detail "ran through Microsoft.WinGet.Client ($($taskRun.Transcript.Parsed.InstallEngineLine))"
        }
        elseif ($engineReason) {
            $rows += New-TestPlanRow -Check 'Install engine outcome' -Result 'PASS' -Detail "NOT READY, fell back to winget.exe: $engineReason"
        }
        else {
            $rows += New-TestPlanRow -Check 'Install engine outcome' -Result 'FAIL' -Detail 'no Install engine line and no NOT READY reason in the transcript'
        }
        $recordEngine = $null
        if ($taskRun.RunRecordRead.Record -and $taskRun.RunRecordRead.Record.PSObject.Properties['installEngine']) {
            $recordEngine = $taskRun.RunRecordRead.Record.installEngine
        }
        $rows += New-TestPlanBoolRow -Check 'last-run.json records the install engine' -Passed ($null -ne $recordEngine) -Detail $(if ($recordEngine) { "requested $($recordEngine.requested), used $($recordEngine.used)" } else { 'no installEngine in last-run.json' })
    }
    return $rows
}

# Stage 6 TimeBudget (item 8): uninstall 7-Zip, run with a spent budget (exit 9), then finish.
function Invoke-RealPcTimeBudgetStage {
    $rows = @()
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $appId = '7zip.7zip'

    try {
        $null = & winget uninstall --id $appId --exact --silent --accept-source-agreements --disable-interactivity 2>&1
        $uninstallCode = $LASTEXITCODE
    }
    catch {
        $uninstallCode = -1
    }
    $rows += New-TestPlanBoolRow -Check "Uninstalled $appId before the budget run" -Passed (-not (Test-RealPcWingetInstalled -Id $appId)) -Detail "winget uninstall exit $uninstallCode"

    # A deterministic spent budget: -MaxRuntimeMinutes 1 and a deadline already in the past.
    $pastDeadline = ([DateTime]::UtcNow.AddMinutes(-5)).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $startedAt = Get-Date
    $exitCode = Invoke-RealPcInstaller -ExtraArgument @('-MaxRuntimeMinutes', '1', '-RunDeadlineUtc', $pastDeadline) -Environment @{ WINGET_APP_SETUP_NONINTERACTIVE = '1' }
    $record = (Read-SystemPassRunRecord -Path (Join-Path $logDirectory 'last-run.json')).Record
    $resultLine = Get-RealPcResultLine -LogDirectory $logDirectory -Since $startedAt
    $rows += Get-RealPcTimeBudgetSpentResult -ExitCode ([int]$exitCode) -RunRecord $record -ResultLine $resultLine -AppId $appId

    # Finish without a budget.
    $startedAt = Get-Date
    $finishExit = Invoke-RealPcInstaller -Environment @{ WINGET_APP_SETUP_NONINTERACTIVE = '1' }
    $finishRecord = (Read-SystemPassRunRecord -Path (Join-Path $logDirectory 'last-run.json')).Record
    $rows += Get-RealPcTimeBudgetFinishResult -ExitCode ([int]$finishExit) -RunRecord $finishRecord -AppId $appId
    return $rows
}

# Stage 7 Diagnostics (item 6): the -CollectDiagnostics bundle and the secret-leak check.
function Invoke-RealPcDiagnosticsStage {
    $invocation = Get-RealPcInstallerInvocation
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $installer = Join-Path $repoRoot 'winget-app-install.ps1'
    $powerShell = Get-RealPcWindowsPowerShellPath
    $output = & $powerShell -NoProfile -ExecutionPolicy Bypass -File $installer -CollectDiagnostics 2>&1 | Out-String
    Write-Host $output
    $zipPath = $null
    if ($output -match 'Diagnostics bundle saved:\s*(.+\.zip)') {
        $zipPath = $Matches[1].Trim()
    }
    if (-not $zipPath -or -not (Test-Path -LiteralPath $zipPath)) {
        return @(New-TestPlanRow -Check 'Diagnostics bundle created' -Result 'FAIL' -Detail 'no bundle path in the output, or the file is missing')
    }
    $script:DiagnosticsZipPath = $zipPath

    $entryName = @()
    $entryText = @{}
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $entryName += $entry.FullName
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try {
                    $entryText[$entry.FullName] = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        return @(New-TestPlanRow -Check 'Diagnostics bundle readable' -Result 'FAIL' -Detail $_.Exception.Message)
    }
    $secrets = @($script:TightVncPassword)
    if ($script:LinkGuard.TempUserName) {
        $secrets += $script:LinkGuard.TempUserName
    }
    $rows = @(New-TestPlanRow -Check 'Diagnostics bundle created' -Result 'PASS' -Detail $zipPath)
    $rows += Get-RealPcDiagnosticsResult -EntryName $entryName -EntryText $entryText -Secret $secrets
    return $rows
}

# Stage 8 Uninstaller (item 9): -WhatIf preview, then a real elevated uninstall.
function Invoke-RealPcUninstallerStage {
    $rows = @()
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $uninstaller = Join-Path $repoRoot 'winget-app-uninstall.ps1'
    $powerShell = Get-RealPcWindowsPowerShellPath
    $catalogId = @($script:CatalogId)
    if ($catalogId.Count -eq 0) {
        $catalogId = Get-RealPcCatalogId
    }

    $beforeInstalled = Get-RealPcInstalledCatalogId -CatalogId $catalogId
    $beforeWau = (Get-RealPcWauTaskHealth).Exists
    $null = & $powerShell -NoProfile -ExecutionPolicy Bypass -File $uninstaller -WhatIf 2>&1 | Out-Host
    $afterInstalled = Get-RealPcInstalledCatalogId -CatalogId $catalogId
    $afterWau = (Get-RealPcWauTaskHealth).Exists

    $realExit = Invoke-RealPcProcess -FilePath $powerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstaller, '-NonInteractive')
    $installedAfterReal = Get-RealPcInstalledCatalogId -CatalogId $catalogId
    $wauAfterReal = (Get-RealPcWauTaskHealth).Exists

    $rows += Get-RealPcUninstallerResult -WhatIfInstalledBefore $beforeInstalled -WhatIfInstalledAfter $afterInstalled -WhatIfWauBefore $beforeWau -WhatIfWauAfter $afterWau -ExitCode ([int]$realExit) -InstalledAfter $installedAfterReal -WauPresentAfter $wauAfterReal
    return $rows
}

<#
.SYNOPSIS
    The harness entry point: the safety gate, the stages in order, the report and the exit code.
#>
function Invoke-RealPcTestPlanMain {
    $script:MachineFacts = [ordered]@{}
    $script:LinkGuard = [pscustomobject]@{ VictimFolder = $null; VictimBefore = @(); TempUser = $null; TempUserName = $null; PlantedAsAdmin = $false; Planted = $false }
    $script:CatalogId = @()
    $script:TightVncPassword = New-RealPcRandomSecret -Length 16
    $script:DiagnosticsZipPath = $null
    $script:FirstRunDone = $false

    $whatIf = $WhatIf -or $Plan
    if (-not $ReportPath) {
        $ReportPath = Join-Path $env:PUBLIC ('winget-app-setup-testplan-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }
    $script:ReportFolder = $ReportPath

    $resolution = Resolve-RealPcTestPlanStage -Requested $Stage -Skip $SkipStage -IncludeOptional @($(if ($IncludeWinGetClient) { 'WinGetClient' }))
    if ($resolution.Errors.Count -gt 0) {
        foreach ($resolveError in $resolution.Errors) {
            Write-RealPcLine $resolveError 'Red'
        }
        exit 2
    }
    foreach ($explanation in $resolution.Explanations) {
        Write-RealPcLine $explanation 'Yellow'
    }

    $publicVictim = Join-Path $env:PUBLIC 'winget-app-setup-victim-<timestamp>'
    foreach ($line in (Get-RealPcChangePlan -Stages $resolution.Stages -ReportFolder $script:ReportFolder -PublicVictimFolder $publicVictim)) {
        Write-RealPcLine $line 'Cyan'
    }
    Write-RealPcLine ('Stages: ' + (@($resolution.Stages | ForEach-Object { $_.Name }) -join ' -> ')) 'Cyan'

    if ($whatIf) {
        $gate = Get-RealPcGateDecision -PlanOnly
        Write-RealPcLine ''
        Write-RealPcLine ("-WhatIf / -Plan: {0}" -f $gate.Reason) 'Green'
        exit $gate.ExitCode
    }

    # Safety gate. Elevation first; then the disposable-machine confirmation (the typed phrase, or
    # -ConfirmDisposableMachine for unattended use). The decision itself is Get-RealPcGateDecision.
    $elevated = Test-RealPcElevated
    $confirmed = [bool]$ConfirmDisposableMachine
    if ($elevated -and -not $confirmed) {
        Write-RealPcLine ''
        Write-RealPcLine "This installs and removes apps and changes %ProgramData%. Run it only on a DISPOSABLE test machine." 'Yellow'
        Write-RealPcLine ("To confirm, type exactly: {0}" -f $script:DisposableConfirmationPhrase) 'Yellow'
        $answer = ''
        try {
            $answer = Read-Host 'Confirmation'
        }
        catch {
            $answer = ''
        }
        $confirmed = ($answer -eq $script:DisposableConfirmationPhrase)
    }
    $gate = Get-RealPcGateDecision -Elevated $elevated -Confirmed $confirmed
    if (-not $gate.Proceed) {
        Write-RealPcLine $gate.Reason 'Red'
        exit $gate.ExitCode
    }

    [void](New-Item -ItemType Directory -Path $script:ReportFolder -Force -ErrorAction SilentlyContinue)
    $transcriptPath = Join-Path $script:ReportFolder 'harness-transcript.log'
    try {
        [void](Start-Transcript -Path $transcriptPath -ErrorAction Stop)
    }
    catch {
        Write-RealPcLine "Could not start the harness transcript: $($_.Exception.Message)" 'Yellow'
    }

    $stageResults = @()
    $toRun = @($resolution.Stages | Where-Object { $_.Name -ne 'Report' })
    try {
        foreach ($stage in $toRun) {
            Write-RealPcLine ''
            Write-RealPcLine ("=== Stage {0} {1} (item {2}): {3} ===" -f $stage.Number, $stage.Name, $stage.Item, $stage.Summary) 'Cyan'
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $rows = @()
            try {
                switch ($stage.Name) {
                    'Preflight' { $rows = Invoke-RealPcPreflightStage; $script:CatalogId = Get-RealPcCatalogId }
                    'LinkGuardSetup' { $rows = Invoke-RealPcLinkGuardSetupStage }
                    'FirstRun' { $rows = Invoke-RealPcFirstRunStage }
                    'ReRun' { $rows = Invoke-RealPcReRunStage }
                    'System' { $rows = Invoke-RealPcSystemStage }
                    'WinGetClient' { $rows = Invoke-RealPcSystemStage -SystemEngine 'WinGetClient' }
                    'TimeBudget' { $rows = Invoke-RealPcTimeBudgetStage }
                    'Diagnostics' { $rows = Invoke-RealPcDiagnosticsStage }
                    'Uninstaller' { $rows = Invoke-RealPcUninstallerStage }
                    default { $rows = @() }
                }
            }
            catch {
                $rows = @(New-TestPlanRow -Check "Stage $($stage.Name) ran" -Result 'FAIL' -Detail "the stage stopped on an error: $($_.Exception.Message)")
            }
            $stopwatch.Stop()
            $stageResult = [pscustomobject]@{ Name = $stage.Name; Number = $stage.Number; Item = $stage.Item; DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds; Rows = @($rows) }
            $stageResults += $stageResult
            foreach ($row in $rows) {
                $color = 'Gray'
                if ($row.Result -eq 'FAIL') {
                    $color = 'Red'
                }
                elseif ($row.Result -eq 'PASS') {
                    $color = 'Green'
                }
                Write-RealPcLine ("  [{0}] {1}: {2}" -f $row.Result, $row.Check, $row.Detail) $color
            }
        }
    }
    finally {
        Remove-RealPcLinkGuardArtifact
    }

    # Stage 9 Report.
    $manual = Get-RealPcManualLeftover
    $reportMd = Format-RealPcReport -MachineFacts $script:MachineFacts -StageResult $stageResults -ManualLeftovers $manual -Markdown
    $reportTxt = Format-RealPcReport -MachineFacts $script:MachineFacts -StageResult $stageResults -ManualLeftovers $manual
    [System.IO.File]::WriteAllText((Join-Path $script:ReportFolder 'report.md'), $reportMd, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $script:ReportFolder 'report.txt'), $reportTxt, (New-Object System.Text.UTF8Encoding($false)))

    # The throwaway TightVNC test password, for item 5's manual viewer step only: in the report
    # folder, clearly labelled, never in the diagnostics bundle (the Diagnostics stage checks that).
    $manualSteps = @(
        'Manual steps for this test machine (throwaway values; this machine is disposable):',
        ('  TightVNC test password (connect a viewer to confirm item 5): {0}' -f $script:TightVncPassword),
        '  Delete this machine (or roll back the checkpoint) when done.'
    )
    [System.IO.File]::WriteAllText((Join-Path $script:ReportFolder 'manual-steps.txt'), ($manualSteps -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

    try {
        [void](Stop-Transcript)
    }
    catch {
    }

    # Gather the evidence into the report folder, then zip the whole folder.
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $evidence = Join-Path $script:ReportFolder 'evidence'
    [void](New-Item -ItemType Directory -Path $evidence -Force -ErrorAction SilentlyContinue)
    try {
        Copy-Item -Path (Join-Path $logDirectory '*.log') -Destination $evidence -ErrorAction SilentlyContinue
        Copy-Item -Path (Join-Path $logDirectory 'last-run.json') -Destination $evidence -ErrorAction SilentlyContinue
    }
    catch {
    }
    if ($script:DiagnosticsZipPath -and (Test-Path -LiteralPath $script:DiagnosticsZipPath)) {
        Copy-Item -LiteralPath $script:DiagnosticsZipPath -Destination $evidence -ErrorAction SilentlyContinue
    }
    $zipPath = $script:ReportFolder.TrimEnd('\') + '.zip'
    try {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($script:ReportFolder, $zipPath)
    }
    catch {
        Write-RealPcLine "Could not create the report zip: $($_.Exception.Message)" 'Yellow'
        $zipPath = $null
    }

    $allRows = @($stageResults | ForEach-Object { $_.Rows })
    $exitCode = Get-RealPcExitCode -Rows $allRows
    $overall = 'PASS'
    if ($exitCode -ne 0) {
        $overall = 'FAIL'
    }
    Write-RealPcLine ''
    Write-RealPcLine ("Overall: {0}" -f $overall) $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
    Write-RealPcLine ("Report folder: {0}" -f $script:ReportFolder) 'Cyan'
    if ($zipPath) {
        Write-RealPcLine ("Send this zip back: {0}" -f $zipPath) 'Cyan'
    }
    exit $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RealPcTestPlanMain
}

