# EntryPoint.Tests.ps1
# Tests for the distribution surface around the module: the generated winget-app-install.ps1
# entry script (head/tail fragments, build stamp, transcript wiring, switch forwarding, IEX
# behavior), the generated winget-app-uninstall.ps1's parse safety and elevated relaunch, build
# determinism, and the psd1 module export surface.
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
    # The run lock name every child run below uses (review finding P3-41), never the real one.
    $script:testRunLockName = 'Global\winget-app-setup-test-' + [Guid]::NewGuid().ToString('N')

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
        # and the real pre-flight checks probe the network and the OS. Initialize-ProgramDataFolder
        # is stubbed to just create the folder because it runs icacls on the log folder in an
        # elevated run (Windows-only, and a test has no business changing ACLs); its own tests are
        # in ProgramDataFolder.Tests.ps1 and Logging.Tests.ps1.
        # Invoke-InstallerHousekeeping is stubbed because it prunes the account's temp folder and
        # %SystemRoot%\Temp (its own tests are in Housekeeping.Tests.ps1), and the run lock gets a
        # name of this test run's own, so a child never contends with a real run on the machine.
        $override = "function Test-SystemRequirements { param([switch]`$WhatIf) `$true }`n"
        $override += "function Initialize-ProgramDataFolder { param([string]`$ChildName, [switch]`$ReadableByUsers) `$path = Join-Path (Join-Path `$env:ProgramData 'winget-app-setup') `$ChildName; [void](New-Item -ItemType Directory -Path `$path -Force); `$path }`n"
        $override += "function Invoke-InstallerHousekeeping { param([string]`$CurrentScriptPath) Write-Host ""HOUSEKEEPING RAN: `$CurrentScriptPath"" }`n"
        $override += "function Get-InstallerRunLockName { '$($script:testRunLockName)' }`n"
        # The environment pre-flight's registry reads (wgt-gq8.39): no Group Policy execution policy
        # and no proxy to report, never the runner's own.
        $override += "function Get-ScriptExecutionPolicyBlock { param([string]`$Engine) `$null }`n"
        $override += "function Get-ProxyInheritanceWarning { param(`$AccountContext) `$null }`n"
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

Describe 'Module export surface (review finding P3-44)' {
    It 'Exports every function the module defines, Public/ and Private/ alike, to a manifest import' {
        # FunctionsToExport is '*': an explicit list had to match Public/*.ps1, which a build check
        # enforced, and a function missing from it was filtered out of the uninstaller's import
        # without a word (#191).
        $definedFunctionNames = Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Public'), (Join-Path $script:WingetAppSetupRoot 'Private') -Filter '*.ps1' | ForEach-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                ForEach-Object { $_.Name }
        }

        $exported = @(Get-ManifestExportedFunctionName)

        $exported | Should -Contain 'Test-EffectiveNonInteractive'
        ($exported | Sort-Object) | Should -Be ($definedFunctionNames | Sort-Object)
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

# The uninstaller is a generated single file too (wgt-gq8.43), and it runs under Windows PowerShell
# 5.1 itself: its elevated window is System32's powershell.exe, with no PowerShell 7 bootstrap. So
# 5.1 must parse the whole file: ASCII-only code tokens and no PowerShell-7-only syntax.
Describe 'Generated uninstaller: Windows PowerShell 5.1 parse safety (wgt-gq8.43)' {
    BeforeDiscovery {
        $script:winPowerShellAvailable = [bool](Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
    }

    It 'Contains no non-ASCII characters outside comment tokens (same rule the build enforces)' {
        $content = Get-Content -Raw -Encoding UTF8 -Path $script:UninstallerScriptPath
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
        $escapedPath = $script:UninstallerScriptPath.Replace("'", "''")
        $probe = "`$t=`$null;`$e=`$null;[System.Management.Automation.Language.Parser]::ParseFile('$escapedPath',[ref]`$t,[ref]`$e)|Out-Null;`$e.Count;`$e|ForEach-Object{`$_.Extent.StartLineNumber.ToString()+': '+`$_.Message}"
        $output = @(& powershell.exe -NoProfile -NonInteractive -Command $probe)
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        # First output line is the parse-error count; any further lines describe the errors.
        $output[0] | Should -Be '0' -Because ($output -join "`n")
    }

    It 'Previews the uninstall under real Windows PowerShell 5.1, from the file alone' -Skip:(-not $script:winPowerShellAvailable) {
        # The generated file with everything that would read the machine replaced: 5.1 runs the
        # whole entry block, as the elevated window does, with nothing next to the file.
        $overrides = @'
function Test-IsAdmin { $false }
function Invoke-WingetUninstall { param ([switch]$WhatIf) Write-Host "UNINSTALL WhatIf=$([bool]$WhatIf) PS=$($PSVersionTable.PSVersion.Major)"; 0 }
function Wait-InstallerExitKeyPress { param ([switch]$NonInteractive) }
'@
        $path = New-TestUninstallerScript -Path (Join-Path $TestDrive 'uninstaller-51/winget-app-uninstall.ps1') -Overrides $overrides

        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path -WhatIf -NonInteractive 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because $output
        $output | Should -Match 'UNINSTALL WhatIf=True PS=5'
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

Describe 'Constrained Language Mode stops the run at once, in one line (wgt-gq8.39)' {
    BeforeAll {
        $script:clmLine = 'PowerShell runs this installer in ConstrainedLanguage mode on this PC, which an application control policy (App Control for Business/WDAC or AppLocker) sets for scripts it does not trust.'
        # A real run stopped here still reports (review finding P3-41): nothing counted, no log.
        $script:installerText -match "\`$script:InstallerBuildId = '([^']+)'" | Should -BeTrue
        $script:clmResultLine = "RESULT: exit=5 installed=0 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=NotRun restart=no build=$($Matches[1]) log=none"
        function Get-ClmResultLine {
            param ([string]$Output)
            @([regex]::Matches($Output, 'RESULT: [^\r\n]*') | ForEach-Object { $_.Value })
        }

        # Runs a command in a child pwsh whose session is put in Constrained Language Mode first, the
        # way an application control policy runs an untrusted script. A probe script reports the
        # mode a script file then runs in: where the platform runs it in FullLanguage anyway, the
        # child exits 99 and the test is skipped instead of running the installer for real.
        function Invoke-ChildUnderConstrainedLanguage {
            param ([string]$Command)
            $probe = Join-Path $TestDrive 'language-mode-probe.ps1'
            Set-Content -LiteralPath $probe -Value '[string]$ExecutionContext.SessionState.LanguageMode' -Encoding UTF8
            $escapedProbe = $probe.Replace("'", "''")
            $script = "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; if ((& '$escapedProbe') -ne 'ConstrainedLanguage') { exit 99 }; $Command"
            Invoke-ChildInstaller -Arguments @('-Command', $script)
        }
    }

    It 'Stops before the transcript, the build line and the run, with exit code 5 (the language-mode seam)' {
        $path = New-FaultInjectedInstaller -Name 'clm-seam.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides "function Get-PowerShellLanguageMode { 'ConstrainedLanguage' }"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match ([regex]::Escape($script:clmLine))
        $result.Output | Should -Not -Match 'install ran|Installer build:|Logging this run to:|UNEXPECTED ERROR'
        Get-ClmResultLine -Output $result.Output | Should -Be @($script:clmResultLine)
        $result.Output.IndexOf($script:clmLine) | Should -BeLessThan $result.Output.IndexOf('RESULT: ')
        Get-ChildTranscript | Should -HaveCount 0
    }

    It 'Prints no RESULT line for a dry run (-WhatIf), which reports nothing' {
        $path = New-FaultInjectedInstaller -Name 'clm-seam-whatif.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides "function Get-PowerShellLanguageMode { 'ConstrainedLanguage' }"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-WhatIf', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match ([regex]::Escape($script:clmLine))
        $result.Output | Should -Not -Match 'install ran|RESULT:'
    }

    It 'Stops before the Windows PowerShell 5.1 bootstrap too' {
        $path = New-FaultInjectedInstaller -Name 'clm-seam-51.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (
            "function Get-PowerShellLanguageMode { 'ConstrainedLanguage' }`n" +
            "function Invoke-PowerShell7Bootstrap { param([switch]`$WhatIf, [switch]`$NonInteractive, [switch]`$SkipSystemCheck, [string]`$CommandPath, [string]`$ExpectedBuildId, [string]`$LogDirectory) Write-Host 'bootstrap ran'; return 0 }")

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match ([regex]::Escape($script:clmLine))
        $result.Output | Should -Not -Match 'bootstrap ran|install ran|Logging the PowerShell 7 bootstrap'
        # No PowerShell 7 run follows to report, so this one does.
        Get-ClmResultLine -Output $result.Output | Should -Be @($script:clmResultLine)
    }

    It 'Says so in one line and exits 5 when the run really is in Constrained Language Mode, from a file' {
        $path = New-FaultInjectedInstaller -Name 'clm-real.ps1' -Body "Write-Host 'install ran'; return 0"
        $escapedPath = $path.Replace("'", "''")

        $result = Invoke-ChildUnderConstrainedLanguage -Command "& '$escapedPath' -WhatIf -NonInteractive; exit `$LASTEXITCODE"
        if ($result.ExitCode -eq 99) {
            Set-ItResult -Skipped -Because 'this platform runs a script file in FullLanguage mode even from a Constrained Language session'
            return
        }

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match ([regex]::Escape($script:clmLine))
        $result.Output | Should -Not -Match 'install ran|UNEXPECTED ERROR|Method invocation is supported only on core types|RESULT:'
    }

    It 'Exits 5 under irm | iex when nobody is at the console (an RMM job)' {
        $path = New-FaultInjectedInstaller -Name 'clm-real-iex.ps1' -Body "Write-Host 'install ran'; return 0"
        $escapedPath = $path.Replace("'", "''")

        $result = Invoke-ChildUnderConstrainedLanguage -Command "`$env:WINGET_APP_SETUP_NONINTERACTIVE = '1'; Get-Content -Raw -LiteralPath '$escapedPath' | Invoke-Expression; Write-Host 'console kept'"
        if ($result.ExitCode -eq 99) {
            Set-ItResult -Skipped -Because 'this platform runs a script file in FullLanguage mode even from a Constrained Language session'
            return
        }

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match ([regex]::Escape($script:clmLine))
        $result.Output | Should -Not -Match 'install ran|console kept|UNEXPECTED ERROR|Method invocation is supported only on core types'
        # A real run: its RESULT line, printed in Constrained Language Mode itself.
        Get-ClmResultLine -Output $result.Output | Should -Be @($script:clmResultLine)
    }

    It 'Keeps an interactive irm | iex console open, with $LASTEXITCODE 5, instead of closing it with the message' {
        # The branch the tests above cannot reach in a child process (stdin is redirected there):
        # pinned on the generated installer's text.
        $script:installerText | Should -Match '(?s)if \(-not \(Test-FullLanguageMode\)\) \{\s*\$global:LASTEXITCODE = 5\s*if \(-not \$WhatIf\) \{\s*try \{\s*Write-InstallerNotStartedResult -ExitCode 5\s*\}\s*catch \{[^{}]*\}\s*\}\s*\$exitForLanguageMode = \[bool\]\$PSCommandPath'
        $script:installerText | Should -Match '(?s)if \(\$exitForLanguageMode\) \{\s*exit 5\s*\}\s*return\s*\}'
        # Checked first: before the command-line probe, the first .NET call that Constrained Language
        # Mode refuses.
        $entryIndex = $script:installerText.LastIndexOf("if (`$MyInvocation.InvocationName -ne '.') {")
        $checkIndex = $script:installerText.IndexOf('if (-not (Test-FullLanguageMode)) {', $entryIndex)
        $checkIndex | Should -BeGreaterThan $entryIndex
        $checkIndex | Should -BeLessThan $script:installerText.IndexOf('[Environment]::GetCommandLineArgs()', $entryIndex)
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

    # 3010: success, restart required (review finding P3-16), which RMM tools read as a soft reboot.
    # Windows only: elsewhere a process exit code keeps only its low 8 bits (3010 arrives as 194).
    It 'Exits 3010 when Invoke-WingetInstall returns 3010 after its summary, without a failure notice' -Skip:(-not $IsWindows) {
        $path = New-FaultInjectedInstaller -Name 'returns-3010.ps1' -Body '$script:InstallerPendingExitCode = 3010; return 3010'

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 3010
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished|stopped early'
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

    It 'Leaves no TightVNC password in the caller''s console after an irm | iex run, whatever Invoke-WingetInstall left (work-order item 18)' {
        # Under Invoke-Expression the run's $script: scope is the console's global scope, which
        # stays open after the run, an abort included: the entry script's finally block drops the
        # passwords Initialize-TightVncSecretForRun kept, on every way out.
        $body = "`$secure = New-Object System.Security.SecureString; `$secure.AppendChar('x'); `$script:TightVncSecret = @{ Password = `$secure }; Write-Host 'secret kept'; return 0"
        $path = New-FaultInjectedInstaller -Name 'keeps-secret-iex.ps1' -Body $body
        $escapedPath = $path.Replace("'", "''")

        $result = Invoke-ChildInstaller -Arguments @('-Command', "Get-Content -Raw -LiteralPath '$escapedPath' | Invoke-Expression; Write-Host ('secret left in the console: ' + [bool](Get-Variable -Name TightVncSecret -Scope Global -ValueOnly -ErrorAction SilentlyContinue))")

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'secret kept'
        $result.Output | Should -Match 'secret left in the console: False'
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

    It 'Exits 4 with the remote elevation guidance when an irm | iex run is not elevated (issues #226/#229, review finding P2-12)' {
        # The real Invoke-WingetInstall, with Test-IsAdmin overridden instead of depending on the
        # runner: CI is elevated, so the old version of this test (gated on real elevation) never
        # ran there. Under Invoke-Expression there is no script path to relaunch from, so the run
        # stops at the elevation gate.
        $path = New-FaultInjectedInstaller -Name 'iex-not-elevated.ps1' -Overrides "function Test-IsAdmin { `$false }"

        $result = Invoke-ChildInstallerViaIex -Path $path

        $result.ExitCode | Should -Be 4
        $result.Output | Should -Match 'This script requires administrator privileges\.'
        $result.Output | Should -Match 'Auto-elevation is unavailable when running through IEX/remote execution\.'
        $result.Output | Should -Match 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again\.'
        # The early-exit notice replaced the old 5-second sleep (review finding P2-14).
        $result.Output | Should -Match 'The installer stopped early with exit code 4: administrator rights are required, and this run was not elevated'
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

# Review findings P3-41 and P3-42, in a real child process: one run at a time (exit code 6), a
# RESULT line and last-run.json for every way a real run ends, and housekeeping only for the run
# that holds the run lock. RunLock.Tests.ps1, RunRecord.Tests.ps1 and Housekeeping.Tests.ps1 test
# the helpers themselves.
Describe 'One run at a time, and the RESULT line and last-run.json of every run (review findings P3-41, P3-42)' {
    BeforeAll {
        $script:installerText -match "\`$script:InstallerBuildId = '([^']+)'" | Should -BeTrue
        $script:runBuildId = $Matches[1]
        # Elevated, whatever the runner: only an elevated run takes the lock and writes the record.
        $script:elevated = "function Test-IsAdmin { `$true }"
        $script:notElevated = "function Test-IsAdmin { `$false }"

        # The last-run.json a child run wrote under its TestDrive ProgramData, or $null.
        function Get-ChildRunRecord {
            $file = Get-ChildItem -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Filter 'last-run.json' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($file) {
                Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            }
        }

        # The RESULT lines a child run printed.
        function Get-ChildResultLine {
            param ([string]$Output)
            @([regex]::Matches($Output, 'RESULT: [^\r\n]*') | ForEach-Object { $_.Value })
        }
    }

    BeforeEach {
        # Each test reads only what its own child run wrote.
        Remove-Item -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Force -ErrorAction SilentlyContinue
        $script:InstallerRunLock = $null
    }

    AfterEach {
        Unlock-InstallerRun
    }

    It 'Exits 6 at once, changing nothing, while another run holds the lock' {
        Lock-InstallerRun -Name $script:testRunLockName | Should -Be 'Acquired'
        $path = New-FaultInjectedInstaller -Name 'another-run.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 6
        $result.Output | Should -Match 'Another run of this installer is in progress on this PC'
        $result.Output | Should -Match 'The installer stopped early with exit code 6: another run of the installer is in progress on this PC'
        $result.Output | Should -Not -Match 'install ran'
        $result.Output | Should -Not -Match 'HOUSEKEEPING RAN'
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped before it finished'
        # It reports its exit code, but the record belongs to the run in progress.
        Get-ChildResultLine -Output $result.Output | Should -Be @("RESULT: exit=6 installed=0 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=NotRun restart=no build=$($script:runBuildId) log=$((Get-ChildTranscript)[0].FullName)")
        Get-ChildRunRecord | Should -BeNullOrEmpty
    }

    It 'Takes the run lock and housekeeps as SYSTEM too (an RMM run), and exits 6 while another run holds the lock (review finding P3-23)' {
        # SYSTEM's token holds the Administrators group, so Test-IsAdmin is true for it and an RMM
        # run as SYSTEM is the run that takes the lock and prunes; it must never be left out.
        $systemRun = $script:elevated + "`nfunction Test-IsSystemAccount { `$true }"
        $path = New-FaultInjectedInstaller -Name 'system-run.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides $systemRun

        $free = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')
        Lock-InstallerRun -Name $script:testRunLockName | Should -Be 'Acquired'
        $busy = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

        $free.ExitCode | Should -Be 0
        $free.Output | Should -Match 'HOUSEKEEPING RAN'
        (Get-Content -Raw -LiteralPath (Get-ChildItem -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Filter 'last-run.json' | Select-Object -First 1).FullName) | Should -Match '"exitCode":\s*0'
        $busy.ExitCode | Should -Be 6
        $busy.Output | Should -Not -Match 'install ran|HOUSEKEEPING RAN'
        $busy.Output | Should -Not -Match 'Press any key'
    }

    It 'Lets the next run start once the first one has ended, whatever its exit code' {
        $path = New-FaultInjectedInstaller -Name 'sequential.ps1' -Body "Write-Host 'install ran'; return 3" -Overrides $script:elevated

        $first = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')
        $second = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $first.ExitCode | Should -Be 3
        $second.ExitCode | Should -Be 3
        $second.Output | Should -Match 'install ran'
        $second.Output | Should -Not -Match 'in progress on this PC'
        # The run lock is free again once the child has ended.
        Lock-InstallerRun -Name $script:testRunLockName | Should -Be 'Acquired'
    }

    It 'Prunes old logs and leftover copies after taking the lock, giving housekeeping its own path' {
        $path = New-FaultInjectedInstaller -Name 'housekeeping.ps1' -Body 'return 0' -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ('HOUSEKEEPING RAN: ' + [regex]::Escape($path))
    }

    It 'Ends an early exit with its RESULT line, after the notice, and records it in last-run.json' {
        $path = New-FaultInjectedInstaller -Name 'early-exit.ps1' -Body "Write-ErrorMessage 'winget is missing'; return 2" -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 2
        $transcript = (Get-ChildTranscript)[0].FullName
        $resultLines = Get-ChildResultLine -Output $result.Output
        $resultLines | Should -Be @("RESULT: exit=2 installed=0 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=NotRun restart=no build=$($script:runBuildId) log=$transcript")
        $result.Output.IndexOf('stopped early with exit code 2') | Should -BeLessThan $result.Output.IndexOf('RESULT: exit=2')
        $record = Get-ChildRunRecord
        $record.exitCode | Should -Be 2
        $record.summaryReached | Should -BeFalse
        $record.buildId | Should -Be $script:runBuildId
        $record.transcriptPath | Should -Be $transcript
        # Read from the text: ConvertFrom-Json turns the time into a DateTime.
        (Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $transcript) 'last-run.json')) | Should -Match '"startedUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        @($record.apps).Count | Should -Be 0
        # In the log the teammate attaches, too.
        (Get-Content -Raw -LiteralPath $transcript) | Should -Match 'RESULT: exit=2 '
    }

    It 'Records an aborted run (exit code 5) with the apps it had finished' {
        $body = "`$script:InstallerAppRecords = [ordered]@{ 'Git.Git' = (New-AppRunRecord -Id 'Git.Git' -Status 'Installed' -InstallResult @{ ExitCode = 0 }) }; [int]::Parse('not-a-number')"
        $path = New-FaultInjectedInstaller -Name 'aborted.ps1' -Body $body -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        Get-ChildResultLine -Output $result.Output | Should -HaveCount 1
        @(Get-ChildResultLine -Output $result.Output)[0] | Should -Match '^RESULT: exit=5 installed=1 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=NotRun restart=no '
        $record = Get-ChildRunRecord
        $record.exitCode | Should -Be 5
        $record.apps[0].id | Should -Be 'Git.Git'
    }

    It 'Records the apps a SYSTEM run deferred, and its auto-update state, in last-run.json and the RESULT line of a run that stops early' {
        # Review findings P3-22 and P3-36 meet P3-41: a run as SYSTEM leaves an app with no
        # machine-wide installer for the signed-in user (Deferred), which the record must count on
        # its own, and Winget-AutoUpdate's task may be unhealthy; both must reach the record of a
        # run that is aborted after its app loop.
        $body = "`$records = [ordered]@{}; " +
            "`$records['Git.Git'] = New-AppRunRecord -Id 'Git.Git' -Status 'Installed' -InstallResult @{ ExitCode = 0 }; " +
            "`$records['Contoso.UserOnly'] = New-AppRunRecord -Id 'Contoso.UserOnly' -Status 'Deferred' -Reason 'winget found no machine-wide installer for it' -InstallResult @{ ExitCode = -1978335216; NoMachineScopeInstaller = `$true }; " +
            "`$script:InstallerAppRecords = `$records; " +
            "`$script:InstallerAutoUpdateResult = [pscustomobject]@{ Status = 'Unhealthy'; Version = [version]'2.12.0'; FrameworkMissing = `$false; RestartRequired = `$false; Problem = 'its scheduled task is missing'; CheckFailed = `$false }; " +
            "[int]::Parse('not-a-number')"
        $path = New-FaultInjectedInstaller -Name 'aborted-deferred.ps1' -Body $body -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        Get-ChildResultLine -Output $result.Output | Should -HaveCount 1
        @(Get-ChildResultLine -Output $result.Output)[0] | Should -Match '^RESULT: exit=5 installed=1 skipped=0 deferred=1 failed=0 notattempted=0 autoupdates=Unhealthy restart=no '
        $record = Get-ChildRunRecord
        $record.counts.installed | Should -Be 1
        $record.counts.deferred | Should -Be 1
        $record.counts.failed | Should -Be 0
        $record.apps[1].id | Should -Be 'Contoso.UserOnly'
        $record.apps[1].status | Should -Be 'Deferred'
        $record.apps[1].codeHex | Should -Be '0x8A150010'
        $record.autoUpdates.status | Should -Be 'Unhealthy'
    }

    It 'Exits 8 with exit=8 in the RESULT line and last-run.json when auto-updates are unhealthy (review finding P3-36)' {
        # The record Invoke-WingetInstall writes at its summary, with the code Get-InstallerExitCode
        # gives it, and the process exit code the entry script passes on, must agree.
        $body = "`$wau = [pscustomobject]@{ Status = 'Unhealthy'; Version = [version]'2.12.0'; FrameworkMissing = `$false; RestartRequired = `$false; Problem = 'its scheduled task is disabled'; CheckFailed = `$false }; " +
            "`$code = Get-InstallerExitCode -FailedAppCount 0 -WingetUsable `$true -AutoUpdatesHealthy `$false; " +
            "`$script:InstallerPendingExitCode = `$code; " +
            "[void](Write-InstallerRunResult -Record (New-InstallerRunRecord -ExitCode `$code -Apps @(New-AppRunRecord -Id 'Git.Git' -Status 'Installed' -InstallResult @{ ExitCode = 0 }) -AutoUpdates (Get-AutoUpdateResultStatus -WauResult `$wau) -AutoUpdatesVersion `$wau.Version -WingetUsable `$true -SummaryReached)); " +
            "`$script:InstallerRunReportPending = `$false; return `$code"
        $path = New-FaultInjectedInstaller -Name 'unhealthy-wau.ps1' -Body $body -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 8
        Get-ChildResultLine -Output $result.Output | Should -Be @("RESULT: exit=8 installed=1 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=Unhealthy restart=no build=$($script:runBuildId) log=$((Get-ChildTranscript)[0].FullName)")
        $record = Get-ChildRunRecord
        $record.exitCode | Should -Be 8
        $record.summaryReached | Should -BeTrue
        $record.autoUpdates.status | Should -Be 'Unhealthy'
        $result.Output | Should -Not -Match 'stopped early'
    }

    It 'Ends a run Group Policy stops at the winget setup (exit code 2) with its RESULT line and last-run.json (review findings P3-30, P3-41)' {
        # The real Invoke-WingetInstall: its environment pre-flight finds the policy before any
        # winget call (wgt-gq8.39), the run returns 2 before its summary, and the entry script's
        # early-exit route reports it.
        $overrides = $script:elevated + "`n" +
            "function Get-InstallAccountContext { [pscustomobject]@{ IsSystem = `$false; ProcessUser = 'CONTOSO\admin-tech'; SessionUser = 'CONTOSO\admin-tech'; IsCrossUserElevation = `$false } }`n" +
            "function Get-PendingRestartState { `$null }`n" +
            "function Wait-WauIdle { `$true }`n" +
            "function Get-WingetPolicyBlock { [pscustomobject]@{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' } }`n" +
            "function Invoke-WingetProcess { throw 'winget must not run when Group Policy blocks it' }"
        $path = New-FaultInjectedInstaller -Name 'policy-blocked.ps1' -Overrides $overrides

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match "Group Policy on this PC blocks winget: 'Enable App Installer' is Disabled"
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|winget must not run'
        $result.Output | Should -Match 'The installer stopped early with exit code 2: winget is not available, could not be started, cannot open its source, or is turned off by Group Policy \(see above\)\.'
        $transcript = (Get-ChildTranscript)[0].FullName
        Get-ChildResultLine -Output $result.Output | Should -Be @("RESULT: exit=2 installed=0 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=NotRun restart=no build=$($script:runBuildId) log=$transcript")
        $result.Output.IndexOf('stopped early with exit code 2') | Should -BeLessThan $result.Output.IndexOf('RESULT: exit=2')
        $record = Get-ChildRunRecord
        $record.exitCode | Should -Be 2
        $record.summaryReached | Should -BeFalse
        @($record.apps).Count | Should -Be 0
    }

    It 'Records a run stopped from outside as exit code 5' {
        $path = New-FaultInjectedInstaller -Name 'stopped-record.ps1' -Body 'throw [System.Management.Automation.PipelineStoppedException]::new()' -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        (Get-ChildRunRecord).exitCode | Should -Be 5
        Get-ChildResultLine -Output $result.Output | Should -HaveCount 1
    }

    It 'Leaves a record without an exit code, not the previous run''s, when the run is killed' {
        # An RMM time limit or taskkill /F ends the process: no catch, no finally, no report. The
        # record written when the run took the lock must replace the previous run's (exit code 0
        # here), so whoever collects last-run.json sees that this run did not finish.
        $logDirectory = Join-Path (Join-Path $TestDrive 'ProgramData') 'winget-app-setup\logs'
        [void](New-Item -ItemType Directory -Path $logDirectory -Force)
        Set-Content -LiteralPath (Join-Path $logDirectory 'last-run.json') -Value '{ "exitCode": 0, "startedUtc": "2026-01-01T00:00:00Z", "summaryReached": true }' -Encoding UTF8
        $path = New-FaultInjectedInstaller -Name 'killed.ps1' -Body "Write-Host 'install started'; [System.Diagnostics.Process]::GetCurrentProcess().Kill()" -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.Output | Should -Match 'install started'
        Get-ChildResultLine -Output $result.Output | Should -HaveCount 0
        $text = Get-Content -Raw -LiteralPath (Join-Path $logDirectory 'last-run.json')
        $text | Should -Match '"exitCode":\s*null'
        $text | Should -Match '"endedUtc":\s*null'
        $text | Should -Match '"summaryReached":\s*false'
        $text | Should -Not -Match '2026-01-01T00:00:00Z'
        $record = $text | ConvertFrom-Json
        $record.buildId | Should -Be $script:runBuildId
        $record.transcriptPath | Should -Be (Get-ChildTranscript)[0].FullName
    }

    It 'Adds no second RESULT line after a run that reported at its summary' {
        $body = "`$script:InstallerRunReportPending = `$false; Write-Host 'RESULT: exit=1 (from the summary)'; `$script:InstallerPendingExitCode = 1; return 1"
        $path = New-FaultInjectedInstaller -Name 'reported.ps1' -Body $body -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 1
        Get-ChildResultLine -Output $result.Output | Should -Be @('RESULT: exit=1 (from the summary)')
    }

    It 'Reports and releases the run lock before an early exit waits for a key press' {
        # Someone at the console: the notice, then the RESULT line, then the prompt, by which time
        # the lock is free, so a window left open does not make the next run (an RMM schedule)
        # exit 6. Write-Prompt throws so the child never reaches [Console]::ReadKey. CI is
        # overridden too: GitHub Actions sets CI and GITHUB_ACTIONS, and the child would then skip
        # the prompt this test checks.
        $overrides = $script:elevated + "`n" +
            "function Test-IsContinuousIntegration { `$false }`n" +
            "function Test-EffectiveNonInteractive { param([switch]`$NonInteractive) `$false }`n" +
            "function Write-Prompt { param([string]`$Message) Write-Host ""PROMPT: `$Message (lock held: `$(`$null -ne `$script:InstallerRunLock))""; throw 'no key press in tests' }"
        $path = New-FaultInjectedInstaller -Name 'early-exit-prompt.ps1' -Body "Write-ErrorMessage 'winget is missing'; return 2" -Overrides $overrides

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'PROMPT: Press any key to exit\.\.\. \(lock held: False\)'
        $noticeAt = $result.Output.IndexOf('stopped early with exit code 2')
        $resultAt = $result.Output.IndexOf('RESULT: exit=2 ')
        $promptAt = $result.Output.IndexOf('PROMPT: Press any key')
        $noticeAt | Should -BeLessThan $resultAt
        $resultAt | Should -BeLessThan $promptAt
        Get-ChildResultLine -Output $result.Output | Should -HaveCount 1
        (Get-ChildRunRecord).exitCode | Should -Be 2
    }

    It 'Takes no lock, prunes nothing and reports nothing in a dry run' {
        Lock-InstallerRun -Name $script:testRunLockName | Should -Be 'Acquired'
        $path = New-FaultInjectedInstaller -Name 'dry-run.ps1' -Body "Write-Host 'dry run ran'; return 0" -Overrides $script:elevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive', '-WhatIf')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'dry run ran'
        $result.Output | Should -Not -Match 'HOUSEKEEPING RAN|in progress on this PC'
        Get-ChildResultLine -Output $result.Output | Should -HaveCount 0
        Get-ChildRunRecord | Should -BeNullOrEmpty
    }

    It 'Takes no lock and writes no record when not elevated, and still ends with its RESULT line' {
        # It stops with exit code 4 (or relaunches elevated, and that run takes the lock).
        Lock-InstallerRun -Name $script:testRunLockName | Should -Be 'Acquired'
        $path = New-FaultInjectedInstaller -Name 'not-elevated.ps1' -Body 'return 4' -Overrides $script:notElevated

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 4
        $result.Output | Should -Not -Match 'HOUSEKEEPING RAN|in progress on this PC'
        @(Get-ChildResultLine -Output $result.Output)[0] | Should -Match '^RESULT: exit=4 '
        Get-ChildRunRecord | Should -BeNullOrEmpty
    }
}

# wgt-gq8.41, in real child processes: the time budget's deadline is counted from the first start of
# the run and crosses the Windows PowerShell 5.1 -> PowerShell 7 relaunch on the command line (the
# elevated relaunch is tested in Install.Tests.ps1 and Elevation.Tests.ps1), a bad value fails
# parameter binding, and a run whose budget is used up exits 9 with what it did not attempt.
Describe 'The time budget from the entry script (-MaxRuntimeMinutes, wgt-gq8.41)' {
    BeforeAll {
        $script:installerText -match "\`$script:InstallerBuildId = '([^']+)'" | Should -BeTrue
        $script:budgetBuildId = $Matches[1]
        $script:bootstrapBudgetSignature = 'param([switch]$WhatIf, [switch]$NonInteractive, [switch]$SkipSystemCheck, [string]$CommandPath, [string]$ExpectedBuildId, [string]$LogDirectory, [string[]]$AdditionalArguments)'
        $script:budgetBootstrap = "function Invoke-PowerShell7Bootstrap { $($script:bootstrapBudgetSignature) Write-Host ""relaunch arguments: [`$(`$AdditionalArguments -join ' ')]""; `$script:PowerShell7BootstrapRelaunched = `$true; return 9 }"

        function ConvertFrom-DeadlineText {
            param ([string]$Text)
            $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
            [DateTime]::ParseExact($Text, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        }
    }

    BeforeEach {
        Remove-Item -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Force -ErrorAction SilentlyContinue
        $script:InstallerRunLock = $null
        $script:savedBudgetVariable = $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES
        Remove-Item -Path Env:\WINGET_APP_SETUP_MAX_RUNTIME_MINUTES -ErrorAction SilentlyContinue
    }

    AfterEach {
        Unlock-InstallerRun
        if ($null -eq $script:savedBudgetVariable) {
            Remove-Item -Path Env:\WINGET_APP_SETUP_MAX_RUNTIME_MINUTES -ErrorAction SilentlyContinue
        }
        else {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $script:savedBudgetVariable
        }
    }

    It 'Windows PowerShell 5.1 phase: passes the PowerShell 7 run the deadline counted from its own start (<Case>)' -ForEach @(
        @{ Case = '-MaxRuntimeMinutes'; Arguments = @('-MaxRuntimeMinutes', '30'); Variable = $null }
        @{ Case = 'WINGET_APP_SETUP_MAX_RUNTIME_MINUTES, for irm | iex'; Arguments = @(); Variable = '30' }
    ) {
        if ($Variable) {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $Variable
        }
        $path = New-FaultInjectedInstaller -Name 'budget-bootstrap.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides $script:budgetBootstrap
        $before = [DateTime]::UtcNow

        $result = Invoke-ChildInstaller -Arguments (@('-File', $path, '-NonInteractive') + $Arguments)

        $after = [DateTime]::UtcNow
        $result.ExitCode | Should -Be 9
        $result.Output | Should -Not -Match 'install ran'
        $result.Output -match 'relaunch arguments: \[-MaxRuntimeMinutes 30 -RunDeadlineUtc (?<deadline>\S+)\]' | Should -BeTrue
        $deadline = ConvertFrom-DeadlineText -Text $Matches.deadline
        $deadline | Should -BeGreaterOrEqual $before.AddMinutes(30).AddSeconds(-1)
        $deadline | Should -BeLessOrEqual $after.AddMinutes(30)
    }

    It 'Windows PowerShell 5.1 phase: keeps a deadline an earlier phase passed on (the elevated window)' {
        $inherited = Format-RunRecordTime -Time ([DateTime]::UtcNow.AddMinutes(5))
        $path = New-FaultInjectedInstaller -Name 'budget-bootstrap-inherited.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides $script:budgetBootstrap

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive', '-MaxRuntimeMinutes', '30', '-RunDeadlineUtc', $inherited)

        $result.Output | Should -Match ([regex]::Escape("relaunch arguments: [-MaxRuntimeMinutes 30 -RunDeadlineUtc $inherited]"))
    }

    It 'Windows PowerShell 5.1 phase: passes nothing on without a budget, or with a variable it cannot read (<Case>)' -ForEach @(
        @{ Case = 'no budget'; Variable = $null; Warning = $null }
        @{ Case = 'variable 0'; Variable = '0'; Warning = $null }
        @{ Case = 'variable abc'; Variable = 'abc'; Warning = "Ignoring WINGET_APP_SETUP_MAX_RUNTIME_MINUTES='abc'" }
    ) {
        if ($Variable) {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $Variable
        }
        $path = New-FaultInjectedInstaller -Name 'budget-bootstrap-none.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides $script:budgetBootstrap

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive')

        $result.Output | Should -Match ([regex]::Escape('relaunch arguments: []'))
        if ($Warning) {
            $result.Output | Should -Match ([regex]::Escape($Warning))
        }
        else {
            $result.Output | Should -Not -Match 'Ignoring WINGET_APP_SETUP_MAX_RUNTIME_MINUTES'
        }
    }

    # Review of wgt-gq8.41: a -MaxRuntimeMinutes 0 that was given wins over the variable the
    # PowerShell 7 run inherits, so it goes on as it is.
    It 'Windows PowerShell 5.1 phase: passes a -MaxRuntimeMinutes 0 that was given on, and no budget from the variable' {
        $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = '30'
        $path = New-FaultInjectedInstaller -Name 'budget-bootstrap-zero.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides $script:budgetBootstrap

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive', '-MaxRuntimeMinutes', '0')

        $result.Output | Should -Match ([regex]::Escape('relaunch arguments: [-MaxRuntimeMinutes 0]'))
    }

    It 'PowerShell 7 phase: passes -MaxRuntimeMinutes and -RunDeadlineUtc on to Invoke-WingetInstall only when given (<Case>)' -ForEach @(
        @{ Case = 'both given'; Arguments = @('-MaxRuntimeMinutes', '30', '-RunDeadlineUtc', '2026-10-05T12:00:00Z'); Expected = 'budget: [30] [2026-10-05T12:00:00Z]'; ViaIex = $false }
        @{ Case = '-MaxRuntimeMinutes 0, which turns off the variable''s budget'; Arguments = @('-MaxRuntimeMinutes', '0'); Expected = 'budget: [0] [unset]'; ViaIex = $false }
        @{ Case = 'neither given'; Arguments = @(); Expected = 'budget: [unset] [unset]'; ViaIex = $false }
        @{ Case = 'irm | iex, which passes no parameter'; Arguments = @(); Expected = 'budget: [unset] [unset]'; ViaIex = $true }
    ) {
        $overrides = "function Test-IsAdmin { `$true }`n" +
            "function Invoke-WingetInstall { param([switch]`$WhatIf, [switch]`$NonInteractive, [switch]`$SkipSystemCheck, [int]`$MaxRuntimeMinutes, [string]`$RunDeadlineUtc) `$minutes = 'unset'; if (`$PSBoundParameters.ContainsKey('MaxRuntimeMinutes')) { `$minutes = `$MaxRuntimeMinutes }; `$deadline = 'unset'; if (`$PSBoundParameters.ContainsKey('RunDeadlineUtc')) { `$deadline = `$RunDeadlineUtc }; Write-Host ""budget: [`$minutes] [`$deadline]""; return 0 }"
        $path = New-FaultInjectedInstaller -Name 'budget-pwsh.ps1' -Overrides $overrides

        if ($ViaIex) {
            $result = Invoke-ChildInstallerViaIex -Path $path
        }
        else {
            $result = Invoke-ChildInstaller -Arguments (@('-File', $path, '-SkipSystemCheck', '-NonInteractive') + $Arguments)
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape($Expected))
    }

    It 'Fails parameter binding, running nothing, for a -MaxRuntimeMinutes that is not a whole number from 0 to 1440: <_>' -ForEach @('-1', '1441', 'abc') {
        $path = New-FaultInjectedInstaller -Name 'budget-bad-value.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides "function Test-IsAdmin { `$true }"

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-NonInteractive', '-MaxRuntimeMinutes', $_)

        $result.ExitCode | Should -Not -Be 0
        # The parameter's own check (range or type), not an unknown parameter.
        $result.Output | Should -Match "(validate|process) argument[^\r\n]*on parameter 'MaxRuntimeMinutes'"
        $result.Output | Should -Not -Match 'install ran|Logging this run to:'
        Get-ChildTranscript | Should -HaveCount 0
    }

    It 'Exits 9 when the budget is used up, reporting what it did not attempt in the summary, the RESULT line and last-run.json' {
        # The real Invoke-WingetInstall, with a deadline in the past: no app install, no
        # Winget-AutoUpdate setup and no winget call starts; winget is still checked at the end.
        $overrides = "function Test-IsAdmin { `$true }`n" +
            "function Get-InstallAccountContext { [pscustomobject]@{ IsSystem = `$false; ProcessUser = 'CONTOSO\admin-tech'; SessionUser = 'CONTOSO\admin-tech'; IsCrossUserElevation = `$false } }`n" +
            "function Get-PendingRestartState { `$null }`n" +
            "function Get-WingetPolicyBlock { `$null }`n" +
            "function Wait-WauIdle { throw 'no wait for Winget-AutoUpdate once the time budget is used up' }`n" +
            "function Initialize-Winget { param([switch]`$WhatIf, `$AccountContext) [pscustomobject]@{ Ready = `$true; Diagnosis = 'Ok' } }`n" +
            "function Remove-LegacyScheduledUpdates { param([switch]`$WhatIf) `$true }`n" +
            "function Get-DefaultAppCatalog { @(@{ name = 'Contoso.AppOne' }, @{ name = 'Contoso.AppTwo' }) }`n" +
            "function Test-AppApplicability { param(`$App, `$Purpose) `$true }`n" +
            "function Set-WindowsTerminalDefaults { param([switch]`$WhatIf) }`n" +
            "function Install-WingetAutoUpdate { throw 'no Winget-AutoUpdate setup once the time budget is used up' }`n" +
            "function Invoke-WingetProcess { throw 'no winget call once the time budget is used up' }`n" +
            "function Test-WingetLaunchable { param(`$Attempts, `$RetryDelaySeconds) [pscustomobject]@{ Launchable = `$true; Version = 'v1.12.350'; Reason = `$null; Attempts = 1 } }"
        $path = New-FaultInjectedInstaller -Name 'budget-used-up.ps1' -Overrides $overrides

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive', '-MaxRuntimeMinutes', '1', '-RunDeadlineUtc', '2026-01-01T00:00:00Z')

        $result.ExitCode | Should -Be 9
        $result.Output | Should -Not -Match 'UNEXPECTED ERROR|stopped early|no wait for|no Winget-AutoUpdate setup once|no winget call'
        $result.Output | Should -Match 'Not attempted: Contoso\.AppOne'
        $result.Output | Should -Match 'Time budget: USED UP - .*so these were not attempted: Contoso\.AppOne, Contoso\.AppTwo, the Winget-AutoUpdate setup\. Run the installer again to finish\.'
        $transcript = (Get-ChildTranscript)[0].FullName
        @([regex]::Matches($result.Output, 'RESULT: [^\r\n]*') | ForEach-Object { $_.Value }) | Should -Be @("RESULT: exit=9 installed=0 skipped=0 deferred=0 failed=0 notattempted=2 autoupdates=NotAttempted restart=no build=$($script:budgetBuildId) log=$transcript")
        $recordFile = Get-ChildItem -Path (Join-Path $TestDrive 'ProgramData') -Recurse -Filter 'last-run.json' | Select-Object -First 1
        $record = Get-Content -Raw -LiteralPath $recordFile.FullName | ConvertFrom-Json
        $record.exitCode | Should -Be 9
        $record.summaryReached | Should -BeTrue
        $record.counts.notAttempted | Should -Be 2
        @($record.apps | ForEach-Object { $_.status } | Sort-Object -Unique) | Should -Be @('NotAttempted')
        $record.autoUpdates.status | Should -Be 'NotAttempted'
        $record.wingetUsable | Should -BeTrue
    }
}

# wgt-gq8.35, in a real child process: -CollectDiagnostics makes the bundle and does nothing a real
# run does (no transcript, run lock, housekeeping, RESULT line or PowerShell 7 bootstrap), also as
# the script block command the failure notices print. Diagnostics.Tests.ps1 tests the collector.
Describe 'The diagnostics bundle from the entry block (-CollectDiagnostics, wgt-gq8.35)' {
    BeforeAll {
        # Elevated, so a real run would take the run lock and run housekeeping.
        $script:collectorOverrides = (
            "function Test-IsAdmin { `$true }`n" +
            "function Invoke-PowerShell7Bootstrap { param([switch]`$WhatIf, [switch]`$NonInteractive, [switch]`$SkipSystemCheck, [string]`$CommandPath, [string]`$ExpectedBuildId, [string]`$LogDirectory) Write-Host 'BOOTSTRAP RAN'; return 0 }`n")
        function Get-CollectorOverride {
            param ([int]$ExitCode)
            $script:collectorOverrides + "function Invoke-DiagnosticsCollection { param([string]`$LogDirectory, [string[]]`$OutputDirectory) Write-Host 'COLLECTED'; return $ExitCode }"
        }
    }

    It 'Makes the bundle and nothing else, and exits with the collector''s code <_>' -ForEach @(0, 5) {
        $path = New-FaultInjectedInstaller -Name "collect-$_.ps1" -Body "Write-Host 'install ran'; return 0" -Overrides (Get-CollectorOverride -ExitCode $_)

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-CollectDiagnostics', '-NonInteractive')

        $result.ExitCode | Should -Be $_
        $result.Output | Should -Match 'COLLECTED'
        $result.Output | Should -Not -Match 'install ran|HOUSEKEEPING RAN|BOOTSTRAP RAN|RESULT:|Logging this run to:|Installer build:'
        @(Get-ChildTranscript).Count | Should -Be 0
        @(Get-ChildTranscript -Filter 'last-run.json').Count | Should -Be 0
    }

    It 'Runs as it is under Windows PowerShell 5.1: no PowerShell 7 bootstrap and no bootstrap log' {
        $path = New-FaultInjectedInstaller -Name 'collect-desktop.ps1' -EmulateWindowsPowerShell -Body "Write-Host 'install ran'; return 0" -Overrides (Get-CollectorOverride -ExitCode 0)

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-CollectDiagnostics', '-NonInteractive')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'COLLECTED'
        $result.Output | Should -Not -Match 'BOOTSTRAP RAN|install ran|Logging the PowerShell 7 bootstrap'
        @(Get-ChildTranscript).Count | Should -Be 0
    }

    It 'Exits 5 when the collector throws' {
        $path = New-FaultInjectedInstaller -Name 'collect-throws.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides (
            $script:collectorOverrides + "function Invoke-DiagnosticsCollection { param([string]`$LogDirectory, [string[]]`$OutputDirectory) throw 'collector exploded' }")

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-CollectDiagnostics', '-NonInteractive')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'The diagnostics bundle could not be made: collector exploded'
        $result.Output | Should -Not -Match 'install ran'
    }

    It 'Works as the printed script block command, unattended: the process exits with the code' {
        $path = New-FaultInjectedInstaller -Name 'collect-scriptblock.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides (Get-CollectorOverride -ExitCode 5)
        $escapedPath = $path.Replace("'", "''")

        $result = Invoke-ChildInstaller -Arguments @('-Command', "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$escapedPath'))) -CollectDiagnostics; Write-Host 'AFTER'")

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'COLLECTED'
        $result.Output | Should -Not -Match 'AFTER|install ran'
    }

    It 'Works as the printed script block command in an interactive console, which it keeps open' {
        $path = New-FaultInjectedInstaller -Name 'collect-scriptblock-interactive.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides (
            (Get-CollectorOverride -ExitCode 5) + "`nfunction Test-EffectiveNonInteractive { param([switch]`$NonInteractive) `$false }")
        $escapedPath = $path.Replace("'", "''")

        $result = Invoke-ChildInstaller -Arguments @('-Command', "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$escapedPath'))) -CollectDiagnostics; Write-Host ('AFTER LASTEXITCODE=' + `$LASTEXITCODE)")

        $result.Output | Should -Match 'COLLECTED'
        $result.Output | Should -Match 'AFTER LASTEXITCODE=5'
    }

    Context 'The real collector in the generated installer' {
        It 'Saves a bundle with the run''s transcript, its header redacted, and adds nothing to the logs folder' {
            $logDirectory = Join-Path (Join-Path $TestDrive 'ProgramData') 'winget-app-setup\logs'
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
            $fixture = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/diagnostics/transcript.txt')
            Set-Content -LiteralPath (Join-Path $logDirectory 'install-20261004-143205.log') -Value $fixture -NoNewline
            $outputDirectory = Join-Path $TestDrive 'bundle-out'
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
            $escapedOutput = $outputDirectory.Replace("'", "''")
            # Only the parts that would start winget or Windows PowerShell on the runner are replaced.
            $path = New-FaultInjectedInstaller -Name 'collect-real.ps1' -Body "Write-Host 'install ran'; return 0" -Overrides (
                "function Get-DiagnosticsBundleDirectory { param(`$AccountContext) '$escapedOutput' }`n" +
                "function Get-DiagnosticsWingetReport { param(`$AccountContext) 'winget: not run in this test' }`n" +
                "function Get-DiagnosticsAppxReport { 'appx: not run in this test' }")
            $before = @(Get-ChildItem -LiteralPath $logDirectory | ForEach-Object { $_.Name })

            $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-CollectDiagnostics', '-NonInteractive')

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Diagnostics bundle saved: '
            @(Get-ChildItem -LiteralPath $logDirectory | ForEach-Object { $_.Name }) | Should -Be $before
            $zip = @(Get-ChildItem -LiteralPath $outputDirectory -Filter 'winget-app-setup-diagnostics-*.zip')
            $zip.Count | Should -Be 1
            Add-Type -AssemblyName System.IO.Compression
            $stream = [System.IO.File]::OpenRead($zip[0].FullName)
            try {
                $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
                $names = @($archive.Entries | ForEach-Object { $_.FullName })
                $reader = [System.IO.StreamReader]::new($archive.GetEntry('logs/install-20261004-143205.log').Open())
                $transcript = $reader.ReadToEnd()
                $reader.Dispose()
                $archive.Dispose()
            }
            finally {
                $stream.Dispose()
            }
            $names | Should -Contain 'README.txt'
            $names | Should -Contain 'system.txt'
            $names | Should -Contain 'wau-updates-log-tail.txt'
            $transcript | Should -Match '(?m)^Username: <domain\d+>\\<user\d+>\r?$'
            $transcript | Should -Match 'Installer failed with exit code: 1603'
            foreach ($token in @('jdoe', 'admin-tech', 'PC-4711', 'CONTOSO', 'Kim.Park')) {
                $transcript | Should -Not -Match ([regex]::Escape($token))
            }
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
        # byte-compare. Verified the way CI would notice: build twice, compare bytes, for both the
        # installer and the uninstaller (wgt-gq8.43).
        $first = @{ Installer = Join-Path $TestDrive 'installer-build-one.ps1'; Uninstaller = Join-Path $TestDrive 'uninstaller-build-one.ps1' }
        $second = @{ Installer = Join-Path $TestDrive 'installer-build-two.ps1'; Uninstaller = Join-Path $TestDrive 'uninstaller-build-two.ps1' }

        foreach ($output in @($first, $second)) {
            & $script:currentPowerShell -NoProfile -File $script:buildScriptPath -OutputPath $output.Installer -UninstallerOutputPath $output.Uninstaller | Out-Null
            $LASTEXITCODE | Should -Be 0
        }

        foreach ($name in 'Installer', 'Uninstaller') {
            (Get-FileHash -Path $first[$name] -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -Path $second[$name] -Algorithm SHA256).Hash
        }
        # Each is its own script: the uninstaller is not a copy of the installer.
        (Get-FileHash -Path $first.Uninstaller -Algorithm SHA256).Hash | Should -Not -Be (Get-FileHash -Path $first.Installer -Algorithm SHA256).Hash
    }

    It 'Writes the uninstaller next to -OutputPath when only -OutputPath is given, never over the repository''s copy' {
        $folder = Join-Path $TestDrive 'only-output-path'
        [void](New-Item -ItemType Directory -Path $folder)
        $repositoryCopy = (Get-FileHash -Path $script:UninstallerScriptPath -Algorithm SHA256).Hash
        $repositoryCopyTime = (Get-Item -LiteralPath $script:UninstallerScriptPath).LastWriteTimeUtc

        & $script:currentPowerShell -NoProfile -File $script:buildScriptPath -OutputPath (Join-Path $folder 'installer.ps1') | Out-Null

        $LASTEXITCODE | Should -Be 0
        @(Get-ChildItem -LiteralPath $folder | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('installer.ps1', 'winget-app-uninstall.ps1')
        (Get-FileHash -Path (Join-Path $folder 'winget-app-uninstall.ps1') -Algorithm SHA256).Hash | Should -Be $repositoryCopy
        (Get-Item -LiteralPath $script:UninstallerScriptPath).LastWriteTimeUtc | Should -Be $repositoryCopyTime
    }
}

# Review findings P2-11, P2-12 and P3-11, through the generated installer's real entry block and
# the real Invoke-WingetInstall and Restart-WithElevation: only the admin check, the console's
# interactivity and the elevated launch itself (which would raise a real UAC prompt) are overridden.
Describe 'Elevated relaunch through the entry block (review findings P2-11, P2-12, P3-11)' {
    BeforeAll {
        # A run from a file, not elevated, with someone at the console unless -NonInteractive is
        # passed. Write-Prompt throws, so a key press the run would wait for shows up as PROMPT:.
        $script:notElevatedOverrides = @'
function Test-IsAdmin { $false }
function Test-EffectiveNonInteractive { param ([switch]$NonInteractive) [bool]$NonInteractive }
function Test-IsContinuousIntegration { $false }
function Write-Prompt { param ([string]$Message) Write-Host "PROMPT: $Message"; throw 'no key press in tests' }
'@
        # The elevated Windows PowerShell, standing in: prints what it was asked to start and
        # "ends" with exit code 1 at once.
        $script:elevatedRunOverride = @'
function Start-ElevatedProcess {
    param ([string]$FilePath, [string]$ArgumentString)
    Write-Host "ELEVATED: $FilePath $ArgumentString"
    $process = [pscustomobject]@{ ExitCode = 1 }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param ($Milliseconds) $true }
    $process
}
'@
    }

    It 'Waits for the elevated run and exits with its exit code, without a second notice or key press' {
        $path = New-FaultInjectedInstaller -Name 'relaunch-waits.ps1' -Overrides ($script:notElevatedOverrides + "`n" + $script:elevatedRunOverride)
        $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

        $result.ExitCode | Should -Be 1
        # System32's Windows PowerShell, running the check-and-copy command, not the file itself,
        # with -ExecutionPolicy Bypass so the command's own check sees only a Group Policy one
        # (wgt-gq8.39).
        $result.Output | Should -Match 'ELEVATED: \S*\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe -NoProfile -ExecutionPolicy Bypass -Command "'
        # The SHA256 the entry block took at startup, and the forwarded switch.
        $result.Output | Should -Match ([regex]::Escape("-ne '$sha256'"))
        $result.Output | Should -Match ([regex]::Escape('-File $copy -SkipSystemCheck;'))
        $result.Output | Should -Match 'The elevated run ended with exit code 1\.'
        # The elevated window showed the outcome and waited for its own key press.
        $result.Output | Should -Not -Match 'stopped early|PROMPT:|UNEXPECTED ERROR'
    }

    It 'Does not relaunch a file that changed after the run started, and exits 5' {
        # The file is rewritten while the run is still going, before it asks for elevation, as a
        # same-user process could do to the bootstrap's copy in %TEMP%: here, in the last check the
        # run makes before it relaunches.
        $tamperOverride = @'
function Test-InvokedFromModuleContext {
    param ($InvocationModule, [string]$CommandPath)
    Add-Content -LiteralPath $PSCommandPath -Value '# rewritten before the UAC prompt'
    $false
}
'@
        $path = New-FaultInjectedInstaller -Name 'relaunch-tampered.ps1' -Overrides ($script:notElevatedOverrides + "`n" + $script:elevatedRunOverride + "`n" + $tamperOverride)

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

        $result.ExitCode | Should -Be 5
        $result.Output | Should -Match 'changed after this run started, so it is not run with administrator rights'
        $result.Output | Should -Not -Match 'ELEVATED:'
        # No UAC prompt was shown, so the run does not say to approve one.
        $result.Output | Should -Not -Match 'approve the administrator|declined'
    }

    It 'Exits 4 after one UAC prompt when the prompt is declined' {
        $declinedOverride = @'
function Start-ElevatedProcess {
    param ([string]$FilePath, [string]$ArgumentString)
    Write-Host 'UAC PROMPT SHOWN'
    throw [System.Management.Automation.MethodInvocationException]::new('Exception calling "Start"', [System.ComponentModel.Win32Exception]::new(1223))
}
'@
        $path = New-FaultInjectedInstaller -Name 'relaunch-declined.ps1' -Overrides ($script:notElevatedOverrides + "`n" + $declinedOverride)

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

        $result.ExitCode | Should -Be 4
        ([regex]::Matches($result.Output, 'UAC PROMPT SHOWN')).Count | Should -Be 1
        $result.Output | Should -Match 'The administrator \(UAC\) prompt was declined'
        $result.Output | Should -Match 'stopped early with exit code 4: administrator rights are required'
    }

    It 'Exits 4 without a UAC prompt when the run is non-interactive' {
        $path = New-FaultInjectedInstaller -Name 'relaunch-unattended.ps1' -Overrides ($script:notElevatedOverrides + "`n" + $script:elevatedRunOverride)

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck', '-NonInteractive')

        $result.ExitCode | Should -Be 4
        $result.Output | Should -Not -Match 'ELEVATED:'
        $result.Output | Should -Match 'this run is non-interactive, so there is nobody to approve a UAC prompt'
        $result.Output | Should -Not -Match 'PROMPT:'
    }

    It 'Exits 4 without a UAC prompt when Group Policy''s machine execution policy would refuse the elevated run (wgt-gq8.39)' {
        # Defined after the fault-injection default, so this one wins.
        $policyOverride = "function Get-ScriptExecutionPolicyBlock { param([string]`$Engine) if (`$Engine -eq 'WindowsPowerShell') { [pscustomobject]@{ Engine = `$Engine; Scope = 'MachinePolicy'; Policy = 'AllSigned'; Key = 'HKLM\K'; GroupPolicyPath = 'Computer Configuration > P'; Description = 'Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned (MachinePolicy, HKLM\K)' } } }"
        $path = New-FaultInjectedInstaller -Name 'relaunch-policy.ps1' -Overrides ($script:notElevatedOverrides + "`n" + $script:elevatedRunOverride + "`n" + $policyOverride)

        $result = Invoke-ChildInstaller -Arguments @('-File', $path, '-SkipSystemCheck')

        $result.ExitCode | Should -Be 4
        $result.Output | Should -Not -Match 'ELEVATED:'
        $result.Output | Should -Match 'Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned .*cannot run this script from a file.* No UAC prompt was shown\.'
        $result.Output | Should -Match 'stopped early with exit code 4: administrator rights are required'
    }
}

# wgt-gq8.43: the uninstaller's elevated run is a checked copy, as the installer's is (review finding
# P3-11), through the generated uninstaller's real entry block and the real Restart-WithElevation:
# only the admin check, the console's interactivity and the elevated launch itself (which would raise
# a real UAC prompt) are overridden. It used to run its own file in place, unchecked, because it
# imported the module from the folder next to it.
Describe 'Elevated relaunch through the uninstaller''s entry block (wgt-gq8.43, review finding P3-11)' {
    BeforeAll {
        # A run from a file, not elevated, with someone at the console unless -NonInteractive is
        # passed, and no Group Policy execution policy. Write-Prompt throws, so a key press the run
        # would wait for shows up as PROMPT:.
        $script:uninstallerNotElevated = @'
function Test-IsAdmin { $false }
function Test-EffectiveNonInteractive { param ([switch]$NonInteractive) [bool]$NonInteractive }
function Test-IsContinuousIntegration { $false }
function Write-Prompt { param ([string]$Message) Write-Host "PROMPT: $Message"; throw 'no key press in tests' }
function Get-ScriptExecutionPolicyBlock { param([string]$Engine) $null }
function Invoke-WingetUninstall { param ([switch]$WhatIf) Write-Host 'UNINSTALL RAN'; 0 }
'@
        # The elevated Windows PowerShell, standing in: prints what it was asked to start and "ends"
        # with exit code 3 at once.
        $script:uninstallerElevatedRun = @'
function Start-ElevatedProcess {
    param ([string]$FilePath, [string]$ArgumentString)
    Write-Host "ELEVATED: $FilePath $ArgumentString"
    $process = [pscustomobject]@{ ExitCode = 3 }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param ($Milliseconds) $true }
    $process
}
'@
    }

    It 'Runs a copy checked against the file''s SHA256, never the file itself, waits for it and exits with its exit code' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'uninstaller-relaunch') -Overrides ($script:uninstallerNotElevated + "`n" + $script:uninstallerElevatedRun)
        $sha256 = (Get-FileHash -LiteralPath $run.Path -Algorithm SHA256).Hash

        $run.ExitCode | Should -Be 3
        # System32's Windows PowerShell, running the check-and-copy command, not the file itself.
        $run.Output | Should -Match 'ELEVATED: \S*\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe -NoProfile -ExecutionPolicy Bypass -Command "'
        $run.Output | Should -Not -Match ([regex]::Escape("-File `"$($run.Path)`""))
        $run.Output | Should -Not -Match ([regex]::Escape("-File $($run.Path)"))
        # The SHA256 the entry block took at startup; the copy keeps the uninstaller's own name and is
        # run with no switches forwarded.
        $run.Output | Should -Match ([regex]::Escape("-ne '$sha256'"))
        $run.Output | Should -Match ([regex]::Escape("Join-Path `$copyDirectory 'winget-app-uninstall.ps1';"))
        $run.Output | Should -Match ([regex]::Escape('-File $copy;'))
        $run.Output | Should -Match 'The elevated run ended with exit code 3\.'
        # The elevated window showed the outcome and waited for its own key press.
        $run.Output | Should -Not -Match 'UNINSTALL RAN|PROMPT:'
    }

    It 'Does not relaunch a file that changed after the run started, and exits 5' {
        # The file is rewritten while the run is still going, before it asks for elevation: here, in
        # the admin check, the last thing the run does before it relaunches.
        $tamperOverride = @'
function Test-IsAdmin {
    Add-Content -LiteralPath $PSCommandPath -Value '# rewritten before the UAC prompt'
    $false
}
'@
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'uninstaller-tampered') -Overrides ($script:uninstallerNotElevated + "`n" + $script:uninstallerElevatedRun + "`n" + $tamperOverride)

        $run.ExitCode | Should -Be 5
        $run.Output | Should -Match 'changed after this run started, so it is not run with administrator rights'
        $run.Output | Should -Not -Match 'ELEVATED:|UNINSTALL RAN'
        # No UAC prompt was shown, so the run does not say to approve one.
        $run.Output | Should -Not -Match 'approve the administrator|declined'
    }

    It 'Exits 4 after one UAC prompt when the prompt is declined' {
        $declinedOverride = @'
function Start-ElevatedProcess {
    param ([string]$FilePath, [string]$ArgumentString)
    Write-Host 'UAC PROMPT SHOWN'
    throw [System.Management.Automation.MethodInvocationException]::new('Exception calling "Start"', [System.ComponentModel.Win32Exception]::new(1223))
}
'@
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'uninstaller-declined') -Overrides ($script:uninstallerNotElevated + "`n" + $declinedOverride)

        $run.ExitCode | Should -Be 4
        ([regex]::Matches($run.Output, 'UAC PROMPT SHOWN')).Count | Should -Be 1
        $run.Output | Should -Match 'The administrator \(UAC\) prompt was declined'
        $run.Output | Should -Not -Match 'UNINSTALL RAN'
    }

    It 'Exits 4 without a UAC prompt when the run is non-interactive' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'uninstaller-unattended') -Overrides ($script:uninstallerNotElevated + "`n" + $script:uninstallerElevatedRun) -ScriptArguments @('-NonInteractive')

        $run.ExitCode | Should -Be 4
        $run.Output | Should -Not -Match 'ELEVATED:|UNINSTALL RAN|PROMPT:'
        $run.Output | Should -Match 'this run is non-interactive, so there is nobody to approve a UAC prompt'
    }

    It 'Exits 4 without a UAC prompt when Group Policy''s machine execution policy would refuse the elevated run' {
        $policyOverride = "function Get-ScriptExecutionPolicyBlock { param([string]`$Engine) if (`$Engine -eq 'WindowsPowerShell') { [pscustomobject]@{ Engine = `$Engine; Scope = 'MachinePolicy'; Policy = 'AllSigned'; Key = 'HKLM\K'; GroupPolicyPath = 'Computer Configuration > P'; Description = 'Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned (MachinePolicy, HKLM\K)' } } }"
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'uninstaller-policy') -Overrides ($script:uninstallerNotElevated + "`n" + $script:uninstallerElevatedRun + "`n" + $policyOverride)

        $run.ExitCode | Should -Be 4
        $run.Output | Should -Not -Match 'ELEVATED:|UNINSTALL RAN'
        $run.Output | Should -Match 'Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned .*cannot run this script from a file.* No UAC prompt was shown\.'
    }
}
