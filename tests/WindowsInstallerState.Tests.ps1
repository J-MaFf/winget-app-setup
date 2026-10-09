# WindowsInstallerState.Tests.ps1
# Tests for WingetAppSetup/Private/WindowsInstallerState.ps1: whether Windows Installer is busy with
# another installation (review finding P2-15) and whether Windows has a restart pending (P3-16).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-WindowsInstallerBusy' {
    # Real named mutexes with a name of their own (never Global\_MSIExecute, which would make a real
    # MSI install on the test machine fail with 1618 while the test holds it). No Global\ prefix
    # either: creating a global object needs a privilege a standard user may not have. A mutex
    # belongs to a thread, and the thread that owns one can always take it again, so the "other
    # installation" holds it on a thread of its own: a runspace whose every invocation runs on a
    # new thread (PSThreadOptions.UseNewThread).
    BeforeAll {
        function Invoke-OnOtherThread {
            param (
                [Parameter(Mandatory = $true)]
                [scriptblock]$ScriptBlock,

                [Parameter(Mandatory = $false)]
                [object[]]$ArgumentList = @()
            )

            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
            $runspace.Open()
            $shell = [powershell]::Create()
            try {
                $shell.Runspace = $runspace
                [void]$shell.AddScript($ScriptBlock.ToString())
                foreach ($argument in $ArgumentList) {
                    [void]$shell.AddArgument($argument)
                }
                return $shell.Invoke()
            }
            finally {
                $shell.Dispose()
                $runspace.Dispose()
            }
        }

        # Whether a thread other than the test's can take the mutex right now: false while anyone
        # else, the busy check included, still owns it.
        function Test-TakenOnOtherThread {
            param ([string]$Name)

            @(Invoke-OnOtherThread -ArgumentList $Name -ScriptBlock {
                    param ($Name)
                    $mutex = [System.Threading.Mutex]::OpenExisting($Name)
                    try {
                        $taken = $false
                        try {
                            $taken = $mutex.WaitOne(0)
                        }
                        catch [System.Threading.AbandonedMutexException] {
                            $taken = $true
                        }
                        if ($taken) {
                            $mutex.ReleaseMutex()
                        }
                        $taken
                    }
                    finally {
                        $mutex.Dispose()
                    }
                })[-1]
        }
    }

    BeforeEach {
        $script:mutexName = 'winget-app-setup-test-' + [guid]::NewGuid().ToString('N')
    }

    It 'Is false while no mutex of that name exists' {
        Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeFalse
    }

    It 'Is true while another thread owns the mutex, and false once that owner has released it' {
        $acquired = [System.Threading.ManualResetEvent]::new($false)
        $release = [System.Threading.ManualResetEvent]::new($false)
        $owner = [powershell]::Create()
        try {
            [void]$owner.AddScript({
                    param ($Name, $Acquired, $Release)
                    $mutex = [System.Threading.Mutex]::new($true, $Name)
                    [void]$Acquired.Set()
                    [void]$Release.WaitOne(30000)
                    $mutex.ReleaseMutex()
                    $mutex.Dispose()
                }).AddArgument($script:mutexName).AddArgument($acquired).AddArgument($release)
            $ownerRun = $owner.BeginInvoke()
            $acquired.WaitOne(10000) | Should -BeTrue -Because 'the other thread must own the mutex before the check runs'

            Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeTrue
            Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeTrue
        }
        finally {
            [void]$release.Set()
            if ($ownerRun) {
                $owner.EndInvoke($ownerRun)
            }
            $owner.Dispose()
        }

        # Once that installation has finished, the check reads idle.
        Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeFalse
    }

    It 'Is false while the mutex exists but nobody owns it, and leaves it free for the next installation' {
        # Another process still has a handle to the released mutex (the review's msiexec service
        # case): the mutex exists, but no installation is running.
        $handle = [System.Threading.Mutex]::new($false, $script:mutexName)
        try {
            Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeFalse
            Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeFalse

            # The check released what it took: another thread can take the mutex at once.
            Test-TakenOnOtherThread -Name $script:mutexName | Should -BeTrue
        }
        finally {
            $handle.Dispose()
        }
    }

    It 'Is false for a mutex whose owner ended without releasing it, and releases it' {
        $handle = [System.Threading.Mutex]::new($false, $script:mutexName)
        try {
            # Take it on a thread that then ends: the mutex is abandoned.
            $ownerThread = @(Invoke-OnOtherThread -ArgumentList $script:mutexName -ScriptBlock {
                    param ($Name)
                    $mutex = [System.Threading.Mutex]::OpenExisting($Name)
                    [void]$mutex.WaitOne(0)
                    [System.Threading.Thread]::CurrentThread
                })[-1]
            $ownerThread.Join(10000) | Should -BeTrue -Because 'the owning thread must have ended for the mutex to be abandoned'

            Test-WindowsInstallerBusy -Name $script:mutexName | Should -BeFalse

            # Released, not kept by the test's thread.
            Test-TakenOnOtherThread -Name $script:mutexName | Should -BeTrue
        }
        finally {
            $handle.Dispose()
        }
    }

    It 'Leaves no handle open that would keep the mutex alive' {
        $handle = [System.Threading.Mutex]::new($false, $script:mutexName)
        [void](Test-WindowsInstallerBusy -Name $script:mutexName)
        $handle.Dispose()

        $reopened = $null
        [System.Threading.Mutex]::TryOpenExisting($script:mutexName, [ref]$reopened) | Should -BeFalse
        if ($reopened) {
            $reopened.Dispose()
        }
    }

    It 'Checks Global\_MSIExecute, the mutex Windows Installer holds during an installation, by default' {
        $definition = (Get-Command Test-WindowsInstallerBusy).ScriptBlock.Ast
        $default = $definition.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Name' }
        $default.DefaultValue.Value | Should -BeExactly 'Global\_MSIExecute'
    }
}

Describe 'Wait-WindowsInstallerIdle' {
    BeforeEach {
        Mock Write-Info { }
        $script:slept = @()
        Mock Start-Sleep { $script:slept += $Seconds }
        $script:busyAnswers = @()
        $script:busyCalls = 0
        Mock Test-WindowsInstallerBusy {
            $answer = $script:busyAnswers[[Math]::Min($script:busyCalls, $script:busyAnswers.Count - 1)]
            $script:busyCalls++
            $answer
        }
    }

    It 'Waits one poll interval, then returns as soon as Windows Installer is idle' {
        $script:busyAnswers = @($true, $true, $false)

        $result = Wait-WindowsInstallerIdle -MaximumSeconds 600

        $result.WaitedSeconds | Should -Be 45
        $result.Busy | Should -BeFalse
        $script:slept | Should -Be @(15, 15, 15)
    }

    It 'Waits at least one poll interval even when Windows Installer is already idle' {
        $script:busyAnswers = @($false)

        $result = Wait-WindowsInstallerIdle -MaximumSeconds 600

        $result.WaitedSeconds | Should -Be 15
        $result.Busy | Should -BeFalse
    }

    It 'Stops at its time limit while Windows Installer is still busy, and says so' {
        $script:busyAnswers = @($true)

        $result = Wait-WindowsInstallerIdle -MaximumSeconds 100

        $result.WaitedSeconds | Should -Be 100
        $result.Busy | Should -BeTrue
        # Six full intervals, then the 10 seconds that were left.
        $script:slept | Should -Be @(15, 15, 15, 15, 15, 15, 10)
        # A progress line once a minute, so a long wait shows in the transcript.
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -like 'Windows Installer is still busy*' }
    }

    It 'Does not wait at all with no time left' {
        $result = Wait-WindowsInstallerIdle -MaximumSeconds 0

        $result.WaitedSeconds | Should -Be 0
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Test-WindowsInstallerBusy -Times 0 -Exactly
    }
}

Describe 'Get-PendingRestartState' {
    BeforeAll {
        $script:cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $script:wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $script:sessionManagerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    }

    BeforeEach {
        # The registry is read through these two commands only; nothing is pending by default.
        Mock Test-Path { $false }
        Mock Get-ItemProperty { throw 'Property PendingFileRenameOperations does not exist.' }
    }

    It 'Reports nothing pending when no indicator is present' {
        $state = Get-PendingRestartState

        $state.ComponentServicing | Should -BeFalse
        $state.WindowsUpdate | Should -BeFalse
        @($state.FileRenames).Count | Should -Be 0
    }

    It 'Reads the component-servicing and Windows Update keys' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:cbsKey }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:wuKey }

        $state = Get-PendingRestartState

        $state.ComponentServicing | Should -BeTrue
        $state.WindowsUpdate | Should -BeTrue
    }

    It 'Keeps the queued file replacements and leaves out the queued deletes' {
        # Pairs of source and destination; an empty destination is a delete (Edge Update's log
        # cleanup, MSI rollback files). The last pair is a delete whose empty destination the
        # registry API may drop.
        Mock Get-ItemProperty {
            [pscustomobject]@{
                PendingFileRenameOperations = @(
                    '\??\C:\Program Files (x86)\Microsoft\EdgeUpdate\Log\old.log', '',
                    '\??\C:\Program Files\7-Zip\7-zip.dll.new', '!\??\C:\Program Files\7-Zip\7-zip.dll',
                    '\??\C:\Config.Msi\3a1b2c.rbf'
                )
            }
        } -ParameterFilter { $LiteralPath -eq $script:sessionManagerKey -and $Name -eq 'PendingFileRenameOperations' }

        $state = Get-PendingRestartState

        $state.FileRenames | Should -Be @('\??\C:\Program Files\7-Zip\7-zip.dll.new -> !\??\C:\Program Files\7-Zip\7-zip.dll')
    }

    It 'Treats an indicator it cannot read as absent instead of failing' {
        Mock Test-Path { throw 'Requested registry access is not allowed.' }

        $state = Get-PendingRestartState

        $state.ComponentServicing | Should -BeFalse
        $state.WindowsUpdate | Should -BeFalse
    }
}

Describe 'Get-PendingRestartReason' {
    It 'Lists every indicator that is present' {
        $state = New-TestRestartState -ComponentServicing -WindowsUpdate -FileRenames @('a -> b')

        $reasons = @(Get-PendingRestartReason -State $state)

        $reasons | Should -Be @(
            'Windows component servicing has a restart pending'
            'Windows Update has a restart pending'
            '1 file replacement is queued for the next restart'
        )
    }

    It 'With -Since, lists only what appeared since the earlier state' {
        $before = New-TestRestartState -WindowsUpdate -FileRenames @('a -> b')
        $after = New-TestRestartState -ComponentServicing -WindowsUpdate -FileRenames @('A -> B', 'c -> d', 'e -> f')

        $reasons = @(Get-PendingRestartReason -State $after -Since $before)

        # Windows Update and the a -> b replacement (compared case-insensitively) were already there.
        $reasons | Should -Be @(
            'Windows component servicing has a restart pending'
            '2 file replacements are queued for the next restart'
        )
    }

    It 'Lists nothing when nothing changed, or when there is no state' {
        $state = New-TestRestartState -WindowsUpdate -FileRenames @('a -> b')

        @(Get-PendingRestartReason -State $state -Since $state).Count | Should -Be 0
        @(Get-PendingRestartReason -State $null).Count | Should -Be 0
    }
}
