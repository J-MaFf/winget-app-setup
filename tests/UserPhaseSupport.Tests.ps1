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
        # The record as the installer's run as SYSTEM leaves it (Get-RunRecordTrustProblem).
        Mock Get-Acl { New-TestFileAcl }
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

    It 'Ignores, with a warning, a record that someone other than SYSTEM or an administrator could have written' {
        $path = New-TestRunRecordFile -Directory $script:recordDirectory -Apps @((New-AppRunRecord -Id 'Contoso.Chosen' -Status 'Deferred'))
        Mock Get-Acl { New-TestFileAcl -OwnerSid 'S-1-5-21-1-2-3-1001' }

        Read-InstallerRunRecord -Path $path | Should -BeNullOrEmpty

        Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $path }
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter {
            $Message -like "Ignoring the run record ${path}: it is owned by S-1-5-21-1-2-3-1001 (S-1-5-21-1-2-3-1001), not by SYSTEM or Administrators. Only a record that SYSTEM or an administrator wrote is used*"
        }
    }

    It 'Checks the owner and access list while it holds the file open, so it reads the bytes it checked' {
        $path = New-TestRunRecordFile -Directory $script:recordDirectory -Apps @((New-AppRunRecord -Id 'Contoso.UserOnly' -Status 'Deferred'))
        $script:events = @()
        Mock Open-ReadLockedFile { $script:events += 'open'; [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read) }
        Mock Get-RunRecordTrustProblem { $script:events += 'check'; $null }

        (Read-InstallerRunRecord -Path $path).DeferredApps | Should -Be @('Contoso.UserOnly')

        $script:events | Should -Be @('open', 'check')
        # Closed again: the installer's next run can replace it.
        { [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
    }
}

Describe 'Get-RunRecordTrustProblem' {
    It 'Trusts <Case>' -ForEach @(
        @{ Case = 'a record the installer wrote as SYSTEM'; Owner = 'S-1-5-18'; Rules = $null }
        @{ Case = 'one an elevated administrator wrote, with read for Users and a deny entry'; Owner = 'S-1-5-32-544'; Rules = @(@{ Sid = 'S-1-5-32-544'; Rights = 2032127 }, @{ Sid = 'S-1-5-32-545'; Rights = 1179817 }, @{ Sid = 'S-1-1-0'; Rights = 2032127; Type = 'Deny' }) }
        @{ Case = 'one whose only other write entry passes to child items without applying to it'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-18'; Rights = 2032127 }, @{ Sid = 'S-1-3-0'; Rights = 268435456; InheritOnly = $true }) }
    ) {
        $owner = $Owner
        $rules = $Rules
        if ($null -eq $rules) {
            Mock Get-Acl { New-TestFileAcl -OwnerSid $owner }
        }
        else {
            Mock Get-Acl { New-TestFileAcl -OwnerSid $owner -Rules $rules }
        }

        Get-RunRecordTrustProblem -Path 'C:\ProgramData\winget-app-setup\logs\last-run.json' | Should -BeNullOrEmpty
    }

    It 'Does not trust one that <Case>' -ForEach @(
        @{ Case = 'a user owns'; Owner = 'S-1-5-21-1-2-3-1001'; Rules = @(@{ Sid = 'S-1-5-18'; Rights = 2032127 }); Expected = 'it is owned by S-1-5-21-1-2-3-1001 (S-1-5-21-1-2-3-1001), not by SYSTEM or Administrators' }
        @{ Case = 'Users may write to'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-32-545'; Rights = 0x2 }); Expected = 'S-1-5-32-545 (S-1-5-32-545) can change it' }
        @{ Case = 'a user may append to'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-21-1-2-3-1001'; Rights = 0x4 }); Expected = 'S-1-5-21-1-2-3-1001 (S-1-5-21-1-2-3-1001) can change it' }
        @{ Case = 'a user may delete'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-21-1-2-3-1001'; Rights = 0x10000 }); Expected = 'S-1-5-21-1-2-3-1001 (S-1-5-21-1-2-3-1001) can change it' }
        @{ Case = 'a user may change the access list of'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-21-1-2-3-1001'; Rights = 0x40000 }); Expected = 'S-1-5-21-1-2-3-1001 (S-1-5-21-1-2-3-1001) can change it' }
        @{ Case = 'a user may take ownership of'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-21-1-2-3-1001'; Rights = 0x80000 }); Expected = 'S-1-5-21-1-2-3-1001 (S-1-5-21-1-2-3-1001) can change it' }
        @{ Case = 'Everyone has generic write on'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-1-0'; Rights = 0x40000000 }); Expected = 'S-1-1-0 (S-1-1-0) can change it' }
        @{ Case = 'Authenticated Users have full control of'; Owner = 'S-1-5-32-544'; Rules = @(@{ Sid = 'S-1-5-11'; Rights = 2032127 }); Expected = 'S-1-5-11 (S-1-5-11) can change it' }
    ) {
        $owner = $Owner
        $rules = $Rules
        Mock Get-Acl { New-TestFileAcl -OwnerSid $owner -Rules $rules }

        Get-RunRecordTrustProblem -Path 'C:\ProgramData\winget-app-setup\logs\last-run.json' | Should -Be $Expected
    }

    It 'Does not trust one whose access list cannot be read' {
        Mock Get-Acl { throw 'Attempted to perform an unauthorized operation.' }

        Get-RunRecordTrustProblem -Path 'C:\ProgramData\winget-app-setup\logs\last-run.json' | Should -Be 'its owner and access list could not be read (Attempted to perform an unauthorized operation.)'
    }

    # The real Get-Acl, on Windows only: the seam's property names (FileSystemRights,
    # PropagationFlags) are what the checks above rely on.
    It 'Reads a real file''s owner and entries, and names an account that was given write access' -Skip:(-not $IsWindows) {
        $path = Join-Path $TestDrive ('trust-' + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $path -Value '{}'
        $grant = Start-Process -FilePath 'icacls.exe' -ArgumentList "`"$path`" /grant *S-1-5-32-545:(W) /q" -Wait -PassThru -WindowStyle Hidden
        $grant.ExitCode | Should -Be 0

        $summary = Get-DirectoryAccessSummary -Path $path
        $summary.OwnerSid | Should -Be ((Get-Acl -LiteralPath $path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value)
        $usersWrite = @($summary.AccessRules | Where-Object { $_.Sid -eq 'S-1-5-32-545' -and $_.AccessControlType -eq 'Allow' -and -not $_.InheritOnly -and ($_.Rights -band 0x2) -ne 0 })
        $usersWrite.Count | Should -BeGreaterThan 0
        Get-RunRecordTrustProblem -Path $path | Should -Match 'S-1-5-32-545\) can change it'
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

Describe 'Update-UserPhaseWingetSource' {
    BeforeEach {
        $script:output = @()
        Mock Write-Info { $script:output += "INFO: $Message" }
        Mock Write-Success { $script:output += "OK: $Message" }
        Mock Write-WarningMessage { $script:output += "WARN: $Message" }
    }

    It 'Updates only the winget source, without the agreements flag source update rejects, within its time limit' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }

        Update-UserPhaseWingetSource

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'source update --name winget --disable-interactivity' -and $TimeoutSeconds -eq 120
        }
        $script:output | Should -Contain 'OK: The winget source is up to date for this account.'
    }

    It 'Says why the source could not be updated (<Case>), and never resets it' -ForEach @(
        @{ Case = 'an exit code'; Result = @{ ExitCode = -1978335221 }; Expected = 'WARN: The winget source could not be updated for this account (exit code 0x8A15000B*). The installs may fail; a later sign-in tries again.' }
        @{ Case = 'winget could not start'; Result = @{ LaunchFailed = $true; LaunchError = 'Access is denied.' }; Expected = 'WARN: The winget source could not be updated for this account (winget could not be started: Access is denied.). The installs may fail; a later sign-in tries again.' }
    ) {
        $result = $Result
        Mock Invoke-WingetProcess { New-TestProcessResult @result }
        Mock Write-ProcessOutput { }

        Update-UserPhaseWingetSource

        @($script:output | Where-Object { $_ -like $Expected }).Count | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
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
