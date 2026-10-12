# E2EUninstallPass.Tests.ps1
# Tests for e2e/Invoke-UninstallPass.ps1 (wgt-gq8.47), the uninstall pass at the end of the
# e2e-install leg of .github/workflows/e2e-install.yml: reading the uninstaller's console output
# (a sample run in tests/fixtures/e2e/uninstall-pass.txt) and the PASS/FAIL verdicts. The part that
# runs the uninstaller and asks winget needs a real Windows runner and is not run here.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:UninstallPassScript = Join-Path $script:RepoRoot 'e2e/Invoke-UninstallPass.ps1'
    . $script:UninstallPassScript
    $script:SampleOutput = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/e2e/uninstall-pass.txt')
    $script:CatalogIds = @(Get-DefaultAppCatalog | ForEach-Object { $_.name })

    # Every id winget was asked about answered 'not installed'.
    function New-AllGoneCheck {
        param ([string[]]$Ids)
        $checks = @{}
        foreach ($id in $Ids) {
            $checks[$id] = @{ Installed = $false; Detail = '' }
        }
        return $checks
    }
}

Describe 'ConvertFrom-UninstallerOutput' {
    It 'Reads the removed, kept and not-installed apps and the summary from a sample run' {
        $parsed = ConvertFrom-UninstallerOutput -Content $script:SampleOutput

        $parsed.HasSummary | Should -BeTrue
        $parsed.Uninstalled | Should -Be @('7zip.7zip', 'Adobe.Acrobat.Reader.64-bit', 'Git.Git', 'GlavSoft.TightVNC', 'Google.Chrome', 'Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $parsed.NotInstalled | Should -Be @('Adobe.Acrobat.Reader.32-bit', 'Dell.CommandUpdate.Universal')
        @($parsed.Kept.Keys | Sort-Object) | Should -Be @('Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
        $parsed.Kept['Microsoft.PowerShell'] | Should -Match '^this uninstaller is running in PowerShell 7'
        $parsed.Failed.Count | Should -Be 0
    }

    It 'Counts as kept on purpose only the uninstaller''s own reasons for keeping an app' -ForEach @(
        @{ Reason = 'a per-user app that this run cannot remove: it runs as SYSTEM; to remove it, run winget-app-uninstall.ps1 signed in as the user it belongs to'; Kept = $true }
        @{ Reason = 'not applicable: Dell hardware with x64 Windows only'; Kept = $true }
        @{ Reason = 'Windows Terminal hosts this window, or is set as the default terminal application'; Kept = $true }
        @{ Reason = 'some other reason'; Kept = $false }
    ) {
        $parsed = ConvertFrom-UninstallerOutput -Content "Skipping: Contoso.App ($Reason)"

        $parsed.Kept.ContainsKey('Contoso.App') | Should -Be $Kept
    }

    It 'Reads failures, in both of the uninstaller''s forms' {
        $content = @(
            'Failed to uninstall: Google.Chrome (winget uninstall exited with 0x8A150030).'
            'Failed to uninstall: Git.Git. Error: unexpected (test)'
        ) -join "`r`n"

        $parsed = ConvertFrom-UninstallerOutput -Content $content

        $parsed.Failed['Google.Chrome'] | Should -Be 'winget uninstall exited with 0x8A150030'
        $parsed.Failed['Git.Git'] | Should -Be 'Error: unexpected (test)'
        $parsed.HasSummary | Should -BeFalse
    }

    It 'Returns empty lists for no output' {
        $parsed = ConvertFrom-UninstallerOutput -Content ''

        @($parsed.Uninstalled).Count | Should -Be 0
        $parsed.Kept.Count | Should -Be 0
        $parsed.HasSummary | Should -BeFalse
    }

    It 'Matches what the uninstaller writes, so a reworded line fails here instead of matching nothing' {
        $uninstall = Get-Content -Raw -LiteralPath (Join-Path $script:WingetAppSetupRoot 'Public/Uninstall.ps1')
        $appUninstall = Get-Content -Raw -LiteralPath (Join-Path $script:WingetAppSetupRoot 'Private/AppUninstall.ps1')

        $uninstall | Should -Match ([regex]::Escape('Write-Success "Successfully uninstalled: $($app.name)"'))
        $uninstall | Should -Match ([regex]::Escape('Write-WarningMessage "Skipping: $($app.name) ($($outcome.Reason))"'))
        $uninstall | Should -Match ([regex]::Escape('Write-ErrorMessage "Failed to uninstall: $($app.name) ($($outcome.Reason))."'))
        $uninstall | Should -Match ([regex]::Escape("Write-Info 'Summary:'"))
        foreach ($reason in $script:UninstallKeptReasons) {
            $appUninstall | Should -Match ([regex]::Escape($reason))
        }
    }
}

Describe 'Get-UninstallPassCheckId' {
    It 'Asks winget about every catalog app except the ones kept on purpose' {
        $parsed = ConvertFrom-UninstallerOutput -Content $script:SampleOutput

        $ids = Get-UninstallPassCheckId -CatalogIds $script:CatalogIds -Parsed $parsed

        $ids | Should -Not -Contain 'Microsoft.PowerShell'
        $ids | Should -Not -Contain 'Microsoft.WindowsTerminal'
        $ids | Should -Contain 'Google.Chrome'
        $ids | Should -Contain 'Dell.CommandUpdate.Universal'
        @($ids).Count | Should -Be ($script:CatalogIds.Count - 2)
    }
}

Describe 'Get-UninstallPassResult' {
    BeforeAll {
        $script:Parsed = ConvertFrom-UninstallerOutput -Content $script:SampleOutput
        $script:CheckIds = @(Get-UninstallPassCheckId -CatalogIds $script:CatalogIds -Parsed $script:Parsed)
    }

    It 'Passes a sample run that exited <ExitCode> with every app gone and Winget-AutoUpdate removed' -ForEach @(
        @{ ExitCode = 0 }
        @{ ExitCode = 3010 }
    ) {
        $rows = @(Get-UninstallPassResult -ExitCode $ExitCode -Parsed $script:Parsed -CatalogIds $script:CatalogIds -InstalledAfter (New-AllGoneCheck -Ids $script:CheckIds) -WauTaskPresent $false)

        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
        ($rows | Where-Object { $_.Assertion -eq 'App kept on purpose: Microsoft.PowerShell' }).Result | Should -Be 'PASS'
        ($rows | Where-Object { $_.Assertion -eq 'App removed: Google.Chrome' }).Detail | Should -Be 'winget no longer lists it; uninstalled by this run'
        ($rows | Where-Object { $_.Assertion -eq 'App removed: Dell.CommandUpdate.Universal' }).Detail | Should -Be 'winget no longer lists it; not installed before the uninstall'
    }

    It 'Fails exit code <ExitCode>, naming the apps that failed' -ForEach @(
        @{ ExitCode = 1 }
        @{ ExitCode = 6 }
    ) {
        $parsed = ConvertFrom-UninstallerOutput -Content ($script:SampleOutput + "`nFailed to uninstall: Contoso.App (winget uninstall exited with 1603).")

        $row = @(Get-UninstallPassResult -ExitCode $ExitCode -Parsed $parsed -CatalogIds $script:CatalogIds -InstalledAfter (New-AllGoneCheck -Ids $script:CheckIds) -WauTaskPresent $false)[0]

        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be "exit $ExitCode; failed: Contoso.App (winget uninstall exited with 1603)"
    }

    It 'Fails a run that did not run to the end' {
        $row = @(Get-UninstallPassResult -ExitCode $null -Parsed $script:Parsed -CatalogIds $script:CatalogIds -InstalledAfter (New-AllGoneCheck -Ids $script:CheckIds) -WauTaskPresent $false)[0]

        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be 'it did not run to the end'
    }

    It 'Fails an app winget still lists, and one winget gave no answer for' {
        $checks = New-AllGoneCheck -Ids $script:CheckIds
        $checks['Google.Chrome'] = @{ Installed = $true; Detail = '' }
        $checks['Git.Git'] = @{ Installed = $null; Detail = 'timed out' }
        $checks.Remove('7zip.7zip')

        $rows = @(Get-UninstallPassResult -ExitCode 0 -Parsed $script:Parsed -CatalogIds $script:CatalogIds -InstalledAfter $checks -WauTaskPresent $false)
        $failed = @($rows | Where-Object { $_.Result -eq 'FAIL' })

        @($failed | ForEach-Object { $_.Assertion } | Sort-Object) | Should -Be @('App removed: 7zip.7zip', 'App removed: Git.Git', 'App removed: Google.Chrome')
        ($failed | Where-Object { $_.Assertion -eq 'App removed: Google.Chrome' }).Detail | Should -Be 'winget still lists it; uninstalled by this run'
        ($failed | Where-Object { $_.Assertion -eq 'App removed: Git.Git' }).Detail | Should -Be 'winget list could not answer (timed out); uninstalled by this run'
        ($failed | Where-Object { $_.Assertion -eq 'App removed: 7zip.7zip' }).Detail | Should -Be 'winget list could not answer (no answer); uninstalled by this run'
    }

    It 'Fails a run that removed nothing or printed no summary' {
        $parsed = ConvertFrom-UninstallerOutput -Content 'Skipping: Google.Chrome (not installed)'

        $rows = @(Get-UninstallPassResult -ExitCode 0 -Parsed $parsed -CatalogIds @('Google.Chrome') -InstalledAfter (New-AllGoneCheck -Ids @('Google.Chrome')) -WauTaskPresent $false)

        ($rows | Where-Object { $_.Assertion -eq 'Uninstaller removed apps' }).Result | Should -Be 'FAIL'
        ($rows | Where-Object { $_.Assertion -eq 'Uninstaller reached its summary' }).Result | Should -Be 'FAIL'
    }

    It 'Checks that Winget-AutoUpdate''s task is gone (<Case>)' -ForEach @(
        @{ Case = 'gone'; Present = $false; Result = 'PASS' }
        @{ Case = 'still there'; Present = $true; Result = 'FAIL' }
        @{ Case = 'unreadable'; Present = $null; Result = 'FAIL' }
    ) {
        $rows = @(Get-UninstallPassResult -ExitCode 0 -Parsed $script:Parsed -CatalogIds $script:CatalogIds -InstalledAfter (New-AllGoneCheck -Ids $script:CheckIds) -WauTaskPresent $Present)

        ($rows | Where-Object { $_.Assertion -eq 'Winget-AutoUpdate removed' }).Result | Should -Be $Result
    }
}

Describe 'The uninstall pass in the e2e workflow' {
    BeforeAll {
        $script:Workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
        $leg = [regex]::Match($script:Workflow, '(?ms)^  e2e-install:\r?\n.*?(?=^  e2e-install-windows-powershell:)')
        $script:Leg = $leg.Value
    }

    It 'Runs in the PowerShell 7 leg after the assertions, before the end-of-job diagnostics and the uploads' {
        $script:Leg | Should -Match 'Invoke-UninstallPass\.ps1'
        $assertions = $script:Leg.IndexOf('./e2e/Assert-Install.ps1')
        $uninstall = $script:Leg.IndexOf('./e2e/Invoke-UninstallPass.ps1')
        $assertions | Should -BeGreaterThan -1
        $uninstall | Should -BeGreaterThan $assertions
        $uninstall | Should -BeLessThan $script:Leg.IndexOf("-Label '3-end-of-job'")
        $uninstall | Should -BeLessThan $script:Leg.IndexOf('name: e2e-diagnostics')
        # Its output goes with the diagnostics, which are uploaded on failure too.
        $script:Leg | Should -Match "uninstall-pass\.txt"
        $script:Leg | Should -Match "uninstall-output\.txt"
        $script:Leg | Should -Match '(?ms)name: Upload diagnostics\s*\r?\n\s*if: always\(\)'
    }

    It 'Watches the uninstaller for pull requests' {
        $script:Workflow | Should -Match ([regex]::Escape('^(winget-app-install\.ps1|winget-app-uninstall\.ps1|\.github/workflows/e2e-install\.yml)$'))
    }
}

Describe 'e2e/Invoke-UninstallPass.ps1 under Windows PowerShell 5.1' {
    It 'Is ASCII only, parses cleanly and uses no PowerShell 7-only operators' {
        $bytes = [System.IO.File]::ReadAllBytes($script:UninstallPassScript)
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0

        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:UninstallPassScript, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $ps7OnlyKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
        @($tokens | Where-Object { $ps7OnlyKinds -contains $_.Kind.ToString() } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" }) | Should -BeNullOrEmpty
    }
}
