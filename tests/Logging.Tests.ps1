# Logging.Tests.ps1
# Tests for WingetAppSetup/Public/Logging.ps1 and Private/LoggingInternal.ps1:
# colored output helpers, Format-AppList, Write-Table, Write-Prompt.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Write-Table' {
    BeforeAll {
        Mock Write-Host { }
    }

    It 'Should format table data correctly with Format-Table' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host at least once with formatted table output
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match 'Status' -or $Object -match 'Apps' }
    }

    It 'Renders a long cell in full, whatever the console width (review finding P3-13)' {
        # The failed-apps table is what a teammate pastes into a GitHub issue. Rendered at the
        # console width, a transcript or captured output (120 columns) cut it off with an ellipsis,
        # and a process with no console got an empty table.
        $longReason = ('x' * 300) + 'END'
        $script:renderedTable = $null
        Mock Write-Host { $script:renderedTable = [string]$Object }

        Write-Table -Headers @('App', 'Reason') -Rows @(, @('Contoso.App', $longReason))

        $script:renderedTable | Should -Match 'Reason'
        @($script:renderedTable -split "`r?`n") | Should -Contain ('Contoso.App ' + $longReason)
    }

    It 'Should handle multiple rows correctly' {
        $headers = @('Status', 'Apps')
        $rows = @(
            @('Installed', 'App1, App2'),
            @('Skipped', 'App3'),
            @('Failed', 'App4')
        )

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host with the formatted output
        Should -Invoke Write-Host -Times 1
    }
}

Describe 'Format-AppList' {
    BeforeAll {
    }

    It 'Should format non-empty array' {
        $result = Format-AppList -AppArray @('App1', 'App2', 'App3')
        $result | Should -Be 'App1, App2, App3'
    }

    It 'Should return null for empty array' {
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }

    It 'Should return null for empty input' {
        # The real Format-AppList declares $AppArray as a mandatory [string[]] with
        # [AllowEmptyCollection()], so an empty array (not $null) is the boundary case
        # it is designed to handle; it returns $null when given no apps.
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }
}

Describe 'Write-Info' {
    BeforeAll {
    }

    It 'Should write message in blue color' {
        Mock Write-Host { }

        Write-Info 'Test message'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Test message' -and $ForegroundColor -eq 'Blue'
        }
    }
}

Describe 'Write-Success' {
    BeforeAll {
    }

    It 'Should write message in green color' {
        Mock Write-Host { }

        Write-Success 'Success message'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Success message' -and $ForegroundColor -eq 'Green'
        }
    }
}

Describe 'Write-WarningMessage' {
    BeforeAll {
    }

    It 'Should write message in yellow color' {
        Mock Write-Host { }

        Write-WarningMessage 'Warning message'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Warning message' -and $ForegroundColor -eq 'Yellow'
        }
    }
}

Describe 'Write-ErrorMessage' {
    BeforeAll {
    }

    It 'Should write message in red color' {
        Mock Write-Host { }

        Write-ErrorMessage 'Error message'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Error message' -and $ForegroundColor -eq 'Red'
        }
    }
}

Describe 'Write-Prompt' {
    BeforeAll {
    }

    It 'Should write message in blue color' {
        Mock Write-Host { }

        Write-Prompt 'Press any key to continue...'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Press any key to continue...' -and $ForegroundColor -eq 'Blue'
        }
    }
}

Describe 'Start-InstallerTranscript (issue #189, review findings P2-13 and P3-14, wgt-gq8.46)' {
    BeforeEach {
        $script:savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
        $script:logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
        Mock Start-Transcript { }
        Mock Test-IsAdmin { $true }
        Mock Write-WarningMessage { }
    }

    AfterEach {
        $env:ProgramData = $script:savedProgramData
    }

    Context 'With the log folder''s checks stood in for' {
        BeforeEach {
            Mock Initialize-ProgramDataFolder { [void](New-Item -ItemType Directory -Path $script:logDirectory -Force); $script:logDirectory }
        }

        It 'Creates the log folder under ProgramData and starts install-<timestamp>.log there' {
            $script:transcriptPath = Start-InstallerTranscript

            Test-Path -LiteralPath $script:logDirectory | Should -BeTrue
            $script:transcriptPath | Should -Match ('^' + [regex]::Escape($script:logDirectory) + '[\\/]install-\d{8}-\d{6}\.log$')
            Should -Invoke Start-Transcript -Times 1 -Exactly -ParameterFilter { $Path -eq $script:transcriptPath }
        }

        It 'Names the files of a dry run, the 5.1 bootstrap and a bootstrapped dry run apart' {
            Start-InstallerTranscript -WhatIf | Should -Match 'install-\d{8}-\d{6}-whatif\.log$'
            Start-InstallerTranscript -Bootstrap | Should -Match 'install-\d{8}-\d{6}-bootstrap\.log$'
            Start-InstallerTranscript -Bootstrap -WhatIf | Should -Match 'install-\d{8}-\d{6}-bootstrap-whatif\.log$'
        }

        # wgt-gq8.58: a logs folder a standard user created is locked in place, so a file that user
        # left under the transcript's name stays theirs. A hard link stands for it.
        It 'Starts the transcript in a new file of its own, never in an entry left at its name' {
            Mock Get-Date { [datetime]::new(2026, 10, 12, 10, 15, 0) }
            [void](New-Item -ItemType Directory -Path $script:logDirectory -Force)
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N') + '.txt')
            Set-Content -LiteralPath $outside -Value 'not the installer''s' -NoNewline
            [void](New-Item -ItemType HardLink -Path (Join-Path $script:logDirectory 'install-20261012-101500-bootstrap.log') -Target $outside)

            $path = Start-InstallerTranscript -Bootstrap

            $path | Should -Be (Join-Path $script:logDirectory 'install-20261012-101500-2-bootstrap.log')
            (Get-Item -LiteralPath $path).Length | Should -Be 0
            Get-Content -Raw -LiteralPath $outside | Should -Be 'not the installer''s'
            Should -Invoke Start-Transcript -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
        }

        It 'Removes the file it created for the transcript when the transcript cannot start' {
            Mock Start-Transcript { throw 'Access to the path is denied.' }

            Start-InstallerTranscript | Should -BeNullOrEmpty

            @(Get-ChildItem -LiteralPath $script:logDirectory -Force) | Should -BeNullOrEmpty
        }

        # wgt-gq8.59: the warning about a removed link is printed before the transcript starts.
        It 'Repeats a warning about a link removed from the log folder once the transcript has started' {
            $script:events = [System.Collections.Generic.List[string]]::new()
            Mock Initialize-ProgramDataFolder {
                [void](New-Item -ItemType Directory -Path $script:logDirectory -Force)
                $LinkWarning.Add("'X' was a link (a junction or symbolic link), not a folder.")
                $script:logDirectory
            }
            Mock Start-Transcript { $script:events.Add('transcript') }
            Mock Write-WarningMessage { $script:events.Add($Message) }

            [void](Start-InstallerTranscript)

            @($script:events) | Should -Be @('transcript', "Before this log started: 'X' was a link (a junction or symbolic link), not a folder.")
        }

        It 'Repeats nothing when no link was removed' {
            [void](Start-InstallerTranscript)

            Should -Invoke Write-WarningMessage -Times 0 -Exactly
        }

        It 'Makes the log folder safe, readable for standard users, before an elevated run starts the transcript in it' {
            Start-InstallerTranscript | Out-Null

            Should -Invoke Initialize-ProgramDataFolder -Times 1 -Exactly -ParameterFilter { $ChildName -eq 'logs' -and $ReadableByUsers }
        }

        It 'Leaves the access list alone in a run that is not elevated, which writes with its own rights only' {
            Mock Test-IsAdmin { $false }

            $path = Start-InstallerTranscript

            Split-Path -Parent $path | Should -Be $script:logDirectory
            Test-Path -LiteralPath $script:logDirectory -PathType Container | Should -BeTrue
            Should -Invoke Initialize-ProgramDataFolder -Times 0 -Exactly
        }

        # Work-order item 34: the user phase runs as a standard user, who cannot write to the machine's
        # logs folder, so it logs to its own %LOCALAPPDATA% and leaves the access list alone.
        It 'Logs the user phase to the user''s own LOCALAPPDATA, as an install-(time)-userphase.log, without changing any access list' {
            $savedLocalAppData = $env:LOCALAPPDATA
            try {
                $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
                $userLogDirectory = Join-Path $env:LOCALAPPDATA 'winget-app-setup\logs'

                $script:userTranscriptPath = Start-InstallerTranscript -UserPhase

                $script:userTranscriptPath | Should -Match ('^' + [regex]::Escape($userLogDirectory) + '[\\/]install-\d{8}-\d{6}-userphase\.log$')
                Test-Path -LiteralPath $userLogDirectory | Should -BeTrue
                Should -Invoke Start-Transcript -Times 1 -Exactly -ParameterFilter { $Path -eq $script:userTranscriptPath }
                Should -Invoke Initialize-ProgramDataFolder -Times 0 -Exactly
            }
            finally {
                $env:LOCALAPPDATA = $savedLocalAppData
            }
        }

        It 'Warns and returns $null instead of failing the run when the transcript cannot start' {
            Mock Start-Transcript { throw 'Access to the path is denied.' }

            Start-InstallerTranscript | Should -BeNullOrEmpty

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Transcript logging could not be started: Access to the path is denied' -and $Message -notmatch 'start over' }
        }

        It 'Starts no transcript when the log folder cannot be made safe, and says how to replace a folder whose access list could not be set without following a link' {
            Mock Initialize-ProgramDataFolder {
                throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("'C:\ProgramData\winget-app-setup\logs' is not limited to SYSTEM and Administrators: PC01\enduser (S-1-5-21-1-2-3-1001) has an access entry (allow)."), 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, 'C:\ProgramData\winget-app-setup\logs')
            }

            Start-InstallerTranscript | Should -BeNullOrEmpty

            Should -Invoke Start-Transcript -Times 0 -Exactly
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter {
                $Message -like "Transcript logging could not be started: 'C:\ProgramData\winget-app-setup\logs' is not limited to SYSTEM and Administrators*Continuing without a log file. To start over with a new folder, rename this one in an elevated prompt: ren `"C:\ProgramData\winget-app-setup\logs`" logs-old-*, then re-run this installer." -and $Message -notlike '*takeown*'
            }
        }
    }

    Context 'With real links and the real folder checks (wgt-gq8.46)' {
        # wgt-gq8.46: an elevated or SYSTEM run would otherwise write its transcript, last-run.json and
        # the installer logs into whatever a link planted as the logs folder points to. Real links here
        # (a junction on Windows, a symbolic link elsewhere); only icacls and the locked creation of the
        # base folder are stood in for.
        It 'Never starts the transcript inside a link planted as the logs folder, and leaves its target alone' {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            [void](New-Item -ItemType Directory -Path $baseDir -Force)
            $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $victim)
            Set-Content -LiteralPath (Join-Path $victim 'keep.txt') -Value 'not the installer''s'
            $linkType = 'SymbolicLink'
            if ($IsWindows) {
                $linkType = 'Junction'
            }
            [void](New-Item -ItemType $linkType -Path $script:logDirectory -Target $victim)
            Mock Set-RestrictedDirectoryAcl { }
            Mock New-RestrictedDirectory { [void](New-Item -ItemType Directory -Path $Path) }

            $path = Start-InstallerTranscript

            $directory = Split-Path -Parent $path
            $directory | Should -Be $script:logDirectory
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
            @(Get-ChildItem -LiteralPath $victim -Force | ForEach-Object { $_.Name }) | Should -Be @('keep.txt')
            Should -Invoke Start-Transcript -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
            # Printed once before the transcript started and once in it (wgt-gq8.59).
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -like "'$($script:logDirectory)' was a link*" }
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -like "Before this log started: '$($script:logDirectory)' was a link*" }
        }

        It 'Starts no transcript when a link planted as the logs folder cannot be removed' {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            [void](New-Item -ItemType Directory -Path $baseDir -Force)
            $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $victim)
            $linkType = 'SymbolicLink'
            if ($IsWindows) {
                $linkType = 'Junction'
            }
            [void](New-Item -ItemType $linkType -Path $script:logDirectory -Target $victim)
            Mock Set-RestrictedDirectoryAcl { }
            Mock Remove-FileSystemLink { throw 'Access is denied.' }

            Start-InstallerTranscript | Should -BeNullOrEmpty

            Should -Invoke Start-Transcript -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $victim -Force) | Should -BeNullOrEmpty
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -like "Transcript logging could not be started: '$($script:logDirectory)' is a link*Continuing without a log file." }
        }
    }
}
