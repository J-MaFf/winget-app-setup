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

    try {
        $probeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'source', 'update', '--name', 'winget', '--disable-interactivity' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput "$env:TEMP\winget_source_probe_output.txt" `
            -RedirectStandardError "$env:TEMP\winget_source_probe_error.txt"

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
        Remove-Item "$env:TEMP\winget_source_probe_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\winget_source_probe_error.txt" -ErrorAction SilentlyContinue
    }
}
