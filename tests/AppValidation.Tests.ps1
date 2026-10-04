# AppValidation.Tests.ps1
# Tests for WingetAppSetup/Public/AppValidation.ps1: Test-AppDefinitions validation of
# app catalog entries (malformed entries, duplicates).
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-AppDefinitions' {
    BeforeAll {
    }

    Context 'When app definitions are valid' {
        It 'Should return the same number of apps without errors or warnings' {
            $apps = @(
                @{ name = 'App.One' },
                @{ name = 'App.Two' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 2
            $result.Errors | Should -BeNullOrEmpty
            $result.Warnings | Should -BeNullOrEmpty
        }
    }

    Context 'When an entry is malformed' {
        It 'Should return an error and skip the invalid entry' {
            $apps = @(
                @{ name = 'App.Valid' },
                @{ bogus = 'value' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -Match "missing a valid 'name'"
        }
    }

    Context 'When an entry has a malformed package id (issue: CLAUDE.md regex enforcement)' {
        It 'Should return an error and skip an entry whose name is not publisher.product shaped' {
            $apps = @(
                @{ name = 'App.Valid' },
                @{ name = 'NotAPackageId' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.ValidApps[0].name | Should -Be 'App.Valid'
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -Match 'invalid package id'
        }

        It 'Should reject a valid id followed by trailing text: <Name>' -ForEach @(
            # Review finding P3-49: the unanchored pattern accepted any valid prefix, and
            # Start-Process -ArgumentList would have handed the rest to winget as extra switches.
            @{ Name = 'Google.Chrome --override "/S"' }
            @{ Name = 'Google.Chrome --scope user' }
            @{ Name = 'Foo.Bar;rm' }
            @{ Name = 'Foo.Bar extra' }
        ) {
            $result = Test-AppDefinitions -Apps @(@{ name = $Name })

            $result.ValidApps.Count | Should -Be 0
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -Match 'invalid package id'
        }

        It 'Should still accept a valid id with surrounding whitespace, trimmed' {
            $result = Test-AppDefinitions -Apps @(@{ name = "  Google.Chrome `t" })

            $result.Errors | Should -BeNullOrEmpty
            $result.ValidApps.Count | Should -Be 1
            $result.ValidApps[0].name | Should -Be 'Google.Chrome'
        }

        It 'Test-WingetPackageIdFormat matches a whole id only' {
            Test-WingetPackageIdFormat -PackageId 'Microsoft.DotNet.DesktopRuntime.8' | Should -BeTrue
            Test-WingetPackageIdFormat -PackageId '7zip.7zip' | Should -BeTrue
            Test-WingetPackageIdFormat -PackageId 'Google.Chrome --override /S' | Should -BeFalse
            Test-WingetPackageIdFormat -PackageId ' Google.Chrome' | Should -BeFalse
        }

        It 'Should accept every entry from the real, curated app catalog' {
            $catalog = Get-DefaultAppCatalog

            $result = Test-AppDefinitions -Apps $catalog

            $result.Errors | Should -BeNullOrEmpty
            $result.ValidApps.Count | Should -Be $catalog.Count
        }
    }

    Context 'When duplicate entries are present' {
        It 'Should keep the first occurrence and warn about duplicates' {
            $apps = @(
                @{ name = 'App.Duplicate' },
                @{ name = 'app.duplicate ' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.ValidApps[0].name | Should -Be 'App.Duplicate'
            $result.Warnings.Count | Should -Be 1
            $result.Warnings[0] | Should -Match 'Duplicate app definition'
        }
    }
}
