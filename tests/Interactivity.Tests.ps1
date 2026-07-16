# Interactivity.Tests.ps1
# Tests for WingetAppSetup/Private/Interactivity.ps1: the shared Test-EffectiveNonInteractive
# detection (issue #214), whose sole remaining caller is Invoke-WingetInstall (issue #230), plus
# the repo-wide "no install path prompts" contract that issue #230 established.

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

    It 'Test-SystemRequirements no longer consults the detection at all (issue #230)' {
        # Inverted from its #214 form. The disk-space prompt this used to gate is gone, so the
        # pre-flight checks behave the same for every session and have nothing to detect.
        $checksBody = (Get-Command Test-SystemRequirements).Definition
        $checksBody | Should -Not -Match 'Test-EffectiveNonInteractive'
        $checksBody | Should -Not -Match 'Read-Host'
    }

    It 'The generated installer calls the pre-flight checks without -NonInteractive (issue #230)' {
        # Guards the exact runtime break the build cannot see: Test-SystemRequirements dropped the
        # parameter, and no build guard inspects parameter binding, so a stale
        # `-NonInteractive:$NonInteractive` here would pass -Check and then die on a real run with
        # "A parameter cannot be found that matches parameter name 'NonInteractive'".
        $installer = Get-Content -Path $script:InstallerScriptPath -Raw
        $installer | Should -Match 'Test-SystemRequirements -WhatIf:\$WhatIf\)'
        $installer | Should -Not -Match 'Test-SystemRequirements[^\r\n]*-NonInteractive'
    }
}

Describe 'No install path asks a yes/no question (issue #230)' {
    # The headline contract: `irm <url> | iex` from an ordinary console must reach the summary
    # without a keystroke. Read-Host is the mechanism that broke it, and it reads as INTERACTIVE on
    # that path (the iex pipe leaves stdin alone), so no interactivity check can be trusted to
    # suppress a prompt - the prompts have to not exist. Structural, because there is no way to
    # assert "nothing blocked" from inside a test that would itself hang if something did.
    BeforeAll {
        # Parse rather than grep. These files explain at length, in comment-based help, WHY they no
        # longer prompt — so a regex for 'Read-Host' matches the documentation of its own removal.
        # The AST only ever reports a real invocation, which is the thing that can actually block.
        function Get-PromptingCommand {
            param([string[]]$Path)
            foreach ($file in $Path) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
                $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                    Where-Object { $_.GetCommandName() -in 'Read-Host', 'Pause' } |
                    ForEach-Object { '{0}:{1}: {2}' -f (Split-Path $file -Leaf), $_.Extent.StartLineNumber, $_.Extent.Text }
            }
        }
    }

    It 'No module source file calls Read-Host or Pause' {
        $sourceFiles = Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Private'), (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1' |
            Select-Object -ExpandProperty FullName
        Get-PromptingCommand -Path $sourceFiles | Should -BeNullOrEmpty
    }

    It 'Neither shipped entry point calls Read-Host or Pause' {
        # The generated installer and the uninstaller are what users actually run. The uninstaller
        # is checked here because it is not generated - it hand-calls into the module, so nothing
        # else would catch a prompt reappearing in it.
        Get-PromptingCommand -Path $script:InstallerScriptPath, $script:UninstallerScriptPath | Should -BeNullOrEmpty
    }
}
