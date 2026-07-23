# Failure-reporting helpers (issue #189). Install-WingetPackage returns a rich diagnostic
# hashtable (ExitCode, Attempts, SessionErrorExhausted, MachineScopeFellBack) built precisely
# because the 0x80073D19-era failures were only diagnosable by hex exit code — but both
# Invoke-WingetInstall call sites used to discard it, reporting every failure as a generic
# "No package found matching input criteria." These helpers turn that result into the failure
# messages and the per-app Reason column of the failed-apps summary.

<#
.SYNOPSIS
    Formats a one-line, human-readable reason for a failed app install.
.DESCRIPTION
    Combines the shared install pipeline's FailureReason bucket with the diagnostic detail the
    installer result carries: the winget exit code (hex), the attempt count, whether the
    machine-scope preference fell back to winget's default scope, and whether the 0x80073D19
    session-error retries were exhausted (issue #189). Used both for the console failure message
    and for the Reason column in the failed-apps summary table.
.PARAMETER FailureReason
    The FailureReason string from the shared install pipeline ('PreCheckTimeout', 'VerifyTimeout',
    'VerifyNotFound', 'CustomInstallFailed'). Unknown or empty values fall back to a generic
    'install failed'.
.PARAMETER InstallResult
    The InstallResult hashtable from the shared install pipeline: Install-WingetPackage's
    ExitCode/Attempts/SessionErrorExhausted/MachineScopeFellBack shape, a custom installer's
    ExitCode/Installed shape, or $null when no installer ran (timeouts, dry runs). Keys are probed
    individually, so partial shapes format whatever detail they carry.
.RETURNS
    [string] e.g. 'package not found after install; winget exit 0x80073D19, 3 attempts,
    machine-scope fallback: no'. Never $null or empty.
#>
function Format-InstallFailureReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FailureReason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$InstallResult
    )

    $base = switch ($FailureReason) {
        'PreCheckTimeout' { 'winget list timed out during the pre-install check' }
        'VerifyTimeout' { 'post-install verification timed out' }
        'VerifyNotFound' { 'package not found after install' }
        'CustomInstallFailed' { 'installer reported failure' }
        default { 'install failed' }
    }

    $detailParts = @()
    if ($InstallResult) {
        if ($InstallResult.ContainsKey('ExitCode') -and $null -ne $InstallResult.ExitCode) {
            # Winget reports HRESULT-style codes as signed Int32 (e.g. -2147009255); the X8 format
            # renders the familiar hex form (0x80073D19) the winget docs and issues use.
            $detailParts += ('winget exit 0x{0:X8}' -f [int]$InstallResult.ExitCode)
        }
        if ($InstallResult.ContainsKey('Attempts') -and $InstallResult.Attempts) {
            $attemptWord = if ([int]$InstallResult.Attempts -eq 1) { 'attempt' } else { 'attempts' }
            $detailParts += ('{0} {1}' -f $InstallResult.Attempts, $attemptWord)
        }
        if ($InstallResult.ContainsKey('MachineScopeFellBack')) {
            $detailParts += ('machine-scope fallback: {0}' -f $(if ($InstallResult.MachineScopeFellBack) { 'yes' } else { 'no' }))
        }
        if ($InstallResult.ContainsKey('SessionErrorExhausted') -and $InstallResult.SessionErrorExhausted) {
            $detailParts += 'session error 0x80073D19 persisted through every retry'
        }
        if ($InstallResult.ContainsKey('LaunchErrorExhausted') -and $InstallResult.LaunchErrorExhausted) {
            # issue #253: Start-Process could not launch winget.exe (transient file lock) on every
            # attempt, so no install ever actually ran.
            $detailParts += 'winget executable was transiently inaccessible through every retry'
        }
    }

    if ($detailParts.Count -gt 0) {
        return ('{0}; {1}' -f $base, ($detailParts -join ', '))
    }
    return $base
}

<#
.SYNOPSIS
    Renders the per-app failure-reason table shown under the installation summary.
.DESCRIPTION
    Prints one row per failed app with its Format-InstallFailureReason diagnostic (issue #189), so
    the summary — and the persistent transcript — carry the winget exit code and retry detail
    instead of just a list of failed names. No-ops when nothing failed. Kept separate from
    Invoke-WingetInstall so the rendering is unit-testable without driving the whole orchestrator
    (whose failure path ends in Exit 1).
.PARAMETER FailedApps
    Array of @{ Name = <winget package id>; Reason = <string> } hashtables tracked by
    Invoke-WingetInstall.
#>
function Write-FailedAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$FailedApps
    )

    if (-not $FailedApps -or $FailedApps.Count -eq 0) {
        return
    }

    $failedRows = @(foreach ($failedApp in $FailedApps) {
            , @([string]$failedApp.Name, [string]$failedApp.Reason)
        })
    Write-Table -Headers @('App', 'Reason') -Rows $failedRows -Title 'Failed Installations'
}
