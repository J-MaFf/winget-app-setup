<#
.SYNOPSIS
    Runs the pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044) and when C: has less than 50 GB free (an
    unreadable drive stays quiet). Blocks only when cdn.winget.microsoft.com is unreachable over
    HTTPS: Invoke-WebRequest honours the system proxy, and any HTTP response, 4xx and 5xx included,
    counts as reachable. When it blocks a run as SYSTEM or as another admin account, a 'Proxy' line
    names the proxy the signed-in user has and this account lacks (Get-ProxyInheritanceWarning).
    Nothing here prompts (issue #230).
.PARAMETER WhatIf
    When specified, reports intended checks and skips the low-disk warning (a dry run makes no
    changes that could run the disk out).
.OUTPUTS
    [bool] True when it is safe to proceed; False when a blocking check fails.
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
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osName = $cv.ProductName
        # The registry's CurrentBuildNumber, not OSVersion: never capped by the host's compatibility
        # manifest under 5.1, and mockable. OSVersion only when the value is absent.
        $build = if ($cv.CurrentBuildNumber) { [int]$cv.CurrentBuildNumber } else { [System.Environment]::OSVersion.Version.Build }
        # Windows 11 still says "Windows 10" in ProductName; build 22000+ tells it apart (issue #221).
        # Windows Server and a correct "Windows 11" are left alone.
        if ($build -ge 22000 -and $osName -match 'Windows 10') {
            $osName = $osName -replace 'Windows 10', 'Windows 11'
        }
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

    # --- Disk Space on C: (warn if under 50 GB) ---
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
        # Distinct from the low-space WARN: free space could not be measured, so the low-disk
        # warning below must not fire and claim a number it does not have ($freeGB stays $null).
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'UNKNOWN'; Detail = "Could not read C: drive: $_" }
    }

    # --- Network (blocking: required for winget) ---
    # Invoke-WebRequest honours the system proxy, unlike Test-NetConnection (#184). Any HTTP response
    # proves the CDN is reachable; only no response at all blocks.
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
            # As SYSTEM or another admin account, this run may lack the signed-in user's proxy. A
            # real run stops here, so the line is added here; a dry run goes on, and the environment
            # pre-flight reports it once.
            if (-not $WhatIf) {
                $proxyWarning = $null
                try {
                    $proxyWarning = Get-ProxyInheritanceWarning -AccountContext (Get-InstallAccountContext)
                }
                catch {
                    $proxyWarning = $null
                }
                if ($proxyWarning) {
                    $results += [PSCustomObject]@{ Check = 'Proxy'; Status = 'WARN'; Detail = $proxyWarning }
                }
            }
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

    # Low disk warns and goes on; it never asks (issue #230). Quiet when free space could not be
    # measured, or under -WhatIf.
    if ($null -ne $freeGB -and $freeGB -lt 50 -and -not $WhatIf) {
        Write-WarningMessage 'Disk space is below the 50 GB recommendation. Continuing anyway.'
    }

    return $true
}
