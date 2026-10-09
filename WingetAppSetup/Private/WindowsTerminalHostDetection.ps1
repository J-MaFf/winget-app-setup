# Windows Terminal self-lock detection (issue #271). winget cannot replace the console-host files of
# a session Windows Terminal itself hosts: its launch fails with "Access is denied" until the session
# ends, so retries never recover. These helpers let the catalog skip that attempt instead.

<#
.SYNOPSIS
    Returns whether the current process's console session is hosted by Windows Terminal.
.DESCRIPTION
    Any one of three signals, cheapest first:
      1. $env:WT_SESSION, which Windows Terminal sets for everything in its tabs.
      2. The default terminal application values under HKCU:\Console\%%Startup
         (DelegationConsole/DelegationTerminal) naming Windows Terminal, which hands every new
         console (such as each step of a CI job) to it. The GUIDs must match
         Set-WindowsTerminalAsDefaultTerminalApplication's. Counted only while Windows Terminal is
         installed (Test-WindowsTerminalInstalled, P3-35): removing it leaves the values behind,
         and the console then falls back to conhost.
      3. A WindowsTerminal.exe or OpenConsole.exe among the parent processes (at most 10 hops).
    A probe that throws counts as "not hosted", so a broken probe never causes a skip.
.OUTPUTS
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
    Get-AppxPackage's answer for exactly 'Microsoft.WindowsTerminal' is final: Preview is another
    package with other default-terminal GUIDs, and a leftover settings.json is not an install
    (P3-34, P3-35). Only when Get-AppxPackage itself fails (PowerShell 7 where the Appx module
    cannot load, 0x80131539) does the stable package's settings.json stand in. Gates the default
    terminal setting (issue #271) and Test-WindowsTerminalHostsCurrentSession's registry signal.
.OUTPUTS
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
    Removes the default terminal application setting that names Windows Terminal when Windows
    Terminal is not installed for this account.
.DESCRIPTION
    Removing Windows Terminal leaves DelegationConsole and DelegationTerminal behind under
    HKCU:\Console\%%Startup (P3-18), and they would make it the default again if it came back. The
    uninstaller calls this once winget no longer lists Windows Terminal: when both values still name
    Windows Terminal and Test-WindowsTerminalInstalled finds none, both are removed, which is
    Windows' own default ("Let Windows decide"). Values naming another terminal are left alone. Per
    user: only the account running it changes.
.PARAMETER WhatIf
    Dry run: says what would be removed and changes nothing.
.OUTPUTS
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
