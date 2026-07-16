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
        # Read-Host is mocked only so the "never prompts" assertions have a command to count.
        # Write-Table has not called it since issue #230; a real call would block the suite.
        Mock Read-Host { throw 'Write-Table must never prompt (issue #230)' }

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
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match 'Status' -or $Object -match 'Apps' }
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

    It 'Should use Out-GridView when requested and available' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView
        Should -Invoke Out-GridView -Times 1
    }

    It 'Should fall back to text output when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Write-Host for fallback
        Should -Invoke Write-Host -Times 2  # Warning message + table output
    }

    It 'Should default to text output when UseGridView is false' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $false

        # Should not call Out-GridView
        Should -Invoke Out-GridView -Times 0
        # Should call Write-Host for text output
        Should -Invoke Write-Host -Times 1
    }

    # -AutoGridView replaced -PromptForGridView in issue #230: the grid view is no longer offered
    # as a Read-Host question, it just opens when the session can show one. Test-CanUseGridView is
    # the mocked seam throughout (rather than Get-Command) because it is the single gate the
    # function consults, and it makes the outcome independent of the host running Pester.
    Context 'AutoGridView opens the grid view without asking (issue #230)' {
        It 'Opens the grid view when the session can show one' {
            Mock Test-CanUseGridView { return $true }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -AutoGridView $true

            Should -Invoke Out-GridView -Times 1
        }

        It 'Still writes the text table when the grid view opens' {
            # Regression pin for the transcript (issue #230). Write-Table used to `return` the
            # moment Out-GridView was shown; now that the grid opens automatically rather than on
            # request, that early return would have silently dropped the summary from the
            # Start-Transcript log of every interactive run - Out-GridView renders in its own
            # window and is never transcribed. Both must happen.
            Mock Test-CanUseGridView { return $true }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -AutoGridView $true

            Should -Invoke Out-GridView -Times 1
            Should -Invoke Write-Host -Times 1
        }

        It 'Never prompts, whatever the session looks like' {
            # A throw rather than -Times 0: Read-Host is gone from the function entirely, so a
            # count assertion would pass vacuously and keep passing if it ever came back.
            Mock Test-CanUseGridView { return $true }
            Mock Read-Host { throw 'Write-Table must never prompt (issue #230)' }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            { Write-Table -Headers $headers -Rows $rows -AutoGridView $true } | Should -Not -Throw
            Should -Invoke Read-Host -Times 0 -Exactly
        }

        It 'Silently skips the grid view when the session cannot show one' {
            # -AutoGridView is an offer, not a request: no window and no warning, just the text.
            Mock Test-CanUseGridView { return $false }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -AutoGridView $true

            Should -Invoke Out-GridView -Times 0
            Should -Invoke Write-Host -Times 1
        }

        It 'Does not open the grid view when neither switch is set' {
            Mock Test-CanUseGridView { return $true }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows

            Should -Invoke Out-GridView -Times 0
            Should -Invoke Write-Host -Times 1
        }

        It 'Has no -PromptForGridView parameter' {
            # Non-vacuous pin on the rename. No build guard inspects parameter binding, so a caller
            # still passing the old name (winget-app-uninstall.ps1 did) would ship and fail at
            # runtime, after the work was already done.
            (Get-Command Write-Table).Parameters.ContainsKey('PromptForGridView') | Should -BeFalse
            (Get-Command Write-Table).Parameters.ContainsKey('AutoGridView') | Should -BeTrue
        }
    }

    It 'Should open the grid view when UseGridView is set, without AutoGridView' {
        Mock Test-CanUseGridView { return $true }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        Should -Invoke Out-GridView -Times 1
    }

    It 'Should warn when UseGridView is explicitly requested but unavailable' {
        # An explicit request that cannot be honored is worth a word; an -AutoGridView offer is not.
        Mock Test-CanUseGridView { return $false }
        Mock Write-WarningMessage { }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        Should -Invoke Out-GridView -Times 0
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'not available' }
    }

    It 'Should handle Out-GridView execution failure gracefully' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { throw 'GridView display error' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView and catch the error
        Should -Invoke Out-GridView -Times 1
        # Should fall back to Write-Host (warning + table output)
        Should -Invoke Write-Host -Times 2
    }

    It 'Should not open a grid view in a session that cannot show one (non-interactive sessions)' {
        # Rewritten in issue #192, then again in #230 when the prompt this guarded was removed.
        # Test-CanUseGridView returns $false when [Environment]::UserInteractive is false, so
        # mocking that seam drives the real non-interactive path deterministically — this is what
        # keeps an unattended run from opening a modal Out-GridView -Wait nobody would close.
        Mock Test-CanUseGridView { return $false }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -AutoGridView $true

        Should -Invoke Out-GridView -Times 0
        Should -Invoke Write-Host -Times 1
    }

    It 'Should use custom title when provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Custom Title' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -Title 'Custom Title'

        # Should call Out-GridView with custom title
        Should -Invoke Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Custom Title' }
    }

    It 'Should use default title when Title parameter is not provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Summary' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView with default title 'Summary'
        Should -Invoke Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Summary' }
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
