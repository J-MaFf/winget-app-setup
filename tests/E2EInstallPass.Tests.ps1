# E2EInstallPass.Tests.ps1
# Tests for e2e/Invoke-InstallPass.ps1, which runs every install pass of
# .github/workflows/e2e-install.yml in both legs (PowerShell 7, and Windows PowerShell 5.1 for the
# bootstrap, review finding P3-40): the command line of each pass, the exit-code policy, and the
# Invoke-RestMethod shim that keeps a 5.1 checkout run on the checkout for its PowerShell 7
# relaunch. The process tests start the current pwsh with a stand-in installer, never the real one.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:InstallPassScript = Join-Path $script:RepoRoot 'e2e/Invoke-InstallPass.ps1'
    . $script:InstallPassScript
    $script:Pwsh = (Get-Process -Id $PID).Path

    function ConvertFrom-EncodedArgument {
        param ([Parameter(Mandatory = $true)][string[]]$Arguments)
        $index = [array]::IndexOf($Arguments, '-EncodedCommand')
        return [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Arguments[$index + 1]))
    }

    function New-StandInInstaller {
        param ([Parameter(Mandatory = $true)][string]$Body)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + " stand-in's installer.ps1")
        Set-Content -LiteralPath $path -Value $Body
        return $path
    }
}

Describe 'Get-InstallPassVerdict' {
    It 'Exit <ExitCode> with KNOWN_PLATFORM_INCOMPATIBLE=''<Known>'' -> <Outcome>, step exit <StepExitCode>' -ForEach @(
        @{ ExitCode = 0; Known = ''; Outcome = 'passed'; StepExitCode = 0 }
        @{ ExitCode = 1; Known = ''; Outcome = 'failed'; StepExitCode = 1 }
        @{ ExitCode = 1; Known = '  '; Outcome = 'failed'; StepExitCode = 1 }
        @{ ExitCode = 1; Known = 'Some.App'; Outcome = 'tolerated'; StepExitCode = 0 }
        @{ ExitCode = 2; Known = 'Some.App'; Outcome = 'failed'; StepExitCode = 2 }
        @{ ExitCode = 5; Known = ''; Outcome = 'failed'; StepExitCode = 5 }
        @{ ExitCode = 3010; Known = ''; Outcome = 'failed'; StepExitCode = 3010 }
    ) {
        $verdict = Get-InstallPassVerdict -ExitCode $ExitCode -KnownPlatformIncompatible $Known -Pass 'first'

        $verdict.Outcome | Should -Be $Outcome
        $verdict.StepExitCode | Should -Be $StepExitCode
    }

    It 'Names the pass and the code in its message' {
        (Get-InstallPassVerdict -ExitCode 2 -KnownPlatformIncompatible '' -Pass 'second').Message | Should -Be 'Second install pass FAILED with exit code 2'
        (Get-InstallPassVerdict -ExitCode 1 -KnownPlatformIncompatible 'Some.App' -Pass 'first').Message | Should -Match '^First install pass exited 1 \(some apps failed\) - tolerated .*: Some\.App$'
    }
}

Describe 'Get-InstallPassCommand' {
    BeforeAll {
        $script:Installer = Join-Path $TestDrive 'winget-app-install.ps1'
    }

    It 'Runs the readme''s one-liner, verbatim, for the weekly raw-main run in either shell and either pass' -ForEach @(
        @{ Shell = 'pwsh'; Entry = 'OneLiner' }
        @{ Shell = 'pwsh'; Entry = 'File' }
        @{ Shell = 'powershell'; Entry = 'OneLiner' }
        @{ Shell = 'powershell'; Entry = 'File' }
    ) {
        $command = Get-InstallPassCommand -Shell $Shell -Entry $Entry -Source 'raw-main' -InstallerPath $script:Installer

        $command.FilePath | Should -Be $Shell
        $command.Arguments[0..1] | Should -Be @('-NoProfile', '-EncodedCommand')
        ConvertFrom-EncodedArgument -Arguments $command.Arguments | Should -Be $command.Script
        $command.Script | Should -Not -Match 'Invoke-RestMethod'
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'readme.md')
        $readme.Contains($command.Script) | Should -BeTrue -Because 'the weekly run tests exactly what the readme tells people to run'
    }

    It 'Runs the checkout with -File for a -File pass' {
        $command = Get-InstallPassCommand -Shell 'powershell' -Entry 'File' -Source 'checkout' -InstallerPath $script:Installer

        $command.FilePath | Should -Be 'powershell'
        $command.Arguments | Should -Be @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Installer)
        $command.Script | Should -BeNullOrEmpty
    }

    It 'Pipes the checkout to iex for a one-liner pass, with the relaunch shim only under Windows PowerShell' {
        $pwshCommand = Get-InstallPassCommand -Shell 'pwsh' -Entry 'OneLiner' -Source 'checkout' -InstallerPath $script:Installer
        $windowsPowerShellCommand = Get-InstallPassCommand -Shell 'powershell' -Entry 'OneLiner' -Source 'checkout' -InstallerPath $script:Installer

        $iexLine = "Get-Content -Raw -Encoding UTF8 -LiteralPath '$script:Installer' | iex"
        ($pwshCommand.Script -split "`n")[-1] | Should -Be $iexLine
        $pwshCommand.Script | Should -Not -Match 'Invoke-RestMethod'
        ($windowsPowerShellCommand.Script -split "`n")[-1] | Should -Be $iexLine
        $windowsPowerShellCommand.Script | Should -Match 'function global:Invoke-RestMethod'
        $windowsPowerShellCommand.Script.IndexOf('function global:Invoke-RestMethod') | Should -BeLessThan $windowsPowerShellCommand.Script.IndexOf($iexLine)
        ConvertFrom-EncodedArgument -Arguments $windowsPowerShellCommand.Arguments | Should -Be $windowsPowerShellCommand.Script
    }

    It 'Treats an empty or unknown source as the checkout' {
        (Get-InstallPassCommand -Shell 'pwsh' -Entry 'OneLiner' -Source '' -InstallerPath $script:Installer).Description | Should -Match '^the checkout'
    }
}

Describe 'The checkout relaunch shim' {
    It 'Serves the checkout for the installer URL the bootstrap downloads, and passes other calls to Invoke-RestMethod' {
        # Run in a child pwsh like the real pass. The stand-in does what the bootstrap does: fetch
        # the installer from raw main by URL. It records what it got, and a call to another URL
        # must reach the real cmdlet (a refused connection, not the checkout's text).
        $resultPath = Join-Path $TestDrive 'shim-result.txt'
        $body = @"
`$fetched = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1' -TimeoutSec 60
`$otherRef = Invoke-RestMethod 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/main/winget-app-install.ps1'
try { Invoke-RestMethod -Uri 'http://127.0.0.1:9/' -TimeoutSec 5; `$other = 'served' } catch { `$other = 'real cmdlet' }
Set-Content -LiteralPath '$resultPath' -Value @(`$fetched.Length, `$otherRef.Length, `$other)
"@
        $installer = New-StandInInstaller -Body $body
        $command = Get-InstallPassCommand -Shell 'powershell' -Entry 'OneLiner' -Source 'checkout' -InstallerPath $installer

        $null = & $script:Pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command.Script))) 2>&1

        $expectedLength = (Get-Content -Raw -Encoding UTF8 -LiteralPath $installer).Length
        Get-Content -LiteralPath $resultPath | Should -Be @("$expectedLength", "$expectedLength", 'real cmdlet')
    }
}

Describe 'e2e/Invoke-InstallPass.ps1 run as a step' {
    It 'Exits <Expected> when the installer exits <InstallerExit> (KNOWN_PLATFORM_INCOMPATIBLE=''<Known>'', -Entry <Entry>)' -ForEach @(
        @{ InstallerExit = 0; Known = ''; Entry = 'File'; Expected = 0 }
        @{ InstallerExit = 1; Known = ''; Entry = 'File'; Expected = 1 }
        @{ InstallerExit = 1; Known = 'Some.App'; Entry = 'File'; Expected = 0 }
        @{ InstallerExit = 2; Known = 'Some.App'; Entry = 'OneLiner'; Expected = 2 }
        @{ InstallerExit = 5; Known = ''; Entry = 'OneLiner'; Expected = 5 }
    ) {
        $installer = New-StandInInstaller -Body "Write-Host 'stand-in installer'; exit $InstallerExit"

        $output = & $script:Pwsh -NoProfile -File $script:InstallPassScript -Pass second -Shell pwsh -Entry $Entry -Source checkout -KnownPlatformIncompatible $Known -InstallerPath $installer 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be $Expected
        ($output -join "`n") | Should -Match 'stand-in installer'
    }

    It 'Exits 64 without a pass, shell and entry' {
        $null = & $script:Pwsh -NoProfile -File $script:InstallPassScript 2>&1
        $LASTEXITCODE | Should -Be 64
    }
}

Describe 'e2e scripts run by Windows PowerShell 5.1' {
    It 'Stays runnable by Windows PowerShell 5.1: <Name> is ASCII only, parses cleanly, no PowerShell 7-only operators' -ForEach @(
        @{ Name = 'e2e/Invoke-InstallPass.ps1' }
        @{ Name = 'e2e/Remove-PreinstalledApps.ps1' }
        @{ Name = 'e2e/TranscriptAssertions.ps1' }
    ) {
        $path = Join-Path $script:RepoRoot $Name
        $bytes = [System.IO.File]::ReadAllBytes($path)
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0

        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $ps7OnlyKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
        @($tokens | Where-Object { $ps7OnlyKinds -contains $_.Kind.ToString() } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" }) | Should -BeNullOrEmpty
    }
}
