# The uninstaller's per-app step (review findings P2-19 and P3-18). winget-app-uninstall.ps1 used
# to decide "installed" from `winget list`'s exit code alone, so a winget that could not be started
# (an admin account with no winget of its own, SYSTEM) read as "not installed" for every app; it
# ran a bare `winget uninstall` with no time limit; and it removed every catalog app, whatever its
# condition, the PowerShell 7 and Windows Terminal it was running in included. Runs under Windows
# PowerShell 5.1 too: the uninstaller's elevated relaunch is System32's powershell.exe.

<#
.SYNOPSIS
    Returns why the uninstaller must not remove a shell it is running in, or $null.
.DESCRIPTION
    Removing the shell that runs this script, or the terminal that hosts its window, ends the run
    part-way: no summary, Winget-AutoUpdate left as it was, and no exit code to read (review finding
    P3-18). So, by default, two catalog apps are kept when they host this run:
      - Microsoft.PowerShell when this script runs in PowerShell 7 (Get-PowerShellEdition 'Core').
        Started from a window that is not elevated, the uninstaller relaunches itself in Windows
        PowerShell, which can remove PowerShell 7.
      - Microsoft.WindowsTerminal when Windows Terminal hosts this session
        (Test-WindowsTerminalHostsCurrentSession: inside a Windows Terminal tab, below a
        WindowsTerminal.exe process, or the default terminal application is set to Windows Terminal,
        which hands every new console window to it).
    The reason says how to remove the app instead. Not detected: Windows' automatic choice of
    default terminal ('Let Windows decide', which on Windows 11 picks Windows Terminal when it is
    installed). A window handed to Windows Terminal that way carries none of the signals above, so
    there the uninstaller can remove the Windows Terminal hosting its own window: to remove Windows
    Terminal on such a machine, run the uninstaller from a Windows Console Host window.
.PARAMETER PackageId
    The catalog app's winget package id.
.RETURNS
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
    winget's uninstall flow has no restart result of its own, unlike its install flow (which
    Test-WingetRestartRequiredResult reads). Any non-zero return from the app's uninstaller,
    restart codes included, ends `winget uninstall` with 0x8A150030
    (APPINSTALLER_CLI_ERROR_EXEC_UNINSTALL_COMMAND_FAILED), after winget prints the uninstaller's
    own return code: 'Uninstall failed with exit code: 3010' (Workflows/UninstallFlow.cpp,
    ReportUninstallerResult). For an MSI, --silent runs `msiexec /x <code> /quiet /norestart`, which
    returns 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) when files still in use are removed at the next
    restart, and 1641 (ERROR_SUCCESS_REBOOT_INITIATED) when the uninstaller started a restart: both
    are successes. So the result is True for exit 0x8A150030 whose output carries 3010 or 1641 as a
    number of its own. The message around the number is translated on other display languages, so
    only the number is matched; a line with a backslash (winget's 'Installer log is available at'
    path) is not read.
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.PARAMETER Output
    What winget printed (Invoke-WingetProcess's Output).
.RETURNS
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
      1. Installed check: Test-WingetPackageInstalled under the per-app time limit
         (WingetListCheck). Only a `winget list` that answered counts. A winget that could not be
         started (CheckLaunchFailed), a check that ran out of time (CheckTimeout) or a `winget list`
         that ran and failed (CheckFailed) is a failure, never "not installed" (review finding
         P2-19): that is what made an admin account with no winget of its own report every app as
         not installed while all of them stayed on the machine.
      2. Not installed: Skipped, NotInstalled.
      3. A shell this run depends on (Get-HostingShellSkipReason): Skipped, HostsThisRun.
      4. The app's catalog condition, with the installer's rule (review finding P3-18): falsy means
         this tool does not manage the app on this machine (Dell Command Update on other hardware),
         so it is Skipped, NotApplicable, and left alone. A condition that throws is warned about
         and treated as applicable, as in the installer.
      5. `winget uninstall --exact --id <id> --silent --accept-source-agreements
         --disable-interactivity` through Invoke-WingetProcess, under the WingetUninstall time limit
         (review finding P3-18): output echoed into the console and the transcript, the installer's
         log written next to it when there is a run log folder, and the process stopped when the
         limit runs out. --silent always: without it winget runs an app's interactive uninstall
         command, which can wait for a click nobody makes. Exit 0 is Uninstalled. An uninstaller
         that returned 3010 or 1641, which winget reports as a failure
         (Test-WingetUninstallRestartRequiredResult), is Uninstalled with RestartRequired. Anything
         else is Failed.
    The installed check comes first, unlike the install pipeline's condition-first order, so an app
    that is not on the machine is reported as not installed, not as a shell or an app this tool
    does not manage.
.PARAMETER App
    A validated catalog entry (Test-AppDefinitions): @{ name = '<winget package id>' }, with the
    optional 'condition' and 'conditionDescription' entries.
.PARAMETER WhatIf
    Dry run: steps 1 to 4 run (they only read), and an app that would be removed comes back as
    Uninstalled without winget uninstall being run.
.RETURNS
    [hashtable] @{
        Status          = 'Uninstalled' | 'Skipped' | 'Failed'
        SkipReason      = 'NotInstalled' | 'HostsThisRun' | 'NotApplicable' when Skipped
        FailureReason   = 'CheckTimeout' | 'CheckLaunchFailed' | 'CheckFailed' |
                          'UninstallLaunchFailed' | 'UninstallTimeout' | 'UninstallFailed' when Failed
        Reason          = the text the caller shows in parentheses after the app id
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

    if ($App.condition) {
        $conditionMet = $true
        try {
            $conditionMet = [bool](& $App.condition)
        }
        catch {
            Write-WarningMessage "Condition for $id failed to evaluate ($($_.Exception.Message)); treating as applicable."
        }
        if (-not $conditionMet) {
            $conditionText = 'condition not met'
            if ($App.conditionDescription) {
                $conditionText = $App.conditionDescription
            }
            $result.Status = 'Skipped'
            $result.SkipReason = 'NotApplicable'
            $result.Reason = "not applicable: $conditionText"
            return $result
        }
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
