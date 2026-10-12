# Whether Windows Installer is busy and whether a restart is pending. Read-only: the Windows
# Installer mutex is held only for the instant it takes to test it. Runs under Windows PowerShell 5.1
# too: .NET Framework 4.5 APIs only.

<#
.SYNOPSIS
    Returns whether Windows Installer is busy with another installation right now.
.DESCRIPTION
    While an installation runs, Windows Installer owns Global\_MSIExecute, and another MSI install
    fails at once with 1618 (winget's 0x8A150102). Busy means the mutex is owned, not that it
    exists: an idle mutex lives as long as any handle to it. So this opens it (none: idle) and tries
    to take it without waiting, as PSAppDeployToolkit does: taken (or abandoned) means idle, and it
    is released at once on the same thread; not taken means busy. For those microseconds another
    MSI could get 1618 itself, the same trade PSAppDeployToolkit makes. A mutex this account may not
    open counts as busy; callers bound their wait and then try anyway. The handle is always closed.
.PARAMETER Name
    The mutex name. Default 'Global\_MSIExecute'; tests pass a name of their own.
.OUTPUTS
    [bool]
#>
function Test-WindowsInstallerBusy {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = 'Global\_MSIExecute'
    )

    $mutex = $null
    $taken = $false
    try {
        if (-not [System.Threading.Mutex]::TryOpenExisting($Name, [ref]$mutex)) {
            return $false
        }
        try {
            $taken = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # Its owner ended without releasing it; this thread owns it now.
            $taken = $true
        }
        return (-not $taken)
    }
    catch [System.UnauthorizedAccessException] {
        # The mutex exists, but this account may not open it.
        return $true
    }
    catch {
        # Cannot tell; the install attempt itself is the real test.
        return $false
    }
    finally {
        if ($taken) {
            # Released before anything else, on the thread that took it: a mutex this run kept
            # would make every MSI on the PC fail with 1618 until the run ended.
            try {
                $mutex.ReleaseMutex()
            }
            catch {
                # Only possible if this thread no longer owned it.
            }
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

<#
.SYNOPSIS
    Waits, within a time limit, until Windows Installer is no longer busy with another installation.
.DESCRIPTION
    Used after winget's 0x8A150102 and before retrying the Winget-AutoUpdate msiexec after 1618.
    Checks Test-WindowsInstallerBusy every poll interval until it is idle or MaximumSeconds is
    reached, with a progress line every minute. Always waits at least one interval (or
    MaximumSeconds, if shorter): a chained installation takes the mutex again right after releasing
    it.
.PARAMETER MaximumSeconds
    The longest this call may wait. 0 or less: return at once without waiting.
.PARAMETER PollSeconds
    Seconds between checks. Default 15.
.PARAMETER Name
    The mutex name, passed to Test-WindowsInstallerBusy.
.OUTPUTS
    [pscustomobject] @{ WaitedSeconds = <int>; Busy = <bool> }. Busy is the last check: True when
    the time limit ran out with Windows Installer still busy.
#>
function Wait-WindowsInstallerIdle {
    param (
        [Parameter(Mandatory = $true)]
        [int]$MaximumSeconds,

        [Parameter(Mandatory = $false)]
        [int]$PollSeconds = 15,

        [Parameter(Mandatory = $false)]
        [string]$Name = 'Global\_MSIExecute'
    )

    if ($PollSeconds -lt 1) {
        $PollSeconds = 1
    }
    $waited = 0
    $busy = $true
    $nextProgressAt = 60
    while ($waited -lt $MaximumSeconds) {
        $step = [Math]::Min($PollSeconds, $MaximumSeconds - $waited)
        Start-Sleep -Seconds $step
        $waited += $step
        $busy = Test-WindowsInstallerBusy -Name $Name
        if (-not $busy) {
            break
        }
        if ($waited -ge $nextProgressAt -and $waited -lt $MaximumSeconds) {
            Write-Info ('Windows Installer is still busy with another installation ({0} of at most {1} seconds waited)...' -f $waited, $MaximumSeconds)
            $nextProgressAt += 60
        }
    }
    return [pscustomobject]@{ WaitedSeconds = $waited; Busy = $busy }
}

<#
.SYNOPSIS
    Reads whether Windows has a restart pending, and why.
.DESCRIPTION
    The indicators Configuration Manager and the DSC RebootPending resource read:
      ComponentServicing  ...\Component Based Servicing\RebootPending exists.
      WindowsUpdate       ...\WindowsUpdate\Auto Update\RebootRequired exists.
      FileRenames         Session Manager's PendingFileRenameOperations: file replacements queued
                          for the next restart, which is how an installer replaces a file in use.
    The value holds source and destination pairs; only replacements (a non-empty destination) are
    kept, because many programs queue deletes of temporary files that no install needs. An
    indicator that cannot be read counts as absent.
.OUTPUTS
    [pscustomobject] @{ ComponentServicing = <bool>; WindowsUpdate = <bool>; FileRenames = <string[]>
    ('<source> -> <destination>' per queued replacement) }
#>
function Get-PendingRestartState {
    $componentServicing = $false
    try {
        $componentServicing = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    }
    catch {
        $componentServicing = $false
    }

    $windowsUpdate = $false
    try {
        $windowsUpdate = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
    catch {
        $windowsUpdate = $false
    }

    $fileRenames = @()
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        $entries = @($sessionManager.PendingFileRenameOperations)
        for ($index = 0; $index -lt $entries.Count; $index += 2) {
            $source = [string]$entries[$index]
            $destination = ''
            if ($index + 1 -lt $entries.Count) {
                $destination = [string]$entries[$index + 1]
            }
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destination)) {
                continue
            }
            $fileRenames += ('{0} -> {1}' -f $source.Trim(), $destination.Trim())
        }
    }
    catch {
        # No value (nothing queued) or unreadable.
        $fileRenames = @()
    }

    return [pscustomobject]@{
        ComponentServicing = $componentServicing
        WindowsUpdate      = $windowsUpdate
        FileRenames        = @($fileRenames)
    }
}

<#
.SYNOPSIS
    Lists why a restart is pending, or with -Since, the reasons that appeared since an earlier state.
.DESCRIPTION
    With -Since (the state at the start of the run), what was already pending is left out, so a
    restart pending before the run does not make the run's own result 3010.
.PARAMETER State
    A Get-PendingRestartState result.
.PARAMETER Since
    An earlier Get-PendingRestartState result. Optional.
.OUTPUTS
    [string[]] Nothing when nothing is pending (or nothing new); call it inside @().
#>
function Get-PendingRestartReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Since
    )

    if ($null -eq $State) {
        return
    }

    $reasons = @()
    if ($State.ComponentServicing -and -not ($Since -and $Since.ComponentServicing)) {
        $reasons += 'Windows component servicing has a restart pending'
    }
    if ($State.WindowsUpdate -and -not ($Since -and $Since.WindowsUpdate)) {
        $reasons += 'Windows Update has a restart pending'
    }

    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Since) {
        foreach ($rename in @($Since.FileRenames)) {
            [void]$known.Add([string]$rename)
        }
    }
    $newRenames = @(@($State.FileRenames) | Where-Object { $_ -and -not $known.Contains([string]$_) })
    if ($newRenames.Count -gt 0) {
        $renameWord = if ($newRenames.Count -eq 1) { 'file replacement is' } else { 'file replacements are' }
        $reasons += ('{0} {1} queued for the next restart' -f $newRenames.Count, $renameWord)
    }
    return $reasons
}
