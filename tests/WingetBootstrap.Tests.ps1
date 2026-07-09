# WingetBootstrap.Tests.ps1
# Tests for WingetAppSetup/Private/WingetBootstrap.ps1: the winget source probe
# (Invoke-WingetSourceProbe) and the shared source health check (Test-WingetSourceHealth).
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-WingetSourceHealth (shared source probe, issue #177)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
    }

    It 'Reports healthy when the source is listed and a search succeeds' {
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

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $true
        $health.Healthy | Should -Be $true
        Should -Invoke Write-Success -Times 1 -ParameterFilter { $Message -match 'accessible and functional' }
    }

    It 'Reports not listed (and skips the search) when the winget source is missing' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
            }
            elseif ($args[0] -eq 'search') {
                throw 'search should not run when the source is not listed'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $false
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
    }

    It 'Reports not functional when the search probe exits nonzero' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                $global:LASTEXITCODE = 1
                return '0x8a15000f Data required by the source is missing'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'corrupted or missing data' }
    }

    It 'Suppresses per-step messages when -Quiet is passed' {
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

        $health = Test-WingetSourceHealth -Quiet

        $health.Healthy | Should -Be $true
        Should -Invoke Write-Success -Times 0 -Exactly
    }
}

Describe 'Invoke-WingetSourceProbe' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Remove-Item { }
    }

    It 'Runs winget source update with agreement acceptance and reports success' {
        Mock Start-Process {
            $p = [pscustomobject]@{ ExitCode = 0 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $p
        }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $true
        $result.ExitCode | Should -Be 0
        $result.TimedOut | Should -Be $false
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -contains 'source') -and
            ($ArgumentList -contains 'update') -and
            ($ArgumentList -contains '--name') -and
            ($ArgumentList -contains 'winget') -and
            ($ArgumentList -contains '--disable-interactivity') -and
            # --accept-source-agreements is INVALID for `winget source update` (0x8A150002); must be absent.
            ($ArgumentList -notcontains '--accept-source-agreements')
        }
    }

    It 'Passes through a failure exit code' {
        Mock Start-Process {
            # -2147009255 = 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF
            $p = [pscustomobject]@{ ExitCode = -2147009255 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $p
        }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be -2147009255
        $result.TimedOut | Should -Be $false
    }

    It 'Kills the process and reports a timeout when winget hangs' {
        $script:probeKillCalled = $false
        Mock Start-Process {
            $p = [pscustomobject]@{ ExitCode = 0 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $false }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { Set-Variable -Name probeKillCalled -Value $true -Scope script }
            $p
        }

        $result = Invoke-WingetSourceProbe -TimeoutSeconds 1

        $result.Succeeded | Should -Be $false
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
        $script:probeKillCalled | Should -Be $true
    }

    It 'Reports failure without throwing when winget cannot start' {
        Mock Start-Process { throw 'winget not found' }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be $null
        $result.TimedOut | Should -Be $false
    }

    It 'Uses unique temp file names on every run (issue #177)' {
        $script:probeRedirectPaths = @()
        Mock Start-Process {
            $script:probeRedirectPaths += @($RedirectStandardOutput, $RedirectStandardError)
            $p = [pscustomobject]@{ ExitCode = 0 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $p
        }

        [void](Invoke-WingetSourceProbe)
        [void](Invoke-WingetSourceProbe)

        $script:probeRedirectPaths.Count | Should -Be 4
        # stdout and stderr differ within one run, and neither repeats across runs.
        ($script:probeRedirectPaths | Select-Object -Unique).Count | Should -Be 4
        # Concurrent runs must not collide on the old fixed names.
        $script:probeRedirectPaths[0] | Should -Not -Be $script:probeRedirectPaths[2]
    }
}
