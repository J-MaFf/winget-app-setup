<#
.SYNOPSIS
    Determines whether the current run has a human at the console.
.DESCRIPTION
    Single source of truth for the effective non-interactive detection (issues #176, #214). Since
    issue #230 this gates no yes/no question — there are none left. It gates one prompt, TightVNC's
    server password at the start of a run that has no WINGET_APP_SETUP_TIGHTVNC_PASSWORD
    (Initialize-TightVncSecretForRun, work-order item 18), and the things that still depend on a
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
      - the caller asked for an unattended run (Test-NonInteractiveRequested): the explicit
        -NonInteractive switch, or $env:WINGET_APP_SETUP_NONINTERACTIVE, which the irm | iex
        one-liner needs because it cannot pass a switch (review finding P3-41);
      - the process runs as SYSTEM (Test-IsSystemAccount; review finding P3-23): an RMM agent or a
        scheduled task, never a person at a console, whatever its session reports. Nobody would
        answer a key press, so none is waited for;
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

    if (Test-NonInteractiveRequested -NonInteractive:$NonInteractive) {
        return $true
    }
    if (Test-IsSystemAccount) {
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
    Determines whether the caller asked for an unattended run.
.DESCRIPTION
    True for the explicit -NonInteractive switch, or when the environment variable
    WINGET_APP_SETUP_NONINTERACTIVE is 1, true or yes (any case, surrounding spaces ignored). The
    documented irm | iex one-liner cannot pass a switch to the script it downloads (review finding
    P3-41), so an RMM job or a wrapper that runs it as the logged-on user, with a console nobody
    watches, sets the variable instead, and the run then never waits for a key press. Any other
    value, or none, leaves the decision to Test-EffectiveNonInteractive's auto-detection. The
    variable is inherited by the PowerShell 7 run the Windows PowerShell 5.1 bootstrap starts, so
    it holds for the whole run. Runs under Windows PowerShell 5.1 too (the tail's bootstrap branch
    calls Test-EffectiveNonInteractive).
.PARAMETER NonInteractive
    The caller's explicit -NonInteractive switch.
.RETURNS
    [bool]
#>
function Test-NonInteractiveRequested {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $true
    }
    $requested = ([string]$env:WINGET_APP_SETUP_NONINTERACTIVE).Trim()
    return (@('1', 'true', 'yes') -contains $requested)
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
