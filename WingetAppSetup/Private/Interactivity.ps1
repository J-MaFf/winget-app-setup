<#
.SYNOPSIS
    Determines whether the current run must behave as non-interactive (no prompts).
.DESCRIPTION
    Single source of truth for the effective non-interactive detection (issue #214). The logic
    was previously inlined in Invoke-WingetInstall (issue #176), which left the pre-flight
    disk-space prompt in Test-SystemRequirements unguarded: an unattended run (CI, RMM, scheduled
    task) with measured-low disk blocked on Read-Host and auto-cancelled when redirected stdin
    returned an empty string. Both callers now share this helper.

    A run is effectively non-interactive when ANY of the following holds:
      - the caller passed the explicit -NonInteractive switch;
      - the session is non-interactive ([Environment]::UserInteractive is false — services,
        scheduled tasks, pwsh -NonInteractive);
      - stdin is redirected (piped input, irm | iex wrappers, CI runners). A console probe
        failure means there is no usable console, so that counts as non-interactive too.
.PARAMETER NonInteractive
    The caller's explicit -NonInteractive switch, forwarded as -NonInteractive:$switch.
.RETURNS
    [bool] True when the run must not prompt; otherwise false.
#>
function Test-EffectiveNonInteractive {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $true
    }
    if (-not [Environment]::UserInteractive) {
        return $true
    }
    try {
        return [System.Console]::IsInputRedirected
    }
    catch {
        # No usable console to probe: treat as non-interactive rather than risk a blocked prompt.
        return $true
    }
}
