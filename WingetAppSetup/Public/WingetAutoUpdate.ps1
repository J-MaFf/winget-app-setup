<#
.SYNOPSIS
    Returns the pinned Winget-AutoUpdate (WAU) release metadata.
.DESCRIPTION
    We deploy a specific, SHA256-verified WAU release rather than tracking latest, and disable WAU's
    own self-update, so an upstream change can never roll out to managed machines unreviewed. Bump
    all fields together to move to a newer WAU (verify the new SHA256 against the winget-pkgs manifest
    for that version). See issue #168.
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
    WAU records its configuration under HKLM and registers a scheduled task 'Winget-AutoUpdate' under
    the '\WAU\' task path. Either is a reliable indicator that WAU is already set up, so the installer
    can leave an existing (possibly customized) WAU configuration untouched.
#>
function Test-WauInstalled {
    if (Test-Path 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate') {
        return $true
    }
    try {
        if (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction Stop) {
            return $true
        }
    }
    catch { }
    return $false
}

<#
.SYNOPSIS
    Installs and configures Winget-AutoUpdate (WAU) to keep installed apps current.
.DESCRIPTION
    Downloads the pinned WAU MSI, verifies its SHA256, and installs it silently with the configuration
    this project standardizes on (issue #168):
      - Weekly updates at 02:00 (WAU runs as SYSTEM for machine-scope packages and spawns a user-context
        task in the logged-on session for user-scope packages, which avoids the cross-user 0x80073d19
        class the homegrown updater fought).
      - USERCONTEXT=1 so user-scope apps update in the real interactive session.
      - DISABLEWAUAUTOUPDATE=1 so WAU stays on this pinned version until we bump it deliberately.
      - Full notifications; skip on metered connections.
    Best-effort: any failure warns and returns $false rather than aborting the install. If WAU is
    already present, its configuration is left as-is.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when WAU is installed (or already present), otherwise False.
#>
function Install-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $pin = Get-WauPin

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would install Winget-AutoUpdate $($pin.Version) (weekly updates at 02:00, Full notifications, self-update disabled)."
        return $true
    }

    if (Test-WauInstalled) {
        Write-Success 'Winget-AutoUpdate is already installed; leaving its configuration unchanged.'
        return $true
    }

    Write-Info "Setting up automatic app updates via Winget-AutoUpdate $($pin.Version)..."
    $msiPath = Join-Path $env:TEMP "WAU-$($pin.Version).msi"

    try {
        Invoke-WebRequest -Uri $pin.MsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

        $actualHash = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash
        if ($actualHash -ne $pin.Sha256) {
            Write-ErrorMessage "Winget-AutoUpdate MSI hash mismatch (expected $($pin.Sha256), got $actualHash). Skipping installation."
            return $false
        }

        # Bake the configuration in via MSI properties (the winget-package install path allows no
        # install-time customization). Single quoted-path argument string for reliable msiexec parsing.
        $msiArgs = "/i `"$msiPath`" /qn /norestart RUN_WAU=YES USERCONTEXT=1 DISABLEWAUAUTOUPDATE=1 UPDATESINTERVAL=Weekly UPDATESATTIME=02:00:00 NOTIFICATIONLEVEL=Full DONOTRUNONMETERED=1"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED — still a success.
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Success "Winget-AutoUpdate $($pin.Version) installed. Apps will update weekly at 2 AM."
            return $true
        }

        Write-ErrorMessage "Winget-AutoUpdate install failed (msiexec exit code $($proc.ExitCode))."
        return $false
    }
    catch {
        Write-ErrorMessage "Failed to install Winget-AutoUpdate: $_"
        return $false
    }
    finally {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Uninstalls Winget-AutoUpdate (WAU) via its pinned MSI product code.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when WAU was removed (or was not installed), otherwise False.
#>
function Uninstall-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if (-not (Test-WauInstalled)) {
        Write-WarningMessage 'Winget-AutoUpdate is not installed; nothing to remove.'
        return $true
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would uninstall Winget-AutoUpdate.'
        return $true
    }

    $pin = Get-WauPin
    Write-Info 'Uninstalling Winget-AutoUpdate...'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $($pin.ProductCode) /qn /norestart" -Wait -PassThru

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Success 'Winget-AutoUpdate uninstalled.'
        return $true
    }

    Write-ErrorMessage "Winget-AutoUpdate uninstall failed (msiexec exit code $($proc.ExitCode))."
    return $false
}

<#
.SYNOPSIS
    Removes the legacy homegrown scheduled-update task and its %APPDATA% data.
.DESCRIPTION
    Auto-updates are now handled by Winget-AutoUpdate (issue #168). Earlier versions registered a
    Windows scheduled task 'WingetAppSetup-ScheduledUpdates' (under '\winget-app-setup\') that ran a
    helper deployed to %APPDATA%\winget-app-setup — a helper that self-downloads from the repo and
    would break once removed. This migration unregisters that task and deletes the data directory so
    already-deployed machines transition cleanly. Safe to call when nothing is present (no-op).
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
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

    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    }
    catch {
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
