# One installer run at a time on a machine (review finding P3-41, exit code 6). An RMM tool that
# starts the installer on a schedule, a teammate who starts it again while the first window is still
# working, or both at once, would otherwise run two installs side by side: winget and msiexec then
# fail each other's installs with 'another installation is in progress', and both runs report
# failures that neither caused.

<#
.SYNOPSIS
    Returns the name of the machine-wide mutex that marks an installer run in progress.
.DESCRIPTION
    Global\ puts it in the namespace every Windows session shares, so a run as SYSTEM from an RMM
    agent (session 0) and a run in someone's desktop session see the same mutex. A function so tests
    can give a run a name of its own and never collide with a real run on the same machine.
.RETURNS
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
.RETURNS
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
    Review finding P3-41. The generated entry script calls this at the start of every real
    (not -WhatIf) run that is elevated, before the pre-flight checks, and exits 6 when another run
    holds the lock: it neither waits for that run nor stops it. A run that is not elevated takes no
    lock, because it either stops with exit code 4 or relaunches itself elevated, and the elevated
    run takes the lock.

    The lock is a named mutex (Get-InstallerRunLockName) owned by the thread that runs the
    installer, and Unlock-InstallerRun releases it in the entry script's finally block. A run that is
    killed releases it with its process: the next run then finds the mutex abandoned, which Windows
    reports with AbandonedMutexException, and takes it over.

    Opening a mutex that another account created can fail with UnauthorizedAccessException when its
    access list does not let this account open it (a run as SYSTEM, then one by an administrator),
    and that counts as busy too. Any other failure warns and returns 'Unavailable': the run goes on
    without the check rather than being blocked by it.

    The lock does not check who holds the mutex. Windows lets any account create a mutex in the
    Global namespace, so 'Busy' means that some process on the machine holds this name, normally
    another run of the installer. A process that is not the installer and holds the name makes
    every run exit 6 until that process ends.
.PARAMETER Name
    The mutex name. Default: Get-InstallerRunLockName.
.RETURNS
    [string] 'Acquired' (the mutex is stored in $script:InstallerRunLock), 'Busy' (another run holds
    it) or 'Unavailable' (the check itself failed).
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
