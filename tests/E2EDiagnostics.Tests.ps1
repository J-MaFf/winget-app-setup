# E2EDiagnostics.Tests.ps1
# Tests for e2e/Collect-Diagnostics.ps1, which .github/workflows/e2e-install.yml runs around the
# install passes. The workflow depends on two promises: the script records each diagnostic source
# or says why it could not, and it exits 0 whatever is missing, so it can never fail a run.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:DiagnosticsScript = Join-Path $script:RepoRoot 'e2e/Collect-Diagnostics.ps1'

    # Test doubles for the Windows-only commands the script calls, so Mock can target them on any
    # OS. On Windows they shadow the real cmdlets for this file only.
    function Get-AppxPackage { [CmdletBinding()] param ([switch]$AllUsers, [string]$Name) }
    function Get-AppxProvisionedPackage { [CmdletBinding()] param ([switch]$Online) }
    function Get-ScheduledTask { [CmdletBinding()] param ([string]$TaskPath, [string]$TaskName) }
    function Get-ScheduledTaskInfo { [CmdletBinding()] param ([object]$InputObject) }
    function Get-WinEvent { [CmdletBinding()] param ([hashtable[]]$FilterHashtable, [long]$MaxEvents) }

    function New-TestErrorRecord {
        param ([string]$Message, [string]$ErrorId)
        return [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($Message), $ErrorId, [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
    }

    function Invoke-DiagnosticsScript {
        param ([hashtable]$Arguments)
        & $script:DiagnosticsScript @Arguments 6>$null
        return $LASTEXITCODE
    }
}

Describe 'e2e/Collect-Diagnostics.ps1' {
    BeforeEach {
        $script:OutputDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Since = [datetime]'2026-10-04T06:00:00'
        $script:MissingWauLogs = Join-Path $TestDrive 'no-wau\logs'

        Mock Get-AppxPackage { }
        Mock Get-AppxProvisionedPackage { }
        Mock Get-ScheduledTask { }
        Mock Get-ScheduledTaskInfo { }
        Mock Get-WinEvent { }
    }

    It 'Exits 0 and names every source that is missing or failing (pwsh removed, AppX broken, no events, no WAU)' {
        Mock Get-AppxPackage { throw 'Get-AppxPackage: access is denied' }
        Mock Get-AppxProvisionedPackage { throw 'DISM: the operation failed' }
        Mock Get-ScheduledTask { throw (New-TestErrorRecord -Message "No MSFT_ScheduledTask objects found with property 'TaskPath' equal to '\WAU\'." -ErrorId 'CmdletizationQuery_NotFound_TaskPath,Get-ScheduledTask') }
        Mock Get-WinEvent { throw (New-TestErrorRecord -Message 'No events were found that match the specified selection criteria.' -ErrorId 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand') }

        # A run that removed PowerShell 7 leaves no pwsh on PATH.
        $emptyPathDirectory = Join-Path $TestDrive 'empty-path'
        $null = New-Item -ItemType Directory -Path $emptyPathDirectory -Force
        $originalPath = $env:PATH
        try {
            $env:PATH = $emptyPathDirectory
            $exitCode = Invoke-DiagnosticsScript @{ OutputDirectory = $script:OutputDirectory; Label = '3-end-of-job'; IncludeLogs = $true; Since = $script:Since; WauLogDirectory = $script:MissingWauLogs }
        }
        finally {
            $env:PATH = $originalPath
        }

        $exitCode | Should -Be 0
        $snapshot = Get-Content -Raw -Path (Join-Path $script:OutputDirectory '3-end-of-job/snapshot.txt')
        $snapshot | Should -Match 'pwsh: not found on PATH'
        $snapshot | Should -Match 'pwsh: MISSING \(not on PATH\)'
        $snapshot | Should -Match 'AppX \(all users\): ERROR: Get-AppxPackage: access is denied'
        $snapshot | Should -Match 'AppX \(provisioned\): ERROR: DISM: the operation failed'
        $snapshot | Should -Match 'WAU tasks: OK, 0 task\(s\)'
        $snapshot | Should -Match 'MsiInstaller events: none since 2026-10-04T06:00:00'
        $snapshot | Should -Match 'RestartManager events: none since'
        $snapshot | Should -Match 'AppX deployment errors/warnings: none since'
        $snapshot | Should -Match ([regex]::Escape("WAU logs: not present ($($script:MissingWauLogs))"))
    }

    It 'Records an unexpected event-log or task error as ERROR on one line and still collects the rest' {
        Mock Get-ScheduledTask { throw "The task scheduler service is not running.`r`nSecond line of the error." }
        Mock Get-WinEvent { throw 'The specified channel could not be found.' } -ParameterFilter { $FilterHashtable[0].LogName -like '*AppXDeploymentServer*' }
        Mock Get-WinEvent {
            [pscustomobject]@{ TimeCreated = [datetime]'2026-10-04T06:05:00'; LevelDisplayName = 'Information'; ProviderName = 'MsiInstaller'; Id = 1033; Message = 'Windows Installer installed the product.' }
        }

        $exitCode = Invoke-DiagnosticsScript @{ OutputDirectory = $script:OutputDirectory; Label = '3-end-of-job'; IncludeLogs = $true; Since = $script:Since; WauLogDirectory = $script:MissingWauLogs }

        $exitCode | Should -Be 0
        $snapshot = Get-Content -Path (Join-Path $script:OutputDirectory '3-end-of-job/snapshot.txt')
        $snapshot | Should -Contain 'WAU tasks: ERROR: The task scheduler service is not running. Second line of the error.'
        $snapshot | Should -Contain 'AppX deployment errors/warnings: ERROR: The specified channel could not be found.'
        ($snapshot | Where-Object { $_ -like 'MsiInstaller events: 1 since *' }) | Should -Not -BeNullOrEmpty
    }

    It 'Writes the all-users and provisioned AppX state, the WAU task run, the events and the WAU logs when present' {
        Mock Get-AppxPackage {
            [pscustomobject]@{
                Name                   = 'Microsoft.DesktopAppInstaller'
                Version                = '1.26.510.0'
                Architecture           = 'X64'
                Status                 = 'Ok'
                IsFramework            = $false
                PackageFullName        = 'Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
                InstallLocation        = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
                PackageUserInformation = @('S-1-5-21-1-1001 [runneradmin]: Installed', 'S-1-5-18 [SYSTEM]: Staged')
            }
        } -ParameterFilter { $Name -eq 'Microsoft.DesktopAppInstaller' }
        Mock Get-AppxProvisionedPackage {
            [pscustomobject]@{ DisplayName = 'Microsoft.DesktopAppInstaller'; Version = '2026.902.255.0'; PackageName = 'Microsoft.DesktopAppInstaller_2026.902.255.0_neutral_~_8wekyb3d8bbwe' }
            [pscustomobject]@{ DisplayName = 'Microsoft.WindowsCalculator'; Version = '11.2405.2.0'; PackageName = 'Microsoft.WindowsCalculator_11.2405.2.0_neutral_~_8wekyb3d8bbwe' }
        }
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'Winget-AutoUpdate'
                State    = 'Ready'
                Triggers = @([pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskWeeklyTrigger' } })
            }
        }
        Mock Get-ScheduledTaskInfo {
            [pscustomobject]@{ LastRunTime = [datetime]'2026-10-04T06:10:00'; LastTaskResult = 267011; NextRunTime = [datetime]'2026-10-06T02:00:00' }
        }
        Mock Get-WinEvent {
            [pscustomobject]@{ TimeCreated = [datetime]'2026-10-04T06:06:00'; LevelDisplayName = 'Information'; ProviderName = 'MsiInstaller'; Id = 11707; Message = "Product: 7-Zip -- Installation completed successfully.`r`nSecond line." }
            [pscustomobject]@{ TimeCreated = [datetime]'2026-10-04T06:05:00'; LevelDisplayName = 'Information'; ProviderName = 'MsiInstaller'; Id = 1040; Message = 'Beginning a Windows Installer transaction.' }
        } -ParameterFilter { $FilterHashtable[0].ProviderName -eq 'MsiInstaller' }
        Mock Get-WinEvent { throw (New-TestErrorRecord -Message 'No events were found that match the specified selection criteria.' -ErrorId 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand') }

        $wauLogs = Join-Path $TestDrive 'wau\logs'
        $null = New-Item -ItemType Directory -Path $wauLogs -Force
        Set-Content -Path (Join-Path $wauLogs 'updates.log') -Value 'WAU run started'
        Set-Content -Path (Join-Path $wauLogs 'install.log') -Value 'WAU installed'

        $exitCode = Invoke-DiagnosticsScript @{ OutputDirectory = $script:OutputDirectory; Label = '3-end-of-job'; IncludeLogs = $true; Since = $script:Since; WauLogDirectory = $wauLogs }

        $exitCode | Should -Be 0
        $labelDirectory = Join-Path $script:OutputDirectory '3-end-of-job'
        $snapshot = Get-Content -Path (Join-Path $labelDirectory 'snapshot.txt')
        $snapshot | Should -Contain 'Microsoft.DesktopAppInstaller 1.26.510.0 X64 Status=Ok Framework=False'
        $snapshot | Should -Contain '  Users: S-1-5-21-1-1001 [runneradmin]: Installed; S-1-5-18 [SYSTEM]: Staged'
        $snapshot | Should -Contain 'AppX (all users): OK, 1 package(s)'
        $snapshot | Should -Contain 'Microsoft.DesktopAppInstaller 2026.902.255.0 (Microsoft.DesktopAppInstaller_2026.902.255.0_neutral_~_8wekyb3d8bbwe)'
        ($snapshot -join "`n") | Should -Not -Match 'WindowsCalculator'
        $snapshot | Should -Contain 'Winget-AutoUpdate State=Ready Triggers=[WeeklyTrigger] LastRun=2026-10-04T06:10:00 LastResult=0x00041303 NextRun=2026-10-06T02:00:00'
        $snapshot | Should -Contain 'MsiInstaller events: 2 since 2026-10-04T06:00:00 -> events-MsiInstaller.txt'
        ($snapshot | Where-Object { $_ -like 'WAU logs: 2 file(s) from *' }) | Should -Not -BeNullOrEmpty

        # Events come out oldest first, with every message line indented under its header.
        $events = Get-Content -Path (Join-Path $labelDirectory 'events-MsiInstaller.txt')
        $events[0] | Should -Be '2026-10-04T06:05:00.000 [Information] MsiInstaller id=1040'
        $events | Should -Contain '    Second line.'
        Get-Content -Raw -Path (Join-Path $labelDirectory 'wau-logs/updates.log') | Should -Match 'WAU run started'

        Should -Invoke Get-AppxPackage -Times 2 -Exactly -ParameterFilter { $AllUsers }
        Should -Invoke Get-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter { $Online }
        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter { $FilterHashtable[0].StartTime -eq $script:Since -and $FilterHashtable[0].LogName -eq 'Microsoft-Windows-AppXDeploymentServer/Operational' }
    }

    It 'Leaves out the event logs and WAU log files without -IncludeLogs' {
        $exitCode = Invoke-DiagnosticsScript @{ OutputDirectory = $script:OutputDirectory; Label = '1-before-first-pass' }

        $exitCode | Should -Be 0
        $labelDirectory = Join-Path $script:OutputDirectory '1-before-first-pass'
        (@(Get-ChildItem -Path $labelDirectory -Name) -join ', ') | Should -Be 'snapshot.txt'
        $snapshot = Get-Content -Raw -Path (Join-Path $labelDirectory 'snapshot.txt')
        $snapshot | Should -Match 'AppX \(all users\): OK, 0 package\(s\)'
        $snapshot | Should -Not -Match 'WAU logs:'
        Should -Invoke Get-WinEvent -Times 0 -Exactly
    }

    It 'Stays runnable by Windows PowerShell 5.1: ASCII only, parses cleanly, no PowerShell 7-only operators' {
        $bytes = [System.IO.File]::ReadAllBytes($script:DiagnosticsScript)
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0

        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:DiagnosticsScript, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $ps7OnlyKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
        @($tokens | Where-Object { $ps7OnlyKinds -contains $_.Kind.ToString() } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" }) | Should -BeNullOrEmpty
    }
}
