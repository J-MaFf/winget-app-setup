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
        @{ ExitCode = 3010; Known = ''; Outcome = 'passed'; StepExitCode = 0 }
        @{ ExitCode = 8; Known = 'Some.App'; Outcome = 'failed'; StepExitCode = 8 }
    ) {
        $verdict = Get-InstallPassVerdict -ExitCode $ExitCode -KnownPlatformIncompatible $Known -Pass 'first'

        $verdict.Outcome | Should -Be $Outcome
        $verdict.StepExitCode | Should -Be $StepExitCode
    }

    It 'Names the pass and the code in its message' {
        (Get-InstallPassVerdict -ExitCode 2 -KnownPlatformIncompatible '' -Pass 'second').Message | Should -Be 'Second install pass FAILED with exit code 2'
        (Get-InstallPassVerdict -ExitCode 1 -KnownPlatformIncompatible 'Some.App' -Pass 'first').Message | Should -Match '^First install pass exited 1 \(some apps failed\) - tolerated .*: Some\.App$'
        (Get-InstallPassVerdict -ExitCode 3010 -KnownPlatformIncompatible '' -Pass 'first').Message | Should -Be 'First install pass exited 3010 (OK, restart required).'
    }

    # Review finding P3-36: the installer exits 8 when auto-updates are not configured, which on
    # windows-latest (no Microsoft.WindowsAppRuntime.1.8) was every pass until the installer
    # installed the framework itself (work-order item 31). Only that reason passes.
    It 'Exit 8 with ''Auto-updates: <Line>'' in the pass''s transcript -> <Outcome>, step exit <StepExitCode>' -ForEach @(
        @{ Line = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'; Outcome = 'passed'; StepExitCode = 0 }
        @{ Line = 'FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.'; Outcome = 'failed'; StepExitCode = 8 }
        @{ Line = 'UNHEALTHY - Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate does not exist; apps will not update automatically (see above).'; Outcome = 'failed'; StepExitCode = 8 }
        @{ Line = 'AT RISK - Winget-AutoUpdate is installed but Microsoft.WindowsAppRuntime.1.8 is missing; its next run may leave winget unusable (see above).'; Outcome = 'failed'; StepExitCode = 8 }
        @{ Line = 'NOT CONFIGURED - some other reason.'; Outcome = 'failed'; StepExitCode = 8 }
    ) {
        $transcript = [pscustomobject]@{ Name = 'install-20261005-060000.log'; Parsed = (ConvertFrom-InstallTranscript -Content "Summary:`nAuto-updates: $Line") }

        $verdict = Get-InstallPassVerdict -ExitCode 8 -KnownPlatformIncompatible 'Some.App' -Pass 'first' -Transcript $transcript

        $verdict.Outcome | Should -Be $Outcome
        $verdict.StepExitCode | Should -Be $StepExitCode
        $verdict.Message | Should -Match '^First install pass exited 8 \(apps OK, auto-updates not configured or unhealthy\) - '
        $verdict.Message | Should -Match 'install-20261005-060000\.log'
    }

    # Work-order item 31: the installer installs the pinned framework itself, so an accepted exit 8
    # now means that install was not possible here; the message says why.
    It 'Quotes the transcript''s Windows App Runtime line when it accepts exit 8 for the missing framework' {
        $content = "Windows App Runtime: NOT INSTALLED - installing it for all users needs administrator rights.`nSummary:`nAuto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it."
        $transcript = [pscustomobject]@{ Name = 'install-20261005-060000.log'; Parsed = (ConvertFrom-InstallTranscript -Content $content) }

        $verdict = Get-InstallPassVerdict -ExitCode 8 -KnownPlatformIncompatible '' -Pass 'first' -Transcript $transcript

        $verdict.Outcome | Should -Be 'passed'
        $verdict.StepExitCode | Should -Be 0
        $verdict.Message | Should -Be "First install pass exited 8 (apps OK, auto-updates not configured or unhealthy) - accepted: install-20261005-060000.log says 'Auto-updates: NOT CONFIGURED' because Microsoft.WindowsAppRuntime.1.8 is missing. The installer's own install of the framework: 'Windows App Runtime: NOT INSTALLED - installing it for all users needs administrator rights.'"
    }

    # Review of item 31: on windows-latest every precondition holds, so a NOT INSTALLED there is a
    # failed download, check or provisioning. Accepting it kept the run green while the install
    # the run is meant to show working was broken.
    It 'Fails exit 8 when the installer started its install of the framework and it failed: <Reason>' -ForEach @(
        @{ Reason = 'Add-AppxProvisionedPackage failed (its error is above); Windows Server without the Desktop Experience, or a policy that blocks app packages, cannot take it' }
        @{ Reason = 'Add-AppxProvisionedPackage reported success, but the framework is still not there (Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 for X64 required; found: none registered)' }
        @{ Reason = 'the downloaded framework failed its signature check: it is not signed by Microsoft Corporation (signature status: UnknownError; signer: none)' }
        @{ Reason = 'downloading https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk.runtime/1.8.260921001/microsoft.windowsappsdk.runtime.1.8.260921001.nupkg failed: The operation has timed out' }
    ) {
        $content = @(
            'Microsoft.WindowsAppRuntime.1.8 is missing; installing the pinned Windows App Runtime 1.8.12 (framework 8000.994.2142.0, X64) for all users first...'
            "Windows App Runtime: NOT INSTALLED - $Reason."
            'Summary:'
            'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'
        ) -join "`n"
        $transcript = [pscustomobject]@{ Name = 'install-20261005-060000.log'; Parsed = (ConvertFrom-InstallTranscript -Content $content) }

        $verdict = Get-InstallPassVerdict -ExitCode 8 -KnownPlatformIncompatible '' -Pass 'first' -Transcript $transcript

        $verdict.Outcome | Should -Be 'failed'
        $verdict.StepExitCode | Should -Be 8
        $verdict.Message | Should -Be "First install pass exited 8 (apps OK, auto-updates not configured or unhealthy) - FAILED: install-20261005-060000.log shows that the installer started its install of the pinned Microsoft.WindowsAppRuntime.1.8 and it failed ('Windows App Runtime: NOT INSTALLED - $Reason.'), so Winget-AutoUpdate was skipped"
    }

    # Review of item 32: when the pinned framework no longer meets what the latest winget release
    # needs, every PC without that framework goes without Winget-AutoUpdate until the pin moves.
    # The weekly run has to go red for that, for a newer 1.8 build as for another family.
    It 'Fails exit 8 when the pinned framework no longer meets what the latest winget release needs: <Needs>' -ForEach @(
        @{ Needs = 'Microsoft.WindowsAppRuntime.1.8 >= 8000.1200.0.0'; Missing = 'Microsoft.WindowsAppRuntime.1.8' }
        @{ Needs = 'Microsoft.WindowsAppRuntime.2 >= 2000.120.5.0'; Missing = 'Microsoft.WindowsAppRuntime.2' }
    ) {
        $runtimeLine = "NOT INSTALLED - the latest winget release needs $Needs, and the framework this installer installs, Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0, does not meet that; a newer version of this installer is needed."
        $content = @(
            "Windows App Runtime: $runtimeLine"
            'Summary:'
            "Auto-updates: NOT CONFIGURED - $Missing is missing, and Winget-AutoUpdate would leave winget unusable without it."
        ) -join "`n"
        $transcript = [pscustomobject]@{ Name = 'install-20261005-060000.log'; Parsed = (ConvertFrom-InstallTranscript -Content $content) }

        $verdict = Get-InstallPassVerdict -ExitCode 8 -KnownPlatformIncompatible '' -Pass 'first' -Transcript $transcript

        $verdict.Outcome | Should -Be 'failed'
        $verdict.StepExitCode | Should -Be 8
        $verdict.Message | Should -Be "First install pass exited 8 (apps OK, auto-updates not configured or unhealthy) - FAILED: install-20261005-060000.log shows that the installer's pinned Windows App Runtime no longer meets what the latest winget release needs ('Windows App Runtime: $runtimeLine'), so Winget-AutoUpdate was skipped, as it will be on every PC without that framework. Move the pin (Get-WindowsAppRuntimePin, WingetAppSetup/Private/WindowsAppRuntime.ps1)"
    }

    It 'Fails exit 8 when the pass''s transcript has no Auto-updates line, or there is no transcript' {
        $noLine = [pscustomobject]@{ Name = 'install-20261005-060000.log'; Parsed = (ConvertFrom-InstallTranscript -Content 'Summary:') }

        $verdict = Get-InstallPassVerdict -ExitCode 8 -KnownPlatformIncompatible '' -Pass 'second' -Transcript $noLine
        $verdict.StepExitCode | Should -Be 8
        $verdict.Message | Should -Be "Second install pass exited 8 (apps OK, auto-updates not configured or unhealthy) - FAILED: install-20261005-060000.log reports no 'Auto-updates:' line, not NOT CONFIGURED for a missing Microsoft.WindowsAppRuntime.1.8"

        $verdict = Get-InstallPassVerdict -ExitCode 8 -KnownPlatformIncompatible '' -Pass 'second' -Transcript $null
        $verdict.StepExitCode | Should -Be 8
        $verdict.Message | Should -Be 'Second install pass exited 8 (apps OK, auto-updates not configured or unhealthy) - FAILED: no transcript of this pass was found, so why cannot be checked'
    }
}

Describe 'Get-InstallPassTranscript' {
    BeforeEach {
        $script:logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:logs
        $script:start = [datetime]'2026-10-05T06:00:00'
        function New-TestTranscript {
            param ([string]$Name, [string[]]$Lines, [int]$MinutesAfterStart)
            $path = Join-Path $script:logs $Name
            Set-Content -LiteralPath $path -Value $Lines
            (Get-Item -LiteralPath $path).LastWriteTime = $script:start.AddMinutes($MinutesAfterStart)
        }
    }

    It 'Reads the PowerShell 7 transcript written since the pass started, not an earlier pass''s, a bootstrap or a dry run' {
        New-TestTranscript -Name 'install-20261005-053000.log' -Lines @('Summary:', 'Auto-updates: FAILED - earlier pass.') -MinutesAfterStart -20
        New-TestTranscript -Name 'install-20261005-060010.log' -Lines @('Summary:', 'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, this pass.') -MinutesAfterStart 10
        New-TestTranscript -Name 'install-20261005-060005-bootstrap.log' -Lines @('Relaunching the installer under PowerShell 7: C:\pwsh.exe') -MinutesAfterStart 11
        New-TestTranscript -Name 'install-20261005-060020-whatif.log' -Lines @('Summary:', 'Auto-updates: FAILED - dry run.') -MinutesAfterStart 12

        $transcript = Get-InstallPassTranscript -LogDirectory $script:logs -Since $script:start

        $transcript.Name | Should -Be 'install-20261005-060010.log'
        $transcript.Parsed.AutoUpdatesFrameworkMissing | Should -BeTrue
    }

    It 'Prefers the transcript that reached its summary when the pass wrote two' {
        New-TestTranscript -Name 'install-20261005-060010.log' -Lines @('Summary:', 'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing.') -MinutesAfterStart 10
        New-TestTranscript -Name 'install-20261005-060001.log' -Lines @('This script requires administrator privileges. Restarting with elevated privileges...') -MinutesAfterStart 11

        (Get-InstallPassTranscript -LogDirectory $script:logs -Since $script:start).Name | Should -Be 'install-20261005-060010.log'
    }

    It 'Returns nothing when the pass wrote no transcript' {
        New-TestTranscript -Name 'install-20261005-053000.log' -Lines @('Summary:') -MinutesAfterStart -20

        Get-InstallPassTranscript -LogDirectory $script:logs -Since $script:start | Should -BeNullOrEmpty
        Get-InstallPassTranscript -LogDirectory (Join-Path $TestDrive 'no-such-folder') -Since $script:start | Should -BeNullOrEmpty
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
        # -OutputFormat Text keeps the child's stderr plain text instead of CLIXML.
        $command.Arguments[0..3] | Should -Be @('-NoProfile', '-OutputFormat', 'Text', '-EncodedCommand')
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

    It 'Leaves a one-liner pass''s output plain text on a redirected stderr, not CLIXML' {
        # As on the runner: the step's stderr is a pipe the installer's PowerShell inherits.
        # ProcessStartInfo, not '2>&1': PowerShell would decode CLIXML it reads itself.
        $installer = New-StandInInstaller -Body "Write-Host 'stand-in installer'; Write-Error 'stand-in error'; exit 0"
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($argument in @('-NoProfile', '-File', $script:InstallPassScript, '-Pass', 'first', '-Shell', 'pwsh', '-Entry', 'OneLiner', '-Source', 'checkout', '-KnownPlatformIncompatible', '', '-InstallerPath', $installer)) {
            $startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $stderr = $stderrTask.Result

        $process.ExitCode | Should -Be 0
        $stdout | Should -Match 'stand-in installer'
        $stderr | Should -Not -Match 'CLIXML'
        $stderr | Should -Match 'stand-in error'
    }

    It 'Exits <Expected> when the installer exits 8 and <Case>' -ForEach @(
        @{ Case = 'its transcript says auto-updates were skipped for the missing framework'; Line = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'; Expected = 0 }
        @{ Case = 'its transcript says the auto-update setup failed'; Line = 'FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically.'; Expected = 8 }
        @{ Case = 'it wrote no transcript'; Line = $null; Expected = 8 }
    ) {
        $logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $logs
        $writeTranscript = ''
        if ($Line) {
            $transcriptPath = Join-Path $logs 'install-20261005-060000.log'
            $writeTranscript = "Set-Content -LiteralPath '$transcriptPath' -Value @('Summary:', 'Auto-updates: $Line'); "
        }
        $installer = New-StandInInstaller -Body ($writeTranscript + "Write-Host 'stand-in installer'; exit 8")

        $output = & $script:Pwsh -NoProfile -File $script:InstallPassScript -Pass first -Shell pwsh -Entry File -Source checkout -KnownPlatformIncompatible '' -InstallerPath $installer -LogDirectory $logs 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be $Expected
        ($output -join "`n") | Should -Match 'First install pass exited 8'
    }

    It 'Exits 64 without a pass, shell and entry' {
        $null = & $script:Pwsh -NoProfile -File $script:InstallPassScript 2>&1
        $LASTEXITCODE | Should -Be 64
    }
}

# E2E run 37518954302: Assert-Install.ps1 decided applicability after the install, but the run
# decided it before its Windows Terminal step changed what Terminal's condition reads.
Describe 'The applicability record taken before each pass' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $script:InstallPassAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallPassScript, [ref]$tokens, [ref]$parseErrors)
        $script:Workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
    }

    It 'Is written before the installer starts' {
        $save = @($script:InstallPassAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Save-ApplicabilityRecord' }, $true))
        $start = @($script:InstallPassAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Ampersand' -and $node.CommandElements[0].Extent.Text -eq '$command.FilePath' }, $true))

        $save.Count | Should -Be 1
        $start.Count | Should -Be 1
        $save[0].Extent.Text | Should -Match '-Path \$ApplicabilityPath\b'
        $save[0].Extent.StartOffset | Should -BeLessThan $start[0].Extent.StartOffset
    }

    # The child imports the real module, so on Windows it reads this machine (read-only CIM, Appx
    # and HKCU queries); the test asserts only the record's shape and timing, never its values.
    It 'Is there, with the module''s answer, when the installer starts' {
        $record = Join-Path $TestDrive 'e2e-applicability-second.json'
        Set-Content -LiteralPath $record -Value 'stale'
        $quotedRecord = "'" + $record.Replace("'", "''") + "'"
        $installer = New-StandInInstaller -Body "if ((Get-Content -Raw -LiteralPath $quotedRecord) -match 'NotApplicable') { Write-Host 'record present' }; exit 0"

        $output = & $script:Pwsh -NoProfile -File $script:InstallPassScript -Pass second -Shell pwsh -Entry File -Source checkout -KnownPlatformIncompatible '' -InstallerPath $installer -ApplicabilityPath $record 2>&1
        $exitCode = $LASTEXITCODE
        $saved = Get-Content -Raw -LiteralPath $record | ConvertFrom-Json

        $exitCode | Should -Be 0
        ($output -join "`n") | Should -Match 'record present'
        ($output -join "`n") | Should -Match 'Recorded which apps apply before the second pass in '
        $saved.Label | Should -Be 'before the second pass'
        $saved.PSObject.Properties.Name | Should -Contain 'NotApplicable'
        $saved.PSObject.Properties.Name | Should -Contain 'UngatedNotApplicable'
    }

    It 'Is passed to every install pass of the workflow, one file per pass' {
        $passCalls = [regex]::Matches($script:Workflow, '(?m)Invoke-InstallPass\.ps1 -Pass (?<pass>first|second)\b.*$')

        $passCalls.Count | Should -Be 4
        foreach ($call in $passCalls) {
            $call.Value | Should -Match ([regex]::Escape(("-ApplicabilityPath (Join-Path `$env:RUNNER_TEMP 'e2e-applicability-{0}.json')" -f $call.Groups['pass'].Value)))
        }
    }

    It 'Is read by <Step> from the second pass only when that pass ran' -ForEach @(
        @{ Step = 'Run assertions (e2e/Assert-Install.ps1, shared with tier 2)' }
        @{ Step = 'Run assertions (e2e/Assert-Install.ps1, with the bootstrap checks)' }
    ) {
        $stepPattern = '(?ms)^\s+- name: ' + [regex]::Escape($Step) + '\r?\n(?<body>.*?)(?=^\s+- name: |\z)'
        $body = [regex]::Match($script:Workflow, $stepPattern).Groups['body'].Value
        $secondPassRan = [regex]::Match($body, "(?ms)if \(\`$env:SECOND_PASS_OUTCOME -eq 'success' -or \`$env:SECOND_PASS_OUTCOME -eq 'failure'\) \{(?<then>[^}]*)\}")

        $body | Should -Match "(?m)^\s+\`$latestPass = 'first'\s*$"
        $secondPassRan.Success | Should -BeTrue
        $secondPassRan.Groups['then'].Value | Should -Match 'ExpectAllSkippedOnSecondRun'
        $secondPassRan.Groups['then'].Value | Should -Match "\`$latestPass = 'second'"
        $body | Should -Match ([regex]::Escape('$assertArgs += @(''-ApplicabilityPath'', (Join-Path $env:RUNNER_TEMP "e2e-applicability-$latestPass.json"))'))
    }
}

Describe 'e2e scripts run by Windows PowerShell 5.1' {
    It 'Stays runnable by Windows PowerShell 5.1: <Name> is ASCII only, parses cleanly, no PowerShell 7-only operators' -ForEach @(
        @{ Name = 'e2e/Invoke-InstallPass.ps1' }
        @{ Name = 'e2e/Remove-PreinstalledApps.ps1' }
        @{ Name = 'e2e/TranscriptAssertions.ps1' }
        @{ Name = 'e2e/Invoke-SystemInstallPass.ps1' }
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
