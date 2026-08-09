# Winget launch resilience helpers (issue #258). Start-Process can fail to launch winget.exe at
# all when the per-user app-execution alias under %LOCALAPPDATA%\Microsoft\WindowsApps is broken
# or locked - most commonly because the Microsoft.DesktopAppInstaller MSIX package is being
# upgraded or re-registered at that moment (e.g. by a background Winget-AutoUpdate run, which the
# installer itself kicks off via RUN_WAU=YES). These helpers classify that failure and resolve a
# concrete winget.exe path that bypasses the alias entirely, so retries can recover instead of
# hammering the same broken reparse point.

<#
.SYNOPSIS
    Returns true when a Start-Process exception message indicates a transient winget launch failure.
.DESCRIPTION
    Matches the two Win32 errors Start-Process surfaces as a terminating exception when winget.exe's
    own file is transiently inaccessible (issues #253/#258): ERROR_CANT_ACCESS_FILE (1920, "The file
    cannot be accessed by the system.") and the sibling ERROR_SHARING_VIOLATION ("...being used by
    another process."). Matched case-insensitively; anything else (e.g. winget genuinely missing
    from PATH) is a real failure the caller should not retry.
.PARAMETER Message
    The exception message to classify.
.RETURNS
    [bool]
#>
function Test-TransientWingetLaunchError {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    return $Message -match 'cannot be accessed by the system|being used by another process'
}

<#
.SYNOPSIS
    Resolves the winget executable to launch, optionally bypassing the app-execution alias.
.DESCRIPTION
    By default returns the bare command name 'winget', which Start-Process resolves through PATH to
    the per-user app-execution alias - the fast path that works whenever winget is healthy.

    With -BypassAlias, resolves the real winget.exe inside the registered
    Microsoft.DesktopAppInstaller package's install location instead (the documented workaround for
    contexts where the alias is unusable, e.g. SYSTEM). This matters during a DesktopAppInstaller
    upgrade (issue #258): the alias reparse point can stay broken or locked for the whole
    registration window, while Get-AppxPackage always reports the currently registered package - so
    re-resolving on each retry converges on a launchable executable as soon as the new package
    version lands. Falls back to 'winget' when the package (or its winget.exe) cannot be resolved,
    preserving the prior behavior.
.PARAMETER BypassAlias
    Resolve the concrete winget.exe under the DesktopAppInstaller package install location instead
    of relying on the PATH alias.
.RETURNS
    [string] An absolute path to winget.exe, or the bare command name 'winget'.
#>
function Resolve-WingetExecutable {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$BypassAlias
    )

    if (-not $BypassAlias) {
        return 'winget'
    }

    try {
        # Newest registered version first: mid-upgrade both old and new can briefly be visible, and
        # the newest is the one whose files are guaranteed to exist once registration completes.
        $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
            Sort-Object -Property { [version]$_.Version } -Descending |
            Select-Object -First 1
        if ($package -and $package.InstallLocation) {
            $candidate = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    catch {
        # Get-AppxPackage can fail under PowerShell 7 when the Appx compatibility session is
        # unavailable; the alias fallback below keeps the caller's retry loop functional.
    }

    return 'winget'
}
