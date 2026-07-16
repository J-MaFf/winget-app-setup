<#
.SYNOPSIS
    Runs pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044, non-blocking), warns when C: has less than
    50 GB free (measured only — an unreadable drive reports UNKNOWN and stays quiet), and blocks
    when cdn.winget.microsoft.com is unreachable over HTTPS (network is required for winget). The
    network probe uses Invoke-WebRequest, which honors system proxy settings; any HTTP response —
    including 4xx/5xx — counts as reachable, and only a transport-level failure (no response at
    all) blocks.

    Nothing here prompts (issue #230): the only blocking check is the network probe, whose verdict
    is not a matter of opinion, so the sole return-$false path is a genuine failure rather than a
    declined question. Low disk warns and proceeds. That is also why this function has no
    -NonInteractive parameter — with the prompt gone there is no interactive behavior left to
    suppress (it previously gated the low-disk Read-Host, per issues #214/#176).
.PARAMETER WhatIf
    When specified, reports intended checks and skips the low-disk warning (a dry run makes no
    changes that could run the disk out).
.RETURNS
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
        # Prefer the registry's CurrentBuildNumber over [Environment]::OSVersion: it is the
        # ground-truth build (never capped by the host's compatibility manifest under Windows
        # PowerShell 5.1) and, unlike the static .NET call, it is mockable in Pester. Fall back
        # to OSVersion only when the value is somehow absent.
        $build = if ($cv.CurrentBuildNumber) { [int]$cv.CurrentBuildNumber } else { [System.Environment]::OSVersion.Version.Build }
        # Windows 11 still reports ProductName "Windows 10 ..." - Microsoft never updated the
        # string, so build >= 22000 is what actually distinguishes it. Relabel so the report
        # isn't misleading (issue #221). The "Windows 10" guard leaves Windows Server (e.g.
        # "Windows Server 2025", build 26100) and an already-correct "Windows 11" untouched.
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

    # Measured-low disk warns and continues; it never asks (issue #230). Low disk is a
    # recommendation, not a blocker, so "continue anyway?" only ever had one useful answer, and
    # asking it stalled the documented one-liner — an interactive `irm | iex` does not redirect
    # stdin, so the interactivity detection this used to branch on reported interactive and the
    # prompt fired. Silent when free space could not be measured ($freeGB stays $null) or under
    # -WhatIf, which makes no changes that could run the disk out.
    if ($null -ne $freeGB -and $freeGB -lt 50 -and -not $WhatIf) {
        Write-WarningMessage 'Disk space is below the 50 GB recommendation. Continuing anyway.'
    }

    return $true
}
