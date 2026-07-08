<#
.SYNOPSIS
    Updates the winget source for the current account to force its per-user first-use bootstrap.
.DESCRIPTION
    Runs `winget source update --name winget --disable-interactivity` under a timeout guard. This is
    the lightest command that forces winget's per-user first-use bootstrap: it registers the
    Microsoft.Winget.Source package for the invoking account. Exit code 0 therefore means the account
    can reach the winget source — the only source the install phase uses (`--source winget`).

    Do NOT pass `--accept-source-agreements` here: it is not a valid argument for `winget source
    update` and makes winget reject the whole command with 0x8A150002 (INVALID_CL_ARGUMENTS,
    -1978335230), which false-failed this probe on every machine (issue #172-followup). Source
    agreements are accepted where the flag is valid — the install commands all pass
    `--accept-source-agreements` (Install-WingetPackage), and the caller handles a genuine
    0x8A150046 (agreements-not-accepted) result explicitly.

    The probe is deliberately scoped to the winget source: msstore can fail for an account that
    has never logged on interactively even when the winget source is healthy
    (microsoft/winget-cli#5398/#6334), and probing it would report a false failure for the only
    source that matters here.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for winget before killing the process. Default 120.
.RETURNS
    [hashtable] @{ Succeeded = <bool>; ExitCode = <int or $null>; TimedOut = <bool> }
    ExitCode is $null when the process timed out or failed to start.
#>
function Invoke-WingetSourceProbe {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120
    )

    # Unique per-run temp files: fixed names made concurrent runs (or a stale locked file from a
    # killed run) fail Start-Process, which read as a false probe failure (issue #177).
    $tempSuffix = [System.IO.Path]::GetRandomFileName()
    $stdoutFile = Join-Path $env:TEMP "winget_source_probe_output_$tempSuffix.txt"
    $stderrFile = Join-Path $env:TEMP "winget_source_probe_error_$tempSuffix.txt"

    try {
        $probeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'source', 'update', '--name', 'winget', '--disable-interactivity' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        if (-not $probeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Write-WarningMessage "Winget source update timed out after $TimeoutSeconds seconds. Terminating process..."
            try { $probeProcess.Kill() } catch { }
            return @{ Succeeded = $false; ExitCode = $null; TimedOut = $true }
        }

        return @{
            Succeeded = ($probeProcess.ExitCode -eq 0)
            ExitCode  = $probeProcess.ExitCode
            TimedOut  = $false
        }
    }
    catch {
        Write-WarningMessage "Winget source update failed to run: $_"
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false }
    }
    finally {
        Remove-Item $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Checks that the winget source is both listed and functional for the current account.
.DESCRIPTION
    Two-step health probe used by Test-WingetSources before and after its repair attempt (one
    shared implementation so the two probes cannot diverge — issue #177):

      1. Listed: `winget source list` output mentions the winget source.
      2. Functional: a real `winget search 7zip --source winget` succeeds (exit code 0 and no
         corruption markers such as 0x8a15000f in the output).

    The search passes `--accept-source-agreements` — valid for `winget search`, unlike
    `winget source update` (issues #174/#175) — so a fresh account's unaccepted source agreements
    (0x8A150046) are accepted inline instead of being misdiagnosed as source corruption and
    triggering a pointless `winget source reset --force` + repair cycle.
.PARAMETER Quiet
    Suppresses the per-step success/corruption messages; used for the post-repair re-probe where
    the caller reports the overall outcome itself.
.RETURNS
    [hashtable] @{ Listed = <bool>; Functional = <bool>; Healthy = <bool> }
    Healthy is True only when the source is listed AND functional.
#>
function Test-WingetSourceHealth {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )

    # First check: verify source is listed
    try {
        $output = winget source list --disable-interactivity --accept-source-agreements 2>&1
        $sourceIsListed = [bool]($output -match 'winget')
    }
    catch {
        Write-WarningMessage "Winget source list failed: $_"
        $sourceIsListed = $false
    }

    # Second check: verify source is functional (not corrupted) by attempting a search
    $sourceIsFunctional = $false
    if ($sourceIsListed) {
        try {
            # Actually test if the source works by attempting a search.
            # Use '7zip' as a known package that always exists.
            $searchOutput = winget search 7zip --source winget --disable-interactivity --accept-source-agreements 2>&1
            $searchExitCode = $LASTEXITCODE

            # Check for corruption error code 0x8a15000f or similar source errors
            if ($searchOutput -match '0x8a150|failed when opening|data required' -or $searchExitCode -ne 0) {
                if (-not $Quiet) {
                    Write-WarningMessage 'Winget source is listed but contains corrupted or missing data.'
                }
                $sourceIsFunctional = $false
            }
            else {
                if (-not $Quiet) {
                    Write-Success 'Winget sources are accessible and functional.'
                }
                $sourceIsFunctional = $true
            }
        }
        catch {
            if (-not $Quiet) {
                Write-WarningMessage "Winget source functionality test failed: $_"
            }
            $sourceIsFunctional = $false
        }
    }

    return @{
        Listed     = $sourceIsListed
        Functional = $sourceIsFunctional
        Healthy    = ($sourceIsListed -and $sourceIsFunctional)
    }
}
