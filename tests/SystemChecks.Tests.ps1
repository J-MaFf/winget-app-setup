# SystemChecks.Tests.ps1
# Tests for WingetAppSetup/Public/SystemChecks.ps1: the Test-SystemRequirements pre-flight
# checks (network reachability, disk space warnings, unattended-safe behavior).
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-SystemRequirements' -Tag 'SystemRequirements' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200 } }
        Mock Get-PSDrive {
            [PSCustomObject]@{ Free = 100GB }
        }
        Mock Get-ItemProperty {
            [PSCustomObject]@{ ProductName = 'Windows 11 Pro'; CurrentBuildNumber = '22631' }
        }
        # No Test-EffectiveNonInteractive mock: Test-SystemRequirements stopped consulting the
        # detection when its low-disk prompt was removed (issue #230), so these checks now behave
        # identically on an interactive console and a CI runner. That invariance is the point, and
        # it is pinned explicitly below rather than simulated with a mock.
    }

    It 'Returns $true when all checks pass' {
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Returns $false on a transport-level network failure (no HTTP response)' {
        Mock Invoke-WebRequest { throw 'No network' }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Treats an HTTP error response (e.g. 403) as reachable and returns $true' {
        Mock Invoke-WebRequest {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (Forbidden).', $response)
        }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    # Measured-low disk warns and continues, unconditionally and without asking (issue #230).
    # Previously it asked "Continue anyway? (Y/N)" and a declining (or empty) answer returned
    # $false, which silently cancelled unattended installs (issues #195/#214).
    Context 'Low disk space never blocks (issue #230)' {
        BeforeEach {
            Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
            # A throw is a stronger guard than -Times 0: it fails loudly at the call site with a
            # real stack, and cannot pass vacuously if the assertion is ever dropped.
            Mock Read-Host { throw 'Test-SystemRequirements must never prompt (issue #230)' }
        }

        It 'Warns and returns $true when low disk is measured, with no prompt' {
            $result = Test-SystemRequirements

            $result | Should -BeTrue
            Should -Invoke Read-Host -Times 0 -Exactly
            Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match 'Continuing anyway' }
        }

        It 'Behaves identically when the caller declares itself non-interactive' {
            # Regression pin for the removed branch: there is now ONE low-disk path, so an
            # unattended run and an interactive one produce the same warning and the same $true.
            # (The switch itself is gone from this function - see the parameter-surface test.)
            $result = Test-SystemRequirements

            $result | Should -BeTrue
            Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match 'Continuing anyway' }
        }

        It 'Skips the low-disk warning in WhatIf mode' {
            # This is the only thing keeping -WhatIf load-bearing in this function; without it the
            # tail's `Test-SystemRequirements -WhatIf:$WhatIf` would be the next thing to rot.
            { Test-SystemRequirements -WhatIf } | Should -Not -Throw
            Should -Invoke Write-WarningMessage -Times 0 -Exactly -ParameterFilter { $Message -match 'Continuing anyway' }
        }
    }

    It 'Does not have a -NonInteractive parameter (issue #230)' {
        # Non-vacuous pin on the signature change. The build's guard stack (parse, ASCII, export,
        # undefined-reference, byte-compare) inspects command NAMES only and is blind to parameter
        # binding, so a caller left passing -NonInteractive would ship and fail at runtime. This
        # test is what actually catches that.
        (Get-Command Test-SystemRequirements).Parameters.ContainsKey('NonInteractive') | Should -BeFalse
    }

    It 'Does not emit the low-disk warning when the C: drive cannot be read' {
        # The UNKNOWN path has no measured number, so it must not claim one (issue #195).
        Mock Get-PSDrive { throw 'Drive read failure' }
        Mock Read-Host { throw 'Test-SystemRequirements must never prompt (issue #230)' }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
        Should -Invoke Write-WarningMessage -Times 0 -Exactly -ParameterFilter { $Message -match 'Continuing anyway' }
    }

    It 'Reports UNKNOWN (not the low-space WARN) when the C: drive cannot be read' {
        Mock Get-PSDrive { throw 'Drive read failure' }
        $null = Test-SystemRequirements
        Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match '\[UNKNOWN\] Disk Space' }
    }

    # Windows 11 still reports the registry ProductName "Windows 10 ..." (Microsoft never
    # updated it); the build number (>= 22000) is the real discriminator (issue #221).
    Context 'OS version relabel (issue #221)' {
        It 'Relabels a Windows 11 machine that reports ProductName "Windows 10 Pro"' {
            Mock Get-ItemProperty { [PSCustomObject]@{ ProductName = 'Windows 10 Pro'; CurrentBuildNumber = '26200' } }
            $null = Test-SystemRequirements
            Should -Invoke Write-Success -ParameterFilter { $Message -match 'OS Version: Windows 11 Pro' }
        }

        It 'Leaves a genuine Windows 10 name unchanged when the build is below 22000' {
            Mock Get-ItemProperty { [PSCustomObject]@{ ProductName = 'Windows 10 Pro'; CurrentBuildNumber = '19045' } }
            $null = Test-SystemRequirements
            Should -Invoke Write-Success -ParameterFilter { $Message -match 'OS Version: Windows 10 Pro' }
        }

        It 'Does not relabel Windows Server 2025 (build >= 22000 but not a "Windows 10" name)' {
            Mock Get-ItemProperty { [PSCustomObject]@{ ProductName = 'Windows Server 2025 Datacenter'; CurrentBuildNumber = '26100' } }
            $null = Test-SystemRequirements
            Should -Invoke Write-Success -ParameterFilter { $Message -match 'OS Version: Windows Server 2025 Datacenter' }
        }

        It 'Warns (non-blocking) and reports the true build on Windows older than build 19044' {
            Mock Get-ItemProperty { [PSCustomObject]@{ ProductName = 'Windows 10 Pro'; CurrentBuildNumber = '19041' } }
            $result = Test-SystemRequirements
            $result | Should -BeTrue
            Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match '\[WARN\] OS Version' -and $Message -match 'build 19041' }
        }
    }
}
