# UserPhase.Tests.ps1
# Tests for WingetAppSetup/Public/UserPhase.ps1 (work-order item 34): Invoke-WingetUserPhase, the
# user phase of an Endpoint Central deployment. It runs at every sign-in, so it must end at once
# and silently when there is nothing to do; otherwise it installs, per-user, the apps the run for
# the whole PC deferred, sets the Windows Terminal defaults, and records what it did, once per
# machine run and within a bounded number of attempts.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A run record written the way the installer writes it (New-InstallerRunRecord, then
    # Save-InstallerRunRecord), so the user phase is tested against item 25's real writer.
    function New-TestRunRecordFile {
        param (
            [Parameter(Mandatory = $true)][string]$Directory,
            [string[]]$Deferred = @(),
            [AllowNull()]$ExitCode = 0,
            [int]$Minute = 30
        )
        $null = New-Item -ItemType Directory -Path $Directory -Force
        $apps = @(New-AppRunRecord -Id '7zip.7zip' -Status 'Installed')
        foreach ($id in $Deferred) {
            $apps += New-AppRunRecord -Id $id -Status 'Deferred' -Reason 'winget found no machine-wide installer for it'
        }
        $script:InstallerRunStartedUtc = [DateTime]::new(2026, 10, 4, 14, $Minute, 0, [DateTimeKind]::Utc)
        $script:InstallerBuildId = '1.0.0+5ea1f00d'
        $record = New-InstallerRunRecord -ExitCode 0 -Apps $apps -SummaryReached
        $record.exitCode = $ExitCode
        $path = Save-InstallerRunRecord -Record $record -Directory $Directory
        $script:InstallerRunStartedUtc = $null
        $script:InstallerBuildId = $null
        return $path
    }

    function Get-TestState {
        Get-Content -Raw -LiteralPath $script:statePath | ConvertFrom-Json
    }

    function Invoke-TestUserPhase {
        param ([int]$MaxMinutes = 15, [int]$MaxAttempts = 3)
        Invoke-WingetUserPhase -RunRecordPath $script:recordPath -StatePath $script:statePath -MaxMinutes $MaxMinutes -MaxAttempts $MaxAttempts
    }
}

Describe 'Invoke-WingetUserPhase (work-order item 34)' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:recordPath = Join-Path $script:root 'ProgramData/winget-app-setup/logs/last-run.json'
        $script:statePath = Join-Path $script:root 'LocalAppData/winget-app-setup/user-phase.json'
        $script:InstallLogPath = $null

        $script:output = @()
        Mock Write-Host { $script:output += "$Object" }
        Mock Write-Info { $script:output += "INFO: $Message" }
        Mock Write-Success { $script:output += "OK: $Message" }
        Mock Write-WarningMessage { $script:output += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:output += "ERROR: $Message" }
        Mock Test-IsSystemAccount { $false }
        Mock Get-ProcessUserName { 'CONTOSO\jdoe' }
        Mock Start-InstallerTranscript { $null }
        Mock Remove-OldInstallerLog { 0 }
        Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; ExitCode = 0; Attempts = 1 } }
        Mock Install-UserPhaseApp { New-AppRunRecord -Id $PackageId -Status 'Installed' -InstallResult @{ ExitCode = 0 } }
        Mock Get-WindowsTerminalSettingsPaths { @('C:\Users\jdoe\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') }
        Mock Set-WindowsTerminalDefaults { }
    }

    It 'Ends at once, printing nothing, when <Case>' -ForEach @(
        @{ Case = 'there is no run record'; Record = 'none' }
        @{ Case = 'the run has not reported yet'; Record = 'running' }
    ) {
        if ($Record -eq 'running') {
            $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly') -ExitCode $null
        }

        Invoke-TestUserPhase | Should -Be 0

        $script:output | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
        Should -Invoke Start-InstallerTranscript -Times 0 -Exactly
        Should -Invoke Install-UserPhaseApp -Times 0 -Exactly
        Should -Invoke Set-WindowsTerminalDefaults -Times 0 -Exactly
    }

    It 'Installs every deferred app per-user and sets the Terminal defaults, logged to the user''s own folder, and records the run as done' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Microsoft.WindowsTerminal', 'Contoso.UserOnly') -ExitCode 8

        Invoke-TestUserPhase | Should -Be 0

        Should -Invoke Start-InstallerTranscript -Times 1 -Exactly -ParameterFilter { $UserPhase }
        Should -Invoke Install-UserPhaseApp -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Microsoft.WindowsTerminal' }
        Should -Invoke Install-UserPhaseApp -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.UserOnly' }
        Should -Invoke Set-WindowsTerminalDefaults -Times 1 -Exactly
        $state = Get-TestState
        $state.complete | Should -BeTrue
        $state.attempts | Should -Be 1
        $state.exitCode | Should -Be 0
        $state.recordSha256 | Should -Be (Get-FileHash -LiteralPath $script:recordPath -Algorithm SHA256).Hash
        @($state.apps | ForEach-Object { '{0}={1}' -f $_.id, $_.status }) | Should -Be @('Microsoft.WindowsTerminal=Installed', 'Contoso.UserOnly=Installed')
        $state.terminalDefaults | Should -Be 'Applied'
        $script:output | Should -Contain 'USER PHASE RESULT: exit=0 installed=2 skipped=0 failed=0 terminal=Applied attempt=1/3 complete=true log=none'
    }

    It 'Does nothing more for this account once it has finished this run, and runs again for the next run' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Invoke-TestUserPhase | Should -Be 0
        $script:output = @()

        Invoke-TestUserPhase | Should -Be 0
        $script:output | Should -BeNullOrEmpty
        Should -Invoke Install-UserPhaseApp -Times 1 -Exactly

        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly') -Minute 45
        Invoke-TestUserPhase | Should -Be 0
        Should -Invoke Install-UserPhaseApp -Times 2 -Exactly
        (Get-TestState).attempts | Should -Be 1
    }

    It 'Tries again at the next sign-ins after a failed app, and gives up after MaxAttempts' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Mock Install-UserPhaseApp { New-AppRunRecord -Id $PackageId -Status 'Failed' -Reason 'install failed' }

        Invoke-TestUserPhase -MaxAttempts 2 | Should -Be 1
        (Get-TestState).complete | Should -BeFalse
        Invoke-TestUserPhase -MaxAttempts 2 | Should -Be 1
        (Get-TestState).attempts | Should -Be 2
        $script:output | Should -Contain 'WARN: This was the last of 2 attempts for this run for the whole PC; the user phase does not try again until the next one.'
        $script:output = @()

        Invoke-TestUserPhase -MaxAttempts 2 | Should -Be 0
        $script:output | Should -BeNullOrEmpty
        Should -Invoke Install-UserPhaseApp -Times 2 -Exactly
    }

    It 'Records the attempt before it installs anything, so an attempt that is killed still counts' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Mock Install-UserPhaseApp {
            $script:stateDuringInstall = Get-TestState
            New-AppRunRecord -Id $PackageId -Status 'Installed'
        }

        Invoke-TestUserPhase | Should -Be 0

        $script:stateDuringInstall.attempts | Should -Be 1
        $script:stateDuringInstall.complete | Should -BeFalse
        $script:stateDuringInstall.exitCode | Should -BeNullOrEmpty
    }

    It 'Installs nothing and exits 2 when winget cannot be started for this account, and tries again later' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = "winget could not be started: 'winget' was not found on PATH"; ExitCode = $null; Attempts = 4 } }

        Invoke-TestUserPhase | Should -Be 2

        Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 4 -and $RetryDelaySeconds -eq 15 }
        Should -Invoke Install-UserPhaseApp -Times 0 -Exactly
        $state = Get-TestState
        $state.complete | Should -BeFalse
        $state.apps[0].status | Should -Be 'NotAttempted'
        $state.exitCode | Should -Be 2
    }

    It 'Sets only the Terminal defaults, without a winget check, when nothing was deferred' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath)

        Invoke-TestUserPhase | Should -Be 0

        Should -Invoke Test-WingetLaunchable -Times 0 -Exactly
        Should -Invoke Set-WindowsTerminalDefaults -Times 1 -Exactly
        (Get-TestState).complete | Should -BeTrue
    }

    It 'Leaves the Terminal step for a later sign-in while Terminal has no settings.json for this account' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath)
        Mock Get-WindowsTerminalSettingsPaths { @() }

        Invoke-TestUserPhase | Should -Be 0

        $state = Get-TestState
        $state.complete | Should -BeFalse
        $state.terminalDefaults | Should -Be 'SettingsNotFound'
        Invoke-TestUserPhase | Should -Be 0
        Should -Invoke Set-WindowsTerminalDefaults -Times 2 -Exactly
    }

    It 'Starts no install once its time budget is spent, and exits 1' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.Slow', 'Contoso.Next')
        Mock Install-UserPhaseApp {
            Start-Sleep -Milliseconds 1600
            New-AppRunRecord -Id $PackageId -Status 'Installed'
        }

        Invoke-TestUserPhase -MaxMinutes 1 | Should -Be 1

        Should -Invoke Install-UserPhaseApp -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.Slow' -and $TimeoutSeconds -le 60 }
        $state = Get-TestState
        ($state.apps | Where-Object id -EQ 'Contoso.Next').status | Should -Be 'NotAttempted'
        $state.complete | Should -BeFalse
    }

    It 'Exits 3010 when an install needs a restart to finish' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Mock Install-UserPhaseApp { New-AppRunRecord -Id $PackageId -Status 'Installed' -RestartRequired $true }

        Invoke-TestUserPhase | Should -Be 3010
        (Get-TestState).complete | Should -BeTrue
    }

    It 'Exits 5 on an unexpected error, records it, and still counts the attempt' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Mock Test-WingetLaunchable { throw 'boom' }

        Invoke-TestUserPhase | Should -Be 5

        $state = Get-TestState
        $state.exitCode | Should -Be 5
        $state.attempts | Should -Be 1
        $state.complete | Should -BeFalse
        $script:output | Should -Contain 'ERROR: UNEXPECTED ERROR - the user phase stopped before it finished: boom'
    }

    It 'Does nothing as SYSTEM, and says so' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        Mock Test-IsSystemAccount { $true }

        Invoke-TestUserPhase | Should -Be 0

        $script:output | Should -Match 'nothing to do as SYSTEM'
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
        Should -Invoke Install-UserPhaseApp -Times 0 -Exactly
    }

    It 'Keeps the newest 10 of its own logs, and puts winget''s logs next to its transcript' {
        $script:recordPath = New-TestRunRecordFile -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.UserOnly')
        $transcript = Join-Path $script:root 'LocalAppData/winget-app-setup/logs/install-20261004-150000-userphase.log'
        Mock Start-InstallerTranscript { $transcript }
        Mock Stop-Transcript { }
        Mock Install-UserPhaseApp {
            $script:logDirectoryDuringInstall = Get-InstallerLogDirectory
            New-AppRunRecord -Id $PackageId -Status 'Installed'
        }

        Invoke-TestUserPhase | Should -Be 0

        Should -Invoke Remove-OldInstallerLog -Times 1 -Exactly -ParameterFilter { $KeepTranscripts -eq 10 -and $CurrentTranscriptPath -eq $transcript }
        $script:logDirectoryDuringInstall | Should -Be (Split-Path -Parent $transcript)
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        $script:InstallLogPath | Should -BeNullOrEmpty
        (Get-TestState).transcriptPath | Should -Be $transcript
    }
}
