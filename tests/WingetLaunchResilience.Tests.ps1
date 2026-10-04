# Tests for WingetAppSetup/Private/WingetLaunchResilience.ps1 (issues #258, #277, review findings
# P2-8, P3-7, P3-9): classification of transient winget-launch failures, the winget executable to
# launch, and the bounded `winget --version` launch check (Test-WingetLaunchable) that
# Test-AndInstallWinget, the circuit breaker and the end-of-run check use.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-TransientWingetLaunchError' {
    It 'Classifies ERROR_CANT_ACCESS_FILE as transient' {
        Test-TransientWingetLaunchError -Message 'This command cannot be run due to the error: The file cannot be accessed by the system.' |
            Should -Be $true
    }

    It 'Classifies ERROR_SHARING_VIOLATION as transient' {
        Test-TransientWingetLaunchError -Message 'The process cannot access the file because it is being used by another process.' |
            Should -Be $true
    }

    It 'Matches case-insensitively' {
        Test-TransientWingetLaunchError -Message 'THE FILE CANNOT BE ACCESSED BY THE SYSTEM.' |
            Should -Be $true
    }

    It 'Does not classify an unrelated launch failure as transient' {
        Test-TransientWingetLaunchError -Message 'The system cannot find the file specified.' |
            Should -Be $false
    }

    It 'Handles a null or empty message without throwing' {
        Test-TransientWingetLaunchError -Message $null | Should -Be $false
        Test-TransientWingetLaunchError -Message '' | Should -Be $false
    }

    It 'Classifies the native-command-invocation StandardOutputEncoding symptom as transient (issue #277)' {
        Test-TransientWingetLaunchError -Message 'StandardOutputEncoding is only supported when standard output is redirected.' |
            Should -Be $true
    }

    Context 'In any display language (review finding P3-6)' {
        It 'Classifies Win32 error <Code> as transient by its code, whatever the message says' -ForEach @(
            @{ Code = 32 }
            @{ Code = 1920 }
        ) {
            Test-TransientWingetLaunchError -NativeErrorCode $Code -Message 'Das System kann auf die Datei nicht zugreifen.' | Should -Be $true
            Test-TransientWingetLaunchError -NativeErrorCode $Code | Should -Be $true
        }

        It 'Does not classify Win32 error <Code> as transient' -ForEach @(
            @{ Code = 2 }
            @{ Code = 5 }
        ) {
            Test-TransientWingetLaunchError -NativeErrorCode $Code -Message 'Le fichier specifie est introuvable.' | Should -Be $false
        }

        It 'Matches a Start-Process message in the machine''s own language when no code is known' {
            # What Windows returns for these codes on a German display language.
            Mock Get-Win32ErrorMessage {
                switch ($Code) {
                    32 { 'Der Prozess kann nicht auf die Datei zugreifen, da sie von einem anderen Prozess verwendet wird.' }
                    1920 { 'Das System kann auf die Datei nicht zugreifen.' }
                }
            }

            Test-TransientWingetLaunchError -Message 'This command cannot be run due to the error: Das System kann auf die Datei nicht zugreifen.' | Should -Be $true
            Test-TransientWingetLaunchError -Message 'This command cannot be run due to the error: Der Prozess kann nicht auf die Datei zugreifen, da sie von einem anderen Prozess verwendet wird.' | Should -Be $true
            Test-TransientWingetLaunchError -Message 'This command cannot be run due to the error: Das System kann die angegebene Datei nicht finden.' | Should -Be $false
        }

        It 'Reads the Windows message for a code, and returns none off Windows, where the runtime words codes as errno values' {
            if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
                Get-Win32ErrorMessage -Code 1920 | Should -Be ([System.ComponentModel.Win32Exception]::new(1920).Message)
            }
            else {
                Get-Win32ErrorMessage -Code 1920 | Should -Be $null
            }
        }
    }
}

Describe 'Resolve-WingetExecutable' {
    It 'Returns the bare command name, resolved on PATH, and never queries the package database (review finding P3-7)' {
        Mock Get-AppxPackage { throw 'must not be called' }

        Resolve-WingetExecutable | Should -Be 'winget'

        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }
}

Describe 'Test-WingetLaunchable (review findings P2-8, P3-9)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Start-Sleep { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
    }

    It 'Is launchable when winget --version exits 0 and prints a version' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('v1.12.350') }

        $result = Test-WingetLaunchable

        $result.Launchable | Should -BeTrue
        $result.Version | Should -Be 'v1.12.350'
        $result.Reason | Should -BeNullOrEmpty
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq '--version' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetVersion) -and $Echo -eq 'None'
        }
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Is not launchable when winget exits 0 without printing a version' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('Windows Package Manager') }

        $result = Test-WingetLaunchable

        $result.Launchable | Should -BeFalse
        $result.Reason | Should -Be "'winget --version' printed no version"
    }

    It 'Is not launchable when winget starts but exits non-zero, and names the code' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335230 -Output @('Some error text') }

        $result = Test-WingetLaunchable

        $result.Launchable | Should -BeFalse
        $result.Reason | Should -Be "'winget --version' exited with 0x8A150002 INVALID_CL_ARGUMENTS"
    }

    It 'Is not launchable when winget --version does not answer in time' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }

        (Test-WingetLaunchable).Reason | Should -Match 'did not answer within 30 seconds'
    }

    It 'Stops at once on a launch failure that waiting does not change (<Case>), whatever -Attempts says' -ForEach @(
        @{ Case = 'not on PATH'; Code = 2; Message = "'winget' was not found on PATH." }
        @{ Case = 'access denied'; Code = 5; Message = 'Access is denied.' }
    ) {
        $script:launchCode = $Code
        $script:launchMessage = $Message
        Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage }

        $result = Test-WingetLaunchable -Attempts 5 -RetryDelaySeconds 15

        $result.Launchable | Should -BeFalse
        $result.Reason | Should -Be ('winget could not be started: {0}' -f $Message.TrimEnd('.'))
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Checks again after RetryDelaySeconds when the launch failure can clear on its own, and passes once it does' {
        $script:calls = 0
        Mock Invoke-WingetProcess {
            $script:calls++
            if ($script:calls -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            New-TestProcessResult -ExitCode 0 -Output @('v1.12.350')
        }

        $result = Test-WingetLaunchable -Attempts 3 -RetryDelaySeconds 7

        $result.Launchable | Should -BeTrue
        $result.Attempts | Should -Be 2
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
        ($script:warnings -join "`n") | Should -Match 'Checking again in 7s \(check 2 of 3\)'
    }

    It 'Gives up after -Attempts checks that keep failing, sleeping only between them' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 }

        $result = Test-WingetLaunchable -Attempts 3 -RetryDelaySeconds 15

        $result.Launchable | Should -BeFalse
        $result.Attempts | Should -Be 3
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 15 }
    }

    It 'Writes what winget printed when the last check failed, so the transcript says why' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 -Output @('No applicable app licenses found.') }
        Mock Write-ProcessOutput { }

        [void](Test-WingetLaunchable)

        Should -Invoke Write-ProcessOutput -Times 1 -Exactly -ParameterFilter { $Line -contains 'No applicable app licenses found.' }
    }

    Context 'With a real process (the Invoke-WingetProcess seam)' {
        BeforeEach {
            $script:fakeDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:fakeDirectory
        }

        It 'Passes a winget that prints its version and exits 0' {
            $script:fakeWinget = New-FakeExecutable -Directory $script:fakeDirectory -Name 'fake-winget' -StandardOutput @('v1.12.350')
            Mock Resolve-WingetExecutable { $script:fakeWinget }

            $result = Test-WingetLaunchable

            $result.Launchable | Should -BeTrue
            $result.Version | Should -Be 'v1.12.350'
        }

        It 'Fails a winget that starts but exits non-zero' {
            $script:fakeWinget = New-FakeExecutable -Directory $script:fakeDirectory -Name 'fake-winget-broken' -StandardError @('No applicable app licenses found.') -ExitCode 3
            Mock Resolve-WingetExecutable { $script:fakeWinget }

            $result = Test-WingetLaunchable

            $result.Launchable | Should -BeFalse
            $result.Reason | Should -Be "'winget --version' exited with 0x00000003"
        }

        It 'Fails a winget that cannot be started, without retrying' {
            Mock Resolve-WingetExecutable { Join-Path $script:fakeDirectory 'missing-winget.exe' }

            $result = Test-WingetLaunchable -Attempts 3

            $result.Launchable | Should -BeFalse
            $result.Reason | Should -Match '^winget could not be started: '
            $result.Attempts | Should -Be 1
        }
    }
}
