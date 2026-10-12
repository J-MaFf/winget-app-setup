<#
.SYNOPSIS
    Determines whether the current run has a human at the console.
.DESCRIPTION
    The one place that decides it (issues #176, #214). The installer asks no yes/no question
    (issue #230); this gates the TightVNC password prompt, the "press any key to exit" holds at the
    end of a run and before an early exit, the exit code forced after an abort, and whether a run
    that is not elevated may show a UAC prompt (it returns 4 instead).

    A run is non-interactive when ANY of these holds:
      - the caller asked for it (Test-NonInteractiveRequested: -NonInteractive or
        WINGET_APP_SETUP_NONINTERACTIVE);
      - the process runs as SYSTEM (Test-IsSystemAccount): an RMM agent or a scheduled task;
      - [Environment]::UserInteractive is false (services, scheduled tasks). PowerShell's own
        -NonInteractive switch is not detected here; only the TightVNC prompt checks for it
        (Test-PowerShellHostNonInteractive), because Read-Host throws in that mode;
      - stdin is redirected, or the console cannot be probed.
    An interactive `irm <url> | iex` counts as interactive: the pipe leaves the process's stdin
    alone, which is why prompts could never have kept the one-liner unattended.
.PARAMETER NonInteractive
    The caller's explicit -NonInteractive switch.
.OUTPUTS
    [bool] True when there is no human to interact with.
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
    Determines whether PowerShell itself was started with its -NonInteractive switch, in which
    Read-Host throws whatever the console looks like.
.DESCRIPTION
    Nothing in .NET or the host's public API says so, so the process command line is read: an
    argument that is -NonInteractive or an abbreviation down to -noni, after '-', '--' or '/'. The
    script's own -NonInteractive matches too, and means the same. Used by the TightVNC password
    prompt. Runs under Windows PowerShell 5.1 too.
.PARAMETER CommandLineArgs
    The process command line, for tests. Default: [Environment]::GetCommandLineArgs().
.OUTPUTS
    [bool]
#>
function Test-PowerShellHostNonInteractive {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$CommandLineArgs = [Environment]::GetCommandLineArgs()
    )

    # The first element is the program itself.
    foreach ($argument in @($CommandLineArgs | Select-Object -Skip 1)) {
        if ($argument -match '^(?:--?|/)(?<name>[A-Za-z]+)$') {
            $name = $Matches['name']
            if ($name.Length -ge 4 -and 'noninteractive'.StartsWith($name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

<#
.SYNOPSIS
    Determines whether the caller asked for an unattended run.
.DESCRIPTION
    True for the -NonInteractive switch, or when WINGET_APP_SETUP_NONINTERACTIVE is 1, true or yes
    (any case, spaces ignored): the irm | iex one-liner cannot pass a switch. The PowerShell 7 run
    the 5.1 bootstrap starts inherits the variable. Runs under Windows PowerShell 5.1 too.
.PARAMETER NonInteractive
    The caller's explicit -NonInteractive switch.
.OUTPUTS
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
    Determines whether the run is under a CI system, so a failed early exit never waits for a key
    press on a CI runner whose console looks interactive.
.DESCRIPTION
    Checks CI (most CI systems), GITHUB_ACTIONS and TF_BUILD (Azure Pipelines); CI set to 'false'
    or '0' does not count. Runs under Windows PowerShell 5.1 too.
.OUTPUTS
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
