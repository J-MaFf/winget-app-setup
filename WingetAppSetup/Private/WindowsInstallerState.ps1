# Machine state that decides whether an install can run now or needs a restart (review findings
# P2-15 and P3-16): whether Windows Installer is busy with another installation, and whether Windows
# has a restart pending. Read-only: nothing here changes the registry, and the Windows Installer
# mutex is only ever held for the instant it takes to test it (Test-WindowsInstallerBusy). Runs under
# Windows PowerShell 5.1 too: .NET Framework 4.5 APIs only.

<#
.SYNOPSIS
    Returns whether Windows Installer is busy with another installation right now.
.DESCRIPTION
    Windows Installer owns the Global\_MSIExecute mutex while an installation runs its execute
    sequence, and any other MSI install started meanwhile fails at once with 1618
    (ERROR_INSTALL_ALREADY_RUNNING), which winget reports as 0x8A150102. The busy signal is that
    the mutex is owned, not that it exists: the mutex object lives as long as any process holds a
    handle to it, released or not, so a check for existence alone could read busy for as long as
    that handle stays open and run every wait to its time limit.

    So the check opens the mutex (Mutex.TryOpenExisting; none of that name: idle) and tries to take
    it without waiting (WaitOne(0)), the same test PSAppDeployToolkit's Test-ADTMutexAvailability
    makes. Taken: nobody owned it, so Windows Installer is idle, and the mutex is released again at
    once, on the same thread. A mutex whose owner ended without releasing it (abandoned) is taken
    the same way and counts as idle. Not taken: an installation owns it, busy. For that instant an
    MSI starting its execute sequence on another process could get 1618 itself; the window is a few
    microseconds once per poll interval, the trade PSAppDeployToolkit makes before every MSI it
    runs. A mutex that this account may not open (TryOpenExisting asks for the rights to wait on
    and release it) counts as busy, without ever taking it; callers bound how long they wait and
    then try the install anyway. The handle is always closed, so this check never keeps the mutex
    alive.
.PARAMETER Name
    The mutex name. Default 'Global\_MSIExecute'; tests pass a name of their own.
.RETURNS
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
    Used after winget reported 0x8A150102 (another installation in progress, msiexec 1618) and
    before the Winget-AutoUpdate msiexec is retried after 1618. Sleeps one poll interval, then
    checks Test-WindowsInstallerBusy every poll interval until it reports idle or MaximumSeconds is
    reached, printing a progress line every minute so a long wait shows in the transcript. Always
    waits at least one poll interval (or MaximumSeconds, if shorter): 1618 means the installer was
    busy a moment ago, and a chained installation (a bundle installing several MSIs in turn) takes
    the mutex again right after releasing it.
.PARAMETER MaximumSeconds
    The longest this call may wait. 0 or less: return at once without waiting.
.PARAMETER PollSeconds
    Seconds between checks. Default 15.
.PARAMETER Name
    The mutex name, passed to Test-WindowsInstallerBusy.
.RETURNS
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
    Reads the indicators Configuration Manager's pending-restart prerequisite check and Microsoft's
    DSC RebootPending resource use:

      ComponentServicing  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based
                          Servicing\RebootPending exists (Windows servicing, features, updates).
      WindowsUpdate       HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto
                          Update\RebootRequired exists.
      FileRenames         HKLM\SYSTEM\CurrentControlSet\Control\Session Manager
                          PendingFileRenameOperations: the file replacements queued for the next
                          restart (MoveFileEx MOVEFILE_DELAY_UNTIL_REBOOT), which is how an MSI or
                          Inno installer finishes replacing a file that was in use.

    The value holds pairs of entries: a source, then a destination that is empty for a delete. Only
    replacements (a non-empty destination) are kept. Queued deletes are left out: many programs
    queue them to clean up temporary or rollback files (Edge Update, for example), and an install is
    complete without them, so they would report a restart that nothing needs.

    Best-effort and read-only: an indicator that cannot be read counts as absent.
.RETURNS
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
    Turns a Get-PendingRestartState result into short reasons for the summary. With -Since (the state
    read at the start of the run), only what appeared during the run counts: an indicator that was
    already present, or a file replacement that was already queued, is left out, so a restart that
    was pending before the run is reported as such and does not make the run's own result 'restart
    required' (exit code 3010).
.PARAMETER State
    A Get-PendingRestartState result.
.PARAMETER Since
    An earlier Get-PendingRestartState result. Optional.
.RETURNS
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
