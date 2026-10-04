<#
.SYNOPSIS
    Uninstalls the curated apps and the automatic updates the installer set up, and returns an exit
    code.
.DESCRIPTION
    The body of winget-app-uninstall.ps1 (review findings P2-19 and P3-18), which runs it after it
    has made sure it is elevated. It reuses the installer's pieces rather than its own copies:
      1. The app list is validated with Test-AppDefinitions, as the installer does (exit code 3).
      2. winget is set up the way Invoke-WingetInstall does it, with Initialize-Winget (review
         finding P3-25): App Installer's Group Policy, `winget --version`, the account fixes
         (registering App Installer, then Repair-WinGetPackageManager, whose module is installed
         only then) and the winget source. When winget still cannot be used, nothing is removed
         and the run returns 2: without winget the uninstaller cannot tell which apps are installed,
         and removing Winget-AutoUpdate anyway would leave every app on the machine without
         updates. It used to report every app as "not installed", remove Winget-AutoUpdate and exit
         0, which is what an admin account with no winget of its own (cross-user elevation) or
         SYSTEM got.
      3. Each app goes through Uninstall-CatalogApp: a check winget could not answer is a failure,
         not "not installed"; the shells this run depends on are kept (Get-HostingShellSkipReason);
         the catalog conditions are honoured; winget uninstall runs with --silent under a time
         limit.
      4. Once winget no longer lists Windows Terminal (removed now, or not installed), the
         default-terminal setting that still names it is removed (Reset-WindowsTerminalDelegation).
      5. Winget-AutoUpdate (and the legacy scheduled-update task) is removed last, and only when no
         app failed: an app that could not be removed is still on the machine and keeps its
         updates until a later run removes it.
.PARAMETER WhatIf
    Dry run: the read-only checks run and the summary shows what a real run would remove. Nothing is
    uninstalled or changed, and nothing is installed (the winget setup only checks).
.PARAMETER NonInteractive
    For unattended runs: no summary grid-view window. Also turned on by
    $env:WINGET_APP_SETUP_NONINTERACTIVE and when the session is not interactive
    (Test-EffectiveNonInteractive).
.PARAMETER Apps
    The app definitions to remove. Default: Get-DefaultAppCatalog, the installer's list.
.OUTPUTS
    [int] The exit code. The function never ends the process; winget-app-uninstall.ps1 exits with
    the returned code.
.NOTES
    Exit codes: 0 = every app was removed, was not installed, or was left alone on purpose (a shell
    this run depends on, or an app whose catalog condition does not hold here), and
    Winget-AutoUpdate was removed or was not installed; 1 = an app could not be removed or checked
    (Winget-AutoUpdate is then kept), or Winget-AutoUpdate could not be removed; 2 = winget cannot
    be started for this account, so nothing was removed; 3 = the app list has invalid entries or is
    empty. A dry run returns 0 when winget cannot be started. winget-app-uninstall.ps1 adds 4 (not
    elevated and the UAC prompt was declined or could not be shown) and 5 (an unexpected error).
#>
function Invoke-WingetUninstall {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [array]$Apps = (Get-DefaultAppCatalog)
    )

    $effectiveNonInteractive = Test-EffectiveNonInteractive -NonInteractive:$NonInteractive

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'Nothing will be uninstalled or changed. This is a preview of what a real run would do.'
        Write-Host ''
    }

    if (@($Apps).Count -eq 0) {
        Write-ErrorMessage 'The app list is empty, so there is nothing to uninstall.'
        return 3
    }
    $validationResult = Test-AppDefinitions -Apps $Apps
    foreach ($validationWarning in $validationResult.Warnings) {
        Write-WarningMessage $validationWarning
    }
    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'The app list has invalid entries, so nothing was uninstalled. Fix them and run the uninstaller again.'
        return 3
    }
    $apps = @($validationResult.ValidApps)

    # winget first, set up as the installer does it (review finding P2-19): Initialize-Winget, the
    # installer's one probe, classify and fix step (review finding P3-25). It says why when winget
    # cannot be used (not startable, or turned off by Group Policy); this run then removes nothing.
    # A dry run only probes (-WhatIf).
    $winget = Initialize-Winget -WhatIf:$WhatIf
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] winget cannot be started for this account yet. A real run would try to set it up (see above) and, if winget still could not start, stop with exit code 2 before removing anything. Without winget this preview cannot tell which apps are installed, so it stops here.'
            return 0
        }
        Write-ErrorMessage 'winget cannot be started for this account, so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed. Winget-AutoUpdate was left in place, so the apps keep getting updates. Run the uninstaller from an account where winget works (for example the signed-in user, elevated), or install App Installer from https://aka.ms/getwinget, then run it again.'
        return 2
    }

    Write-Info 'Uninstalling the following apps:'
    foreach ($app in $apps) {
        Write-Info $app.name
    }

    $uninstalledApps = @()
    $skippedApps = @()
    $failedApps = @()
    $restartRequiredApps = @()
    $terminalGone = $false
    foreach ($app in $apps) {
        try {
            $outcome = Uninstall-CatalogApp -App $app -WhatIf:$WhatIf
            if ($app.name -eq 'Microsoft.WindowsTerminal') {
                $terminalGone = ($outcome.Status -eq 'Uninstalled' -and -not $WhatIf) -or ($outcome.SkipReason -eq 'NotInstalled')
            }
            switch ($outcome.Status) {
                'Uninstalled' {
                    if ($WhatIf) {
                        Write-Info "[DRY-RUN] Would uninstall: $($app.name)"
                    }
                    elseif ($outcome.RestartRequired) {
                        Write-Success "Successfully uninstalled: $($app.name) (a restart finishes removing it)"
                        $restartRequiredApps += $app.name
                    }
                    else {
                        Write-Success "Successfully uninstalled: $($app.name)"
                    }
                    $uninstalledApps += $app.name
                }
                'Skipped' {
                    Write-WarningMessage "Skipping: $($app.name) ($($outcome.Reason))"
                    $skippedApps += $app.name
                }
                default {
                    Write-ErrorMessage "Failed to uninstall: $($app.name) ($($outcome.Reason))."
                    $failedApps += @{ Name = $app.name; Reason = [string]$outcome.Reason }
                }
            }
        }
        catch {
            Write-ErrorMessage "Failed to uninstall: $($app.name). Error: $_"
            $failedApps += @{ Name = $app.name; Reason = "Unexpected error: $_" }
        }
    }

    # The default-terminal setting the installer writes, once winget says Windows Terminal is gone
    # (removed now, or earlier), so it no longer names a terminal that is not there.
    # Reset-WindowsTerminalDelegation checks the package itself as well, so both have to agree.
    if ($terminalGone) {
        try {
            [void](Reset-WindowsTerminalDelegation -WhatIf:$WhatIf)
        }
        catch {
            Write-WarningMessage "Could not check the default terminal application setting: $_"
        }
    }

    # Automatic updates last, and only when every app is gone or was left alone on purpose: an app
    # that could not be removed (or checked) is still on the machine, and removing its updater would
    # leave it without updates (review finding P2-19).
    $autoUpdatesKept = $false
    $autoUpdatesRemovalFailed = $false
    if ($failedApps.Count -gt 0) {
        $autoUpdatesKept = $true
        $dryRunPrefix = ''
        if ($WhatIf) {
            $dryRunPrefix = '[DRY-RUN] '
        }
        Write-WarningMessage ('{0}Winget-AutoUpdate is kept: {1} app(s) could not be uninstalled, and it keeps them updated. Fix the failures above and run the uninstaller again to remove it.' -f $dryRunPrefix, $failedApps.Count)
    }
    else {
        Write-Info 'Removing automatic-update components...'
        try {
            [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)
            if (-not (Uninstall-WingetAutoUpdate -WhatIf:$WhatIf)) {
                $autoUpdatesRemovalFailed = $true
            }
        }
        catch {
            Write-ErrorMessage "Removing automatic updates failed unexpectedly: $_"
            $autoUpdatesRemovalFailed = $true
        }
    }

    if ($WhatIf) {
        Write-Host ''
        Write-Info '=== DRY-RUN SUMMARY ==='
        Write-Info 'A real run would do the following:'
    }
    else {
        Write-Info 'Summary:'
    }

    $headers = @('Status', 'Apps')
    $rows = @()
    $appList = Format-AppList -AppArray $uninstalledApps
    if ($appList) {
        $rows += , @('Uninstalled', $appList)
    }
    $appList = Format-AppList -AppArray $skippedApps
    if ($appList) {
        $rows += , @('Skipped', $appList)
    }
    $appList = Format-AppList -AppArray @($failedApps | ForEach-Object { $_.Name })
    if ($appList) {
        $rows += , @('Failed', $appList)
    }
    # The grid view only when someone is there to close it; the text table prints either way.
    Write-Table -Headers $headers -Rows $rows -AutoGridView (-not $effectiveNonInteractive) -Title 'Uninstallation Summary'
    Write-FailedAppsSummary -FailedApps $failedApps -Title 'Failed Uninstalls'

    if ($autoUpdatesKept) {
        Write-WarningMessage 'Auto-updates: KEPT - Winget-AutoUpdate stays until every app is removed (see above).'
    }
    elseif ($autoUpdatesRemovalFailed) {
        Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be removed (see above). Run the uninstaller again.'
    }
    if ($restartRequiredApps.Count -gt 0) {
        Write-WarningMessage ('Restart: REQUIRED to finish removing {0}.' -f ($restartRequiredApps -join ', '))
    }

    if ($failedApps.Count -gt 0 -or $autoUpdatesRemovalFailed) {
        return 1
    }
    return 0
}
