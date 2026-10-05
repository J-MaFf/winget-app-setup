<#
.SYNOPSIS
    Uninstalls the curated apps and the automatic updates the installer set up, and returns an exit
    code.
.DESCRIPTION
    The body of winget-app-uninstall.ps1, which runs it once elevated. It reuses the installer's
    pieces:
      1. The app list is validated with Test-AppDefinitions (exit code 3).
      2. winget is set up as Invoke-WingetInstall does it, with Initialize-Winget for the account
         Get-InstallAccountContext decides. When winget still cannot be used, nothing is removed
         and the run returns 2: without winget the uninstaller cannot tell what is installed, and
         removing Winget-AutoUpdate anyway would leave every app without updates.
      3. Each app goes through Uninstall-CatalogApp.
      4. Once winget no longer lists Windows Terminal, the default terminal setting that still names
         it is removed (Reset-WindowsTerminalDelegation).
      5. Winget-AutoUpdate (and the legacy scheduled-update task) goes last, and only when no app
         failed: an app still on the machine keeps its updates. That is said only when
         Winget-AutoUpdate is installed.
.PARAMETER WhatIf
    Dry run: the read-only checks run and the summary shows what a real run would remove. Nothing is
    uninstalled or changed, and nothing is installed (the winget setup only checks).
.PARAMETER Apps
    The app definitions to remove. Default: Get-DefaultAppCatalog, the installer's list.
.OUTPUTS
    [int] The exit code. The function never ends the process; winget-app-uninstall.ps1 exits with
    the returned code.
.NOTES
    Exit codes: 0 = every app was removed, was not installed, or was left alone on purpose, and
    Winget-AutoUpdate was removed or was not installed; 3010 = the same, and a restart finishes a
    removal (an uninstaller returned 3010 or 1641); 1 = an app could not be removed or checked
    (Winget-AutoUpdate is then kept), or Winget-AutoUpdate could not be removed; 2 = winget cannot be
    started for this account, or Group Policy turns it off, so nothing was removed; 3 = the app list
    has invalid entries or is empty. 1 ranks above 3010. A dry run returns 0 when winget cannot be
    started, and never 3010. winget-app-uninstall.ps1 adds 4 (not elevated, and the UAC prompt was
    declined or could not be shown) and 5 (an unexpected error, a run without a script file, or a
    file that changed before its elevated run).
#>
function Invoke-WingetUninstall {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [array]$Apps = (Get-DefaultAppCatalog)
    )

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

    # winget first, set up as the installer does it, for the account the run decides once. As SYSTEM
    # Initialize-Winget uses the machine-wide winget.exe (a stale path from an earlier run in this
    # session is dropped first) and runs no account fix. When winget cannot be used, nothing is
    # removed. A dry run only probes.
    $script:MachineWingetPath = $null
    $account = Get-InstallAccountContext
    $winget = Initialize-Winget -WhatIf:$WhatIf -AccountContext $account
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable) {
        # Group Policy (review finding P3-30) is not fixed by another account or by installing App
        # Installer: Initialize-Winget has named the policy, and this says what that means here.
        $policyBlocked = $winget.Diagnosis -eq 'PolicyBlocked'
        if ($WhatIf) {
            if ($policyBlocked) {
                Write-Info '[DRY-RUN] Group Policy on this PC blocks winget (see above). A real run would stop with exit code 2 before removing anything. Without winget this preview cannot tell which apps are installed, so it stops here.'
            }
            else {
                Write-Info '[DRY-RUN] winget cannot be started for this account yet. A real run would try to set it up (see above) and, if winget still could not start, stop with exit code 2 before removing anything. Without winget this preview cannot tell which apps are installed, so it stops here.'
            }
            return 0
        }
        if ($policyBlocked) {
            $message = 'Group Policy on this PC blocks winget (see above), so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed.'
        }
        else {
            $message = 'winget cannot be started for this account, so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed.'
        }
        if (Test-WauInstalled) {
            $message += ' Winget-AutoUpdate was left in place, so the apps keep getting updates.'
        }
        if ($policyBlocked) {
            $message += ' Run the uninstaller again once the policy allows winget.'
        }
        else {
            $message += ' Run the uninstaller from an account where winget works (for example the signed-in user, elevated), or install App Installer from https://aka.ms/getwinget, then run it again.'
        }
        Write-ErrorMessage $message
        return 2
    }

    Write-Info 'Uninstalling the following apps:'
    foreach ($app in $apps) {
        Write-Info $app.name
    }

    $uninstalledApps = @()
    $skippedApps = @()
    $failedApps = @()
    # What a restart finishes removing: apps, and Winget-AutoUpdate (exit code 3010).
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
    # still on the machine keeps its updater (P2-19). Said only when Winget-AutoUpdate is there.
    $autoUpdatesKept = $false
    $autoUpdatesRemovalFailed = $false
    if ($failedApps.Count -gt 0) {
        $autoUpdatesKept = Test-WauInstalled
        if ($autoUpdatesKept) {
            $dryRunPrefix = ''
            if ($WhatIf) {
                $dryRunPrefix = '[DRY-RUN] '
            }
            Write-WarningMessage ('{0}Winget-AutoUpdate is kept: {1} app(s) could not be uninstalled, and it keeps them updated. Fix the failures above and run the uninstaller again to remove it.' -f $dryRunPrefix, $failedApps.Count)
        }
    }
    else {
        Write-Info 'Removing automatic-update components...'
        try {
            [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)
            $autoUpdateRemoval = Uninstall-WingetAutoUpdate -WhatIf:$WhatIf
            if (-not ($autoUpdateRemoval -and $autoUpdateRemoval.Succeeded)) {
                $autoUpdatesRemovalFailed = $true
            }
            elseif ($autoUpdateRemoval.RestartRequired) {
                $restartRequiredApps += 'Winget-AutoUpdate'
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
    Write-Table -Headers $headers -Rows $rows -Title 'Uninstallation Summary'
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

    # 1 > 3010 > 0, as in the installer (Get-InstallerExitCode): 3010 tells an RMM tool that the
    # removal succeeded and a restart finishes it.
    if ($failedApps.Count -gt 0 -or $autoUpdatesRemovalFailed) {
        return 1
    }
    if ($restartRequiredApps.Count -gt 0) {
        return 3010
    }
    return 0
}
