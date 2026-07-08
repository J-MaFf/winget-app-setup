# Interactivity.Tests.ps1
# Tests for WingetAppSetup/Private/Interactivity.ps1: the shared Test-EffectiveNonInteractive
# detection used by Invoke-WingetInstall and Test-SystemRequirements (issue #214).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-EffectiveNonInteractive (issue #214)' {
    It 'Returns $true when the explicit -NonInteractive switch is passed' {
        Test-EffectiveNonInteractive -NonInteractive | Should -BeTrue
    }

    It 'Returns a boolean either way (auto-detection path)' {
        # The switchless result depends on the host environment ([Environment]::UserInteractive
        # and Console.IsInputRedirected are not mockable statics), so pin the contract: the
        # function always returns a [bool] and never throws — a console probe failure must be
        # swallowed and mapped to $true, not propagated.
        { Test-EffectiveNonInteractive } | Should -Not -Throw
        Test-EffectiveNonInteractive | Should -BeOfType [bool]
    }

    It 'Detects a non-interactive session or redirected stdin as non-interactive (structural)' {
        # Structural pin on the three-way detection (issue #176 origin): explicit switch OR
        # non-UserInteractive session OR redirected stdin, with the console probe failure
        # branch treated as non-interactive.
        $body = (Get-Command Test-EffectiveNonInteractive).Definition
        $body | Should -Match '\[Environment\]::UserInteractive'
        $body | Should -Match '\[System\.Console\]::IsInputRedirected'
        $body | Should -Match '(?s)catch\s*\{.*return \$true'
    }
}

Describe 'Callers share the effective non-interactive detection (issue #214)' {
    It 'Invoke-WingetInstall derives its effective state from Test-EffectiveNonInteractive' {
        $installBody = (Get-Command Invoke-WingetInstall).Definition
        $installBody | Should -Match '\$effectiveNonInteractive = Test-EffectiveNonInteractive -NonInteractive:\$NonInteractive'
        # The old inline detection must not survive alongside the helper.
        $installBody | Should -Not -Match 'IsInputRedirected'
    }

    It 'Test-SystemRequirements gates its disk-space prompt on Test-EffectiveNonInteractive' {
        $checksBody = (Get-Command Test-SystemRequirements).Definition
        $checksBody | Should -Match 'Test-EffectiveNonInteractive -NonInteractive:\$NonInteractive'
    }

    It 'The generated installer forwards -NonInteractive into the pre-flight checks' {
        $installer = Get-Content -Path $script:InstallerScriptPath -Raw
        $installer | Should -Match 'Test-SystemRequirements -WhatIf:\$WhatIf -NonInteractive:\$NonInteractive'
    }
}
