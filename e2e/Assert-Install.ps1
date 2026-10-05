<#
.SYNOPSIS
    Shared post-install assertions for end-to-end runs of winget-app-install.ps1 (issue #214).
.DESCRIPTION
    Runs AFTER the installer has completed on a real machine (e2e tier 1: GitHub-hosted
    windows-latest runners via .github/workflows/e2e-install.yml; tier 2, issue #215, will reuse
    this script on a snapshot-rollback Proxmox VM). It verifies the observable outcomes the unit
    suite can only mock:

      1. Each catalog app's applicability (its 'arch' list and its 'condition' scriptblock, issue
         #217) is decided ON THIS MACHINE by the installer's own rule, the module's
         Test-AppApplicability, fail open included: a gate that cannot answer is warned about and
         the app is treated as applicable. Apps that do not apply (e.g.
         Dell.CommandUpdate.Universal on non-Dell hardware, or the 64-bit Reader on ARM64) are
         asserted differently below instead of being expected as installed. An app with neither
         an arch list nor a condition must apply whatever the module says: it stays expected
         installed, and the module finding it not applicable fails an assertion of its own.
      2. Every APPLICABLE app in Get-DefaultAppCatalog (minus -SkipApps) resolves via
         `winget list --exact --id <id>`, classified by $LASTEXITCODE captured immediately
         after the call (exit 0 = installed; nonzero = missing).
      3. The Winget-AutoUpdate scheduled task exists ('\WAU\Winget-AutoUpdate') - or, when
         Microsoft.WindowsAppRuntime.1.8 is still missing after the run (the installer installs
         the pinned framework itself where it can, work-order item 31, so on windows-latest it is
         expected to be there), that WAU was NOT installed and the latest transcript says
         'Auto-updates: NOT CONFIGURED'.
      4. The installed WAU version matches the pin in Get-WauPin (read from the registry via the
         module's Get-InstalledWauInfo helper, from the checkout's module).
    The transcript assertions (5-9) live in e2e/TranscriptAssertions.ps1, fixture-tested in
    tests/E2EAssertions.Tests.ps1. They read the real-run transcripts under
    %ProgramData%\winget-app-setup\logs (dry-run '-whatif' transcripts left out) and keep the
    Windows PowerShell 5.1 '-bootstrap' transcripts apart:
      5. A transcript exists and the latest one contains the 'Installer build' stamp. With
         -InstallerPath: EVERY transcript, bootstrap ones included, logs the build id stamped
         into that file, so each install pass provably ran the installer under test.
      6. Every NOT-applicable app shows its 'Skipping: <name> (not applicable: <reason>)' line
         in the latest transcript; not-applicable apps are excluded from the per-app installed
         checks (2) and the idempotence checks (8).
      7. Containment: in EVERY real-run transcript, every app still failed at the end of the run
         is on -SkipApps - this is the promise that lets the workflow tolerate installer exit 1
         for skip-listed apps. Read from the summary's Failed row and every failure line the
         retry pass did not recover (the 'Failed to install', 'Retry failed', 'Winget list timed
         out' and 'Verification timed out' forms), so a run whose circuit breaker failed the
         remaining apps because winget could not be launched is caught too. A transcript with no
         summary fails: its run stopped early.
      8. With -ExpectAllSkippedOnSecondRun: the LATEST transcript (the second, idempotence-leg
         run) shows every applicable non-skipped catalog app as
         'Skipping: <name> (already installed)', records no installs and no failures for
         non-skip-listed apps, and did not install the Windows App Runtime framework again.
      9. With -ExpectPowerShell7Bootstrap: every pass went through the Windows PowerShell 5.1
         bootstrap (one bootstrap transcript per real-run transcript), and each bootstrap
         relaunched the installer under PowerShell 7 and logged how that run ended. With
         -ExpectPowerShell7Installed also: the first pass's bootstrap installed PowerShell 7
         instead of finding one.

    Prints a per-assertion PASS/FAIL table and exits nonzero listing the failures.
.PARAMETER SkipApps
    Winget package ids from the catalog to exclude from the per-app and idempotence assertions.
    Escape hatch for runner-platform incompatibilities ONLY (e.g. an app that provably cannot
    install on a Server-based hosted image) - never for product bugs. Orthogonal to the catalog's
    applicability conditions: a skip-listed app is excluded from all per-app assertions whether
    or not it is applicable. Each use MUST reference a GitHub issue in a comment at the call site
    (workflow step or tier-2 harness) so the exclusion stays visible and temporary. Default: empty.
.PARAMETER ExpectAllSkippedOnSecondRun
    Enables the idempotence assertions (8). Pass this when the installer has just been run a
    second time on an already-provisioned machine, so the latest transcript must show every
    applicable app Skipped and nothing Installed or Failed.
.PARAMETER InstallerPath
    The installer file the runs were given (e.g. the checkout's winget-app-install.ps1). Each
    transcript must then log 'Installer build: <id>' with the $script:InstallerBuildId
    stamped into this file, which catches a run that tested some other copy - for example a
    workflow that fetched raw main while the branch under test changed the module. Default: no
    build check.
.PARAMETER ExpectPowerShell7Bootstrap
    Enables the bootstrap assertions (9). Pass this when every pass was started from Windows
    PowerShell 5.1 (the e2e-install-windows-powershell leg).
.PARAMETER ExpectPowerShell7Installed
    Adds the assertion that the first pass's bootstrap installed PowerShell 7 (9). Pass this when
    the first pass started on a machine without PowerShell 7 (the e2e-install-windows-powershell
    leg removes it first), so a leftover PowerShell 7 cannot leave the install path untested.
.NOTES
    Exit codes: 0 = all assertions passed, 1 = one or more assertions failed (each listed).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string[]]$SkipApps = @(),

    [Parameter(Mandatory = $false)]
    [switch]$ExpectAllSkippedOnSecondRun,

    [Parameter(Mandatory = $false)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $false)]
    [switch]$ExpectPowerShell7Bootstrap,

    [Parameter(Mandatory = $false)]
    [switch]$ExpectPowerShell7Installed
)

$ErrorActionPreference = 'Stop'

# pwsh -File passes arguments as literal strings (no PowerShell array parsing), so accept a
# comma-separated single token too: -SkipApps 'App.One,App.Two' == -SkipApps @('App.One','App.Two').
$SkipApps = @($SkipApps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Import the module from the checkout - same source of truth, no reimplementation drift. The
# manifest exports every function (FunctionsToExport = '*', review finding P3-44), Private/ ones
# included: Get-DefaultAppCatalog (the app list under test), Test-AppApplicability (which apps
# apply here), Get-WauPin (the pinned WAU version), Get-InstalledWauInfo, Test-WingetLaunchable and
# Test-WingetPackageInstalled all run as the module's own code.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force
# Transcript parsing, the transcript assertions (sections 5-9) and the applicability split (1).
. (Join-Path $PSScriptRoot 'TranscriptAssertions.ps1')

$logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'

$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-AssertionResult {
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $false)][string]$Detail = ''
    )
    $results.Add([pscustomobject]@{
            Assertion = $Name
            Result    = if ($Passed) { 'PASS' } else { 'FAIL' }
            Detail    = $Detail
        })
}

$catalog = @(Get-DefaultAppCatalog)
$candidateApps = @($catalog | Where-Object { $SkipApps -notcontains $_.name })
$skipped = @($catalog | Where-Object { $SkipApps -contains $_.name })
foreach ($app in $skipped) {
    Write-Host "SKIPPED (per -SkipApps): $($app.name) - must be justified by a referenced issue at the call site." -ForegroundColor Yellow
}

# --- 1. Applicability: the installer's own rule, on THIS machine -----------------------------
# Get-CatalogAppApplicability asks the module (Test-AppApplicability, Get-AppNotApplicableReason),
# so an arch list counts as in the run and the expected skip reason is the one the run printed.
$applicability = Get-CatalogAppApplicability -Apps $candidateApps
$appsToAssert = @($applicability.Applicable)
foreach ($id in $applicability.NotApplicable.Keys) {
    Write-Host "NOT APPLICABLE on this machine: $id ($($applicability.NotApplicable[$id])) - asserting its skip line instead of an install." -ForegroundColor Yellow
}
# The one check that does not ask the module: an app with no gate applies everywhere, so a module
# that skipped one would otherwise leave the run's matching skip line looking correct.
$ungatedNotApplicable = @($applicability.UngatedNotApplicable)
if ($ungatedNotApplicable.Count -gt 0) {
    Add-AssertionResult -Name 'Apps with no arch list or condition apply' -Passed $false -Detail "Test-AppApplicability found $($ungatedNotApplicable -join ', ') not applicable; still expected installed"
}
else {
    Add-AssertionResult -Name 'Apps with no arch list or condition apply' -Passed $true -Detail 'Test-AppApplicability found every one applicable'
}

# --- 2. Per-app: winget list resolves each applicable catalog app ---------------------------
# Retried: winget list is observably flaky on hosted runners - PR #219's run saw a one-off
# 0x8A150002 for an app the installer had just verified as installed (and that the identical
# probe resolved on the previous run). A retry with backoff separates transient winget noise
# from a genuinely missing app.
#
# Routed through the module's own Test-WingetPackageInstalled -TimeoutSeconds (WingetCore.ps1)
# instead of invoking `winget list` inline (issue #277 follow-up). The first version of this fix
# called winget via `& $wingetExecutable list ...` so it could swap in a bypass path after a launch
# failure - but that call style turned out to reliably reproduce the exact
# "StandardOutputEncoding is only supported when standard output is redirected" exception it was
# meant to tolerate: a live PR run against this change saw EVERY app fail with that message on
# every attempt, for the full ~3 minutes the assertion step ran, immediately after the installer's
# own Start-Process-based winget calls had just succeeded cleanly moments earlier - a 100% failure
# rate is not what a genuinely clearing alias lock looks like, it is what a reliably-triggered bug
# in the invocation style looks like. Test-WingetPackageInstalled -TimeoutSeconds never invokes
# winget as a captured native command; it runs it through the module's Invoke-WingetProcess with
# redirected output (the same helper the install passes use), so it sidesteps that whole bug class
# instead of retrying into it. It reports a winget that could not be started as LaunchFailed, not
# as 'not installed'.
#
# Checks that winget can be started before starting (issue #277): a Winget-AutoUpdate run can leave
# winget.exe unlaunchable for several minutes. The installer no longer starts one immediately
# (RUN_WAU=YES was removed), so this normally passes on the first check; it stays as a guard
# against a WAU run started by its own schedule, with up to 7 checks 30 seconds apart: 3 minutes
# when each check fails at once, about 6.5 minutes when each hangs to its 30-second limit, which is
# what e2e-install.yml's assertions step limit is sized for. Best-effort - the per-app retry loop
# below still tolerates a timeout or launch failure if a lock outlasts it.
$launchCheck = Test-WingetLaunchable -Attempts 7 -RetryDelaySeconds 30
if (-not $launchCheck.Launchable) {
    Write-Host "winget could not be started before the per-app checks ($($launchCheck.Reason)); proceeding anyway (each check retries independently)." -ForegroundColor Yellow
}

# Why a check did not confirm the app: a timeout, a winget that could not be started, or the
# exit code of a `winget list` that ran.
function Get-InstalledCheckFailureText {
    param ([Parameter(Mandatory = $true)][hashtable]$Result)
    if ($Result.TimedOut) { return 'timed out' }
    if ($Result.LaunchFailed) { return "winget could not be started: $($Result.LaunchError)" }
    return ('exit 0x{0:X8}' -f $Result.ExitCode)
}

$probeAttempts = 3
foreach ($app in $appsToAssert) {
    $id = $app.name
    $result = $null
    for ($attempt = 1; $attempt -le $probeAttempts; $attempt++) {
        $result = Test-WingetPackageInstalled -PackageId $id -TimeoutSeconds 60
        if ($result.Installed) { break }
        if ($attempt -lt $probeAttempts) {
            $reason = Get-InstalledCheckFailureText -Result $result
            Write-Host "winget list for $id did not confirm installed ($reason, attempt $attempt/$probeAttempts) - retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    if ($result.Installed) {
        $detail = if ($attempt -gt 1) { "winget list confirmed installed (attempt $attempt/$probeAttempts)" } else { 'winget list confirmed installed' }
        Add-AssertionResult -Name "App installed: $id" -Passed $true -Detail $detail
    }
    else {
        $reason = Get-InstalledCheckFailureText -Result $result
        Add-AssertionResult -Name "App installed: $id" -Passed $false -Detail "winget list $reason after $probeAttempts attempts"
    }
}

# --- 3/4. Winget-AutoUpdate: installed at the pin, unless the framework gate skipped it ------
# The installer deliberately skips WAU when Microsoft.WindowsAppRuntime.1.8 is missing (every WAU
# run installs the newest winget, which needs it; without it WAU wedged winget - issues #279/#284).
# The windows-latest (Server 2025) runner ships without that framework, and the installer now
# installs the pinned one for all users first (work-order item 31), so there it is expected to be
# present here and WAU installed at the pin. Where that install was not possible, the framework is
# still missing now and the correct outcome is NO WAU plus an 'Auto-updates: NOT CONFIGURED' line
# in the latest real-run transcript (checked with the other transcript assertions below, whose
# detail quotes the transcript's 'Windows App Runtime:' line with the reason). An unknown framework
# status falls back to expecting WAU, matching the installer's own fallback. This checks for the
# built-in requirement (Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0), not for what the run
# read from the latest winget release (work-order item 32): when the pinned framework no longer
# meets that, e2e/Invoke-InstallPass.ps1 has already failed the pass.
$frameworkStatus = Get-WindowsAppRuntimeStatus
if ($frameworkStatus.Present -eq $false) {
    $wauTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction SilentlyContinue
    Add-AssertionResult -Name 'WAU not installed without the WindowsAppRuntime framework' -Passed (-not $wauTask) -Detail $(if ($wauTask) { '\WAU\Winget-AutoUpdate exists although the framework is missing' } else { "skipped as designed ($($frameworkStatus.Detail))" })
}
else {
    try {
        $null = Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction Stop
        Add-AssertionResult -Name 'WAU scheduled task exists' -Passed $true -Detail '\WAU\Winget-AutoUpdate found'
    }
    catch {
        Add-AssertionResult -Name 'WAU scheduled task exists' -Passed $false -Detail "Get-ScheduledTask: $($_.Exception.Message)"
    }

    # Compared at the PIN's precision: the WAU MSI registers a DisplayVersion with an extra build
    # segment (e.g. 2.12.0.2118 for the pinned 2.12.0), so a strict [version] equality would
    # false-fail on every correctly provisioned machine. This mirrors the product's own comparison
    # (Install-WingetAutoUpdate upgrades only when installed -lt pin).
    $pin = Get-WauPin
    $installedWau = Get-InstalledWauInfo
    $pinFieldCount = ($pin.Version -split '\.').Count
    $installedAtPinPrecision = $null
    if ($installedWau.Version) {
        try {
            $installedAtPinPrecision = $installedWau.Version.ToString($pinFieldCount)
        }
        catch {
            # Installed version carries fewer fields than the pin - treat as a plain mismatch below.
            $installedAtPinPrecision = $installedWau.Version.ToString()
        }
    }
    if ($installedAtPinPrecision -and $installedAtPinPrecision -eq ([version]$pin.Version).ToString($pinFieldCount)) {
        Add-AssertionResult -Name 'WAU version matches pin' -Passed $true -Detail "installed v$($installedWau.Version) = pinned v$($pin.Version) (at pin precision)"
    }
    elseif ($installedWau.Version) {
        Add-AssertionResult -Name 'WAU version matches pin' -Passed $false -Detail "installed v$($installedWau.Version) != pinned v$($pin.Version)"
    }
    else {
        Add-AssertionResult -Name 'WAU version matches pin' -Passed $false -Detail "installed WAU version could not be read (pinned v$($pin.Version))"
    }
}

# --- 5-9. Transcripts: build stamp, skip lines, containment, idempotence, bootstrap ---------
# Read by e2e/TranscriptAssertions.ps1 (fixture-tested in tests/E2EAssertions.Tests.ps1). Dry-run
# transcripts are left out, and the Windows PowerShell 5.1 bootstrap transcripts are kept apart
# from the PowerShell 7 runs: the 5.1 parent writes its transcript last, so it would otherwise pass
# for the latest run.
$transcriptAssertionArgs = @{
    LogDirectory                = $logDirectory
    ExpectedAppIds              = @($appsToAssert | ForEach-Object { $_.name })
    NotApplicableApps           = $applicability.NotApplicable
    SkipApps                    = $SkipApps
    ExpectAllSkippedOnSecondRun = $ExpectAllSkippedOnSecondRun
    ExpectPowerShell7Bootstrap  = $ExpectPowerShell7Bootstrap
    ExpectPowerShell7Installed  = $ExpectPowerShell7Installed
}
if ($InstallerPath) {
    $transcriptAssertionArgs.InstallerPath = $InstallerPath
}
if ($frameworkStatus.Present -eq $false) {
    $transcriptAssertionArgs.ExpectedAutoUpdatesStatus = 'NOT CONFIGURED'
}
foreach ($row in (Get-TranscriptAssertionResult @transcriptAssertionArgs)) {
    $results.Add($row)
}

# --- Report ----------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== E2E assertion results ==='
# An explicit width, as in the installer's Write-Table (review finding P3-13): Out-Host renders at
# the console width, and printed nothing at all in a process without a console.
Write-Host ($results | Format-Table -AutoSize -Wrap | Out-String -Width 4096).TrimEnd()

$failures = @($results | Where-Object { $_.Result -eq 'FAIL' })
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAILED: $($failures.Count) assertion(s) failed:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $($failure.Assertion): $($failure.Detail)" -ForegroundColor Red
    }
    exit 1
}

Write-Host ''
Write-Host "PASSED: all $($results.Count) assertions passed." -ForegroundColor Green
exit 0
