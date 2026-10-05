# The uninstaller's per-app step. Runs under Windows PowerShell 5.1 too: the uninstaller's elevated
# relaunch is System32's powershell.exe.

<#
.SYNOPSIS
    Returns why the uninstaller must not remove a shell it is running in, or $null.
.DESCRIPTION
    Removing the shell or the terminal running this script ends the run part-way, with no summary
    and no exit code. So Microsoft.PowerShell is kept when this runs in PowerShell 7
    (Get-PowerShellEdition), and Microsoft.WindowsTerminal when Windows Terminal hosts this session
    (Test-WindowsTerminalHostsCurrentSession). The reason says how to remove the app instead.
    Windows' 'Let Windows decide' default terminal leaves no trace to detect: to remove Windows
    Terminal there, run the uninstaller from a Windows Console Host window.
.PARAMETER PackageId
    The catalog app's winget package id.
.OUTPUTS
    [string] The skip reason, or $null when removing the app does not affect this run.
#>
function Get-HostingShellSkipReason {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    if ($PackageId -eq 'Microsoft.PowerShell' -and (Get-PowerShellEdition) -eq 'Core') {
        return 'this uninstaller is running in PowerShell 7; to remove it, run winget-app-uninstall.ps1 from Windows PowerShell'
    }
    if ($PackageId -eq 'Microsoft.WindowsTerminal' -and (Test-WindowsTerminalHostsCurrentSession)) {
        return 'Windows Terminal hosts this window, or is set as the default terminal application, so removing it would close this window; to remove it, set the default terminal application to Windows Console Host and run winget-app-uninstall.ps1 from a window Windows Terminal does not host'
    }
    return $null
}

<#
.SYNOPSIS
    Returns whether a `winget uninstall` result says the app was removed and a restart finishes it.
.DESCRIPTION
    winget's uninstall has no restart result of its own: any non-zero return from the app's
    uninstaller ends it with 0x8A150030 after 'Uninstall failed with exit code: <n>'. msiexec's
    3010 and 1641 are successes that need a restart, so the result is True for 0x8A150030 with
    3010 or 1641 as a number of its own in the output. Only the number is matched, since the text
    is translated, and lines with a backslash (the installer log path) are not read.
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.PARAMETER Output
    What winget printed (Invoke-WingetProcess's Output).
.OUTPUTS
    [bool]
#>
function Test-WingetUninstallRestartRequiredResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Output
    )

    # 0x8A150030 APPINSTALLER_CLI_ERROR_EXEC_UNINSTALL_COMMAND_FAILED as a signed Int32.
    if ($null -eq $ExitCode -or $ExitCode -ne -1978335184) {
        return $false
    }
    foreach ($line in @($Output)) {
        $text = [string]$line
        if ($text.Contains('\')) {
            continue
        }
        if ($text -match '(?<![\w.])(3010|1641)(?![\w.])') {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Uninstalls one catalog app with winget, without prompting, and says what happened.
.DESCRIPTION
    The uninstaller's counterpart of Install-AppWithVerification, in this order:
      1. Installed check (Test-WingetPackageInstalled, WingetListCheck time limit). A winget that
         could not start, ran out of time or failed is a failure, never "not installed" (P2-19).
      2. Not installed: Skipped, NotInstalled.
      3. A shell this run depends on (Get-HostingShellSkipReason): Skipped, HostsThisRun.
      4. Not applicable by the installer's own rule (Test-AppApplicability, failing open): Skipped,
         NotApplicable, and left alone.
      5. `winget uninstall --exact --id <id> --silent --accept-source-agreements
         --disable-interactivity` through Invoke-WingetProcess (WingetUninstall time limit).
         --silent always: an interactive uninstaller would wait for a click nobody makes. Exit 0 is
         Uninstalled; a 3010 or 1641 from the app's uninstaller
         (Test-WingetUninstallRestartRequiredResult) is Uninstalled with RestartRequired; anything
         else is Failed.
    The installed check comes first, so an app that is not there is reported as not installed.
.PARAMETER App
    A validated catalog entry (Test-AppDefinitions).
.PARAMETER WhatIf
    Dry run: steps 1 to 4 run (they only read), and an app that would be removed is reported as
    Uninstalled without running winget uninstall.
.OUTPUTS
    [hashtable] @{
        Status          = 'Uninstalled' | 'Skipped' | 'Failed'
        SkipReason      = 'NotInstalled' | 'HostsThisRun' | 'NotApplicable' when Skipped
        FailureReason   = 'CheckTimeout' | 'CheckLaunchFailed' | 'CheckFailed' |
                          'UninstallLaunchFailed' | 'UninstallTimeout' | 'UninstallFailed' when Failed
        Reason          = the text shown in parentheses after the app id
        ExitCode        = the exit code of the winget call that decided a failure, or $null
        RestartRequired = True when the app's uninstaller said a restart finishes removing it
    }
#>
function Uninstall-CatalogApp {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $id = $App.name
    $result = @{ Status = 'Failed'; SkipReason = $null; FailureReason = $null; Reason = $null; ExitCode = $null; RestartRequired = $false }

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck
    $check = Test-WingetPackageInstalled -PackageId $id -TimeoutSeconds $checkTimeoutSeconds
    if ($check.TimedOut) {
        $result.FailureReason = 'CheckTimeout'
        $result.Reason = "could not check whether it is installed: 'winget list' did not answer within $checkTimeoutSeconds seconds"
        return $result
    }
    if ($check.LaunchFailed) {
        $result.FailureReason = 'CheckLaunchFailed'
        $result.Reason = 'could not check whether it is installed: winget could not be started ({0})' -f "$($check.LaunchError)".Trim().TrimEnd('.')
        return $result
    }
    if ($check.CheckFailed) {
        $result.FailureReason = 'CheckFailed'
        $result.ExitCode = $check.ExitCode
        $result.Reason = "could not check whether it is installed: 'winget list' failed with {0}" -f (Format-WingetExitCode -ExitCode ([int]$check.ExitCode))
        return $result
    }
    if (-not $check.Installed) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'NotInstalled'
        $result.Reason = 'not installed'
        return $result
    }

    $hostReason = Get-HostingShellSkipReason -PackageId $id
    if ($hostReason) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'HostsThisRun'
        $result.Reason = $hostReason
        return $result
    }

    # The installer's single applicability rule (review finding P3-34), so a condition with no
    # answer - one that throws, or writes an error and returns nothing - fails open here as well.
    if (-not (Test-AppApplicability -App $App -Purpose Uninstall)) {
        $conditionText = Get-AppNotApplicableReason -App $App
        $result.Status = 'Skipped'
        $result.SkipReason = 'NotApplicable'
        $result.Reason = "not applicable: $conditionText"
        return $result
    }

    if ($WhatIf) {
        $result.Status = 'Uninstalled'
        return $result
    }

    Write-Info "Uninstalling: $id"
    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetUninstall
    $run = Invoke-WingetProcess -ArgumentList @('uninstall', '--exact', '--id', $id, '--silent', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $timeoutSeconds
    if ($run.LaunchFailed) {
        $result.FailureReason = 'UninstallLaunchFailed'
        $result.Reason = 'winget could not be started ({0})' -f "$($run.LaunchError)".Trim().TrimEnd('.')
        return $result
    }
    if ($run.TimedOut) {
        $result.FailureReason = 'UninstallTimeout'
        $result.Reason = "'winget uninstall' did not finish within {0} minutes and was stopped" -f [Math]::Round($timeoutSeconds / 60)
        return $result
    }

    $restartRequired = Test-WingetUninstallRestartRequiredResult -ExitCode $run.ExitCode -Output $run.Output
    if ($run.ExitCode -eq 0 -or $restartRequired) {
        $result.Status = 'Uninstalled'
        $result.RestartRequired = [bool]$restartRequired
        return $result
    }

    $result.FailureReason = 'UninstallFailed'
    $result.ExitCode = $run.ExitCode
    $result.Reason = "'winget uninstall' exited with {0}" -f (Format-WingetExitCode -ExitCode ([int]$run.ExitCode))
    if ($run.LogPath -and (Test-Path -LiteralPath $run.LogPath)) {
        $result.Reason += "; uninstaller log: $($run.LogPath)"
    }
    return $result
}
