# One installer run at a time on a machine (exit code 6): two runs side by side would fail each
# other's winget and msiexec installs with 'another installation is in progress'.

<#
.SYNOPSIS
    Returns the name of the machine-wide mutex that marks an installer run in progress.
.DESCRIPTION
    Global\ is shared by every session, so a run as SYSTEM (session 0) and a run on the desktop see
    the same mutex. A function so tests can use a name of their own.
.OUTPUTS
    [string]
#>
function Get-InstallerRunLockName {
    return 'Global\winget-app-setup-run'
}

<#
.SYNOPSIS
    Creates or opens a named mutex. A seam, so tests can make the open fail.
.PARAMETER Name
    The mutex name.
.OUTPUTS
    [System.Threading.Mutex]
#>
function New-InstallerRunMutex {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (New-Object System.Threading.Mutex($false, $Name))
}

<#
.SYNOPSIS
    Takes the machine-wide installer run lock, without waiting for it.
.DESCRIPTION
    The entry script takes it at the start of every elevated run that is not -WhatIf and exits 6
    when it is busy; Unlock-InstallerRun releases it in the entry script's finally block. The
    mutex of a run that was killed is abandoned, and the next run takes it over. Another account's
    mutex that this account may not open (UnauthorizedAccessException) counts as busy; any other
    failure warns and returns 'Unavailable', so the run goes on without the check. Any process
    holding the name counts as another run.
.PARAMETER Name
    The mutex name. Default: Get-InstallerRunLockName.
.OUTPUTS
    [string] 'Acquired' (the mutex is kept in $script:InstallerRunLock), 'Busy' or 'Unavailable'.
#>
function Lock-InstallerRun {
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = (Get-InstallerRunLockName)
    )

    $mutex = $null
    try {
        $mutex = New-InstallerRunMutex -Name $Name
    }
    catch [System.UnauthorizedAccessException] {
        return 'Busy'
    }
    catch {
        Write-WarningMessage "Could not check whether another run of the installer is in progress: $($_.Exception.Message.Trim().TrimEnd('.')). Continuing without that check."
        return 'Unavailable'
    }

    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # The run that held it ended without releasing it (killed, or its window closed); the mutex
        # now belongs to this run.
        $acquired = $true
    }
    catch {
        Write-WarningMessage "Could not check whether another run of the installer is in progress: $($_.Exception.Message.Trim().TrimEnd('.')). Continuing without that check."
        $mutex.Dispose()
        return 'Unavailable'
    }

    if (-not $acquired) {
        $mutex.Dispose()
        return 'Busy'
    }
    $script:InstallerRunLock = $mutex
    return 'Acquired'
}

<#
.SYNOPSIS
    Releases the installer run lock taken by Lock-InstallerRun, if this run holds it.
.DESCRIPTION
    Called from the entry script's finally block, so the lock is released on every way out of a
    run. Never throws: a release that fails (not on the owning thread) still closes the handle.
#>
function Unlock-InstallerRun {
    $mutex = $script:InstallerRunLock
    $script:InstallerRunLock = $null
    if ($null -eq $mutex) {
        return
    }
    try {
        $mutex.ReleaseMutex()
    }
    catch {
        # Not owned by this thread (any more); disposing below still closes the handle.
    }
    try {
        $mutex.Dispose()
    }
    catch {
    }
}
