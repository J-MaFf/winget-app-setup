<#
.SYNOPSIS
    Determines whether the current run has a human at the console.
.DESCRIPTION
    Single source of truth for the effective non-interactive detection (issues #176, #214). Since
    issue #230 this gates no prompt — there are none left — only the things that still depend on a
    human being present: whether Invoke-WingetInstall opens the summary grid view and holds the
    window with "press any key to exit", whether Write-InstallerExitNotice holds it the same way
    before an early exit (review finding P2-14), whether the entry script forces an exit code
    after an abort, and whether a run that is not elevated may show a UAC prompt at all
    (Invoke-WingetInstall and Restart-WithElevation return 4 instead; review finding P2-12).

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

<#
.SYNOPSIS
    Determines whether the run is under a CI system.
.DESCRIPTION
    Used by Write-InstallerExitNotice so a failed early exit never waits for a key press on a CI
    runner, even where the runner's console looks interactive. Checks the variables CI systems set:
    CI (GitHub Actions, GitLab, Azure Pipelines' agents and most others), GITHUB_ACTIONS and TF_BUILD
    (Azure Pipelines). A CI value of 'false' or '0' does not count. Runs under Windows PowerShell 5.1
    too.
.RETURNS
    [bool] True under CI.
#>
function Test-IsContinuousIntegration {
    if ($env:CI -and $env:CI -ne 'false' -and $env:CI -ne '0') {
        return $true
    }
    if ($env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD -eq 'True') {
        return $true
    }
    return $false
}
