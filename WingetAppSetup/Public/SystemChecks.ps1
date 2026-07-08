<#
.SYNOPSIS
    Runs pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044, non-blocking), warns and prompts to
    continue when C: has less than 50 GB free (measured only — an unreadable drive reports
    UNKNOWN and never prompts), and blocks when cdn.winget.microsoft.com is unreachable over
    HTTPS (network is required for winget). The network probe uses Invoke-WebRequest, which
    honors system proxy settings; any HTTP response — including 4xx/5xx — counts as reachable,
    and only a transport-level failure (no response at all) blocks. In -WhatIf mode the
    disk-space prompt is skipped.
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
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "$osName (build $build - Windows 10 21H2 or later recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "Could not determine OS version: $_" }
    }

    # --- Disk Space on C: (warn + prompt if under 50 GB) ---
    $freeGB = $null
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
        # Distinct from the low-space WARN: free space could not be measured, so the
        # low-disk prompt below must not fire ($freeGB stays $null).
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'UNKNOWN'; Detail = "Could not read C: drive: $_" }
    }

    # --- Network (blocking — required for winget) ---
    # Proxy-aware HTTPS probe: Invoke-WebRequest honors system proxy settings, unlike a raw
    # TCP test (Test-NetConnection), which false-fails on proxy-only networks (#184). Any HTTP
    # response — even 4xx/5xx — proves the CDN is reachable; only a transport-level failure
    # (no response at all) blocks.
    try {
        # -UseBasicParsing is a no-op on PowerShell 7 but prevents a false FAIL on Windows
        # PowerShell 5.1 (README launch path) when the IE parsing engine is unavailable.
        $null = Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache' -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = 'HTTPS probe of cdn.winget.microsoft.com succeeded' }
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = "cdn.winget.microsoft.com reachable (HTTP $([int]$response.StatusCode))" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = "Cannot reach cdn.winget.microsoft.com over HTTPS - network is required: $($_.Exception.Message)" }
            $proceed = $false
        }
    }

    # --- Display results ---
    Write-Host ''
    Write-Info 'Pre-flight System Checks:'
    foreach ($r in $results) {
        $icon = switch ($r.Status) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'UNKNOWN' { '[UNKNOWN]' } 'FAIL' { '[FAIL]' } }
        $msg = "$icon $($r.Check): $($r.Detail)"
        switch ($r.Status) {
            'OK' { Write-Success $msg }
            'WARN' { Write-WarningMessage $msg }
            'UNKNOWN' { Write-WarningMessage $msg }
            'FAIL' { Write-ErrorMessage $msg }
        }
    }
    Write-Host ''

    if (-not $proceed) {
        return $false
    }

    # Prompt only when free space was actually measured below the threshold
    # (skip prompt in WhatIf mode; never prompt when the drive could not be read).
    if ($null -ne $freeGB -and $freeGB -lt 50 -and -not $WhatIf) {
        $choice = Read-Host 'Disk space is below the 50 GB recommendation. Continue anyway? (Y/N)'
        if ($choice -notin @('Y', 'y')) {
            Write-WarningMessage 'Installation cancelled by user due to low disk space.'
            return $false
        }
    }

    return $true
}
