# EntryPoint.Tests.ps1
# Tests for the distribution surface around the module: the generated winget-app-install.ps1
# entry script (head/tail fragments, build stamp, transcript wiring, switch forwarding, IEX
# behavior), build determinism, and the psd1 module export surface.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # Child-process helpers for the entry-block tests below, which run the generated installer's
    # real tail.ps1 logic in a separate pwsh, so its `exit` ends that child and not this test run.
    $script:currentPowerShell = (Get-Process -Id $PID).Path
    $script:installerText = Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath

    # Builds a copy of the generated installer with function overrides injected just before the
    # entry block, so the real tail.ps1 logic runs unchanged. -Body replaces Invoke-WingetInstall;
    # -Overrides adds further definitions, which win over the defaults here because they come later.
    # -EmulateWindowsPowerShell sends the run down the entry block's Windows PowerShell 5.1 branch
    # (the PowerShell 7 bootstrap) under this pwsh: $PSVersionTable is read-only, so the version
    # test itself is rewritten. Override Invoke-PowerShell7Bootstrap with it.
    function New-FaultInjectedInstaller {
        param ([string]$Name, [string]$Body, [string]$Overrides = '', [switch]$EmulateWindowsPowerShell)
        $text = $script:installerText
        if ($EmulateWindowsPowerShell) {
            $versionTest = 'if ($PSVersionTable.PSVersion.Major -lt 7) {'
            $text.Contains($versionTest) | Should -BeTrue
            $text = $text.Replace($versionTest, 'if ($true) {')
        }
        $entryIndex = $text.LastIndexOf("if (`$MyInvocation.InvocationName -ne '.') {")
        $entryIndex | Should -BeGreaterThan 0
        # Test-SystemRequirements is stubbed too: an irm | iex run cannot pass -SkipSystemCheck,
        # and the real pre-flight checks probe the network and the OS. Grant-InstallLogReadAccess
        # is stubbed because it runs icacls on the log folder in an elevated run (Windows-only, and
        # a test has no business changing ACLs); its own tests are in Logging.Tests.ps1.
        $override = "function Test-SystemRequirements { param([switch]`$WhatIf) `$true }`n"
        $override += "function Grant-InstallLogReadAccess { param([string]`$Path) `$true }`n"
        if ($PSBoundParameters.ContainsKey('Body')) {
            $override += "function Invoke-WingetInstall { param([switch]`$WhatIf, [switch]`$NonInteractive, [switch]`$SkipSystemCheck) $Body }`n"
        }
        $override += "$Overrides`n"
        $path = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $path -Value ($text.Insert($entryIndex, $override)) -Encoding UTF8
        $path
    }

    # The transcripts a child run left under its TestDrive ProgramData.
    function Get-ChildTranscript {
        param ([string]$Filter = 'install-*.log')
        @(Get-ChildItem -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Filter $Filter -ErrorAction SilentlyContinue)
    }

    # Runs a child pwsh with the transcript pointed into TestDrive (never the real ProgramData).
    function Invoke-ChildInstaller {
        param ([string[]]$Arguments)
        $savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive 'ProgramData'
        try {
            $output = & $script:currentPowerShell -NoLogo -NoProfile -NonInteractive @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            $env:ProgramData = $savedProgramData
        }
    }

    # The same child run through `Get-Content | Invoke-Expression`, the shape of the irm | iex
    # one-liner (no script path, so Test-IsRunningLocally is false), non-interactive like RMM or CI.
    function Invoke-ChildInstallerViaIex {
        param ([string]$Path)
        $escapedPath = $Path.Replace("'", "''")
        Invoke-ChildInstaller -Arguments @('-Command', "Get-Content -Raw -LiteralPath '$escapedPath' | Invoke-Expression")
    }
}

Describe 'Module export surface (issue #191)' {
    # The psd1 FunctionsToExport list is the single export authority; the psm1 reads it and the
    # build asserts it matches Public/*.ps1. These tests pin the reconciled surface.
    It 'No longer defines the dead ConvertTo-CommandArguments helper' {
        # Remnant of the removed homegrown updater; it had no production callers.
        Test-Path Function:\ConvertTo-CommandArguments | Should -Be $false
    }

    It 'No longer exports module-internal helpers moved to Private/' {
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        $manifest.FunctionsToExport | Should -Not -Contain 'Write-Prompt'
        $manifest.FunctionsToExport | Should -Not -Contain 'ConvertFrom-TerminalSettingsJson'
    }

    It 'Still exports the logging helpers consumed by winget-app-uninstall.ps1' {
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        foreach ($helper in @('Write-Info', 'Write-Success', 'Write-WarningMessage', 'Write-ErrorMessage', 'Format-AppList', 'Write-Table')) {
            $manifest.FunctionsToExport | Should -Contain $helper
        }
    }

    It 'FunctionsToExport exactly matches the functions defined under Public/*.ps1' {
        # Cross-platform mirror of the Build-WingetInstallScript.ps1 export assertion.
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        $publicFunctionNames = Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1' | ForEach-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                ForEach-Object { $_.Name }
        }
        ($manifest.FunctionsToExport | Sort-Object) | Should -Be ($publicFunctionNames | Sort-Object)
    }
}

Describe 'SkipSystemCheck elevation forwarding (issue #185)' {
    Context 'Invoke-WingetInstall parameter surface' {
        It 'Should accept a SkipSystemCheck switch parameter' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('SkipSystemCheck') | Should -Be $true
            $command.Parameters['SkipSystemCheck'].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    Context 'Generated installer entry point' {
        It 'Should forward -SkipSystemCheck from the entry script into Invoke-WingetInstall' {
            $installer = Get-Content $script:InstallerScriptPath -Raw
            $installer | Should -Match 'Invoke-WingetInstall -WhatIf:\$WhatIf -NonInteractive:\$NonInteractive -SkipSystemCheck:\$SkipSystemCheck'
        }
    }
}

Describe 'Generated installer: build stamp and transcript wiring (issue #189)' {
    BeforeAll {
        $script:generatedInstaller = Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath
    }

    It 'Stamps a content-derived $script:InstallerBuildId matching the module version' {
        $moduleVersion = (Import-PowerShellDataFile -Path (Join-Path $script:WingetAppSetupRoot 'WingetAppSetup.psd1')).ModuleVersion
        $expectedPattern = [regex]::Escape("`$script:InstallerBuildId = '$moduleVersion+") + '[0-9a-f]{8}'''

        $script:generatedInstaller | Should -Match $expectedPattern
    }

    It 'Wraps the dispatch in a transcript under ProgramData that never blocks the install' {
        # File naming and the never-blocks rule are tested on Start-InstallerTranscript itself
        # (Logging.Tests.ps1); here, that the entry block starts it for both phases and stops it.
        $script:generatedInstaller | Should -Match ([regex]::Escape('$script:InstallLogPath = Start-InstallerTranscript -WhatIf:$WhatIf'))
        $script:generatedInstaller | Should -Match ([regex]::Escape('$script:InstallLogPath = Start-InstallerTranscript -Bootstrap -WhatIf:$WhatIf'))
        $script:generatedInstaller | Should -Match 'Stop-Transcript'
    }

    It 'Writes the transcript of a dry run under ProgramData with a -whatif suffix' {
        $path = New-FaultInjectedInstaller -Name 'dry-run-transcript.ps1' -Body "Write-Host 'dry run finished'; return 0"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-WhatIf', '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 0
        $transcripts = Get-ChildTranscript
        $transcripts.Name | Should -Match '^install-\d{8}-\d{6}-whatif\.log$'
        $result.Output | Should -Match ('Logging this run to: ' + [regex]::Escape($transcripts[0].FullName))
    }

    It 'Logs the log path and the build id at startup' {
        $script:generatedInstaller | Should -Match ([regex]::Escape('Write-Info "Logging this run to: $script:InstallLogPath"'))
        $script:generatedInstaller | Should -Match ([regex]::Escape('Write-Info "Installer build: $script:InstallerBuildId"'))
    }
}

Describe 'Generated installer: Windows PowerShell 5.1 parse safety (issue #210)' {
    # The installer ships as BOM-less UTF-8. Windows PowerShell 5.1 decodes a BOM-less file as
    # ANSI, so a multi-byte character inside a string literal misdecodes - and some byte sequences
    # terminate the string early (an em dash's 0x94 byte becomes a closing curly quote), cascading
    # into dozens of parser errors. Non-comment tokens must therefore stay pure ASCII so 5.1 can
    # parse the file and reach the PowerShell-7 fail-fast in the dispatch. Comments are exempt:
    # misdecoded bytes there cannot change tokenization.
    BeforeDiscovery {
        # Discovery-time (not BeforeAll) because -Skip is bound during discovery.
        $script:winPowerShellAvailable = [bool](Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
        $script:pwshAvailableForRelaunch = [bool](Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
        # The live-relaunch test is OPT-IN: it drives the machine's real pwsh through a full
        # -WhatIf pipeline (real winget presence probes, a transcript under ProgramData), which
        # violates the "unit tests never touch real system state" rule for a default run and has
        # environment-dependent timing. Enable it explicitly when touching the bootstrap:
        #   $env:WINGET_APP_SETUP_RUN_51_RELAUNCH_TEST = '1'; Invoke-Pester ./tests/EntryPoint.Tests.ps1
        $script:runLiveRelaunchTest = ($env:WINGET_APP_SETUP_RUN_51_RELAUNCH_TEST -eq '1')
    }

    It 'Contains no non-ASCII characters outside comment tokens (same rule the build enforces)' {
        $content = Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors) | Out-Null
        $parseErrors | Should -BeNullOrEmpty

        $offending = @($tokens |
                Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -match '[^\x00-\x7F]' } |
                ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Kind) token" })
        $offending | Should -BeNullOrEmpty
    }

    It 'Parses with zero errors under real Windows PowerShell 5.1' -Skip:(-not $script:winPowerShellAvailable) {
        $escapedPath = $script:InstallerScriptPath.Replace("'", "''")
        $probe = "`$t=`$null;`$e=`$null;[System.Management.Automation.Language.Parser]::ParseFile('$escapedPath',[ref]`$t,[ref]`$e)|Out-Null;`$e.Count;`$e|ForEach-Object{`$_.Extent.StartLineNumber.ToString()+': '+`$_.Message}"
        $output = @(& powershell.exe -NoProfile -NonInteractive -Command $probe)
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        # First output line is the parse-error count; any further lines describe the errors.
        $output[0] | Should -Be '0' -Because ("Windows PowerShell 5.1 reported parse errors:`n" + ($output -join "`n"))
    }

    It 'Under 5.1 with no pwsh discoverable, -WhatIf previews the bootstrap and exits 0' -Skip:(-not $script:winPowerShellAvailable) {
        # NEVER run the installer BARE under 5.1 in a test: since issue #225 the 5.1 branch
        # bootstraps - on a pwsh-equipped machine it would relaunch into a REAL install. This
        # test poisons the child's lookup environment (PATH without pwsh; nonexistent
        # ProgramFiles/ProgramW6432/LOCALAPPDATA roots) so Find-PowerShell7 cannot resolve
        # anything, and passes -WhatIf, which returns before any install attempt - exercising
        # the no-pwsh preview path with zero side effects. ProgramData points into TestDrive, where
        # the bootstrap phase writes its own transcript (review finding P2-13).
        $escapedPath = $script:InstallerScriptPath.Replace("'", "''")
        $programData = Join-Path $TestDrive 'ProgramData-51-preview'
        $escapedProgramData = $programData.Replace("'", "''")
        $childCommand = "& { `$env:PATH = 'C:\Windows\System32'; `$env:ProgramFiles = 'C:\__was_no_such_dir__'; `$env:ProgramW6432 = 'C:\__was_no_such_dir__'; `$env:LOCALAPPDATA = 'C:\__was_no_such_dir__'; `$env:ProgramData = '$escapedProgramData'; & '$escapedPath' -WhatIf }"
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $childCommand 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $output | Should -Match 'requires PowerShell 7\+'
        $output | Should -Match '\[DRY-RUN\] PowerShell 7 is not installed'
        # The PowerShell 7 run's transcript never starts; the bootstrap phase's does, under 5.1.
        $output | Should -Not -Match 'Logging this run to:'
        $output | Should -Match 'Logging the PowerShell 7 bootstrap to:'
        $bootstrapLogs = @(Get-ChildItem -Path $programData -Recurse -Filter 'install-*-bootstrap-whatif.log')
        $bootstrapLogs.Count | Should -Be 1
        (Get-Content -Raw -LiteralPath $bootstrapLogs[0].FullName) | Should -Match '\[DRY-RUN\] PowerShell 7 is not installed'
    }

    It 'Under 5.1 with pwsh available, relaunches under pwsh and forwards the switches (opt-in)' -Skip:(-not $script:winPowerShellAvailable -or -not $script:pwshAvailableForRelaunch -or -not $script:runLiveRelaunchTest) {
        # Real end-to-end handoff (issue #225): 5.1 finds the machine's pwsh and relaunches the
        # installer in the same console. -WhatIf keeps the child side-effect-free (it does write
        # a -whatif transcript under ProgramData - the designed dry-run artifact),
        # -SkipSystemCheck keeps it fast (~20s), and -NonInteractive is REQUIRED here: without
        # it, a run from an interactive console would hit the dry run's prompts and hang the
        # suite. Opt-in only (see BeforeDiscovery) - default runs cover the dispatch with the
        # poisoned-env test above and the mocked suite in PowerShell7Bootstrap.Tests.ps1.
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:InstallerScriptPath -WhatIf -SkipSystemCheck -NonInteractive 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $output | Should -Match 'Relaunching the installer under PowerShell 7'
        # Proof the switches crossed the relaunch boundary: the child announced dry-run mode.
        $output | Should -Match 'DRY-RUN MODE ENABLED'
    }

    It 'Carries the PowerShell 7 bootstrap dispatch at the top of the entry block' {
        # Cross-platform pin of the guard's presence for environments without powershell.exe. What
        # the branch does is run under pwsh by the 'Windows PowerShell 5.1 bootstrap phase' tests.
        $installer = Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath
        $installer | Should -Match ([regex]::Escape('if ($PSVersionTable.PSVersion.Major -lt 7)'))
        $installer | Should -Match ([regex]::Escape('$bootstrapExitCode = Invoke-PowerShell7Bootstrap -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck -CommandPath $PSCommandPath -ExpectedBuildId $script:InstallerBuildId -LogDirectory $bootstrapLogDirectory'))
        $installer | Should -Match 'This installer requires PowerShell 7\+ \(pwsh\)'
    }
}

Describe 'Aborted runs exit non-zero (review P1: tail.ps1 try/finally exited 0)' {
    It 'Exits 5 and logs the error with a stack trace when an unexpected .NET error aborts the run' {
        $path = New-FaultInjectedInstaller -Name 'net-error.ps1' -Body "[int]::Parse('not-a-number')"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'UNEXPECTED ERROR - the run was aborted before it finished'
        $result.Output | Should -Match 'Stack trace:'
        $transcript = Get-ChildItem -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Filter 'install-*.log' | Select-Object -First 1
        $transcript | Should -Not -BeNullOrEmpty
        (Get-Content -Raw -LiteralPath $transcript.FullName) | Should -Match 'Stack trace:'
    }

    It 'Exits 5 when the run is stopped from outside (PipelineStoppedException cannot be caught)' {
        $path = New-FaultInjectedInstaller -Name 'stopped.ps1' -Body 'throw [System.Management.Automation.PipelineStoppedException]::new()'

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'The run was stopped before it finished'
    }

    It 'Keeps the decided exit code when the run is stopped at the final prompt' {
        # Invoke-WingetInstall records InstallerPendingExitCode before 'Press any key to exit';
        # Ctrl+C there must not turn a finished run into an abort (5).
        $path = New-FaultInjectedInstaller -Name 'stopped-at-prompt.ps1' -Body '$script:InstallerPendingExitCode = 1; throw [System.Management.Automation.PipelineStoppedException]::new()'

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Not -Match 'stopped before it finished'
    }

    It 'Only force-exits after an unexpected error where the process ends anyway (file or non-interactive run)' {
        # In an interactive console (irm | iex, or .\winget-app-install.ps1 typed at a prompt),
        # exiting would close the window and the error with it.
        $script:installerText | Should -Match '(?s)if \(\$forceExitCodeOnAbort\) \{\s*Exit-Installer -Code 5 -NonInteractive:\$NonInteractive\s*\}'
        $script:installerText | Should -Match '\$forceExitCodeOnAbort = \$launchedForScript -or \(Test-EffectiveNonInteractive'
    }

    It 'Exits 0 when the run completes normally' {
        $path = New-FaultInjectedInstaller -Name 'completed.ps1' -Body "Write-Host 'run finished'; return 0"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'run finished'
    }

    It 'Exits 5 for an unexpected error under irm | iex too (non-interactive, e.g. RMM or CI)' {
        $path = New-FaultInjectedInstaller -Name 'net-error-iex.ps1' -Body "[int]::Parse('not-a-number')"

        $result = Invoke-ChildInstallerViaIex -Path $path

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'UNEXPECTED ERROR'
    }
}

# Invoke-WingetInstall returns its exit code instead of calling `exit` itself (wgt-gq8.6); the
# entry block exits with it. Which code each path returns is covered in-process in
# tests/Install.Tests.ps1; these check the hand-off in a real child process.
Describe 'The entry block exits with the code Invoke-WingetInstall returns (wgt-gq8.6)' {
    It 'Exits <_> when Invoke-WingetInstall returns <_>, without reporting an abort' -ForEach @(1, 2, 3) {
        $path = New-FaultInjectedInstaller -Name "returns-$_.ps1" -Body "return $_"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be $_
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished'
    }

    It 'Exits with the returned code under irm | iex too (non-interactive, e.g. RMM or CI)' {
        $path = New-FaultInjectedInstaller -Name 'returns-2-iex.ps1' -Body 'return 2'

        $result = Invoke-ChildInstallerViaIex -Path $path

        $result.ExitCode | Should -Be 2
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished'
    }

    It 'Does not exit after a successful irm | iex run, so the caller''s console stays open' {
        # Someone who typed the one-liner in a console must keep that console after a success:
        # under Invoke-Expression an exit ends the caller's host, closing the window. The exit
        # code alone cannot show this (a -File run ends with 0 either way), so the caller runs a
        # command after the iex and the test checks that it still ran.
        $path = New-FaultInjectedInstaller -Name 'returns-0-iex.ps1' -Body "Write-Host 'run finished'; return 0"
        $escapedPath = $path.Replace("'", "''")

        $result = Invoke-ChildInstaller -Arguments @('-Command', "Get-Content -Raw -LiteralPath '$escapedPath' | Invoke-Expression; Write-Host 'caller session continues'")

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'run finished'
        $result.Output | Should -Match 'caller session continues'
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished'
    }

    It 'Exits with the returned code, not a value a helper leaked into the output stream before it' {
        $path = New-FaultInjectedInstaller -Name 'leaks-then-returns.ps1' -Body "Write-Output 'stray value'; Write-Output 7; return 3"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 3
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR'
    }

    It 'Exits 1 without running the install when a blocking pre-flight check fails' {
        $path = New-FaultInjectedInstaller -Name 'preflight-fails.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides "function Test-SystemRequirements { param([switch]`$WhatIf) `$false }"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Not -Match 'install ran'
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished'
        $result.Output | Should -Match 'stopped early with exit code 1: a blocking pre-flight system check failed'
    }

    It 'Exits 1 with the remote elevation guidance when an irm | iex run is not elevated (issues #226/#229)' {
        # The real Invoke-WingetInstall, with Test-IsAdmin overridden instead of depending on the
        # runner: CI is elevated, so the old version of this test (gated on real elevation) never
        # ran there. Under Invoke-Expression there is no script path to relaunch from, so the run
        # stops at the elevation gate.
        $path = New-FaultInjectedInstaller -Name 'iex-not-elevated.ps1' -Overrides "function Test-IsAdmin { `$false }"

        $result = Invoke-ChildInstallerViaIex -Path $path

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'This script requires administrator privileges\.'
        $result.Output | Should -Match 'Auto-elevation is unavailable when running through IEX/remote execution\.'
        $result.Output | Should -Match 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again\.'
        # The early-exit notice replaced the old 5-second sleep (review finding P2-14).
        $result.Output | Should -Match 'The installer stopped early with exit code 1'
        $result.Output | Should -Not -Match 'Exiting in 5 seconds'
        $result.Output | Should -Not -Match 'Press Enter to restart script with elevated privileges'
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished'
    }
}

# Review finding P2-14: under irm | iex an early exit ends the host, so the window used to close
# before the teammate could read the error or the log path.
Describe 'Early exits explain themselves before the window closes (review finding P2-14)' {
    BeforeAll {
        $script:installerText -match "\`$script:InstallerBuildId = '([^']+)'" | Should -BeTrue
        $script:buildId = $Matches[1]

        # The log file a child run printed, read back.
        function Get-PrintedLog {
            param ([string]$Output, [string]$Label)
            $Output -match ([regex]::Escape($Label) + '\s*([^\r\n\x1b]+?\.log)') | Should -BeTrue -Because "the run prints '$Label <path>'"
            $logPath = $Matches[1].Trim()
            Test-Path -LiteralPath $logPath | Should -BeTrue
            Get-Content -Raw -LiteralPath $logPath
        }
    }

    It 'Prints the exit code, the log file, the build and where to report it, for exit code <_>' -ForEach @(1, 2, 3) {
        $path = New-FaultInjectedInstaller -Name "early-exit-$_.ps1" -Body "Write-ErrorMessage 'early failure'; return $_"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be $_
        $result.Output | Should -Match "The installer stopped early with exit code ${_}: "
        $result.Output | Should -Match ('Installer build: ' + [regex]::Escape($script:buildId))
        $result.Output | Should -Match 'issues/new\?template=install-failure\.yml'
        $result.Output | Should -Match 'remove or redact the log''s header'
        # The notice is in the log the teammate attaches, too.
        Get-PrintedLog -Output $result.Output -Label 'Log file:' | Should -Match "stopped early with exit code $_"
        # -NonInteractive: nothing waits for a key press.
        $result.Output | Should -Not -Match 'Press any key'
    }

    It 'Explains an aborted run (exit code 5) the same way' {
        $path = New-FaultInjectedInstaller -Name 'abort-notice.ps1' -Body "[int]::Parse('not-a-number')"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'The installer stopped early with exit code 5: the run was aborted before it finished'
    }

    It 'Adds nothing after a run that reached its summary (it showed its outcome and its own prompt)' {
        $path = New-FaultInjectedInstaller -Name 'summary-shown.ps1' -Body "`$script:InstallerPendingExitCode = 1; Write-Host 'summary shown'; return 1"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'summary shown'
        $result.Output | Should -Not -Match 'stopped early'
    }

    Context 'Waiting for a key press' {
        BeforeAll {
            # The child's console is not interactive, so its interactivity is overridden; Write-Prompt
            # throws so the child never reaches [Console]::ReadKey (Exit-Installer still exits with
            # the code when the notice fails).
            $script:interactiveOverrides = (
                "function Test-EffectiveNonInteractive { param([switch]`$NonInteractive) `$false }`n" +
                "function Write-Prompt { param([string]`$Message) Write-Host ""PROMPT: `$Message""; throw 'no key press in tests' }")
        }

        It 'Waits for a key press when someone is at the console, then exits with the code' {
            $path = New-FaultInjectedInstaller -Name 'interactive-early-exit.ps1' -Body 'return 2' -Overrides (
                $script:interactiveOverrides + "`nfunction Test-IsContinuousIntegration { `$false }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'stopped early with exit code 2'
            $result.Output | Should -Match 'PROMPT: Press any key to exit\.\.\.'
        }

        It 'Never waits under CI' {
            $path = New-FaultInjectedInstaller -Name 'ci-early-exit.ps1' -Body 'return 2' -Overrides (
                $script:interactiveOverrides + "`nfunction Test-IsContinuousIntegration { `$true }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'stopped early with exit code 2'
            $result.Output | Should -Not -Match 'PROMPT:'
        }
    }

    # The entry block's Windows PowerShell 5.1 branch, run under pwsh (see
    # New-FaultInjectedInstaller -EmulateWindowsPowerShell) with Invoke-PowerShell7Bootstrap
    # overridden. Invoke-WingetInstall is overridden too, so a fall-through into the PowerShell 7
    # body would print 'install ran'.
    Context 'Windows PowerShell 5.1 bootstrap phase (review findings P2-13 and P2-14)' {
        BeforeAll {
            $script:bootstrapSignature = 'param([switch]$WhatIf, [switch]$NonInteractive, [switch]$SkipSystemCheck, [string]$CommandPath, [string]$ExpectedBuildId, [string]$LogDirectory)'
        }

        It 'Logs the bootstrap to its own transcript, hands msiexec that folder, and explains a failure' {
            $path = New-FaultInjectedInstaller -Name 'bootstrap-fails.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (
                "function Invoke-PowerShell7Bootstrap { $($script:bootstrapSignature) Write-Host ""bootstrap log folder: [`$LogDirectory]""; Write-ErrorMessage 'PowerShell 7 could not be installed automatically.'; return 7 }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

            $result.ExitCode | Should -Be 7
            $result.Output | Should -Not -Match 'install ran|Logging this run to:'
            $result.Output | Should -Match 'Logging the PowerShell 7 bootstrap to: [^\r\n]*install-\d{8}-\d{6}-bootstrap\.log'
            $result.Output | Should -Match 'The installer stopped early with exit code 7: PowerShell 7 could not be installed, or the installer could not be relaunched under it'
            $bootstrapLog = Get-PrintedLog -Output $result.Output -Label 'Logging the PowerShell 7 bootstrap to:'
            $bootstrapLog | Should -Match ('Installer build: ' + [regex]::Escape($script:buildId))
            $bootstrapLog | Should -Match 'PowerShell 7 could not be installed automatically'
            $bootstrapLog | Should -Match 'stopped early with exit code 7'
            $result.Output -match 'Logging the PowerShell 7 bootstrap to:\s*([^\r\n\x1b]+?)[\\/]install-' | Should -BeTrue
            $result.Output | Should -Match ('bootstrap log folder: \[' + [regex]::Escape($Matches[1].Trim()) + '\]')
        }

        It 'Exits with the relaunched run''s code and adds nothing to the outcome it reported' {
            $path = New-FaultInjectedInstaller -Name 'bootstrap-relaunched.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (
                "function Invoke-PowerShell7Bootstrap { $($script:bootstrapSignature) `$script:PowerShell7BootstrapRelaunched = `$true; return 3 }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-WhatIf', '-NonInteractive')

            $result.ExitCode | Should -Be 3
            $result.Output | Should -Not -Match 'install ran|stopped early'
            $result.Output | Should -Match 'Logging the PowerShell 7 bootstrap to: [^\r\n]*install-\d{8}-\d{6}-bootstrap-whatif\.log'
        }

        It 'Hands the bootstrap the running build id, so an irm | iex relaunch runs this same build (review finding P2-18)' {
            $path = New-FaultInjectedInstaller -Name 'bootstrap-build-id.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (
                "function Invoke-PowerShell7Bootstrap { $($script:bootstrapSignature) Write-Host ""expected build: [`$ExpectedBuildId]""; `$script:PowerShell7BootstrapRelaunched = `$true; return 0 }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match ('expected build: \[' + [regex]::Escape($script:buildId) + '\]')
        }

        It 'Exits 7 with the notice when the bootstrap throws, never falling through' {
            $path = New-FaultInjectedInstaller -Name 'bootstrap-throws.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (
                "function Invoke-PowerShell7Bootstrap { $($script:bootstrapSignature) throw 'bootstrap exploded' }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

            $result.ExitCode | Should -Be 7
            $result.Output | Should -Match 'The PowerShell 7 bootstrap failed unexpectedly: bootstrap exploded'
            $result.Output | Should -Match 'The installer stopped early with exit code 7'
            $result.Output | Should -Not -Match 'install ran'
        }

        It 'Exits 5 when the bootstrap is stopped from outside' {
            $path = New-FaultInjectedInstaller -Name 'bootstrap-stopped.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (
                "function Invoke-PowerShell7Bootstrap { $($script:bootstrapSignature) throw [System.Management.Automation.PipelineStoppedException]::new() }")

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

            $result.ExitCode | Should -Be 5
            $result.Output | Should -Not -Match 'install ran'
        }
    }
}

Describe 'Build determinism (issue #189)' {
    BeforeAll {
        $script:buildScriptPath = Join-Path $script:RepoRoot 'build/Build-WingetInstallScript.ps1'
        $script:currentPowerShell = (Get-Process -Id $PID).Path
    }

    It 'Produces byte-identical output when the same tree is built twice' {
        # The build id must derive from CONTENT only (module version + functions hash) — anything
        # time- or git-based would make every rebuild differ and permanently break the CI -Check
        # byte-compare. Verified the way CI would notice: build twice, compare bytes.
        $firstOutput = Join-Path $TestDrive 'installer-build-one.ps1'
        $secondOutput = Join-Path $TestDrive 'installer-build-two.ps1'

        & $script:currentPowerShell -NoProfile -File $script:buildScriptPath -OutputPath $firstOutput | Out-Null
        $LASTEXITCODE | Should -Be 0
        & $script:currentPowerShell -NoProfile -File $script:buildScriptPath -OutputPath $secondOutput | Out-Null
        $LASTEXITCODE | Should -Be 0

        (Get-FileHash -Path $firstOutput -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -Path $secondOutput -Algorithm SHA256).Hash
    }
}
