<#
.SYNOPSIS
    Runs every automatable item of PR #285's owner test plan on a disposable Windows test machine,
    as one command, and writes one pass/fail report plus one zip to send back (bead wgt-gq8.60).
.DESCRIPTION
    An administrator runs this on a DISPOSABLE Windows 10 22H2+ or Windows 11 test machine (a VM
    with a checkpoint, or a spare PC; internet access; signed in as an administrator, or as another
    user with the window elevated as an administrator: cross-user elevation). It installs
    and removes apps, sets up and removes Winget-AutoUpdate, changes %ProgramData%\winget-app-setup,
    creates a temporary local user, registers one-shot scheduled tasks and writes a folder under
    C:\Users\Public. It is NOT for a work PC.

    It drives the checkout's own files: winget-app-install.ps1, winget-app-uninstall.ps1,
    rmm\Invoke-WingetAppSetup.ps1, the e2e helpers and the WingetAppSetup module (for the catalog's
    applicability, read in a child Windows PowerShell so the module never loads into this process).
    It STARTS under Windows PowerShell 5.1, which a fresh PC has (the file is 5.1-safe and ASCII
    only, like the rmm scripts).

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

    Every install run's console output is saved per stage (evidence\<n>-<stage>\console*.txt): the
    installer prints its 'was a link ... removed' warning before its transcript starts, so only the
    console has it. After each stage, the transcripts, last-run.json and the winget logs it wrote are
    copied into that stage's evidence folder, and the Apps & features entries are written to arp.txt
    there before Preflight and after each stage that installs or uninstalls (evidence only). The
    TimeBudget stage's own 'winget uninstall' output goes to winget-uninstall.txt in its folder.

    Preflight records who runs the harness and who is signed in (the owner of the oldest
    explorer.exe in its session, as the installer reads it: cross-user elevation), the build
    id of the installer under test, winget's version and source state
    (evidence\0-Preflight\winget-info.txt), and checks that winget can open its 'winget' source in
    this account; FirstRun checks that again, and so does the Uninstaller stage before it runs.
    When it cannot, winget reads every installed app as 'not installed' here, so the rows that ask
    it are SKIP or FAIL, never PASS, the uninstaller must refuse (exit 2) and keep
    Winget-AutoUpdate unless it opens the source itself, and the report starts with a warning.
    Preflight's failed check is SKIP once the latest check opened the source: that was the PC
    before the run, and the row and the warning name the check that opened it.

    FirstRun also checks that the installer registered winget's source package itself when
    Preflight found it missing (0x8A15000F), and that it detected the cross-user elevation exactly
    when Preflight did. Under cross-user elevation the installer installs machine-wide only, as
    SYSTEM does, so FirstRun and ReRun accept an app deferred for want of a machine-wide installer
    and judge Windows Terminal by its provisioning. The harness's own winget calls have time limits
    (list 45 s, search 120 s, uninstall 150 s); one that runs out reads as 'winget could not answer'.

    Never prints or stores a real secret. The temporary standard user's name and password are random
    and never printed, and the password is never written to disk: it stays in memory until its
    planting task is registered, and Task Scheduler stores none (S4U). One exception: a random
    8-character TightVNC test password (TightVNC uses 8; item 5's configuration half) is written to
    manual-steps.txt in winget-app-setup-localsecrets-<time> (Get-RealPcLocalFolderPath), next to
    the report folder, named so a wildcard on the report folder's name cannot match it, and never
    zipped or uploaded, so the operator can connect a viewer. The Diagnostics stage checks that the
    bundle does not contain it or the temporary user's name, and the Report stage checks every file
    that goes into the zip and the zip itself, and leaves out any file that holds it.
.PARAMETER Stage
    Run only these stages (by name; Preflight and Report always run). Their dependencies are added
    and the additions are explained. LinkGuardSetup also brings FirstRun, which checks and removes
    the junction it plants. Default: every stage.
.PARAMETER SkipStage
    Skip these stages. A stage other stages depend on cannot be skipped while they run; the refusal
    names it. Preflight and Report cannot be skipped.
.PARAMETER TimeoutMinutes
    The time limit of each install run: the installer's own time budget
    (WINGET_APP_SETUP_MAX_RUNTIME_MINUTES) for the first run, the re-run and the time-budget stage's
    finishing run, and the scheduled task's limit for the SYSTEM runs. A run that overruns ends with
    its own report (exit 9 for an install run). The diagnostics and uninstaller runs have no limit of
    their own here; every winget call they make has one. Default 60.
.PARAMETER ReportPath
    The report folder; it must not exist yet, or be empty, and '<ReportPath>.zip' must not exist.
    Default: %PUBLIC%\winget-app-setup-testplan-<yyyyMMdd-HHmmss>. The folder that must never be
    sent goes next to it (Get-RealPcLocalFolderPath).
.PARAMETER UseOneLiner
    Run the installer as 'irm <raw branch URL> | iex' (the production one-liner) instead of the
    checkout's file, for the install stages. A one-liner run under Windows PowerShell downloads the
    installer again for its PowerShell 7 relaunch, from main; the harness answers that download with
    the branch's file, as e2e/Invoke-InstallPass.ps1 does with the checkout's. A run that needs
    arguments (the spent time budget) runs '& ([scriptblock]::Create((irm <url>))) <arguments>'. The
    diagnostics and uninstaller stages always run the checkout's files.
.PARAMETER Branch
    The branch the one-liner fetches from. Default: claude/trusting-dirac-foyiaa.
.PARAMETER IncludeWinGetClient
    Also run stage 5 (the SYSTEM pass with -SystemInstallEngine WinGetClient). Off by default.
.PARAMETER ResetProgramData
    When %ProgramData%\winget-app-setup already exists, rename it aside to
    winget-app-setup-old-<time> (never delete it) so stage 1 can run the link guard on a fresh folder.
    Without it, a non-fresh machine skips stage 1 and warns.
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
    elevated, not confirmed disposable, an unknown stage name, or a -ReportPath in use). Runs under
    Windows PowerShell 5.1 and PowerShell 7: ASCII only, no PowerShell-7-only syntax.
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
$script:PlantTaskName = 'winget-app-setup-plantjunction'
# The sentinel a child Windows PowerShell writes before its JSON result (Invoke-RealPcModuleJson).
$script:ModuleJsonSentinel = 'WGT-TESTPLAN-JSON:'
# winget's APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND (0x8A150014): 'winget list' found no package.
$script:WingetNoPackageFoundExitCode = -1978335212
# winget's APPINSTALLER_CLI_ERROR_SOURCE_DATA_MISSING (0x8A15000F): no source package for the account.
$script:WingetSourceDataMissingExitCode = -1978335217
# The time limits of the harness's own winget calls, in seconds (Invoke-RealPcWinget). The search
# opens the source as the installer's own check does, with its limit ('WingetSourceOpen', 120 s).
$script:RealPcWingetListTimeoutSeconds = 45
$script:RealPcWingetSearchTimeoutSeconds = 120
$script:RealPcWingetUninstallTimeoutSeconds = 150
# The reason a machine-wide-only run defers an app winget has no machine-scope installer for
# (Get-AppDeferReasonText 'NoMachineScopeInstaller', WingetAppSetup/Private/FailureReporting.ps1).
$script:NoMachineScopeDeferReason = 'winget found no machine-wide installer for it'
# The reasons the uninstaller gives for an app it keeps on purpose ('Skipping: <id> (<reason>...').
$script:UninstallerKeptReasons = @(
    'this uninstaller is running in PowerShell 7',
    'Windows Terminal hosts this window',
    'a per-user app that this run cannot remove'
)
# The winget result codes the report names (AppInstallerErrors.h), by their hex digits.
$script:RealPcWingetCodeName = @{
    '8A15000B' = 'SOURCES_INVALID'
    '8A15000F' = 'SOURCE_DATA_MISSING'
    '8A150012' = 'SOURCE_NAME_DOES_NOT_EXIST'
    '8A150014' = 'NO_APPLICATIONS_FOUND'
    '8A150030' = 'EXEC_UNINSTALL_COMMAND_FAILED'
    '8A150045' = 'SOURCE_OPEN_FAILED'
    '8A150046' = 'SOURCE_AGREEMENTS_NOT_ACCEPTED'
    '8A15004B' = 'FAILED_TO_OPEN_ALL_SOURCES'
}
# The source checks so far (Add-RealPcWingetSourceCheck) and the latest outcome: $true when winget
# opened its 'winget' source in this account, $false when it could not, $null before any check.
$script:WingetSourceChecks = @()
$script:WingetSourceOpen = $null

# This script's arguments, taken before the dot-source below: the dot-sourced scripts' param blocks
# bind their own defaults into this scope, and one name, TimeoutMinutes, collides with this script's.
$script:HarnessArguments = @{
    Stage                    = @($Stage | Where-Object { $_ })
    SkipStage                = @($SkipStage | Where-Object { $_ })
    TimeoutMinutes           = $TimeoutMinutes
    ReportPath               = $ReportPath
    UseOneLiner              = [bool]$UseOneLiner
    Branch                   = $Branch
    IncludeWinGetClient      = [bool]$IncludeWinGetClient
    ResetProgramData         = [bool]$ResetProgramData
    ConfirmDisposableMachine = [bool]$ConfirmDisposableMachine
    WhatIf                   = [bool]$WhatIf
    Plan                     = [bool]$Plan
}
$script:StageTimeoutMinutes = $TimeoutMinutes
$script:RealPcOptions = [pscustomobject]@{ UseOneLiner = [bool]$UseOneLiner; Branch = $Branch; ResetProgramData = [bool]$ResetProgramData }

# Reuse the e2e SYSTEM-pass helpers (which dot-source Invoke-InstallPass.ps1 and
# TranscriptAssertions.ps1): Get-InstallPassVerdict and the transcript parser for the install
# checks, and Get-SystemPassAppExpectation, Invoke-SystemPassTask and Get-SystemInstallPassResult
# for the SYSTEM stages.
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
    NeedsAfter names the stages that must run after this one because they check and undo what it
    changed (LinkGuardSetup plants a junction that only FirstRun removes). AlwaysRun stages
    (Preflight, Report) cannot be skipped and are always included. Optional is set for a stage that
    only runs when asked (WinGetClient, by -IncludeWinGetClient).
.RETURNS
    [pscustomobject[]] in run order, with Name, Number, Summary, Item, DependsOn ([string[]]),
    NeedsAfter ([string[]]), AlwaysRun ([bool]) and Optional ([bool]).
#>
function Get-RealPcTestPlanStage {
    return @(
        [pscustomobject]@{ Name = 'Preflight'; Number = 0; Item = '0'; AlwaysRun = $true; Optional = $false; DependsOn = @(); NeedsAfter = @(); Summary = 'admin, who is signed in, OS, PowerShell, internet, winget and its source, disk, catalog apps already installed, existing ProgramData' }
        [pscustomobject]@{ Name = 'LinkGuardSetup'; Number = 1; Item = '11'; AlwaysRun = $false; Optional = $false; DependsOn = @('Preflight'); NeedsAfter = @('FirstRun'); Summary = 'plant a junction at ProgramData\winget-app-setup as a temporary standard user (only when the folder does not exist)' }
        [pscustomobject]@{ Name = 'FirstRun'; Number = 2; Item = '1+4+5+11'; AlwaysRun = $false; Optional = $false; DependsOn = @('Preflight', 'LinkGuardSetup'); NeedsAfter = @(); Summary = 'first unattended install; verify apps, WAU, runtime, TightVNC, the link guard, the cross-user detection and the source repair' }
        [pscustomobject]@{ Name = 'ReRun'; Number = 3; Item = '2'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); NeedsAfter = @(); Summary = 're-run: everything already installed, nothing reinstalled' }
        [pscustomobject]@{ Name = 'System'; Number = 4; Item = '3'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); NeedsAfter = @(); Summary = 'SYSTEM run through the Endpoint Central machine-phase wrapper' }
        [pscustomobject]@{ Name = 'WinGetClient'; Number = 5; Item = '10'; AlwaysRun = $false; Optional = $true; DependsOn = @('FirstRun'); NeedsAfter = @(); Summary = 'SYSTEM run with the Microsoft.WinGet.Client engine (opt-in)' }
        [pscustomobject]@{ Name = 'TimeBudget'; Number = 6; Item = '8'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); NeedsAfter = @(); Summary = 'uninstall one app, run with a spent budget (exit 9), then finish (exit 0/3010)' }
        [pscustomobject]@{ Name = 'Diagnostics'; Number = 7; Item = '6'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); NeedsAfter = @(); Summary = '-CollectDiagnostics bundle; verify entries and no secret leak' }
        [pscustomobject]@{ Name = 'Uninstaller'; Number = 8; Item = '9'; AlwaysRun = $false; Optional = $false; DependsOn = @('FirstRun'); NeedsAfter = @(); Summary = 'uninstaller -WhatIf, then a real elevated uninstall' }
        [pscustomobject]@{ Name = 'Report'; Number = 9; Item = '-'; AlwaysRun = $true; Optional = $false; DependsOn = @(); NeedsAfter = @(); Summary = 'clean up, write report.md and report.txt, check the zip for the test password, and zip' }
    )
}

<#
.SYNOPSIS
    Resolves which stages run, in order, from -Stage, -SkipStage and -IncludeWinGetClient, adding any
    dependencies a requested stage needs and explaining the additions and the skips.
.DESCRIPTION
    With no -Stage, every stage runs except the optional ones that were not asked for. With -Stage,
    only those stages (plus the always-run ones, the dependencies they pull in and the stages that
    must follow them, NeedsAfter) run. -SkipStage removes a stage, unless a stage that still runs
    depends on it or needs it after; then it is refused and kept. An unknown name in either list is
    refused. The result is in the registry's order.
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
    stage was added or a skip refused) and Errors ([string[]], an unknown name; empty when the
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

    # Pull in dependencies and the stages that must follow, repeatedly, so what they pull in is
    # added too.
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($name in @($selected)) {
            foreach ($dependency in @($byName[$name].DependsOn)) {
                if (-not $selected.Contains($dependency)) {
                    [void]$selected.Add($dependency)
                    $changed = $true
                    if ($requested.Count -gt 0 -and $requested -notcontains $dependency) {
                        $explanations += "Added '$dependency': '$name' depends on it."
                    }
                }
            }
            foreach ($follower in @($byName[$name].NeedsAfter)) {
                if (-not $selected.Contains($follower)) {
                    [void]$selected.Add($follower)
                    $changed = $true
                    $explanations += "Added '$follower': '$name' changes this PC in a way only '$follower' checks and undoes."
                }
            }
        }
    }

    foreach ($name in $skip) {
        $entry = $byName[$name]
        if ($entry.AlwaysRun) {
            $explanations += "Cannot skip '$name': it always runs."
            continue
        }
        if (-not $selected.Contains($name)) {
            continue
        }
        $neededBy = @($selected | Where-Object { $_ -ne $name -and (@($byName[$_].DependsOn) -contains $name -or @($byName[$_].NeedsAfter) -contains $name) })
        if ($neededBy.Count -gt 0) {
            $explanations += "Cannot skip '$name': $($neededBy -join ', ') need(s) it. It stays."
            continue
        }
        [void]$selected.Remove($name)
    }

    $stages = @($Registry | Where-Object { $selected.Contains($_.Name) })
    return [pscustomobject]@{ Stages = $stages; Explanations = $explanations; Errors = @() }
}

# ======================================================================================
# Result rows (pure)
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

# The detail for an exit code that could not be read (the program did not start, or did not end).
function Get-RealPcNoExitCodeDetail {
    return 'exit code not read: the program did not start, or did not finish'
}

# The detail of a row that asks winget what is installed in this account, when the source check
# failed: winget then reads every installed app as not installed here.
function Get-RealPcWingetBlindDetail {
    return "winget cannot see this account's apps: it could not open its 'winget' source here (see 'winget can open its source in this account')"
}

<#
.SYNOPSIS
    A winget exit code as the report shows it, e.g. '0x8A15000F (SOURCE_DATA_MISSING)', or
    'no exit code' when winget did not run to the end.
.PARAMETER ExitCode
    The exit code, or $null.
.RETURNS
    [string]
#>
function Format-RealPcWingetExitCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    if ($null -eq $ExitCode) {
        return 'no exit code'
    }
    $hex = '{0:X8}' -f [int]$ExitCode
    $text = '0x' + $hex
    if ($script:RealPcWingetCodeName.ContainsKey($hex)) {
        $text += ' (' + $script:RealPcWingetCodeName[$hex] + ')'
    }
    return $text
}

<#
.SYNOPSIS
    The source check's row: whether winget could open its 'winget' source in the account the
    harness runs as ('winget search --id Microsoft.PowerShell --exact --source winget').
.DESCRIPTION
    PASS only on exit 0; anything else fails and names the code. Without the source, 'winget list'
    and 'winget uninstall' without --source only warn and answer 'no package found' for an
    installed app, so every installed-state answer in this account is blind. 0x8A15000F means the
    account has no registered source package (Microsoft.Winget.Source_8wekyb3d8bbwe), as when
    winget's own registration of it fails under cross-user elevation (0x80073D19, issue #159).
    With -OpenedLater, a failed check is SKIP: the PC's state before the first run is no product
    result once a later check opened the source (Update-RealPcPreflightSourceRow).
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.PARAMETER When
    Which check this is, for the row's name: empty for Preflight, e.g. 'after the first run'.
.PARAMETER SourcePackage
    The source package for this account: its version, 'not registered', or empty when unknown.
.PARAMETER OpenedLater
    When a later check opened the source: that check's label (e.g. 'after the first run').
.RETURNS
    One row (New-TestPlanRow).
#>
function Get-RealPcWingetSourceRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$When = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SourcePackage = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OpenedLater = ''
    )

    $check = 'winget can open its source in this account'
    if ($When) {
        $check += " ($When)"
    }
    $detail = 'winget search --id Microsoft.PowerShell --exact --source winget: ' + (Format-RealPcWingetExitCode -ExitCode $ExitCode)
    if ($SourcePackage) {
        $detail += "; Microsoft.Winget.Source for this account: $SourcePackage"
    }
    if ($null -ne $ExitCode -and [int]$ExitCode -eq 0) {
        return (New-TestPlanRow -Check $check -Result 'PASS' -Detail $detail)
    }
    $reason = ''
    if ($null -eq $ExitCode) {
        $reason = '; winget did not run to the end'
    }
    elseif ([int]$ExitCode -eq -1978335217) {
        $reason = '; its source package (Microsoft.Winget.Source_8wekyb3d8bbwe) is not registered for this account, which winget''s own registration fails to do under cross-user elevation (0x80073D19, issue #159)'
    }
    elseif ([int]$ExitCode -eq $script:WingetNoPackageFoundExitCode) {
        $reason = '; the source answered but did not find Microsoft.PowerShell'
    }
    if ($OpenedLater) {
        $detail += (". It opened {0}; until then winget could not see this account's apps, so the checks that asked it are SKIP{1}. This is the PC's state before the run, not a product result" -f $OpenedLater, $reason)
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail $detail)
    }
    $detail += ". winget cannot see this account's apps, so the checks that ask it what is installed here are SKIP or FAIL" + $reason
    return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail $detail)
}

<#
.SYNOPSIS
    The source check that opened winget's source for good: the first check that opened after the
    last failed one, or $null while the latest check fails.
.DESCRIPTION
    A full run checks three times (Preflight, 'after the first run', 'before the uninstaller'):
    when the first run opened the source, the latest check only found it still open.
.PARAMETER SourceCheck
    The source checks (When, ExitCode, Opened, SourcePackage), in order.
.RETURNS
    The check, or $null.
#>
function Get-RealPcSourceOpenedCheck {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SourceCheck = @()
    )

    $checks = @($SourceCheck | Where-Object { $null -ne $_ })
    if ($checks.Count -eq 0 -or -not $checks[$checks.Count - 1].Opened) {
        return $null
    }
    $index = $checks.Count - 1
    while ($index -gt 0 -and $checks[$index - 1].Opened) {
        $index--
    }
    return $checks[$index]
}

<#
.SYNOPSIS
    Turns Preflight's failed source check into SKIP when the latest later check opened the source.
.DESCRIPTION
    Preflight sees the PC as it was before the first run: a source that only the installer's own
    repair registered is not a product failure. The row stays FAIL while the latest check fails.
    The row names the check that opened the source after the last failure
    (Get-RealPcSourceOpenedCheck).
.PARAMETER StageResult
    The stage results (Name, Number, Item, DurationSeconds, Rows).
.PARAMETER SourceCheck
    The source checks (When, ExitCode, Opened, SourcePackage), in order.
.RETURNS
    [object[]] the stage results, new objects where a row changed.
#>
function Update-RealPcPreflightSourceRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$StageResult = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SourceCheck = @()
    )

    $stages = @($StageResult | Where-Object { $null -ne $_ })
    $checks = @($SourceCheck | Where-Object { $null -ne $_ })
    if ($checks.Count -lt 2) {
        return $stages
    }
    $first = $checks[0]
    $opened = Get-RealPcSourceOpenedCheck -SourceCheck $checks
    if ($first.When -or $first.Opened -or $null -eq $opened) {
        return $stages
    }
    $check = 'winget can open its source in this account'
    $result = @()
    foreach ($stage in $stages) {
        if ($stage.Name -ne 'Preflight') {
            $result += $stage
            continue
        }
        $rows = @(foreach ($row in @($stage.Rows | Where-Object { $null -ne $_ })) {
                if ($row.Check -eq $check -and $row.Result -eq 'FAIL') {
                    Get-RealPcWingetSourceRow -ExitCode $first.ExitCode -SourcePackage ([string]$first.SourcePackage) -OpenedLater ([string]$opened.When)
                }
                else {
                    $row
                }
            })
        $result += [pscustomobject]@{ Name = $stage.Name; Number = $stage.Number; Item = $stage.Item; DurationSeconds = $stage.DurationSeconds; Rows = $rows }
    }
    return $result
}

<#
.SYNOPSIS
    Says whether the harness runs elevated as another account than the one signed in to its
    session (cross-user elevation, issue #159), comparing the two by SID.
.PARAMETER ElevatedUser
    This process's account name.
.PARAMETER ElevatedSid
    Its SID.
.PARAMETER SessionUser
    The owner of explorer.exe in this process's session, or empty when none was found.
.PARAMETER SessionUserSid
    That owner's SID, or empty.
.RETURNS
    [string] starting with 'yes', 'no' or 'unknown', then who is who.
#>
function Get-RealPcCrossUserElevation {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ElevatedUser = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ElevatedSid = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SessionUser = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SessionUserSid = ''
    )

    if ([string]::IsNullOrWhiteSpace($ElevatedSid)) {
        return 'unknown (this process''s account SID could not be read)'
    }
    if ([string]::IsNullOrWhiteSpace($SessionUserSid)) {
        return ('unknown (no signed-in user found in this session; elevated as {0})' -f $ElevatedUser)
    }
    if ([string]::Equals($ElevatedSid.Trim(), $SessionUserSid.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return ('no (signed in and elevated as {0})' -f $ElevatedUser)
    }
    return ('yes (signed in as {0} {1}, elevated as {2} {3})' -f $SessionUser, $SessionUserSid.Trim(), $ElevatedUser, $ElevatedSid.Trim())
}

# The first word of Get-RealPcCrossUserElevation's answer: 'yes', 'no', or 'unknown' for anything
# else (an empty fact included).
function Get-RealPcCrossUserAnswer {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CrossUser = ''
    )

    if ([string]$CrossUser -match '^\s*(yes|no)\b') {
        return $Matches[1].ToLowerInvariant()
    }
    return 'unknown'
}

<#
.SYNOPSIS
    The FirstRun row that says whether the installer saw the cross-user elevation Preflight found.
.DESCRIPTION
    The installer prints 'Cross-user elevation detected: ...' (WingetAppSetup/Public/WingetCore.ps1)
    and then installs machine-wide only. Without that line its cross-user handling did not run.
.PARAMETER CrossUser
    Get-RealPcCrossUserElevation's answer, or empty.
.PARAMETER Text
    The first run's console output and transcripts.
.RETURNS
    One row: PASS when the line is there exactly when Preflight said 'yes', FAIL when not, SKIP
    when Preflight could not tell.
#>
function Get-RealPcCrossUserDetectionRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CrossUser = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $check = 'The installer detected the cross-user elevation as Preflight did'
    $line = [regex]::Match([string]$Text, 'Cross-user elevation detected[^\r\n]*')
    $answer = Get-RealPcCrossUserAnswer -CrossUser $CrossUser
    if ($answer -eq 'yes') {
        if ($line.Success) {
            return (New-TestPlanRow -Check $check -Result 'PASS' -Detail ('Preflight: yes; the installer printed: {0}' -f $line.Value.Trim()))
        }
        return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail "Preflight: yes; the installer did not detect it (no 'Cross-user elevation detected' line), so its cross-user handling (machine-wide installs only) did not run")
    }
    if ($answer -eq 'no') {
        if ($line.Success) {
            return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail ('Preflight: no (the same account is signed in and elevated); the installer printed: {0}' -f $line.Value.Trim()))
        }
        return (New-TestPlanRow -Check $check -Result 'PASS' -Detail 'Preflight: no; the installer reported no cross-user elevation either')
    }
    $known = 'Preflight did not record who is signed in'
    if (-not [string]::IsNullOrWhiteSpace($CrossUser)) {
        $known = 'Preflight: ' + $CrossUser.Trim()
    }
    return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail $known)
}

<#
.SYNOPSIS
    The FirstRun row that says whether the installer registered winget's source package for this
    account itself (Register-WingetSourcePackage), when Preflight found it missing.
.DESCRIPTION
    The installer registers it only when its own source check answers 0x8A15000F
    (SOURCE_DATA_MISSING), and then prints 'The winget source package is registered for this
    account (from <url>).' or '(by family name, from the copy already on this PC).'
    (WingetAppSetup/Private/WingetBootstrap.ps1). That line passes whatever Preflight saw: Preflight
    makes no check before winget can be started in this account, and its check can run out of time.
    Without the line, the row is judged only when Preflight's check answered 0x8A15000F.
.PARAMETER PreflightCheck
    Preflight's source check (When '', ExitCode, Opened), or $null when it made none.
.PARAMETER AfterCheck
    The source check after the first run, or $null.
.PARAMETER Text
    The first run's console output and transcripts.
.RETURNS
    One row: PASS when the line is there, naming the route; FAIL when it is not and the source was
    still closed after the run; SKIP when the source opened without it, or the repair was not
    exercised.
#>
function Get-RealPcSourceRepairRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $PreflightCheck,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $AfterCheck,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $check = 'The installer registered winget''s source package for this account'
    $preflightCode = $null
    if ($null -ne $PreflightCheck -and $null -ne $PreflightCheck.ExitCode) {
        $preflightCode = [int]$PreflightCheck.ExitCode
    }
    if ($null -eq $PreflightCheck) {
        $preflightText = 'Preflight: no source check (winget could not be started in this account yet)'
    }
    elseif ($PreflightCheck.Opened) {
        $preflightText = 'Preflight: the source opened'
    }
    elseif ($preflightCode -eq $script:WingetSourceDataMissingExitCode) {
        $preflightText = 'Preflight: 0x8A15000F'
    }
    else {
        $preflightText = 'Preflight: ' + (Format-RealPcWingetExitCode -ExitCode $preflightCode)
    }
    $afterText = 'no source check after the first run'
    if ($null -ne $AfterCheck) {
        $afterText = 'the source check after the first run: ' + (Format-RealPcWingetExitCode -ExitCode $AfterCheck.ExitCode)
    }
    # The installer's own line first: it registers the package only after its own check answered
    # 0x8A15000F, whatever Preflight could see.
    $download = [regex]::Match([string]$Text, 'The winget source package is registered for this account \(from (?<url>[^\s)]+)\)\.')
    if ($download.Success) {
        return (New-TestPlanRow -Check $check -Result 'PASS' -Detail ('{0}; registered from {1}; {2}' -f $preflightText, $download.Groups['url'].Value, $afterText))
    }
    if ([string]$Text -match 'The winget source package is registered for this account \(by family name, from the copy already on this PC\)\.') {
        return (New-TestPlanRow -Check $check -Result 'PASS' -Detail ('{0}; registered from the copy already on this PC (by family name); {1}' -f $preflightText, $afterText))
    }

    if ($null -eq $PreflightCheck) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail 'not exercised: Preflight made no source check (winget was not on this PC yet), and the installer printed no ''registered for this account'' line')
    }
    if ($PreflightCheck.Opened) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail 'not exercised: winget''s source already opened before the first run; to exercise the repair, first run: Get-AppxPackage Microsoft.Winget.Source* | Remove-AppxPackage')
    }
    if ($preflightCode -ne $script:WingetSourceDataMissingExitCode) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail ('not the missing-package case: Preflight''s check answered {0}, not 0x8A15000F (SOURCE_DATA_MISSING), and the installer printed no ''registered for this account'' line' -f (Format-RealPcWingetExitCode -ExitCode $preflightCode)))
    }
    if ($null -ne $AfterCheck -and $AfterCheck.Opened) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail ("Preflight: 0x8A15000F; the source opened after the first run, but the run did not register the source package itself (no 'registered for this account' line)"))
    }
    if ($null -eq $AfterCheck) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail "Preflight: 0x8A15000F; no 'registered for this account' line, and no source check after the first run to tell whether the source opened")
    }
    $detail = "Preflight: 0x8A15000F; the installer's repair did not get the source open: no 'registered for this account' line, and " + $afterText
    $redLine = [regex]::Match([string]$Text, 'The winget source cannot be opened for [^\r\n]*')
    if ($redLine.Success) {
        $detail += ('. The installer said: {0}' -f $redLine.Value.Trim())
    }
    return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail $detail)
}

<#
.SYNOPSIS
    The warning the report starts with when winget could not open its source in the account the
    harness runs as.
.PARAMETER SourceCheck
    The source checks (When, ExitCode, Opened, SourcePackage), in order.
.PARAMETER Account
    The account the harness runs as.
.PARAMETER CrossUser
    Get-RealPcCrossUserElevation's answer, or empty.
.PARAMETER StageName
    The stages that ran: the installer's and the uninstaller's are named only when they ran.
.RETURNS
    [string[]] the lines; none when every check opened the source.
#>
function Get-RealPcReportBanner {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SourceCheck = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Account = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CrossUser = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$StageName = @()
    )

    $checks = @($SourceCheck | Where-Object { $null -ne $_ })
    $failed = @($checks | Where-Object { -not $_.Opened })
    if ($failed.Count -eq 0) {
        return @()
    }
    $who = 'the account this harness ran as'
    if ($Account) {
        $who += " ($Account)"
    }
    $when = @(foreach ($check in $failed) {
            $label = 'at Preflight'
            if ($check.When) {
                $label = [string]$check.When
            }
            '{0}: {1}' -f $label, (Format-RealPcWingetExitCode -ExitCode $check.ExitCode)
        }) -join '; '
    $lines = @(("WARNING: winget could not open its 'winget' source in {0} ({1})." -f $who, $when))
    # Named after the check that opened it after the last failure, not the latest check.
    $opened = Get-RealPcSourceOpenedCheck -SourceCheck $checks
    if ($null -ne $opened) {
        $label = 'at Preflight'
        if ($opened.When) {
            $label = [string]$opened.When
        }
        $lines += 'Until it opened, winget read every installed app as not installed there: the checks that asked it then are SKIP, never PASS.'
        $lines += ('It opened {0}, so the stages after that asked winget as usual.' -f $label)
    }
    else {
        $line = 'While it cannot, winget reads every installed app as not installed there: the checks that ask it are SKIP or FAIL, never PASS.'
        # Only the stages that ran here: the installer's (FirstRun, ReRun, TimeBudget) and the uninstaller's.
        $ran = @()
        if (@($StageName | Where-Object { @('FirstRun', 'ReRun', 'TimeBudget') -contains $_ }).Count -gt 0) {
            $ran += 'installer'
        }
        if (@($StageName) -contains 'Uninstaller') {
            $ran += 'uninstaller'
        }
        if ($ran.Count -gt 0) {
            $line += (' The {0} ran in this account with the same blind winget.' -f ($ran -join ' and the '))
        }
        $lines += $line
    }
    if ($CrossUser) {
        $lines += ('Cross-user elevation: {0}.' -f $CrossUser)
    }
    return $lines
}

# ======================================================================================
# Preflight and small verdicts (pure)
# ======================================================================================

<#
.SYNOPSIS
    Reads a 'winget list --id <id> --exact' exit code: installed, not installed, or no answer.
.DESCRIPTION
    0 means winget lists the package; 0x8A150014 (no package found) means it does not. Anything
    else (winget not found, a source error, a timeout, no exit code) is no answer, never 'not
    installed', so a removal check cannot pass on a winget that could not look.
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.RETURNS
    $true, $false, or $null for no answer.
#>
function Get-RealPcWingetListVerdict {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    if ($null -eq $ExitCode) {
        return $null
    }
    if ([int]$ExitCode -eq 0) {
        return $true
    }
    if ([int]$ExitCode -eq $script:WingetNoPackageFoundExitCode) {
        return $false
    }
    return $null
}

<#
.SYNOPSIS
    Rows for the reachability probes of the hosts the installer uses.
.PARAMETER Probe
    One object per host with Url, Reachable ([bool]) and Detail (the HTTP status, or why there was
    no answer). Any HTTP answer, an error status included, counts as reachable.
.RETURNS
    Assertion rows (New-TestPlanRow): one per host.
#>
function Get-RealPcReachabilityResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Probe = @()
    )

    $rows = @()
    foreach ($item in @($Probe | Where-Object { $null -ne $_ })) {
        $hostName = [string]$item.Url
        try {
            $hostName = ([System.Uri][string]$item.Url).Host
        }
        catch {
        }
        $rows += New-TestPlanBoolRow -Check "Internet: $hostName reachable" -Passed ([bool]$item.Reachable) -Detail ([string]$item.Detail)
    }
    return $rows
}

<#
.SYNOPSIS
    The Preflight row about catalog apps that are already installed (a non-fresh machine).
.PARAMETER CatalogId
    The catalog's package ids, or empty when they could not be read.
.PARAMETER Installed
    The ids winget lists as installed.
.PARAMETER Unknown
    The ids winget could not answer for.
.PARAMETER SourceOpen
    The source check's outcome: $false makes the row SKIP, since winget cannot see this account's
    apps; $null (not checked) changes nothing.
.RETURNS
    One row: PASS when none is installed, SKIP (a warning) when some are or winget could not tell.
#>
function Get-RealPcInstalledCatalogRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$CatalogId = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Installed = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Unknown = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$SourceOpen
    )

    $check = 'No catalog app installed yet'
    if (@($CatalogId).Count -eq 0) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail 'could not read the catalog from the checkout''s module')
    }
    if ($SourceOpen -eq $false) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail ((Get-RealPcWingetBlindDetail) + '. What Apps & features lists is in arp.txt in this stage''s evidence.'))
    }
    $installedIds = @($Installed | Where-Object { $_ })
    $unknownIds = @($Unknown | Where-Object { $_ })
    if ($installedIds.Count -gt 0) {
        $detail = 'already installed: {0}. The results describe a non-fresh machine: those apps are expected Skipped as already installed.' -f ($installedIds -join ', ')
        if ($unknownIds.Count -gt 0) {
            $detail += ' winget could not answer for: ' + ($unknownIds -join ', ')
        }
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail $detail)
    }
    if ($unknownIds.Count -gt 0) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail ('winget could not answer for: {0} (a fresh PC may not have winget registered yet)' -f ($unknownIds -join ', ')))
    }
    return (New-TestPlanRow -Check $check -Result 'PASS' -Detail ('none of the {0} catalog apps is installed' -f @($CatalogId).Count))
}

<#
.SYNOPSIS
    The 'Installer build' machine fact: the build id of the winget-app-install.ps1 the run uses.
.DESCRIPTION
    The build stamps '$script:InstallerBuildId = ''<id>''' into the installer
    (build/Build-WingetInstallScript.ps1), read here with Get-InstallerBuildIdFromScript. The
    one-liner downloads the installer, so its id comes from the first run's 'Installer build: <id>'
    line, once there is one.
.PARAMETER ScriptText
    The checkout's winget-app-install.ps1, or empty when it could not be read.
.PARAMETER UseOneLiner
    The install stages run the one-liner.
.PARAMETER Branch
    The branch the one-liner fetches from.
.PARAMETER RunBuildId
    The build id the first run printed, or empty.
.RETURNS
    [string]
#>
function Get-RealPcInstallerBuildFact {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ScriptText = '',

        [Parameter(Mandatory = $false)]
        [switch]$UseOneLiner,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Branch = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunBuildId = ''
    )

    if ($UseOneLiner) {
        if ($RunBuildId) {
            return ('{0} (one-liner from {1}, as the first run printed it)' -f $RunBuildId, $Branch)
        }
        return ('one-liner from {0}' -f $Branch)
    }
    $buildId = $null
    if ($ScriptText) {
        $buildId = Get-InstallerBuildIdFromScript -Content $ScriptText
    }
    if (-not $buildId) {
        return 'unknown (no build id in the checkout''s winget-app-install.ps1)'
    }
    return ('{0} (the checkout''s winget-app-install.ps1)' -f $buildId)
}

# The build id an installer run printed first ('Installer build: <id>'), or empty.
function Get-RealPcRunBuildId {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $match = [regex]::Match([string]$Text, '(?m)^\s*Installer build:\s+(?<id>\S+)\s*$')
    if ($match.Success) {
        return $match.Groups['id'].Value
    }
    return ''
}

<#
.SYNOPSIS
    Says why a -ReportPath cannot be used, or $null when it can.
.DESCRIPTION
    The harness writes into the folder, zips all of it into the zip the operator sends back, and
    writes '<path>.zip' and the local folder (Get-RealPcLocalFolderPath). So the folder must be new
    or empty and not a link, and neither the zip nor a non-empty local folder may exist already.
.PARAMETER Path
    The report folder.
.PARAMETER State
    Get-RealPcReportPathState's result: Exists, IsDirectory, IsEmpty, IsReparsePoint, ZipExists,
    LocalFolderInUse and LocalFolder.
.RETURNS
    [string] the problem, or $null.
#>
function Get-RealPcReportPathProblem {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $State
    )

    $localFolder = [string]$State.LocalFolder
    if (-not $localFolder) {
        $localFolder = Get-RealPcLocalFolderPath -ReportPath $Path
    }
    $problems = @()
    if ($State.IsReparsePoint) {
        $problems += "'$Path' is a link (a junction or symbolic link)"
    }
    elseif ($State.Exists -and -not $State.IsDirectory) {
        $problems += "'$Path' is a file"
    }
    elseif ($State.Exists -and -not $State.IsEmpty) {
        $problems += "'$Path' already exists and is not empty: everything in it would go into the zip"
    }
    if ($State.ZipExists) {
        $problems += "'$Path.zip' already exists"
    }
    if ($State.LocalFolderInUse) {
        $problems += "'$localFolder' already exists and is not empty"
    }
    if ($problems.Count -eq 0) {
        return $null
    }
    return (($problems -join '; ') + '. Give a new -ReportPath.')
}

<#
.SYNOPSIS
    The folder for what must never be sent (manual-steps.txt with the TightVNC test password, and
    any file held back from the zip): next to the report folder, under a name a wildcard on the
    report folder's name cannot match.
.DESCRIPTION
    winget-app-setup-testplan-<time> gets winget-app-setup-localsecrets-<time>; any other report
    folder <name> gets winget-app-setup-localsecrets-<name>, or localsecrets-<name> when that would
    start with <name> (so '<name>*' still cannot match it). Text only, so it runs on any OS.
.PARAMETER ReportPath
    The report folder's full path.
.RETURNS
    [string]
#>
function Get-RealPcLocalFolderPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $path = $ReportPath.TrimEnd('\', '/')
    $index = $path.LastIndexOfAny([char[]]@('\', '/'))
    $parent = ''
    $leaf = $path
    if ($index -ge 0) {
        $parent = $path.Substring(0, $index + 1)
        $leaf = $path.Substring($index + 1)
    }
    $name = 'winget-app-setup-localsecrets-' + $leaf
    if ($leaf -match '^winget-app-setup-testplan-(.+)$') {
        $name = 'winget-app-setup-localsecrets-' + $Matches[1]
    }
    if ($name.StartsWith($leaf, [System.StringComparison]::OrdinalIgnoreCase)) {
        $name = 'localsecrets-' + $leaf
    }
    return ($parent + $name)
}

<#
.SYNOPSIS
    The lines the run ends with: report.txt's exact path and a ready-to-paste command that copies
    it, the zip to send, a privacy note, and the folder never to send. Exact paths only, never a
    wildcard.
.DESCRIPTION
    The copy command reads report.txt as UTF-8 (the harness writes it without a BOM, which Windows
    PowerShell would read as ANSI) and quotes the path with EscapeSingleQuotedStringContent, which
    also doubles the typographic single quotes PowerShell treats as quotes. With -HoldsSecret (the
    report or the zip held the TightVNC test password) there is no copy command, only a warning.
.PARAMETER ReportTextPath
    report.txt's full path.
.PARAMETER ZipPath
    The zip, or empty when there is none.
.PARAMETER ManualStepsPath
    manual-steps.txt, or empty.
.PARAMETER LocalFolder
    The folder that holds the TightVNC test password, or empty.
.PARAMETER HoldsSecret
    The report or the zip held the TightVNC test password: nothing may be pasted or sent.
.RETURNS
    [string[]]
#>
function Get-RealPcFinishLine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ReportTextPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ZipPath = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ManualStepsPath = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LocalFolder = '',

        [Parameter(Mandatory = $false)]
        [switch]$HoldsSecret
    )

    $lines = @(('Report: {0}' -f $ReportTextPath))
    if ($HoldsSecret) {
        $lines += 'Do not paste or send this report, the report folder or a zip of it: the TightVNC test password was found in the report or the zip (see the lines above).'
    }
    else {
        $quoted = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($ReportTextPath)
        $lines += 'To copy it, paste this line into any PowerShell window:'
        $lines += ("  Get-Content -LiteralPath '{0}' -Raw -Encoding UTF8 | Set-Clipboard" -f $quoted)
    }
    if ($ZipPath -and -not $HoldsSecret) {
        $lines += ('Send this zip back: {0}' -f $ZipPath)
    }
    else {
        $lines += 'There is no zip to send (see the lines above).'
    }
    if (-not $HoldsSecret) {
        $lines += 'The report and the zip name this PC''s accounts and their SIDs: send them privately, or replace the names before you post them on a public issue or pull request.'
    }
    if ($ManualStepsPath) {
        $lines += ('Manual steps, with the throwaway TightVNC test password, for this PC only: {0}' -f $ManualStepsPath)
    }
    if ($LocalFolder) {
        $lines += ('Do not send {0}: it holds the TightVNC test password.' -f $LocalFolder)
    }
    return $lines
}

# ======================================================================================
# Install-run check evaluation (pure): items 1, 4, 5 and the re-run (item 2)
# ======================================================================================

<#
.SYNOPSIS
    Accepts a first-run install exit code: 0, 3010, or 8 with a stated reason; anything else is a
    failure, and so is an exit code that could not be read.
.DESCRIPTION
    Uses the e2e install-pass policy (Get-InstallPassVerdict from e2e/Invoke-InstallPass.ps1, which
    this script dot-sources). 8 is accepted only when the pass's transcript gives the missing
    Microsoft.WindowsAppRuntime.1.8 as the reason and the installer could not try to install it.
.PARAMETER ExitCode
    The installer's exit code, or $null when it was not read.
.PARAMETER Transcript
    The run's transcript (Get-InstallPassTranscript result: Name and Parsed), or $null.
.PARAMETER Pass
    'first', 'second' or 'budget', for the message.
.RETURNS
    [pscustomobject] with Passed ([bool]), Outcome ('passed', 'failed') and Message.
#>
function Get-RealPcInstallExitVerdict {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,

        [Parameter(Mandatory = $false)]
        [string]$Pass = 'first'
    )

    if ($null -eq $ExitCode) {
        return [pscustomobject]@{ Passed = $false; Outcome = 'failed'; Message = "The $Pass install pass: $(Get-RealPcNoExitCodeDetail)." }
    }
    $verdict = Get-InstallPassVerdict -ExitCode ([int]$ExitCode) -KnownPlatformIncompatible '' -Pass $Pass -Transcript $Transcript
    return [pscustomobject]@{ Passed = ($verdict.Outcome -eq 'passed'); Outcome = $verdict.Outcome; Message = $verdict.Message }
}

<#
.SYNOPSIS
    Says whether a run record was written by a run that started at or after a time.
.DESCRIPTION
    last-run.json is overwritten by every run, so a stage must not read the record an earlier run
    left. startedUtc is written as yyyy-MM-ddTHH:mm:ssZ (whole seconds); PowerShell 7 may hand it
    over as a [datetime]. Two seconds of slack cover the truncation.
.PARAMETER RunRecord
    last-run.json parsed.
.PARAMETER Since
    When the stage started the run.
.RETURNS
    [pscustomobject] with Fresh ([bool]) and Detail.
#>
function Test-RealPcRunRecordFresh {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )

    if ($null -eq $RunRecord) {
        return [pscustomobject]@{ Fresh = $false; Detail = 'no record' }
    }
    $value = $RunRecord.startedUtc
    $started = $null
    if ($value -is [datetime]) {
        $started = $value
        if ($started.Kind -eq [System.DateTimeKind]::Unspecified) {
            $started = [datetime]::SpecifyKind($started, [System.DateTimeKind]::Utc)
        }
        $started = $started.ToUniversalTime()
    }
    else {
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if ([datetime]::TryParseExact([string]$value, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            $started = $parsed
        }
    }
    if ($null -eq $started) {
        return [pscustomobject]@{ Fresh = $false; Detail = "last-run.json has no readable startedUtc ('$value')" }
    }
    $sinceUtc = $Since.ToUniversalTime().AddSeconds(-2)
    $startedText = $started.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $sinceText = $Since.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($started -lt $sinceUtc) {
        return [pscustomobject]@{ Fresh = $false; Detail = "last-run.json is from an earlier run (startedUtc $startedText, this run started $sinceText)" }
    }
    return [pscustomobject]@{ Fresh = $true; Detail = "startedUtc $startedText" }
}

<#
.SYNOPSIS
    Checks a run record (last-run.json, parsed): schema 1, the run reached its summary, the recorded
    exit code matches, and no app is Failed.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER RunRecordProblem
    Why there is no record (missing, unreadable, or from an earlier run), for the failed row.
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
        [AllowEmptyString()]
        [string]$RunRecordProblem,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExpectedExitCode
    )

    if ($null -eq $RunRecord) {
        $detail = 'no last-run.json for this run'
        if ($RunRecordProblem) {
            $detail = $RunRecordProblem
        }
        return @(New-TestPlanRow -Check 'last-run.json written' -Result 'FAIL' -Detail $detail)
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
    Turns an install run's expectations into those of a run that installs machine-wide only, as
    the installer does under cross-user elevation (and as SYSTEM).
.DESCRIPTION
    Get-SystemPassAppExpectation already gives what such a run decides from the catalog: per-user
    apps Deferred, and an msixName app judged by its provisioning ('already provisioned for every
    user on this PC'). What no catalog field predicts is an app winget has no machine-scope
    installer for: Install-WingetPackage -MachineScopeOnly defers it. So an Installed or
    AlreadyPresent expectation also accepts that deferral (DeferReasons), and its 'already there'
    skip must be one of its AlreadyPresentReasons, as for SYSTEM (MachineWide).
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result (Id, Expected, Reason, AlreadyPresentReasons,
    MustInstall).
.RETURNS
    [object[]] copies, with MachineWide $true and DeferReasons ([string[]]).
#>
function ConvertTo-RealPcMachineWideExpectation {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation = @()
    )

    return @(foreach ($expectation in @($AppExpectation | Where-Object { $null -ne $_ })) {
            $deferReasons = @()
            if (@('Installed', 'AlreadyPresent') -contains [string]$expectation.Expected) {
                $deferReasons = @($script:NoMachineScopeDeferReason)
            }
            [pscustomobject]@{
                Id                    = [string]$expectation.Id
                Expected              = [string]$expectation.Expected
                Reason                = $expectation.Reason
                AlreadyPresentReasons = [string[]]@(@($expectation.AlreadyPresentReasons) | Where-Object { $null -ne $_ })
                MustInstall           = [bool]$expectation.MustInstall
                MachineWide           = $true
                DeferReasons          = [string[]]$deferReasons
            }
        })
}

# Whether an expectation is for a machine-wide-only run (ConvertTo-RealPcMachineWideExpectation).
function Test-RealPcMachineWideExpectation {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Expectation
    )

    return ($null -ne $Expectation -and $null -ne $Expectation.PSObject.Properties['MachineWide'] -and [bool]$Expectation.MachineWide)
}

<#
.SYNOPSIS
    Checks each catalog app's entry in last-run.json after the first run: an app that applies is
    Installed or Skipped as already there; one that does not apply is Skipped with its
    not-applicable reason; a per-user app is Deferred with its reason.
.DESCRIPTION
    The expectations come from Get-SystemPassAppExpectation (e2e/Invoke-SystemInstallPass.ps1) with
    the applicability decided for this PC BEFORE the run, as the installer decides it: the run's
    Windows Terminal step changes what the Terminal condition reads. This evaluator compares
    last-run.json's entries with them.

    A same-user run accepts any 'already' skip. Under cross-user elevation the installer installs
    machine-wide only, as SYSTEM does, and the stage passes MachineWide expectations
    (ConvertTo-RealPcMachineWideExpectation): an applicable app is then Installed, Skipped with one
    of its AlreadyPresentReasons (an msixName app: provisioned for every user), or Deferred because
    winget has no machine-wide installer for it.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result (Id, Expected, Reason, AlreadyPresentReasons), or
    ConvertTo-RealPcMachineWideExpectation's.
.PARAMETER AppExpectationProblem
    Why there are no expectations (the catalog query failed), for the failed row.
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
        [object[]]$AppExpectation,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AppExpectationProblem
    )

    if ($null -eq $RunRecord -or $null -eq $RunRecord.apps) {
        return @(New-TestPlanRow -Check 'Catalog apps recorded' -Result 'FAIL' -Detail 'no apps list in last-run.json')
    }
    if ($null -eq $AppExpectation -or @($AppExpectation).Count -eq 0) {
        $detail = 'no catalog expectations to check against'
        if ($AppExpectationProblem) {
            $detail += ": $AppExpectationProblem"
        }
        return @(New-TestPlanRow -Check 'Catalog apps recorded' -Result 'FAIL' -Detail $detail)
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
        elseif (Test-RealPcMachineWideExpectation -Expectation $expectation) {
            # A machine-wide-only run: SYSTEM's skip reasons, or deferred for want of a
            # machine-scope installer.
            $present = ($status -eq 'Skipped' -and @($expectation.AlreadyPresentReasons) -contains $reason)
            $deferred = ($status -eq 'Deferred' -and @($expectation.DeferReasons) -contains $reason)
            $passed = ($status -eq 'Installed') -or $present -or $deferred
            $rows += New-TestPlanBoolRow -Check "App installed, present or deferred (machine-wide only): $id" -Passed $passed -Detail $detail
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
    Auto-updates Configured (or Already present); Winget-AutoUpdate task present, enabled and with a
    trigger and no at-logon trigger (from WauTaskHealth the caller read on Windows); the Windows App
    Runtime present now (from the caller; a status that could not be read fails); and TightVNC's
    post-install Configured (when a TightVNC password was supplied).
.PARAMETER Transcript
    The run's transcript (Name, Parsed).
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER WauTaskHealth
    Get-WauTaskHealth-shaped object the caller read (Exists, Healthy, Triggers, Problem), or $null
    off Windows / when not read.
.PARAMETER WindowsAppRuntimePresent
    Whether the framework is present now (Get-WindowsAppRuntimeStatus.Present), $null when unknown.
.PARAMETER WindowsAppRuntimeProblem
    Why it is unknown, for the failed row.
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
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WindowsAppRuntimeProblem,

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
    else {
        $detail = 'the runtime status could not be read'
        if ($WindowsAppRuntimeProblem) {
            $detail += ": $WindowsAppRuntimeProblem"
        }
        $rows += New-TestPlanRow -Check 'Windows App Runtime present' -Result 'FAIL' -Detail $detail
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
    The re-run's exit code, or $null when it was not read.
.PARAMETER Transcript
    The re-run's transcript (Name, Parsed).
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER RunRecordProblem
    Why there is no record, for the failed row.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result, with -AlreadyPresent, after Set-RealPcFirstRunExpectation:
    an app the first run left installed must now be Skipped as already there ('AlreadyPresent');
    one it did not may be installed now or found ('Installed'). Under cross-user elevation they
    are MachineWide (ConvertTo-RealPcMachineWideExpectation): the skip must be one of the
    AlreadyPresentReasons, and an app the first run did not leave installed may be Deferred again
    because winget has no machine-wide installer for it.
.PARAMETER AppExpectationProblem
    Why there are no expectations, for the failed row.
.RETURNS
    Assertion rows (New-TestPlanRow): one per expectation, never none.
#>
function Get-RealPcReRunResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunRecordProblem,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AppExpectationProblem
    )

    $rows = @()
    if ($null -eq $ExitCode) {
        $rows += New-TestPlanRow -Check 'Re-run exit code 0 or 3010' -Result 'FAIL' -Detail (Get-RealPcNoExitCodeDetail)
    }
    else {
        $rows += New-TestPlanBoolRow -Check 'Re-run exit code 0 or 3010' -Passed (@(0, 3010) -contains [int]$ExitCode) -Detail "exit $ExitCode"
    }

    if ($null -eq $RunRecord -or $null -eq $RunRecord.apps) {
        $detail = 'no apps list in last-run.json for this run'
        if ($RunRecordProblem) {
            $detail = $RunRecordProblem
        }
        $rows += New-TestPlanRow -Check 'Re-run apps recorded' -Result 'FAIL' -Detail $detail
    }
    elseif ($null -eq $AppExpectation -or @($AppExpectation).Count -eq 0) {
        $detail = 'no catalog expectations to check against'
        if ($AppExpectationProblem) {
            $detail += ": $AppExpectationProblem"
        }
        $rows += New-TestPlanRow -Check 'Re-run apps recorded' -Result 'FAIL' -Detail $detail
    }
    else {
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
            if (-not $matching) {
                $rows += New-TestPlanRow -Check "Re-run recorded: $id" -Result 'FAIL' -Detail 'no entry in last-run.json'
            }
            elseif ($expectation.Expected -eq 'AlreadyPresent') {
                $passed = ($status -eq 'Skipped' -and [string]$reason -match '(?i)already')
                if (Test-RealPcMachineWideExpectation -Expectation $expectation) {
                    $passed = ($status -eq 'Skipped' -and @($expectation.AlreadyPresentReasons) -contains $reason)
                }
                $rows += New-TestPlanBoolRow -Check "Re-run skipped as present: $id" -Passed $passed -Detail $detail
            }
            elseif ($expectation.Expected -eq 'NotApplicable') {
                $passed = ($status -eq 'Skipped' -and $reason -eq $expectation.Reason)
                $rows += New-TestPlanBoolRow -Check "Re-run not applicable: $id" -Passed $passed -Detail $detail
            }
            elseif ($expectation.Expected -eq 'Deferred') {
                $passed = ($status -eq 'Deferred' -and $reason -eq $expectation.Reason)
                $rows += New-TestPlanBoolRow -Check "Re-run deferred: $id" -Passed $passed -Detail $detail
            }
            elseif ($expectation.Expected -eq 'Installed' -and (Test-RealPcMachineWideExpectation -Expectation $expectation)) {
                # Machine-wide only: an app the first run deferred for want of a machine-scope
                # installer is deferred again.
                $present = ($status -eq 'Skipped' -and @($expectation.AlreadyPresentReasons) -contains $reason)
                $deferred = ($status -eq 'Deferred' -and @($expectation.DeferReasons) -contains $reason)
                $passed = ($status -eq 'Installed') -or $present -or $deferred
                $rows += New-TestPlanBoolRow -Check "Re-run installed, found or deferred (machine-wide only): $id" -Passed $passed -Detail $detail
            }
            elseif ($expectation.Expected -eq 'Installed') {
                # The first run did not leave it installed: installed now, or found already there.
                $passed = ($status -eq 'Installed') -or ($status -eq 'Skipped' -and [string]$reason -match '(?i)already')
                $rows += New-TestPlanBoolRow -Check "Re-run installed or found: $id" -Passed $passed -Detail $detail
            }
            else {
                $rows += New-TestPlanRow -Check "Re-run recorded: $id" -Result 'FAIL' -Detail ("no check for the expectation '{0}'; {1}" -f $expectation.Expected, $detail)
            }
        }
    }

    if ($Transcript) {
        $rows += New-TestPlanBoolRow -Check 'Re-run did not install the Windows App Runtime again' -Passed (-not $Transcript.Parsed.WindowsAppRuntimeInstalled) -Detail $(if ($Transcript.Parsed.WindowsAppRuntimeInstalled) { "Windows App Runtime: $($Transcript.Parsed.WindowsAppRuntimeLine)" } else { 'no install line' })
        $auLine = $Transcript.Parsed.AutoUpdatesLine
        $rows += New-TestPlanBoolRow -Check 'Re-run WAU already present' -Passed ($Transcript.Parsed.AutoUpdatesStatus -eq 'Already present') -Detail "Auto-updates: $auLine"
    }
    else {
        $rows += New-TestPlanRow -Check 'Re-run transcript' -Result 'FAIL' -Detail 'no transcript of the re-run was found'
    }
    return $rows
}

<#
.SYNOPSIS
    Bases a later run's 'already present' expectations on what the first run left installed.
.DESCRIPTION
    An app the first run recorded Installed, or Skipped as already there, must be found already
    there (AlreadyPresent stays). Any other app (Failed, NotAttempted, no entry, or no record at
    all) may be installed by the later run or found: its expectation becomes Installed with
    MustInstall off, which accepts both. NotApplicable and Deferred expectations are kept, and so
    are MachineWide and DeferReasons (ConvertTo-RealPcMachineWideExpectation).
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result with -AlreadyPresent (Id, Expected, Reason,
    AlreadyPresentReasons, MustInstall), or ConvertTo-RealPcMachineWideExpectation's.
.PARAMETER FirstRunRecord
    The first run's last-run.json, parsed, or $null when it left none.
.RETURNS
    [pscustomobject] with Value (copies of the expectations, changed as above) and Changed (one
    '<id> (<what the first run recorded>)' per changed app).
#>
function Set-RealPcFirstRunExpectation {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $FirstRunRecord
    )

    $entries = @()
    if ($null -ne $FirstRunRecord -and $null -ne $FirstRunRecord.apps) {
        $entries = @($FirstRunRecord.apps | Where-Object { $null -ne $_ })
    }
    $changed = @()
    $values = @(foreach ($expectation in @($AppExpectation | Where-Object { $null -ne $_ })) {
            $copy = [pscustomobject]@{
                Id                    = [string]$expectation.Id
                Expected              = [string]$expectation.Expected
                Reason                = $expectation.Reason
                AlreadyPresentReasons = [string[]]@(@($expectation.AlreadyPresentReasons) | Where-Object { $null -ne $_ })
                MustInstall           = [bool]$expectation.MustInstall
            }
            if (Test-RealPcMachineWideExpectation -Expectation $expectation) {
                $copy | Add-Member -NotePropertyName 'MachineWide' -NotePropertyValue $true
                $copy | Add-Member -NotePropertyName 'DeferReasons' -NotePropertyValue ([string[]]@(@($expectation.DeferReasons) | Where-Object { $null -ne $_ }))
            }
            if ($copy.Expected -eq 'AlreadyPresent') {
                $entry = @($entries | Where-Object { [string]$_.id -eq $copy.Id }) | Select-Object -First 1
                $recorded = 'no entry in its last-run.json'
                if ($null -eq $FirstRunRecord) {
                    $recorded = 'the first run left no last-run.json'
                }
                $leftInstalled = $false
                if ($entry) {
                    $recorded = Format-SystemPassAppEntry -Entry $entry
                    $leftInstalled = ([string]$entry.status -eq 'Installed') -or ([string]$entry.status -eq 'Skipped' -and [string]$entry.reason -match '(?i)already')
                }
                if (-not $leftInstalled) {
                    $copy.Expected = 'Installed'
                    $copy.MustInstall = $false
                    $changed += ('{0} ({1})' -f $copy.Id, $recorded)
                }
            }
            $copy
        })
    return [pscustomobject]@{ Value = $values; Changed = $changed }
}

<#
.SYNOPSIS
    In the SYSTEM run's rows, also accepts an app deferred again because winget found no
    machine-wide installer for it, when the first run deferred it for that reason.
.DESCRIPTION
    Get-SystemPassAppResult expects every app the first run did not leave installed to be
    installed as SYSTEM. A first run that installed machine-wide only (cross-user elevation)
    deferred such an app for want of a machine-scope installer, and SYSTEM installs machine-wide
    only too: for those apps either outcome passes. Every other row is kept as it is.
.PARAMETER Row
    The SYSTEM stage's rows (New-TestPlanRow).
.PARAMETER RunRecord
    The SYSTEM run's last-run.json, parsed, or $null.
.PARAMETER FirstRunRecord
    The first run's last-run.json, parsed, or $null.
.RETURNS
    [object[]] the rows, a new one in place of each app row this changes.
#>
function Update-RealPcSystemRedeferredRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Row = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $FirstRunRecord
    )

    $rows = @($Row | Where-Object { $null -ne $_ })
    if ($null -eq $FirstRunRecord -or $null -eq $FirstRunRecord.apps) {
        return $rows
    }
    $deferredIds = @($FirstRunRecord.apps | Where-Object { $null -ne $_ -and [string]$_.status -eq 'Deferred' -and [string]$_.reason -eq $script:NoMachineScopeDeferReason } | ForEach-Object { [string]$_.id })
    if ($deferredIds.Count -eq 0) {
        return $rows
    }
    $entries = @()
    if ($null -ne $RunRecord -and $null -ne $RunRecord.apps) {
        $entries = @($RunRecord.apps | Where-Object { $null -ne $_ })
    }
    return @(foreach ($item in $rows) {
            $id = ''
            if ([string]$item.Check -match '^App installed: (?<id>\S+)$') {
                $id = $Matches['id']
            }
            if (-not $id -or $deferredIds -notcontains $id) {
                $item
                continue
            }
            $check = 'App installed, or deferred again as the first run did: ' + $id
            $entry = @($entries | Where-Object { [string]$_.id -eq $id })
            if ($item.Result -ne 'PASS' -and $entry.Count -eq 1 -and [string]$entry[0].status -eq 'Deferred' -and [string]$entry[0].reason -eq $script:NoMachineScopeDeferReason) {
                New-TestPlanRow -Check $check -Result 'PASS' -Detail ('last-run.json: {0}; the first run, machine-wide only, deferred it for the same reason' -f (Format-SystemPassAppEntry -Entry $entry[0]))
            }
            else {
                New-TestPlanRow -Check $check -Result $item.Result -Detail $item.Detail
            }
        })
}

<#
.SYNOPSIS
    The row that names the apps a later run expects installed or found, rather than already there,
    because the first run did not leave them installed (Set-RealPcFirstRunExpectation).
.PARAMETER Changed
    Set-RealPcFirstRunExpectation's Changed.
.PARAMETER Run
    The later run, for the detail, e.g. 'The re-run'.
.RETURNS
    One SKIP row, or none when no expectation changed.
#>
function Get-RealPcFirstRunGapRow {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Changed = @(),

        [Parameter(Mandatory = $false)]
        [string]$Run = 'This run'
    )

    $apps = @($Changed | Where-Object { $_ })
    if ($apps.Count -eq 0) {
        return @()
    }
    $detail = '{0} expects these installed or found, not already there: {1}' -f $Run, ($apps -join '; ')
    return @(New-TestPlanRow -Check 'Apps the first run did not leave installed' -Result 'SKIP' -Detail $detail)
}

# ======================================================================================
# Time budget (item 8), diagnostics (item 6), uninstaller (item 9) (pure)
# ======================================================================================

<#
.SYNOPSIS
    The row that checks an app is gone after 'winget uninstall', from a three-way winget answer.
.DESCRIPTION
    Never passes on 'found nothing': an uninstall that ended with 0x8A150014 (no package found)
    removed nothing, whatever the lookup after it says, and with the source check failed winget
    cannot see this account's apps at all (SKIP).
.PARAMETER AppId
    The package id.
.PARAMETER Present
    Test-RealPcWingetInstalled's answer: $true, $false, or $null when winget could not answer.
.PARAMETER UninstallExitCode
    winget uninstall's exit code, or $null when it did not run to the end.
.PARAMETER UninstallProblem
    Why it did not run, for the detail.
.PARAMETER SourceOpen
    The source check's outcome: $false makes the row SKIP; $null (not checked) changes nothing.
.RETURNS
    One row: PASS only when the uninstall ran, found the package, and winget then answered that
    the app is not installed.
#>
function Get-RealPcUninstallCheckRow {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$Present,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$UninstallExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UninstallProblem = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$SourceOpen
    )

    $check = "Uninstalled $AppId before the budget run"
    $uninstallText = 'winget uninstall ' + (Format-RealPcWingetExitCode -ExitCode $UninstallExitCode)
    if ($UninstallProblem) {
        $uninstallText += " ($UninstallProblem)"
    }
    if ($SourceOpen -eq $false) {
        return (New-TestPlanRow -Check $check -Result 'SKIP' -Detail ('{0}; {1}' -f $uninstallText, (Get-RealPcWingetBlindDetail)))
    }
    if ($null -eq $UninstallExitCode) {
        return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail "${uninstallText}: it did not run to the end, so nothing was removed")
    }
    if ([int]$UninstallExitCode -eq $script:WingetNoPackageFoundExitCode) {
        return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail "${uninstallText}: winget found no package; not removed")
    }
    if ($null -eq $Present) {
        return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail "$uninstallText; winget list could not answer whether it is still installed")
    }
    if ($Present) {
        return (New-TestPlanRow -Check $check -Result 'FAIL' -Detail "$uninstallText; winget still lists it")
    }
    return (New-TestPlanRow -Check $check -Result 'PASS' -Detail "$uninstallText; winget no longer lists it")
}

# The ids an uninstaller run's console says it skipped as not installed ('Skipping: <id> (not
# installed)', WingetAppSetup/Public/Uninstall.ps1).
function Get-RealPcNotInstalledSkip {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $ids = @()
    foreach ($line in @([string]$Text -split '\r?\n')) {
        if ($line -match 'Skipping: ([\w][\w.\-]+\.[\w][\w.\-]+) \(not installed\)') {
            $ids += $Matches[1]
        }
    }
    return @($ids | Sort-Object -Unique)
}

# The ids an uninstaller run's console says it kept on purpose: 'Skipping: <id> (' followed by one
# of $script:UninstallerKeptReasons (WingetAppSetup/Private/AppUninstall.ps1).
function Get-RealPcKeptSkip {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $ids = @()
    foreach ($line in @([string]$Text -split '\r?\n')) {
        $match = [regex]::Match($line, 'Skipping: (?<id>[\w][\w.\-]+\.[\w][\w.\-]+) \((?<reason>.*)$')
        if (-not $match.Success) {
            continue
        }
        foreach ($reason in $script:UninstallerKeptReasons) {
            if ($match.Groups['reason'].Value.StartsWith($reason, [System.StringComparison]::Ordinal)) {
                $ids += $match.Groups['id'].Value
                break
            }
        }
    }
    return @($ids | Sort-Object -Unique)
}

<#
.SYNOPSIS
    The installer's 'RESULT: ...' line from its console output or a transcript, or empty.
.PARAMETER Text
    The text to search (the last RESULT line wins).
#>
function Get-RealPcResultLineFromText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $lines = @($Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^RESULT: ' })
    if ($lines.Count -eq 0) {
        return ''
    }
    return [string]$lines[-1]
}

<#
.SYNOPSIS
    Checks the spent-budget half of item 8: exit 9, the named app NotAttempted in last-run.json, and
    notattempted at least 1 in the RESULT line.
.PARAMETER ExitCode
    The budgeted run's exit code, or $null when it was not read.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER RunRecordProblem
    Why there is no record, for the detail.
.PARAMETER ResultLine
    The RESULT line text (the installer's 'RESULT: ...'), or empty.
.PARAMETER AppId
    The app uninstalled first and expected NotAttempted. Default 7zip.7zip.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcTimeBudgetSpentResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunRecordProblem,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ResultLine,

        [Parameter(Mandatory = $false)]
        [string]$AppId = '7zip.7zip'
    )

    $rows = @()
    if ($null -eq $ExitCode) {
        $rows += New-TestPlanRow -Check 'Spent-budget run exits 9' -Result 'FAIL' -Detail (Get-RealPcNoExitCodeDetail)
    }
    else {
        $rows += New-TestPlanBoolRow -Check 'Spent-budget run exits 9' -Passed ([int]$ExitCode -eq 9) -Detail "exit $ExitCode"
    }

    $status = ''
    $statusDetail = ''
    if ($null -ne $RunRecord) {
        $entry = @($RunRecord.apps | Where-Object { [string]$_.id -eq $AppId }) | Select-Object -First 1
        if ($entry) {
            $status = [string]$entry.status
        }
        $statusDetail = "status: $status"
    }
    else {
        $statusDetail = 'no last-run.json for this run'
        if ($RunRecordProblem) {
            $statusDetail = $RunRecordProblem
        }
    }
    $rows += New-TestPlanBoolRow -Check "$AppId not attempted" -Passed ($status -eq 'NotAttempted') -Detail $statusDetail

    $notAttempted = $null
    if ($ResultLine -match 'notattempted=(\d+)') {
        $notAttempted = [int]$Matches[1]
    }
    $rows += New-TestPlanBoolRow -Check 'RESULT line notattempted >= 1' -Passed ($null -ne $notAttempted -and $notAttempted -ge 1) -Detail "notattempted=$notAttempted"
    return $rows
}

<#
.SYNOPSIS
    Checks the finish half of item 8: the next run (no spent budget) installs the app and exits 0 or
    3010.
.PARAMETER ExitCode
    The finishing run's exit code, or $null when it was not read.
.PARAMETER RunRecord
    last-run.json parsed, or $null.
.PARAMETER RunRecordProblem
    Why there is no record, for the detail.
.PARAMETER AppId
    The app that must now be Installed. Default 7zip.7zip.
.RETURNS
    Assertion rows (New-TestPlanRow).
#>
function Get-RealPcTimeBudgetFinishResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunRecordProblem,

        [Parameter(Mandatory = $false)]
        [string]$AppId = '7zip.7zip'
    )

    $rows = @()
    if ($null -eq $ExitCode) {
        $rows += New-TestPlanRow -Check 'Finish run exits 0 or 3010' -Result 'FAIL' -Detail (Get-RealPcNoExitCodeDetail)
    }
    else {
        $rows += New-TestPlanBoolRow -Check 'Finish run exits 0 or 3010' -Passed (@(0, 3010) -contains [int]$ExitCode) -Detail "exit $ExitCode"
    }
    $status = ''
    $statusDetail = ''
    if ($null -ne $RunRecord) {
        $entry = @($RunRecord.apps | Where-Object { [string]$_.id -eq $AppId }) | Select-Object -First 1
        if ($entry) {
            $status = [string]$entry.status
        }
        $statusDetail = "status: $status"
    }
    else {
        $statusDetail = 'no last-run.json for this run'
        if ($RunRecordProblem) {
            $statusDetail = $RunRecordProblem
        }
    }
    $rows += New-TestPlanBoolRow -Check "$AppId installed on the finish run" -Passed ($status -eq 'Installed') -Detail $statusDetail
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
    The secrets a scan looks for, by label: what is never to leave this machine.
.PARAMETER TightVncPassword
    The throwaway TightVNC test password.
.PARAMETER TempUserName
    The temporary user's name, or empty (left out).
.RETURNS
    [System.Collections.Specialized.OrderedDictionary] label -> value.
#>
function Get-RealPcSecretSet {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$TightVncPassword = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$TempUserName = ''
    )

    $secrets = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($TightVncPassword)) {
        $secrets['the TightVNC test password'] = $TightVncPassword
        # TightVNC uses only the first 8 characters: that is the password that works.
        if ($TightVncPassword.Length -gt 8) {
            $secrets['the first 8 characters of the TightVNC test password'] = $TightVncPassword.Substring(0, 8)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($TempUserName)) {
        $secrets['the temporary user''s name'] = $TempUserName
    }
    return $secrets
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
    Label -> value of the strings that must not appear (Get-RealPcSecretSet).
.RETURNS
    Assertion rows (New-TestPlanRow). No row ever holds a secret's value.
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
        [System.Collections.IDictionary]$Secret = @{}
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

    $leak = @(Get-RealPcSecretLeak -Entry $EntryText -Secret $Secret)
    $leakDetail = 'no secret found in any bundle file'
    if ($leak.Count -gt 0) {
        $leakDetail = 'LEAK: ' + (@($leak | ForEach-Object { '{0} holds {1}' -f $_.Name, $_.Label }) -join '; ')
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
    Label -> value (Get-RealPcSecretSet); empty and whitespace-only values are ignored.
.RETURNS
    [pscustomobject[]] one per entry and secret found, with Name and Label (never the value);
    empty when none is found.
#>
function Get-RealPcSecretLeak {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$Entry = @{},

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$Secret = @{}
    )

    $leaks = @()
    if ($null -eq $Entry -or $null -eq $Secret) {
        return $leaks
    }
    $labels = @($Secret.Keys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$Secret[$_]) })
    foreach ($name in @($Entry.Keys)) {
        $text = [string]$Entry[$name]
        if ([string]::IsNullOrEmpty($text)) {
            continue
        }
        $lower = $text.ToLowerInvariant()
        foreach ($label in $labels) {
            if ($lower.Contains(([string]$Secret[$label]).ToLowerInvariant())) {
                $leaks += [pscustomobject]@{ Name = [string]$name; Label = [string]$label }
            }
        }
    }
    return $leaks
}

<#
.SYNOPSIS
    Scans every file under a folder, and every entry of each .zip in it, for the given secrets.
.DESCRIPTION
    Reads each file as text (a BOM picks UTF-16 or UTF-8; otherwise UTF-8). A .zip's entries are
    read the same way, so a diagnostics bundle copied into the report is checked too. Plain .NET, so
    it runs on any OS. A file that cannot be read is reported with the label 'unreadable', so it is
    left out of the zip like a leak rather than sent unchecked.
.PARAMETER Path
    The folder.
.PARAMETER Secret
    Label -> value (Get-RealPcSecretSet).
.RETURNS
    [pscustomobject[]] with File (the full path of the file, or of the .zip), Name (its path under
    the folder, with '!<entry>' for a zip entry) and Label.
#>
function Get-RealPcFolderSecretLeak {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$Secret = @{}
    )

    $results = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $results
    }
    $root = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\', '/')
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
        $entries = @{}
        try {
            if ($file.Extension -eq '.zip') {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                try {
                    foreach ($zipEntry in $zip.Entries) {
                        if ($zipEntry.FullName.EndsWith('/')) {
                            continue
                        }
                        $reader = New-Object System.IO.StreamReader($zipEntry.Open(), [System.Text.Encoding]::UTF8, $true)
                        try {
                            $entries[$relative + '!' + $zipEntry.FullName] = $reader.ReadToEnd()
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
            else {
                $entries[$relative] = [System.IO.File]::ReadAllText($file.FullName)
            }
        }
        catch {
            $results += [pscustomobject]@{ File = $file.FullName; Name = $relative; Label = 'unreadable' }
            continue
        }
        foreach ($leak in @(Get-RealPcSecretLeak -Entry $entries -Secret $Secret)) {
            $results += [pscustomobject]@{ File = $file.FullName; Name = $leak.Name; Label = $leak.Label }
        }
    }
    return $results
}

<#
.SYNOPSIS
    Checks the uninstaller (item 9).
.DESCRIPTION
    Two halves: the -WhatIf preview changed nothing (the catalog apps winget lists and the WAU task
    are the same before and after), and a real elevated uninstall exited 0 or 3010, removed the
    catalog apps except the ones its console says it kept on purpose (Get-RealPcKeptSkip:
    PowerShell 7 when it runs in it, Windows Terminal when that hosts the window or is the default
    terminal, a per-user app a SYSTEM or cross-user run cannot remove), and removed
    Winget-AutoUpdate (its task is gone). A catalog app winget could not answer for fails: an
    unanswered lookup is never read as 'removed'. No row passes on 'found nothing': the -WhatIf
    row is SKIP when winget listed no catalog app before or after the preview. When the source
    check failed (winget cannot see this account's apps), the rows that ask winget are SKIP, each
    run's 'Skipping: <id> (not installed)' lines fail ('the uninstaller could not see installed
    apps'), and the real uninstall must refuse as SourceUnusable: exit 2 passes, a success exit
    fails, and Winget-AutoUpdate must be kept (removed fails; SKIP when it was not installed).
    Unless the real uninstall's console says 'The winget source opens for': its own source check
    (and repair, when a fix's success line comes first) opened the source, so it is judged as
    usual, apart from the preview, whose lookups ran before the repair.
.PARAMETER WhatIfInstalledBefore
    The catalog ids winget listed as installed before the -WhatIf preview.
.PARAMETER WhatIfInstalledAfter
    The catalog ids winget listed as installed after the -WhatIf preview (must equal the before set).
.PARAMETER WhatIfWauBefore
    Whether the WAU task existed before the preview.
.PARAMETER WhatIfWauAfter
    Whether the WAU task existed after the preview (must equal the before value).
.PARAMETER ExitCode
    The real uninstall's exit code, or $null when it was not read.
.PARAMETER InstalledAfter
    The catalog ids still installed after the real uninstall.
.PARAMETER UnknownIds
    The catalog ids winget could not answer for in any of the three lookups.
.PARAMETER UnknownAfterIds
    The catalog ids winget could not answer for after the real uninstall. Used instead of
    UnknownIds when the uninstaller repaired the source: the lookups before it were blind. Default:
    UnknownIds.
.PARAMETER KeptIds
    The catalog ids the uninstaller kept on purpose. Default: the ones the real uninstall's console
    names (Get-RealPcKeptSkip); with no console text, PowerShell 7 and Windows Terminal, the apps
    it may keep.
.PARAMETER WauPresentAfter
    Whether the WAU task still exists after the real uninstall (must be false, or true while the
    source is closed).
.PARAMETER SourceOpen
    The source check's outcome just before the uninstaller ran: $false when winget could not open
    its source in this account; $null (not checked) changes nothing.
.PARAMETER WhatIfConsoleText
    The -WhatIf preview's console output.
.PARAMETER UninstallConsoleText
    The real uninstall's console output.
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

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$InstalledAfter = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$UnknownIds = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$UnknownAfterIds,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$KeptIds,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WauPresentAfter,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$SourceOpen,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WhatIfConsoleText = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UninstallConsoleText = ''
    )

    $rows = @()
    # The uninstaller runs the installer's source check and repair: once it says the source opens,
    # its own winget calls, and the lookups after it, are no longer blind.
    $repairLine = [regex]::Match([string]$UninstallConsoleText, 'The winget source opens for[^\r\n]*')
    $repaired = ($SourceOpen -eq $false) -and $repairLine.Success
    $blind = ($SourceOpen -eq $false) -and -not $repaired
    if ($repaired) {
        # 'Repaired' only when a fix's success line comes before it; else its first check opened.
        $fixLines = @([regex]::Matches([string]$UninstallConsoleText, '(The winget source package is registered for this account|App Installer registered for this account|Source reset completed)[^\r\n]*') | Where-Object { $_.Index -lt $repairLine.Index })
        if ($fixLines.Count -gt 0) {
            $rows += New-TestPlanRow -Check 'The uninstaller repaired winget''s source for this account' -Result 'PASS' -Detail ('the harness''s check before it could not open it; the uninstaller printed: {0} Then: {1}' -f $fixLines[-1].Value.Trim(), $repairLine.Value.Trim())
        }
        else {
            $rows += New-TestPlanRow -Check 'The uninstaller found winget''s source open' -Result 'PASS' -Detail ('the harness''s check before it could not open it, the uninstaller''s own check did, with no repair; it printed: {0}' -f $repairLine.Value.Trim())
        }
    }
    $unknownSource = $UnknownIds
    if ($repaired -and $PSBoundParameters.ContainsKey('UnknownAfterIds')) {
        $unknownSource = $UnknownAfterIds
    }
    $unknown = @($unknownSource | Where-Object { $_ } | Sort-Object -Unique)
    if ($blind) {
        $rows += New-TestPlanRow -Check 'winget answered for every catalog app' -Result 'SKIP' -Detail (Get-RealPcWingetBlindDetail)
    }
    elseif ($unknown.Count -gt 0) {
        $rows += New-TestPlanRow -Check 'winget answered for every catalog app' -Result 'FAIL' -Detail ('winget list could not answer for: {0}, so their removal is unchecked' -f ($unknown -join ', '))
    }

    $before = @($WhatIfInstalledBefore | Where-Object { $_ } | Sort-Object -Unique)
    $after = @($WhatIfInstalledAfter | Where-Object { $_ } | Sort-Object -Unique)
    $sameApps = (@($before | Where-Object { $after -notcontains $_ }).Count -eq 0) -and (@($after | Where-Object { $before -notcontains $_ }).Count -eq 0)
    $sameWau = ($WhatIfWauBefore -eq $WhatIfWauAfter)
    $whatIfCheck = 'Uninstaller -WhatIf changed nothing'
    $wauText = 'WAU before {0}, after {1}' -f $WhatIfWauBefore, $WhatIfWauAfter
    if (-not $sameWau) {
        $rows += New-TestPlanRow -Check $whatIfCheck -Result 'FAIL' -Detail ('the preview changed Winget-AutoUpdate: {0}' -f $wauText)
    }
    elseif ($blind -or $repaired) {
        # The preview's lookups ran before the uninstaller's repair, so they were blind either way.
        $rows += New-TestPlanRow -Check $whatIfCheck -Result 'SKIP' -Detail ('{0}; only Winget-AutoUpdate could be compared: {1}' -f (Get-RealPcWingetBlindDetail), $wauText)
    }
    elseif ($before.Count -eq 0 -and $after.Count -eq 0) {
        $rows += New-TestPlanRow -Check $whatIfCheck -Result 'SKIP' -Detail ('winget listed no catalog app before or after the preview, so it shows nothing about the apps; {0}' -f $wauText)
    }
    else {
        $rows += New-TestPlanBoolRow -Check $whatIfCheck -Passed $sameApps -Detail ("installed before: {0}; after: {1}; {2}" -f ($before -join ', '), ($after -join ', '), $wauText)
    }

    # With the source closed, the uninstaller must refuse (SourceUnusable: exit 2, nothing removed).
    if ($blind) {
        $exitCheck = 'Real uninstall stops with exit 2 while winget cannot open its source'
        if ($null -eq $ExitCode) {
            $rows += New-TestPlanRow -Check $exitCheck -Result 'FAIL' -Detail (Get-RealPcNoExitCodeDetail)
        }
        elseif ([int]$ExitCode -eq 2) {
            $rows += New-TestPlanRow -Check $exitCheck -Result 'PASS' -Detail 'exit 2: refused, as winget could not open its source in this account'
        }
        elseif (@(0, 3010) -contains [int]$ExitCode) {
            $rows += New-TestPlanRow -Check $exitCheck -Result 'FAIL' -Detail ("exit {0}: reported success although winget could not see this account's apps" -f $ExitCode)
        }
        else {
            $rows += New-TestPlanRow -Check $exitCheck -Result 'FAIL' -Detail ("exit {0}, not 2 (winget could not open its source in this account)" -f $ExitCode)
        }
    }
    elseif ($null -eq $ExitCode) {
        $rows += New-TestPlanRow -Check 'Real uninstall exits 0 or 3010' -Result 'FAIL' -Detail (Get-RealPcNoExitCodeDetail)
    }
    else {
        $rows += New-TestPlanBoolRow -Check 'Real uninstall exits 0 or 3010' -Passed (@(0, 3010) -contains [int]$ExitCode) -Detail "exit $ExitCode"
    }

    $removedCheck = 'Catalog apps removed (except what the uninstaller keeps on purpose)'
    if ($blind) {
        $rows += New-TestPlanRow -Check $removedCheck -Result 'SKIP' -Detail (Get-RealPcWingetBlindDetail)
    }
    else {
        # Kept only when the uninstaller said so: a PowerShell 7 left behind by a Windows PowerShell
        # run, which removes it, is a failure.
        if ($PSBoundParameters.ContainsKey('KeptIds')) {
            $kept = @($KeptIds | Where-Object { $_ })
        }
        elseif (-not [string]::IsNullOrWhiteSpace($UninstallConsoleText)) {
            $kept = @(Get-RealPcKeptSkip -Text $UninstallConsoleText)
        }
        else {
            $kept = @('Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
        }
        $stillThere = @($InstalledAfter | Where-Object { $_ -and $kept -notcontains $_ } | Sort-Object -Unique)
        $removedDetail = 'every removable catalog app is gone'
        if ($stillThere.Count -gt 0) {
            $removedDetail = "still installed: $($stillThere -join ', ')"
        }
        $keptNow = @($InstalledAfter | Where-Object { $kept -contains $_ } | Sort-Object -Unique)
        if ($keptNow.Count -gt 0) {
            $removedDetail += "; kept on purpose: $($keptNow -join ', ')"
        }
        $rows += New-TestPlanBoolRow -Check $removedCheck -Passed ($stillThere.Count -eq 0) -Detail $removedDetail
    }

    # The uninstaller asks the same winget: with the source closed, each 'not installed' it printed
    # is an app it could not see.
    if ($blind) {
        foreach ($run in @(@{ Name = 'preview'; Text = $WhatIfConsoleText }, @{ Name = 'real uninstall'; Text = $UninstallConsoleText })) {
            $seenCheck = "Uninstaller ($($run.Name)) called no app it could not see 'not installed'"
            if ([string]::IsNullOrWhiteSpace([string]$run.Text)) {
                $rows += New-TestPlanRow -Check $seenCheck -Result 'SKIP' -Detail 'no console output to read'
                continue
            }
            $notSeen = @(Get-RealPcNotInstalledSkip -Text ([string]$run.Text))
            if ($notSeen.Count -gt 0) {
                $rows += New-TestPlanRow -Check $seenCheck -Result 'FAIL' -Detail ("uninstaller could not see installed apps: it skipped {0} as 'not installed' while winget could not open its source in this account" -f ($notSeen -join ', '))
            }
            else {
                $rows += New-TestPlanRow -Check $seenCheck -Result 'PASS' -Detail "no 'Skipping: <id> (not installed)' line"
            }
        }
    }

    if ($blind) {
        # Kept is right: the apps winget could not see are still on this PC and keep their updates.
        $wauCheck = 'Winget-AutoUpdate kept while winget cannot open its source'
        $wauBeforeReal = $WhatIfWauAfter
        if ($null -eq $wauBeforeReal) {
            $wauBeforeReal = $WhatIfWauBefore
        }
        if ($wauBeforeReal -eq $false) {
            $rows += New-TestPlanRow -Check $wauCheck -Result 'SKIP' -Detail 'Winget-AutoUpdate was not installed before the real uninstall, so there was nothing to keep'
        }
        elseif ($WauPresentAfter -eq $true) {
            $rows += New-TestPlanRow -Check $wauCheck -Result 'PASS' -Detail 'WAU task present: kept, so the apps still on this PC keep getting updates'
        }
        elseif ($WauPresentAfter -eq $false) {
            $rows += New-TestPlanRow -Check $wauCheck -Result 'FAIL' -Detail "removed although winget could not see this account's apps: catalog apps still on this PC no longer get updates"
        }
        else {
            $rows += New-TestPlanRow -Check $wauCheck -Result 'SKIP' -Detail 'the Winget-AutoUpdate task could not be read'
        }
    }
    elseif ($null -ne $WauPresentAfter) {
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
    Decides who planted the junction: the temporary standard user's task, or the admin fallback,
    and why the fallback was needed.
.PARAMETER UserCreated
    The temporary user was created.
.PARAMETER UserProblem
    Why it could not be created.
.PARAMETER TaskStep
    The step of the planting task that failed: 'Register', 'Start' or 'Wait' (empty when none did).
.PARAMETER TaskProblem
    Why that step failed (ConvertTo-RealPcTaskProblem), e.g. 'Access is denied. (0x80070005)'.
.PARAMETER TaskResult
    The task's LastTaskResult, or $null when it did not finish in time.
.PARAMETER JunctionAfterTask
    A junction was at the folder once the task had ended.
.RETURNS
    [pscustomobject] with PlantedBy ('StandardUser' or 'Admin') and Note (what happened, on one line,
    for the report).
#>
function Get-RealPcJunctionPlantResult {
    param (
        [Parameter(Mandatory = $false)]
        [bool]$UserCreated = $false,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserProblem,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TaskStep,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TaskProblem,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[long]]$TaskResult,

        [Parameter(Mandatory = $false)]
        [bool]$JunctionAfterTask = $false
    )

    # An error's text can end in CR/LF (a CimException's does), which would break the report's line.
    $UserProblem = ([string]$UserProblem -replace '\s*[\r\n]+\s*', ' ').Trim()
    $TaskProblem = ([string]$TaskProblem -replace '\s*[\r\n]+\s*', ' ').Trim()
    if (-not $UserCreated) {
        return [pscustomobject]@{ PlantedBy = 'Admin'; Note = "the temporary standard user could not be created ($UserProblem), so the admin planted the junction" }
    }
    if ($TaskProblem) {
        $stepText = 'registering or starting the S4U task'
        switch ($TaskStep) {
            'Register' { $stepText = 'registering the S4U task' }
            'Start' { $stepText = 'starting the S4U task' }
            'Wait' { $stepText = 'waiting for the S4U task' }
        }
        # 0x80070569 can come from any step (in practice the start). At registration a missing right
        # is only a success code (SCHED_S_BATCH_LOGON_PROBLEM), which a COM call from PowerShell drops.
        $hint = ''
        if ($TaskProblem -match '0x80070569') {
            $hint = '; the temporary user lacks Log on as a batch job (SeBatchLogonRight; the machine facts list who holds it)'
        }
        return [pscustomobject]@{ PlantedBy = 'Admin'; Note = ("the standard user's planting task failed ({0}: {1}){2}, so the admin planted the junction" -f $stepText, $TaskProblem, $hint) }
    }
    if ($null -eq $TaskResult) {
        return [pscustomobject]@{ PlantedBy = 'Admin'; Note = "the standard user's planting task did not finish in time, so the admin planted the junction" }
    }
    if ($TaskResult -ne 0) {
        $code = [long]$TaskResult -band 0xFFFFFFFFL
        # ERROR_LOGON_TYPE_NOT_GRANTED: an S4U task launches only for an account with the batch-logon right.
        if ($code -eq 0x80070569L) {
            return [pscustomobject]@{ PlantedBy = 'Admin'; Note = ("the standard user's planting task ended with 0x{0:X8}: the temporary user lacks Log on as a batch job (SeBatchLogonRight; the machine facts list who holds it), so the admin planted the junction" -f $code) }
        }
        return [pscustomobject]@{ PlantedBy = 'Admin'; Note = ("the standard user's planting task ended with 0x{0:X8}, so the admin planted the junction" -f $code) }
    }
    if (-not $JunctionAfterTask) {
        return [pscustomobject]@{ PlantedBy = 'Admin'; Note = "the standard user's planting task ended with 0 but no junction appeared, so the admin planted the junction" }
    }
    return [pscustomobject]@{ PlantedBy = 'StandardUser'; Note = 'planted by the temporary standard user (a scheduled task with an S4U logon, exit 0)' }
}

<#
.SYNOPSIS
    Why a step of the planting task failed, on one line: the error's own text, then its HRESULT,
    e.g. 'Access is denied. (0x80070005)'.
.DESCRIPTION
    A failed COM call (the Task Scheduler COM API's) reaches PowerShell as a
    MethodInvocationException around a TargetInvocationException around the exception .NET maps
    the HRESULT to: an UnauthorizedAccessException for 0x80070005, an ArgumentException for
    0x80070057, a COMException only for a code .NET has no type for. The HRESULT comes from the
    error id the ScheduledTasks cmdlets give ('HRESULT 0x80070005,...'), else from a
    '(0x80070005 ...)' or '(Exception from HRESULT: 0x80070005 ...)' suffix in the text, else from
    a COMException's code, else, for a COM call, from the innermost exception's HResult. The text
    is the COM error's own description where PowerShell 7 puts it (on the
    TargetInvocationException), else the innermost exception's, without its CR/LF and that suffix.
.PARAMETER ErrorRecord
    The error the step threw.
.RETURNS
    [string]
#>
function ConvertTo-RealPcTaskProblem {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $chain = @()
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $chain += $exception
        $exception = $exception.InnerException
    }
    $innermost = $chain[$chain.Count - 1]
    $invocation = $null
    foreach ($item in $chain) {
        if ($item -is [System.Reflection.TargetInvocationException]) {
            $invocation = $item
            break
        }
    }
    $text = [string]$innermost.Message
    # Windows PowerShell leaves .NET's generic (localized) text on the TargetInvocationException.
    $genericText = ([System.Reflection.TargetInvocationException]::new([System.Exception]$null)).Message
    if ($null -ne $invocation -and [string]$invocation.Message -and [string]$invocation.Message -ne $genericText) {
        $text = [string]$invocation.Message
    }
    # Windows PowerShell's COM text ends in '(Exception from HRESULT: 0x80070005 (E_ACCESSDENIED))'
    # (its prefix localized), PowerShell 7's in '(0x80070005 (E_ACCESSDENIED))'; the code is added
    # back once, below.
    $suffix = '\s*\((?:[^():\r\n]+: )?0x([0-9A-Fa-f]{8})(?: \([A-Za-z0-9_]+\))?\)'
    $hresult = $null
    if ("$($ErrorRecord.FullyQualifiedErrorId)" -match 'HRESULT 0x([0-9A-Fa-f]{8})') {
        $hresult = [Convert]::ToInt64($Matches[1], 16)
    }
    if ($null -eq $hresult) {
        $texts = @($text) + @(for ($index = $chain.Count - 1; $index -ge 0; $index--) { [string]$chain[$index].Message })
        foreach ($candidate in $texts) {
            $match = [regex]::Match($candidate, $suffix)
            if ($match.Success) {
                $hresult = [Convert]::ToInt64($match.Groups[1].Value, 16)
                break
            }
        }
    }
    if ($null -eq $hresult -and $innermost -is [System.Runtime.InteropServices.ExternalException]) {
        $hresult = [long]$innermost.ErrorCode -band 0xFFFFFFFFL
    }
    if ($null -eq $hresult -and ($null -ne $invocation -or "$($ErrorRecord.FullyQualifiedErrorId)" -like 'ComMethod*')) {
        # A failure code, but not one of the CLR's own (facility 0x13), which no COM server returns.
        $code = [long]$innermost.HResult -band 0xFFFFFFFFL
        if (($code -band 0x80000000L) -ne 0 -and ($code -band 0xFFFF0000L) -ne 0x80130000L) {
            $hresult = $code
        }
    }
    $message = ($text -replace $suffix, '' -replace '\s*[\r\n]+\s*', ' ').Trim()
    if ($null -ne $hresult) {
        return ('{0} (0x{1:X8})' -f $message, $hresult).Trim()
    }
    return $message
}

<#
.SYNOPSIS
    The 'Log on as a batch job' and 'Deny log on as a batch job' lines of a secedit /export of the
    user rights: who may, and who may not, have the logon an S4U task runs with.
.PARAMETER Text
    The exported file's text.
.PARAMETER HideName
    Names and SIDs to show as '[temporary user]' (the temporary user's are never printed).
.RETURNS
    [string[]] 'SeBatchLogonRight = <holders>' and 'SeDenyBatchLogonRight = <holders>', with
    '(not assigned)' for a right nobody holds.
#>
function Get-RealPcBatchLogonRightLine {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$HideName = @()
    )

    $lines = @()
    foreach ($right in @('SeBatchLogonRight', 'SeDenyBatchLogonRight')) {
        $value = '(not assigned)'
        $match = [regex]::Match([string]$Text, '(?im)^[ \t]*' + $right + '[ \t]*=[ \t]*(.*?)\s*$')
        if ($match.Success -and $match.Groups[1].Value) {
            $value = $match.Groups[1].Value
        }
        foreach ($name in @($HideName | Where-Object { $_ })) {
            $value = [regex]::Replace($value, [regex]::Escape($name), '[temporary user]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        $lines += ('{0} = {1}' -f $right, $value)
    }
    return $lines
}

<#
.SYNOPSIS
    Checks the ProgramData link guard (item 11) from what a first run left behind.
.DESCRIPTION
    The base folder is now a real directory (not a reparse point) locked to SYSTEM and Administrators
    (Get-RealPcRestrictedFolderProblem), the logs folder is readable by Users, the run warned that the
    link was removed, and the victim folder and everything in it kept their owner and SDDL
    (Compare-RealPcAclSnapshot). The installer prints that warning before its transcript starts (its
    5.1 bootstrap removes the link while it gets its log folder), so it is looked for in the run's
    console output first and in its transcripts too.
.PARAMETER BaseIsReparsePoint
    Whether %ProgramData%\winget-app-setup is still a reparse point (must be false).
.PARAMETER BaseAcl
    Get-DirectoryAccessSummary of the base folder, or $null.
.PARAMETER LogsAcl
    Get-DirectoryAccessSummary of the logs folder, or $null.
.PARAMETER ConsoleText
    The run's console output (everything it printed).
.PARAMETER TranscriptText
    The run's transcripts' text.
.PARAMETER VictimBefore
    The victim tree's ACL snapshot before the run.
.PARAMETER VictimAfter
    The victim tree's ACL snapshot after the run.
.PARAMETER PlantedBy
    'StandardUser' or 'Admin' (Get-RealPcJunctionPlantResult).
.PARAMETER PlantNote
    Get-RealPcJunctionPlantResult's Note.
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
        [string]$ConsoleText = '',

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
        [string]$PlantedBy = 'StandardUser',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PlantNote = ''
    )

    $rows = @()
    if ($PlantedBy -eq 'StandardUser') {
        $rows += New-TestPlanRow -Check 'Junction planted by a standard user' -Result 'PASS' -Detail $PlantNote
    }
    else {
        $rows += New-TestPlanRow -Check 'Junction planted by a standard user' -Result 'SKIP' -Detail $PlantNote
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

    $warningPattern = '(?m)was a link .* removed'
    $where = @()
    if ($ConsoleText -match $warningPattern) {
        $where += 'the console output'
    }
    if ($TranscriptText -match $warningPattern) {
        $where += 'a transcript'
    }
    $warnDetail = 'no removed-link warning in the console output or the transcripts'
    if ($where.Count -gt 0) {
        $warnDetail = 'found the removed-link warning in ' + ($where -join ' and ')
    }
    $rows += New-TestPlanBoolRow -Check 'The run warned that the link was removed' -Passed ($where.Count -gt 0) -Detail $warnDetail

    $compare = Compare-RealPcAclSnapshot -Before $VictimBefore -After $VictimAfter
    $rows += New-TestPlanBoolRow -Check 'Victim folder and contents kept their owner and SDDL' -Passed $compare.Unchanged -Detail $compare.Detail
    return $rows
}

# ======================================================================================
# Safety gate, change plan, child scripts and report (pure)
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
.PARAMETER ResetProgramData
    -ResetProgramData was given: an existing %ProgramData%\winget-app-setup is renamed aside.
.PARAMETER LocalFolder
    The folder for what is never sent. Default: Get-RealPcLocalFolderPath of ReportFolder.
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
        [string]$PublicVictimFolder = '',

        [Parameter(Mandatory = $false)]
        [switch]$ResetProgramData,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$LocalFolder = ''
    )

    if (-not $LocalFolder -and $ReportFolder) {
        $LocalFolder = Get-RealPcLocalFolderPath -ReportPath $ReportFolder
    }
    $stageNames = @($Stages | ForEach-Object { $_.Name })
    $lines = @('This run will change this machine as follows:')
    if ($stageNames -contains 'FirstRun') {
        $lines += '  - Install the curated catalog apps (7-Zip, TightVNC with a throwaway test password, Adobe Reader, Chrome, Google Drive, Git, Bulk Crap Uninstaller, Dell Command Update where applicable, PowerShell 7, Windows Terminal) and make Windows Terminal the default terminal (not when this window is elevated as another account than the signed-in user: those per-user settings are then left alone).'
        $lines += '  - Set up Winget-AutoUpdate and install the Windows App Runtime 1.8 for all users.'
        $lines += '  - Create and lock %ProgramData%\winget-app-setup (logs and cache).'
    }
    if ($ResetProgramData -and $stageNames -contains 'LinkGuardSetup') {
        $lines += '  - If %ProgramData%\winget-app-setup exists, rename it to winget-app-setup-old-<time> in the same folder (never delete it).'
    }
    if ($stageNames -contains 'LinkGuardSetup') {
        $lines += "  - Create a temporary STANDARD local user (random name and password, never printed or written down; member of Users and Performance Log Users, for the batch logon its one-shot task needs), a victim folder under $PublicVictimFolder, and a junction at %ProgramData%\winget-app-setup planted by that user from a one-shot S4U task (registered with the user's password, which Task Scheduler does not store); the user, its profile, its task and the victim folder are removed afterwards."
        $lines += "  - Read who holds 'Log on as a batch job' (secedit /export, read-only, into a temporary file that is deleted) for the report."
    }
    if ($stageNames -contains 'System' -or $stageNames -contains 'WinGetClient') {
        $lines += '  - Register and run one-shot SYSTEM scheduled tasks (the Endpoint Central machine phase).'
    }
    if ($stageNames -contains 'TimeBudget') {
        $lines += '  - Uninstall and reinstall 7-Zip (the time-budget stage).'
    }
    if ($stageNames -contains 'Uninstaller') {
        $lines += '  - Remove the catalog apps and Winget-AutoUpdate with the uninstaller. PowerShell 7 is removed too (the uninstaller runs in Windows PowerShell), and Windows Terminal unless it hosts this window, is the default terminal, or this window is elevated as another account than the signed-in user (it then keeps it as a per-user app).'
    }
    $lines += '  - Read, without changing them, who is signed in, winget''s version and source state, and the Apps & features entries, for the report.'
    $lines += "  - Write a report and a zip to $ReportFolder (and $ReportFolder.zip), and the manual steps, with the TightVNC test password, to $LocalFolder (never zipped)."
    $lines += 'Run it only on a disposable test machine, never on a work PC.'
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
    Renders arguments as PowerShell source for a script line: a parameter name as it is, any other
    value in single quotes.
.PARAMETER ArgumentList
    The arguments, e.g. '-MaxRuntimeMinutes', '1'.
.RETURNS
    [string]
#>
function ConvertTo-RealPcScriptArgumentText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @()
    )

    $parts = @(foreach ($argument in @($ArgumentList)) {
            if ($argument -match '^-[A-Za-z][A-Za-z0-9]*\z') {
                $argument
            }
            else {
                "'" + ([string]$argument).Replace("'", "''") + "'"
            }
        })
    return ($parts -join ' ')
}

<#
.SYNOPSIS
    The script a one-liner install run executes in a fresh Windows PowerShell (-UseOneLiner).
.DESCRIPTION
    Downloads the branch's installer once with irm, then defines an Invoke-RestMethod function that
    answers the installer's own relaunch download (raw main, or jsDelivr) with that same text: under
    Windows PowerShell an irm | iex run has no file, so its bootstrap downloads the installer again
    for the PowerShell 7 relaunch, from main, and refuses a build other than the one it started
    with. Every other call goes to the real cmdlet. Without arguments the text is piped to iex, as
    the readme's one-liner does; with arguments it runs as a script block with them (the readme's
    form for -CollectDiagnostics), since iex cannot pass any.
.PARAMETER Url
    The raw URL of the branch's winget-app-install.ps1.
.PARAMETER ArgumentList
    Arguments for the installer, or none.
.RETURNS
    [string] the script text.
#>
function Get-RealPcOneLinerScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @()
    )

    $quotedUrl = "'" + $Url.Replace("'", "''") + "'"
    $template = @'
Set-ExecutionPolicy Unrestricted -Scope Process -Force
$env:WINGET_APP_SETUP_NONINTERACTIVE = '1'
$global:WingetAppSetupTestPlanUrl = __URL__
$global:WingetAppSetupTestPlanText = [string](Invoke-RestMethod -Uri $global:WingetAppSetupTestPlanUrl)
function global:Invoke-RestMethod {
    foreach ($argument in $args) {
        if ("$argument" -match '^https://(raw\.githubusercontent\.com/J-MaFf/winget-app-setup/.+|cdn\.jsdelivr\.net/gh/J-MaFf/winget-app-setup@[^/]+)/winget-app-install\.ps1$') {
            Write-Host "[test plan] Serving the installer from $global:WingetAppSetupTestPlanUrl for $argument"
            return $global:WingetAppSetupTestPlanText
        }
    }
    Microsoft.PowerShell.Utility\Invoke-RestMethod @args
}
'@
    $script = $template.Replace('__URL__', $quotedUrl) + "`n"
    $arguments = @($ArgumentList | Where-Object { $null -ne $_ -and "$_" -ne '' })
    if ($arguments.Count -gt 0) {
        $script += '& ([scriptblock]::Create($global:WingetAppSetupTestPlanText)) ' + (ConvertTo-RealPcScriptArgumentText -ArgumentList $arguments)
    }
    else {
        $script += '$global:WingetAppSetupTestPlanText | iex'
    }
    return $script
}

<#
.SYNOPSIS
    The script a child Windows PowerShell runs for a module query: import the checkout's module,
    dot-source the SYSTEM-pass helpers, run the body (which sets $result), and write $result as
    JSON on one line after a sentinel, so nothing else the child prints is taken for the answer.
.PARAMETER Body
    The query; it must assign $result.
.PARAMETER ManifestPath
    WingetAppSetup.psd1.
.PARAMETER SystemPassPath
    e2e\Invoke-SystemInstallPass.ps1.
.RETURNS
    [string]
#>
function Get-RealPcModuleQueryScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$SystemPassPath
    )

    $lines = @(
        '$ErrorActionPreference = ''Stop''',
        '$result = $null',
        ("Import-Module '{0}' -Force -ErrorAction Stop | Out-Null" -f $ManifestPath.Replace("'", "''")),
        (". '{0}'" -f $SystemPassPath.Replace("'", "''")),
        $Body,
        ("'{0}' + (ConvertTo-Json -InputObject `$result -Depth 6 -Compress)" -f $script:ModuleJsonSentinel)
    )
    return ($lines -join "`n")
}

<#
.SYNOPSIS
    Reads a module query's answer from the child's output: the last line that starts with the
    sentinel, parsed as JSON.
.PARAMETER Output
    The child's output lines.
.RETURNS
    [pscustomobject] with Ok ([bool]), Value (the parsed answer) and Problem (why there is none).
#>
function Get-RealPcModuleJsonResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Output = @()
    )

    $answer = @($Output | Where-Object { $null -ne $_ -and ([string]$_).StartsWith($script:ModuleJsonSentinel) }) | Select-Object -Last 1
    if (-not $answer) {
        $tail = @($Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3) -join ' | '
        if (-not $tail) {
            $tail = 'no output'
        }
        return [pscustomobject]@{ Ok = $false; Value = $null; Problem = "the module query gave no answer ($tail)" }
    }
    $json = ([string]$answer).Substring($script:ModuleJsonSentinel.Length)
    try {
        $value = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Problem = "the module query's answer is not JSON: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Ok = $true; Value = $value; Problem = $null }
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
.PARAMETER Banner
    Warning lines the report starts with, right under its title (Get-RealPcReportBanner).
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
        [switch]$Markdown,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Banner = @()
    )

    $bannerLines = @($Banner | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

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
        if ($bannerLines.Count -gt 0) {
            foreach ($bannerLine in $bannerLines) {
                $lines += ('> **{0}**' -f $bannerLine)
                $lines += '>'
            }
            $lines += ''
        }
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
        if ($bannerLines.Count -gt 0) {
            $lines += ''
            foreach ($bannerLine in $bannerLines) {
                $lines += ('!! {0}' -f $bannerLine)
            }
            $lines += ''
        }
        $lines += ('Overall: {0} - {1} passed, {2} failed, {3} skipped.' -f $overall, $pass, $fail, $skip)
        $lines += ''
        $lines += 'Machine:'
        foreach ($name in @($MachineFacts.Keys)) {
            $lines += ('  {0}: {1}' -f $name, $MachineFacts[$name])
        }
    }
    $lines += ''

    foreach ($stage in $StageResult) {
        $rows = @($stage.Rows | Where-Object { $null -ne $_ })
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
.PARAMETER LocalFolder
    The folder that holds manual-steps.txt (Get-RealPcLocalFolderPath), or empty.
.RETURNS
    [string[]]
#>
function Get-RealPcManualLeftover {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LocalFolder = ''
    )

    $where = 'the winget-app-setup-localsecrets-... folder next to the report folder (the run prints its exact path)'
    if ($LocalFolder) {
        $where = $LocalFolder
    }
    return @(
        'Cross-user elevation: run the one-liner from a standard user and approve the UAC prompt as a DIFFERENT admin account; check that apps with no machine-scope installer are Deferred, not put in the admin profile. (When the machine fact ''Cross-user elevation'' is yes, this run already was one, and FirstRun and ReRun checked that.)',
        ('TightVNC: connect a viewer with the throwaway test password in manual-steps.txt (in {0}; it is not in the zip), and confirm the server accepts it. The Uninstaller stage removes TightVNC: to try a viewer, run with -SkipStage Uninstaller, or connect while stages 3 to 7 run.' -f $where),
        'Endpoint Central: after this branch merges and the RMM pins are set (build/Set-RmmInstallerPin.ps1), deploy the machine and user phases from Endpoint Central and watch the Remarks.',
        'ARM64 hardware: on a real Windows 11 ARM64 PC, check the 32-bit Reader installs, the 64-bit Reader and Dell Command Update are skipped, and Google Drive installs and mounts.'
    )
}

<#
.SYNOPSIS
    The text of manual-steps.txt, the one local file that holds the TightVNC test password.
.PARAMETER TightVncPassword
    The throwaway TightVNC test password.
.PARAMETER UninstallerRan
    The Uninstaller stage ran, so TightVNC was removed (the password no longer opens anything).
.RETURNS
    [string[]] the lines.
#>
function Get-RealPcManualStepText {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TightVncPassword,

        [Parameter(Mandatory = $false)]
        [switch]$UninstallerRan
    )

    $lines = @(
        'Manual steps for this test machine. Do not send this file: it is not in the report zip.',
        ('  TightVNC test password (a throwaway for this disposable machine): {0}' -f $TightVncPassword)
    )
    if ($UninstallerRan) {
        $lines += '  The Uninstaller stage ran, which removes TightVNC, so no server should be listening with it now. To try a viewer, run the harness again with -SkipStage Uninstaller.'
    }
    else {
        $lines += '  TightVNC is still installed with this password: connect a viewer to this machine to confirm item 5.'
    }
    $lines += '  Delete this machine (or roll back the checkpoint) when done.'
    return $lines
}

<#
.SYNOPSIS
    An evidence file's text from titled sections of raw output.
.PARAMETER Section
    Title -> lines, in order.
.RETURNS
    [string] each section as '== <title> ==', its lines and a blank line.
#>
function Format-RealPcEvidenceText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$Section = @{}
    )

    $lines = @()
    foreach ($title in @($Section.Keys)) {
        $lines += ('== {0} ==' -f $title)
        $body = @($Section[$title] | ForEach-Object { [string]$_ })
        if ($body.Count -eq 0) {
            $body = @('(nothing)')
        }
        $lines += $body
        $lines += ''
    }
    return ($lines -join [Environment]::NewLine)
}

<#
.SYNOPSIS
    The text of arp.txt: the Apps & features entries at one moment, one per line, sorted by name.
    Evidence only: no check reads it.
.PARAMETER Entry
    Get-RealPcArpEntry's result (DisplayName, DisplayVersion, InstallDate, Key, Hive).
.PARAMETER Title
    When it was taken, e.g. 'before stage 0 Preflight'.
.RETURNS
    [string]
#>
function Format-RealPcArpSnapshot {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Entry = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Title = ''
    )

    $entries = @($Entry | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { [string]$_.DisplayName } }, @{ Expression = { [string]$_.Hive } }, @{ Expression = { [string]$_.Key } })
    $lines = @(
        ('Apps & features (uninstall entries) {0}: {1} entries. Evidence only; no check reads it.' -f $Title, $entries.Count),
        'HKLM64 and HKLM32 are both registry views of HKEY_LOCAL_MACHINE; HKCU is the account the harness runs as.',
        'DisplayName | DisplayVersion | InstallDate | Hive\Key'
    )
    foreach ($item in $entries) {
        $lines += ('{0} | {1} | {2} | {3}\{4}' -f $item.DisplayName, $item.DisplayVersion, $item.InstallDate, $item.Hive, $item.Key)
    }
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

# When a stage's Apps & features snapshot is taken: 'Before' Preflight (the PC as found), 'After'
# each stage that installs or uninstalls, $null for the others.
function Get-RealPcArpSnapshotMoment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$StageName
    )

    if ($StageName -eq 'Preflight') {
        return 'Before'
    }
    if (@('FirstRun', 'ReRun', 'System', 'WinGetClient', 'TimeBudget', 'Uninstaller') -contains $StageName) {
        return 'After'
    }
    return $null
}

<#
.SYNOPSIS
    Which of a stage's winget logs to copy: all of them up to First + Last; beyond that the first
    First (the earliest failure explains the rest) and the last Last, oldest first.
.PARAMETER Log
    The log files (objects with Name and LastWriteTime) written during the stage.
.PARAMETER First
    How many of the earliest to keep. Default 15.
.PARAMETER Last
    How many of the latest to keep. Default 25.
.RETURNS
    [pscustomobject] with Selected (oldest first), Total and Dropped.
#>
function Select-RealPcWingetLog {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Log = @(),

        [Parameter(Mandatory = $false)]
        [int]$First = 15,

        [Parameter(Mandatory = $false)]
        [int]$Last = 25
    )

    $sorted = @($Log | Where-Object { $null -ne $_ } | Sort-Object -Property LastWriteTime, Name)
    $selected = $sorted
    if ($sorted.Count -gt ($First + $Last)) {
        $selected = @($sorted | Select-Object -First $First) + @($sorted | Select-Object -Last $Last)
    }
    return [pscustomobject]@{ Selected = @($selected); Total = $sorted.Count; Dropped = ($sorted.Count - @($selected).Count) }
}

<#
.SYNOPSIS
    The text of a stage's winget-logs\README.txt: how many logs each source folder had, and how
    many were copied and left out (Select-RealPcWingetLog).
.PARAMETER Source
    One object per source folder: Label, Folder, Total and Copied.
.RETURNS
    [string]
#>
function Format-RealPcWingetLogReadme {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Source = @()
    )

    $lines = @(
        "winget's own logs written during this stage, copied here as <source>-<file name>.",
        'A source with more than 40 keeps its first 15 (the first failure explains the rest) and its last 25.',
        ''
    )
    foreach ($item in @($Source | Where-Object { $null -ne $_ })) {
        $lines += ('{0}: {1} written during the stage, {2} copied, {3} left out ({4})' -f $item.Label, $item.Total, $item.Copied, ([int]$item.Total - [int]$item.Copied), $item.Folder)
    }
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
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
    A random string of ASCII letters and digits (no look-alikes), for the temporary user's name and
    password and the TightVNC test password.
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

<#
.SYNOPSIS
    Runs a program, shows (and transcribes) its output line by line, optionally appends it to a
    file, and returns its exit code and output.
.DESCRIPTION
    Native stderr must not stop the harness: Windows PowerShell turns redirected stderr into error
    records, and a step shell that set $ErrorActionPreference to Stop would make the first one a
    terminating error, so this sets Continue for itself. The caller sets any environment variables
    first.
.PARAMETER FilePath
    The program.
.PARAMETER ArgumentList
    Its arguments.
.PARAMETER ConsoleLogPath
    A file to append every output line to (the stage's console evidence), or empty.
.RETURNS
    [pscustomobject] with ExitCode ($null when the program could not be started or gave none) and
    Output ([string[]]).
#>
function Invoke-RealPcProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ConsoleLogPath = ''
    )

    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]
    $exitCode = $null
    $global:LASTEXITCODE = $null
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host $line
            $lines.Add($line)
            if ($ConsoleLogPath) {
                try {
                    [System.IO.File]::AppendAllText($ConsoleLogPath, $line + [Environment]::NewLine)
                }
                catch {
                }
            }
        }
        $exitCode = $global:LASTEXITCODE
    }
    catch {
        $message = "Could not start ${FilePath}: $($_.Exception.Message)"
        Write-RealPcLine $message 'Red'
        $lines.Add($message)
        $exitCode = $null
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $lines.ToArray() }
}

<#
.SYNOPSIS
    Joins arguments into one command line, quoted the way Windows programs split it again.
.DESCRIPTION
    For ProcessStartInfo.Arguments: Windows PowerShell's .NET has no ArgumentList. An argument that
    is empty or holds white space or a double quote is wrapped in double quotes, with backslashes
    before a quote doubled (CommandLineToArgvW). A copy of the module's
    ConvertTo-ProcessArgumentString: this script loads no module code.
.PARAMETER ArgumentList
    The arguments.
.RETURNS
    [string]
#>
function ConvertTo-RealPcCommandLine {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @()
    )

    if ($null -eq $ArgumentList) {
        return ''
    }
    $parts = foreach ($argument in $ArgumentList) {
        $text = [string]$argument
        if ($text.Length -gt 0 -and $text -notmatch '[\s"]') {
            $text
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $text.ToCharArray()) {
            if ($character -eq [char]'\') {
                $backslashes++
                continue
            }
            if ($character -eq [char]'"') {
                [void]$builder.Append([char]'\', (2 * $backslashes) + 1)
            }
            elseif ($backslashes -gt 0) {
                [void]$builder.Append([char]'\', $backslashes)
            }
            [void]$builder.Append($character)
            $backslashes = 0
        }
        [void]$builder.Append([char]'\', 2 * $backslashes)
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return (@($parts) -join ' ')
}

# A program's redirected output as lines: terminal control sequences, blank lines and winget's
# spinner lines (- \ | /) dropped; carriage returns split lines as winget's redraws do.
function ConvertTo-RealPcOutputLine {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $lines = @()
    foreach ($line in @([string]$Text -split '[\r\n]+')) {
        $plain = ($line -replace '\x1b\[[0-?]*[ -/]*[@-~]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '').TrimEnd()
        if ([string]::IsNullOrWhiteSpace($plain) -or $plain -match '^\s*[-\\|/]\s*$') {
            continue
        }
        $lines += $plain
    }
    return $lines
}

<#
.SYNOPSIS
    The result of a bounded program run (Invoke-RealPcBoundedProcess), from what happened.
.DESCRIPTION
    Only a program that ended on its own has an exit code. A timeout and a program that did not
    start give ExitCode $null, which every verdict reads as 'no answer' or a failure, and a Problem
    that is also the last output line, so the evidence says why.
.PARAMETER ExitCode
    The exit code, when the program ended on its own.
.PARAMETER TimedOut
    The time limit ran out and the program was stopped.
.PARAMETER StartProblem
    Why the program did not start, or empty.
.PARAMETER TimeoutSeconds
    The limit, for the Problem.
.PARAMETER Output
    What the program printed (ConvertTo-RealPcOutputLine).
.RETURNS
    [pscustomobject] with ExitCode, TimedOut, Output ([string[]]) and Problem ('' when it ended on
    its own).
#>
function Get-RealPcBoundedProcessResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [bool]$TimedOut = $false,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$StartProblem = '',

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Output = @()
    )

    $lines = @($Output | Where-Object { $null -ne $_ })
    $problem = ''
    if ($StartProblem) {
        $problem = 'not run: ' + $StartProblem
    }
    elseif ($TimedOut) {
        $problem = 'timed out after {0} s' -f $TimeoutSeconds
    }
    elseif ($null -eq $ExitCode) {
        $problem = 'ended without an exit code'
    }
    if ($problem) {
        return [pscustomobject]@{ ExitCode = $null; TimedOut = [bool]$TimedOut; Output = [string[]]@($lines + @($problem)); Problem = $problem }
    }
    return [pscustomobject]@{ ExitCode = [int]$ExitCode; TimedOut = $false; Output = [string[]]$lines; Problem = '' }
}

# Stops a program and everything it started: taskkill /T on Windows (Windows PowerShell's .NET has
# no tree kill), else Process.Kill($true), and Kill() as the last resort. Adapted from the module's
# Stop-ProcessTree.
function Stop-RealPcProcessTree {
    param (
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            $killerInfo = New-Object System.Diagnostics.ProcessStartInfo
            $killerInfo.FileName = Get-RealPcSystem32Path -ChildPath 'taskkill.exe'
            $killerInfo.Arguments = '/PID {0} /T /F' -f $Process.Id
            $killerInfo.UseShellExecute = $false
            $killerInfo.CreateNoWindow = $true
            $killerInfo.RedirectStandardOutput = $true
            $killerInfo.RedirectStandardError = $true
            $killer = [System.Diagnostics.Process]::Start($killerInfo)
            $null = $killer.StandardOutput.ReadToEndAsync()
            $null = $killer.StandardError.ReadToEndAsync()
            if ($killer.WaitForExit(30000) -and $Process.WaitForExit(10000)) {
                return
            }
        }
        catch {
        }
    }
    try {
        $Process.Kill($true)
    }
    catch {
        # Kill(bool) does not exist on .NET Framework; the process may also be gone already.
        try {
            $Process.Kill()
        }
        catch {
        }
    }
    try {
        [void]$Process.WaitForExit(10000)
    }
    catch {
    }
}

<#
.SYNOPSIS
    Runs a program with a time limit and returns its exit code and output; never reads
    $LASTEXITCODE.
.DESCRIPTION
    Modelled on Invoke-BoundedProcess in e2e/Remove-PreinstalledApps.ps1, which this standalone
    script does not load. stdout and stderr are read asynchronously, so a full pipe cannot stall
    the program, and stdin is closed, so nothing waits for a key. When the limit runs out, the
    program and everything it started are stopped (Stop-RealPcProcessTree). Each output stream is
    waited for at most 5 seconds after that, in case a child the program started still holds it.
.PARAMETER FilePath
    The program.
.PARAMETER ArgumentList
    Its arguments (ConvertTo-RealPcCommandLine).
.PARAMETER TimeoutSeconds
    The limit.
.RETURNS
    Get-RealPcBoundedProcessResult's result: ExitCode ($null when it did not start or timed out),
    TimedOut, Output and Problem.
#>
function Invoke-RealPcBoundedProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $process = $null
    $readers = @()
    $exitCode = $null
    $timedOut = $false
    $startProblem = ''
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $FilePath
        $info.Arguments = ConvertTo-RealPcCommandLine -ArgumentList $ArgumentList
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $process = [System.Diagnostics.Process]::Start($info)
        $readers = @($process.StandardOutput.ReadToEndAsync(), $process.StandardError.ReadToEndAsync())
        try {
            $process.StandardInput.Close()
        }
        catch {
        }
        if ($process.WaitForExit($TimeoutSeconds * 1000)) {
            $exitCode = $process.ExitCode
        }
        else {
            $timedOut = $true
            Stop-RealPcProcessTree -Process $process
        }
    }
    catch {
        $startProblem = ([string]$_.Exception.Message -replace '\s*[\r\n]+\s*', ' ').Trim()
    }
    $output = @()
    foreach ($reader in $readers) {
        try {
            if ($reader.Wait(5000)) {
                $output += @(ConvertTo-RealPcOutputLine -Text ([string]$reader.Result))
            }
        }
        catch {
        }
    }
    if ($null -ne $process) {
        $process.Dispose()
    }
    return (Get-RealPcBoundedProcessResult -ExitCode $exitCode -TimedOut $timedOut -StartProblem $startProblem -TimeoutSeconds $TimeoutSeconds -Output $output)
}

# The 64-bit Windows PowerShell 5.1 path, which the installer's 5.1 bootstrap relaunches from.
function Get-RealPcWindowsPowerShellPath {
    $root = $env:SystemRoot
    if (-not $root) {
        $root = 'C:\Windows'
    }
    # Joined as text: Join-Path would refuse a drive this PowerShell does not have (tests off Windows).
    return ($root.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe')
}

<#
.SYNOPSIS
    Runs a query in a child Windows PowerShell with the WingetAppSetup module imported and the e2e
    SYSTEM-pass helpers dot-sourced, and returns its answer.
.DESCRIPTION
    Keeps the module out of this process. The module runs under Windows PowerShell 5.1 (its
    manifest asks for 5.1, and the uninstaller runs the same functions there), so the query works
    before the first install pass has installed PowerShell 7: the first run's expectations are
    decided before it changes anything. The script goes as -EncodedCommand, so no quoting can
    break it, and the answer is the line after the sentinel (Get-RealPcModuleJsonResult), so a
    warning the module prints is not taken for it.
.PARAMETER Body
    The query; it must assign $result.
.RETURNS
    [pscustomobject] with Ok, Value and Problem (Get-RealPcModuleJsonResult).
#>
function Invoke-RealPcModuleJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $ErrorActionPreference = 'Continue'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script = Get-RealPcModuleQueryScript -Body $Body -ManifestPath (Join-Path $repoRoot 'WingetAppSetup\WingetAppSetup.psd1') -SystemPassPath (Join-Path $PSScriptRoot 'Invoke-SystemInstallPass.ps1')
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    $powerShell = Get-RealPcWindowsPowerShellPath
    $output = @()
    try {
        $output = @(& $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded 2>$null | ForEach-Object { [string]$_ })
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Problem = "could not start ${powerShell}: $($_.Exception.Message)" }
    }
    return (Get-RealPcModuleJsonResult -Output $output)
}

# The catalog's package ids (Get-DefaultAppCatalog), via a child Windows PowerShell; empty when the
# query fails.
function Get-RealPcCatalogId {
    $read = Invoke-RealPcModuleJson -Body '$result = @(Get-DefaultAppCatalog | ForEach-Object { [string]$_.name })'
    if (-not $read.Ok -or $null -eq $read.Value) {
        return @()
    }
    return @($read.Value | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

<#
.SYNOPSIS
    The module query (for Invoke-RealPcModuleJson) that builds the per-app expectations of an
    install run with Get-SystemPassAppExpectation.
.PARAMETER System
    The run is a run for the whole PC (SYSTEM): applicability is decided with Test-IsSystemAccount
    true (Get-SystemRunApplicability).
.PARAMETER AlreadyPresent
    A re-run or a run after the apps are installed: every app that would be Installed must now be
    present.
.RETURNS
    [string] the query; it sets $result.
#>
function Get-RealPcAppExpectationQuery {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$System,

        [Parameter(Mandatory = $false)]
        [switch]$AlreadyPresent
    )

    $applicabilityLine = '$applicability = @{}; foreach ($app in $catalog) { $applicability[$app.name] = [bool](Test-AppApplicability -App $app) }'
    if ($System) {
        $applicabilityLine = '$applicability = Get-SystemRunApplicability -Catalog $catalog -Module (Get-Module WingetAppSetup)'
    }
    $alreadyPresentArgument = ''
    if ($AlreadyPresent) {
        $alreadyPresentArgument = ' -AlreadyPresent'
    }
    return (@(
            '$catalog = @(Get-DefaultAppCatalog)',
            $applicabilityLine,
            ('$result = @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability $applicability' + $alreadyPresentArgument + ')')
        ) -join "`n")
}

<#
.SYNOPSIS
    Builds the per-app expectations for an install run, via the module and
    Get-SystemPassAppExpectation in a child Windows PowerShell. Call it BEFORE the run: the
    installer decides applicability before it changes anything, and its Windows Terminal step
    changes what the Terminal condition reads.
.PARAMETER System
    See Get-RealPcAppExpectationQuery.
.PARAMETER AlreadyPresent
    See Get-RealPcAppExpectationQuery.
.RETURNS
    [pscustomobject] with Value (the expectation objects: Id, Expected, Reason,
    AlreadyPresentReasons, MustInstall; $null when they could not be built) and Problem.
#>
function Get-RealPcAppExpectation {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$System,

        [Parameter(Mandatory = $false)]
        [switch]$AlreadyPresent
    )

    $read = Invoke-RealPcModuleJson -Body (Get-RealPcAppExpectationQuery -System:$System -AlreadyPresent:$AlreadyPresent)
    if ($read.Ok -and $null -ne $read.Value) {
        $values = @($read.Value | Where-Object { $null -ne $_ })
        if ($values.Count -gt 0) {
            return [pscustomobject]@{ Value = $values; Problem = $null }
        }
        return [pscustomobject]@{ Value = $null; Problem = 'the catalog query returned no apps' }
    }
    $problem = [string]$read.Problem
    if (-not $problem) {
        $problem = 'the catalog query returned nothing'
    }
    return [pscustomobject]@{ Value = $null; Problem = $problem }
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

<#
.SYNOPSIS
    What Get-RealPcReportPathProblem needs to know about a -ReportPath. Reads only.
.RETURNS
    [pscustomobject] with Exists, IsDirectory, IsEmpty, IsReparsePoint, ZipExists,
    LocalFolderInUse and LocalFolder (Get-RealPcLocalFolderPath).
#>
function Get-RealPcReportPathState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $exists = Test-Path -LiteralPath $Path
    $isDirectory = $exists -and (Test-Path -LiteralPath $Path -PathType Container)
    $isEmpty = $true
    if ($isDirectory) {
        $isEmpty = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -eq 0
    }
    $localFolder = Get-RealPcLocalFolderPath -ReportPath $Path
    $localInUse = (Test-Path -LiteralPath $localFolder) -and @(Get-ChildItem -LiteralPath $localFolder -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0
    return [pscustomobject]@{
        Exists           = [bool]$exists
        IsDirectory      = [bool]$isDirectory
        IsEmpty          = [bool]$isEmpty
        IsReparsePoint   = ((Test-RealPcReparsePoint -Path $Path) -eq $true)
        ZipExists        = [bool](Test-Path -LiteralPath ($Path + '.zip'))
        LocalFolderInUse = [bool]$localInUse
        LocalFolder      = $localFolder
    }
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

# winget's full path as a program in this account (its App Installer alias), or $null.
function Get-RealPcWingetPath {
    $command = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return [string]$command.Path
    }
    return $null
}

<#
.SYNOPSIS
    Runs winget with a time limit (Invoke-RealPcBoundedProcess), found by Get-RealPcWingetPath.
.PARAMETER ArgumentList
    winget's arguments.
.PARAMETER TimeoutSeconds
    The limit: $script:RealPcWingetListTimeoutSeconds and its siblings.
.RETURNS
    Invoke-RealPcBoundedProcess's result; ExitCode $null and Problem 'not run: ...' when winget is
    not here.
#>
function Invoke-RealPcWinget {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $wingetPath = Get-RealPcWingetPath
    if (-not $wingetPath) {
        return (Get-RealPcBoundedProcessResult -StartProblem 'winget was not found in this account' -TimeoutSeconds $TimeoutSeconds)
    }
    return (Invoke-RealPcBoundedProcess -FilePath $wingetPath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds)
}

# Whether winget lists a package id as installed: $true, $false, or $null when winget could not
# answer, a timeout included (Get-RealPcWingetListVerdict). --source winget: without it, a source
# that cannot open is only a warning and an installed app reads as not installed (0x8A150014).
function Test-RealPcWingetInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $run = Invoke-RealPcWinget -ArgumentList @('list', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $script:RealPcWingetListTimeoutSeconds
    return (Get-RealPcWingetListVerdict -ExitCode $run.ExitCode)
}

# Whether winget can be started as a program in this account (its App Installer alias).
function Test-RealPcWingetPresent {
    return [bool](Get-RealPcWingetPath)
}

# Uninstalls one package with winget, silently, as this account, from the winget source (as
# Test-RealPcWingetInstalled looks it up). Returns ExitCode ($null when winget did not run to the
# end), Problem (why, e.g. 'timed out after 150 s') and Output (for the evidence).
function Invoke-RealPcWingetUninstall {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $run = Invoke-RealPcWinget -ArgumentList @('uninstall', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $script:RealPcWingetUninstallTimeoutSeconds
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Problem = [string]$run.Problem; Output = @($run.Output) }
}

# The source check: winget looks one package up in its 'winget' source, as this account. Returns
# ExitCode ($null when winget did not run to the end) and Output (for the evidence, with why).
function Invoke-RealPcWingetSourceCheck {
    $run = Invoke-RealPcWinget -ArgumentList @('search', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $script:RealPcWingetSearchTimeoutSeconds
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Output = @($run.Output) }
}

<#
.SYNOPSIS
    Records a source check for the later stages and the report's banner, and returns its row.
.PARAMETER ExitCode
    Invoke-RealPcWingetSourceCheck's ExitCode.
.PARAMETER When
    Which check this is (Get-RealPcWingetSourceRow): empty for Preflight.
.PARAMETER SourcePackage
    The source package for this account, for the detail.
.RETURNS
    The row (Get-RealPcWingetSourceRow). Sets $script:WingetSourceOpen and adds to
    $script:WingetSourceChecks.
#>
function Add-RealPcWingetSourceCheck {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$When = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SourcePackage = ''
    )

    $opened = ($null -ne $ExitCode -and [int]$ExitCode -eq 0)
    $script:WingetSourceOpen = $opened
    $script:WingetSourceChecks = @(@($script:WingetSourceChecks) | Where-Object { $null -ne $_ }) + @([pscustomobject]@{ When = $When; ExitCode = $ExitCode; Opened = $opened; SourcePackage = $SourcePackage })
    return (Get-RealPcWingetSourceRow -ExitCode $ExitCode -When $When -SourcePackage $SourcePackage)
}

# Runs a program without echoing it, and returns ExitCode ($null when it could not start) and Output.
function Invoke-RealPcQuietProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = $null
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Output = $output }
    }
    catch {
        return [pscustomobject]@{ ExitCode = $null; Output = @("could not run ${FilePath}: $($_.Exception.Message)") }
    }
}

# winget's source package for this account: its version, 'not registered', or why it could not be
# read. Windows only.
function Get-RealPcWingetSourcePackage {
    try {
        $package = @(Get-AppxPackage -Name 'Microsoft.Winget.Source' -ErrorAction Stop) | Select-Object -First 1
        if ($package) {
            return [string]$package.Version
        }
        return 'not registered'
    }
    catch {
        return "unreadable ($($_.Exception.Message))"
    }
}

<#
.SYNOPSIS
    winget's facts in this account: its version, App Installer's version, its source package, and
    the raw text of 'winget --info', 'winget source list' and every account's registration of the
    source package. Reads only. Windows only.
.RETURNS
    [pscustomobject] with WingetVersion, AppInstallerVersion, SourcePackage and Raw (title ->
    lines, in order).
#>
function Get-RealPcWingetFact {
    $ErrorActionPreference = 'Continue'
    $fact = [pscustomobject]@{ WingetVersion = ''; AppInstallerVersion = ''; SourcePackage = ''; Raw = [ordered]@{} }

    # Bounded like a search: none of these may hold the run up.
    $version = Invoke-RealPcWinget -ArgumentList @('--version') -TimeoutSeconds $script:RealPcWingetSearchTimeoutSeconds
    $fact.WingetVersion = (@($version.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1)
    if ($null -eq $version.ExitCode) {
        $fact.WingetVersion = ('winget could not run ({0})' -f $version.Problem)
    }
    foreach ($argumentText in @('--info', 'source list')) {
        $run = Invoke-RealPcWinget -ArgumentList @($argumentText -split ' ') -TimeoutSeconds $script:RealPcWingetSearchTimeoutSeconds
        $fact.Raw[('winget {0} (exit {1})' -f $argumentText, (Format-RealPcWingetExitCode -ExitCode $run.ExitCode))] = @($run.Output)
    }

    try {
        $appInstaller = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop) | Select-Object -First 1
        $fact.AppInstallerVersion = 'not registered'
        if ($appInstaller) {
            $fact.AppInstallerVersion = [string]$appInstaller.Version
        }
    }
    catch {
        $fact.AppInstallerVersion = "unreadable ($($_.Exception.Message))"
    }
    $fact.SourcePackage = Get-RealPcWingetSourcePackage

    # Every account's registration of the source package (-AllUsers needs elevation).
    $registrations = @()
    try {
        foreach ($package in @(Get-AppxPackage -AllUsers -Name 'Microsoft.Winget.Source' -ErrorAction Stop)) {
            $registrations += ('{0}' -f $package.PackageFullName)
            foreach ($user in @($package.PackageUserInformation)) {
                $registrations += ('  {0}' -f [string]$user)
            }
        }
        if ($registrations.Count -eq 0) {
            $registrations = @('no account has it registered')
        }
    }
    catch {
        $registrations = @("could not read it: $($_.Exception.Message)")
    }
    $fact.Raw['Get-AppxPackage -AllUsers -Name Microsoft.Winget.Source (PackageUserInformation)'] = $registrations
    return $fact
}

# Processes oldest first, by CreationDate, sorted as the installer sorts them
# (Get-SessionShellOwnerName: Sort-Object CreationDate, which puts one without a date first). The
# session's first explorer.exe is the signed-in user's shell: one started later may run as another
# account.
function Select-RealPcOldestProcess {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Process = @()
    )

    return @($Process | Where-Object { $null -ne $_ } | Sort-Object -Property CreationDate)
}

<#
.SYNOPSIS
    Who runs the harness and who is signed in: the elevated account and its SID, its profile's
    creation time, the owner of the oldest explorer.exe in this process's session (the same rule
    as the installer's), the console user (Win32_ComputerSystem) and the sessions qwinsta lists.
    Reads only; what cannot be read stays empty. Windows only.
.RETURNS
    [pscustomobject] with ElevatedUser, ElevatedSid, ProfileCreated, SessionUser, SessionUserSid,
    ConsoleUser and Sessions ([string[]]).
#>
function Get-RealPcAccountFact {
    $ErrorActionPreference = 'Continue'
    $fact = [pscustomobject]@{ ElevatedUser = ''; ElevatedSid = ''; ProfileCreated = ''; SessionUser = ''; SessionUserSid = ''; ConsoleUser = ''; Sessions = @() }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $fact.ElevatedUser = [string]$identity.Name
        $fact.ElevatedSid = [string]$identity.User.Value
    }
    catch {
    }
    try {
        $fact.ProfileCreated = (Get-Item -LiteralPath $env:USERPROFILE -Force -ErrorAction Stop).CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
    }
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $explorers = @(Get-CimInstance -ClassName Win32_Process -Filter ("Name = 'explorer.exe' AND SessionId = {0}" -f $sessionId) -ErrorAction Stop)
        # The installer's rule (Get-SessionShellOwnerName): a shell whose owner cannot be read, or
        # comes back without ReturnValue 0, a user and a domain, is passed over.
        foreach ($explorer in @(Select-RealPcOldestProcess -Process $explorers)) {
            try {
                $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            }
            catch {
                continue
            }
            if (-not ($owner -and $owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace($owner.User) -and -not [string]::IsNullOrWhiteSpace($owner.Domain))) {
                continue
            }
            $fact.SessionUser = '{0}\{1}' -f $owner.Domain, $owner.User
            try {
                $fact.SessionUserSid = [string](Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction Stop).Sid
            }
            catch {
            }
            if ([string]::IsNullOrWhiteSpace($fact.SessionUserSid)) {
                try {
                    $fact.SessionUserSid = ([System.Security.Principal.NTAccount]$fact.SessionUser).Translate([System.Security.Principal.SecurityIdentifier]).Value
                }
                catch {
                }
            }
            break
        }
    }
    catch {
    }
    try {
        $fact.ConsoleUser = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    }
    catch {
    }
    $sessions = Invoke-RealPcQuietProcess -FilePath (Get-RealPcSystem32Path -ChildPath 'qwinsta.exe')
    $fact.Sessions = @($sessions.Output | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() } | Where-Object { $_ })
    return $fact
}

<#
.SYNOPSIS
    The uninstall entries Apps & features lists: both registry views of HKLM (through
    RegistryKey.OpenBaseKey, so a 32-bit host sees both) and this account's HKCU. An entry without
    a DisplayName is left out. Reads only. Windows only.
.RETURNS
    [pscustomobject[]] with DisplayName, DisplayVersion, InstallDate, Key and Hive.
#>
function Get-RealPcArpEntry {
    $views = @(
        @{ Hive = 'HKLM64'; Base = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64 },
        @{ Hive = 'HKLM32'; Base = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 },
        @{ Hive = 'HKCU'; Base = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default }
    )
    if (-not [Environment]::Is64BitOperatingSystem) {
        $views = @(
            @{ Hive = 'HKLM'; Base = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Default },
            @{ Hive = 'HKCU'; Base = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default }
        )
    }
    $entries = @()
    foreach ($view in $views) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view.Base, $view.View)
            $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -ne $key) {
                foreach ($name in $key.GetSubKeyNames()) {
                    $sub = $null
                    try {
                        $sub = $key.OpenSubKey($name)
                        if ($null -ne $sub -and -not [string]::IsNullOrWhiteSpace([string]$sub.GetValue('DisplayName'))) {
                            $entries += [pscustomobject]@{
                                DisplayName    = [string]$sub.GetValue('DisplayName')
                                DisplayVersion = [string]$sub.GetValue('DisplayVersion')
                                InstallDate    = [string]$sub.GetValue('InstallDate')
                                Key            = [string]$name
                                Hive           = $view.Hive
                            }
                        }
                    }
                    catch {
                    }
                    finally {
                        if ($null -ne $sub) {
                            $sub.Dispose()
                        }
                    }
                }
            }
        }
        catch {
            $entries += [pscustomobject]@{ DisplayName = "(could not read $($view.Hive): $($_.Exception.Message))"; DisplayVersion = ''; InstallDate = ''; Key = ''; Hive = $view.Hive }
        }
        finally {
            if ($null -ne $key) {
                $key.Dispose()
            }
            if ($null -ne $base) {
                $base.Dispose()
            }
        }
    }
    return $entries
}

# Writes text to a file as UTF-8 without a BOM; a failure is reported on the console, never thrown.
function Save-RealPcText {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Text = ''
    )

    try {
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-RealPcLine "Could not write ${Path}: $($_.Exception.Message)" 'Yellow'
    }
}

# Writes the Apps & features snapshot (Format-RealPcArpSnapshot) to a file: evidence only.
function Save-RealPcArpSnapshot {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Title = ''
    )

    $entries = @()
    try {
        $entries = @(Get-RealPcArpEntry)
    }
    catch {
        $entries = @([pscustomobject]@{ DisplayName = "(could not read the uninstall entries: $($_.Exception.Message))"; DisplayVersion = ''; InstallDate = ''; Key = ''; Hive = '' })
    }
    Save-RealPcText -Path $Path -Text (Format-RealPcArpSnapshot -Entry $entries -Title $Title)
}

# The folders winget writes its own logs to: this account's (packaged winget's DiagOutputDir) and a
# run as SYSTEM's (unpackaged winget's %TEMP%\WinGet\defaultState, under either SYSTEM temp folder).
function Get-RealPcWingetLogSource {
    $sources = [ordered]@{}
    if ($env:LOCALAPPDATA) {
        $sources['user'] = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    }
    if ($env:SystemRoot) {
        $sources['system'] = Join-Path $env:SystemRoot 'Temp\WinGet\defaultState'
        $sources['systemtemp'] = Join-Path $env:SystemRoot 'SystemTemp\WinGet\defaultState'
    }
    return $sources
}

# The catalog ids winget lists as installed, and those it could not answer for.
function Get-RealPcInstalledCatalogId {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$CatalogId
    )

    $installed = @()
    $unknown = @()
    foreach ($id in @($CatalogId)) {
        $answer = Test-RealPcWingetInstalled -Id $id
        if ($null -eq $answer) {
            $unknown += $id
        }
        elseif ($answer) {
            $installed += $id
        }
    }
    return [pscustomobject]@{ Installed = $installed; Unknown = $unknown }
}

# The hosts the installer downloads from (winget's source, GitHub, the PowerShell Gallery, aka.ms).
function Get-RealPcInstallerHostUrl {
    return @(
        'https://cdn.winget.microsoft.com/cache/source.msix',
        'https://github.com/',
        'https://raw.githubusercontent.com/',
        'https://aka.ms/',
        'https://www.powershellgallery.com/'
    )
}

<#
.SYNOPSIS
    Asks a URL for its headers (HEAD, no redirects, twice at most) and says whether anything
    answered: any HTTP status counts as reachable.
.RETURNS
    [pscustomobject] with Url, Reachable and Detail.
#>
function Test-RealPcUrlReachable {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 15
    )

    $detail = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $request = [System.Net.WebRequest]::Create($Url)
            $request.Method = 'HEAD'
            $request.Timeout = $TimeoutSeconds * 1000
            $request.AllowAutoRedirect = $false
            $response = $request.GetResponse()
            try {
                $code = [int]$response.StatusCode
            }
            finally {
                $response.Close()
            }
            return [pscustomobject]@{ Url = $Url; Reachable = $true; Detail = "HTTP $code" }
        }
        catch {
            # .NET's WebException arrives wrapped in PowerShell's MethodInvocationException.
            $exception = $_.Exception
            while ($null -ne $exception -and -not ($exception -is [System.Net.WebException])) {
                $exception = $exception.InnerException
            }
            if ($null -ne $exception -and $null -ne $exception.Response) {
                $code = [int]$exception.Response.StatusCode
                $exception.Response.Close()
                return [pscustomobject]@{ Url = $Url; Reachable = $true; Detail = "HTTP $code" }
            }
            if ($null -ne $exception) {
                $detail = "$($exception.Status): $($exception.Message)"
            }
            else {
                $detail = $_.Exception.Message
            }
        }
    }
    return [pscustomobject]@{ Url = $Url; Reachable = $false; Detail = "no answer: $detail" }
}

# The installer command for an install pass: the one-liner (Get-RealPcOneLinerScript, as
# -EncodedCommand) or the checkout's file with -File.
function Get-RealPcInstallerInvocation {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$ExtraArgument = @()
    )

    $powerShell = Get-RealPcWindowsPowerShellPath
    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ($script:RealPcOptions.UseOneLiner) {
        $url = 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/{0}/winget-app-install.ps1' -f $script:RealPcOptions.Branch
        $oneLiner = Get-RealPcOneLinerScript -Url $url -ArgumentList $ExtraArgument
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($oneLiner))
        return [pscustomobject]@{ FilePath = $powerShell; Arguments = @('-NoProfile', '-OutputFormat', 'Text', '-EncodedCommand', $encoded); Description = "the one-liner from $url" }
    }
    $installer = Join-Path $repoRoot 'winget-app-install.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-NonInteractive') + @($ExtraArgument)
    return [pscustomobject]@{ FilePath = $powerShell; Arguments = $arguments; Description = "the checkout's $installer" }
}

# Runs the installer once with the given extra arguments and environment, and returns
# Invoke-RealPcProcess's result.
function Invoke-RealPcInstaller {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$ExtraArgument = @(),

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$Environment = @{},

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ConsoleLogPath = ''
    )

    $invocation = Get-RealPcInstallerInvocation -ExtraArgument $ExtraArgument
    Write-RealPcLine ('Running {0} {1}' -f $invocation.Description, (@($ExtraArgument) -join ' ')) 'Cyan'
    $saved = @{}
    foreach ($name in @($Environment.Keys)) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name])
    }
    try {
        return (Invoke-RealPcProcess -FilePath $invocation.FilePath -ArgumentList $invocation.Arguments -ConsoleLogPath $ConsoleLogPath)
    }
    finally {
        foreach ($name in @($saved.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

# last-run.json, only when a run that started at or after -Since wrote it.
function Read-RealPcRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )

    $read = Read-SystemPassRunRecord -Path $Path
    if ($null -eq $read.Record) {
        return [pscustomobject]@{ Record = $null; Problem = $read.Problem }
    }
    $fresh = Test-RealPcRunRecordFresh -RunRecord $read.Record -Since $Since
    if (-not $fresh.Fresh) {
        return [pscustomobject]@{ Record = $null; Problem = $fresh.Detail }
    }
    return [pscustomobject]@{ Record = $read.Record; Problem = $null }
}

# The text of every installer transcript (bootstrap ones included) written since a time.
function Get-RealPcTranscriptText {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )

    $files = Get-InstallTranscriptFile -LogDirectory $LogDirectory
    $text = ''
    foreach ($file in @(@($files.Bootstrap) + @($files.RealRun) | Where-Object { $null -ne $_ -and $_.LastWriteTime -ge $Since })) {
        $text += [string](Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue) + [Environment]::NewLine
    }
    return $text
}

# Waits for a one-shot task to end; returns its exit code, or $null when it did not end in time.
function Wait-RealPcScheduledTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 90
    )

    # 267009 (0x41301) is 'the task is running', 267011 (0x41303) 'the task has not yet run'.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $info -and "$($task.State)" -ne 'Running' -and $info.LastRunTime -ge $StartedAt.AddMinutes(-1) -and @(267009, 267011) -notcontains $info.LastTaskResult) {
            return [long](ConvertTo-TaskExitCode -LastTaskResult $info.LastTaskResult)
        }
    }
    return $null
}

# The Task Scheduler COM service, connected (tests give Register-RealPcPlantTask a stand-in).
function New-RealPcTaskService {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return $service
}

# A file in System32, joined as text: Join-Path would refuse a drive this PowerShell does not have.
function Get-RealPcSystem32Path {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $root = $env:SystemRoot
    if (-not $root) {
        $root = 'C:\Windows'
    }
    return ($root.TrimEnd('\') + '\System32\' + $ChildPath)
}

<#
.SYNOPSIS
    Registers the one-shot task that plants the junction as the temporary standard user: an S4U
    logon, limited, through the Task Scheduler COM API.
.DESCRIPTION
    An administrator may register an S4U task for a different account only by giving that account's
    password (Microsoft Learn, 'Security Contexts for Tasks'). Register-ScheduledTask's -Principal
    set takes no password, so Task Scheduler refused it with 'Access is denied' (wgt-gq8.62). With
    TASK_LOGON_S4U the password only authorizes the registration; Task Scheduler stores none. It is
    handed to Task Scheduler as plain text only in the RegisterTaskDefinition call (a managed copy
    of that text stays in memory until it is collected), and is never written, logged or put on a
    command line (as schtasks /RP would put it).
.PARAMETER TaskName
    The task's name, in the root folder; an existing task of that name is replaced.
.PARAMETER UserId
    The account the task runs as, as COMPUTERNAME\name.
.PARAMETER Password
    That account's password.
.PARAMETER Execute
    The program the task runs.
.PARAMETER Argument
    Its arguments.
.RETURNS
    Nothing; throws when the task cannot be registered.
#>
function Register-RealPcPlantTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [string]$UserId,

        [Parameter(Mandatory = $true)]
        [securestring]$Password,

        [Parameter(Mandatory = $true)]
        [string]$Execute,

        [Parameter(Mandatory = $false)]
        [string]$Argument = ''
    )

    $service = New-RealPcTaskService
    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Description = 'winget-app-setup real-PC test plan: plants a junction as a temporary standard user; removed when the run ends.'
    # TASK_LOGON_S4U (2), TASK_RUNLEVEL_LUA (0): no stored password, no elevation.
    $definition.Principal.LogonType = 2
    $definition.Principal.RunLevel = 0
    $definition.Settings.ExecutionTimeLimit = 'PT5M'
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    # TASK_ACTION_EXEC (0).
    $action = $definition.Actions.Create(0)
    $action.Path = $Execute
    $action.Arguments = $Argument
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        # TASK_CREATE_OR_UPDATE (6), TASK_LOGON_S4U (2), no security descriptor.
        $null = $service.GetFolder('\').RegisterTaskDefinition($TaskName, $definition, 6, $UserId, [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), 2, $null)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# The admin fallback: plants the junction as this (administrator) account. A junction needs no
# privilege.
function New-RealPcAdminJunction {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    $null = & cmd.exe /c mklink /J $Path $Target 2>&1
}

<#
.SYNOPSIS
    Reads, without changing anything, who holds 'Log on as a batch job' and 'Deny log on as a batch
    job': the planting task's S4U logon needs the first and must not meet the second.
.DESCRIPTION
    secedit /export writes the machine's user rights to a file in a new temporary folder, which is
    read and deleted; only the two lines are kept (Get-RealPcBatchLogonRightLine). Microsoft's pages
    disagree on whether a Windows client gives the right to Performance Log Users, so a run whose
    task ends with 0x80070569 shows which it is.
.PARAMETER HideName
    Names and SIDs to show as '[temporary user]'.
.RETURNS
    [string[]] the two lines, or one line saying why they could not be read.
#>
function Read-RealPcBatchLogonRight {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$HideName = @()
    )

    $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('wgt-rights-' + [guid]::NewGuid().ToString('N'))
    $exportPath = Join-Path $folder 'user-rights.inf'
    try {
        [void](New-Item -ItemType Directory -Path $folder -ErrorAction Stop)
        $run = Invoke-RealPcProcess -FilePath (Get-RealPcSystem32Path -ChildPath 'secedit.exe') -ArgumentList @('/export', '/areas', 'USER_RIGHTS', '/cfg', $exportPath, '/log', (Join-Path $folder 'secedit.log'), '/quiet')
        if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exportPath)) {
            return @("secedit /export could not read the user rights (exit $($run.ExitCode))")
        }
        # secedit writes UTF-16 with a byte-order mark, which ReadAllText detects.
        return @(Get-RealPcBatchLogonRightLine -Text ([System.IO.File]::ReadAllText($exportPath)) -HideName $HideName)
    }
    catch {
        return @("could not read the user rights: $($_.Exception.Message)")
    }
    finally {
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Copies what a stage left in the installer's log folder (transcripts, the RMM wrapper's log and
    last-run.json) and the winget logs it wrote into the stage's evidence folder: every run
    overwrites last-run.json, so each stage keeps its own copy.
.DESCRIPTION
    Of each source's winget logs written during the stage, all are copied up to 40, else the first
    15 and the last 25 (Select-RealPcWingetLog); winget-logs\README.txt gives the counts.
.PARAMETER Folder
    The stage's evidence folder.
.PARAMETER LogDirectory
    The installer's log folder.
.PARAMETER Since
    When the stage started.
.PARAMETER WingetLogSource
    Label -> folder of winget's own logs. Default: Get-RealPcWingetLogSource.
#>
function Save-RealPcStageEvidence {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Folder,

        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [datetime]$Since,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$WingetLogSource
    )

    $ErrorActionPreference = 'Continue'
    [void](New-Item -ItemType Directory -Path $Folder -Force -ErrorAction SilentlyContinue)
    foreach ($file in @(Get-ChildItem -LiteralPath $LogDirectory -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since -and ($_.Name -like 'install-*.log' -or $_.Name -eq 'last-run.json') })) {
        Copy-Item -LiteralPath $file.FullName -Destination $Folder -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $WingetLogSource) {
        $WingetLogSource = Get-RealPcWingetLogSource
    }
    $target = Join-Path $Folder 'winget-logs'
    [void](New-Item -ItemType Directory -Path $target -Force -ErrorAction SilentlyContinue)
    $counts = @()
    foreach ($label in @($WingetLogSource.Keys)) {
        $sourceFolder = [string]$WingetLogSource[$label]
        $logs = @()
        if ($sourceFolder -and (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
            $logs = @(Get-ChildItem -LiteralPath $sourceFolder -Filter '*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since })
        }
        $pick = Select-RealPcWingetLog -Log $logs
        $copied = 0
        foreach ($log in @($pick.Selected)) {
            try {
                Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $target ($label + '-' + $log.Name)) -Force -ErrorAction Stop
                $copied++
            }
            catch {
            }
        }
        $counts += [pscustomobject]@{ Label = [string]$label; Folder = $sourceFolder; Total = $pick.Total; Copied = $copied }
    }
    Save-RealPcText -Path (Join-Path $target 'README.txt') -Text (Format-RealPcWingetLogReadme -Source $counts)
}

# ---- Stages --------------------------------------------------------------------------------------

# Stage 0 Preflight: machine facts (who is signed in, winget and its source), internet, the source
# check, catalog apps already installed, and a warning for a non-fresh machine or Windows Sandbox.
function Invoke-RealPcPreflightStage {
    param (
        [Parameter(Mandatory = $false)]
        [string]$EvidenceFolder
    )

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
    $facts['OS'] = $osName
    $facts['Build'] = $build
    $facts['Edition'] = $edition
    $facts['Architecture'] = $env:PROCESSOR_ARCHITECTURE
    $facts['Windows PowerShell'] = "$($PSVersionTable.PSVersion)"
    $pwsh = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $facts['PowerShell 7'] = $(if ($pwsh) { $pwsh.Source } else { 'not installed yet' })
    $facts['Elevated'] = (Test-RealPcElevated)
    $facts['Report folder'] = $script:ReportFolder
    $facts['Installer under test'] = $(if ($script:RealPcOptions.UseOneLiner) { "one-liner, branch $($script:RealPcOptions.Branch)" } else { 'the checkout''s files' })
    # The code under test by its build id; for the one-liner, FirstRun fills it in from its run.
    $installerText = ''
    if (-not $script:RealPcOptions.UseOneLiner) {
        try {
            $installerText = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'winget-app-install.ps1'))
        }
        catch {
        }
    }
    $facts['Installer build'] = Get-RealPcInstallerBuildFact -ScriptText $installerText -UseOneLiner:([bool]$script:RealPcOptions.UseOneLiner) -Branch ([string]$script:RealPcOptions.Branch)

    # Who runs the harness and who is signed in: under cross-user elevation (issue #159) the
    # elevated account's per-user packages, winget's source among them, may fail to register.
    $account = Get-RealPcAccountFact
    $crossUser = Get-RealPcCrossUserElevation -ElevatedUser $account.ElevatedUser -ElevatedSid $account.ElevatedSid -SessionUser $account.SessionUser -SessionUserSid $account.SessionUserSid
    $script:ElevatedAccount = [string]$account.ElevatedUser
    $script:CrossUserElevation = $crossUser
    $facts['Elevated account'] = ('{0} ({1})' -f $account.ElevatedUser, $account.ElevatedSid)
    $facts['Elevated account profile created'] = $account.ProfileCreated
    $facts['Signed-in user (this session)'] = $(if ($account.SessionUser) { '{0} ({1})' -f $account.SessionUser, $account.SessionUserSid } else { 'none found (no explorer.exe in this session)' })
    $facts['Console user (Win32_ComputerSystem)'] = $account.ConsoleUser
    $facts['Sessions (qwinsta)'] = (@($account.Sessions) -join '; ')
    $facts['Cross-user elevation'] = $crossUser

    $rows += New-TestPlanBoolRow -Check 'Running elevated' -Passed (Test-RealPcElevated) -Detail 'administrator'

    $wingetPresent = Test-RealPcWingetPresent
    $facts['winget present'] = $wingetPresent
    if (Test-RealPcWindowsSandbox) {
        $rows += New-TestPlanRow -Check 'Windows Sandbox detected' -Result 'SKIP' -Detail 'WDAGUtilityAccount: winget may be missing in Windows Sandbox; install App Installer first'
    }
    if ($wingetPresent) {
        $rows += New-TestPlanRow -Check 'winget present' -Result 'PASS' -Detail 'winget found'
    }
    else {
        $rows += New-TestPlanRow -Check 'winget present' -Result 'SKIP' -Detail 'winget not found yet (a fresh PC may register it shortly, and the installer sets it up); the install stages show whether that worked'
    }

    # winget's state in this account, and whether it can open its source here: without the source,
    # every 'is it installed' answer in this account is 'no'.
    $winget = Get-RealPcWingetFact
    $facts['winget version'] = $winget.WingetVersion
    $facts['App Installer (this account)'] = $winget.AppInstallerVersion
    $facts['winget source package (this account)'] = $winget.SourcePackage
    if ($wingetPresent) {
        $sourceCheck = Invoke-RealPcWingetSourceCheck
        $rows += Add-RealPcWingetSourceCheck -ExitCode $sourceCheck.ExitCode -SourcePackage $winget.SourcePackage
    }
    else {
        # A fresh PC may not have winget yet: the first run sets it up, and the check runs after it.
        $sourceCheck = [pscustomobject]@{ ExitCode = $null; Output = @('not run: winget is not on this PC yet') }
        $rows += New-TestPlanRow -Check 'winget can open its source in this account' -Result 'SKIP' -Detail 'winget is not on this PC yet; the first run sets it up, and the check runs again after it'
    }
    if ($EvidenceFolder) {
        $sections = [ordered]@{}
        $sections[('winget search --id Microsoft.PowerShell --exact --source winget (the source check; exit {0})' -f (Format-RealPcWingetExitCode -ExitCode $sourceCheck.ExitCode))] = @($sourceCheck.Output)
        foreach ($title in @($winget.Raw.Keys)) {
            $sections[$title] = @($winget.Raw[$title])
        }
        Save-RealPcText -Path (Join-Path $EvidenceFolder 'winget-info.txt') -Text (Format-RealPcEvidenceText -Section $sections)
    }

    # TLS 1.2 for this process's probes (Windows PowerShell may default to older protocols).
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
    }
    $probes = @(foreach ($url in Get-RealPcInstallerHostUrl) {
            Test-RealPcUrlReachable -Url $url
        })
    $rows += Get-RealPcReachabilityResult -Probe $probes

    $freeGb = $null
    try {
        $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $freeGb = [Math]::Round($drive.Free / 1GB, 1)
    }
    catch {
    }
    $facts['Free disk (GB)'] = $freeGb
    $rows += New-TestPlanRow -Check 'Free disk space' -Result 'PASS' -Detail "$freeGb GB free on $env:SystemDrive"

    # A non-fresh machine: catalog apps already installed, or an existing ProgramData folder.
    $script:CatalogId = @(Get-RealPcCatalogId)
    $installedRead = [pscustomobject]@{ Installed = @(); Unknown = @() }
    if ($script:CatalogId.Count -gt 0) {
        $installedRead = Get-RealPcInstalledCatalogId -CatalogId $script:CatalogId
    }
    $rows += Get-RealPcInstalledCatalogRow -CatalogId $script:CatalogId -Installed $installedRead.Installed -Unknown $installedRead.Unknown -SourceOpen $script:WingetSourceOpen

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

# Adds a local user to a built-in group by its SID (names are localized); one already there is fine.
function Add-RealPcUserToGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$GroupSid,

        [Parameter(Mandatory = $true)]
        [string]$UserName
    )

    try {
        Add-LocalGroupMember -SID $GroupSid -Member $UserName -ErrorAction Stop
        return $null
    }
    catch {
        if ("$($_.FullyQualifiedErrorId)" -match 'MemberExists') {
            return $null
        }
        return "could not add it to $GroupSid ($($_.Exception.Message))"
    }
}

# Stage 1 LinkGuardSetup: plant a junction at %ProgramData%\winget-app-setup as a temporary standard
# user (item 11). Only when the folder does not exist (or -ResetProgramData renamed it aside).
function Invoke-RealPcLinkGuardSetupStage {
    param (
        [Parameter(Mandatory = $false)]
        [string]$EvidenceFolder
    )

    $rows = @()
    $baseFolder = Join-Path $env:ProgramData 'winget-app-setup'
    if ((Test-Path -LiteralPath $baseFolder) -and $script:RealPcOptions.ResetProgramData) {
        $asideName = 'winget-app-setup-old-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
        try {
            Rename-Item -LiteralPath $baseFolder -NewName $asideName -ErrorAction Stop
            $rows += New-TestPlanRow -Check 'Renamed the existing ProgramData folder aside' -Result 'PASS' -Detail (Join-Path $env:ProgramData $asideName)
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
    $script:LinkGuard.VictimFolder = $publicRoot
    Set-Content -LiteralPath (Join-Path $publicRoot 'marker.txt') -Value 'not the installers file' -Encoding ASCII
    [void](New-Item -ItemType Directory -Path (Join-Path $publicRoot 'sub') -ErrorAction Stop)
    Set-Content -LiteralPath (Join-Path $publicRoot 'sub\inner.txt') -Value 'not the installers file either' -Encoding ASCII
    $script:LinkGuard.VictimBefore = Get-RealPcAclSnapshotTree -Path $publicRoot
    $rows += New-TestPlanRow -Check 'Created a victim folder under C:\Users\Public' -Result 'PASS' -Detail $publicRoot

    # Random name and password, neither printed. The password is never written anywhere: it stays in
    # memory, as a SecureString, until the planting task is registered, and is disposed of then (or
    # in the finally below when no task is registered). A fixed complexity suffix keeps
    # New-LocalUser from refusing it under a complexity policy.
    $userName = 'wgt' + (New-RealPcRandomSecret -Length 8)
    $userSid = ''
    $userCreated = $false
    $userProblem = ''
    $secure = $null
    $taskStep = ''
    $taskProblem = ''
    $taskResult = $null
    $junctionAfterTask = $false
    try {
        try {
            $secure = ConvertTo-SecureString -String ((New-RealPcRandomSecret -Length 20) + 'Aa9!') -AsPlainText -Force
            $newUser = New-LocalUser -Name $userName -Password $secure -AccountNeverExpires -ErrorAction Stop
            $userCreated = $true
            $script:LinkGuard.TempUser = $userName
            # Kept after cleanup so the Diagnostics stage can check the bundle does not leak it.
            $script:LinkGuard.TempUserName = $userName
            if ($newUser -and $newUser.SID) {
                $userSid = [string]$newUser.SID.Value
            }
            # Users: BUILTIN\Users may create folders in %ProgramData%, and a junction is one.
            # Performance Log Users: on a server it holds 'Log on as a batch job', which the S4U logon
            # needs; Microsoft's pages disagree for a client, so the right's holders are recorded below.
            # Neither is an administrator group.
            $groupProblems = @(@((Add-RealPcUserToGroup -GroupSid 'S-1-5-32-545' -UserName $userName), (Add-RealPcUserToGroup -GroupSid 'S-1-5-32-559' -UserName $userName)) | Where-Object { $_ })
            $detail = 'random name and password (neither shown); a member of Users and Performance Log Users, not of Administrators'
            if ($groupProblems.Count -gt 0) {
                $detail += '; ' + ($groupProblems -join '; ')
            }
            $rows += New-TestPlanRow -Check 'Created a temporary standard user' -Result 'PASS' -Detail $detail
        }
        catch {
            $userProblem = ([string]$_.Exception.Message -replace '\s*[\r\n]+\s*', ' ').Trim()
            $rows += New-TestPlanRow -Check 'Created a temporary standard user' -Result 'SKIP' -Detail "could not create it ($userProblem); planting the junction as the admin instead"
        }

        # Plant the junction as the temporary standard user, from a one-shot task with an S4U logon:
        # it runs without the user signing in, and Task Scheduler stores no password. An administrator
        # registers such a task for another account only with that account's password, which
        # Register-RealPcPlantTask gives through the COM API. A junction needs no network or
        # encrypted-file access, which S4U does not give.
        if ($userCreated) {
            try {
                $taskStep = 'Register'
                try {
                    Register-RealPcPlantTask -TaskName $script:PlantTaskName -UserId "$env:COMPUTERNAME\$userName" -Password $secure -Execute (Get-RealPcSystem32Path -ChildPath 'cmd.exe') -Argument ('/c mklink /J "{0}" "{1}"' -f $baseFolder, $publicRoot)
                }
                finally {
                    # The password's last use.
                    $secure.Dispose()
                    $secure = $null
                }
                $taskStep = 'Start'
                $taskStartedAt = Get-Date
                Start-ScheduledTask -TaskName $script:PlantTaskName -ErrorAction Stop
                $taskStep = 'Wait'
                $taskResult = Wait-RealPcScheduledTask -TaskName $script:PlantTaskName -StartedAt $taskStartedAt -TimeoutSeconds 90
                $taskStep = ''
            }
            catch {
                $taskProblem = ConvertTo-RealPcTaskProblem -ErrorRecord $_
            }
            finally {
                Unregister-ScheduledTask -TaskName $script:PlantTaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
            $junctionAfterTask = (Test-RealPcReparsePoint -Path $baseFolder) -eq $true

            # Read-only evidence for the S4U logon: who holds, or is denied, the batch-logon right
            # (a task that ends with 0x80070569 lacked it). The temporary user's name and SID are hidden.
            $rights = @(Read-RealPcBatchLogonRight -HideName @($userName, $userSid))
            if ($null -ne $script:MachineFacts) {
                $script:MachineFacts['Log on as a batch job (secedit)'] = ($rights -join '; ')
            }
            if ($EvidenceFolder) {
                try {
                    [System.IO.File]::WriteAllText((Join-Path $EvidenceFolder 'batch-logon-rights.txt'), (($rights -join [Environment]::NewLine) + [Environment]::NewLine))
                }
                catch {
                }
            }
        }
    }
    finally {
        if ($null -ne $secure) {
            $secure.Dispose()
        }
        $secure = $null
    }
    $plant = Get-RealPcJunctionPlantResult -UserCreated $userCreated -UserProblem $userProblem -TaskStep $taskStep -TaskProblem $taskProblem -TaskResult $taskResult -JunctionAfterTask $junctionAfterTask
    if ($plant.PlantedBy -ne 'StandardUser' -and (Test-RealPcReparsePoint -Path $baseFolder) -ne $true) {
        New-RealPcAdminJunction -Path $baseFolder -Target $publicRoot
    }
    $script:LinkGuard.PlantedBy = $plant.PlantedBy
    $script:LinkGuard.PlantNote = $plant.Note
    $planted = (Test-RealPcReparsePoint -Path $baseFolder) -eq $true
    $script:LinkGuard.Planted = $planted
    if (-not $planted) {
        $rows += New-TestPlanRow -Check 'Planted the junction at the ProgramData folder' -Result 'FAIL' -Detail ('the junction could not be created; ' + $plant.Note)
        return $rows
    }
    $rows += New-TestPlanRow -Check 'Planted the junction at the ProgramData folder' -Result 'PASS' -Detail ("$baseFolder -> $publicRoot; " + $plant.Note)
    return $rows
}

# Stage 2 FirstRun: items 1 + 4 + 5, whether the installer saw the cross-user elevation and
# registered winget's source package itself, then the item-11 verification and cleanup.
function Invoke-RealPcFirstRunStage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$EvidenceFolder
    )

    $rows = @()
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    # Before the run, as the installer decides it: its Windows Terminal step changes what the
    # Terminal condition reads (Install.ps1).
    $expectationRead = Get-RealPcAppExpectation
    # Under cross-user elevation the installer installs machine-wide only, as SYSTEM does.
    $expectations = $expectationRead.Value
    if ((Get-RealPcCrossUserAnswer -CrossUser $script:CrossUserElevation) -eq 'yes' -and $null -ne $expectations) {
        $expectations = @(ConvertTo-RealPcMachineWideExpectation -AppExpectation $expectations)
    }
    $preflightCheck = @(@($script:WingetSourceChecks) | Where-Object { $null -ne $_ -and -not $_.When }) | Select-Object -First 1
    $startedAt = Get-Date
    $run = Invoke-RealPcInstaller -ConsoleLogPath (Join-Path $EvidenceFolder 'console.txt') -Environment @{
        WINGET_APP_SETUP_NONINTERACTIVE      = '1'
        WINGET_APP_SETUP_TIGHTVNC_PASSWORD   = $script:TightVncPassword
        WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = [string]$script:StageTimeoutMinutes
    }
    $exitCode = $run.ExitCode
    $transcript = Get-InstallPassTranscript -LogDirectory $logDirectory -Since $startedAt
    $recordRead = Read-RealPcRunRecord -Path (Join-Path $logDirectory 'last-run.json') -Since $startedAt
    $record = $recordRead.Record
    $transcriptText = Get-RealPcTranscriptText -LogDirectory $logDirectory -Since $startedAt
    $consoleText = @($run.Output) -join [Environment]::NewLine
    $script:FirstRunDone = $true
    # The later runs' expectations follow what this run left installed (Set-RealPcFirstRunExpectation).
    $script:FirstRunRecord = $record

    $runText = $consoleText + [Environment]::NewLine + $transcriptText
    # The one-liner's build is known only from what the run printed.
    if ($script:RealPcOptions -and $script:RealPcOptions.UseOneLiner -and $null -ne $script:MachineFacts) {
        $runBuildId = ''
        if ($transcript -and $transcript.Parsed) {
            $runBuildId = [string]$transcript.Parsed.BuildId
        }
        if (-not $runBuildId) {
            $runBuildId = Get-RealPcRunBuildId -Text $runText
        }
        $script:MachineFacts['Installer build'] = Get-RealPcInstallerBuildFact -UseOneLiner -Branch ([string]$script:RealPcOptions.Branch) -RunBuildId $runBuildId
    }

    # Items 1 + 4 + 5: exit code, run record, cross-user detection, each app, auto-updates, runtime,
    # WAU, TightVNC.
    $verdict = Get-RealPcInstallExitVerdict -ExitCode $exitCode -Transcript $transcript -Pass 'first'
    $rows += New-TestPlanBoolRow -Check 'First run exit code acceptable (0, 3010 or 8 with reason)' -Passed $verdict.Passed -Detail $verdict.Message
    $rows += Get-RealPcRunRecordResult -RunRecord $record -RunRecordProblem $recordRead.Problem -ExpectedExitCode $exitCode
    $rows += Get-RealPcCrossUserDetectionRow -CrossUser $script:CrossUserElevation -Text $runText
    $rows += Get-RealPcAppResult -RunRecord $record -AppExpectation $expectations -AppExpectationProblem $expectationRead.Problem

    $wauHealth = Get-RealPcWauTaskHealth
    $runtimePresent = $null
    $runtimeProblem = ''
    $runtimeRead = Invoke-RealPcModuleJson -Body '$result = Get-WindowsAppRuntimeStatus'
    if ($runtimeRead.Ok -and $null -ne $runtimeRead.Value -and $null -ne $runtimeRead.Value.Present) {
        $runtimePresent = [bool]$runtimeRead.Value.Present
    }
    elseif ($runtimeRead.Ok -and $null -ne $runtimeRead.Value) {
        $runtimeProblem = [string]$runtimeRead.Value.Detail
    }
    else {
        $runtimeProblem = [string]$runtimeRead.Problem
    }
    $rows += Get-RealPcAutoUpdateResult -Transcript $transcript -RunRecord $record -WauTaskHealth $wauHealth -WindowsAppRuntimePresent $runtimePresent -WindowsAppRuntimeProblem $runtimeProblem -ExpectTightVncConfigured

    # The source check again: the run may have registered winget's source here, or lost it.
    $sourceCheck = Invoke-RealPcWingetSourceCheck
    $sourcePackage = Get-RealPcWingetSourcePackage
    $rows += Add-RealPcWingetSourceCheck -ExitCode $sourceCheck.ExitCode -When 'after the first run' -SourcePackage $sourcePackage
    $afterCheck = @($script:WingetSourceChecks)[-1]
    $rows += Get-RealPcSourceRepairRow -PreflightCheck $preflightCheck -AfterCheck $afterCheck -Text $runText
    $sections = [ordered]@{}
    $sections[('winget search --id Microsoft.PowerShell --exact --source winget (the source check after the first run; exit {0}; Microsoft.Winget.Source for this account: {1})' -f (Format-RealPcWingetExitCode -ExitCode $sourceCheck.ExitCode), $sourcePackage)] = @($sourceCheck.Output)
    Save-RealPcText -Path (Join-Path $EvidenceFolder 'winget-source-check.txt') -Text (Format-RealPcEvidenceText -Section $sections)

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
        $rows += Get-RealPcLinkGuardResult -BaseIsReparsePoint $baseIsLink -BaseAcl $baseAcl -LogsAcl $logsAcl -ConsoleText $consoleText -TranscriptText $transcriptText -VictimBefore $script:LinkGuard.VictimBefore -VictimAfter $victimAfter -PlantedBy $script:LinkGuard.PlantedBy -PlantNote $script:LinkGuard.PlantNote
    }
    $rows += @(Remove-RealPcLinkGuardArtifact)
    return $rows
}

<#
.SYNOPSIS
    Removes the link-guard stage's temporary user (and its profile) and victim folder, and says
    whether each is gone.
.RETURNS
    Rows (New-TestPlanRow); none when there was nothing to remove.
#>
function Remove-RealPcLinkGuardArtifact {
    $rows = @()
    $userName = $script:LinkGuard.TempUser
    if ($userName) {
        $user = $null
        try {
            $user = Get-LocalUser -Name $userName -ErrorAction Stop
        }
        catch {
        }
        $removeProblem = ''
        if ($user) {
            # The profile first (it is found by the account's SID); its task's logon may still be
            # unloading it, so try for half a minute.
            $sid = [string]$user.SID.Value
            $profileFound = $false
            $profileProblem = ''
            for ($attempt = 1; $attempt -le 6; $attempt++) {
                try {
                    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID = '$sid'" -ErrorAction Stop)
                    if ($profiles.Count -gt 0) {
                        $profileFound = $true
                        $profiles | Remove-CimInstance -ErrorAction Stop
                    }
                    $profileProblem = ''
                    break
                }
                catch {
                    $profileProblem = $_.Exception.Message
                    Start-Sleep -Seconds 5
                }
            }
            if ($profileProblem) {
                $rows += New-TestPlanRow -Check 'Removed the temporary user''s profile' -Result 'SKIP' -Detail "could not remove it ($profileProblem); remove it in System Properties > Advanced > User Profiles"
            }
            elseif ($profileFound) {
                $rows += New-TestPlanRow -Check 'Removed the temporary user''s profile' -Result 'PASS' -Detail 'removed'
            }
            try {
                Remove-LocalUser -Name $userName -ErrorAction Stop
            }
            catch {
                $removeProblem = $_.Exception.Message
            }
        }
        $left = $null
        try {
            $left = Get-LocalUser -Name $userName -ErrorAction Stop
        }
        catch {
        }
        if ($left) {
            $rows += New-TestPlanRow -Check 'Removed the temporary user' -Result 'FAIL' -Detail "it still exists ($removeProblem): remove the local user whose name starts with 'wgt' with Remove-LocalUser"
        }
        else {
            $rows += New-TestPlanRow -Check 'Removed the temporary user' -Result 'PASS' -Detail 'the account is gone'
        }
        $script:LinkGuard.TempUser = $null
    }
    $victim = $script:LinkGuard.VictimFolder
    if ($victim) {
        $victimProblem = ''
        if (Test-Path -LiteralPath $victim) {
            try {
                Remove-Item -LiteralPath $victim -Recurse -Force -ErrorAction Stop
            }
            catch {
                $victimProblem = $_.Exception.Message
            }
        }
        if (Test-Path -LiteralPath $victim) {
            $rows += New-TestPlanRow -Check 'Removed the victim folder' -Result 'FAIL' -Detail "$victim is still there ($victimProblem)"
        }
        else {
            $rows += New-TestPlanRow -Check 'Removed the victim folder' -Result 'PASS' -Detail $victim
        }
        $script:LinkGuard.VictimFolder = $null
    }
    return $rows
}

<#
.SYNOPSIS
    The cleanup that always runs (in main's finally): the one-shot tasks, a junction the harness
    planted that no run removed, and the link-guard stage's user and victim folder.
.RETURNS
    Rows (New-TestPlanRow) for what was left and removed, or could not be.
#>
function Remove-RealPcHarnessLeftover {
    $ErrorActionPreference = 'Continue'
    $rows = @()
    foreach ($taskName in @($script:PlantTaskName, $script:SystemTaskName)) {
        $task = $null
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }
        catch {
        }
        if (-not $task) {
            continue
        }
        try {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        }
        catch {
        }
        $still = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $rows += New-TestPlanBoolRow -Check "Removed the leftover scheduled task $taskName" -Passed (-not $still) -Detail $(if ($still) { 'still registered: remove it in Task Scheduler' } else { 'removed' })
    }
    if ($script:LinkGuard -and $script:LinkGuard.Planted) {
        $baseFolder = Join-Path $env:ProgramData 'winget-app-setup'
        if ((Test-RealPcReparsePoint -Path $baseFolder) -eq $true) {
            # rmdir without /s removes the junction itself, never what it points to.
            $null = & cmd.exe /c rmdir $baseFolder 2>&1
            $stillLink = (Test-RealPcReparsePoint -Path $baseFolder) -eq $true
            $rows += New-TestPlanBoolRow -Check 'Removed the junction the harness planted' -Passed (-not $stillLink) -Detail $(if ($stillLink) { "$baseFolder is still a junction: remove it with rmdir (no /s)" } else { "no installer run removed it, so the harness did: $baseFolder" })
        }
    }
    if ($script:LinkGuard) {
        $rows += @(Remove-RealPcLinkGuardArtifact)
    }
    return $rows
}

# Stage 3 ReRun (item 2): run the installer again; everything already present.
function Invoke-RealPcReRunStage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$EvidenceFolder
    )

    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    # What the first run left installed must be found; what it did not may be installed now, or,
    # machine-wide only (cross-user elevation), deferred again.
    $expectationRead = Get-RealPcAppExpectation -AlreadyPresent
    $baseExpectation = $expectationRead.Value
    if ((Get-RealPcCrossUserAnswer -CrossUser $script:CrossUserElevation) -eq 'yes' -and $null -ne $baseExpectation) {
        $baseExpectation = @(ConvertTo-RealPcMachineWideExpectation -AppExpectation $baseExpectation)
    }
    $adjusted = Set-RealPcFirstRunExpectation -AppExpectation $baseExpectation -FirstRunRecord $script:FirstRunRecord
    $expectations = $expectationRead.Value
    if ($null -ne $expectationRead.Value) {
        $expectations = @($adjusted.Value)
    }
    $startedAt = Get-Date
    $run = Invoke-RealPcInstaller -ConsoleLogPath (Join-Path $EvidenceFolder 'console.txt') -Environment @{
        WINGET_APP_SETUP_NONINTERACTIVE      = '1'
        WINGET_APP_SETUP_TIGHTVNC_PASSWORD   = $script:TightVncPassword
        WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = [string]$script:StageTimeoutMinutes
    }
    $transcript = Get-InstallPassTranscript -LogDirectory $logDirectory -Since $startedAt
    $recordRead = Read-RealPcRunRecord -Path (Join-Path $logDirectory 'last-run.json') -Since $startedAt
    $rows = @()
    $rows += Get-RealPcRunRecordResult -RunRecord $recordRead.Record -RunRecordProblem $recordRead.Problem -ExpectedExitCode $run.ExitCode
    $rows += Get-RealPcReRunResult -ExitCode $run.ExitCode -Transcript $transcript -RunRecord $recordRead.Record -RunRecordProblem $recordRead.Problem -AppExpectation $expectations -AppExpectationProblem $expectationRead.Problem
    $rows += @(Get-RealPcFirstRunGapRow -Changed $adjusted.Changed -Run 'The re-run')
    return $rows
}

# Stage 4 System (item 3) and stage 5 WinGetClient (item 10): the SYSTEM pass through the RMM wrapper.
function Invoke-RealPcSystemStage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$EvidenceFolder,

        [Parameter(Mandatory = $false)]
        [string]$SystemEngine
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $wrapper = Join-Path $repoRoot 'rmm\Invoke-WingetAppSetup.ps1'
    $installer = Join-Path $repoRoot 'winget-app-install.ps1'
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $sha = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    $powerShell32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    # Decided before the run: what the first run left installed must be found already there; what
    # it did not may be installed now or found (Set-RealPcFirstRunExpectation).
    $expectationRead = Get-RealPcAppExpectation -System -AlreadyPresent
    $adjusted = Set-RealPcFirstRunExpectation -AppExpectation $expectationRead.Value -FirstRunRecord $script:FirstRunRecord
    $expectations = $expectationRead.Value
    if ($null -ne $expectationRead.Value) {
        $expectations = @($adjusted.Value)
    }
    $taskArgument = Get-SystemPassTaskArgument -WrapperPath $wrapper -InstallerPath $installer -InstallerSha256 $sha -SystemInstallEngine $SystemEngine
    $taskRun = Invoke-SystemPassTask -PowerShellPath $powerShell32 -TaskArgument $taskArgument -TimeoutMinutes $script:StageTimeoutMinutes -LogFolder $logDirectory

    if ($taskRun.StartError) {
        return @(New-TestPlanRow -Check 'SYSTEM task started' -Result 'FAIL' -Detail $taskRun.StartError)
    }
    $record = $taskRun.RunRecordRead.Record
    $recordProblem = $taskRun.RunRecordRead.Problem
    if ($null -ne $record) {
        $fresh = Test-RealPcRunRecordFresh -RunRecord $record -Since $taskRun.StartedAt
        if (-not $fresh.Fresh) {
            $record = $null
            $recordProblem = $fresh.Detail
        }
    }
    $check = Get-SystemInstallPassResult -TaskExitCode $taskRun.TaskExitCode -Transcript $taskRun.Transcript -WrapperLog $taskRun.WrapperLog -RunRecord $record -RunRecordProblem $recordProblem -NewSystemProfileEntries $taskRun.NewSystemProfileEntries -AppExpectation $expectations -AppExpectationProblem $expectationRead.Problem -SecondPass
    $rows = @($check.Results | ForEach-Object { New-TestPlanRow -Check $_.Assertion -Result $_.Result -Detail $_.Detail })
    $rows = @(Update-RealPcSystemRedeferredRow -Row $rows -RunRecord $record -FirstRunRecord $script:FirstRunRecord)
    $rows += @(Get-RealPcFirstRunGapRow -Changed $adjusted.Changed -Run 'The SYSTEM run')

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
        if ($record -and $record.PSObject.Properties['installEngine']) {
            $recordEngine = $record.installEngine
        }
        $rows += New-TestPlanBoolRow -Check 'last-run.json records the install engine' -Passed ($null -ne $recordEngine) -Detail $(if ($recordEngine) { "requested $($recordEngine.requested), used $($recordEngine.used)" } else { 'no installEngine in last-run.json for this run' })
    }
    return $rows
}

# Stage 6 TimeBudget (item 8): uninstall 7-Zip (its output kept in winget-uninstall.txt), run with a
# spent budget (exit 9), then finish.
function Invoke-RealPcTimeBudgetStage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$EvidenceFolder
    )

    $ErrorActionPreference = 'Continue'
    $rows = @()
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $appId = '7zip.7zip'

    $uninstall = Invoke-RealPcWingetUninstall -Id $appId
    $uninstallSection = [ordered]@{}
    $uninstallSection[('winget uninstall --id {0} --exact --source winget --silent (exit {1})' -f $appId, (Format-RealPcWingetExitCode -ExitCode $uninstall.ExitCode))] = @($uninstall.Output)
    Save-RealPcText -Path (Join-Path $EvidenceFolder 'winget-uninstall.txt') -Text (Format-RealPcEvidenceText -Section $uninstallSection)
    $rows += Get-RealPcUninstallCheckRow -AppId $appId -Present (Test-RealPcWingetInstalled -Id $appId) -UninstallExitCode $uninstall.ExitCode -UninstallProblem $uninstall.Problem -SourceOpen $script:WingetSourceOpen
    Save-RealPcArpSnapshot -Path (Join-Path $EvidenceFolder 'arp-after-uninstall.txt') -Title "after 'winget uninstall --id $appId'"

    # A deterministic spent budget: -MaxRuntimeMinutes 1 and a deadline already in the past, in the
    # form Format-RunRecordTime writes and Resolve-InstallerRunBudget reads.
    $pastDeadline = ([DateTime]::UtcNow.AddMinutes(-5)).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $startedAt = Get-Date
    $spent = Invoke-RealPcInstaller -ExtraArgument @('-MaxRuntimeMinutes', '1', '-RunDeadlineUtc', $pastDeadline) -Environment @{ WINGET_APP_SETUP_NONINTERACTIVE = '1' } -ConsoleLogPath (Join-Path $EvidenceFolder 'console-spent-budget.txt')
    $recordRead = Read-RealPcRunRecord -Path (Join-Path $logDirectory 'last-run.json') -Since $startedAt
    $resultLine = Get-RealPcResultLineFromText -Text (@($spent.Output) -join "`n")
    if (-not $resultLine) {
        $resultLine = Get-RealPcResultLineFromText -Text (Get-RealPcTranscriptText -LogDirectory $logDirectory -Since $startedAt)
    }
    $rows += Get-RealPcTimeBudgetSpentResult -ExitCode $spent.ExitCode -RunRecord $recordRead.Record -RunRecordProblem $recordRead.Problem -ResultLine $resultLine -AppId $appId

    # Finish, with only the stage's own limit as the budget.
    $startedAt = Get-Date
    $finish = Invoke-RealPcInstaller -Environment @{ WINGET_APP_SETUP_NONINTERACTIVE = '1'; WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = [string]$script:StageTimeoutMinutes } -ConsoleLogPath (Join-Path $EvidenceFolder 'console-finish.txt')
    $finishRead = Read-RealPcRunRecord -Path (Join-Path $logDirectory 'last-run.json') -Since $startedAt
    $rows += Get-RealPcTimeBudgetFinishResult -ExitCode $finish.ExitCode -RunRecord $finishRead.Record -RunRecordProblem $finishRead.Problem -AppId $appId
    return $rows
}

# Stage 7 Diagnostics (item 6): the -CollectDiagnostics bundle and the secret-leak check.
function Invoke-RealPcDiagnosticsStage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$EvidenceFolder
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $installer = Join-Path $repoRoot 'winget-app-install.ps1'
    $powerShell = Get-RealPcWindowsPowerShellPath
    $run = Invoke-RealPcProcess -FilePath $powerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-CollectDiagnostics', '-NonInteractive') -ConsoleLogPath (Join-Path $EvidenceFolder 'console.txt')
    $rows = @()
    if ($null -eq $run.ExitCode) {
        $rows += New-TestPlanRow -Check 'Diagnostics run exits 0' -Result 'FAIL' -Detail (Get-RealPcNoExitCodeDetail)
    }
    else {
        $rows += New-TestPlanBoolRow -Check 'Diagnostics run exits 0' -Passed ([int]$run.ExitCode -eq 0) -Detail "exit $($run.ExitCode)"
    }
    $zipPath = $null
    if ((@($run.Output) -join "`n") -match 'Diagnostics bundle saved:\s*([^\r\n]+\.zip)') {
        $zipPath = $Matches[1].Trim()
    }
    if (-not $zipPath -or -not (Test-Path -LiteralPath $zipPath)) {
        $rows += New-TestPlanRow -Check 'Diagnostics bundle created' -Result 'FAIL' -Detail 'no bundle path in the output, or the file is missing'
        return $rows
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
        $rows += New-TestPlanRow -Check 'Diagnostics bundle readable' -Result 'FAIL' -Detail $_.Exception.Message
        return $rows
    }
    $secrets = Get-RealPcSecretSet -TightVncPassword $script:TightVncPassword -TempUserName ([string]$script:LinkGuard.TempUserName)
    $rows += New-TestPlanRow -Check 'Diagnostics bundle created' -Result 'PASS' -Detail $zipPath
    $rows += Get-RealPcDiagnosticsResult -EntryName $entryName -EntryText $entryText -Secret $secrets
    Copy-Item -LiteralPath $zipPath -Destination $EvidenceFolder -ErrorAction SilentlyContinue
    return $rows
}

# Stage 8 Uninstaller (item 9): -WhatIf preview, then a real elevated uninstall.
function Invoke-RealPcUninstallerStage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$EvidenceFolder
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $uninstaller = Join-Path $repoRoot 'winget-app-uninstall.ps1'
    $powerShell = Get-RealPcWindowsPowerShellPath
    $catalogId = @($script:CatalogId)
    if ($catalogId.Count -eq 0) {
        $catalogId = @(Get-RealPcCatalogId)
    }
    if ($catalogId.Count -eq 0) {
        return @(New-TestPlanRow -Check 'Catalog read for the uninstaller checks' -Result 'FAIL' -Detail 'could not read the catalog from the checkout''s module, so nothing could be checked')
    }

    # The source as the uninstaller finds it: an installer run since the last check may have
    # repaired it, and the blind rows judge the uninstaller's refusal by this state.
    $sourceCheck = Invoke-RealPcWingetSourceCheck
    $sourcePackage = Get-RealPcWingetSourcePackage
    $sourceRow = Add-RealPcWingetSourceCheck -ExitCode $sourceCheck.ExitCode -When 'before the uninstaller' -SourcePackage $sourcePackage
    $sourceOpenBefore = $script:WingetSourceOpen
    $sections = [ordered]@{}
    $sections[('winget search --id Microsoft.PowerShell --exact --source winget (the source check before the uninstaller; exit {0}; Microsoft.Winget.Source for this account: {1})' -f (Format-RealPcWingetExitCode -ExitCode $sourceCheck.ExitCode), $sourcePackage)] = @($sourceCheck.Output)
    Save-RealPcText -Path (Join-Path $EvidenceFolder 'winget-source-check.txt') -Text (Format-RealPcEvidenceText -Section $sections)

    $before = Get-RealPcInstalledCatalogId -CatalogId $catalogId
    $beforeWau = (Get-RealPcWauTaskHealth).Exists
    # -NonInteractive: the preview must not wait for a key press at its end.
    $preview = Invoke-RealPcProcess -FilePath $powerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstaller, '-WhatIf', '-NonInteractive') -ConsoleLogPath (Join-Path $EvidenceFolder 'console-whatif.txt')
    $after = Get-RealPcInstalledCatalogId -CatalogId $catalogId
    $afterWau = (Get-RealPcWauTaskHealth).Exists

    $real = Invoke-RealPcProcess -FilePath $powerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstaller, '-NonInteractive') -ConsoleLogPath (Join-Path $EvidenceFolder 'console-uninstall.txt')
    $afterReal = Get-RealPcInstalledCatalogId -CatalogId $catalogId
    $wauAfterReal = (Get-RealPcWauTaskHealth).Exists
    $unknown = @(@($before.Unknown) + @($after.Unknown) + @($afterReal.Unknown) | Where-Object { $_ })

    # What the uninstaller kept on purpose comes from its console only (Get-RealPcKeptSkip): it runs
    # in Windows PowerShell here, so it must remove PowerShell 7.
    $uninstallText = @($real.Output) -join "`n"
    # The uninstaller opened the source although the check before it could not: check again, so the
    # report's banner and Preflight's row read the source as it is after the uninstaller.
    $afterRows = @()
    if ($sourceOpenBefore -eq $false -and $uninstallText -match 'The winget source opens for') {
        $afterSource = Invoke-RealPcWingetSourceCheck
        $afterPackage = Get-RealPcWingetSourcePackage
        $afterRows = @(Add-RealPcWingetSourceCheck -ExitCode $afterSource.ExitCode -When 'after the uninstaller' -SourcePackage $afterPackage)
        $sections[('winget search --id Microsoft.PowerShell --exact --source winget (the source check after the uninstaller; exit {0}; Microsoft.Winget.Source for this account: {1})' -f (Format-RealPcWingetExitCode -ExitCode $afterSource.ExitCode), $afterPackage)] = @($afterSource.Output)
        Save-RealPcText -Path (Join-Path $EvidenceFolder 'winget-source-check.txt') -Text (Format-RealPcEvidenceText -Section $sections)
    }
    return (@($sourceRow) + @(Get-RealPcUninstallerResult -WhatIfInstalledBefore $before.Installed -WhatIfInstalledAfter $after.Installed -WhatIfWauBefore $beforeWau -WhatIfWauAfter $afterWau -ExitCode $real.ExitCode -InstalledAfter $afterReal.Installed -UnknownIds $unknown -UnknownAfterIds @($afterReal.Unknown | Where-Object { $_ }) -KeptIds @(Get-RealPcKeptSkip -Text $uninstallText) -WauPresentAfter $wauAfterReal -SourceOpen $sourceOpenBefore -WhatIfConsoleText (@($preview.Output) -join "`n") -UninstallConsoleText $uninstallText) + $afterRows)
}

<#
.SYNOPSIS
    The harness entry point: the safety gate, the stages in order, the cleanup, the report and the
    exit code. Returns the exit code (the guarded block at the end of the file exits with it), so
    tests can call it.
.PARAMETER Stage
    See the script's -Stage.
.PARAMETER SkipStage
    See the script's -SkipStage.
.PARAMETER TimeoutMinutes
    See the script's -TimeoutMinutes.
.PARAMETER ReportPath
    See the script's -ReportPath.
.PARAMETER UseOneLiner
    See the script's -UseOneLiner.
.PARAMETER Branch
    See the script's -Branch.
.PARAMETER IncludeWinGetClient
    See the script's -IncludeWinGetClient.
.PARAMETER ResetProgramData
    See the script's -ResetProgramData.
.PARAMETER ConfirmDisposableMachine
    See the script's -ConfirmDisposableMachine.
.PARAMETER WhatIf
    See the script's -WhatIf.
.PARAMETER Plan
    See the script's -Plan.
.RETURNS
    [int] 0, 1 or 2 (see the script's .NOTES).
#>
function Invoke-RealPcTestPlanMain {
    param (
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Stage = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SkipStage = @(),

        [int]$TimeoutMinutes = 60,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ReportPath,

        [switch]$UseOneLiner,

        [string]$Branch = 'claude/trusting-dirac-foyiaa',

        [switch]$IncludeWinGetClient,

        [switch]$ResetProgramData,

        [switch]$ConfirmDisposableMachine,

        [switch]$WhatIf,

        [switch]$Plan
    )

    # Native stderr must not stop the run: a step shell's $ErrorActionPreference = 'Stop' would turn
    # a child's first stderr line into a terminating error under Windows PowerShell.
    $ErrorActionPreference = 'Continue'
    $script:RealPcOptions = [pscustomobject]@{ UseOneLiner = [bool]$UseOneLiner; Branch = $Branch; ResetProgramData = [bool]$ResetProgramData }
    $script:StageTimeoutMinutes = $TimeoutMinutes
    $script:MachineFacts = [ordered]@{}
    $script:LinkGuard = [pscustomobject]@{ VictimFolder = $null; VictimBefore = @(); TempUser = $null; TempUserName = $null; PlantedBy = 'Admin'; PlantNote = ''; Planted = $false }
    $script:CatalogId = @()
    # 8 characters: TightVNC uses only the first 8, so this is the whole password that works.
    $script:TightVncPassword = New-RealPcRandomSecret -Length 8
    $script:DiagnosticsZipPath = $null
    $script:FirstRunDone = $false
    $script:FirstRunRecord = $null
    $script:WingetSourceChecks = @()
    $script:WingetSourceOpen = $null
    $script:ElevatedAccount = ''
    $script:CrossUserElevation = ''

    $planOnly = [bool]$WhatIf -or [bool]$Plan
    if (-not $ReportPath) {
        $publicRoot = $env:PUBLIC
        if (-not $publicRoot) {
            $publicRoot = [System.IO.Path]::GetTempPath()
        }
        $ReportPath = Join-Path $publicRoot ('winget-app-setup-testplan-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }
    $ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath).TrimEnd('\', '/')
    $script:ReportFolder = $ReportPath
    $script:LocalFolder = Get-RealPcLocalFolderPath -ReportPath $ReportPath

    $resolution = Resolve-RealPcTestPlanStage -Requested $Stage -Skip $SkipStage -IncludeOptional @($(if ($IncludeWinGetClient) { 'WinGetClient' }))
    if ($resolution.Errors.Count -gt 0) {
        foreach ($resolveError in $resolution.Errors) {
            Write-RealPcLine $resolveError 'Red'
        }
        return 2
    }
    foreach ($explanation in $resolution.Explanations) {
        Write-RealPcLine $explanation 'Yellow'
    }
    $stageNames = @($resolution.Stages | ForEach-Object { $_.Name })

    $reportProblem = Get-RealPcReportPathProblem -Path $script:ReportFolder -State (Get-RealPcReportPathState -Path $script:ReportFolder)
    if ($reportProblem) {
        Write-RealPcLine "Refused: $reportProblem" 'Red'
        return 2
    }

    $publicRootName = $env:PUBLIC
    if (-not $publicRootName) {
        $publicRootName = '%PUBLIC%'
    }
    $publicVictim = $publicRootName.TrimEnd('\') + '\winget-app-setup-victim-<timestamp>'
    foreach ($line in (Get-RealPcChangePlan -Stages $resolution.Stages -ReportFolder $script:ReportFolder -PublicVictimFolder $publicVictim -ResetProgramData:$ResetProgramData -LocalFolder $script:LocalFolder)) {
        Write-RealPcLine $line 'Cyan'
    }
    Write-RealPcLine ('Stages: ' + ($stageNames -join ' -> ')) 'Cyan'

    if ($planOnly) {
        $gate = Get-RealPcGateDecision -PlanOnly
        Write-RealPcLine ''
        Write-RealPcLine ("-WhatIf / -Plan: {0}" -f $gate.Reason) 'Green'
        return $gate.ExitCode
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
        return $gate.ExitCode
    }
    if (Test-RealPcWindowsSandbox) {
        Write-RealPcLine 'This is Windows Sandbox (WDAGUtilityAccount): winget is often missing there, and the install stages need it.' 'Yellow'
    }

    try {
        [void](New-Item -ItemType Directory -Path $script:ReportFolder -Force -ErrorAction Stop)
        [void](New-Item -ItemType Directory -Path $script:LocalFolder -Force -ErrorAction Stop)
    }
    catch {
        Write-RealPcLine "Refused: could not create the report folders: $($_.Exception.Message)" 'Red'
        return 2
    }
    $evidenceRoot = Join-Path $script:ReportFolder 'evidence'
    [void](New-Item -ItemType Directory -Path $evidenceRoot -Force -ErrorAction SilentlyContinue)
    $transcriptPath = Join-Path $script:ReportFolder 'harness-transcript.log'
    try {
        [void](Start-Transcript -Path $transcriptPath -ErrorAction Stop)
    }
    catch {
        Write-RealPcLine "Could not start the harness transcript: $($_.Exception.Message)" 'Yellow'
    }

    # Every child the harness starts runs non-interactively: nothing may wait for a key press.
    $savedNonInteractive = [Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_NONINTERACTIVE')
    [Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_NONINTERACTIVE', '1')
    $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    $stageResults = @()
    $leftoverRows = @()
    $toRun = @($resolution.Stages | Where-Object { $_.Name -ne 'Report' })
    try {
        foreach ($stageEntry in $toRun) {
            Write-RealPcLine ''
            Write-RealPcLine ("=== Stage {0} {1} (item {2}): {3} ===" -f $stageEntry.Number, $stageEntry.Name, $stageEntry.Item, $stageEntry.Summary) 'Cyan'
            $stageEvidence = Join-Path $evidenceRoot ('{0}-{1}' -f $stageEntry.Number, $stageEntry.Name)
            [void](New-Item -ItemType Directory -Path $stageEvidence -Force -ErrorAction SilentlyContinue)
            # Apps & features before Preflight and after each install or uninstall stage (evidence only).
            $arpMoment = Get-RealPcArpSnapshotMoment -StageName $stageEntry.Name
            if ($arpMoment -eq 'Before') {
                Save-RealPcArpSnapshot -Path (Join-Path $stageEvidence 'arp.txt') -Title ('before stage {0} {1}' -f $stageEntry.Number, $stageEntry.Name)
            }
            $stageStartedAt = Get-Date
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $rows = @()
            try {
                switch ($stageEntry.Name) {
                    'Preflight' { $rows = @(Invoke-RealPcPreflightStage -EvidenceFolder $stageEvidence) }
                    'LinkGuardSetup' { $rows = @(Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $stageEvidence) }
                    'FirstRun' { $rows = @(Invoke-RealPcFirstRunStage -EvidenceFolder $stageEvidence) }
                    'ReRun' { $rows = @(Invoke-RealPcReRunStage -EvidenceFolder $stageEvidence) }
                    'System' { $rows = @(Invoke-RealPcSystemStage -EvidenceFolder $stageEvidence) }
                    'WinGetClient' { $rows = @(Invoke-RealPcSystemStage -EvidenceFolder $stageEvidence -SystemEngine 'WinGetClient') }
                    'TimeBudget' { $rows = @(Invoke-RealPcTimeBudgetStage -EvidenceFolder $stageEvidence) }
                    'Diagnostics' { $rows = @(Invoke-RealPcDiagnosticsStage -EvidenceFolder $stageEvidence) }
                    'Uninstaller' { $rows = @(Invoke-RealPcUninstallerStage -EvidenceFolder $stageEvidence) }
                    default { $rows = @() }
                }
            }
            catch {
                $rows = @($rows) + @(New-TestPlanRow -Check "Stage $($stageEntry.Name) ran" -Result 'FAIL' -Detail "the stage stopped on an error: $($_.Exception.Message)")
            }
            $stopwatch.Stop()
            Save-RealPcStageEvidence -Folder $stageEvidence -LogDirectory $logDirectory -Since $stageStartedAt
            if ($arpMoment -eq 'After') {
                Save-RealPcArpSnapshot -Path (Join-Path $stageEvidence 'arp.txt') -Title ('after stage {0} {1}' -f $stageEntry.Number, $stageEntry.Name)
            }
            $rows = @($rows | Where-Object { $null -ne $_ })
            $stageResults += [pscustomobject]@{ Name = $stageEntry.Name; Number = $stageEntry.Number; Item = $stageEntry.Item; DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds; Rows = $rows }
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
        # Always, Ctrl+C included: the one-shot tasks, a junction no run removed, the temporary
        # user and its profile, and the victim folder.
        $leftoverRows = @(Remove-RealPcHarnessLeftover)
        [Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_NONINTERACTIVE', $savedNonInteractive)
    }

    # Preflight's failed source check is SKIP once a later check opened the source: that was the PC
    # before the run.
    $ranStages = @($stageResults | ForEach-Object { [string]$_.Name })
    $stageResults = @(Update-RealPcPreflightSourceRow -StageResult $stageResults -SourceCheck $script:WingetSourceChecks)

    # Stage 9 Report: the cleanup rows, the manual steps (outside the zip), the evidence check for
    # the test password, the report, and the zip.
    $reportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $reportRows = @($leftoverRows)
    $manualStepsPath = Join-Path $script:LocalFolder 'manual-steps.txt'
    $manualSteps = Get-RealPcManualStepText -TightVncPassword $script:TightVncPassword -UninstallerRan:($stageNames -contains 'Uninstaller')
    try {
        [System.IO.File]::WriteAllText($manualStepsPath, ($manualSteps -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-RealPcLine "Could not write ${manualStepsPath}: $($_.Exception.Message)" 'Yellow'
    }

    try {
        [void](Stop-Transcript)
    }
    catch {
    }

    # Nothing that holds the test password goes into the zip: such a file is moved to the local
    # folder instead, and the row says which.
    $passwordOnly = Get-RealPcSecretSet -TightVncPassword $script:TightVncPassword
    $leaks = @(Get-RealPcFolderSecretLeak -Path $script:ReportFolder -Secret $passwordOnly)
    if ($leaks.Count -eq 0) {
        $reportRows += New-TestPlanRow -Check 'Report zip holds no TightVNC test password' -Result 'PASS' -Detail 'no file in the report folder holds it'
    }
    else {
        $withheld = Join-Path $script:LocalFolder 'withheld'
        [void](New-Item -ItemType Directory -Path $withheld -Force -ErrorAction SilentlyContinue)
        foreach ($file in @($leaks | ForEach-Object { $_.File } | Sort-Object -Unique)) {
            Move-Item -LiteralPath $file -Destination (Join-Path $withheld ((Split-Path -Leaf $file) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -Force -ErrorAction SilentlyContinue
        }
        $reportRows += New-TestPlanRow -Check 'Report zip holds no TightVNC test password' -Result 'FAIL' -Detail ('held by: {0}; moved out of the report folder to {1}' -f (@($leaks | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Label }) -join '; '), $withheld)
    }
    $reportStopwatch.Stop()
    $stageResults += [pscustomobject]@{ Name = 'Report'; Number = 9; Item = '-'; DurationSeconds = [int]$reportStopwatch.Elapsed.TotalSeconds; Rows = $reportRows }
    foreach ($row in $reportRows) {
        Write-RealPcLine ("  [{0}] {1}: {2}" -f $row.Result, $row.Check, $row.Detail) $(if ($row.Result -eq 'FAIL') { 'Red' } elseif ($row.Result -eq 'PASS') { 'Green' } else { 'Gray' })
    }

    $manual = Get-RealPcManualLeftover -LocalFolder $script:LocalFolder
    # The report starts with a warning when winget could not open its source in this account.
    $banner = @(Get-RealPcReportBanner -SourceCheck $script:WingetSourceChecks -Account $script:ElevatedAccount -CrossUser $script:CrossUserElevation -StageName $ranStages)
    $reportMd = Format-RealPcReport -MachineFacts $script:MachineFacts -StageResult $stageResults -ManualLeftovers $manual -Banner $banner -Markdown
    $reportTxt = Format-RealPcReport -MachineFacts $script:MachineFacts -StageResult $stageResults -ManualLeftovers $manual -Banner $banner
    $reportTextPath = Join-Path $script:ReportFolder 'report.txt'
    [System.IO.File]::WriteAllText((Join-Path $script:ReportFolder 'report.md'), $reportMd, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($reportTextPath, $reportTxt, (New-Object System.Text.UTF8Encoding($false)))

    $allRows = @($stageResults | ForEach-Object { $_.Rows })
    $exitCode = Get-RealPcExitCode -Rows $allRows

    # The reports were written after the folder scan, and the run offers report.txt for pasting:
    # check their text itself, so a zip that could not be made leaves nothing unchecked.
    $holdsSecret = $false
    $reportLeaks = @(Get-RealPcSecretLeak -Entry ([ordered]@{ 'report.txt' = $reportTxt; 'report.md' = $reportMd }) -Secret $passwordOnly)
    if ($reportLeaks.Count -gt 0) {
        $holdsSecret = $true
        $exitCode = 1
        Write-RealPcLine ('The report held the TightVNC test password ({0}). Do not paste or send it, or the report folder.' -f (@($reportLeaks | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Label }) -join '; ')) 'Red'
    }

    $zipPath = $script:ReportFolder + '.zip'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($script:ReportFolder, $zipPath)
    }
    catch {
        Write-RealPcLine "Could not create the report zip: $($_.Exception.Message)" 'Yellow'
        $zipPath = $null
    }
    # The zip itself, once more: a zip that holds the password is deleted, never sent.
    if ($zipPath) {
        $zipFolder = Join-Path $script:LocalFolder 'zip-check'
        [void](New-Item -ItemType Directory -Path $zipFolder -Force -ErrorAction SilentlyContinue)
        $zipCopy = Join-Path $zipFolder 'report.zip'
        Copy-Item -LiteralPath $zipPath -Destination $zipCopy -Force -ErrorAction SilentlyContinue
        $zipLeaks = @(Get-RealPcFolderSecretLeak -Path $zipFolder -Secret $passwordOnly)
        Remove-Item -LiteralPath $zipFolder -Recurse -Force -ErrorAction SilentlyContinue
        if ($zipLeaks.Count -gt 0) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            Write-RealPcLine ('The report zip held the TightVNC test password ({0}), so it was deleted. Do not send the report folder as it is.' -f (@($zipLeaks | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Label }) -join '; ')) 'Red'
            $zipPath = $null
            $exitCode = 1
            $holdsSecret = $true
        }
    }

    $overall = 'PASS'
    if ($exitCode -ne 0) {
        $overall = 'FAIL'
    }
    Write-RealPcLine ''
    foreach ($bannerLine in $banner) {
        Write-RealPcLine $bannerLine 'Yellow'
    }
    Write-RealPcLine ("Overall: {0}" -f $overall) $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
    Write-RealPcLine ("Report folder: {0}" -f $script:ReportFolder) 'Cyan'
    # Exact paths and a ready-to-paste copy command: a wildcard could pick the wrong folder.
    foreach ($line in (Get-RealPcFinishLine -ReportTextPath $reportTextPath -ZipPath $zipPath -ManualStepsPath $manualStepsPath -LocalFolder $script:LocalFolder -HoldsSecret:$holdsSecret)) {
        Write-RealPcLine $line 'Cyan'
    }
    return $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    $harnessExitCode = @(Invoke-RealPcTestPlanMain @script:HarnessArguments)
    exit ([int]$harnessExitCode[-1])
}
