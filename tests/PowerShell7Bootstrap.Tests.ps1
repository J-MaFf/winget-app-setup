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
            # Pin the candidate roots so assertions are deterministic on any host.
            $script:savedProgramFiles = $env:ProgramFiles
            $script:savedProgramW6432 = $env:ProgramW6432
            $script:savedLocalAppData = $env:LOCALAPPDATA
            $env:ProgramFiles = 'C:\TestProgramFiles'
            $env:ProgramW6432 = 'C:\TestProgramW6432'
            $env:LOCALAPPDATA = 'C:\TestLocalAppData'
        }
        AfterEach {
            $env:ProgramFiles = $script:savedProgramFiles
            $env:ProgramW6432 = $script:savedProgramW6432
            $env:LOCALAPPDATA = $script:savedLocalAppData
        }

        It 'Falls back to the Program Files install location' {
            Mock Test-Path { $LiteralPath -like 'C:\TestProgramFiles*' } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path 'C:\TestProgramFiles' 'PowerShell\7\pwsh.exe')
        }

        It 'Probes the 64-bit Program Files from a 32-bit host (ProgramW6432)' {
            Mock Test-Path { $LiteralPath -like 'C:\TestProgramW6432*' } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path 'C:\TestProgramW6432' 'PowerShell\7\pwsh.exe')
        }

        It 'Probes the WindowsApps execution alias (MSIX install on Windows 11 24H2+)' {
            Mock Test-Path { $LiteralPath -like 'C:\TestLocalAppData*' } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path 'C:\TestLocalAppData' 'Microsoft\WindowsApps\pwsh.exe')
        }

        It 'Prefers the Program Files install over the WindowsApps alias when both exist' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path 'C:\TestProgramFiles' 'PowerShell\7\pwsh.exe')
        }

        It 'Returns $null when no candidate exists' {
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }

        It 'Skips a candidate that exists but fails validation (pre-7 engine or broken alias)' {
            # PATH-less; ProgramFiles and WindowsApps candidates both exist on disk, but the
            # ProgramFiles one fails the execution probe - the WindowsApps one must win.
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
            Mock Test-PowerShell7Executable { $Path -like 'C:\TestLocalAppData*' }

            Find-PowerShell7 | Should -Be (Join-Path 'C:\TestLocalAppData' 'Microsoft\WindowsApps\pwsh.exe')
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

Describe 'Invoke-PowerShell7Bootstrap' {
    BeforeEach {
        # Quiet the console helpers; every path is asserted through mocks, not output.
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Write-Success { }
        Mock Invoke-RestMethod { '# stub' }
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

            Should -Invoke Start-Process -Times 0 -ParameterFilter { $FilePath -eq 'winget' }
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

        It 'Returns 1 instead of a false success when the pwsh launch itself fails' {
            # Under 5.1 a Start-Process failure is non-terminating: without the production
            # try/catch the result would be $null and the tail's exit ($null) would report 0.
            Mock Start-Process { throw 'This command cannot be run due to the error: broken alias.' } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 1
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'could not be started' }
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
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Installs via winget with the agreement flags, then relaunches' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'winget' -and
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
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'winget' -and $ArgumentList -contains '--disable-interactivity'
            }
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

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'winget' -and $ArgumentList -contains '--disable-interactivity'
            }
        }
    }

    Context 'PowerShell 7 missing, MSI fallback' {
        BeforeEach {
            Mock Test-EffectiveNonInteractive { $true }
            Mock Read-Host { '' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } } -ParameterFilter { $FilePath -eq 'winget' }
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
            Should -Invoke Start-Process -Times 0 -ParameterFilter { $FilePath -eq 'winget' }
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
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'winget' }
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

        It 'Returns 1 when the re-download fails' {
            Mock Invoke-RestMethod { throw 'network unreachable' }

            $result = Invoke-PowerShell7Bootstrap

            $result | Should -Be 1
            Should -Invoke Start-Process -Times 0
        }
    }
}
