<#
.SYNOPSIS
    Determines whether the current run has a human at the console.
.DESCRIPTION
    Single source of truth for the effective non-interactive detection (issues #176, #214). Since
    issue #230 this gates no prompt — there are none left — and its only caller is
    Invoke-WingetInstall, which uses it for the two things that still depend on a human being
    present: whether to open the summary grid view, and whether to hold the window with "press any
    key to exit".

    Note what it deliberately does NOT catch: an interactive `irm <url> | iex` reports INTERACTIVE
    here, because the pipe is a PowerShell-internal pipeline and leaves the process's stdin alone.
    That is correct — there really is a human there — but it is why prompts could never be the
    mechanism that kept the documented one-liner unattended (issue #230).

    A run is effectively non-interactive when ANY of the following holds:
      - the caller passed the explicit -NonInteractive switch;
      - the session is non-interactive ([Environment]::UserInteractive is false — services,
        scheduled tasks, pwsh -NonInteractive);
      - stdin is redirected (piped input, irm | iex wrappers, CI runners). A console probe
        failure means there is no usable console, so that counts as non-interactive too.
.PARAMETER NonInteractive
    The caller's explicit -NonInteractive switch, forwarded as -NonInteractive:$switch.
.RETURNS
    [bool] True when there is no human to interact with; otherwise false.
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
