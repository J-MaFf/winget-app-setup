# Logging.Tests.ps1
# Tests for WingetAppSetup/Public/Logging.ps1 and Private/LoggingInternal.ps1:
# colored output helpers, Format-AppList, Write-Table (grid view routing), Write-Prompt.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Write-Table' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . $script:InstallerScriptPath

        Mock Write-Host { }
        Mock Read-Host { return 'N' }

        # Unconditional test double (issue #192): shadows any real Out-GridView so Pester always
        # has a command to mock on every platform, and the suite can never pop real UI. The old
        # conditional `if (-not (Get-Command Out-GridView...))` stub made the mock target depend
        # on the machine running the tests.
        function Out-GridView { param($Title, [switch]$Wait) }
    }

    BeforeEach {
        Mock Out-GridView { }
    }

    It 'Should format table data correctly with Format-Table' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host at least once with formatted table output
        Assert-MockCalled Write-Host -Times 1 -ParameterFilter { $Object -match 'Status' -or $Object -match 'Apps' }
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
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should use Out-GridView when requested and available' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should fall back to text output when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Write-Host for fallback
        Assert-MockCalled Write-Host -Times 2  # Warning message + table output
    }

    It 'Should default to text output when UseGridView is false' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $false

        # Should not call Out-GridView
        Assert-MockCalled Out-GridView -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should prompt user when PromptForGridView is true and user accepts' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should call Read-Host to prompt user
        Assert-MockCalled Read-Host -Times 1
        # Should call Out-GridView since user said yes
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should prompt user when PromptForGridView is true and user declines' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'N' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should call Read-Host to prompt user
        Assert-MockCalled Read-Host -Times 1
        # Should not call Out-GridView since user said no
        Assert-MockCalled Out-GridView -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 2  # Empty line + table output
    }

    It 'Should not prompt when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should not call Read-Host since Out-GridView is not available
        Assert-MockCalled Read-Host -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should accept case-insensitive affirmative responses (y, Y, yes, YES)' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $testCases = @('y', 'Y', 'yes', 'YES', 'Yes', 'yEs')
        foreach ($response in $testCases) {
            Mock Read-Host { return $response }
            Mock Out-GridView { }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

            # Should call Out-GridView for all case variations
            Assert-MockCalled Out-GridView -Times 1
        }
    }

    It 'Should reject non-affirmative responses (n, N, no, anything else)' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $testCases = @('n', 'N', 'no', 'NO', 'nope', 'maybe', '', 'x')
        foreach ($response in $testCases) {
            Mock Read-Host { return $response }
            Mock Out-GridView { }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

            # Should NOT call Out-GridView for non-affirmative responses
            Assert-MockCalled Out-GridView -Times 0
            # Should call Write-Host for text output (empty line + table)
            Assert-MockCalled Write-Host -Times 2
        }
    }

    It 'Should skip prompt when UseGridView is true regardless of PromptForGridView' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'N' }  # User says no, but should be ignored

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -PromptForGridView $true

        # Should NOT call Read-Host since UseGridView takes precedence
        Assert-MockCalled Read-Host -Times 0
        # Should call Out-GridView directly
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should handle Out-GridView execution failure gracefully' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { throw 'GridView display error' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView and catch the error
        Assert-MockCalled Out-GridView -Times 1
        # Should fall back to Write-Host (warning + table output)
        Assert-MockCalled Write-Host -Times 2
    }

    It 'Should not prompt when the session cannot use grid view (non-interactive sessions)' {
        # Rewritten in issue #192: the old version wrapped its only assertion in
        # `if ([Environment]::UserInteractive)` and asserted the prompt IS shown — the opposite
        # of its name, and a no-op in non-interactive sessions. Write-Table's prompt is gated on
        # Test-CanUseGridView, which returns $false when [Environment]::UserInteractive is false,
        # so mocking that seam drives the real non-interactive code path deterministically.
        Mock Test-CanUseGridView { return $false }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # No prompt, no grid view — straight to text output.
        Assert-MockCalled Read-Host -Times 0
        Assert-MockCalled Out-GridView -Times 0
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should use custom title when provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Custom Title' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -Title 'Custom Title'

        # Should call Out-GridView with custom title
        Assert-MockCalled Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Custom Title' }
    }

    It 'Should use default title when Title parameter is not provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Summary' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView with default title 'Summary'
        Assert-MockCalled Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Summary' }
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

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
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

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
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

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
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

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
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

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Press any key to continue...' -and $ForegroundColor -eq 'Blue'
        }
    }
}
