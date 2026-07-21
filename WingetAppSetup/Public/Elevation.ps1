# Public (exported) elevation helpers. The rest of the elevation detection helpers live in
# Private/Elevation.ps1; these are exported (issue #190) so winget-app-uninstall.ps1 can reuse
# them instead of hand-rolling its own admin check / Start-Process relaunch.

<#
.SYNOPSIS
    Detects whether the current process is running with administrator privileges.
.DESCRIPTION
    The single shared implementation of the
    "[Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(...)"
    check, previously copy-pasted (and already behaviorally diverged) across
    WingetAppSetup/Public/Install.ps1, winget-app-uninstall.ps1, and
    WingetAppSetup/Private/PowerShell7Bootstrap.ps1 (full-repo review finding, 2026-07-16).
    Fails safe: if the underlying identity/role check throws for any reason (an exotic restricted
    token, a non-interactive service context, or a mocked failure in tests), this warns and
    returns $true rather than letting the exception propagate and abort the caller - matching the
    PowerShell7Bootstrap.ps1 behavior that is now applied at every call site.

    At the two call sites that gate elevation (Invoke-WingetInstall, winget-app-uninstall.ps1),
    "assume elevated" on failure means a broken check SKIPS Restart-WithElevation and proceeds
    unelevated rather than retrying elevation. This is a deliberate tradeoff, not an oversight
    (full-repo mega-review, 2026-07-17): the trigger is vanishingly rare on a real Windows
    session, the caller still warns loudly before proceeding, any operation that genuinely needed
    elevation then fails just as loudly with an access-denied error, and the alternative
    (fail-closed: assume non-admin, always attempt Restart-WithElevation) risks a relaunch loop if
    the same check throws deterministically in the relaunched process too - a worse failure mode
    than a noisy unelevated run. If a future caller's failure consequence is instead silent/unsafe
    rather than loud, that caller should check the exception itself rather than rely on this
    shared default.
.RETURNS
    [bool] $true when the current process is elevated (or when the check itself failed and could
    not determine elevation), $false when it is confirmed non-elevated.
#>
function Test-IsAdmin {
    try {
        $principal = Get-CurrentWindowsPrincipal
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    }
    catch {
        Write-WarningMessage "Could not determine administrator status; assuming elevated: $_"
        return $true
    }
}

<#
.SYNOPSIS
    Relaunches the script with elevated privileges, preferring Windows Terminal when available.
.DESCRIPTION
    Attempts to restart the current script in an elevated session. When Windows Terminal is installed,
    the script is relaunched inside an elevated Windows Terminal tab running the specified PowerShell
    executable. If Windows Terminal is unavailable or fails to start, the function falls back to the
    standard Start-Process call for the provided PowerShell executable.
.PARAMETER PowerShellExecutable
    The PowerShell executable to use when relaunching (for example, pwsh.exe or powershell.exe).
.PARAMETER ScriptPath
    The full path to the script that should be relaunched.
.PARAMETER WindowsTerminalExecutable
    Optional explicit path to the Windows Terminal executable (wt.exe). When not supplied, the
    function attempts to discover it automatically.
.PARAMETER AdditionalArguments
    Optional switches/arguments to forward to the elevated relaunch (for example, '-WhatIf'). These
    are appended after the -File argument so the elevated session inherits the caller's intent.
.RETURNS
    [string] Returns 'WindowsTerminal' when the Windows Terminal relaunch path succeeds, otherwise
    returns 'PowerShell'.
#>
function Restart-WithElevation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExecutable,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string]$WindowsTerminalExecutable,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalArguments = @()
    )

    $quotedScriptPath = '"' + $ScriptPath.Replace('"', '`"') + '"'
    $commandArguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
    if ($AdditionalArguments.Count -gt 0) {
        $commandArguments += ' ' + ($AdditionalArguments -join ' ')
    }
    $windowsTerminalPath = $WindowsTerminalExecutable

    if (-not $windowsTerminalPath) {
        $wtCommand = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
        if ($wtCommand) {
            $windowsTerminalPath = $wtCommand.Source
        }
    }

    if ($windowsTerminalPath) {
        Write-Info 'Attempting to relaunch script in Windows Terminal with elevated privileges...'
        try {
            Start-Process $windowsTerminalPath -ArgumentList @("$PowerShellExecutable $commandArguments") -Verb RunAs
            return 'WindowsTerminal'
        }
        catch {
            Write-Warning "Failed to start Windows Terminal: $_"
        }
    }

    Write-Info 'Relaunching script in standard PowerShell window with elevated privileges...'
    Start-Process $PowerShellExecutable -ArgumentList $commandArguments -Verb RunAs
    return 'PowerShell'
}
