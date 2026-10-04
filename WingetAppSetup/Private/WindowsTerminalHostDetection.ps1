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
         Set-WindowsTerminalAsDefaultTerminalApplication. Counted only while Windows Terminal is
         installed (Test-WindowsTerminalInstalled, review finding P3-35): nothing clears these
         values when Windows Terminal is removed, and a delegation to a Windows Terminal that is
         not there cannot host anything (the console falls back to conhost), so on its own it
         made the catalog skip the Windows Terminal install as 'not applicable' on every run.
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
            $existingValues.DelegationTerminal -eq $delegationTerminal -and
            (Test-WindowsTerminalInstalled)) {
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
    Returns whether Windows Terminal (the stable Microsoft.WindowsTerminal package) is registered
    for the current user.
.DESCRIPTION
    Asks Get-AppxPackage for exactly 'Microsoft.WindowsTerminal', and its answer is final (review
    findings P3-34, P3-35): Windows Terminal Preview is a different package with different
    default-terminal GUIDs, and a settings.json left behind by a removed or unpackaged Windows
    Terminal is not an installed one. Only when Get-AppxPackage itself fails (PowerShell 7 on
    builds where the Appx module cannot load, 0x80131539) does the stable package's own
    settings.json stand in for it.

    Used to gate Set-WindowsTerminalDefaults so it never configures Windows Terminal as the
    default terminal application when Windows Terminal is not actually present (issue #271) -
    doing so unconditionally is what let a single failed install attempt poison every subsequent
    console session on the machine - and by Test-WindowsTerminalHostsCurrentSession, which counts
    those default-terminal values only while Windows Terminal is installed.
.RETURNS
    [bool]
#>
function Test-WindowsTerminalInstalled {
    [CmdletBinding()]
    param ()

    try {
        return [bool](Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction Stop)
    }
    catch {
        # Get-AppxPackage can fail under PowerShell 7 when the Appx module cannot load; the stable
        # package's settings.json (its LocalState folder goes when the package is removed) is the
        # next best sign.
    }

    return @(Get-WindowsTerminalSettingsPaths | Where-Object { $_ -match '\\Packages\\Microsoft\.WindowsTerminal_8wekyb3d8bbwe\\' }).Count -gt 0
}

<#
.SYNOPSIS
    Removes the "default terminal application" setting that names Windows Terminal when Windows
    Terminal is not installed for this account.
.DESCRIPTION
    Set-WindowsTerminalAsDefaultTerminalApplication writes DelegationConsole and DelegationTerminal
    under HKCU:\Console\%%Startup. Removing Windows Terminal leaves them behind (review finding
    P3-18). Windows then falls back to the console host, but Test-WindowsTerminalHostsCurrentSession
    still reads the values as "this session is hosted by Windows Terminal", so the installer would
    skip Microsoft.WindowsTerminal as not applicable on every later run. The uninstaller calls this
    after its app loop once winget no longer lists Windows Terminal: when both values still name
    Windows Terminal (the values the installer writes) and Test-WindowsTerminalInstalled finds no
    Windows Terminal either, both are removed, which is Windows' own default ("Let Windows
    decide"). Values naming another terminal (Windows Terminal
    Preview, the console host) are left alone, and so is everything while a Windows Terminal is
    installed. The values are per-user: this changes only the account running it.
.PARAMETER WhatIf
    Dry run: says what would be removed and changes nothing.
.RETURNS
    [bool] True when the values were removed (under -WhatIf: would be removed).
#>
function Reset-WindowsTerminalDelegation {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # The values Set-WindowsTerminalAsDefaultTerminalApplication writes.
    $registryPath = 'HKCU:\Console\%%Startup'
    $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

    try {
        $values = Get-ItemProperty -Path $registryPath -ErrorAction Stop
    }
    catch {
        # No such key: nothing names Windows Terminal.
        return $false
    }
    if ($values.DelegationConsole -ne $delegationConsole -or $values.DelegationTerminal -ne $delegationTerminal) {
        return $false
    }
    if (Test-WindowsTerminalInstalled) {
        return $false
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would remove the default terminal application setting ($registryPath DelegationConsole and DelegationTerminal), which names Windows Terminal although it is not installed."
        return $true
    }
    try {
        Remove-ItemProperty -Path $registryPath -Name 'DelegationConsole', 'DelegationTerminal' -ErrorAction Stop
        Write-Success 'Removed the default terminal application setting that named Windows Terminal, which is not installed: Windows chooses the terminal again.'
        return $true
    }
    catch {
        Write-WarningMessage "Could not remove the default terminal application setting that names Windows Terminal ($registryPath): $_"
        return $false
    }
}
