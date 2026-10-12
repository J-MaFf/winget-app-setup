# SystemHandoff.Tests.ps1
# Tests for WingetAppSetup/Private/SystemHandoff.ps1 (wgt-gq8.68): under cross-user elevation, a
# winget source that stays closed hands the install over to a one-shot scheduled task that runs a
# checked copy of the installer as SYSTEM. Every scheduled-task cmdlet is mocked; the copy and the
# run record are real files in TestDrive.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Get-InstallAccountContext as the SYSTEM task''s run sees it' {
    It 'Never reports SYSTEM as cross-user, even with another user signed in, so the hand-over cannot loop' {
        Mock Test-IsSystemAccount { $true }
        Mock Get-ProcessUserName { 'NT AUTHORITY\SYSTEM' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\stduser' }

        $context = Get-InstallAccountContext

        $context.IsSystem | Should -BeTrue
        $context.IsCrossUserElevation | Should -BeFalse
    }
}

Describe 'Find-MachinePowerShell7' {
    BeforeEach {
        $script:savedProgramW6432 = $env:ProgramW6432
        $script:savedProgramFiles = $env:ProgramFiles
        # TestDrive lasts for the whole Describe, so each test gets its own folders.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:ProgramW6432 = Join-Path $root 'Program Files'
        $env:ProgramFiles = Join-Path $root 'Program Files (x86)'
        Mock Test-PowerShell7Executable { $true }
    }

    AfterEach {
        $env:ProgramW6432 = $script:savedProgramW6432
        $env:ProgramFiles = $script:savedProgramFiles
    }

    It 'Returns the PowerShell 7 installed for the whole PC, from the 64-bit Program Files first' {
        $pwsh = Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe'
        [void](New-Item -ItemType File -Path $pwsh -Force)
        [void](New-Item -ItemType File -Path (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') -Force)

        Find-MachinePowerShell7 | Should -Be $pwsh
    }

    It 'Returns nothing when no PowerShell 7 is installed there' {
        Find-MachinePowerShell7 | Should -BeNullOrEmpty

        Should -Invoke Test-PowerShell7Executable -Times 0 -Exactly
    }

    It 'Passes over a pwsh.exe that does not start as PowerShell 7' {
        $broken = Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe'
        $script:working = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        [void](New-Item -ItemType File -Path $broken -Force)
        [void](New-Item -ItemType File -Path $script:working -Force)
        Mock Test-PowerShell7Executable { $Path -eq $script:working }

        Find-MachinePowerShell7 | Should -Be $script:working
    }
}

Describe 'The SYSTEM task''s command line and definition' {
    It 'Runs the copy non-interactively, with -SkipSystemCheck and the time budget when given' {
        Get-SystemHandoffTaskArgument -ScriptPath 'C:\ProgramData\winget-app-setup\system-handoff-0123\winget-app-install.ps1' |
            Should -Be '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\winget-app-setup\system-handoff-0123\winget-app-install.ps1" -NonInteractive'

        Get-SystemHandoffTaskArgument -ScriptPath 'C:\copy\winget-app-install.ps1' -SkipSystemCheck -BudgetArguments @('-MaxRuntimeMinutes', '60', '-RunDeadlineUtc', '2026-10-12T15:00:00Z') |
            Should -Be '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\copy\winget-app-install.ps1" -NonInteractive -SkipSystemCheck -MaxRuntimeMinutes 60 -RunDeadlineUtc 2026-10-12T15:00:00Z'
    }

    It 'Accepts no budget argument that could add a command' {
        { Get-SystemHandoffTaskArgument -ScriptPath 'C:\copy\winget-app-install.ps1' -BudgetArguments @('60; calc') } | Should -Throw
    }

    It 'Defines a task for SYSTEM, by its SID, at the highest run level, with no trigger and a time limit' {
        $xml = [xml](New-SystemHandoffTaskXml -Command 'C:\Program Files\PowerShell\7\pwsh.exe' -Arguments '-File "C:\copy\a&b.ps1" -NonInteractive' -TimeLimitSeconds 10800)

        $xml.Task.Principals.Principal.UserId | Should -Be 'S-1-5-18'
        $xml.Task.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
        $xml.Task.Actions.Exec.Command | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $xml.Task.Actions.Exec.Arguments | Should -Be '-File "C:\copy\a&b.ps1" -NonInteractive'
        $xml.Task.Settings.ExecutionTimeLimit | Should -Be 'PT185M'
        $xml.Task.Settings.DisallowStartIfOnBatteries | Should -Be 'false'
        $xml.Task.Triggers | Should -BeNullOrEmpty
    }
}

Describe 'Get-SystemHandoffWaitSeconds' {
    It 'Waits up to 3 hours without a time budget' {
        Get-SystemHandoffWaitSeconds -Budget $null | Should -Be 10800
    }

    It 'Waits what is left of the time budget plus 45 minutes' {
        $budget = [pscustomobject]@{ Minutes = 60; DeadlineUtc = [DateTime]::UtcNow.AddSeconds(600); MinutesGiven = $true }

        $seconds = Get-SystemHandoffWaitSeconds -Budget $budget

        $seconds | Should -BeGreaterOrEqual 3290
        $seconds | Should -BeLessOrEqual 3300
    }

    It 'Waits 45 minutes once the budget is used up' {
        $budget = [pscustomobject]@{ Minutes = 60; DeadlineUtc = [DateTime]::UtcNow.AddMinutes(-5); MinutesGiven = $true }

        Get-SystemHandoffWaitSeconds -Budget $budget | Should -Be 2700
    }
}

Describe 'Copy-SystemHandoffInstaller and Test-SystemHandoffCopy' {
    BeforeEach {
        $script:installer = Join-Path $TestDrive 'winget-app-install.ps1'
        Set-Content -LiteralPath $script:installer -Value "Write-Host 'installer build 1'" -Encoding utf8
        $script:installerSha256 = (Get-FileHash -LiteralPath $script:installer -Algorithm SHA256).Hash
        $script:staging = Join-Path $TestDrive ('system-handoff-' + [guid]::NewGuid().ToString('N'))
        Mock New-WauStagingDirectory { [void](New-Item -ItemType Directory -Path $script:staging -Force); $script:staging }
    }

    It 'Copies the installer into a staging folder of its own, when it still has the SHA256 the run started with' {
        $copy = Copy-SystemHandoffInstaller -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256.ToLowerInvariant()

        $copy.Directory | Should -Be $script:staging
        $copy.Path | Should -Be (Join-Path $script:staging 'winget-app-install.ps1')
        $copy.Sha256 | Should -Be $script:installerSha256
        (Get-FileHash -LiteralPath $copy.Path -Algorithm SHA256).Hash | Should -Be $script:installerSha256
        Should -Invoke New-WauStagingDirectory -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'system-handoff' }
        Test-SystemHandoffCopy -Path $copy.Path -Sha256 $copy.Sha256 | Should -BeTrue
    }

    It 'Copies nothing when the installer changed after the run started' {
        { Copy-SystemHandoffInstaller -ScriptPath $script:installer -ExpectedSha256 ('AB' * 32) } | Should -Throw '*changed after this run started*'

        Should -Invoke New-WauStagingDirectory -Times 0 -Exactly
    }

    It 'Fails the check of a copy that changed, or is gone' {
        $copy = Copy-SystemHandoffInstaller -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256
        Add-Content -LiteralPath $copy.Path -Value 'Start-Process calc'

        Test-SystemHandoffCopy -Path $copy.Path -Sha256 $copy.Sha256 | Should -BeFalse
        Test-SystemHandoffCopy -Path (Join-Path $TestDrive 'missing.ps1') -Sha256 $copy.Sha256 | Should -BeFalse
    }
}

Describe 'Wait-SystemHandoffTask' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Write-Info { }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        $script:started = [DateTime]::UtcNow
    }

    It 'Returns the exit code once the task has run and is no longer running' {
        $script:looks = 0
        Mock Get-ScheduledTask {
            $script:looks++
            if ($script:looks -lt 3) { return [pscustomobject]@{ State = 'Running' } }
            [pscustomobject]@{ State = 'Ready' }
        }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = 3010; LastRunTime = Get-Date } }

        Wait-SystemHandoffTask -TaskName 'winget-app-setup-system-x' -StartedUtc $script:started -TimeoutSeconds 60 | Should -Be 3010

        Should -Invoke Get-ScheduledTask -Times 3 -Exactly -ParameterFilter { $TaskName -eq 'winget-app-setup-system-x' }
    }

    It 'Turns an unsigned LastTaskResult into the exit code the process returned' {
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = [long]4294967295; LastRunTime = Get-Date } }

        Wait-SystemHandoffTask -TaskName 'x' -StartedUtc $script:started -TimeoutSeconds 60 | Should -Be -1
    }

    It 'Returns nothing when the task is still running, has not run, or ran before it was started, at the time limit' -ForEach @(
        @{ Case = 'still running'; Result = 267009; RunMinutesAgo = 0 }
        @{ Case = 'not yet run'; Result = 267011; RunMinutesAgo = 0 }
        @{ Case = 'an earlier run'; Result = 0; RunMinutesAgo = 30 }
    ) {
        Mock Start-Sleep { [System.Threading.Thread]::Sleep(100) }
        $script:taskResult = $Result
        $script:taskRunTime = (Get-Date).AddMinutes(-$RunMinutesAgo)
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = $script:taskResult; LastRunTime = $script:taskRunTime } }

        Wait-SystemHandoffTask -TaskName 'x' -StartedUtc $script:started -TimeoutSeconds 1 | Should -BeNullOrEmpty
    }
}

Describe 'Read-SystemHandoffRunRecord' {
    BeforeAll {
        function Save-TestSystemRecord {
            param ([DateTime]$StartedUtc, [string]$BuildId = '1.0.0+5ea1f00d', [AllowNull()]$ExitCode = 0)
            $script:InstallerRunStartedUtc = $StartedUtc
            $script:InstallerBuildId = $BuildId
            $script:InstallLogPath = 'C:\ProgramData\winget-app-setup\logs\install-20261012-101500.log'
            $record = New-InstallerRunRecord -ExitCode 0 -Apps @(
                (New-AppRunRecord -Id '7zip.7zip' -Status 'Installed'),
                (New-AppRunRecord -Id 'Microsoft.WindowsTerminal' -Status 'Deferred' -Reason 'per-user app')
            ) -SummaryReached
            $record.exitCode = $ExitCode
            [void](Save-InstallerRunRecord -Record $record -Directory $script:recordDirectory)
            $script:InstallerRunStartedUtc = $null
            $script:InstallerBuildId = $null
            $script:InstallLogPath = $null
        }
    }

    BeforeEach {
        Mock Write-WarningMessage { }
        # The record as a run as SYSTEM leaves it (Get-RunRecordTrustProblem).
        Mock Get-Acl { New-TestFileAcl }
        $script:recordDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:recordDirectory -Force)
        $script:recordPath = Join-Path $script:recordDirectory 'last-run.json'
        $script:taskStarted = [DateTime]::new(2026, 10, 12, 10, 15, 0, [DateTimeKind]::Utc)
    }

    It 'Reads the SYSTEM run''s record and its deferred apps' {
        Save-TestSystemRecord -StartedUtc $script:taskStarted.AddSeconds(4)

        $read = Read-SystemHandoffRunRecord -StartedUtc $script:taskStarted -BuildId '1.0.0+5ea1f00d' -Path $script:recordPath

        $read.Problem | Should -BeNullOrEmpty
        $read.Record.DeferredApps | Should -Be @('Microsoft.WindowsTerminal')
        $read.Record.Record.transcriptPath | Should -Be 'C:\ProgramData\winget-app-setup\logs\install-20261012-101500.log'
    }

    It 'Ignores <Case>' -ForEach @(
        @{ Case = 'an earlier run''s record'; StartedOffset = -600; BuildId = '1.0.0+5ea1f00d'; ExitCode = 0; Problem = '*an earlier run''s*' }
        @{ Case = 'another build''s record'; StartedOffset = 4; BuildId = '1.0.0+0badc0de'; ExitCode = 0; Problem = '*installer build 1.0.0+0badc0de''s*' }
        @{ Case = 'a record with no exit code'; StartedOffset = 4; BuildId = '1.0.0+5ea1f00d'; ExitCode = $null; Problem = '*stopped before it reported*' }
    ) {
        Save-TestSystemRecord -StartedUtc $script:taskStarted.AddSeconds($StartedOffset) -BuildId $BuildId -ExitCode $ExitCode

        $read = Read-SystemHandoffRunRecord -StartedUtc $script:taskStarted -BuildId '1.0.0+5ea1f00d' -Path $script:recordPath

        $read.Record | Should -BeNullOrEmpty
        $read.Problem | Should -BeLike $Problem
    }

    It 'Ignores a record a standard user could have written' {
        Save-TestSystemRecord -StartedUtc $script:taskStarted.AddSeconds(4)
        Mock Get-Acl { New-TestFileAcl -OwnerSid 'S-1-5-21-1-2-3-1001' }

        $read = Read-SystemHandoffRunRecord -StartedUtc $script:taskStarted -BuildId '1.0.0+5ea1f00d' -Path $script:recordPath

        $read.Record | Should -BeNullOrEmpty
        $read.Problem | Should -BeLike '*that SYSTEM or an administrator wrote*'
    }

    It 'Says so when there is no record' {
        (Read-SystemHandoffRunRecord -StartedUtc $script:taskStarted -Path $script:recordPath).Problem | Should -BeLike 'there is no last-run.json at*'
    }
}

Describe 'Invoke-SystemHandoff' {
    BeforeEach {
        $script:messages = @()
        Mock Write-Info { $script:messages += "INFO: $Message" }
        Mock Write-WarningMessage { $script:messages += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:messages += "ERROR: $Message" }
        Mock Start-Sleep { }

        $script:installer = Join-Path $TestDrive 'winget-app-install.ps1'
        Set-Content -LiteralPath $script:installer -Value "Write-Host 'installer build 1'" -Encoding utf8
        $script:installerSha256 = (Get-FileHash -LiteralPath $script:installer -Algorithm SHA256).Hash
        $script:pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        Mock Find-MachinePowerShell7 { $script:pwsh }
        $script:staging = Join-Path $TestDrive ('system-handoff-' + [guid]::NewGuid().ToString('N'))
        Mock New-WauStagingDirectory { [void](New-Item -ItemType Directory -Path $script:staging -Force); $script:staging }

        $script:events = [System.Collections.Generic.List[string]]::new()
        $script:registeredXml = $null
        $script:copyAtRegistration = $null
        Mock Register-ScheduledTask {
            $script:events.Add('register')
            $script:registeredXml = $Xml
            $script:registeredName = $TaskName
            $script:copyAtRegistration = Get-Content -Raw -LiteralPath (Join-Path $script:staging 'winget-app-install.ps1')
        }
        Mock Start-ScheduledTask { $script:events.Add('start') }
        Mock Stop-ScheduledTask { $script:events.Add('stop') }
        Mock Unregister-ScheduledTask { $script:events.Add('unregister') }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = 0; LastRunTime = Get-Date } }
        Mock Read-SystemHandoffRunRecord { [pscustomobject]@{ Record = [pscustomobject]@{ DeferredApps = [string[]]@(); Record = $null }; Problem = $null } }

        # The run holds the run lock; the SYSTEM run must be able to take it.
        $script:InstallerRunLock = 'held'
        $script:InstallerRunRecordEnabled = $true
        Mock Unlock-InstallerRun { $script:events.Add('unlock'); $script:InstallerRunLock = $null }
        Mock Lock-InstallerRun { $script:events.Add('lock'); 'Acquired' }
        $script:context = New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-jmaffiola' -SessionUser 'CONTOSO\stduser'
    }

    AfterEach {
        $script:InstallerRunLock = $null
        $script:InstallerRunRecordEnabled = $false
    }

    It 'Runs a checked copy of this installer as SYSTEM, waits for it, and cleans up' {
        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context

        $result.Started | Should -BeTrue
        $result.TaskExitCode | Should -Be 0
        $result.WaitSeconds | Should -Be 10800
        @($result.DeferredApps).Count | Should -Be 0

        $xml = [xml]$script:registeredXml
        $xml.Task.Principals.Principal.UserId | Should -Be 'S-1-5-18'
        $xml.Task.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
        $xml.Task.Actions.Exec.Command | Should -Be $script:pwsh
        $xml.Task.Actions.Exec.Arguments | Should -Be ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -NonInteractive' -f (Join-Path $script:staging 'winget-app-install.ps1'))
        $script:registeredName | Should -Match '^winget-app-setup-system-[0-9a-f]{32}$'
        $script:copyAtRegistration | Should -Be (Get-Content -Raw -LiteralPath $script:installer)
        # The lock is free while the SYSTEM run works, and taken back afterwards.
        @($script:events) | Should -Be @('unlock', 'register', 'start', 'unregister', 'lock')
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq $script:registeredName }
        Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
        Test-Path -LiteralPath $script:staging | Should -BeFalse
        $script:InstallerRunRecordEnabled | Should -BeTrue

        $text = $script:messages -join "`n"
        $text | Should -Match "WARN: Switching to SYSTEM: winget cannot open its source for 'CONTOSO\\admin-jmaffiola', elevated in CONTOSO\\stduser's session \(cross-user elevation\)"
        $text | Should -Match 'INFO: The SYSTEM run has started \(scheduled task winget-app-setup-system-[0-9a-f]{32}, C:\\Program Files\\PowerShell\\7\\pwsh\.exe\)\. Its transcript is the newest install-\*\.log in '
    }

    It 'Passes the time budget''s deadline and -SkipSystemCheck on, and waits no longer than the budget allows' {
        $budget = [pscustomobject]@{ Minutes = 60; DeadlineUtc = [DateTime]::UtcNow.AddMinutes(30); MinutesGiven = $true }

        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -Budget $budget -SkipSystemCheck -AccountContext $script:context

        $arguments = ([xml]$script:registeredXml).Task.Actions.Exec.Arguments
        $arguments | Should -Match ' -NonInteractive -SkipSystemCheck -MaxRuntimeMinutes 60 -RunDeadlineUtc \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $arguments | Should -Match ([regex]::Escape((Format-RunRecordTime -Time $budget.DeadlineUtc)))
        $result.WaitSeconds | Should -BeLessOrEqual (1800 + 2700)
    }

    It 'Returns the apps the SYSTEM run deferred, from its record' {
        Mock Read-SystemHandoffRunRecord { [pscustomobject]@{ Record = [pscustomobject]@{ DeferredApps = [string[]]@('Microsoft.WindowsTerminal'); Record = $null }; Problem = $null } }

        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context

        $result.DeferredApps | Should -Be @('Microsoft.WindowsTerminal')
        Should -Invoke Read-SystemHandoffRunRecord -Times 1 -Exactly
    }

    It 'Starts nothing, with exit code 2 and why, <Case>' -ForEach @(
        @{ Case = 'without PowerShell 7 for the whole PC'; NoPwsh = $true; Path = 'installer'; Message = 'ERROR: The install was not handed over to SYSTEM: PowerShell 7 is not installed for the whole PC*' }
        @{ Case = 'without an installer file (irm | iex, the module)'; NoPwsh = $false; Path = ''; Message = 'ERROR: The install was not handed over to SYSTEM: this run has no installer file to hand over*' }
    ) {
        if ($NoPwsh) {
            Mock Find-MachinePowerShell7 { $null }
        }
        $scriptPath = ''
        if ($Path) {
            $scriptPath = $script:installer
        }

        $result = Invoke-SystemHandoff -ScriptPath $scriptPath -ExpectedSha256 $script:installerSha256 -AccountContext $script:context

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 2
        @($script:messages | Where-Object { $_ -like $Message }).Count | Should -Be 1
        Should -Invoke New-WauStagingDirectory -Times 0 -Exactly
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke Unlock-InstallerRun -Times 0 -Exactly
    }

    It 'Starts nothing, with exit code 2, when the installer changed after the run started' {
        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 ('AB' * 32) -AccountContext $script:context

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 2
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        ($script:messages -join "`n") | Should -Match 'could not be copied for the SYSTEM run \(.*changed after this run started\)'
    }

    It 'Registers no task, with exit code 2, when the staged copy does not have its SHA256' {
        Mock Test-SystemHandoffCopy { $false }

        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 2
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
        Should -Invoke Unlock-InstallerRun -Times 0 -Exactly
        Test-Path -LiteralPath $script:staging | Should -BeFalse
        ($script:messages -join "`n") | Should -Match 'does not have the SHA256 .* it was written with, so it is not run as SYSTEM'
    }

    It 'Returns exit code 2 and cleans up when the task cannot be <Case>' -ForEach @(
        @{ Case = 'registered'; Fails = 'Register'; Unregistered = 0 }
        @{ Case = 'started'; Fails = 'Start'; Unregistered = 1 }
    ) {
        if ($Fails -eq 'Register') {
            Mock Register-ScheduledTask { throw 'Access is denied.' }
        }
        else {
            Mock Start-ScheduledTask { throw 'The task is disabled.' }
        }

        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 2
        Should -Invoke Unregister-ScheduledTask -Times $Unregistered -Exactly
        Should -Invoke Lock-InstallerRun -Times 1 -Exactly
        Test-Path -LiteralPath $script:staging | Should -BeFalse
        ($script:messages -join "`n") | Should -Match 'the scheduled task winget-app-setup-system-[0-9a-f]{32} could not be registered or started'
    }

    It 'Stops the task when it does not end in time, and still cleans up' {
        Mock Wait-SystemHandoffTask { $null }

        $result = Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context

        $result.Started | Should -BeTrue
        $result.TaskExitCode | Should -BeNullOrEmpty
        @($script:events) | Should -Be @('unlock', 'register', 'start', 'stop', 'unregister', 'lock')
        Test-Path -LiteralPath $script:staging | Should -BeFalse
    }

    It 'Always unregisters the task, removes the copy and takes the lock back, even after an unexpected error' {
        Mock Wait-SystemHandoffTask { throw 'unexpected' }

        { Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context } | Should -Throw 'unexpected'

        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        Should -Invoke Lock-InstallerRun -Times 1 -Exactly
        Test-Path -LiteralPath $script:staging | Should -BeFalse
    }

    It 'Leaves last-run.json to another run that took the lock meanwhile' {
        Mock Lock-InstallerRun { 'Busy' }

        [void](Invoke-SystemHandoff -ScriptPath $script:installer -ExpectedSha256 $script:installerSha256 -AccountContext $script:context)

        $script:InstallerRunRecordEnabled | Should -BeFalse
        $script:messages | Should -Contain 'WARN: Another run of the installer started after the SYSTEM run; this run leaves last-run.json to it.'
    }
}

Describe 'Get-SystemHandoffExitCode' {
    It 'Is 1 when the SYSTEM run deferred any app, whatever its own code (<Code>)' -ForEach @(
        @{ Code = 0 }, @{ Code = 3010 }, @{ Code = 8 }
    ) {
        Get-SystemHandoffExitCode -TaskExitCode $Code -DeferredApps @('Microsoft.WindowsTerminal') | Should -Be 1
    }

    It 'Is the SYSTEM run''s code otherwise (<Code>)' -ForEach @(
        @{ Code = 0 }, @{ Code = 1 }, @{ Code = 2 }, @{ Code = 6 }, @{ Code = 9 }, @{ Code = 3010 }
    ) {
        Get-SystemHandoffExitCode -TaskExitCode $Code -DeferredApps @() | Should -Be $Code
    }

    It 'Is 5 when the SYSTEM run did not end in time' {
        Get-SystemHandoffExitCode -TaskExitCode $null -DeferredApps @('Microsoft.WindowsTerminal') | Should -Be 5
    }
}

Describe 'Write-SystemHandoffResult and New-SystemHandoffRunRecord' {
    BeforeEach {
        $script:messages = @()
        Mock Write-Info { $script:messages += "INFO: $Message" }
        Mock Write-WarningMessage { $script:messages += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:messages += "ERROR: $Message" }
        $script:context = New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-jmaffiola' -SessionUser 'CONTOSO\stduser'

        # The SYSTEM run's record as last-run.json holds it, read back from JSON.
        $script:InstallLogPath = 'C:\ProgramData\winget-app-setup\logs\install-20261012-101500.log'
        $systemRecord = New-InstallerRunRecord -ExitCode 3010 -Apps @(
            (New-AppRunRecord -Id '7zip.7zip' -Status 'Installed' -RestartRequired $true),
            (New-AppRunRecord -Id 'Microsoft.WindowsTerminal' -Status 'Deferred' -Reason 'per-user app (catalog scope ''user'')')
        ) -AutoUpdates 'Configured' -AutoUpdatesVersion '2.12.0' -RestartRequired $true -WingetUsable $true -SummaryReached
        $script:InstallLogPath = $null
        $script:systemRecordRead = ConvertTo-Json -InputObject $systemRecord -Depth 6 | ConvertFrom-Json
        $script:handoff = [pscustomobject]@{
            Started = $true; ExitCode = $null; TaskExitCode = 3010; WaitSeconds = 10800
            RunRecord = [pscustomobject]@{ DeferredApps = [string[]]@('Microsoft.WindowsTerminal'); Record = $script:systemRecordRead }
            RecordProblem = $null; DeferredApps = [string[]]@('Microsoft.WindowsTerminal')
        }
    }

    It 'Says how the SYSTEM run ended and where its transcript is, lists what it deferred, and returns 1' {
        Write-SystemHandoffResult -Handoff $script:handoff -AccountContext $script:context | Should -Be 1

        $script:messages | Should -Contain 'INFO: The SYSTEM run ended with exit code 3010.'
        $script:messages | Should -Contain 'INFO: Transcript of the SYSTEM run (its summary, and why any app failed): C:\ProgramData\winget-app-setup\logs\install-20261012-101500.log'
        $script:messages | Should -Contain 'ERROR: Deferred by the SYSTEM run, so not installed for CONTOSO\stduser: Microsoft.WindowsTerminal.'
    }

    It 'Returns the SYSTEM run''s code when it deferred nothing' {
        $script:handoff.DeferredApps = [string[]]@()

        Write-SystemHandoffResult -Handoff $script:handoff -AccountContext $script:context | Should -Be 3010

        ($script:messages -join "`n") | Should -Not -Match 'Deferred by the SYSTEM run'
    }

    It 'Warns when the SYSTEM run''s record could not be read' {
        $script:handoff.RunRecord = $null
        $script:handoff.DeferredApps = [string[]]@()
        $script:handoff.RecordProblem = 'there is no last-run.json at C:\ProgramData\winget-app-setup\logs\last-run.json that SYSTEM or an administrator wrote'

        Write-SystemHandoffResult -Handoff $script:handoff -AccountContext $script:context | Should -Be 3010

        $script:messages | Should -Contain "WARN: The SYSTEM run's result could not be read: there is no last-run.json at C:\ProgramData\winget-app-setup\logs\last-run.json that SYSTEM or an administrator wrote. Which apps it deferred is not known; see its transcript."
    }

    It 'Says the SYSTEM run was stopped, and returns 5, when it did not end in time' {
        $script:handoff.TaskExitCode = $null

        Write-SystemHandoffResult -Handoff $script:handoff -AccountContext $script:context | Should -Be 5

        ($script:messages -join "`n") | Should -Match 'ERROR: The SYSTEM run did not end within 180 minutes and was stopped'
    }

    It 'Records the SYSTEM run''s apps and outcome with the hand-over, in the shape last-run.json keeps' {
        $record = New-SystemHandoffRunRecord -Handoff $script:handoff -ExitCode 1
        $json = ConvertTo-Json -InputObject $record -Depth 6 | ConvertFrom-Json

        $json.exitCode | Should -Be 1
        @($json.apps | ForEach-Object { $_.id }) | Should -Be @('7zip.7zip', 'Microsoft.WindowsTerminal')
        $json.counts.installed | Should -Be 1
        $json.counts.deferred | Should -Be 1
        $json.autoUpdates.status | Should -Be 'Configured'
        $json.autoUpdates.version | Should -Be '2.12.0'
        $json.restartRequired | Should -BeTrue
        $json.wingetUsable | Should -BeTrue
        $json.summaryReached | Should -BeTrue
        @($json.handoff.PSObject.Properties.Name) | Should -Be @('to', 'reason', 'exitCode', 'recordRead', 'deferred', 'transcriptPath')
        $json.handoff.to | Should -Be 'SYSTEM'
        $json.handoff.reason | Should -Be 'SourceUnusable'
        $json.handoff.exitCode | Should -Be 3010
        $json.handoff.recordRead | Should -BeTrue
        @($json.handoff.deferred) | Should -Be @('Microsoft.WindowsTerminal')
        $json.handoff.transcriptPath | Should -Be 'C:\ProgramData\winget-app-setup\logs\install-20261012-101500.log'
    }

    It 'Records a hand-over whose SYSTEM run was stopped or left no record: no apps, and recordRead false' {
        $script:handoff.TaskExitCode = $null
        $script:handoff.RunRecord = $null
        $script:handoff.DeferredApps = [string[]]@()

        $json = ConvertTo-Json -InputObject (New-SystemHandoffRunRecord -Handoff $script:handoff -ExitCode 5) -Depth 6 | ConvertFrom-Json

        $json.exitCode | Should -Be 5
        @($json.apps).Count | Should -Be 0
        $json.autoUpdates.status | Should -Be 'NotRun'
        $json.handoff.exitCode | Should -BeNullOrEmpty
        $json.handoff.recordRead | Should -BeFalse
        @($json.handoff.deferred).Count | Should -Be 0
        $json.handoff.transcriptPath | Should -BeNullOrEmpty
    }
}
