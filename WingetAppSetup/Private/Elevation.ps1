<#
.SYNOPSIS
    Detects if the script is running locally or from a remote source (e.g., via IEX).
.DESCRIPTION
    Checks if $PSScriptRoot is non-empty and represents a valid directory.
    Returns $true for local execution (file on disk), $false for remote execution (piped script).
.RETURNS
    [bool] True if running locally, False if running remotely.
#>
function Test-IsRunningLocally {
    # Check if $PSScriptRoot is non-empty and valid
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $false
    }

    # Verify it's an actual directory path
    try {
        $null = Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns the account name the current process is running as (DOMAIN\user), or $null.
#>
function Get-ProcessUserName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Returns the account name that owns the interactive console session (DOMAIN\user), or $null.
.DESCRIPTION
    Win32_ComputerSystem.UserName reports the interactively logged-on console user regardless of
    which account the current (possibly elevated) process runs as. Comparing it with
    Get-ProcessUserName detects cross-user elevation — running elevated as a different account
    than the logged-on user — where winget's per-user MSIX bootstrap is blocked by the AppX
    deployment service with 0x80073D19 because the process account has no interactive logon
    session (issue #159).
#>
function Get-InteractiveSessionUserName {
    try {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ([string]::IsNullOrWhiteSpace($userName)) {
            return $null
        }
        return $userName
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Detects whether Invoke-WingetInstall is executing from the WingetAppSetup module rather than
    the generated single-file installer.
.DESCRIPTION
    Auto-elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the imported
    module, $PSCommandPath resolves to WingetAppSetup/Public/Install.ps1 — a functions-only file —
    so the elevated window would define a function and exit without installing anything
    (issue #185). Callers use this check to fail fast with guidance instead of silently
    relaunching a no-op.
.PARAMETER InvocationModule
    The caller's $MyInvocation.MyCommand.Module. Non-null when the function was invoked from an
    imported module.
.PARAMETER CommandPath
    The caller's $PSCommandPath. Matched against the module layout to also catch a dot-sourced
    WingetAppSetup/Public/Install.ps1, where the module info is null but the defining file is
    still functions-only.
.RETURNS
    [bool] True when running from module context (relaunching $PSCommandPath would be a no-op).
#>
function Test-InvokedFromModuleContext {
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSModuleInfo]$InvocationModule,

        [Parameter(Mandatory = $false)]
        [string]$CommandPath
    )

    if ($null -ne $InvocationModule) {
        return $true
    }

    return [bool]($CommandPath -match '[\\/]WingetAppSetup[\\/]Public[\\/]Install\.ps1$')
}

<#
.SYNOPSIS
    Returns a WindowsPrincipal wrapping the current process's WindowsIdentity.
.DESCRIPTION
    Thin wrapper around the static [Security.Principal.WindowsIdentity]::GetCurrent() /
    [Security.Principal.WindowsPrincipal] construction, split out purely so Test-IsAdmin
    (Public/Elevation.ps1) has a command it can Mock in unit tests to simulate the underlying
    .NET call throwing (a static method call can't be mocked directly).
.RETURNS
    [Security.Principal.WindowsPrincipal] for the current process.
#>
function Get-CurrentWindowsPrincipal {
    [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
}

# Restart-WithElevation lives in Public/Elevation.ps1 (issue #190): it is exported so
# winget-app-uninstall.ps1 can reuse it instead of hand-rolling its own relaunch.

