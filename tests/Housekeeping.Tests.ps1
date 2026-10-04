# Housekeeping.Tests.ps1
# Tests for WingetAppSetup/Private/Housekeeping.ps1: retention for the installer's logs and its
# leftover temporary copies (review finding P3-42). Everything runs against folders in TestDrive;
# the entry script's call (only for a real, elevated run that holds the run lock) is tested in
# EntryPoint.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A file in -Directory with the given name.
    function New-TestFile {
        param ([string]$Directory, [string]$Name)
        [void](New-Item -ItemType Directory -Path $Directory -Force)
        $path = Join-Path $Directory $Name
        Set-Content -LiteralPath $path -Value 'test' -Encoding ASCII
        $path
    }

    # The names left in a folder, sorted.
    function Get-TestFileName {
        param ([string]$Directory)
        @(Get-ChildItem -LiteralPath $Directory -Force | ForEach-Object { $_.Name } | Sort-Object)
    }

    # Transcripts install-20261001-HHMM00.log for the given minutes past 10:00, oldest first.
    function New-TestTranscriptSet {
        param ([string]$Directory, [int]$Count)
        for ($minute = 0; $minute -lt $Count; $minute++) {
            [void](New-TestFile -Directory $Directory -Name ('install-20261001-10{0:D2}00.log' -f $minute))
        }
    }

    # A copy folder like the installer's, with one file in it, last written -AgeHours ago.
    function New-TestCopyFolder {
        param ([string]$Root, [string]$Prefix = 'winget-app-setup-', [double]$AgeHours, [string]$FileName = 'winget-app-install.ps1')
        $path = Join-Path $Root ($Prefix + [Guid]::NewGuid().ToString('N'))
        [void](New-TestFile -Directory $path -Name $FileName)
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-$AgeHours)
        $path
    }
}

Describe 'Remove-OldInstallerLog (review finding P3-42)' {
    BeforeEach {
        $script:logDirectory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:logDirectory -Force)
    }

    It 'Keeps the newest transcripts and deletes the older ones' {
        New-TestTranscriptSet -Directory $script:logDirectory -Count 7

        $removed = Remove-OldInstallerLog -LogDirectory $script:logDirectory -KeepTranscripts 4

        $removed | Should -Be 3
        Get-TestFileName -Directory $script:logDirectory | Should -Be @(
            'install-20261001-100300.log', 'install-20261001-100400.log', 'install-20261001-100500.log', 'install-20261001-100600.log'
        )
    }

    It 'Counts bootstrap and dry-run transcripts with the rest, by the time in their names' {
        [void](New-TestFile -Directory $script:logDirectory -Name 'install-20261001-100000-bootstrap.log')
        [void](New-TestFile -Directory $script:logDirectory -Name 'install-20261001-100001.log')
        [void](New-TestFile -Directory $script:logDirectory -Name 'install-20261001-110000-whatif.log')
        [void](New-TestFile -Directory $script:logDirectory -Name 'install-20261001-120000-bootstrap-whatif.log')

        Remove-OldInstallerLog -LogDirectory $script:logDirectory -KeepTranscripts 2 | Should -Be 2

        Get-TestFileName -Directory $script:logDirectory | Should -Be @('install-20261001-110000-whatif.log', 'install-20261001-120000-bootstrap-whatif.log')
    }

    It 'Deletes the installer logs of the runs whose transcripts it deleted, and keeps the rest' {
        New-TestTranscriptSet -Directory $script:logDirectory -Count 3
        # Written during the 10:00 run (deleted below) and during the 10:01 and 10:02 runs (kept).
        foreach ($name in @(
                'winget-install-Git.Git-20261001-100010.log',
                'winget-install-Git.Git-20261001-100010-2.log',
                'pwsh-msi-20261001-100005-1.log',
                'winget-install-Zoom.Zoom-20261001-100100.log',
                'winget-upgrade-Microsoft.PowerShell-20261001-100230.log',
                'pwsh-msi-20261001-100130-2.log'
            )) {
            [void](New-TestFile -Directory $script:logDirectory -Name $name)
        }

        Remove-OldInstallerLog -LogDirectory $script:logDirectory -KeepTranscripts 2 | Should -Be 4

        Get-TestFileName -Directory $script:logDirectory | Should -Be @(
            'install-20261001-100100.log', 'install-20261001-100200.log',
            'pwsh-msi-20261001-100130-2.log',
            'winget-install-Zoom.Zoom-20261001-100100.log', 'winget-upgrade-Microsoft.PowerShell-20261001-100230.log'
        )
    }

    It 'Never touches last-run.json or files it did not write' {
        New-TestTranscriptSet -Directory $script:logDirectory -Count 3
        foreach ($name in @('last-run.json', 'notes.txt', 'install-old.log', 'winget-install-20200101-000000.txt', 'support-bundle.zip')) {
            [void](New-TestFile -Directory $script:logDirectory -Name $name)
        }

        Remove-OldInstallerLog -LogDirectory $script:logDirectory -KeepTranscripts 1 | Should -Be 2

        Get-TestFileName -Directory $script:logDirectory | Should -Be @(
            'install-20261001-100200.log', 'install-old.log', 'last-run.json', 'notes.txt', 'support-bundle.zip', 'winget-install-20200101-000000.txt'
        )
    }

    It 'Deletes nothing while there are no more transcripts than it keeps, old installer logs included' {
        New-TestTranscriptSet -Directory $script:logDirectory -Count 3
        [void](New-TestFile -Directory $script:logDirectory -Name 'winget-install-Git.Git-20200101-000000.log')

        Remove-OldInstallerLog -LogDirectory $script:logDirectory -KeepTranscripts 3 | Should -Be 0

        @(Get-TestFileName -Directory $script:logDirectory).Count | Should -Be 4
    }

    It 'Never deletes the current run''s transcript, even when its name sorts oldest (clock set back)' {
        New-TestTranscriptSet -Directory $script:logDirectory -Count 3
        $current = New-TestFile -Directory $script:logDirectory -Name 'install-20200101-000000.log'

        Remove-OldInstallerLog -LogDirectory $script:logDirectory -KeepTranscripts 2 -CurrentTranscriptPath $current | Should -Be 1

        Test-Path -LiteralPath $current | Should -BeTrue
        Get-TestFileName -Directory $script:logDirectory | Should -Be @('install-20200101-000000.log', 'install-20261001-100100.log', 'install-20261001-100200.log')
    }

    It 'Returns 0 for a folder that does not exist' {
        Remove-OldInstallerLog -LogDirectory (Join-Path $TestDrive 'missing') -KeepTranscripts 1 | Should -Be 0
    }
}

Describe 'Remove-StaleInstallerCopy (review finding P3-42)' {
    BeforeEach {
        $script:tempRoot = Join-Path $TestDrive ('temp-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:tempRoot -Force)
    }

    It 'Removes every kind of copy folder the installer makes once it is old enough' {
        $relaunchCopy = New-TestCopyFolder -Root $script:tempRoot -AgeHours 30
        $stagedCopy = New-TestCopyFolder -Root $script:tempRoot -Prefix 'winget-app-setup-elevate-' -AgeHours 48
        $msiDownload = New-TestCopyFolder -Root $script:tempRoot -Prefix 'winget-app-setup-pwsh-' -AgeHours 25 -FileName 'PowerShell-7.6.4-win-x64.msi'

        Remove-StaleInstallerCopy -Root @($script:tempRoot) -MaxAgeHours 24 | Should -Be 3

        Test-Path -LiteralPath $relaunchCopy | Should -BeFalse
        Test-Path -LiteralPath $stagedCopy | Should -BeFalse
        Test-Path -LiteralPath $msiDownload | Should -BeFalse
    }

    It 'Keeps a copy folder that is not old enough, since its run may still be going' {
        $recent = New-TestCopyFolder -Root $script:tempRoot -AgeHours 2

        Remove-StaleInstallerCopy -Root @($script:tempRoot) -MaxAgeHours 24 | Should -Be 0

        Test-Path -LiteralPath $recent | Should -BeTrue
    }

    It 'Keeps the running installer''s own folder, whatever its age' {
        $current = New-TestCopyFolder -Root $script:tempRoot -AgeHours 100

        Remove-StaleInstallerCopy -Root @($script:tempRoot) -MaxAgeHours 24 -CurrentScriptPath (Join-Path $current 'winget-app-install.ps1') | Should -Be 0

        Test-Path -LiteralPath $current | Should -BeTrue
    }

    It 'Leaves folders whose names are not the installer''s alone' {
        $kept = @(
            (New-TestCopyFolder -Root $script:tempRoot -Prefix 'winget-app-setup-tests-' -AgeHours 100),
            (New-TestCopyFolder -Root $script:tempRoot -Prefix 'other-app-' -AgeHours 100)
        )
        $shortName = Join-Path $script:tempRoot 'winget-app-setup-1234'
        [void](New-TestFile -Directory $shortName -Name 'file.txt')
        (Get-Item -LiteralPath $shortName).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-10)

        Remove-StaleInstallerCopy -Root @($script:tempRoot) -MaxAgeHours 24 | Should -Be 0

        foreach ($path in $kept + $shortName) {
            Test-Path -LiteralPath $path | Should -BeTrue
        }
    }

    It 'Leaves a folder that holds a folder: the installer''s copy folders hold files only' {
        # Any account can create entries in %SystemRoot%\Temp, so a folder with the installer's
        # name but a different shape is someone else's, and nothing inside it is followed.
        $foreign = New-TestCopyFolder -Root $script:tempRoot -AgeHours 100
        [void](New-Item -ItemType Directory -Path (Join-Path $foreign 'nested') -Force)
        (Get-Item -LiteralPath $foreign).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-100)

        Remove-StaleInstallerCopy -Root @($script:tempRoot) -MaxAgeHours 24 | Should -Be 0

        Test-Path -LiteralPath (Join-Path $foreign 'winget-app-install.ps1') | Should -BeTrue
    }

    It 'Skips roots that are missing or listed twice' {
        [void](New-TestCopyFolder -Root $script:tempRoot -AgeHours 30)

        $removed = Remove-StaleInstallerCopy -Root @($script:tempRoot, ($script:tempRoot + [System.IO.Path]::DirectorySeparatorChar), (Join-Path $TestDrive 'missing'), '') -MaxAgeHours 24

        $removed | Should -Be 1
    }
}

Describe 'Invoke-InstallerHousekeeping (review finding P3-42)' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        $script:savedInstallLogPath = $script:InstallLogPath
        $script:logDirectory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        $script:tempRoot = Join-Path $TestDrive ('temp-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:logDirectory, $script:tempRoot -Force)
    }

    AfterEach {
        $script:InstallLogPath = $script:savedInstallLogPath
    }

    It 'Keeps the newest 30 transcripts in the run''s log folder and removes copy folders a day old' {
        New-TestTranscriptSet -Directory $script:logDirectory -Count 33
        $script:InstallLogPath = Join-Path $script:logDirectory 'install-20261001-103200.log'
        $dayOld = New-TestCopyFolder -Root $script:tempRoot -AgeHours 25
        $hoursOld = New-TestCopyFolder -Root $script:tempRoot -AgeHours 20

        $result = Invoke-InstallerHousekeeping -TempRoot @($script:tempRoot)

        $result.LogsRemoved | Should -Be 3
        $result.CopiesRemoved | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:logDirectory -Filter 'install-*.log').Count | Should -Be 30
        Test-Path -LiteralPath (Join-Path $script:logDirectory 'install-20261001-100200.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:logDirectory 'install-20261001-100300.log') | Should -BeTrue
        Test-Path -LiteralPath $dayOld | Should -BeFalse
        Test-Path -LiteralPath $hoursOld | Should -BeTrue
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq 'Removed 3 old log file(s), keeping the logs of the newest 30 transcripts, and 1 leftover temporary copy folder(s) of the installer.' }
    }

    It 'Looks in this account''s temp folder and the elevated relaunch''s copy folder by default' {
        Mock Remove-OldInstallerLog { 0 }
        Mock Remove-StaleInstallerCopy { 0 }
        Mock Get-ElevatedCopyRoot { 'X:\Windows\Temp' }

        [void](Invoke-InstallerHousekeeping -LogDirectory $script:logDirectory -CurrentScriptPath 'X:\copy\winget-app-install.ps1')

        Should -Invoke Remove-StaleInstallerCopy -Times 1 -Exactly -ParameterFilter {
            $Root.Count -eq 2 -and $Root[0] -eq [System.IO.Path]::GetTempPath() -and $Root[1] -eq 'X:\Windows\Temp' -and
            $MaxAgeHours -eq 24 -and $CurrentScriptPath -eq 'X:\copy\winget-app-install.ps1'
        }
        Should -Invoke Remove-OldInstallerLog -Times 1 -Exactly -ParameterFilter { $LogDirectory -eq $script:logDirectory -and $KeepTranscripts -eq 30 }
    }

    It 'Prunes no logs when the run has no transcript' {
        $script:InstallLogPath = $null
        Mock Remove-OldInstallerLog { 0 }

        [void](Invoke-InstallerHousekeeping -TempRoot @($script:tempRoot))

        Should -Invoke Remove-OldInstallerLog -Times 0
    }

    It 'Says nothing when there was nothing to remove' {
        [void](Invoke-InstallerHousekeeping -LogDirectory $script:logDirectory -TempRoot @($script:tempRoot))

        Should -Invoke Write-Info -Times 0
        Should -Invoke Write-WarningMessage -Times 0
    }

    It 'Warns and carries on when housekeeping fails, so it never stops a run' {
        Mock Remove-OldInstallerLog { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }

        { $script:housekeepingResult = Invoke-InstallerHousekeeping -LogDirectory $script:logDirectory -TempRoot @($script:tempRoot) } | Should -Not -Throw

        $script:housekeepingResult.LogsRemoved | Should -Be 0
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match "Could not remove the installer's old logs and temporary copies: Access to the path is denied\. Continuing\." }
    }
}
