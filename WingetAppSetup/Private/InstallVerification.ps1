<#
.SYNOPSIS
    Installs a single curated app with pre-check and post-install verification, without prompting.
.DESCRIPTION
    Shared per-app install pipeline used by both the first pass and the retry pass of
    Invoke-WingetInstall (issue #188). It replaces the three drifted inline Start-Process
    `winget list` verify blocks with a single implementation:

      1. Pre-check: Test-WingetPackageInstalled under a timeout guard. Already installed maps to
         Skipped; a hung `winget list` maps to Failed so the app flows into the retry pass and
         the non-zero exit code instead of being silently dropped (issue #176).
      2. Dispatch: a package-specific self-verifying installer named in $App.install (e.g.
         Install-PowerShellLatest, whose DISM-provisioned MSIX path never shows up under
         `winget list` for the elevating account), or the default Install-WingetPackage, which
         retries the transient 0x80073d19 session error with backoff (issue #150).
      3. Post-verify: winget installs are re-checked with Test-WingetPackageInstalled; an install
         that reported success but does not show up under `winget list` is Failed.

    The helper contains no prompts, no Exit, and no ReadKey — user-facing messages, summary
    bucketing, and exit-code policy stay in Invoke-WingetInstall — which is what makes the install
    pipeline unit-testable (issue #188).
.PARAMETER App
    A validated app-definition hashtable: @{ name = '<winget package id>' } with optional
    'install' (name of a self-verifying installer command) and 'installerType' (winget
    --installer-type override forwarded to Install-WingetPackage) entries.
.PARAMETER WhatIf
    Dry run: the read-only pre-check still runs, but no installer is dispatched. An app that is
    not yet installed reports Status 'Installed' so the caller's dry-run summary shows what would
    change, matching the pre-#188 dry-run bucket semantics.
.RETURNS
    [hashtable] @{
        Status        = 'Installed' | 'Failed' | 'Skipped'
        InstallResult = the Install-WingetPackage result hashtable — or the $App.install command's
                        result — returned intact so exit codes can be surfaced without
                        restructuring (issue #189); $null when no installer ran (skip, dry run,
                        pre-check timeout)
        FailureReason = $null when Status is not 'Failed'; otherwise 'PreCheckTimeout',
                        'CustomInstallFailed', 'VerifyTimeout', or 'VerifyNotFound' so the caller
                        can keep its per-situation message texts
    }
#>
function Install-AppWithVerification {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # Same 15-second guard the inlined blocks used: `winget list` can hang indefinitely on broken
    # sources or first-use prompts, and a hung check must not stall the whole install loop.
    $checkTimeoutSeconds = 15

    $preCheck = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    if ($preCheck.TimedOut) {
        # Failed, not skipped: the app then flows through the retry pass, appears in the summary,
        # and drives the non-zero exit code (issue #176).
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' }
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
        $customResult = & $App.install
        if ($customResult.Installed) {
            return @{ Status = 'Installed'; InstallResult = $customResult; FailureReason = $null }
        }
        return @{ Status = 'Failed'; InstallResult = $customResult; FailureReason = 'CustomInstallFailed' }
    }

    # Install through the helper so the transient 0x80073d19 session error is retried with
    # backoff (issue #150) instead of failing on the first hit.
    $installResult = Install-WingetPackage -PackageId $App.name -InstallerType $App.installerType

    $verify = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    if ($verify.TimedOut) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyTimeout' }
    }
    if ($verify.Installed) {
        return @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null }
    }
    return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
}
