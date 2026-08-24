# Windows Terminal self-lock detection (issue #271). A scheduled/dispatched E2E run showed
# winget repeatedly fail to even LAUNCH while installing/verifying Microsoft.WindowsTerminal -
# "Access is denied" / "The file cannot be accessed by the system" - across 5 launch retries plus
# a full final retry pass, all failing identically, while every other catalog app installed fine
# in the same run. That failure shape (persistent, not transient; unique to this one package) does
# not match the DesktopAppInstaller re-registration race WingetLaunchResilience.ps1 already
# retries around (issue #258) - that lock clears once registration finishes, so retries recover.
# It matches a structural self-lock instead: when the CURRENT session's console is itself hosted
# by Windows Terminal (directly, via wt.exe, or delegated via the "default terminal application"
# registry setting), winget cannot safely replace the very console-host files rendering that
# session, and no amount of waiting fixes that - the lock only clears when the session ends. These
# helpers detect that condition so the caller can skip the doomed attempt instead of retrying it.

<#
.SYNOPSIS
    Returns whether the current process's console session is hosted by Windows Terminal.
.DESCRIPTION
    Checked via three independent signals, cheapest and most direct first. Any single positive
    match is sufficient:

      1. $env:WT_SESSION - set directly by Windows Terminal for anything running inside one of
         its panes/tabs. The standard, documented signal for "am I inside Windows Terminal".
      2. HKCU:\Console\%%Startup DelegationConsole/DelegationTerminal - the "default terminal
         application" values Set-WindowsTerminalAsDefaultTerminalApplication also writes. When
         these already point at Windows Terminal, a freshly created console with no inherited
         console (e.g. a new top-level pwsh.exe process - exactly what each step of a CI job
         spawns) is delegated to Windows Terminal's console host even though nothing launched
         wt.exe directly. The GUIDs here must stay in sync with
         Set-WindowsTerminalAsDefaultTerminalApplication.
      3. Process ancestry - walks parent processes (bounded to 10 hops) looking for
         WindowsTerminal.exe or OpenConsole.exe, covering direct wt.exe hosting that neither of
         the above catches.

    Fail-open throughout: any probe that throws (missing registry key, Get-CimInstance
    unavailable, non-Windows Pester run, restricted session) is treated as "not hosted" rather
    than propagating, so a broken probe can never cause an unnecessary skip.
.RETURNS
    [bool]
#>
function Test-WindowsTerminalHostsCurrentSession {
    [CmdletBinding()]
    param ()

    if (-not [string]::IsNullOrEmpty($env:WT_SESSION)) {
        return $true
    }

    try {
        $registryPath = 'HKCU:\Console\%%Startup'
        $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
        $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction Stop
        if ($existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal) {
            return $true
        }
    }
    catch {
        # No delegation key (default console host), or the registry provider is unavailable
        # (e.g. a non-Windows Pester run) - fall through to the ancestry check.
    }

    try {
        $currentProcessId = $PID
        for ($depth = 0; $depth -lt 10 -and $currentProcessId; $depth++) {
            $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $currentProcessId" -ErrorAction Stop
            if (-not $process) {
                break
            }
            if ($process.Name -in @('WindowsTerminal.exe', 'OpenConsole.exe')) {
                return $true
            }
            $currentProcessId = $process.ParentProcessId
        }
    }
    catch {
        # Best-effort only; a probe failure must never read as "hosted" (fail open).
    }

    return $false
}

<#
.SYNOPSIS
    Returns whether Windows Terminal is registered/installed for the current user.
.DESCRIPTION
    Prefers Get-AppxPackage (the authoritative package-registration check, same technique
    Resolve-WingetExecutable already uses for Microsoft.DesktopAppInstaller) and falls back to
    Get-WindowsTerminalSettingsPaths when Get-AppxPackage is unavailable (e.g. PowerShell 7
    without the Appx compatibility session). Used to gate Set-WindowsTerminalDefaults so it never
    configures Windows Terminal as the default terminal application when Windows Terminal is not
    actually present (issue #271) - doing so unconditionally is what let a single failed install
    attempt poison every subsequent console session on the machine.
.RETURNS
    [bool]
#>
function Test-WindowsTerminalInstalled {
    [CmdletBinding()]
    param ()

    try {
        $package = Get-AppxPackage -Name 'Microsoft.WindowsTerminal*' -ErrorAction Stop
        if ($package) {
            return $true
        }
    }
    catch {
        # Get-AppxPackage can fail under PowerShell 7 when the Appx compatibility session is
        # unavailable; the settings.json presence check below keeps this function functional.
    }

    return (Get-WindowsTerminalSettingsPaths).Count -gt 0
}
