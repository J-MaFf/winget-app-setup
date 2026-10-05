# Diagnostics.Tests.ps1
# Tests for the diagnostics bundle (WingetAppSetup/Private/Diagnostics.ps1, wgt-gq8.35): the .zip a
# teammate attaches to a public GitHub issue after a failed run. The redaction runs on the sample
# files in tests/fixtures/diagnostics, every source the collector reads is mocked, and the bundle is
# written to TestDrive, so nothing here reads or changes the machine.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:fixtureRoot = Join-Path $PSScriptRoot 'fixtures/diagnostics'
    $script:fixtures = [ordered]@{}
    foreach ($name in @('transcript.txt', 'msi-log.txt', 'appx.txt', 'wau-updates.txt')) {
        $script:fixtures[$name] = Get-Content -Raw -LiteralPath (Join-Path $script:fixtureRoot $name)
    }

    # What the PC itself says about its names (Get-DiagnosticsIdentityHint); the fixtures carry
    # more, which the map must find on its own.
    function New-TestIdentityHint {
        param (
            [string[]]$ComputerNames = @('PC-4711'),
            [string[]]$DnsDomains = @('corp.contoso.com'),
            [string[]]$Domains = @('CONTOSO'),
            [string[]]$Users = @('jdoe'),
            [string[]]$Organizations = @()
        )
        [pscustomobject]@{
            ComputerNames = $ComputerNames
            DnsDomains    = $DnsDomains
            Domains       = $Domains
            Users         = $Users
            Organizations = $Organizations
        }
    }

    # Every name, SID and address in the fixtures that identifies the PC or a person.
    $script:sensitiveTokens = @(
        'jdoe', 'admin-tech', 'PC-4711', 'CONTOSO', 'corp.contoso.com', 'Jane Q. Sample', 'Fabrikam Widgets Ltd',
        'maria.lopez', 'Kim.Park', 'ADMIN-~1', '1004336348-1177238915-682003330', '1234567890-2345678901-3456789012-4567890123'
    )

    # Reads every entry of a .zip as text.
    function Get-ZipEntryText {
        param ([string]$Path)
        Add-Type -AssemblyName System.IO.Compression
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
            $entries = [ordered]@{}
            foreach ($entry in $archive.Entries) {
                $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
                try {
                    $entries[$entry.FullName] = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
            }
            $archive.Dispose()
            return $entries
        }
        finally {
            $stream.Dispose()
        }
    }
}

Describe 'Redacting the bundle for a public issue (wgt-gq8.35)' {
    BeforeAll {
        $script:map = New-DiagnosticsRedactionMap -IdentityHint (New-TestIdentityHint) -Text @($script:fixtures.Values)
        $script:redacted = [ordered]@{}
        foreach ($name in $script:fixtures.Keys) {
            $script:redacted[$name] = ConvertTo-RedactedDiagnosticText -Text $script:fixtures[$name] -Map $script:map
        }
        $script:allRedacted = ($script:redacted.Values -join "`n")
    }

    It 'Removes <_> from every fixture' -ForEach @(
        'jdoe', 'admin-tech', 'PC-4711', 'CONTOSO', 'corp.contoso.com', 'Jane Q. Sample', 'Fabrikam Widgets Ltd',
        'maria.lopez', 'Kim.Park', 'ADMIN-~1', '1004336348-1177238915-682003330', '1234567890-2345678901-3456789012-4567890123',
        'jdoe@contoso.com'
    ) {
        $script:allRedacted | Should -Not -Match ([regex]::Escape($_))
    }

    It 'Replaces the transcript header''s accounts and computer, keeping who ran what apart' {
        $transcript = $script:redacted['transcript.txt']
        $transcript | Should -Match '(?m)^Username: <domain1>\\<user\d+>\r?$'
        $transcript | Should -Match '(?m)^RunAs User: <domain1>\\<user\d+>\r?$'
        $transcript -match '(?m)^Username: <domain1>\\(?<user><user\d+>)' | Should -BeTrue
        $sessionUser = $Matches['user']
        $transcript -match '(?m)^RunAs User: <domain1>\\(?<user><user\d+>)' | Should -BeTrue
        $Matches['user'] | Should -Not -Be $sessionUser
        $transcript | Should -Match '(?m)^Machine: <computer1> \(Microsoft Windows NT 10\.0\.26100\.0\)'
    }

    It 'Gives a name and a SID the same placeholder in every file' {
        $transcript = $script:redacted['transcript.txt']
        $transcript -match "(?m)^Username: <domain1>\\(?<user><user\d+>)" | Should -BeTrue
        $sessionUser = $Matches['user']
        $transcript | Should -Match ([regex]::Escape("C:\Users\$sessionUser\AppData\Local\Temp"))
        $script:redacted['wau-updates.txt'] | Should -Match ([regex]::Escape("<domain1>\$sessionUser (C:\Users\$sessionUser)"))
        $script:redacted['wau-updates.txt'] | Should -Match ([regex]::Escape('Running in System context as <computer1>$'))
        $transcript | Should -Match ([regex]::Escape('HKEY_USERS\S-1-5-21-<sid1>-1104 (<computer1>.<dns-domain1>)'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('User: S-1-5-21-<sid1>-1104 Installed'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('User: S-1-5-21-<sid1>-1105 Installed'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('User: S-1-5-21-<sid1>-1106 [<domain1>\<user'))
    }

    It 'Keeps the RID of a SID and Azure AD''s prefix, and the well-known SIDs and accounts' {
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('User: S-1-12-1-<sid2> Installed'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('User: S-1-5-18 Staged'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('[<domain1>\<user'))
        $wellKnown = 'Well-known accounts stay: NT AUTHORITY\SYSTEM, BUILTIN\Administrators, S-1-5-18, S-1-5-32-544, S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
        $script:redacted['transcript.txt'] | Should -Match ([regex]::Escape($wellKnown))
    }

    It 'Takes the values out of the msiexec user properties' {
        foreach ($property in @('UserSID', 'LogonUser', 'USERNAME', 'COMPANYNAME', 'ComputerName')) {
            $script:redacted['msi-log.txt'] | Should -Match ('(?m)^Property\(S\): {0} = <redacted>\r?$' -f $property)
        }
        $script:redacted['msi-log.txt'] | Should -Match ([regex]::Escape("Its value is '<organization1>'"))
    }

    It 'Replaces a profile folder it has no name for, and keeps Public and the empty Users folder' {
        $script:redacted['transcript.txt'] | Should -Match ([regex]::Escape('Another profile on this PC: C:\Users\<user>\AppData\Local and the shared C:\Users\Public\Documents'))
        $script:redacted['msi-log.txt'] | Should -Match ([regex]::Escape('TempFolder = C:\Users\<user>\AppData\Local\Temp\'))
        $script:redacted['msi-log.txt'] | Should -Match ([regex]::Escape('ProfilesFolder = C:\Users\'))
        $script:redacted['transcript.txt'] | Should -Match ([regex]::Escape('Contact for this PC: <email>'))
    }

    It 'Keeps what the owner needs to debug the run' {
        foreach ($kept in @(
                'Installer build: 1.0.0+0badc0de',
                'Installer failed with exit code: 1603',
                'winget exit 0x8A150101 INSTALL_PACKAGE_IN_USE',
                '--id Git.Git --scope machine --log C:\ProgramData\winget-app-setup\logs\winget-install-Git.Git-20261004-143300.log',
                'C:\Windows\Temp\winget-app-setup-0123456789abcdef0123456789abcdef\winget-app-install.ps1',
                'RESULT: exit=1 installed=11 skipped=2 deferred=0 failed=1 autoupdates=Configured restart=no build=1.0.0+0badc0de'
            )) {
            $script:redacted['transcript.txt'] | Should -Match ([regex]::Escape($kept))
        }
        $script:redacted['msi-log.txt'] | Should -Match ([regex]::Escape('Installation success or error status: 1603.'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'))
        $script:redacted['appx.txt'] | Should -Match ([regex]::Escape('Microsoft.WindowsAppRuntime.1.8 8000.616.304.0 X64 Status=Ok Framework=True'))
        $script:redacted['wau-updates.txt'] | Should -Match ([regex]::Escape('Installing WinGet MSIXBundle for App Installer...'))
    }

    It 'Finds the names in the files when the PC no longer knows them (an earlier run''s accounts)' {
        $map = New-DiagnosticsRedactionMap -IdentityHint $null -Text @($script:fixtures['transcript.txt'])
        $redacted = ConvertTo-RedactedDiagnosticText -Text $script:fixtures['transcript.txt'] -Map $map

        foreach ($token in @('jdoe', 'admin-tech', 'PC-4711', 'CONTOSO', '1004336348')) {
            $redacted | Should -Not -Match ([regex]::Escape($token))
        }
    }

    It 'Finds the header names in a transcript with Windows line endings' {
        $crlf = ($script:fixtures['transcript.txt'] -replace '\r?\n', "`r`n")
        $map = New-DiagnosticsRedactionMap -IdentityHint $null -Text @($crlf, ($script:fixtures['msi-log.txt'] -replace '\r?\n', "`r`n"))
        $redacted = ConvertTo-RedactedDiagnosticText -Text $crlf -Map $map

        $redacted | Should -Match '(?m)^Username: <domain1>\\<user\d+>\r$'
        foreach ($token in @('jdoe', 'admin-tech', 'PC-4711', 'CONTOSO')) {
            $redacted | Should -Not -Match ([regex]::Escape($token))
        }
        @($map.Names | ForEach-Object { $_.Value }) | Should -Contain 'Jane Q. Sample'
    }

    It 'Redacts a name in any letter case, and one with letters outside ASCII' {
        $name = 'J' + [char]0x00F6 + 'rg'
        $map = New-DiagnosticsRedactionMap -IdentityHint (New-TestIdentityHint -Users @($name)) -Text @()
        $redacted = ConvertTo-RedactedDiagnosticText -Text ("{0} and {1} and {2}" -f $name, $name.ToUpperInvariant(), 'Jorg') -Map $map

        $redacted | Should -Be '<user1> and <user1> and Jorg'
    }

    It 'Replaces whole names only, the longest first' {
        $map = New-DiagnosticsRedactionMap -IdentityHint (New-TestIdentityHint -Users @('ann', 'ann-marie')) -Text @()

        ConvertTo-RedactedDiagnosticText -Text 'ann-marie, ann, annual, Anna' -Map $map | Should -Be '<user2>, <user1>, annual, Anna'
    }

    It 'Keeps built-in names and generic owners, and skips names too short to be safe to replace' {
        $hint = New-TestIdentityHint -ComputerNames @('localhost') -Domains @('NT AUTHORITY', 'WORKGROUP') -Users @('Administrator', 'SYSTEM', 'User', 'Owner', 'x', '1001') -Organizations @('Windows User')
        $map = New-DiagnosticsRedactionMap -IdentityHint $hint -Text @()

        @($map.Names | Where-Object { $_.Value -ne 'corp.contoso.com' }).Count | Should -Be 0
        $text = 'NT AUTHORITY\SYSTEM ran as Administrator on WORKGROUP for User x (RID 1001)'
        ConvertTo-RedactedDiagnosticText -Text $text -Map $map | Should -Be $text
    }

    It 'Treats a computer account (PC$) as the computer' {
        $map = New-DiagnosticsRedactionMap -IdentityHint $null -Text @("Username: CONTOSO\PC-0815`$`r`nRunAs User: NT AUTHORITY\SYSTEM")
        $redacted = ConvertTo-RedactedDiagnosticText -Text "Username: CONTOSO\PC-0815`$`r`nRunAs User: NT AUTHORITY\SYSTEM`r`nPC-0815 is ready" -Map $map

        $redacted | Should -Be "Username: <domain1>\<computer1>`$`r`nRunAs User: NT AUTHORITY\SYSTEM`r`n<computer1> is ready"
    }

    It 'Redacts the SID of a real account the map does not know' {
        $map = New-DiagnosticsRedactionMap -IdentityHint $null -Text @()

        ConvertTo-RedactedDiagnosticText -Text 'S-1-5-21-11-22-33-1001 and S-1-12-1-1-2-3-4' -Map $map | Should -Be 'S-1-5-21-<sid>-1001 and S-1-12-1-<sid>'
    }
}

Describe 'Choosing the latest run''s logs (Select-DiagnosticsLogFile)' {
    BeforeEach {
        $script:logDirectory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:logDirectory | Out-Null
        function New-LogFile {
            param ([string[]]$Name)
            foreach ($fileName in $Name) {
                Set-Content -LiteralPath (Join-Path $script:logDirectory $fileName) -Value $fileName
            }
        }
        # An older run, then a cross-user run started from Windows PowerShell 5.1: the bootstrap and
        # PowerShell 7 transcripts of the window that asked for elevation and of the elevated one.
        New-LogFile -Name @(
            'install-20261001-100000.log', 'winget-install-Old.App-20261001-100100.log',
            'install-20261004-142900-bootstrap.log', 'pwsh-msi-20261004-142930-1.log', 'install-20261004-143000.log',
            'install-20261004-143200-bootstrap.log', 'install-20261004-143205.log',
            'winget-install-Git.Git-20261004-143300.log', 'winget-install-Git.Git-20261004-143300-2.log',
            'wau-msi-install-20261004-150000-1.log',
            'install-20261004-160000-whatif.log', 'notes.txt'
        )
    }

    It 'Takes every transcript of the latest run and its installer logs, oldest first, and no dry run' {
        $selection = Select-DiagnosticsLogFile -LogDirectory $script:logDirectory

        @($selection.Transcripts | ForEach-Object { $_.Name }) | Should -Be @(
            'install-20261004-142900-bootstrap.log', 'install-20261004-143000.log', 'install-20261004-143200-bootstrap.log', 'install-20261004-143205.log')
        # Within one second the order of two logs does not matter.
        @($selection.InstallerLogs | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @(
            'pwsh-msi-20261004-142930-1.log', 'wau-msi-install-20261004-150000-1.log', 'winget-install-Git.Git-20261004-143300-2.log', 'winget-install-Git.Git-20261004-143300.log' | Sort-Object)
        $selection.InstallerLogs[0].Name | Should -Be 'pwsh-msi-20261004-142930-1.log'
        $selection.InstallerLogs[3].Name | Should -Be 'wau-msi-install-20261004-150000-1.log'
        $selection.RunRecord | Should -BeNullOrEmpty
        @($selection.Files).Count | Should -Be 12
    }

    It 'Adds last-run.json, and the transcript it names when that is older' {
        Set-Content -LiteralPath (Join-Path $script:logDirectory 'last-run.json') -Value '{"exitCode":1,"transcriptPath":"C:\\ProgramData\\winget-app-setup\\logs\\install-20261001-100000.log"}'

        $selection = Select-DiagnosticsLogFile -LogDirectory $script:logDirectory

        $selection.RunRecord.Name | Should -Be 'last-run.json'
        @($selection.Transcripts | ForEach-Object { $_.Name }) | Should -Contain 'install-20261001-100000.log'
        @($selection.InstallerLogs | ForEach-Object { $_.Name }) | Should -Contain 'winget-install-Old.App-20261001-100100.log'
    }

    It 'Keeps to its limits, newest first' {
        $selection = Select-DiagnosticsLogFile -LogDirectory $script:logDirectory -MaximumTranscripts 2 -MaximumInstallerLogs 1

        @($selection.Transcripts | ForEach-Object { $_.Name }) | Should -Be @('install-20261004-143200-bootstrap.log', 'install-20261004-143205.log')
        @($selection.InstallerLogs | ForEach-Object { $_.Name }) | Should -Be @('wau-msi-install-20261004-150000-1.log')
    }

    It 'Takes nothing from an empty folder, and throws for a folder that cannot be listed' {
        $empty = Join-Path $TestDrive ('empty-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty | Out-Null

        $selection = Select-DiagnosticsLogFile -LogDirectory $empty
        @($selection.Transcripts).Count | Should -Be 0
        @($selection.InstallerLogs).Count | Should -Be 0
        { Select-DiagnosticsLogFile -LogDirectory (Join-Path $TestDrive 'no-such-folder') } | Should -Throw
    }
}

Describe 'Reading a log for the bundle (Read-DiagnosticsTextFile)' {
    It 'Reads <Name>' -ForEach @(
        @{ Name = 'UTF-16 LE with a byte order mark (an msiexec log)'; Encoding = [System.Text.UnicodeEncoding]::new($false, $true) }
        @{ Name = 'UTF-8 with a byte order mark'; Encoding = [System.Text.UTF8Encoding]::new($true) }
        @{ Name = 'UTF-8 without one'; Encoding = [System.Text.UTF8Encoding]::new($false) }
    ) {
        $path = Join-Path $TestDrive ('encoded-' + [Guid]::NewGuid().ToString('N') + '.log')
        $text = "Property(S): USERNAME = J" + [char]0x00F6 + "rg`r`nsecond line"
        [System.IO.File]::WriteAllText($path, $text, $Encoding)

        Read-DiagnosticsTextFile -Path $path | Should -Be $text
    }

    It 'Reads UTF-16 LE without a byte order mark' {
        $path = Join-Path $TestDrive 'unicode-no-bom.log'
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::Unicode.GetBytes('MSI (s) log'))

        Read-DiagnosticsTextFile -Path $path | Should -Be 'MSI (s) log'
    }

    It 'Keeps the end of a long file, where an installer log has its result, and says what it left out' {
        $path = Join-Path $TestDrive 'long.log'
        [System.IO.File]::WriteAllText($path, ('a' * 100) + 'THE END', [System.Text.UTF8Encoding]::new($false))

        $text = Read-DiagnosticsTextFile -Path $path -MaxBytes 10

        $text | Should -Be ('[The first 97 bytes of this file were left out; its last 10 bytes follow.]' + [Environment]::NewLine + 'aaaTHE END')
    }

    It 'Keeps whole characters of a long UTF-16 file' {
        $path = Join-Path $TestDrive 'long-unicode.log'
        [System.IO.File]::WriteAllText($path, 'abcdefghij', [System.Text.UnicodeEncoding]::new($false, $true))

        (Read-DiagnosticsTextFile -Path $path -MaxBytes 7) | Should -Match '(?s)follow\.\]\r?\nhij$'
    }

    It 'Reads a log another process is still writing' {
        $path = Join-Path $TestDrive 'open.log'
        $writer = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes('still running')
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()

            Read-DiagnosticsTextFile -Path $path | Should -Be 'still running'
        }
        finally {
            $writer.Dispose()
        }
    }
}

Describe 'Where the bundle is saved (Get-DiagnosticsBundleDirectory)' {
    BeforeEach {
        $script:desktop = Join-Path $TestDrive 'Desktop'
        $script:publicDocuments = Join-Path $TestDrive 'PublicDocuments'
        New-Item -ItemType Directory -Path $script:desktop, $script:publicDocuments -Force | Out-Null
        Mock Get-DiagnosticsSpecialFolder {
            switch ($Name) {
                'Desktop' { $script:desktop }
                'CommonDocuments' { $script:publicDocuments }
            }
        }
    }

    It 'Puts it on the Desktop of the signed-in user who ran it' {
        $folders = @(Get-DiagnosticsBundleDirectory -AccountContext (New-TestAccountContext))

        $folders[0] | Should -Be $script:desktop
        $folders[1] | Should -Be $script:publicDocuments
    }

    It 'Puts it in Public Documents, which every account can read, for <Kind>' -ForEach @(
        @{ Kind = 'a run as SYSTEM'; System = $true }
        @{ Kind = 'a cross-user elevation'; System = $false }
    ) {
        $context = New-TestAccountContext -CrossUser -SessionUser 'CONTOSO\jdoe'
        if ($System) {
            $context = New-TestAccountContext -System
        }
        $folders = @(Get-DiagnosticsBundleDirectory -AccountContext $context)

        $folders[0] | Should -Be $script:publicDocuments
        $folders | Should -Not -Contain $script:desktop
    }

    It 'Falls back to the temp folder, and leaves out folders that do not exist' {
        $script:desktop = Join-Path $TestDrive 'missing-desktop'
        $script:publicDocuments = $null

        $folders = @(Get-DiagnosticsBundleDirectory -AccountContext (New-TestAccountContext))

        $folders | Should -Be @([System.IO.Path]::GetTempPath())
    }
}

Describe 'winget in the bundle (Get-DiagnosticsWingetReport)' {
    BeforeEach {
        Mock Invoke-WingetProcess {
            if ($ArgumentList[0] -eq '--version') {
                New-TestProcessResult -ExitCode 0 -Output @('v1.26.510')
            }
            else {
                New-TestProcessResult -ExitCode 0 -Output @('Windows Package Manager v1.26.510', 'Windows: Windows.Desktop v10.0.26100.4061')
            }
        }
        Mock Get-MachineWingetCandidate { }
    }

    It 'Runs winget --version and --info with the version-check time limit, no echo and no installer log' {
        $lines = @(Get-DiagnosticsWingetReport -AccountContext (New-TestAccountContext))

        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq '--version' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetVersion) -and $Echo -eq 'None' -and $LogDirectory -eq '' -and $WingetPath -eq 'winget'
        }
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '--info' -and $Echo -eq 'None' }
        $lines | Should -Contain 'winget --version: exit 0x00000000 (0), 0 seconds'
        $lines | Should -Contain '  v1.26.510'
        $lines | Should -Contain '  Windows: Windows.Desktop v10.0.26100.4061'
    }

    It 'Reports a winget that cannot be started instead of failing' {
        Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.' }

        $lines = @(Get-DiagnosticsWingetReport -AccountContext (New-TestAccountContext))

        $lines | Should -Contain 'winget --version: could not be started (error 1920): The file cannot be accessed by the system.'
        $lines | Should -Contain 'winget --info: could not be started (error 1920): The file cannot be accessed by the system.'
    }

    It 'Reports a winget that stopped at its time limit, and a named winget exit code' {
        Mock Invoke-WingetProcess {
            if ($ArgumentList[0] -eq '--version') { New-TestProcessResult -TimedOut } else { New-TestProcessResult -ExitCode -1978335174 }
        }

        $lines = @(Get-DiagnosticsWingetReport -AccountContext (New-TestAccountContext))

        $lines | Should -Contain 'winget --version: stopped at its time limit, after 0 seconds'
        ($lines -join "`n") | Should -Match 'winget --info: exit 0x8A15003A BLOCKED_BY_POLICY \(-1978335174\)'
    }

    It 'Runs the machine-wide winget.exe as SYSTEM, which has no winget alias' {
        Mock Get-MachineWingetCandidate { [pscustomobject]@{ Path = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe\winget.exe'; Version = [version]'1.26.510.0'; Architecture = 'x64'; Source = 'Get-AppxPackage -AllUsers' } }

        $lines = @(Get-DiagnosticsWingetReport -AccountContext (New-TestAccountContext -System))

        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly -ParameterFilter { $WingetPath -like '*\Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe\winget.exe' }
        $lines[0] | Should -Match '^winget\.exe for this PC \(as SYSTEM\): '
    }

    It 'Says so, and runs nothing, when SYSTEM finds no machine-wide winget.exe' {
        $lines = @(Get-DiagnosticsWingetReport -AccountContext (New-TestAccountContext -System))

        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        $lines[0] | Should -Match '^No machine-wide winget\.exe was found'
    }
}

Describe 'AppX packages in the bundle (Get-DiagnosticsAppxReport)' {
    BeforeEach {
        $script:appxCalls = @()
        Mock Invoke-ExternalProcess {
            $encodedIndex = [array]::IndexOf($ArgumentList, '-EncodedCommand')
            $script:appxCalls += [pscustomobject]@{
                FilePath  = $FilePath
                Arguments = $ArgumentList
                Script    = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[$encodedIndex + 1]))
                Timeout   = $TimeoutSeconds
                Echo      = $Echo
            }
            New-TestProcessResult -ExitCode 0 -Output @('== Registered for any account (Get-AppxPackage -AllUsers) ==', 'Microsoft.DesktopAppInstaller 1.26.510.0 X64 Status=Ok Framework=False')
        }
    }

    It 'Queries every account''s and the provisioned packages in Windows PowerShell, with a time limit' {
        $lines = @(Get-DiagnosticsAppxReport)

        $script:appxCalls.Count | Should -Be 1
        $call = $script:appxCalls[0]
        $call.FilePath | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $call.Arguments | Should -Contain '-NonInteractive'
        $call.Timeout | Should -Be 120
        $call.Echo | Should -Be 'None'
        $call.Script | Should -Match ([regex]::Escape("@('Microsoft.DesktopAppInstaller', 'Microsoft.WindowsAppRuntime.*')"))
        $call.Script | Should -Match 'Get-AppxPackage -AllUsers -Name \$name'
        $call.Script | Should -Match 'PackageUserInformation'
        $call.Script | Should -Match 'Get-AppxProvisionedPackage -Online'
        $call.Script | Should -Match ([regex]::Escape('[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)'))
        # The query changes nothing.
        $call.Script | Should -Not -Match '(?i)\b(Add|Remove|Reset|Set|Register)-Appx'
        $lines | Should -Be @('== Registered for any account (Get-AppxPackage -AllUsers) ==', 'Microsoft.DesktopAppInstaller 1.26.510.0 X64 Status=Ok Framework=False')
    }

    It 'The query script parses' {
        [void](Get-DiagnosticsAppxReport)
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:appxCalls[0].Script, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'Reports a Windows PowerShell that could not start' {
        Mock Invoke-ExternalProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'The system cannot find the file specified.' }

        $lines = @(Get-DiagnosticsAppxReport)

        $lines[0] | Should -Be 'Windows PowerShell (AppX queries): could not be started (error 2): The system cannot find the file specified.'
    }
}

Describe 'The machine''s state in the bundle (Get-DiagnosticsSystemReport)' {
    BeforeEach {
        Mock Get-DiagnosticsRegistryValue {
            switch ($Path) {
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' { [ordered]@{ ProductName = 'Windows 10 Pro'; EditionID = 'Professional'; InstallationType = 'Client'; DisplayVersion = '24H2'; CurrentBuild = '26100'; UBR = 4061 } }
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' { [ordered]@{ EnableAppInstaller = 1; EnableDefaultSource = 0 } }
                'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' { throw 'Access is denied' }
                default { $null }
            }
        }
        Mock Get-PendingRestartState { New-TestRestartState -WindowsUpdate -FileRenames @('\??\C:\Users\jdoe\a.tmp -> \??\C:\Users\jdoe\a.dll') }
        Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.12.0'; ProductCode = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' } }
        Mock Get-WauTaskHealth { [pscustomobject]@{ Healthy = $false; Exists = $true; CheckFailed = $false; State = 'Disabled'; Triggers = @('Weekly on Tuesday'); LastRunTime = $null; LastTaskResult = 267011; NextRunTime = $null; Problem = 'its scheduled task \WAU\Winget-AutoUpdate is disabled' } }
        Mock Get-AccountSid { 'S-1-5-21-1004336348-1177238915-682003330-1104' }
        Mock Get-OSArchitecture { 'Arm64' }
        Mock Get-ExecutionPolicy { @([pscustomobject]@{ Scope = 'MachinePolicy'; ExecutionPolicy = 'AllSigned' }, [pscustomobject]@{ Scope = 'Process'; ExecutionPolicy = 'Bypass' }) }
        $script:savedBuildId = $script:InstallerBuildId
        $script:InstallerBuildId = '1.0.0+0badc0de'
    }

    AfterEach {
        $script:InstallerBuildId = $script:savedBuildId
    }

    It 'Has the Windows build, the architecture, the accounts and the elevation style' {
        $lines = @(Get-DiagnosticsSystemReport -AccountContext (New-TestAccountContext -CrossUser -SessionUser 'CONTOSO\jdoe') -IsAdmin $true)

        $lines | Should -Contain 'Collected by installer build: 1.0.0+0badc0de'
        $lines | Should -Contain 'Product: Windows 10 Pro (Professional, Client)'
        $lines | Should -Contain 'Version: 24H2'
        $lines | Should -Contain 'Build: 26100.4061'
        $lines | Should -Contain 'OS architecture: Arm64'
        $lines | Should -Contain 'Signed-in user (console session): CONTOSO\jdoe (S-1-5-21-1004336348-1177238915-682003330-1104)'
        $lines | Should -Contain 'Elevation style: cross-user (elevated as another account than the signed-in user)'
        ($lines -join "`n") | Should -Match 'This collection ran as: CONTOSO\\admin-tech.*, elevated: yes'
    }

    It 'Has the execution policy, Group Policy, the pending restart and Winget-AutoUpdate, and goes on past a key it cannot read' {
        $lines = @(Get-DiagnosticsSystemReport -AccountContext (New-TestAccountContext) -IsAdmin $false)

        $lines | Should -Contain '  MachinePolicy = AllSigned'
        $lines | Should -Contain '  EnableAppInstaller = 1'
        $lines | Should -Contain '  EnableDefaultSource = 0'
        $lines | Should -Contain '  not read: Access is denied'
        $lines | Should -Contain 'Windows Update RebootRequired: True'
        $lines | Should -Contain 'File replacements queued for the next restart: 1'
        $lines | Should -Contain 'Installed: version 2.12.0, MSI product code {AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
        $lines | Should -Contain 'Task \WAU\Winget-AutoUpdate: state Disabled; triggers: Weekly on Tuesday; last run never, result 0x00041303; next run none scheduled'
        $lines | Should -Contain 'Task problem: its scheduled task \WAU\Winget-AutoUpdate is disabled'
        $lines | Should -Contain 'Elevation style: same-user, not elevated'
    }

    It 'Still reports the rest when the restart state and Winget-AutoUpdate cannot be read' {
        Mock Get-PendingRestartState { throw 'registry unavailable' }
        Mock Get-WauTaskHealth { throw 'task scheduler unavailable' }

        $lines = @(Get-DiagnosticsSystemReport -AccountContext $null -IsAdmin $true)

        $lines | Should -Contain 'Not read: registry unavailable'
        $lines | Should -Contain 'Task not read: task scheduler unavailable'
        $lines | Should -Contain 'Build: 26100.4061'
    }
}

Describe 'Get-DiagnosticsElevationStyle' {
    It 'Says <Expected>' -ForEach @(
        @{ Kind = 'System'; IsAdmin = $true; Expected = 'SYSTEM' }
        @{ Kind = 'CrossUser'; IsAdmin = $true; Expected = 'cross-user (elevated as another account than the signed-in user)' }
        @{ Kind = 'SameUser'; IsAdmin = $true; Expected = 'same-user, elevated' }
        @{ Kind = 'SameUser'; IsAdmin = $false; Expected = 'same-user, not elevated' }
    ) {
        $context = switch ($Kind) {
            'System' { New-TestAccountContext -System }
            'CrossUser' { New-TestAccountContext -CrossUser -SessionUser 'CONTOSO\jdoe' }
            default { New-TestAccountContext }
        }

        Get-DiagnosticsElevationStyle -AccountContext $context -IsAdmin $IsAdmin | Should -Be $Expected
    }
}

Describe 'The names the PC knows (Get-DiagnosticsIdentityHint)' {
    BeforeEach {
        Mock Get-DiagnosticsProfileList {
            [pscustomobject]@{ Sid = 'S-1-5-18'; ProfilePath = 'C:\Windows\system32\config\systemprofile' }
            [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1104'; ProfilePath = 'C:\Users\jdoe.CONTOSO' }
            [pscustomobject]@{ Sid = 'S-1-12-1-1-2-3-4'; ProfilePath = 'C:\Users\MariaLopez' }
        }
        Mock Get-DiagnosticsSidAccountName { if ($Sid -eq 'S-1-5-21-1-2-3-1104') { 'CONTOSO\john.doe' } }
        Mock Get-DiagnosticsRegistryValue { [ordered]@{ RegisteredOwner = 'Jane Q. Sample'; RegisteredOrganization = 'Fabrikam Widgets Ltd' } }
    }

    It 'Collects the accounts of the run, the profiles of real accounts and the registered owner' {
        $hint = Get-DiagnosticsIdentityHint -AccountContext (New-TestAccountContext -CrossUser -ProcessUser 'FABRIKAM\admin-tech' -SessionUser 'CONTOSO\jdoe')

        $hint.Users | Should -Contain 'admin-tech'
        $hint.Users | Should -Contain 'jdoe'
        $hint.Users | Should -Contain 'jdoe.CONTOSO'
        $hint.Users | Should -Contain 'john.doe'
        $hint.Users | Should -Contain 'MariaLopez'
        $hint.Users | Should -Contain 'Jane Q. Sample'
        $hint.Users | Should -Not -Contain 'systemprofile'
        $hint.Domains | Should -Contain 'FABRIKAM'
        $hint.Domains | Should -Contain 'CONTOSO'
        $hint.Organizations | Should -Contain 'Fabrikam Widgets Ltd'
        Should -Invoke Get-DiagnosticsSidAccountName -Times 0 -Exactly -ParameterFilter { $Sid -eq 'S-1-5-18' }
    }
}

Describe 'Making the bundle (Invoke-DiagnosticsCollection)' {
    BeforeEach {
        $script:messages = @()
        Mock Write-Info { $script:messages += "INFO: $Message" }
        Mock Write-Success { $script:messages += "OK: $Message" }
        Mock Write-WarningMessage { $script:messages += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:messages += "ERROR: $Message" }
        Mock Get-InstallAccountContext { New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe' }
        Mock Test-IsAdmin { $true }
        Mock Get-DiagnosticsIdentityHint { New-TestIdentityHint }
        Mock Get-DiagnosticsSystemReport { @('This collection ran as: CONTOSO\admin-tech, elevated: yes', 'Signed-in user (console session): CONTOSO\jdoe') }
        Mock Get-DiagnosticsWingetReport { @('winget --version: exit 0x00000000 (0), 0.2 seconds', '  v1.26.510') }
        Mock Get-DiagnosticsAppxReport { $script:fixtures['appx.txt'] -split '\r?\n' }
        Mock Get-DiagnosticsWauLogTail { $script:fixtures['wau-updates.txt'] -split '\r?\n' }

        # What a real run does and a diagnostics run must not.
        Mock Start-Transcript { }
        Mock Lock-InstallerRun { 'Acquired' }
        Mock Save-InstallerRunRecord { }
        Mock Save-InstallerRunStartRecord { }
        Mock Invoke-InstallerHousekeeping { }
        Mock Grant-InstallLogReadAccess { $true }
        Mock Initialize-Winget { }
        Mock Invoke-WingetInstall { 0 }
        Mock Restart-WithElevation { }
        Mock Invoke-PowerShell7Bootstrap { 0 }

        $script:logDirectory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:logDirectory | Out-Null
        Set-Content -LiteralPath (Join-Path $script:logDirectory 'install-20261004-143205.log') -Value $script:fixtures['transcript.txt'] -NoNewline
        Set-Content -LiteralPath (Join-Path $script:logDirectory 'winget-install-Git.Git-20261004-143300.log') -Value $script:fixtures['msi-log.txt'] -NoNewline
        Set-Content -LiteralPath (Join-Path $script:logDirectory 'last-run.json') -Value '{"exitCode":1,"transcriptPath":"C:\\ProgramData\\winget-app-setup\\logs\\install-20261004-143205.log"}'
        $script:outputDirectory = Join-Path $TestDrive ('out-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:outputDirectory | Out-Null
    }

    It 'Saves one .zip with every part, says where, and returns 0' {
        $exitCode = Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory -OutputDirectory $script:outputDirectory

        $exitCode | Should -Be 0
        $zip = @(Get-ChildItem -LiteralPath $script:outputDirectory -Filter 'winget-app-setup-diagnostics-*.zip')
        $zip.Count | Should -Be 1
        $zip[0].Name | Should -Match '^winget-app-setup-diagnostics-\d{8}-\d{6}\.zip$'
        $script:messages | Should -Contain "OK: Diagnostics bundle saved: $($zip[0].FullName)"
        $entries = Get-ZipEntryText -Path $zip[0].FullName
        @($entries.Keys) | Should -Be @('README.txt', 'logs/install-20261004-143205.log', 'logs/winget-install-Git.Git-20261004-143300.log', 'logs/last-run.json', 'system.txt', 'winget.txt', 'appx.txt', 'wau-updates-log-tail.txt')
        $entries['logs/install-20261004-143205.log'] | Should -Match 'Installer failed with exit code: 1603'
        $entries['winget.txt'] | Should -Match 'v1\.26\.510'
        $entries['README.txt'] | Should -Match 'Installer logs \(.+\): 1 transcript\(s\), 1 installer log\(s\), last-run\.json included'
    }

    It 'Removes every name from every file in the .zip' {
        [void](Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory -OutputDirectory $script:outputDirectory)

        $zip = @(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.zip')[0]
        $entries = Get-ZipEntryText -Path $zip.FullName
        foreach ($name in $entries.Keys) {
            foreach ($token in $script:sensitiveTokens) {
                $entries[$name] | Should -Not -Match ([regex]::Escape($token)) -Because "$name must not name '$token'"
            }
        }
        $entries['system.txt'] | Should -Match ([regex]::Escape('This collection ran as: <domain1>\<user'))
    }

    It 'Changes nothing on the PC: no transcript, run lock, run record, housekeeping, winget setup, install, elevation or PowerShell 7 bootstrap' {
        [void](Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory -OutputDirectory $script:outputDirectory)

        foreach ($command in @('Start-Transcript', 'Lock-InstallerRun', 'Save-InstallerRunRecord', 'Save-InstallerRunStartRecord', 'Invoke-InstallerHousekeeping', 'Grant-InstallLogReadAccess', 'Initialize-Winget', 'Invoke-WingetInstall', 'Restart-WithElevation', 'Invoke-PowerShell7Bootstrap')) {
            Should -Invoke $command -Times 0 -Exactly
        }
        # The logs it read are as they were, and it wrote nothing next to them.
        @(Get-ChildItem -LiteralPath $script:logDirectory).Count | Should -Be 3
        (Get-Content -Raw -LiteralPath (Join-Path $script:logDirectory 'install-20261004-143205.log')) | Should -Be $script:fixtures['transcript.txt']
    }

    It 'Saves it in the next folder when the first does not take it' {
        $missing = Join-Path $TestDrive 'no-such-folder'

        $exitCode = Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory -OutputDirectory @($missing, $script:outputDirectory)

        $exitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.zip').Count | Should -Be 1
        ($script:messages -join "`n") | Should -Match ([regex]::Escape("WARN: Could not save the diagnostics bundle in $missing"))
    }

    It 'Returns 5 when no folder takes it' {
        $exitCode = Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory -OutputDirectory @(Join-Path $TestDrive 'nowhere')

        $exitCode | Should -Be 5
        $script:messages | Should -Contain 'ERROR: The diagnostics bundle could not be saved in any folder (see above).'
    }

    It 'Uses the folders Get-DiagnosticsBundleDirectory picks for the account when none is given' {
        Mock Get-DiagnosticsBundleDirectory { $script:outputDirectory }

        [void](Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory)

        Should -Invoke Get-DiagnosticsBundleDirectory -Times 1 -Exactly -ParameterFilter { $AccountContext.IsCrossUserElevation }
        @(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.zip').Count | Should -Be 1
    }

    It 'Still makes the bundle when every source fails, and says which ones did' {
        Mock Get-DiagnosticsSystemReport { throw 'no registry' }
        Mock Get-DiagnosticsWingetReport { throw 'no winget' }
        Mock Get-DiagnosticsAppxReport { throw 'no appx' }
        Mock Get-DiagnosticsWauLogTail { throw 'no wau' }
        Mock Get-DiagnosticsIdentityHint { throw 'no names' }

        $exitCode = Invoke-DiagnosticsCollection -LogDirectory (Join-Path $TestDrive 'missing-logs') -OutputDirectory $script:outputDirectory

        $exitCode | Should -Be 0
        $entries = Get-ZipEntryText -Path (@(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.zip')[0]).FullName
        $entries['README.txt'] | Should -Match 'System \(system\.txt\): not collected: no registry'
        $entries['README.txt'] | Should -Match 'winget --version and --info \(winget\.txt\): not collected: no winget'
        $entries['README.txt'] | Should -Match 'AppX packages \(appx\.txt\): not collected: no appx'
        $entries['README.txt'] | Should -Match 'not collected: no wau'
        $entries['README.txt'] | Should -Match 'the folder does not exist or cannot be opened'
    }

    It 'Says what an elevated PowerShell would add when it is not elevated' {
        Mock Test-IsAdmin { $false }

        [void](Invoke-DiagnosticsCollection -LogDirectory $script:logDirectory -OutputDirectory $script:outputDirectory)

        $entries = Get-ZipEntryText -Path (@(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.zip')[0]).FullName
        $entries['README.txt'] | Should -Match 'This PowerShell was not elevated'
        ($script:messages -join "`n") | Should -Match 'WARN: This PowerShell is not elevated'
    }

    It 'Reads no environment variables wholesale' {
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:WingetAppSetupRoot 'Private/Diagnostics.ps1')

        $source | Should -Not -Match '(?i)GetEnvironmentVariables'
        $source | Should -Not -Match '(?i)(Get-ChildItem|Get-Item|dir|ls|gci)\s+-?(LiteralPath\s+|Path\s+)?[''"]?env:'
        $source | Should -Not -Match '(?i)\$env:\w*\s*\|'
    }
}

Describe 'The bundle command the failure notices print' {
    BeforeEach {
        $script:hintLines = @()
        Mock Write-Info { $script:hintLines += "INFO: $Message" }
        Mock Write-WarningMessage { $script:hintLines += "WARN: $Message" }
    }

    It 'Is one PowerShell command that downloads the installer from main and runs it with -CollectDiagnostics' {
        $command = Get-DiagnosticsCommandLine
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$errors)

        @($errors).Count | Should -Be 0
        $command | Should -BeExactly '& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics'
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandParameterAst] -and $node.ParameterName -eq 'CollectDiagnostics' }, $true)).Count | Should -Be 1
    }

    It 'Is printed with where to report the failure and the privacy note' {
        Write-InstallerReportHint

        $script:hintLines | Should -Contain ('INFO:     ' + (Get-DiagnosticsCommandLine))
        ($script:hintLines -join "`n") | Should -Match ([regex]::Escape('https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml'))
        ($script:hintLines -join "`n") | Should -Match 'WARN: That repository is public'
    }

    It 'Is in the notice of a run that stops early' {
        Mock Write-ErrorMessage { }
        Mock Write-Host { }

        Write-InstallerExitNotice -Code 2 -NoPause

        $script:hintLines | Should -Contain ('INFO:     ' + (Get-DiagnosticsCommandLine))
    }

    It 'Runs the installer the readme documents, from the URL of its one-liner' {
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'readme.md')
        (Get-DiagnosticsCommandLine) -match 'irm "(?<url>[^"]+)"' | Should -BeTrue
        $readme | Should -Match ([regex]::Escape('irm "' + $Matches['url'] + '" | iex'))
    }
}

Describe 'The install-failure issue form asks for the bundle (wgt-gq8.35)' {
    BeforeAll {
        $script:formText = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/install-failure.yml')
    }

    It 'Has a required <Id> field' -ForEach @(
        @{ Id = 'diagnostics' }
        @{ Id = 'build-id' }
        @{ Id = 'elevation' }
        @{ Id = 'windows-build' }
    ) {
        $field = [regex]::Match($script:formText, ('(?ms)^\s+id: {0}\s*$(?<body>.*?)(?=^\s+- type:|\z)' -f [regex]::Escape($Id)))
        $field.Success | Should -BeTrue
        $field.Groups['body'].Value | Should -Match '(?m)^\s+required: true\s*$'
    }

    It 'Offers the elevation styles: same-user, cross-user and SYSTEM' {
        $elevation = [regex]::Match($script:formText, '(?ms)^\s+id: elevation\s*$(?<body>.*?)(?=^\s+- type:|\z)').Groups['body'].Value
        $elevation | Should -Match '- Same-user'
        $elevation | Should -Match '- Cross-user'
        $elevation | Should -Match '- SYSTEM'
    }

    It 'Keeps its earlier fields' -ForEach @('exit-code', 'build-id', 'target', 'start', 'windows', 'what-happened', 'log', 'privacy') {
        $script:formText | Should -Match ('(?m)^\s+id: {0}\s*$' -f [regex]::Escape($_))
    }

    It 'Shows the same bundle command the installer prints' {
        $script:formText | Should -Match ([regex]::Escape((Get-DiagnosticsCommandLine)))
    }

    It 'Quotes every plain value that holds '': '', which YAML would read as a nested key' {
        # GitHub rejects an issue form that is not valid YAML and shows no form at all. A plain
        # (unquoted) scalar cannot contain ': ' or ' #'.
        $offending = @()
        foreach ($line in ($script:formText -split '\r?\n')) {
            if ($line -match '^\s*(?:-\s+)?[\w-]+:\s+(?<value>[^\s''"|>].*)$') {
                $value = $Matches['value']
                if ($value -match ': ' -or $value -match ' #') {
                    $offending += $line.Trim()
                }
            }
        }
        $offending | Should -BeNullOrEmpty
    }
}
