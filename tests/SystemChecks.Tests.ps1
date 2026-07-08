# SystemChecks.Tests.ps1
# Tests for WingetAppSetup/Public/SystemChecks.ps1: the Test-SystemRequirements pre-flight
# checks (network reachability, disk space prompts, unattended-safe behavior).
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
            [PSCustomObject]@{ ProductName = 'Windows 11 Pro' }
        }
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

    It 'Returns $false when user declines low disk space prompt' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { 'N' }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Returns $true when user accepts low disk space prompt' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { 'Y' }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Skips disk space prompt in WhatIf mode' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { throw 'Should not prompt in WhatIf mode' }
        { Test-SystemRequirements -WhatIf } | Should -Not -Throw
    }

    It 'Does not prompt when the C: drive cannot be read (unattended-safe)' {
        Mock Get-PSDrive { throw 'Drive read failure' }
        Mock Read-Host { throw 'Should not prompt when free space was not measured' }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Reports UNKNOWN (not the low-space WARN) when the C: drive cannot be read' {
        Mock Get-PSDrive { throw 'Drive read failure' }
        Mock Read-Host { throw 'Should not prompt when free space was not measured' }
        $null = Test-SystemRequirements
        Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match '\[UNKNOWN\] Disk Space' }
    }
}
