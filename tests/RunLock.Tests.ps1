# RunLock.Tests.ps1
# Tests for WingetAppSetup/Private/RunLock.ps1: the machine-wide lock that keeps a second run of the
# installer from starting while one is in progress (review finding P3-41, exit code 6). The entry
# script's use of it (exit 6 in a child process) is tested in EntryPoint.Tests.ps1.
#
# These use real named mutexes, which .NET supports on every platform, each under a name of its own
# so nothing here meets a real run of the installer on the same machine. A mutex belongs to the
# thread that took it, and that thread can take it again, so "another run" is played by a second
# runspace with a thread of its own.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function New-TestLockName {
        'Global\winget-app-setup-test-' + [Guid]::NewGuid().ToString('N')
    }

    # Takes the mutex on another thread and keeps it until Stop-TestLockHolder.
    function Start-TestLockHolder {
        param ([string]$Name)
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript({ param ($LockName) $global:heldMutex = [System.Threading.Mutex]::new($false, $LockName); $global:heldMutex.WaitOne(0) }).AddArgument($Name)
        $acquired = @($shell.Invoke())[0]
        $shell.Dispose()
        $acquired | Should -BeTrue -Because 'the holder thread must own the mutex before the test runs'
        $runspace
    }

    # -Abandon ends the holder's thread without releasing the mutex, as a killed run would.
    function Stop-TestLockHolder {
        param ($Runspace, [switch]$Abandon)
        if (-not $Abandon) {
            $shell = [powershell]::Create()
            $shell.Runspace = $Runspace
            [void]$shell.AddScript({ $global:heldMutex.ReleaseMutex(); $global:heldMutex.Dispose() }).Invoke()
            $shell.Dispose()
        }
        $Runspace.Close()
        $Runspace.Dispose()
    }

    # Whether another thread can take the mutex right now (it releases it again at once).
    function Test-TestLockFree {
        param ([string]$Name)
        $shell = [powershell]::Create()
        [void]$shell.AddScript({
                param ($LockName)
                $mutex = [System.Threading.Mutex]::new($false, $LockName)
                try {
                    $taken = $mutex.WaitOne(0)
                }
                catch [System.Threading.AbandonedMutexException] {
                    $taken = $true
                }
                if ($taken) {
                    $mutex.ReleaseMutex()
                }
                $mutex.Dispose()
                $taken
            }).AddArgument($Name)
        $free = @($shell.Invoke())[0]
        $shell.Dispose()
        [bool]$free
    }
}

Describe 'Get-InstallerRunLockName (review finding P3-41)' {
    It 'Names one mutex in the namespace every Windows session shares' {
        # An RMM run as SYSTEM (session 0) and a run in someone's desktop session must meet.
        Get-InstallerRunLockName | Should -Be 'Global\winget-app-setup-run'
    }
}

Describe 'Lock-InstallerRun and Unlock-InstallerRun (review finding P3-41)' {
    BeforeEach {
        $script:InstallerRunLock = $null
        $script:lockName = New-TestLockName
        $script:holder = $null
        Mock Write-WarningMessage { }
    }

    AfterEach {
        Unlock-InstallerRun
        if ($script:holder) {
            Stop-TestLockHolder -Runspace $script:holder
        }
    }

    It 'Takes a free lock and keeps it until Unlock-InstallerRun releases it' {
        Lock-InstallerRun -Name $script:lockName | Should -Be 'Acquired'

        $script:InstallerRunLock | Should -BeOfType [System.Threading.Mutex]
        Test-TestLockFree -Name $script:lockName | Should -BeFalse -Because 'another run must find the lock taken'

        Unlock-InstallerRun

        $script:InstallerRunLock | Should -BeNullOrEmpty
        Test-TestLockFree -Name $script:lockName | Should -BeTrue -Because 'the next run must be able to take it'
    }

    It 'Takes the lock named by Get-InstallerRunLockName by default' {
        Mock Get-InstallerRunLockName { $script:lockName }

        Lock-InstallerRun | Should -Be 'Acquired'

        Test-TestLockFree -Name $script:lockName | Should -BeFalse
    }

    It 'Returns Busy at once, without waiting, when another run holds the lock' {
        $script:holder = Start-TestLockHolder -Name $script:lockName

        $elapsed = Measure-Command { $script:lockResult = Lock-InstallerRun -Name $script:lockName }

        $script:lockResult | Should -Be 'Busy'
        $elapsed.TotalSeconds | Should -BeLessThan 5 -Because 'a second run must not wait for the first'
        $script:InstallerRunLock | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 0
    }

    It 'Takes over a lock whose run ended without releasing it (killed, or its window closed)' {
        $abandoningHolder = Start-TestLockHolder -Name $script:lockName
        Stop-TestLockHolder -Runspace $abandoningHolder -Abandon

        Lock-InstallerRun -Name $script:lockName | Should -Be 'Acquired'

        $script:InstallerRunLock | Should -Not -BeNullOrEmpty
    }

    It 'Returns Busy when the mutex exists but this account may not open it (a run by another account)' {
        Mock New-InstallerRunMutex { throw [System.UnauthorizedAccessException]::new("Access to the path 'Global\winget-app-setup-run' is denied.") }

        Lock-InstallerRun -Name $script:lockName | Should -Be 'Busy'

        Should -Invoke Write-WarningMessage -Times 0
    }

    It 'Warns and returns Unavailable when the check itself fails, so the run is not blocked by it' {
        Mock New-InstallerRunMutex { throw [System.IO.IOException]::new('The handle is invalid.') }

        Lock-InstallerRun -Name $script:lockName | Should -Be 'Unavailable'

        $script:InstallerRunLock | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not check whether another run of the installer is in progress: The handle is invalid\. Continuing without that check\.' }
    }

    It 'Does nothing when no lock is held' {
        $script:InstallerRunLock = $null

        { Unlock-InstallerRun } | Should -Not -Throw
    }
}
