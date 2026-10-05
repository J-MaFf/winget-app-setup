<#
.SYNOPSIS
    Returns the pinned Winget-AutoUpdate (WAU) release metadata.
.DESCRIPTION
    A pinned, SHA256-checked release with WAU's self-update off, so no upstream change reaches
    managed PCs unreviewed (issue #168). Change all fields together (check the SHA256 against the
    winget-pkgs manifest), and re-check the framework the newest winget needs
    (Get-WindowsAppRuntimeRequirement) against Get-WindowsAppRuntimePin: WAU installs the newest
    winget, so that framework decides whether WAU is safe.
#>
function Get-WauPin {
    return @{
        Version     = '2.12.0'
        MsiUrl      = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi'
        Sha256      = 'F5AB2303FDF82FBFCB2248CCA4F96479FE17D74584A528B0F86B3DBE9F9E9718'
        ProductCode = '{FB0EB14E-95AC-45D7-A951-432316FFCBD4}'
    }
}

<#
.SYNOPSIS
    Returns true when Winget-AutoUpdate appears to be installed on this machine.
.DESCRIPTION
    Its HKLM configuration key or its '\WAU\Winget-AutoUpdate' task, so an existing (possibly
    customized) WAU is left alone. Whether it will run is Get-WauTaskHealth's question. The task is
    read with -ErrorAction SilentlyContinue: no task is the normal answer, and a caught terminating
    error still shows in the transcript (P3-38).
#>
function Test-WauInstalled {
    if (Test-Path 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate') {
        return $true
    }
    try {
        if (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    catch {
        # The task scheduler cmdlets could not run at all.
    }
    return $false
}

<#
.SYNOPSIS
    Installs (or upgrades) and configures Winget-AutoUpdate (WAU) to keep installed apps current.
.DESCRIPTION
    Downloads the pinned WAU MSI into a staging folder only SYSTEM and Administrators can change,
    checked before the download (issue #186, P2-21), checks its SHA256 from a handle it keeps open
    until msiexec has finished, and installs it silently with this configuration (issue #168):
      - Weekly, Tuesdays at 02:00, and not at logon (UPDATESATLOGON=0), where a run collides with a
        technician signing in to run this installer again. WAU runs as SYSTEM for machine-scope
        packages and in the user's session (USERCONTEXT=1) for user-scope ones.
      - DISABLEWAUAUTOUPDATE=1, so WAU stays on the pin; full notifications; not on metered
        connections.
      - Only when the Windows App Runtime framework the newest winget needs is present
        (Get-WindowsAppRuntimeStatus, with the requirement read from the latest winget release):
        every WAU run provisions the newest winget, which is unusable without it. When it is
        missing, the pinned framework is installed for all users first
        (Install-WindowsAppRuntimeFramework); WAU is skipped (or reported AT RISK) only when that
        is not possible or fails. A check that could not run installs nothing and goes ahead.
    A WAU older than the pin is upgraded in place by the pinned MSI, which also re-applies this
    configuration (issue #186); an equal, newer or unreadable version is left alone, apart from
    removing its at-logon trigger (Disable-WauLogonTrigger) and reporting a missing framework.

    WAU counts as set up only when its \WAU\Winget-AutoUpdate task exists, is enabled and has an
    enabled trigger (Get-WauTaskHealth, P3-36). The task's state and the end of WAU's log go to the
    transcript (Write-WauTaskHealth), and msiexec's verbose log to the logs folder. Best-effort: a
    failure warns and returns Failed.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, when msiexec exits 1618 (Windows Installer busy): it waits for that
    installation (Wait-WindowsInstallerIdle) and retries, up to 3 times. Invoke-WingetInstall passes
    what is left of the run's budget. Default 600. 0: 1618 fails at once.
.OUTPUTS
    [pscustomobject] with:
      - Status:  'Configured' (installed or upgraded this run), 'AlreadyPresent' (left as-is),
                 'Unhealthy' (installed, this run or before, but its scheduled task is missing,
                 disabled, has no enabled trigger or could not be checked), 'FrameworkMissing'
                 (not installed: WindowsAppRuntime 1.8 is missing), 'Failed', or 'DryRun' (under
                 -WhatIf). Configured and AlreadyPresent mean the task was found ready to run.
      - Version: the pinned version for Configured/Failed/DryRun/FrameworkMissing, and for
                 Unhealthy after an install this run; the installed version (or $null when
                 unreadable) for AlreadyPresent, and for Unhealthy when WAU was already there.
      - Problem: for Unhealthy, what is wrong with the task (Get-WauTaskHealth's Problem).
      - CheckFailed: for Unhealthy, $true when the task could not be checked at all, so whether WAU
                 will run is unknown; the messages then point to Task Scheduler, not a reinstall.
      - FrameworkMissing: $true when no suitable framework is there, even after trying to install
                 it (on AlreadyPresent this means the existing WAU may break winget on its next run).
      - FrameworkInstallError: with FrameworkMissing, why the pinned framework could not be
                 installed (Install-WindowsAppRuntimeFramework's Reason), or $null.
      - FrameworkName: for AlreadyPresent, Unhealthy and FrameworkMissing, the framework winget
                 needs (e.g. 'Microsoft.WindowsAppRuntime.1.8'; several are joined with ' and '),
                 for the summary's messages. With FrameworkMissing, only the ones this PC lacks.
      - RestartRequired: $true when msiexec returned 3010: WAU is installed, and a restart finishes
                 it.
#>
function Install-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600
    )

    $pin = Get-WauPin

    if ($WhatIf) {
        # Read-only probe, so the preview matches what a real run would do on this machine.
        $runtimePin = Get-WindowsAppRuntimePin
        $runtimePreview = "If Microsoft.WindowsAppRuntime.1.8 is missing, would first install the pinned Windows App Runtime $($runtimePin.Release) (framework $($runtimePin.FrameworkVersion)) for all users from NuGet.org."
        if (Test-WauInstalled) {
            Write-Info "[DRY-RUN] Winget-AutoUpdate is already installed: would leave it in place and remove its at-logon trigger if it has one (WAU_UpdatesAtLogon = 0). $runtimePreview"
        }
        else {
            Write-Info "[DRY-RUN] Would install Winget-AutoUpdate $($pin.Version) (weekly updates on Tuesdays at 02:00, not at logon, Full notifications, self-update disabled). $runtimePreview"
        }
        return [pscustomobject]@{ Status = 'DryRun'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }

    # What the winget release WAU installs needs, read from that release
    # (the built-in Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 when it cannot be read).
    $requirement = Get-WindowsAppRuntimeRequirement
    $frameworkName = (@($requirement.Frameworks) | ForEach-Object { $_.Name }) -join ' and '
    # '1.8' for the advice below; '1.8 and 2' when winget needs two.
    $frameworkRelease = $frameworkName -replace 'Microsoft\.WindowsAppRuntime\.', ''
    $framework = Get-WindowsAppRuntimeStatus -Requirement $requirement
    $frameworkInstallError = $null
    if ($null -eq $framework.Present) {
        # A failed query is not evidence the framework is missing; keep the previous behavior, and
        # install nothing on an unknown answer.
        Write-WarningMessage "Could not check for $frameworkName ($($framework.Detail)); continuing with Winget-AutoUpdate."
    }
    elseif (-not $framework.Present) {
        # Install the pinned framework for all users, then go on with the
        # status it re-checked. Also on a machine that already has WAU, which is then no longer
        # at risk. It installs nothing when the pin does not meet what this PC lacks (item 32).
        $missingFrameworks = @($requirement.Frameworks)
        if ($framework.Missing) {
            $missingFrameworks = @($framework.Missing)
        }
        $frameworkInstall = Install-WindowsAppRuntimeFramework -Requirement $requirement -MissingFrameworks $missingFrameworks
        if ($frameworkInstall.Installed) {
            $framework = $frameworkInstall.Status
        }
        else {
            $frameworkInstallError = $frameworkInstall.Reason
        }
    }
    $frameworkMissing = $framework.Present -eq $false
    if ($frameworkMissing -and $framework.Missing) {
        # Name only what this PC lacks, not a framework of the requirement it already has.
        $frameworkName = (@($framework.Missing) | ForEach-Object { $_.Name }) -join ' and '
        $frameworkRelease = $frameworkName -replace 'Microsoft\.WindowsAppRuntime\.', ''
    }
    # For the messages below. Install-WindowsAppRuntimeFramework has just printed why, and the
    # summary repeats it.
    $frameworkInstallNote = ''
    if ($frameworkInstallError) {
        $frameworkInstallNote = " The installer could not install it (see 'Windows App Runtime: NOT INSTALLED' above)."
    }

    if (Test-WauInstalled) {
        $installed = Get-InstalledWauInfo
        if ($installed.Version -and $installed.Version -lt [version]$pin.Version -and -not $frameworkMissing) {
            Write-Info "Winget-AutoUpdate v$($installed.Version) is older than the pinned v$($pin.Version); upgrading in place..."
        }
        else {
            $versionLabel = if ($installed.Version) { "v$($installed.Version)" } else { 'version unknown' }
            Write-Success "Winget-AutoUpdate is already installed ($versionLabel); leaving its configuration unchanged apart from the at-logon trigger."
            [void](Disable-WauLogonTrigger)
            if ($frameworkMissing) {
                Write-ErrorMessage "Winget-AutoUpdate is installed, but $frameworkName is missing ($($framework.Detail)).$frameworkInstallNote Its next update run may install a winget that cannot start and leave winget unusable. Install the Windows App Runtime $frameworkRelease (update App Installer from the Microsoft Store, or install Microsoft's Windows App SDK $frameworkRelease runtime), or uninstall Winget-AutoUpdate on this machine."
            }
            # WAU's registry key says it is installed, not that it will run (review finding P3-36).
            $health = Get-WauTaskHealth
            Write-WauTaskHealth -Health $health
            if (-not $health.Healthy) {
                if ($health.CheckFailed) {
                    # An unknown state: reinstalling would not fix a task scheduler that cannot be queried.
                    Write-ErrorMessage "Winget-AutoUpdate is installed, but $($health.Problem), so it is not known whether apps will update automatically. Check the task \WAU\Winget-AutoUpdate in Task Scheduler; if it is missing, disabled or has no enabled trigger, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer."
                }
                else {
                    Write-ErrorMessage "Winget-AutoUpdate is installed, but $($health.Problem), so apps will not update automatically. To set it up again, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer."
                }
                return [pscustomobject]@{ Status = 'Unhealthy'; Version = $installed.Version; FrameworkMissing = $frameworkMissing; FrameworkInstallError = $frameworkInstallError; FrameworkName = $frameworkName; RestartRequired = $false; Problem = $health.Problem; CheckFailed = [bool]$health.CheckFailed }
            }
            return [pscustomobject]@{ Status = 'AlreadyPresent'; Version = $installed.Version; FrameworkMissing = $frameworkMissing; FrameworkInstallError = $frameworkInstallError; FrameworkName = $frameworkName; RestartRequired = $false }
        }
    }
    elseif (-not $frameworkMissing) {
        Write-Info "Setting up automatic app updates via Winget-AutoUpdate $($pin.Version)..."
    }

    if ($frameworkMissing) {
        Write-ErrorMessage "Winget-AutoUpdate was NOT installed: $frameworkName is missing ($($framework.Detail)).$frameworkInstallNote Every WAU update run installs the newest winget, which needs that framework, so WAU would leave winget unusable here. Install the Windows App Runtime $frameworkRelease (update App Installer from the Microsoft Store, or install Microsoft's Windows App SDK $frameworkRelease runtime), then re-run this installer."
        return [pscustomobject]@{ Status = 'FrameworkMissing'; Version = $pin.Version; FrameworkMissing = $true; FrameworkInstallError = $frameworkInstallError; FrameworkName = $frameworkName; RestartRequired = $false }
    }

    $stagingDir = $null
    $msiStream = $null
    try {
        # A per-run folder only SYSTEM and Administrators can change, not a predictable %TEMP% path
        # (issue #186); nothing is downloaded unless that is verified (P2-21).
        try {
            $stagingDir = New-WauStagingDirectory
        }
        catch {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
                Write-ErrorMessage "Winget-AutoUpdate was NOT installed: its download folder could not be limited to SYSTEM and Administrators, so its installer could have been swapped before it ran. $_ To reset the folder, run in an elevated prompt: takeown /f `"$baseDir`" /a, then icacls `"$baseDir`" /reset, and re-run this installer."
            }
            else {
                # Not an access-list problem (a file already named winget-app-setup, a full disk,
                # icacls.exe not starting): resetting the folder's owner would not help.
                Write-ErrorMessage "Winget-AutoUpdate was NOT installed: its download folder in '$baseDir' could not be set up: $_"
            }
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }
        $msiPath = Join-Path $stagingDir "WAU-$($pin.Version).msi"
        # Time-limited (review finding P2-5): without a limit, a download that connects and then
        # stalls waits for ever.
        $downloadTimeouts = Get-WebDownloadTimeoutParameters
        Invoke-WebRequest @downloadTimeouts -Uri $pin.MsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

        # Held open, with read-only sharing, from the hash until msiexec has finished (review
        # finding P2-21): while it is open the file cannot be overwritten, renamed or deleted, so
        # msiexec installs exactly the bytes hashed here. Disposed in finally, before the cleanup.
        $msiStream = Open-ReadLockedFile -Path $msiPath
        $actualHash = (Get-FileHash -InputStream $msiStream -Algorithm SHA256).Hash
        if ($actualHash -ne $pin.Sha256) {
            Write-ErrorMessage "Winget-AutoUpdate MSI hash mismatch (expected $($pin.Sha256), got $actualHash). Skipping installation."
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        # The configuration as MSI properties. No RUN_WAU=YES: an immediate WAU run re-provisions App
        # Installer, resets winget's source and upgrades apps while this installer is still running
        # (the #279/#284 winget wedge and the #283 console stop); WAU's schedule runs the first pass.
        # UPDATESATLOGON=0 is stored as WAU_UpdatesAtLogon, which later MSI upgrades read back.
        $msiArgs = "/i `"$msiPath`" /qn /norestart UPDATESATLOGON=0 USERCONTEXT=1 DISABLEWAUAUTOUPDATE=1 UPDATESINTERVAL=Weekly UPDATESATTIME=02:00:00 NOTIFICATIONLEVEL=Full DONOTRUNONMETERED=1"
        # Time-limited (review finding P2-5), waits for an installation that holds Windows Installer
        # (msiexec 1618, review finding P2-15), and writes msiexec's verbose log to the run's logs
        # folder (review finding P3-37): Invoke-WauMsiexec.
        $msiexec = Invoke-WauMsiexec -ArgumentString $msiArgs -Action install -InstallInProgressWaitSeconds $InstallInProgressWaitSeconds
        if ($msiexec.LaunchFailed) {
            Write-ErrorMessage "Failed to install Winget-AutoUpdate: msiexec could not be started ($($msiexec.LaunchError))."
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }
        $msiLogNote = ''
        if ($msiexec.LogPath) {
            $msiLogNote = " msiexec log: $($msiexec.LogPath)"
        }
        if ($msiexec.TimedOut) {
            Write-ErrorMessage (('Winget-AutoUpdate install failed: msiexec did not finish within {0} minutes and was stopped.' -f [Math]::Round((Get-ProcessTimeoutSeconds -Operation MsiExec) / 60)) + $msiLogNote)
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED: installed, and a restart finishes it (P3-16).
        if ($msiexec.ExitCode -eq 0 -or $msiexec.ExitCode -eq 3010) {
            $restartRequired = $msiexec.ExitCode -eq 3010
            # msiexec success does not prove the task exists: WAU registers it from a post-install
            # script that swallows its errors (P3-36).
            $health = Get-WauTaskHealth
            if ($health.Healthy) {
                Write-Success "Winget-AutoUpdate $($pin.Version) installed. Apps will update weekly, on Tuesdays at 02:00 (or soon after the next start if the machine was off)."
            }
            elseif ($health.CheckFailed) {
                # An unknown state: reinstalling would not fix a task scheduler that cannot be queried.
                Write-ErrorMessage ("Winget-AutoUpdate $($pin.Version) was installed, but $($health.Problem), so it is not known whether apps will update automatically. Check the task \WAU\Winget-AutoUpdate in Task Scheduler; if it is missing, disabled or has no enabled trigger, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer." + $msiLogNote)
            }
            else {
                Write-ErrorMessage ("Winget-AutoUpdate $($pin.Version) was installed, but $($health.Problem), so apps will not update automatically. Uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer; if this happens again, attach the msiexec log and this transcript to a GitHub issue." + $msiLogNote)
            }
            Write-WauTaskHealth -Health $health
            if ($restartRequired) {
                Write-WarningMessage 'The Winget-AutoUpdate installer reported that a restart finishes the installation (msiexec exit code 3010).'
            }
            if (-not $health.Healthy) {
                return [pscustomobject]@{ Status = 'Unhealthy'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $restartRequired; Problem = $health.Problem; CheckFailed = [bool]$health.CheckFailed }
            }
            return [pscustomobject]@{ Status = 'Configured'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $restartRequired }
        }

        if ($msiexec.ExitCode -eq 1618) {
            Write-ErrorMessage (('Winget-AutoUpdate install failed: Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting (msiexec exit code 1618). Re-run the installer once that installation has finished.' -f $msiexec.BusyRetries, $msiexec.BusyWaitedSeconds) + $msiLogNote)
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        Write-ErrorMessage ("Winget-AutoUpdate install failed (msiexec exit code $($msiexec.ExitCode))." + $msiLogNote)
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }
    catch {
        Write-ErrorMessage "Failed to install Winget-AutoUpdate: $_"
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }
    finally {
        # Close the MSI first: the open handle refuses deletion, so the cleanup would fail.
        if ($msiStream) {
            $msiStream.Dispose()
        }
        if ($stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Uninstalls Winget-AutoUpdate (WAU) via the MSI product code of the installed version.
.DESCRIPTION
    Each WAU version has its own ProductCode, so it is read from the uninstall registry entry; the
    pinned one would make msiexec exit 1605 against any other version (issue #186). Falls back to
    the pinned code when none is found. msiexec runs through Invoke-WauMsiexec, as for the install.
    3010 is a removal a restart finishes, and the uninstaller then exits 3010.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, when msiexec exits 1618 because another installation is running.
    Default 600.
.OUTPUTS
    [hashtable] @{
        Succeeded       = True when WAU was removed (or was not installed), otherwise False
        RestartRequired = True when msiexec returned 3010
    }
#>
function Uninstall-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600
    )

    $result = @{ Succeeded = $false; RestartRequired = $false }
    if (-not (Test-WauInstalled)) {
        Write-WarningMessage 'Winget-AutoUpdate is not installed; nothing to remove.'
        $result.Succeeded = $true
        return $result
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would uninstall Winget-AutoUpdate.'
        $result.Succeeded = $true
        return $result
    }

    $productCode = (Get-InstalledWauInfo).ProductCode
    if (-not $productCode) {
        $productCode = (Get-WauPin).ProductCode
    }
    Write-Info 'Uninstalling Winget-AutoUpdate...'
    $msiexec = Invoke-WauMsiexec -ArgumentString "/x $productCode /qn /norestart" -Action uninstall -InstallInProgressWaitSeconds $InstallInProgressWaitSeconds
    if ($msiexec.LaunchFailed) {
        Write-ErrorMessage "Winget-AutoUpdate uninstall failed: msiexec could not be started ($($msiexec.LaunchError))."
        return $result
    }
    $msiLogNote = ''
    if ($msiexec.LogPath) {
        $msiLogNote = " msiexec log: $($msiexec.LogPath)"
    }
    if ($msiexec.TimedOut) {
        Write-ErrorMessage ('Winget-AutoUpdate uninstall failed: msiexec did not finish in time and was stopped.' + $msiLogNote)
        return $result
    }

    if ($msiexec.ExitCode -eq 0) {
        Write-Success 'Winget-AutoUpdate uninstalled.'
        $result.Succeeded = $true
        return $result
    }
    if ($msiexec.ExitCode -eq 3010) {
        Write-Success 'Winget-AutoUpdate uninstalled (a restart finishes removing it: msiexec exit code 3010).'
        $result.Succeeded = $true
        $result.RestartRequired = $true
        return $result
    }

    if ($msiexec.ExitCode -eq 1618) {
        Write-ErrorMessage (('Winget-AutoUpdate uninstall failed: Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting (msiexec exit code 1618). Run the uninstaller again once that installation has finished.' -f $msiexec.BusyRetries, $msiexec.BusyWaitedSeconds) + $msiLogNote)
        return $result
    }

    Write-ErrorMessage ("Winget-AutoUpdate uninstall failed (msiexec exit code $($msiexec.ExitCode))." + $msiLogNote)
    return $result
}

<#
.SYNOPSIS
    Removes the legacy scheduled-update task ('\winget-app-setup\WingetAppSetup-ScheduledUpdates')
    and its %APPDATA%\winget-app-setup data, which older versions set up before WAU (issue #168).
.DESCRIPTION
    Safe to call when nothing is there.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.OUTPUTS
    [bool] True when something was removed, otherwise False.
#>
function Remove-LegacyScheduledUpdates {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'
    $appDataDir = Join-Path $env:APPDATA 'winget-app-setup'
    $removed = $false

    # -ErrorAction SilentlyContinue (review finding P3-38): most machines have no legacy task, and
    # a caught -ErrorAction Stop error still wrote 'PS>TerminatingError(Get-ScheduledTask)' into
    # every such run's transcript.
    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    }
    catch {
        # The task scheduler cmdlets could not run at all.
        $task = $null
    }
    if ($task) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy scheduled task '$taskPath$taskName'."
        }
        else {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            Write-Info 'Removed the legacy scheduled-update task (updates are now handled by Winget-AutoUpdate).'
        }
        $removed = $true
    }

    if (Test-Path $appDataDir) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy update data directory '$appDataDir'."
        }
        else {
            Remove-Item -Path $appDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $removed = $true
    }

    return $removed
}
