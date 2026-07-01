<#
.SYNOPSIS
    Runs pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044, non-blocking), warns and prompts to
    continue when C: has less than 50 GB free, and blocks when cdn.winget.microsoft.com is
    unreachable (network is required for winget). In -WhatIf mode the disk-space prompt is skipped.
.PARAMETER WhatIf
    When specified, reports intended checks without prompting on low disk space.
.RETURNS
    [bool] True when it is safe to proceed; False when a blocking check fails or the user declines.
#>
function Test-SystemRequirements {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $results = @()
    $proceed = $true

    # --- OS Version (warn only, Windows 10 21H2 = build 19044) ---
    try {
        $build = [System.Environment]::OSVersion.Version.Build
        $osName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).ProductName
        if ($build -ge 19044) {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'OK'; Detail = $osName }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "$osName (build $build — Windows 10 21H2 or later recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "Could not determine OS version: $_" }
    }

    # --- Disk Space on C: (warn + prompt if under 50 GB) ---
    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $freeGB = [Math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -ge 50) {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'OK'; Detail = "${freeGB} GB free on C:" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'WARN'; Detail = "${freeGB} GB free on C: (50 GB recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'WARN'; Detail = "Could not read C: drive: $_" }
        $freeGB = 999
    }

    # --- Network (blocking — required for winget) ---
    try {
        $netTest = Test-NetConnection -ComputerName 'cdn.winget.microsoft.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
        if ($netTest) {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = 'Connected to cdn.winget.microsoft.com' }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = 'Cannot reach cdn.winget.microsoft.com — network is required' }
            $proceed = $false
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = "Network check failed: $_" }
        $proceed = $false
    }

    # --- Display results ---
    Write-Host ''
    Write-Info 'Pre-flight System Checks:'
    foreach ($r in $results) {
        $icon = switch ($r.Status) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'FAIL' { '[FAIL]' } }
        $msg = "$icon $($r.Check): $($r.Detail)"
        switch ($r.Status) {
            'OK' { Write-Success $msg }
            'WARN' { Write-WarningMessage $msg }
            'FAIL' { Write-ErrorMessage $msg }
        }
    }
    Write-Host ''

    if (-not $proceed) {
        return $false
    }

    # Prompt on low disk space (skip prompt in WhatIf mode)
    $diskResult = $results | Where-Object { $_.Check -eq 'Disk Space' }
    if ($diskResult.Status -eq 'WARN' -and -not $WhatIf) {
        $choice = Read-Host 'Disk space is below the 50 GB recommendation. Continue anyway? (Y/N)'
        if ($choice -notin @('Y', 'y')) {
            Write-WarningMessage 'Installation cancelled by user due to low disk space.'
            return $false
        }
    }

    return $true
}
