# WingetAgreementArgs.Tests.ps1
# Tests for WingetAppSetup/Private/WingetAgreementArgs.ps1: the shared helper
# (Get-WingetAgreementArgs) that de-duplicates the agreement/interactivity flag triple that used
# to be hand-copied across Install-WingetPackage, Install-MsixProvisionedPackage, and the
# PowerShell 7 bootstrap's winget install call (issue #230 follow-up).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Get-WingetAgreementArgs' {
    It 'Returns exactly the three shared agreement/interactivity flags, in order' {
        $result = Get-WingetAgreementArgs

        $result | Should -Be @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    }

    It 'Returns a flat string array (no nested arrays that would collapse when spliced with +)' {
        $result = @(Get-WingetAgreementArgs)

        $result.Count | Should -Be 3
        $result | ForEach-Object { $_ | Should -BeOfType [string] }
    }
}
