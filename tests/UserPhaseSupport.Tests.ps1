# UserPhaseSupport.Tests.ps1
# Tests for WingetAppSetup/Private/UserPhaseSupport.ps1 (work-order item 34): reading the machine's
# run record and this account's user-phase state, deciding whether the user phase has work, and
# installing one deferred app per-user.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A run record written the way the installer writes it (New-InstallerRunRecord, then
    # Save-InstallerRunRecord), so these tests read exactly what item 25's writer produces.
    function New-TestRunRecordFile {
        param (
            [Parameter(Mandatory = $true)][string]$Directory,
            [object[]]$Apps = @(),
            [AllowNull()]$ExitCode = 0
        )
        $null = New-Item -ItemType Directory -Path $Directory -Force
        $script:InstallerRunStartedUtc = [DateTime]::new(2026, 10, 4, 14, 30, 0, [DateTimeKind]::Utc)
        $script:InstallerBuildId = '1.0.0+5ea1f00d'
        $record = New-InstallerRunRecord -ExitCode 0 -Apps $Apps -SummaryReached
        $record.exitCode = $ExitCode
        $path = Save-InstallerRunRecord -Record $record -Directory $Directory
        $script:InstallerRunStartedUtc = $null
        $script:InstallerBuildId = $null
        return $path
    }
}

Describe 'Read-InstallerRunRecord' {
    BeforeEach {
        Mock Write-WarningMessage { }
        $script:recordDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'Returns nothing, without a warning, when there is no record' {
        Read-InstallerRunRecord -Path (Join-Path $script:recordDirectory 'last-run.json') | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 0 -Exactly
    }

    It 'Reads the deferred apps, in record order and once each, from what the installer writes' {
        $apps = @(
            (New-AppRunRecord -Id '7zip.7zip' -Status 'Installed'),
            (New-AppRunRecord -Id 'Microsoft.WindowsTerminal' -Status 'Deferred' -Reason 'winget found no machine-wide installer for it'),
            (New-AppRunRecord -Id 'Git.Git' -Status 'Failed' -Reason 'install failed'),
            (New-AppRunRecord -Id 'Contoso.UserOnly' -Status 'Deferred'),
            (New-AppRunRecord -Id 'Microsoft.WindowsTerminal' -Status 'Deferred')
        )
        $path = New-TestRunRecordFile -Directory $script:recordDirectory -Apps $apps -ExitCode 8

        $record = Read-InstallerRunRecord -Path $path

        $record.DeferredApps | Should -Be @('Microsoft.WindowsTerminal', 'Contoso.UserOnly')
        $record.InvalidDeferredIds | Should -BeNullOrEmpty
        $record.ExitCode | Should -Be 8
        $record.BuildId | Should -Be '1.0.0+5ea1f00d'
        $record.StartedUtc | Should -Be '2026-10-04T14:30:00Z'
        $record.Sha256 | Should -Be (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    It 'Leaves out a deferred id that is not a winget package id, and lists it' {
        $apps = @((New-AppRunRecord -Id 'Google.Chrome --override /S' -Status 'Deferred'), (New-AppRunRecord -Id 'Contoso.UserOnly' -Status 'Deferred'))
        $path = New-TestRunRecordFile -Directory $script:recordDirectory -Apps $apps

        $record = Read-InstallerRunRecord -Path $path

        $record.DeferredApps | Should -Be @('Contoso.UserOnly')
        $record.InvalidDeferredIds | Should -Be @('Google.Chrome --override /S')
    }

    It 'Reads the record of a run that has not reported yet with no exit code' {
        $path = New-TestRunRecordFile -Directory $script:recordDirectory -ExitCode $null

        (Read-InstallerRunRecord -Path $path).ExitCode | Should -BeNullOrEmpty
    }

    It 'Warns and returns nothing for <Case>' -ForEach @(
        @{ Case = 'a file that is not JSON'; Content = '{ not json' }
        @{ Case = 'JSON that is not a run record'; Content = '{"exitCode":0}' }
    ) {
        $null = New-Item -ItemType Directory -Path $script:recordDirectory -Force
        $path = Join-Path $script:recordDirectory 'last-run.json'
        Set-Content -LiteralPath $path -Value $Content

        Read-InstallerRunRecord -Path $path | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 1 -Exactly
    }
}

Describe 'Read-UserPhaseState and Save-UserPhaseState' {
    BeforeEach {
        Mock Write-WarningMessage { }
        $script:statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'winget-app-setup/user-phase.json'
    }

    It 'Returns nothing when there is no state' {
        Read-UserPhaseState -Path $script:statePath | Should -BeNullOrEmpty
    }

    It 'Writes the state, creating its folder, and reads it back' {
        $state = [ordered]@{ schemaVersion = 1; recordSha256 = ('AB' * 32); attempts = 2; complete = $true; apps = @() }

        Save-UserPhaseState -Path $script:statePath -State $state | Should -Be $script:statePath

        $read = Read-UserPhaseState -Path $script:statePath
        $read.RecordSha256 | Should -Be ('AB' * 32)
        $read.Attempts | Should -Be 2
        $read.Complete | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:statePath) -Filter '*.tmp').Count | Should -Be 0
    }

    It 'Warns and returns nothing for a state it cannot read' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:statePath) -Force
        Set-Content -LiteralPath $script:statePath -Value 'not json'

        Read-UserPhaseState -Path $script:statePath | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 1 -Exactly
    }

    It 'Warns and returns nothing when the state cannot be written' {
        $blocker = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $blocker -Value 'a file where the folder should be'

        Save-UserPhaseState -Path (Join-Path $blocker 'user-phase.json') -State ([ordered]@{ attempts = 1 }) | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match '^Could not write the user-phase state' }
    }
}

Describe 'Get-UserPhaseDecision' {
    BeforeAll {
        $script:record = [pscustomobject]@{ Sha256 = ('A1' * 32); ExitCode = 0 }
    }

    It '<Case> -> Run <Run>, <Reason>, attempt <Attempt>' -ForEach @(
        @{ Case = 'no record'; Record = 'none'; State = $null; Run = $false; Reason = 'NoRecord'; Attempt = 0 }
        @{ Case = 'a run that has not reported'; Record = 'running'; State = $null; Run = $false; Reason = 'RunNotFinished'; Attempt = 0 }
        @{ Case = 'no state yet'; Record = 'done'; State = $null; Run = $true; Reason = 'New'; Attempt = 1 }
        @{ Case = 'a state for an older run'; Record = 'done'; State = @{ RecordSha256 = ('B2' * 32); Complete = $true; Attempts = 3 }; Run = $true; Reason = 'New'; Attempt = 1 }
        @{ Case = 'this run, complete'; Record = 'done'; State = @{ RecordSha256 = ('a1' * 32); Complete = $true; Attempts = 1 }; Run = $false; Reason = 'Done'; Attempt = 0 }
        @{ Case = 'this run, one attempt left'; Record = 'done'; State = @{ RecordSha256 = ('A1' * 32); Complete = $false; Attempts = 2 }; Run = $true; Reason = 'Pending'; Attempt = 3 }
        @{ Case = 'this run, attempts used up'; Record = 'done'; State = @{ RecordSha256 = ('A1' * 32); Complete = $false; Attempts = 3 }; Run = $false; Reason = 'GaveUp'; Attempt = 0 }
    ) {
        $recordValue = switch ($Record) {
            'none' { $null }
            'running' { [pscustomobject]@{ Sha256 = ('A1' * 32); ExitCode = $null } }
            default { $script:record }
        }
        $stateValue = $null
        if ($State) {
            $stateValue = [pscustomobject]$State
        }

        $decision = Get-UserPhaseDecision -Record $recordValue -State $stateValue -MaxAttempts 3

        $decision.Run | Should -Be $Run
        $decision.Reason | Should -Be $Reason
        $decision.Attempt | Should -Be $Attempt
    }
}

Describe 'Install-UserPhaseApp' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Write-InstalledAppNote { [bool]$InstallResult.RestartRequired }
        $script:checks = @()
        Mock Test-WingetPackageInstalled {
            $answer = $script:checks[0]
            $script:checks = @($script:checks | Select-Object -Skip 1)
            $answer
        }
        $script:installResult = @{ ExitCode = 0; Attempts = 1; MachineScopeFellBack = $false; NoUserScopeInstaller = $false; LaunchErrorExhausted = $false; LaunchError = $null; TimedOut = $false; RestartRequired = $false }
        Mock Install-WingetPackage { $script:installResult }
        $script:notInstalled = @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = -1978335212 }
        $script:installed = @{ Installed = $true; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 }
    }

    It 'Skips an app that is already there, without installing it' {
        $script:checks = @($script:installed)

        $result = Install-UserPhaseApp -PackageId 'Contoso.UserOnly' -TimeoutSeconds 600

        $result.status | Should -Be 'Skipped'
        $result.reason | Should -Be 'already installed'
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
    }

    It 'Installs per-user only, silently, within the time it is given, and checks it again' {
        $script:checks = @($script:notInstalled, $script:installed)

        $result = Install-UserPhaseApp -PackageId 'Contoso.UserOnly' -TimeoutSeconds 600

        $result.status | Should -Be 'Installed'
        $result.code | Should -Be 0
        $result.restartRequired | Should -BeFalse
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter {
            $PackageId -eq 'Contoso.UserOnly' -and $UserScopeOnly -and -not $MachineScopeOnly -and $Silent -and $TimeoutSeconds -eq 600 -and $InstallInProgressWaitSeconds -eq 120
        }
        Should -Invoke Test-WingetPackageInstalled -Times 2 -Exactly
    }

    It 'Reports a restart the install needs' {
        $script:checks = @($script:notInstalled, $script:installed)
        $script:installResult.RestartRequired = $true

        (Install-UserPhaseApp -PackageId 'Contoso.UserOnly' -TimeoutSeconds 600).restartRequired | Should -BeTrue
    }

    It 'Fails an app with no per-user installer, without trying another scope, and says why' {
        $script:checks = @($script:notInstalled)
        $script:installResult.ExitCode = -1978335216
        $script:installResult.NoUserScopeInstaller = $true

        $result = Install-UserPhaseApp -PackageId 'Contoso.MachineOnly' -TimeoutSeconds 600

        $result.status | Should -Be 'Failed'
        $result.reason | Should -Match '^winget found no per-user installer for it that applies to this PC'
        $result.reason | Should -Not -Match 'machine-scope fallback'
        $result.codeHex | Should -Be '0x8A150010'
        Should -Invoke Install-WingetPackage -Times 1 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
    }

    It 'Fails an app whose check could not answer, without installing it blind (<Case>)' -ForEach @(
        @{ Case = 'timed out'; Check = @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }; Reason = '^winget list timed out during the pre-install check' }
        @{ Case = 'winget could not start'; Check = @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = 'The file cannot be accessed by the system.'; CheckFailed = $false; ExitCode = $null }; Reason = '^winget could not be launched for the pre-install check' }
    ) {
        $script:checks = @($Check)

        $result = Install-UserPhaseApp -PackageId 'Contoso.UserOnly' -TimeoutSeconds 600

        $result.status | Should -Be 'Failed'
        $result.reason | Should -Match $Reason
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
    }

    It 'Fails an app winget could not be started for, and one that is not there after the install' {
        $script:checks = @($script:notInstalled)
        $script:installResult.ExitCode = $null
        $script:installResult.LaunchErrorExhausted = $true
        $script:installResult.LaunchError = 'Access is denied.'

        $launch = Install-UserPhaseApp -PackageId 'Contoso.UserOnly' -TimeoutSeconds 600
        $launch.status | Should -Be 'Failed'
        $launch.reason | Should -Match '^winget could not be launched to install it.*Access is denied'

        $script:checks = @($script:notInstalled, $script:notInstalled)
        $script:installResult.ExitCode = 1603
        $script:installResult.LaunchErrorExhausted = $false
        $missing = Install-UserPhaseApp -PackageId 'Contoso.UserOnly' -TimeoutSeconds 600
        $missing.status | Should -Be 'Failed'
        $missing.code | Should -Be 1603
    }
}
