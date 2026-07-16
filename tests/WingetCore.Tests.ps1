# WingetCore.Tests.ps1
# Tests for WingetAppSetup/Public/WingetCore.ps1: winget bootstrap, source health/repair,
# package install (0x80073d19 backoff, scope fallback), installed-checks, per-user source
# init, and the PowerShell always-latest / MSIX provisioning strategies.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-AndInstallWingetModule' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . $script:InstallerScriptPath

        Mock Write-Host { }
        Mock Write-Warning { }

    }

    Context 'When module is already available' {
        It 'Should return true without installing' {
            Mock Get-Module { @{ Name = 'Microsoft.WinGet.Client' } } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }
            Mock Get-PackageProvider { }
            Mock Install-PackageProvider { }
            Mock Install-Module { }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $true
            Should -Invoke Install-Module -Times 0
        }
    }

    Context 'When module is missing and installation succeeds' {
        It 'Should install dependencies and return true' {
            $script:moduleInstalled = $false

            Mock Get-Module {
                if ($script:moduleInstalled) {
                    return @{ Name = 'Microsoft.WinGet.Client' }
                }
                return $null
            } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }

            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { $script:moduleInstalled = $true }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $true
            Should -Invoke Install-PackageProvider -Times 1 -ParameterFilter { $Name -eq 'NuGet' }
            Should -Invoke Install-Module -Times 1
        }
    }

    Context 'When module installation fails' {
        It 'Should return false and emit warning' {
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }
            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { }
            Mock Install-Module { throw 'Failure installing module' }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $false
            Should -Invoke Install-Module -Times 1
        }
    }
}

Describe 'Test-AndInstallWinget' {
    BeforeAll {
        Mock Write-Host { }

        # Dot-source the main script to import Test-AndInstallWinget
    }

    BeforeEach {
        # Safety net (#181): never let the real Repair-WinGetPackageManager run during unit
        # tests — it downloads and re-registers the App Installer. The cmdlet exists on dev
        # machines and CI (Microsoft.WinGet.Client is installed), so Pester can mock it
        # unconditionally.
        Mock Repair-WinGetPackageManager { }
        # Default: the repair cmdlet appears absent, so tests exercise the plain
        # aka.ms/getwinget fallback unless a test overrides this lookup.
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
    }

    Context 'When winget is available' {
        It 'Should return true and not attempt installation' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WebRequest { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Get-Command -Times 1
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    Context 'When winget is not available and installation succeeds' {
        It 'Should attempt installation, re-verify winget, and return true' {
            $script:appInstallerRegistered = $false
            Mock Get-Command {
                if ($script:appInstallerRegistered) { return $true }
                return $false
            } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:appInstallerRegistered = $true }
            Mock Remove-Item { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Invoke-WebRequest -Times 1
            Should -Invoke Add-AppxPackage -Times 1
            Should -Invoke Remove-Item -Times 1
            # The fallback must verify winget after Add-AppxPackage (issue #177): initial check + re-check.
            Should -Invoke Get-Command -Times 2 -Exactly -ParameterFilter { $Name -eq 'winget' }
        }
    }

    Context 'When App Installer registers but winget is still unavailable (issue #177)' {
        It 'Should return false and direct the user to install winget manually' {
            Mock Get-Command { $false } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }
            Mock Remove-Item { }
            Mock Write-ErrorMessage { }

            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Should -Invoke Add-AppxPackage -Times 1
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'install winget manually' }
        }
    }

    Context 'When winget is not available and installation fails' {
        It 'Should attempt installation, catch error, and return false' {
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { throw 'Network error' }
            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Should -Invoke Invoke-WebRequest -Times 1
        }
    }

    Context 'When Repair-WinGetPackageManager is available and bootstraps winget' {
        It 'Should return true without downloading the App Installer' {
            $script:wingetAvailable = $false
            Mock Get-Command {
                if ($script:wingetAvailable) { return $true }
                return $null
            } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager { $script:wingetAvailable = $true }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
            Should -Invoke Add-AppxPackage -Times 0
        }
    }

    Context 'When Repair-WinGetPackageManager is available but throws' {
        It 'Should fall back to the App Installer download and return true once winget resolves' {
            # winget is absent until the App Installer fallback registers it; the fallback's
            # post-install re-check (issue #177) must then find it and return $true.
            $script:appInstallerRegistered = $false
            Mock Get-Command {
                if ($script:appInstallerRegistered) { return $true }
                return $null
            } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager { throw 'Repair failed' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:appInstallerRegistered = $true }
            Mock Remove-Item { }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1
            Should -Invoke Add-AppxPackage -Times 1
        }
    }
}

Describe 'Test-WingetSources' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        # Dot-source the main script to import Test-WingetSources
    }

    Context 'When winget sources are listed and functional' {
        It 'Should return true without attempting repair' {
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 0
        }
    }

    Context 'When winget source is corrupted (0x8a15000f)' {
        It 'Should detect corruption and attempt repair with source reset' {
            $script:searchCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCount++
                    if ($script:searchCount -eq 1) {
                        # First call: corrupted data
                        $global:LASTEXITCODE = 1
                        return 'Failed when opening source(s); try the source reset command if the problem persists. 0x8a15000f Data required by the source is missing'
                    }
                    # After reset: works
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When winget sources are missing entirely' {
        It 'Should attempt repair with source reset and Add-AppxPackage' {
            # Poison any exit code left over from other tests so this test only
            # passes when the mock choreography below is complete (#181).
            $global:LASTEXITCODE = 1
            $script:listCallCount = 0
            Mock winget {
                # Set $global:LASTEXITCODE on EVERY simulated call: production reads it
                # right after each search, and stale values leak between tests (#181).
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCallCount++
                    $global:LASTEXITCODE = 0
                    if ($script:listCallCount -eq 1) {
                        # Initially: only msstore, no winget
                        return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                    }
                    # After repair: winget source is restored
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    # Production performs a single post-repair search in this scenario
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When winget sources repair fails' {
        It 'Should return false when Add-AppxPackage throws error' {
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { throw 'Network error' }

            $result = Test-WingetSources
            $result | Should -Be $false
        }
    }

    Context 'When winget source is corrupted and source reset fails' {
        It 'Should still attempt Add-AppxPackage as fallback' {
            $script:listCallCount = 0
            $script:searchCallCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCallCount++
                    if ($script:listCallCount -eq 1) {
                        # Initially: source is listed
                        return 'winget      https://cdn.winget.microsoft.com/cache'
                    }
                    # After repair attempt: still listed (but Add-AppxPackage will fix it)
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCallCount++
                    if ($script:searchCallCount -eq 1) {
                        # Initially: corrupted
                        $global:LASTEXITCODE = 1
                        return '0x8a15000f Data required by the source is missing'
                    }
                    # After Add-AppxPackage: works
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    # Reset fails
                    throw 'Access denied'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When winget source list throws an exception' {
        It 'Should attempt repair and handle the error gracefully' {
            # Poison any exit code left over from other tests so this test only
            # passes when the mock choreography below is complete (#181).
            $global:LASTEXITCODE = 1
            $script:listCount = 0
            Mock winget {
                # Set $global:LASTEXITCODE on EVERY simulated call: production reads it
                # right after each search, and stale values leak between tests (#181).
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCount++
                    if ($script:listCount -eq 1) {
                        throw 'Access denied'
                    }
                    # After repair, list succeeds
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    # Production performs a single post-repair search in this scenario
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'Functional probe arguments (issue #177)' {
        It 'Should pass --accept-source-agreements to the winget search probe' {
            $script:searchArgs = $null
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchArgs = $args
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources

            $result | Should -Be $true
            # --accept-source-agreements is valid for `winget search` (unlike `winget source
            # update`, issues #174/#175) and stops a fresh account's unaccepted agreements
            # (0x8A150046) from being misdiagnosed as source corruption.
            $script:searchArgs | Should -Contain '--accept-source-agreements'
            $script:searchArgs | Should -Contain '--disable-interactivity'
            $script:searchArgs | Should -Contain '--source'
        }
    }
}

Describe 'msstore-era source-trust helpers removed (issue #177)' {
    # Test-WingetSourceTrusted trusted error output (no $LASTEXITCODE check on merged stderr) and
    # Set-Sources was only reachable from the removed Install.ps1 trusted-sources loop; source
    # health is verified (and repaired) solely by Test-WingetSources now.
    It 'No longer defines Test-WingetSourceTrusted' {
        Test-Path Function:\Test-WingetSourceTrusted | Should -Be $false
    }

    It 'No longer defines Set-Sources' {
        Test-Path Function:\Set-Sources | Should -Be $false
    }

    It 'No longer exports either helper from the module manifest' {
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        $manifest.FunctionsToExport | Should -Not -Contain 'Test-WingetSourceTrusted'
        $manifest.FunctionsToExport | Should -Not -Contain 'Set-Sources'
    }
}

Describe 'Install-WingetPackage (0x80073d19 session-error backoff)' {
    BeforeAll {
        # 0x80073D19 (ERROR_INSTALL_USER_LOGOFF) as the signed Int32 winget reports.
        $script:SessionLogoffExitCode = -2147009255
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        # Never actually wait during tests; the backoff is verified via Should -Invoke.
        Mock Start-Sleep { }

        # Each Start-Process call returns the next exit code from the queue, simulating winget.
        $script:exitCodeQueue = @()
        $script:procCallIndex = 0
        Mock Start-Process {
            $code = $script:exitCodeQueue[$script:procCallIndex]
            $script:procCallIndex++
            [pscustomobject]@{ ExitCode = $code }
        }
    }

    It 'Succeeds on the first attempt without sleeping' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Retries with backoff and recovers when the session error is transient' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Start-Process -Times 2 -Exactly
        # One backoff wait between the failed first attempt and the successful second.
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Exhausts MaxAttempts when the session error persists' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, $script:SessionLogoffExitCode, $script:SessionLogoffExitCode)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be $script:SessionLogoffExitCode
        $result.Attempts | Should -Be 3
        $result.SessionErrorExhausted | Should -Be $true
        Should -Invoke Start-Process -Times 3 -Exactly
        # Sleeps between attempts only (1->2 and 2->3), never after the final attempt.
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'Does not retry a non-session failure (lets the caller verify)' {
        # -1978335189 = "No applicable update found"; any non-session code must stop immediately.
        $script:exitCodeQueue = @(-1978335189)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335189
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Prefers machine scope on the first attempt (issue #159)' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.MachineScopeFellBack | Should -Be $false
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -contains '--scope') -and ($ArgumentList -contains 'machine')
        }
    }

    It 'Falls back to default scope when the package has no machine-scope installer' {
        # -1978335216 = 0x8A150010 NO_APPLICABLE_INSTALLER (e.g. MSIX-only Microsoft.WindowsTerminal).
        $script:exitCodeQueue = @(-1978335216, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        # The scope fallback is not a session-error retry: it must not consume an attempt or sleep.
        $result.Attempts | Should -Be 1
        Should -Invoke Start-Process -Times 2 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--scope' }
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Falls back on scope at most once' {
        # NO_APPLICABLE_INSTALLER at both scopes is a real failure and must be returned, not looped.
        $script:exitCodeQueue = @(-1978335216, -1978335216)

        $result = Install-WingetPackage -PackageId 'Broken.Package' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335216
        $result.MachineScopeFellBack | Should -Be $true
        Should -Invoke Start-Process -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Still retries the session error with backoff after a scope fallback' {
        $script:exitCodeQueue = @(-1978335216, $script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Start-Process -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Passes --installer-type to winget when an installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Microsoft.PowerShell' -InstallerType 'wix' -MaxAttempts 1 | Out-Null

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '--installer-type\s+wix'
        }
    }

    It 'Omits --installer-type when no installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -notcontains '--installer-type'
        }
    }

    It 'Installs from the winget source with both agreement-acceptance flags (issue #172)' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            (($ArgumentList -join ' ') -match '--source winget') -and
            ($ArgumentList -contains '--accept-source-agreements') -and
            ($ArgumentList -contains '--accept-package-agreements')
        }
    }
}

Describe 'Test-WingetPackageInstalled (timeout support, issue #188)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Remove-Item { }
    }

    Context 'Without -TimeoutSeconds (backward-compatible inline call)' {
        It 'Returns $true when winget lists the package' {
            Mock winget { "Name    Id       Version`n7-Zip   Test.App 24.09" }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App'

            $result | Should -BeOfType [bool]
            $result | Should -Be $true
        }

        It 'Returns $false when winget does not list the package' {
            Mock winget { 'No installed package found matching input criteria.' }

            Test-WingetPackageInstalled -PackageId 'Test.App' | Should -Be $false
        }

        It 'Returns $false when winget throws' {
            Mock winget { throw 'winget not found' }

            Test-WingetPackageInstalled -PackageId 'Test.App' | Should -Be $false
        }
    }

    Context 'With -TimeoutSeconds (Start-Process guard, the pattern Invoke-WingetInstall inlined pre-#188)' {
        It 'Reports installed with the process exit code when the id appears in the output' {
            Mock Start-Process {
                $p = [pscustomobject]@{ ExitCode = 0 }
                $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
                $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
                $p
            }
            Mock Get-Content { 'Test.App  1.2.3  winget' }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $true
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'list') -and
                ($ArgumentList -contains '--exact') -and
                ($ArgumentList -contains '--id') -and
                ($ArgumentList -contains 'Test.App') -and
                ($ArgumentList -contains '--accept-source-agreements')
            }
        }

        It 'Reports not-installed when the output does not mention the id' {
            Mock Start-Process {
                $p = [pscustomobject]@{ ExitCode = -1978335212 }
                $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
                $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
                $p
            }
            Mock Get-Content { 'No installed package found matching input criteria.' }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be -1978335212
        }

        It 'Kills a hung winget list and reports the timeout distinctly from not-installed (issue #176)' {
            $script:listKillCalled = $false
            Mock Start-Process {
                $p = [pscustomobject]@{ ExitCode = 0 }
                $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $false }
                $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { Set-Variable -Name listKillCalled -Value $true -Scope script }
                $p
            }
            Mock Get-Content { throw 'output must not be read after a timeout' }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 1

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $true
            $result.ExitCode | Should -Be $null
            $script:listKillCalled | Should -Be $true
        }

        It 'Reports a failure without throwing when winget cannot start' {
            Mock Start-Process { throw 'winget not found' }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be $null
        }

        It 'Uses unique temp file names on every run and cleans them up (issue #177)' {
            $script:listRedirectPaths = @()
            Mock Start-Process {
                $script:listRedirectPaths += @($RedirectStandardOutput, $RedirectStandardError)
                $p = [pscustomobject]@{ ExitCode = 0 }
                $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
                $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
                $p
            }
            Mock Get-Content { '' }

            [void](Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15)
            [void](Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15)

            $script:listRedirectPaths.Count | Should -Be 4
            # stdout and stderr differ within one run, and neither repeats across runs.
            ($script:listRedirectPaths | Select-Object -Unique).Count | Should -Be 4
            # Both temp files are removed after each of the two runs.
            Should -Invoke Remove-Item -Times 4 -Exactly
        }
    }
}

Describe 'Initialize-WingetSourcesForUser (cross-user bootstrap, issue #159)' {
    BeforeAll {
        # Stub so the cmdlet can be mocked on machines without the Microsoft.WinGet.Client module.
        function Repair-WinGetPackageManager { param([switch]$Latest, [switch]$Force) }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Repair-WinGetPackageManager { }
        Mock Get-ProcessUserName { 'CONTOSO\admin-jmaffiola' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\admin-jmaffiola' }
        # Repair-WinGetPackageManager resolves as available unless a test overrides this.
        Mock Get-Command { [pscustomobject]@{ Name = 'Repair-WinGetPackageManager' } } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
    }

    It 'Reports the dry run without probing' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser -WhatIf

        $result | Should -Be $true
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
    }

    It 'Returns true without repairing when the probe succeeds' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $true
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
    }

    It 'Repairs the package manager and succeeds when the re-probe passes' {
        $script:probeCallCount = 0
        Mock Invoke-WingetSourceProbe {
            $script:probeCallCount++
            if ($script:probeCallCount -eq 1) {
                # First probe: blocked per-user bootstrap (0x80073D19).
                return @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false }
            }
            return @{ Succeeded = $true; ExitCode = 0; TimedOut = $false }
        }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $true
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Returns false when the probe still fails after repair' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Returns false and skips repair when Repair-WinGetPackageManager is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -1978335162; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
    }

    It 'Warns about cross-user elevation when the process account differs from the session owner' {
        Mock Get-ProcessUserName { 'CONTOSO\admin-jmaffiola' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        [void](Initialize-WingetSourcesForUser)

        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'Cross-user elevation detected' }
    }

    It 'Does not warn about cross-user elevation for a same-account session' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        [void](Initialize-WingetSourcesForUser)

        Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'Cross-user elevation detected' }
    }
}

Describe 'Install-PowerShellLatest (always-latest strategy, issue #166)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
    }

    It 'installs the MSI while one is available and verifies via winget' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $true
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $InstallerType -eq 'wix' }
        Should -Invoke Install-MsixProvisionedPackage -Times 0 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -gt 0 }
    }

    It 'installs the native MSIX on Windows 24H2+ when no MSI is available' {
        # -1978335216 = NO_APPLICABLE_INSTALLER: the wix (MSI) installer is gone at 7.7+.
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-native'
        $result.Installed | Should -Be $true
        Should -Invoke Install-MsixProvisionedPackage -Times 0 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -gt 0 }
    }

    It 'provisions the MSIX via DISM on older Windows when no MSI is available' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } }
        Mock Get-WindowsBuildNumber { 19045 }
        Mock Install-MsixProvisionedPackage { @{ ExitCode = 0; Installed = $true } }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-provisioned'
        $result.Installed | Should -Be $true
        Should -Invoke Install-MsixProvisionedPackage -Times 1 -Exactly
    }

    It 'passes a 15-second timeout (matching Install-AppWithVerification) to the MSI-path verification call' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        [void](Install-PowerShellLatest)

        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'passes a 15-second timeout to the native-MSIX-path verification call' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        [void](Install-PowerShellLatest)

        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'treats a timed-out MSI-path verification as not installed rather than throwing' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; ExitCode = $null } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $false
    }
}

Describe 'Install-MsixProvisionedPackage (DISM provisioning, issue #166)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-ErrorMessage { }
        Mock New-Item { }
        Mock Remove-Item { }
    }

    It 'downloads, provisions, and verifies the MSIX for all users' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-ChildItem {
            @(
                [pscustomobject]@{ Name = 'PowerShell-7.7.0-win.msixbundle'; Extension = '.msixbundle'; FullName = 'C:\dl\PowerShell-7.7.0-win.msixbundle' },
                [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.msix'; Extension = '.msix'; FullName = 'C:\dl\Dependencies\Microsoft.WindowsAppRuntime.msix' },
                [pscustomobject]@{ Name = 'PowerShell_License1.xml'; Extension = '.xml'; FullName = 'C:\dl\PowerShell_License1.xml' }
            )
        }
        Mock Invoke-AppxProvisioning { $true }
        Mock Test-AppxPackageProvisioned { $true }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $true
        Should -Invoke Invoke-AppxProvisioning -Times 1 -Exactly -ParameterFilter {
            $PackagePath -like '*PowerShell-7.7.0-win.msixbundle' -and (($DependencyPackagePath -join '') -like '*WindowsAppRuntime*')
        }
    }

    It 'returns not-installed when winget download fails' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run after a failed download' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
    }

    It 'returns not-installed when no MSIX is found in the download' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-ChildItem { @() }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run when no package was found' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
    }
}

Describe 'Invoke-AppxProvisioning (delegated command quoting, issue #178)' {
    # Under pwsh, Invoke-AppxProvisioning delegates to Windows PowerShell 5.1 by string-building
    # an elevated powershell.exe -Command payload. Every path interpolated into that string sits
    # inside a single-quoted literal, so embedded apostrophes must be doubled — otherwise a path
    # like C:\Users\O'Brien\... unbalances the quoting (or breaks out of the literal entirely).
    # These tests mock the powershell.exe invocation boundary and inspect the -Command argument.
    BeforeEach {
        Mock Write-ErrorMessage { }
        $script:capturedCommand = $null
        Mock powershell.exe { $script:capturedCommand = "$($args[-1])"; $global:LASTEXITCODE = 0 }
    }

    It 'escapes an apostrophe in PackagePath by doubling the single quote' {
        [void](Invoke-AppxProvisioning -PackagePath "C:\Users\O'Brien\pkg.msix")

        Should -Invoke powershell.exe -Times 1 -Exactly
        $script:capturedCommand | Should -BeLike "*-PackagePath 'C:\Users\O''Brien\pkg.msix'*"
        $script:capturedCommand | Should -Not -BeLike "*-PackagePath 'C:\Users\O'Brien*"
    }

    It 'escapes apostrophes in every DependencyPackagePath element before joining' {
        [void](Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msix' -DependencyPackagePath @(
                "C:\Users\O'Brien\dep1.msix",
                "C:\Users\D'Arcy\dep2.msix"
            ))

        $script:capturedCommand | Should -BeLike "*-DependencyPackagePath @('C:\Users\O''Brien\dep1.msix','C:\Users\D''Arcy\dep2.msix')*"
    }

    It 'escapes an apostrophe in LicensePath' {
        Mock Test-Path { $true }

        [void](Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msix' -LicensePath "C:\Users\O'Brien\license.xml")

        $script:capturedCommand | Should -BeLike "*-LicensePath 'C:\Users\O''Brien\license.xml'*"
    }

    It 'leaves apostrophe-free paths unchanged and skips the license when none exists' {
        $result = Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msixbundle' -DependencyPackagePath @('C:\dl\Dependencies\runtime.msix')

        $result | Should -Be $true
        $script:capturedCommand | Should -BeLike "*-PackagePath 'C:\dl\pkg.msixbundle' -DependencyPackagePath @('C:\dl\Dependencies\runtime.msix') -SkipLicense*"
    }
}
