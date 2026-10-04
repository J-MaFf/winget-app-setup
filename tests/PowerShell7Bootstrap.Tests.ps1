# PowerShell7Bootstrap.Tests.ps1
# Unit tests for the Windows PowerShell 5.1 bootstrap (issue #225): Find-PowerShell7 discovery
# order and Invoke-PowerShell7Bootstrap's find/consent/install/fallback/relaunch paths. All
# externals are mocked; the real-execution 5.1 integration tests live in EntryPoint.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-PowerShell7Executable' {
    BeforeDiscovery {
        $script:realPwshAvailable = [bool](Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
        $script:realWinPowerShellAvailable = [bool](Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
    }

    It 'Returns $false for a path that does not exist or cannot launch' {
        Test-PowerShell7Executable -Path 'C:\__no_such_dir__\pwsh.exe' | Should -Be $false
    }

    It 'Accepts a real PowerShell 7 executable' -Skip:(-not $script:realPwshAvailable) {
        $realPwsh = (Get-Command -Name 'pwsh.exe' -CommandType Application | Select-Object -First 1).Source

        Test-PowerShell7Executable -Path $realPwsh | Should -Be $true
    }

    It 'Rejects a real pre-7 engine (powershell.exe reports major version 5)' -Skip:(-not $script:realWinPowerShellAvailable) {
        # The exact defect this validation exists for: an engine that launches fine but is < 7
        # must not be treated as a relaunch target, or the version dispatch would loop.
        $winPowerShell = (Get-Command -Name 'powershell.exe' -CommandType Application | Select-Object -First 1).Source

        Test-PowerShell7Executable -Path $winPowerShell | Should -Be $false
    }
}

Describe 'Find-PowerShell7' {
    BeforeEach {
        # Candidates are validated by execution in production; stub the validator so these
        # discovery-order tests stay hermetic. Validation behavior has its own tests above/below.
        Mock Test-PowerShell7Executable { $true }
    }

    Context 'pwsh.exe resolves on PATH' {
        BeforeEach {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
        }

        It 'Returns the Get-Command source' {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\somewhere\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }

            Find-PowerShell7 | Should -Be 'C:\somewhere\pwsh.exe'
        }

        It 'Returns the first hit when PATH resolves multiple pwsh entries' {
            Mock Get-Command {
                @(
                    [pscustomobject]@{ Source = 'C:\first\pwsh.exe' },
                    [pscustomobject]@{ Source = 'C:\second\pwsh.exe' }
                )
            } -ParameterFilter { $Name -eq 'pwsh.exe' }

            Find-PowerShell7 | Should -Be 'C:\first\pwsh.exe'
        }
    }

    Context 'pwsh.exe not on PATH (stale PATH, 32-bit host, or MSIX install)' {
        BeforeEach {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }
            # Pin the candidate roots so assertions are deterministic on any host. TestDrive roots,
            # not 'C:\...' literals: Join-Path checks the drive exists, so off Windows a C: root
            # turned every candidate and every expected path into $null and these tests passed
            # without checking anything (Test-Path is mocked, so nothing touches the disk).
            $script:savedProgramFiles = $env:ProgramFiles
            $script:savedProgramW6432 = $env:ProgramW6432
            $script:savedLocalAppData = $env:LOCALAPPDATA
            $script:testProgramFiles = Join-Path $TestDrive 'TestProgramFiles'
            $script:testProgramW6432 = Join-Path $TestDrive 'TestProgramW6432'
            $script:testLocalAppData = Join-Path $TestDrive 'TestLocalAppData'
            $env:ProgramFiles = $script:testProgramFiles
            $env:ProgramW6432 = $script:testProgramW6432
            $env:LOCALAPPDATA = $script:testLocalAppData
        }
        AfterEach {
            $env:ProgramFiles = $script:savedProgramFiles
            $env:ProgramW6432 = $script:savedProgramW6432
            $env:LOCALAPPDATA = $script:savedLocalAppData
        }

        It 'Falls back to the Program Files install location' {
            Mock Test-Path { $LiteralPath -like "$script:testProgramFiles*" } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testProgramFiles 'PowerShell\7\pwsh.exe')
        }

        It 'Probes the 64-bit Program Files from a 32-bit host (ProgramW6432)' {
            Mock Test-Path { $LiteralPath -like "$script:testProgramW6432*" } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testProgramW6432 'PowerShell\7\pwsh.exe')
        }

        It 'Probes the WindowsApps execution alias (MSIX install on Windows 11 24H2+)' {
            Mock Test-Path { $LiteralPath -like "$script:testLocalAppData*" } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testLocalAppData 'Microsoft\WindowsApps\pwsh.exe')
        }

        It 'Prefers the Program Files install over the WindowsApps alias when both exist' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testProgramFiles 'PowerShell\7\pwsh.exe')
        }

        It 'Returns $null when no candidate exists' {
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }

        It 'Skips a candidate that exists but fails validation (pre-7 engine or broken alias)' {
            # PATH-less; ProgramFiles and WindowsApps candidates both exist on disk, but the
            # ProgramFiles one fails the execution probe - the WindowsApps one must win.
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
            Mock Test-PowerShell7Executable { $Path -like "$script:testLocalAppData*" }

            Find-PowerShell7 | Should -Be (Join-Path $script:testLocalAppData 'Microsoft\WindowsApps\pwsh.exe')
        }

        It 'Returns $null when every existing candidate fails validation' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
            Mock Test-PowerShell7Executable { $false }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }

        It 'Skips candidates whose environment root is unset' {
            $env:ProgramFiles = ''
            $env:ProgramW6432 = ''
            $env:LOCALAPPDATA = ''
            # Even an always-true Test-Path cannot produce a hit with no candidates to probe.
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-GitHubRateLimitError' {
    It 'Matches the literal text GitHub returns for a throttled raw.githubusercontent.com request' {
        Test-GitHubRateLimitError -ErrorRecord '429: Too Many Requests' | Should -Be $true
    }

    It 'Matches the WebException phrasing PowerShell formats for a 429 response' {
        Test-GitHubRateLimitError -ErrorRecord 'The remote server returned an error: (429) Too Many Requests.' | Should -Be $true
    }

    It 'Does not match an unrelated network failure' {
        Test-GitHubRateLimitError -ErrorRecord 'network unreachable' | Should -Be $false
    }
}

Describe 'Get-PowerShell7MsiInfo' {
    BeforeEach {
        Mock Write-WarningMessage { }
        Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.6.4' } }
        $script:savedArchitecture = $env:PROCESSOR_ARCHITECTURE
        $script:savedArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_ARCHITEW6432 = ''
        # Isolate from any other test/call that set this (issue #274) - only the throttle test
        # below should ever see it $true.
        $script:PowerShell7BootstrapGitHubThrottled = $false
    }
    AfterEach {
        $env:PROCESSOR_ARCHITECTURE = $script:savedArchitecture
        $env:PROCESSOR_ARCHITEW6432 = $script:savedArchitectureW6432
    }

    It 'Builds the x64 MSI url from the release metadata' {
        $info = Get-PowerShell7MsiInfo

        $info.Version | Should -Be '7.6.4'
        $info.FileName | Should -Be 'PowerShell-7.6.4-win-x64.msi'
        $info.Url | Should -Be 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.4/PowerShell-7.6.4-win-x64.msi'
    }

    It 'Bounds the metadata request with a timeout' {
        # The whole point of issue #263: no request on this path may be able to block forever.
        Get-PowerShell7MsiInfo | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $TimeoutSec -gt 0
        }
    }

    It 'Honors a custom MetadataUrl' {
        Get-PowerShell7MsiInfo -MetadataUrl 'https://example.test/metadata.json' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://example.test/metadata.json' }
    }

    It 'Resolves arm64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'

        (Get-PowerShell7MsiInfo).FileName | Should -Be 'PowerShell-7.6.4-win-arm64.msi'
    }

    It 'Prefers PROCESSOR_ARCHITEW6432 so a 32-bit host does not pick the x86 MSI' {
        # A 32-bit host process (some RMM agents) reports x86 on a 64-bit OS - the same stale-view
        # problem Find-PowerShell7 handles with ProgramW6432.
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'

        (Get-PowerShell7MsiInfo).FileName | Should -Be 'PowerShell-7.6.4-win-x64.msi'
    }

    It 'Uses the x86 MSI on a genuinely 32-bit OS' {
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        $env:PROCESSOR_ARCHITEW6432 = ''

        (Get-PowerShell7MsiInfo).FileName | Should -Be 'PowerShell-7.6.4-win-x86.msi'
    }

    It 'Returns $null for an unrecognized architecture without calling the network' {
        $env:PROCESSOR_ARCHITECTURE = 'IA64'

        Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'Returns $null when the metadata request fails' {
        Mock Invoke-RestMethod { throw 'network unreachable' }

        Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
    }

    It 'Flags a 429 metadata failure for the top-level bootstrap to explain (issue #274)' {
        Mock Invoke-RestMethod { throw '429: Too Many Requests' }

        Get-PowerShell7MsiInfo | Out-Null

        $script:PowerShell7BootstrapGitHubThrottled | Should -Be $true
    }

    It 'Does not flag an unrelated metadata failure' {
        Mock Invoke-RestMethod { throw 'network unreachable' }

        Get-PowerShell7MsiInfo | Out-Null

        $script:PowerShell7BootstrapGitHubThrottled | Should -Be $false
    }

    It 'Returns $null when the metadata carries no ReleaseTag' {
        Mock Invoke-RestMethod { [pscustomobject]@{ PreviewReleaseTag = 'v7.7.0-preview.1' } }

        Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
    }
}

Describe 'Save-WebFileWithTimeout' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
    }

    It 'Returns $false instead of throwing when the request cannot even be created' {
        Save-WebFileWithTimeout -Uri 'not-a-url' -DestinationPath (Join-Path $TestDrive 'out.bin') | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'download failed' }
    }

    It 'Returns $false when the host cannot be resolved' {
        # Bounded by the request timeout rather than hanging - the defect issue #263 exists for.
        Save-WebFileWithTimeout -Uri 'https://no-such-host.invalid/file.msi' -DestinationPath (Join-Path $TestDrive 'out.bin') -StallTimeoutSeconds 5 -MaximumSeconds 15 |
            Should -Be $false
    }
}

Describe 'Install-PowerShell7FromMsi' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock New-Item { }
        Mock Remove-Item { }
        Mock Get-PowerShell7MsiInfo {
            @{
                Version  = '7.6.4'
                FileName = 'PowerShell-7.6.4-win-x64.msi'
                Url      = 'https://example.test/PowerShell-7.6.4-win-x64.msi'
            }
        }
        Mock Save-WebFileWithTimeout { $true }

        # msiexec stand-in. Start-Process -PassThru returns a real Process, so the double needs the
        # two members production reads (WaitForExit/ExitCode) plus Kill for the timeout path.
        $script:msiExited = $true
        $script:msiExitCode = 0
        $script:msiKilled = $false
        $script:msiProcess = [pscustomobject]@{}
        $script:msiProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { $script:msiExitCode }
        $script:msiProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $script:msiExited }
        $script:msiProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:msiKilled = $true }
        Mock Start-Process { $script:msiProcess } -ParameterFilter { $FilePath -eq 'msiexec.exe' }
    }

    It 'Downloads the resolved MSI and installs it quietly' {
        Install-PowerShell7FromMsi | Should -Be $true

        Should -Invoke Save-WebFileWithTimeout -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://example.test/PowerShell-7.6.4-win-x64.msi' -and
            $DestinationPath -like '*winget-app-setup-pwsh-*PowerShell-7.6.4-win-x64.msi'
        }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'msiexec.exe' -and
            $ArgumentList -contains '/i' -and
            $ArgumentList -contains '/quiet' -and
            $ArgumentList -contains '/norestart'
        }
    }

    It 'Downloads into a unique per-run directory, then removes it' {
        Install-PowerShell7FromMsi | Out-Null

        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*winget-app-setup-pwsh-*' }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-pwsh-*' }
    }

    It 'Treats msiexec 3010 (reboot required) as success' {
        # pwsh.exe is on disk and launchable at that point; the relaunch does not need the reboot.
        $script:msiExitCode = 3010

        Install-PowerShell7FromMsi | Should -Be $true
    }

    It 'Returns $false on a nonzero msiexec exit code' {
        $script:msiExitCode = 1603

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'exit code 1603' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
    }

    Context 'Another installation in progress: msiexec 1618 (review finding P2-13)' {
        BeforeEach {
            Mock Start-Sleep { }
        }

        It 'Waits and retries while Windows Installer is busy, then succeeds' {
            # msiexec returns 1618 at once when another installation holds Windows Installer, as on
            # a freshly enrolled machine whose agents are still installing. One busy moment used to
            # fail the bootstrap outright.
            $script:msiExitCodes = [System.Collections.Generic.Queue[int]]::new([int[]]@(1618, 1618, 0))
            $script:msiProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Force -Value { $script:msiExitCodes.Dequeue() }

            Install-PowerShell7FromMsi -BusyRetryCount 6 -BusyRetryDelaySeconds 30 | Should -Be $true

            Should -Invoke Start-Process -Times 3 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 30 }
            Should -Invoke Write-WarningMessage -Times 2 -Exactly -ParameterFilter { $Message -match 'busy with another installation \(msiexec exit code 1618\)' }
        }

        It 'Gives up after the retry budget and says why' {
            $script:msiExitCode = 1618

            Install-PowerShell7FromMsi -BusyRetryCount 2 -BusyRetryDelaySeconds 1 | Should -Be $false

            Should -Invoke Start-Process -Times 3 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'still busy with another installation after 2 retries' }
        }

        It 'Does not retry any other failure' {
            $script:msiExitCode = 1603

            Install-PowerShell7FromMsi | Should -Be $false

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    Context 'msiexec log (review finding P2-13)' {
        It 'Writes a verbose msiexec log, one file per attempt, into the given folder' {
            Mock Start-Sleep { }
            $logDirectory = Join-Path $TestDrive 'logs'
            $script:msiExitCodes = [System.Collections.Generic.Queue[int]]::new([int[]]@(1618, 0))
            $script:msiProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Force -Value { $script:msiExitCodes.Dequeue() }
            $script:msiLogArguments = @()
            Mock Start-Process {
                $logIndex = [array]::IndexOf([string[]]$ArgumentList, '/l*v')
                $script:msiLogArguments += $(if ($logIndex -ge 0) { $ArgumentList[$logIndex + 1] } else { '<none>' })
                $script:msiProcess
            } -ParameterFilter { $FilePath -eq 'msiexec.exe' }

            Install-PowerShell7FromMsi -MsiLogDirectory $logDirectory | Should -Be $true

            $script:msiLogArguments.Count | Should -Be 2
            $script:msiLogArguments[0] | Should -BeLike ('"' + (Join-Path $logDirectory 'pwsh-msi-*-1.log') + '"')
            $script:msiLogArguments[1] | Should -BeLike ('"' + (Join-Path $logDirectory 'pwsh-msi-*-2.log') + '"')
        }

        It 'Names the log of a failed attempt' {
            $script:msiExitCode = 1603

            Install-PowerShell7FromMsi -MsiLogDirectory (Join-Path $TestDrive 'logs') | Should -Be $false

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'log of the failed attempt: .*pwsh-msi-.*-1\.log' }
        }

        It 'Asks msiexec for no log without a folder (it fails the install when it cannot write one)' {
            Install-PowerShell7FromMsi | Should -Be $true

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and -not ($ArgumentList -contains '/l*v')
            }
        }
    }

    It 'Kills msiexec and returns $false when the install outruns the timeout' {
        $script:msiExited = $false

        Install-PowerShell7FromMsi -InstallTimeoutSeconds 5 | Should -Be $false
        $script:msiKilled | Should -Be $true
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'did not finish within 5 seconds' }
    }

    It 'Passes the install timeout to WaitForExit in milliseconds' {
        $script:waitMilliseconds = $null
        $script:msiProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Force -Value {
            param($Milliseconds)
            $script:waitMilliseconds = $Milliseconds
            return $true
        }

        Install-PowerShell7FromMsi -InstallTimeoutSeconds 42 | Out-Null

        $script:waitMilliseconds | Should -Be 42000
    }

    It 'Never runs msiexec when the download fails' {
        Mock Save-WebFileWithTimeout { $false }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Start-Process -Times 0
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-pwsh-*' }
    }

    It 'Never downloads when the temp directory cannot be created' {
        Mock New-Item { throw 'Access to the path is denied.' }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Save-WebFileWithTimeout -Times 0
        Should -Invoke Start-Process -Times 0
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'temporary directory' }
    }

    It 'Never downloads when the release cannot be resolved' {
        Mock Get-PowerShell7MsiInfo { $null }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Save-WebFileWithTimeout -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'Returns $false when msiexec cannot be started' {
        # Under 5.1 a Start-Process failure is non-terminating, so without production's try/catch
        # $msiProcess would stay $null and the ExitCode read would blow up mid-bootstrap.
        Mock Start-Process { throw 'The system cannot find the file specified.' } -ParameterFilter { $FilePath -eq 'msiexec.exe' }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'msiexec could not be started' }
    }
}

Describe 'Invoke-PowerShell7Bootstrap' {
    BeforeEach {
        # Quiet the console helpers; every path is asserted through mocks, not output.
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Write-Success { }
        Mock Invoke-RestMethod { '# stub' }
        # Default the direct-MSI path to "did not work" so the pre-existing tests below keep
        # exercising the upstream-script fallback deterministically, with no real network reachable
        # from any of them. The direct path has its own context further down.
        Mock Install-PowerShell7FromMsi { $false }
        # The winget install runs through Invoke-WingetProcess (review findings P2-5, P2-6): no test
        # starts a real winget. The winget-path contexts below override this.
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
        # The function sets this relaunch-loop sentinel before relaunching; clear it so no test
        # inherits another test's (or an outer process's) bootstrap state.
        $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = ''
    }
    AfterEach {
        $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = ''
    }

    Context 'PowerShell 7 already installed' {
        BeforeEach {
            Mock Find-PowerShell7 { 'C:\pf7\pwsh.exe' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 42 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Relaunches the caller script under pwsh and returns the child exit code' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 42
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\pf7\pwsh.exe' -and
                ($ArgumentList -join ' ') -match '-NoProfile -ExecutionPolicy Bypass -File "C:\\repo\\winget-app-install\.ps1"'
            }
        }

        It 'Returns a single integer (the exit code), not an array' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            @($result).Count | Should -Be 1
            $result | Should -BeOfType [int]
        }

        It 'Forwards -WhatIf, -NonInteractive, and -SkipSystemCheck to the relaunch' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -WhatIf -NonInteractive -SkipSystemCheck | Out-Null

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '-WhatIf' -and
                $ArgumentList -contains '-NonInteractive' -and
                $ArgumentList -contains '-SkipSystemCheck'
            }
        }

        It 'Omits switches the caller did not pass' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                -not ($ArgumentList -contains '-WhatIf') -and
                -not ($ArgumentList -contains '-NonInteractive') -and
                -not ($ArgumentList -contains '-SkipSystemCheck')
            }
        }

        It 'Never attempts an install or a download' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 0
            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'Sets the relaunch-loop sentinel before relaunching' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            $env:WINGET_APP_SETUP_PS7_BOOTSTRAP | Should -Be '1'
        }

        It 'Fails fast (exit 1) when the sentinel says a relaunched child re-entered the dispatch' {
            $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = '1'

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 1
            Should -Invoke Start-Process -Times 0
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 're-entered' }
        }

        It 'Records that the relaunched run reported its own outcome, and logs its exit code (review finding P2-14)' {
            $script:PowerShell7BootstrapRelaunched = $false

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            $script:PowerShell7BootstrapRelaunched | Should -BeTrue
            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq 'The PowerShell 7 run ended with exit code 42.' }
        }

        It 'Returns 1 instead of a false success when the pwsh launch itself fails' {
            # Under 5.1 a Start-Process failure is non-terminating: without the production
            # try/catch the result would be $null and the tail's exit ($null) would report 0.
            Mock Start-Process { throw 'This command cannot be run due to the error: broken alias.' } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 1
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'could not be started' }
            # Nothing ran, so the tail must report this failure itself.
            $script:PowerShell7BootstrapRelaunched | Should -BeFalse
        }
    }

    Context 'PowerShell 7 missing, -WhatIf run' {
        BeforeEach {
            Mock Find-PowerShell7 { $null }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Read-Host { '' }
        }

        It 'Previews the would-be install, returns 0, and touches nothing' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -WhatIf

            $result | Should -Be 0
            Should -Invoke Start-Process -Times 0
            Should -Invoke Invoke-WingetProcess -Times 0
            Should -Invoke Read-Host -Times 0
            Should -Invoke Write-Info -Times 1 -ParameterFilter { $Message -match '\[DRY-RUN\] PowerShell 7 is not installed' }
        }
    }

    Context 'PowerShell 7 missing, interactive session (issue #230)' {
        # There is no consent prompt anymore. PowerShell 7 is a hard requirement of everything the
        # installer does, so the question only ever had one useful answer - and it fired on exactly
        # the run that must not stop: `irm | iex` reads as INTERACTIVE, because the iex pipe is an
        # in-process pipeline and leaves stdin alone.
        BeforeEach {
            Mock Find-PowerShell7 { $null }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Read-Host { throw 'The bootstrap must never prompt (issue #230)' }
        }

        It 'Installs without asking, even though the session is interactive' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Read-Host -Times 0 -Exactly
            # winget is mocked away, so the flow reaches the MSI fallback download.
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -like '*install-powershell*' }
        }

        It 'Announces the install rather than asking about it' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-Info -Times 1 -ParameterFilter { $Message -match 'Installing it now' }
        }
    }

    Context 'PowerShell 7 missing, winget install path (non-interactive)' {
        BeforeEach {
            # Find-PowerShell7 misses before the install and resolves after it.
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 2) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Test-EffectiveNonInteractive { $true }
            Mock Read-Host { '' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Installs via winget with the agreement flags, then relaunches' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[0] -eq 'install' -and
                $ArgumentList -contains 'Microsoft.PowerShell' -and
                $ArgumentList -contains '--accept-source-agreements' -and
                $ArgumentList -contains '--accept-package-agreements' -and
                $ArgumentList -contains '--exact'
            }
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Passes --disable-interactivity and never prompts' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Read-Host -Times 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '--disable-interactivity'
            }
        }

        It 'Runs the winget install under the install time limit, logging the installer next to the bootstrap transcript (review findings P2-5, P2-6)' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -LogDirectory 'C:\ProgramData\winget-app-setup\logs' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetInstall) -and
                $LogDirectory -eq 'C:\ProgramData\winget-app-setup\logs'
            }
        }

        It 'Passes --silent when the run is unattended, so the MSI installs with /quiet' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--silent' }
        }

        It 'Falls back to the MSI when the winget install runs past its time limit' {
            Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }
            Mock Find-PowerShell7 { $null }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish installing PowerShell 7 in time' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
        }

        It 'Falls back to the MSI when winget cannot be started' {
            Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.' }
            Mock Find-PowerShell7 { $null }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'winget could not be started: The file cannot be accessed by the system' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
        }

        It 'Does not reach the MSI fallback when winget succeeds' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-RestMethod -Times 0
        }
    }

    Context 'The winget install is never interactive (issue #230)' {
        It 'Passes --disable-interactivity even when the session is interactive' {
            # Inverted from its original form, which asserted the flag was OMITTED for interactive
            # sessions. That was exactly backwards for the case that matters: the documented
            # one-liner reports interactive, so the run most likely to be walked away from was the
            # one run that let winget stop and ask. Nothing here needs winget's UI - the agreements
            # go in by flag, and a failure falls through to the MSI fallback.
            Mock Find-PowerShell7 { $null }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '--disable-interactivity'
            }
            # Someone is at the console: the MSI may show its progress window (/passive).
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--silent' }
        }
    }

    Context 'PowerShell 7 missing, direct MSI download (issue #263)' {
        BeforeEach {
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 2) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Installs via the bounded direct MSI path and never touches the upstream script' {
            # The regression this guards: the upstream script suppresses all download progress and
            # downloads with an untimed Invoke-WebRequest, so reaching it is the slow, silent,
            # unbounded path. It must now only run when the direct path has already failed.
            Mock Install-PowerShell7FromMsi { $true }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like '*install-powershell*' }
        }

        It 'Hands the bootstrap log folder to the MSI install for msiexec''s log (review finding P2-13)' {
            Mock Install-PowerShell7FromMsi { $true }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -LogDirectory 'C:\ProgramData\winget-app-setup\logs' | Out-Null

            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly -ParameterFilter { $MsiLogDirectory -eq 'C:\ProgramData\winget-app-setup\logs' }
        }

        It 'Falls through to the upstream script only when the direct path fails' {
            Mock Install-PowerShell7FromMsi { $false }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*install-powershell*' }
        }

        It 'Warns that the upstream script produces no output before handing off to it' {
            # Silence is the whole complaint in issue #263; if this path is still reachable, the
            # operator has to be told that no output is expected rather than inferring a hang.
            Mock Install-PowerShell7FromMsi { $false }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'no download progress' }
        }

        It 'Bounds the upstream script download with a timeout' {
            Mock Install-PowerShell7FromMsi { $false }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*install-powershell*' -and $TimeoutSec -gt 0
            }
        }
    }

    Context 'PowerShell 7 missing, MSI fallback' {
        BeforeEach {
            Mock Test-EffectiveNonInteractive { $true }
            Mock Read-Host { '' }
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            # A parameter-bound no-op stands in for the downloaded aka.ms install script. The
            # params MUST be [switch]: production invokes it as `-UseMSI -Quiet`, and non-switch
            # params would throw at binding - silently diverting these tests into the catch path
            # (the review caught exactly that in an earlier revision of this file).
            Mock Invoke-RestMethod { 'param([switch]$UseMSI, [switch]$Quiet)' } -ParameterFilter { $Uri -like '*install-powershell*' }
        }

        It 'Uses the aka.ms MSI script when winget is absent' {
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 2) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*install-powershell*' }
            Should -Invoke Invoke-WingetProcess -Times 0
            # The stand-in script must have executed cleanly - a binding/runtime throw would be
            # swallowed by production's try/catch and this test would pass vacuously.
            Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'MSI fallback failed' }
        }

        It 'Uses the aka.ms MSI script when the winget install fails' {
            # Misses on the initial probe AND after the failed winget install; resolves after MSI.
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 3) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'winget could not install PowerShell 7 (exit code 1).' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*install-powershell*' }
            Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'MSI fallback failed' }
        }

        It 'Returns 1 with manual guidance when nothing can provision PowerShell 7' {
            Mock Find-PowerShell7 { $null }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 1
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'could not be installed automatically' }
            Should -Invoke Start-Process -Times 0 -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Points at "winget source reset" when the aka.ms fallback also hits a GitHub 429 (issue #274)' {
            # A machine already throttled on raw.githubusercontent.com loses every GitHub-hosted
            # fallback at once, so the generic manual-install message is not the most useful thing
            # to print - see issue #274 for the real-world failure this reproduces.
            Mock Find-PowerShell7 { $null }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-RestMethod { throw '429: Too Many Requests' } -ParameterFilter { $Uri -like '*install-powershell*' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 1
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter {
                $Message -match 'rate-limiting' -and $Message -match 'winget source reset --force'
            }
        }
    }

    Context 'iex mode: no script file on disk' {
        BeforeEach {
            Mock Find-PowerShell7 { 'C:\pf7\pwsh.exe' }
            Mock Set-Content { }
            Mock New-Item { } -ParameterFilter { $Path -like '*winget-app-setup-*' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 7 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Re-downloads the installer to a unique per-run temp directory and relaunches it' {
            Mock Invoke-RestMethod { '# installer body' }

            $result = Invoke-PowerShell7Bootstrap

            $result | Should -Be 7
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*winget-app-install.ps1' }
            # The relaunch file must live inside the fresh GUID-named directory, not at a fixed
            # predictable temp path (pre-planting / concurrent-run collision hazard).
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*winget-app-setup-*' }
            Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-*winget-app-install.ps1' }
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -match 'winget-app-setup-.*winget-app-install\.ps1'
            }
        }

        It 'Honors a custom InstallerUrl' {
            Mock Invoke-RestMethod { '# installer body' }

            Invoke-PowerShell7Bootstrap -InstallerUrl 'https://example.test/custom.ps1' | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://example.test/custom.ps1' }
        }

        It 'Bounds the re-download with a timeout (issue #263)' {
            Mock Invoke-RestMethod { '# installer body' }

            Invoke-PowerShell7Bootstrap | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $TimeoutSec -gt 0 }
        }

        It 'Returns 1 when the re-download fails' {
            Mock Invoke-RestMethod { throw 'network unreachable' }

            $result = Invoke-PowerShell7Bootstrap

            $result | Should -Be 1
            Should -Invoke Start-Process -Times 0
        }
    }
}
