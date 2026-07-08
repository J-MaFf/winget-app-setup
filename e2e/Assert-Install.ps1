<#
.SYNOPSIS
    Shared post-install assertions for end-to-end runs of winget-app-install.ps1 (issue #214).
.DESCRIPTION
    Runs AFTER the installer has completed on a real machine (e2e tier 1: GitHub-hosted
    windows-latest runners via .github/workflows/e2e-install.yml; tier 2, issue #215, will reuse
    this script on a snapshot-rollback Proxmox VM). It verifies the observable outcomes the unit
    suite can only mock:

      1. Every app in Get-DefaultAppCatalog (minus -SkipApps) resolves via
         `winget list --exact --id <id>`, classified by $LASTEXITCODE captured immediately
         after the call (exit 0 = installed; nonzero = missing).
      2. The Winget-AutoUpdate scheduled task exists ('\WAU\Winget-AutoUpdate').
      3. The installed WAU version matches the pin in Get-WauPin (read from the registry via the
         module's private Get-InstalledWauInfo helper, dot-sourced from the checkout).
      4. A transcript exists under %ProgramData%\winget-app-setup\logs and contains the
         'Installer build' stamp.
      5. Containment: in EVERY real-run transcript, no app outside -SkipApps failed — this is
         the promise that lets the workflow tolerate installer exit 1 for skip-listed apps.
      6. With -ExpectAllSkippedOnSecondRun: the LATEST transcript (the second, idempotence-leg
         run) shows every non-skipped catalog app as 'Skipping: <name> (already installed)' and
         records no installs and no failures for non-skip-listed apps.

    Prints a per-assertion PASS/FAIL table and exits nonzero listing the failures.
.PARAMETER SkipApps
    Winget package ids from the catalog to exclude from the per-app and idempotence assertions.
    Escape hatch for runner-platform incompatibilities ONLY (e.g. an app that provably cannot
    install on a Server-based hosted image) - never for product bugs. Each use MUST reference a
    GitHub issue in a comment at the call site (workflow step or tier-2 harness) so the exclusion
    stays visible and temporary. Default: empty.
.PARAMETER ExpectAllSkippedOnSecondRun
    Enables the idempotence assertions (5). Pass this when the installer has just been run a
    second time on an already-provisioned machine, so the latest transcript must show every app
    Skipped and nothing Installed or Failed.
.NOTES
    Exit codes: 0 = all assertions passed, 1 = one or more assertions failed (each listed).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string[]]$SkipApps = @(),

    [Parameter(Mandatory = $false)]
    [switch]$ExpectAllSkippedOnSecondRun
)

$ErrorActionPreference = 'Stop'

# pwsh -File passes arguments as literal strings (no PowerShell array parsing), so accept a
# comma-separated single token too: -SkipApps 'App.One,App.Two' == -SkipApps @('App.One','App.Two').
$SkipApps = @($SkipApps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Import the module from the checkout: Get-DefaultAppCatalog (the app list under test) and
# Get-WauPin (the pinned WAU version) are exported; Get-InstalledWauInfo is private, so
# dot-source its file directly - same source of truth, no reimplementation drift.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force
. (Join-Path $repoRoot 'WingetAppSetup\Private\WauSupport.ps1')

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
$appsToAssert = @($catalog | Where-Object { $SkipApps -notcontains $_.name })
$skipped = @($catalog | Where-Object { $SkipApps -contains $_.name })
foreach ($app in $skipped) {
    Write-Host "SKIPPED (per -SkipApps): $($app.name) - must be justified by a referenced issue at the call site." -ForegroundColor Yellow
}

# --- 1. Per-app: winget list resolves each catalog app -------------------------------------
# Retried: winget list is observably flaky on hosted runners - PR #219's run saw a one-off
# 0x8A150002 for an app the installer had just verified as installed (and that the identical
# probe resolved on the previous run). A retry with backoff separates transient winget noise
# from a genuinely missing app; the output is kept for diagnosis when all attempts fail.
$probeAttempts = 3
foreach ($app in $appsToAssert) {
    $id = $app.name
    $exitCode = $null
    $output = @()
    for ($attempt = 1; $attempt -le $probeAttempts; $attempt++) {
        # --accept-source-agreements/--disable-interactivity: never hang on a first-use prompt.
        $output = @(winget list --exact --id $id --accept-source-agreements --disable-interactivity 2>&1)
        # Capture immediately - $LASTEXITCODE goes stale fast (repo rule).
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { break }
        if ($attempt -lt $probeAttempts) {
            Write-Host ('winget list for {0} exited 0x{1:X8} (attempt {2}/{3}) - retrying...' -f $id, $exitCode, $attempt, $probeAttempts) -ForegroundColor Yellow
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    if ($exitCode -eq 0) {
        $detail = if ($attempt -gt 1) { "winget list exit 0 (attempt $attempt/$probeAttempts)" } else { 'winget list exit 0' }
        Add-AssertionResult -Name "App installed: $id" -Passed $true -Detail $detail
    }
    else {
        $outputTail = (@($output | Select-Object -Last 3) -join ' | ')
        Add-AssertionResult -Name "App installed: $id" -Passed $false -Detail (('winget list exit 0x{0:X8} after {1} attempts; last output: {2}' -f $exitCode, $probeAttempts, $outputTail))
    }
}

# --- 2. WAU scheduled task exists -----------------------------------------------------------
try {
    $null = Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction Stop
    Add-AssertionResult -Name 'WAU scheduled task exists' -Passed $true -Detail '\WAU\Winget-AutoUpdate found'
}
catch {
    Add-AssertionResult -Name 'WAU scheduled task exists' -Passed $false -Detail "Get-ScheduledTask: $($_.Exception.Message)"
}

# --- 3. Installed WAU version matches the pin ------------------------------------------------
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

# --- 4. Transcript exists and carries the build stamp ----------------------------------------
$logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
# Real-run transcripts only: dry runs get a -whatif suffix and prove nothing about an install.
$transcripts = @(Get-ChildItem -Path $logDirectory -Filter 'install-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '-whatif\.log$' } |
        Sort-Object LastWriteTime)
if ($transcripts.Count -eq 0) {
    Add-AssertionResult -Name 'Transcript exists' -Passed $false -Detail "no install-*.log under $logDirectory"
    Add-AssertionResult -Name "Transcript contains 'Installer build'" -Passed $false -Detail 'no transcript to inspect'
}
else {
    $latest = $transcripts[-1]
    Add-AssertionResult -Name 'Transcript exists' -Passed $true -Detail "$($transcripts.Count) transcript(s); latest: $($latest.Name)"
    $latestContent = Get-Content -Path $latest.FullName -Raw
    if ($latestContent -match 'Installer build') {
        $buildLine = (($latestContent -split "`n") | Where-Object { $_ -match 'Installer build' } | Select-Object -First 1).Trim()
        Add-AssertionResult -Name "Transcript contains 'Installer build'" -Passed $true -Detail $buildLine
    }
    else {
        Add-AssertionResult -Name "Transcript contains 'Installer build'" -Passed $false -Detail "no 'Installer build' line in $($latest.Name)"
    }

    # --- 5. Containment: no app OUTSIDE -SkipApps failed, in ANY real-run transcript ---------
    # The workflow tolerates installer exit 1 only on the promise that every failure belongs to
    # the justified skip list (KNOWN_PLATFORM_INCOMPATIBLE / issue-referenced). Parse each
    # transcript's summary table 'Failed    <app1>, <app2>' row and diff against $SkipApps.
    foreach ($transcript in $transcripts) {
        $content = if ($transcript.FullName -eq $latest.FullName) { $latestContent } else { Get-Content -Path $transcript.FullName -Raw }
        # Primary source: the per-app failure lines ('Failed to install: <id> ...' and
        # 'Retry failed: <id> ...'), which are logged unconditionally per app. The summary
        # table's 'Failed' row is Format-Table output and can ellipsis-truncate long lists,
        # which would hide offenders, so it is deliberately not parsed.
        $failedApps = @()
        foreach ($line in ($content -split "`n")) {
            if ($line -match '^(Failed to install|Retry failed):\s+(?<app>[^\s(]+)') {
                $failedApps += $Matches.app.TrimEnd('.', ',')
            }
        }
        $failedApps = @($failedApps | Sort-Object -Unique)
        $uncontained = @($failedApps | Where-Object { $SkipApps -notcontains $_ })
        if ($uncontained.Count -eq 0) {
            $detail = if ($failedApps.Count -gt 0) { "failed apps all skip-listed: $($failedApps -join ', ')" } else { 'no failed apps' }
            Add-AssertionResult -Name "Failures contained ($($transcript.Name))" -Passed $true -Detail $detail
        }
        else {
            Add-AssertionResult -Name "Failures contained ($($transcript.Name))" -Passed $false -Detail "apps outside -SkipApps failed: $($uncontained -join ', ')"
        }
    }

    # --- 6. Idempotence: the latest (second-run) transcript shows everything Skipped ---------
    if ($ExpectAllSkippedOnSecondRun) {
        foreach ($app in $appsToAssert) {
            $id = $app.name
            # Invoke-WingetInstall logs exactly this per already-installed app.
            $skipLine = "Skipping: $id (already installed)"
            if ($latestContent.Contains($skipLine)) {
                Add-AssertionResult -Name "Second run skipped: $id" -Passed $true
            }
            else {
                Add-AssertionResult -Name "Second run skipped: $id" -Passed $false -Detail "transcript $($latest.Name) has no '$skipLine'"
            }
        }
        # Per-app checks so skip-listed apps (which legitimately install-retry-fail on this
        # platform) don't trip the idempotence assertions for everything else.
        $installedOffenders = @($appsToAssert | Where-Object { $latestContent.Contains("Successfully installed: $($_.name)") } | ForEach-Object { $_.name })
        Add-AssertionResult -Name 'Second run installed nothing (non-skip-listed)' -Passed ($installedOffenders.Count -eq 0) -Detail $(if ($installedOffenders.Count) { "installed on second run: $($installedOffenders -join ', ')" } else { '' })
        $failedOffenders = @($appsToAssert | Where-Object { $latestContent.Contains("Failed to install: $($_.name)") } | ForEach-Object { $_.name })
        Add-AssertionResult -Name 'Second run failed nothing (non-skip-listed)' -Passed ($failedOffenders.Count -eq 0) -Detail $(if ($failedOffenders.Count) { "failed on second run: $($failedOffenders -join ', ')" } else { '' })
    }
}

# --- Report ----------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== E2E assertion results ==='
$results | Format-Table -AutoSize -Wrap | Out-Host

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
