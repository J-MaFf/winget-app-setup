<#
.SYNOPSIS
    Runs the uninstall pass of the end-to-end workflow and checks what it removed (wgt-gq8.47).
.DESCRIPTION
    Used by the e2e-install leg of .github/workflows/e2e-install.yml, after the install passes and
    their assertions. It runs the checkout's winget-app-uninstall.ps1 with -NonInteractive in a new
    PowerShell 7 process (the runner account is an elevated administrator, so the uninstaller runs
    in place) and saves its console output, since the uninstaller keeps no transcript. Then:

      1. The uninstaller's exit code is 0, or 3010 (a restart finishes a removal).
      2. It reached its summary ('Summary:') and removed at least one app ('Successfully
         uninstalled: <id>'): the install passes left Chrome, 7-Zip and Git there, so a pass that
         removed nothing proves nothing.
      3. Each catalog app is gone: `winget list` (the module's Test-WingetPackageInstalled, with
         retries when winget gives no answer) no longer lists it, unless the uninstaller kept it on
         purpose. Kept on purpose is a 'Skipping: <id> (<reason>)' line whose reason is one of
         $script:UninstallKeptReasons: PowerShell 7 while the uninstaller runs in it, Windows
         Terminal when it hosts the window or is the default terminal (the installer sets that),
         a per-user app a SYSTEM or cross-user run cannot remove, or an app whose catalog condition
         does not hold here. An app winget gives no answer for fails: no answer is never 'removed'.
      4. Winget-AutoUpdate is gone: its \WAU\Winget-AutoUpdate scheduled task no longer exists.

    Prints a PASS/FAIL table under '=== E2E uninstall results ===' and exits 1 when a check
    failed. The parsing and the verdicts (ConvertFrom-UninstallerOutput, Get-UninstallPassResult)
    read only text and values, so tests/E2EUninstallPass.Tests.ps1 checks them against
    tests/fixtures/e2e/uninstall-pass.txt on any OS.

    ASCII only, no PowerShell-7-only syntax, like the other e2e scripts.
.PARAMETER UninstallerPath
    The uninstaller to run. Default: winget-app-uninstall.ps1 at the repository root (the checkout).
.PARAMETER OutputPath
    Where to save the uninstaller's console output. Default: not saved.
.NOTES
    Exit codes: 0 = every check passed; 1 = a check failed (each listed); 127 = pwsh could not be
    started.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$UninstallerPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# The reasons the uninstaller gives for an app it keeps on purpose, as the start of the text in
# 'Skipping: <id> (<reason>)' (WingetAppSetup/Private/AppUninstall.ps1).
$script:UninstallKeptReasons = @(
    'this uninstaller is running in PowerShell 7',
    'Windows Terminal hosts this window',
    'a per-user app that this run cannot remove',
    'not applicable: '
)

<#
.SYNOPSIS
    Reads an uninstaller run's console output.
.PARAMETER Content
    The output, as text.
.RETURNS
    [pscustomobject] with Uninstalled (ids), Kept (hashtable id -> reason, the apps kept on
    purpose), NotInstalled (ids), Failed (hashtable id -> reason) and HasSummary (the run printed
    'Summary:').
#>
function ConvertFrom-UninstallerOutput {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Content = ''
    )

    # A package id ends with a letter, digit or '-', never the '.' of 'Failed to uninstall: <id>. Error'.
    $idPattern = '(?<id>[\w][\w.\-]*\.[\w.\-]*[\w\-])'
    $uninstalled = @()
    $notInstalled = @()
    $kept = @{}
    $failed = @{}
    $hasSummary = $false
    foreach ($rawLine in @([string]$Content -split '\r?\n')) {
        $line = $rawLine.Trim()
        if ($line -eq 'Summary:') {
            $hasSummary = $true
            continue
        }
        $match = [regex]::Match($line, "^Successfully uninstalled: $idPattern(?: \(.*\))?$")
        if ($match.Success) {
            $uninstalled += $match.Groups['id'].Value
            continue
        }
        $match = [regex]::Match($line, "^Failed to uninstall: $idPattern(?<rest>.*)$")
        if ($match.Success) {
            # '<id> (<reason>).' or '<id>. Error: <error>'.
            $rest = $match.Groups['rest'].Value.Trim()
            $inner = [regex]::Match($rest, '^\((?<reason>.*)\)\.?$')
            if ($inner.Success) {
                $rest = $inner.Groups['reason'].Value
            }
            else {
                $rest = $rest.TrimStart([char[]]@('.', ' '))
            }
            $failed[$match.Groups['id'].Value] = $rest
            continue
        }
        $match = [regex]::Match($line, "^Skipping: $idPattern \((?<reason>.*)\)$")
        if (-not $match.Success) {
            continue
        }
        $id = $match.Groups['id'].Value
        $reason = $match.Groups['reason'].Value
        if ($reason -eq 'not installed') {
            $notInstalled += $id
            continue
        }
        foreach ($keptReason in $script:UninstallKeptReasons) {
            if ($reason.StartsWith($keptReason, [System.StringComparison]::Ordinal)) {
                $kept[$id] = $reason
                break
            }
        }
    }
    return [pscustomobject]@{
        Uninstalled  = @($uninstalled | Sort-Object -Unique)
        Kept         = $kept
        NotInstalled = @($notInstalled | Sort-Object -Unique)
        Failed       = $failed
        HasSummary   = $hasSummary
    }
}

<#
.SYNOPSIS
    The catalog ids to check with winget after the uninstall: every one not kept on purpose.
.PARAMETER CatalogIds
    The catalog's package ids.
.PARAMETER Parsed
    ConvertFrom-UninstallerOutput's result.
.RETURNS
    [string[]]
#>
function Get-UninstallPassCheckId {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$CatalogIds,

        [Parameter(Mandatory = $true)]
        $Parsed
    )

    return @($CatalogIds | Where-Object { -not $Parsed.Kept.ContainsKey($_) })
}

<#
.SYNOPSIS
    Turns the uninstall pass's outcome into PASS/FAIL rows.
.PARAMETER ExitCode
    The uninstaller's exit code, or $null when it did not run to the end.
.PARAMETER Parsed
    ConvertFrom-UninstallerOutput's result for its console output.
.PARAMETER CatalogIds
    The catalog's package ids.
.PARAMETER InstalledAfter
    Hashtable id -> @{ Installed = $true | $false | $null; Detail = <why there was no answer> }
    for each id Get-UninstallPassCheckId returned; $null Installed (or a missing id) means winget
    gave no answer.
.PARAMETER WauTaskPresent
    Whether the \WAU\Winget-AutoUpdate task still exists, or $null when that could not be read.
.RETURNS
    [pscustomobject[]] with Assertion, Result ('PASS' or 'FAIL') and Detail.
#>
function Get-UninstallPassResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $true)]
        $Parsed,

        [Parameter(Mandatory = $true)]
        [string[]]$CatalogIds,

        [Parameter(Mandatory = $false)]
        [hashtable]$InstalledAfter = @{},

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WauTaskPresent
    )

    $rows = @()
    $newRow = {
        param ([string]$Name, [bool]$Passed, [string]$Detail)
        $result = 'FAIL'
        if ($Passed) {
            $result = 'PASS'
        }
        [pscustomobject]@{ Assertion = $Name; Result = $result; Detail = $Detail }
    }

    if ($null -eq $ExitCode) {
        $rows += & $newRow 'Uninstaller exit code 0 or 3010' $false 'it did not run to the end'
    }
    elseif ($ExitCode -eq 0) {
        $rows += & $newRow 'Uninstaller exit code 0 or 3010' $true 'exit 0'
    }
    elseif ($ExitCode -eq 3010) {
        $rows += & $newRow 'Uninstaller exit code 0 or 3010' $true 'exit 3010 (a restart finishes a removal)'
    }
    else {
        $failedText = ''
        if ($Parsed.Failed.Count -gt 0) {
            $failedText = '; failed: ' + ((@($Parsed.Failed.Keys) | Sort-Object | ForEach-Object { '{0} ({1})' -f $_, $Parsed.Failed[$_] }) -join ', ')
        }
        $rows += & $newRow 'Uninstaller exit code 0 or 3010' $false ("exit $ExitCode$failedText")
    }

    $summaryDetail = "no 'Summary:' line: the run stopped before its summary"
    if ($Parsed.HasSummary) {
        $summaryDetail = "'Summary:' printed"
    }
    $rows += & $newRow 'Uninstaller reached its summary' ([bool]$Parsed.HasSummary) $summaryDetail

    $removedCount = @($Parsed.Uninstalled).Count
    $removedDetail = 'no ''Successfully uninstalled:'' line, although the install passes left apps to remove'
    if ($removedCount -gt 0) {
        $removedDetail = '{0} app(s): {1}' -f $removedCount, (@($Parsed.Uninstalled) -join ', ')
    }
    $rows += & $newRow 'Uninstaller removed apps' ($removedCount -gt 0) $removedDetail

    foreach ($id in $CatalogIds) {
        if ($Parsed.Kept.ContainsKey($id)) {
            $rows += & $newRow "App kept on purpose: $id" $true $Parsed.Kept[$id]
            continue
        }
        $how = 'not installed before the uninstall'
        if (@($Parsed.Uninstalled) -contains $id) {
            $how = 'uninstalled by this run'
        }
        elseif ($Parsed.Failed.ContainsKey($id)) {
            $how = "the uninstaller failed it ($($Parsed.Failed[$id]))"
        }
        $check = $null
        if ($InstalledAfter.ContainsKey($id)) {
            $check = $InstalledAfter[$id]
        }
        if ($null -eq $check -or $null -eq $check.Installed) {
            $why = 'no answer'
            if ($null -ne $check -and $check.Detail) {
                $why = $check.Detail
            }
            $rows += & $newRow "App removed: $id" $false "winget list could not answer ($why); $how"
        }
        elseif ($check.Installed) {
            $rows += & $newRow "App removed: $id" $false "winget still lists it; $how"
        }
        else {
            $rows += & $newRow "App removed: $id" $true "winget no longer lists it; $how"
        }
    }

    if ($null -eq $WauTaskPresent) {
        $rows += & $newRow 'Winget-AutoUpdate removed' $false 'whether \WAU\Winget-AutoUpdate exists could not be read'
    }
    elseif ($WauTaskPresent) {
        $rows += & $newRow 'Winget-AutoUpdate removed' $false '\WAU\Winget-AutoUpdate still exists'
    }
    else {
        $rows += & $newRow 'Winget-AutoUpdate removed' $true '\WAU\Winget-AutoUpdate is gone'
    }
    return $rows
}

if ($MyInvocation.InvocationName -ne '.') {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    if (-not $UninstallerPath) {
        $UninstallerPath = Join-Path $repoRoot 'winget-app-uninstall.ps1'
    }
    $UninstallerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($UninstallerPath)
    Write-Host "Uninstaller under test: $UninstallerPath ($env:GITHUB_REF at $env:GITHUB_SHA), run with -File -NonInteractive in PowerShell 7."

    # Native stderr must not stop this script, and each line is shown as it comes and kept.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    $lines = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $UninstallerPath -NonInteractive 2>&1 | ForEach-Object {
            $text = "$_"
            Write-Host $text
            $text
        })
    $uninstallerExitCode = $global:LASTEXITCODE
    $output = $lines -join "`n"
    if ($OutputPath) {
        try {
            $outputDirectory = Split-Path -Parent $OutputPath
            if ($outputDirectory) {
                $null = New-Item -ItemType Directory -Path $outputDirectory -Force
            }
            Set-Content -LiteralPath $OutputPath -Value $output -Encoding UTF8
        }
        catch {
            Write-Host "Could not save the uninstaller's output to ${OutputPath}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($null -eq $uninstallerExitCode) {
        Write-Host 'pwsh could not be started.' -ForegroundColor Red
        exit 127
    }
    Write-Host "The uninstaller exited $uninstallerExitCode."

    $parsed = ConvertFrom-UninstallerOutput -Content $output
    Import-Module (Join-Path $repoRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force
    $catalogIds = @(Get-DefaultAppCatalog | ForEach-Object { $_.name })

    # Retried only when winget gives no answer, as Assert-Install.ps1 does: winget list is flaky on
    # hosted runners, and an answer either way is what is checked.
    $installedAfter = @{}
    $probeAttempts = 3
    foreach ($id in (Get-UninstallPassCheckId -CatalogIds $catalogIds -Parsed $parsed)) {
        $answer = @{ Installed = $null; Detail = 'not checked' }
        for ($attempt = 1; $attempt -le $probeAttempts; $attempt++) {
            $check = Test-WingetPackageInstalled -PackageId $id -TimeoutSeconds 60
            if ($check.Installed) {
                $answer = @{ Installed = $true; Detail = '' }
                break
            }
            if (-not ($check.TimedOut -or $check.LaunchFailed -or $check.CheckFailed)) {
                $answer = @{ Installed = $false; Detail = '' }
                break
            }
            if ($check.TimedOut) {
                $answer = @{ Installed = $null; Detail = 'timed out' }
            }
            elseif ($check.LaunchFailed) {
                $answer = @{ Installed = $null; Detail = "winget could not be started: $($check.LaunchError)" }
            }
            else {
                $answer = @{ Installed = $null; Detail = ('exit 0x{0:X8}' -f $check.ExitCode) }
            }
            if ($attempt -lt $probeAttempts) {
                Write-Host "winget list for $id gave no answer ($($answer.Detail), attempt $attempt/$probeAttempts) - retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
        $installedAfter[$id] = $answer
    }

    $wauTaskPresent = $null
    try {
        $wauTaskPresent = $null -ne (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction SilentlyContinue)
    }
    catch {
        $wauTaskPresent = $null
    }

    $results = @(Get-UninstallPassResult -ExitCode $uninstallerExitCode -Parsed $parsed -CatalogIds $catalogIds -InstalledAfter $installedAfter -WauTaskPresent $wauTaskPresent)
    Write-Host ''
    Write-Host '=== E2E uninstall results ==='
    Write-Host ($results | Format-Table -AutoSize -Wrap | Out-String -Width 4096).TrimEnd()

    $failures = @($results | Where-Object { $_.Result -eq 'FAIL' })
    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host "FAILED: $($failures.Count) uninstall check(s) failed:" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "  - $($failure.Assertion): $($failure.Detail)" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host ''
    Write-Host "PASSED: all $($results.Count) uninstall checks passed." -ForegroundColor Green
    exit 0
}
