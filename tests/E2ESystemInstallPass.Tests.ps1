# E2ESystemInstallPass.Tests.ps1
# Tests for e2e/Invoke-SystemInstallPass.ps1, the e2e-install-system job of
# .github/workflows/e2e-install.yml (work-order item 34): the run as SYSTEM, started through the RMM
# wrapper by a 32-bit Windows PowerShell from a scheduled task, as Endpoint Central would. The task
# handling needs Windows; the checks it applies afterwards read only what they are given and are
# tested here.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')

    $script:Sha256 = 'AB' * 32
    $script:GoodWrapperLog = @(
        'winget-app-setup RMM wrapper (machine phase): running as NT AUTHORITY\SYSTEM, 64-bit process: True, PowerShell 5.1.26100.1.',
        'Started by a 32-bit PowerShell on 64-bit Windows, and relaunched in 64-bit Windows PowerShell through Sysnative.',
        "Installer checked (SHA256 $($script:Sha256)).",
        'The installer exited with 0. Its transcripts and last-run.json are in C:\ProgramData\winget-app-setup\logs.'
    ) -join "`r`n"

    # What windows-latest prints since work-order item 31: the framework is missing, the SYSTEM run
    # installs the pinned one, then Winget-AutoUpdate, and exits 0.
    $script:RuntimeInstalledLines = @(
        'Microsoft.WindowsAppRuntime.1.8 is missing; installing the pinned Windows App Runtime 1.8.12 (framework 8000.994.2142.0, X64) for all users first...',
        'Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.'
    )
    $script:FrameworkMissing = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'

    function New-TestTranscript {
        param (
            [switch]$NotSystem,
            [string]$AutoUpdates = 'Configured (Winget-AutoUpdate v2.12.0).',
            [AllowEmptyCollection()][string[]]$RuntimeLines = $script:RuntimeInstalledLines,
            [AllowEmptyCollection()][string[]]$Deferred = @('Microsoft.WindowsTerminal')
        )
        $lines = @('Installer build: 1.0.0+5ea1f00d')
        if (-not $NotSystem) {
            $lines += 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only.'
        }
        $lines += $RuntimeLines
        $lines += @('Summary:', '', 'Status    Apps', '------    ----', 'Installed 7zip.7zip')
        if ($Deferred.Count -gt 0) {
            $lines += ('Deferred  {0}' -f ($Deferred -join ', '))
        }
        $lines += "Auto-updates: $AutoUpdates"
        [pscustomobject]@{ Name = 'install-20261005-060010.log'; Parsed = (ConvertFrom-InstallTranscript -Content ($lines -join "`n")) }
    }

    function New-TestRunRecord {
        param ($ExitCode = 0, $SummaryReached = $true, [object[]]$Deferred = @([pscustomobject]@{ id = 'Microsoft.WindowsTerminal'; status = 'Deferred'; reason = 'winget found no machine-wide installer for it' }))
        [pscustomobject]@{
            exitCode       = $ExitCode
            summaryReached = $SummaryReached
            apps           = @([pscustomobject]@{ id = '7zip.7zip'; status = 'Installed'; reason = $null }) + @($Deferred)
        }
    }

    function Get-TestResult {
        param ($TaskExitCode = 0, $Transcript = (New-TestTranscript), $WrapperLog = $script:GoodWrapperLog, $RunRecord = (New-TestRunRecord), [string[]]$NewEntries = @())
        Get-SystemInstallPassResult -TaskExitCode $TaskExitCode -Transcript $Transcript -WrapperLog $WrapperLog -RunRecord $RunRecord -NewSystemProfileEntries $NewEntries
    }

    function Get-Row {
        param ($Result, [string]$Assertion)
        $Result.Results | Where-Object Assertion -EQ $Assertion
    }
}

Describe 'Get-SystemInstallPassResult' {
    It 'Passes a SYSTEM run that relaunched in 64-bit, ran the checked installer as SYSTEM, installed the framework and Winget-AutoUpdate, and exited 0' {
        $result = Get-TestResult

        $result.StepExitCode | Should -Be 0
        @($result.Results | Where-Object Result -EQ 'FAIL') | Should -BeNullOrEmpty
        @($result.Results).Count | Should -Be 10
        (Get-Row $result 'last-run.json records the run').Detail | Should -Be 'exitCode 0, summaryReached True, deferred: Microsoft.WindowsTerminal'
        (Get-Row $result 'Auto-updates configured by the SYSTEM run').Detail | Should -Be 'install-20261005-060010.log: Auto-updates: Configured (Winget-AutoUpdate v2.12.0).'
        (Get-Row $result 'Windows App Runtime installed once, or already there').Detail | Should -Be 'install-20261005-060010.log: Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.'
        (Get-Row $result 'Deferred apps recorded for the user phase').Detail | Should -Be 'deferred, each with its reason: Microsoft.WindowsTerminal (winget found no machine-wide installer for it)'
    }

    # Work-order item 31: the runner gets the framework now, so the leg checks what the other legs'
    # Assert-Install.ps1 checks: WAU set up, and the framework installed once.
    It 'Still accepts exit 8 for the missing framework when the installer could not try to install it' {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 0', 'exited with 8'

        $result = Get-TestResult -TaskExitCode 8 -WrapperLog $wrapper -Transcript (New-TestTranscript -AutoUpdates $script:FrameworkMissing -RuntimeLines @('Windows App Runtime: NOT INSTALLED - installing it for all users needs administrator rights.')) -RunRecord (New-TestRunRecord -ExitCode 8)

        $result.StepExitCode | Should -Be 0
        (Get-Row $result 'Auto-updates configured by the SYSTEM run').Result | Should -Be 'PASS'
        (Get-Row $result 'Auto-updates configured by the SYSTEM run').Detail | Should -Match 'accepted: the framework is missing and the installer could not try to install it'
        (Get-Row $result 'Windows App Runtime installed once, or already there').Result | Should -Be 'PASS'
    }

    It 'Fails exit 8 when the framework install started and failed' {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 0', 'exited with 8'
        $runtime = @($script:RuntimeInstalledLines[0], 'Windows App Runtime: NOT INSTALLED - Add-AppxProvisionedPackage failed (its error is above).')

        $result = Get-TestResult -TaskExitCode 8 -WrapperLog $wrapper -Transcript (New-TestTranscript -AutoUpdates $script:FrameworkMissing -RuntimeLines $runtime) -RunRecord (New-TestRunRecord -ExitCode 8)

        $result.StepExitCode | Should -Be 8
        (Get-Row $result 'Auto-updates configured by the SYSTEM run').Result | Should -Be 'FAIL'
        (Get-Row $result 'Windows App Runtime installed once, or already there').Result | Should -Be 'FAIL'
    }

    It 'Fails a run that reports no auto-updates set up, whatever its exit code' {
        $result = Get-TestResult -Transcript (New-TestTranscript -AutoUpdates 'UNHEALTHY - Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate is disabled; apps will not update automatically (see above).')

        $result.StepExitCode | Should -Be 1
        (Get-Row $result 'Auto-updates configured by the SYSTEM run').Result | Should -Be 'FAIL'
    }

    It 'Fails a run that installed the framework twice, and passes one that found it there' {
        $twice = Get-TestResult -Transcript (New-TestTranscript -RuntimeLines @($script:RuntimeInstalledLines + $script:RuntimeInstalledLines))
        (Get-Row $twice 'Windows App Runtime installed once, or already there').Result | Should -Be 'FAIL'
        (Get-Row $twice 'Windows App Runtime installed once, or already there').Detail | Should -Be 'install-20261005-060010.log installed it 2 times in one run'
        $twice.StepExitCode | Should -Be 1

        $present = Get-TestResult -Transcript (New-TestTranscript -AutoUpdates 'Already present (v2.12.0).' -RuntimeLines @())
        (Get-Row $present 'Windows App Runtime installed once, or already there').Result | Should -Be 'PASS'
        $present.StepExitCode | Should -Be 0
    }

    # Work-order items 34 and 38: the user phase installs the Deferred entries of last-run.json by id.
    It 'Passes the per-user deferrals item 38 records, each with its own reason' {
        $deferred = @(
            [pscustomobject]@{ id = 'Contoso.UserSetting'; status = 'Deferred'; reason = (Get-AppDeferReasonText -DeferReason 'UserPhase') }
            [pscustomobject]@{ id = 'Contoso.UserApp'; status = 'Deferred'; reason = (Get-AppDeferReasonText -DeferReason 'UserScope') }
        )

        $result = Get-TestResult -Transcript (New-TestTranscript -Deferred @('Contoso.UserSetting', 'Contoso.UserApp')) -RunRecord (New-TestRunRecord -Deferred $deferred)

        (Get-Row $result 'Deferred apps recorded for the user phase').Result | Should -Be 'PASS'
        $result.StepExitCode | Should -Be 0
    }

    It 'Fails when a Deferred entry <Case>' -ForEach @(
        @{ Case = 'has no reason'; Entry = [pscustomobject]@{ id = 'Microsoft.WindowsTerminal'; status = 'Deferred'; reason = $null }; Detail = 'Microsoft.WindowsTerminal has no reason' }
        @{ Case = 'has no winget package id'; Entry = [pscustomobject]@{ id = 'not an id'; status = 'Deferred'; reason = 'x' }; Detail = "'not an id' is not a winget package id" }
    ) {
        $result = Get-TestResult -Transcript (New-TestTranscript -Deferred @($Entry.id)) -RunRecord (New-TestRunRecord -Deferred @($Entry))

        (Get-Row $result 'Deferred apps recorded for the user phase').Result | Should -Be 'FAIL'
        (Get-Row $result 'Deferred apps recorded for the user phase').Detail | Should -Match ([regex]::Escape($Detail))
        $result.StepExitCode | Should -Be 1
    }

    It 'Fails when the summary''s Deferred row and last-run.json disagree, and passes with nothing deferred' {
        $mismatch = Get-TestResult -Transcript (New-TestTranscript -Deferred @())
        (Get-Row $mismatch 'Deferred apps recorded for the user phase').Result | Should -Be 'FAIL'

        $none = Get-TestResult -Transcript (New-TestTranscript -Deferred @()) -RunRecord (New-TestRunRecord -Deferred @())
        (Get-Row $none 'Deferred apps recorded for the user phase').Detail | Should -Be 'nothing deferred'
        $none.StepExitCode | Should -Be 0
    }

    It 'Passes exit <Code>' -ForEach @(@{ Code = 0 }, @{ Code = 3010 }) {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 0', "exited with $Code"

        (Get-TestResult -TaskExitCode $Code -WrapperLog $wrapper -RunRecord (New-TestRunRecord -ExitCode $Code)).StepExitCode | Should -Be 0
    }

    It 'Fails with the run''s own code when the exit code fails the pass policy (<Case>)' -ForEach @(
        @{ Case = 'winget unavailable'; Code = 2; AutoUpdates = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing.' }
        @{ Case = '8 for another reason'; Code = 8; AutoUpdates = 'FAILED - Winget-AutoUpdate could not be installed.' }
    ) {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 0', "exited with $Code"

        $result = Get-TestResult -TaskExitCode $Code -WrapperLog $wrapper -Transcript (New-TestTranscript -AutoUpdates $AutoUpdates) -RunRecord (New-TestRunRecord -ExitCode $Code)

        $result.StepExitCode | Should -Be $Code
        (Get-Row $result 'SYSTEM run exit code').Result | Should -Be 'FAIL'
    }

    It 'Tolerates exit 1 only while KNOWN_PLATFORM_INCOMPATIBLE lists apps, and only when every app the run left failed is on it' {
        # Two apps failed for good (Google.GoogleDrive, Klocman.BulkCrapUninstaller) in a run as SYSTEM.
        $content = "Running as SYSTEM (for example from an RMM agent): installing for the whole PC only.`n" + [string](Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'tests/fixtures/e2e/timeouts.txt'))
        $transcript = [pscustomobject]@{ Name = 'install-20261005-060010.log'; Parsed = (ConvertFrom-InstallTranscript -Content $content) }
        $wrapper = $script:GoodWrapperLog -replace 'exited with 0', 'exited with 1'
        # The fixture's summary defers nothing.
        $arguments = @{ TaskExitCode = 1; Transcript = $transcript; WrapperLog = $wrapper; RunRecord = (New-TestRunRecord -ExitCode 1 -Deferred @()) }

        $strict = Get-SystemInstallPassResult @arguments
        (Get-Row $strict 'SYSTEM run exit code').Result | Should -Be 'FAIL'
        $strict.StepExitCode | Should -Be 1

        $contained = Get-SystemInstallPassResult @arguments -KnownPlatformIncompatible 'Google.GoogleDrive, Klocman.BulkCrapUninstaller'
        (Get-Row $contained 'SYSTEM run exit code').Result | Should -Be 'PASS'
        $row = Get-Row $contained 'Failures are all known platform-incompatible apps'
        $row.Result | Should -Be 'PASS'
        $row.Detail | Should -BeLike 'install-20261005-060010.log: failed apps all skip-listed: Google.GoogleDrive, Klocman.BulkCrapUninstaller*'
        $contained.StepExitCode | Should -Be 0

        $leaked = Get-SystemInstallPassResult @arguments -KnownPlatformIncompatible 'Google.GoogleDrive'
        $row = Get-Row $leaked 'Failures are all known platform-incompatible apps'
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be 'install-20261005-060010.log: apps outside -SkipApps failed: Klocman.BulkCrapUninstaller'
        $leaked.StepExitCode | Should -Be 1

        $noTranscript = Get-SystemInstallPassResult -TaskExitCode 1 -Transcript $null -WrapperLog $wrapper -RunRecord (New-TestRunRecord -ExitCode 1 -Deferred @()) -KnownPlatformIncompatible 'Google.GoogleDrive'
        (Get-Row $noTranscript 'Failures are all known platform-incompatible apps').Detail | Should -Be 'no transcript of the run, so its failures cannot be checked'
        $noTranscript.StepExitCode | Should -Be 1
    }

    It 'Fails, naming what landed there, when something was installed per-user into SYSTEM''s profile' {
        $entry = 'HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Uninstall\Contoso.UserOnly [Contoso User Only]'

        $result = Get-TestResult -NewEntries @($entry)

        $result.StepExitCode | Should -Be 1
        $row = Get-Row $result 'Nothing installed per-user into SYSTEM''s profile'
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be "installed per-user for SYSTEM: $entry"
    }

    It 'Fails when <Case>' -ForEach @(
        @{ Case = 'the wrapper was not relaunched from a 32-bit PowerShell'; Remove = 'Started by a 32-bit'; Assertion = 'Wrapper relaunched in 64-bit Windows PowerShell' }
        @{ Case = 'the wrapper did not check the installer'; Remove = 'Installer checked'; Assertion = 'Wrapper checked the installer''s SHA256' }
        @{ Case = 'the wrapper did not report the installer''s exit code'; Remove = 'The installer exited with'; Assertion = 'Wrapper passed the exit code back unchanged' }
    ) {
        $wrapper = (@($script:GoodWrapperLog -split "`r`n") | Where-Object { -not $_.StartsWith($Remove) }) -join "`r`n"

        $result = Get-TestResult -WrapperLog $wrapper

        $result.StepExitCode | Should -Be 1
        (Get-Row $result $Assertion).Result | Should -Be 'FAIL'
    }

    It 'Fails when the task''s exit code is not the installer''s' {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 0', 'exited with 8'
        $result = Get-TestResult -TaskExitCode 0 -WrapperLog $wrapper -RunRecord (New-TestRunRecord -ExitCode 0)

        (Get-Row $result 'Wrapper passed the exit code back unchanged').Detail | Should -Be 'the installer exited with 8, the task with 0'
        $result.StepExitCode | Should -Be 1
    }

    It 'Fails when the run did not run as SYSTEM, when last-run.json disagrees, and when there is no wrapper log or transcript' {
        (Get-Row (Get-TestResult -Transcript (New-TestTranscript -NotSystem)) 'Installer ran as SYSTEM').Result | Should -Be 'FAIL'
        (Get-Row (Get-TestResult -RunRecord (New-TestRunRecord -ExitCode 1)) 'last-run.json records the run').Result | Should -Be 'FAIL'
        (Get-Row (Get-TestResult -RunRecord (New-TestRunRecord -SummaryReached $false)) 'last-run.json records the run').Result | Should -Be 'FAIL'
        (Get-Row (Get-TestResult -RunRecord $null) 'last-run.json records the run').Detail | Should -Be 'no last-run.json'

        $nothing = Get-TestResult -TaskExitCode 0 -Transcript $null -WrapperLog $null -RunRecord $null
        (Get-Row $nothing 'Wrapper relaunched in 64-bit Windows PowerShell').Detail | Should -Be 'no wrapper log (install-<time>-rmm.log) from this run'
        (Get-Row $nothing 'Installer ran as SYSTEM').Detail | Should -Be 'no transcript of the run'
        $nothing.StepExitCode | Should -Be 1
    }

    It 'Fails when the task never finished' {
        $result = Get-TestResult -TaskExitCode $null

        (Get-Row $result 'SYSTEM run exit code').Detail | Should -Be 'the scheduled task did not finish'
        $result.StepExitCode | Should -Be 1
    }
}

Describe 'The SYSTEM pass helpers' {
    It 'Reads LastTaskResult <Result> as exit code <ExitCode>' -ForEach @(
        @{ Result = 0; ExitCode = 0 }
        @{ Result = 8; ExitCode = 8 }
        @{ Result = 3010; ExitCode = 3010 }
        @{ Result = 4294967295; ExitCode = -1 }
        @{ Result = 2316632080; ExitCode = -1978335216 }
    ) {
        ConvertTo-TaskExitCode -LastTaskResult $Result | Should -Be $ExitCode
    }

    It 'Builds the task''s arguments: the wrapper with the checkout''s installer and its SHA256' {
        Get-SystemPassTaskArgument -WrapperPath 'D:\a\repo\rmm\Invoke-WingetAppSetup.ps1' -InstallerPath 'D:\a\repo\winget-app-install.ps1' -InstallerSha256 $script:Sha256 |
            Should -Be "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""D:\a\repo\rmm\Invoke-WingetAppSetup.ps1"" -InstallerPath ""D:\a\repo\winget-app-install.ps1"" -InstallerSha256 $($script:Sha256)"
    }

    It 'Lists what is in SYSTEM''s Programs folders, and reports only what appeared' {
        $programs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $programs 'Existing') -Force
        $before = Get-SystemProfileInstallEntry -RegistryPath @('Registry::HKEY_USERS\S-1-5-18\Software\Contoso\NoSuchKey') -FolderPath @($programs, (Join-Path $TestDrive 'missing'))
        $null = New-Item -ItemType Directory -Path (Join-Path $programs 'Contoso.UserOnly')

        $after = Get-SystemProfileInstallEntry -RegistryPath @() -FolderPath @($programs)

        @($before) | Should -Be @((Join-Path $programs 'Existing'))
        Compare-SystemProfileInstallEntry -Before $before -After $after | Should -Be @((Join-Path $programs 'Contoso.UserOnly'))
        Compare-SystemProfileInstallEntry -Before $after -After $after | Should -BeNullOrEmpty
    }
}

Describe 'e2e/Invoke-SystemInstallPass.ps1 wiring' {
    It 'Keeps its own parameters apart from the ones dot-sourcing e2e/Invoke-InstallPass.ps1 sets' {
        # Dot-sourcing a script binds its param block in the caller's scope: a shared name would be
        # reset to Invoke-InstallPass.ps1's default before this script used it.
        $own = @([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1'), [ref]$null, [ref]$null).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $dotSourced = @([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'e2e/Invoke-InstallPass.ps1'), [ref]$null, [ref]$null).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

        $own | Should -Contain 'CheckoutInstallerPath'
        @($own | Where-Object { $dotSourced -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'Applies the workflow''s KNOWN_PLATFORM_INCOMPATIBLE, as the other legs do' {
        $script = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')

        $script | Should -Match 'Get-SystemInstallPassResult [^\r\n]*-KnownPlatformIncompatible "\$env:KNOWN_PLATFORM_INCOMPATIBLE"'
    }

    It 'Is run by the e2e-install-system job, which also watches rmm/ for pull requests' {
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')

        $workflow | Should -Match '(?m)^  e2e-install-system:'
        $workflow | Should -Match 'Invoke-SystemInstallPass\.ps1'
        $workflow | Should -Match "pattern='\^\(WingetAppSetup/\|build/\|e2e/\|rmm/\)"
        $workflow | Should -Match 'needs: \[e2e-install, e2e-install-windows-powershell, e2e-install-system, e2e-install-system-winget-client\]'
    }
}

# wgt-gq8.45: the other legs check each catalog app with winget list; the SYSTEM leg checks each
# one's entry in last-run.json. tests/fixtures/e2e/system-last-run.json is a sample record of that
# run on windows-latest, built with New-AppRunRecord and New-InstallerRunRecord and written as
# Save-InstallerRunRecord writes it.
Describe 'What the catalog expects of a run as SYSTEM' {
    BeforeAll {
        $script:RemovalScriptPath = Join-Path $script:RepoRoot 'e2e/Remove-PreinstalledApps.ps1'

        function Get-ExpectationById {
            param ([hashtable[]]$Catalog = @(Get-DefaultAppCatalog))
            $verdicts = Get-SystemRunApplicability -Catalog $Catalog
            $byId = @{}
            foreach ($expectation in (Get-SystemPassAppExpectation -Catalog $Catalog -Applicability $verdicts -RemovedApps (Get-PreinstalledAppRemovalList -ScriptPath $script:RemovalScriptPath))) {
                $byId[$expectation.Id] = $expectation
            }
            return $byId
        }
    }

    BeforeEach {
        # windows-latest: x64, not Dell. Windows Terminal hosting this session would make its entry
        # not apply for an interactive run; a run as SYSTEM has no Terminal session.
        Mock Get-OSArchitecture { 'X64' }
        Mock Get-ComputerManufacturer { 'Microsoft Corporation' }
        Mock Test-WindowsTerminalHostsCurrentSession { $true }
    }

    It 'Reads the apps the job uninstalls first from e2e/Remove-PreinstalledApps.ps1''s defaults' {
        Get-PreinstalledAppRemovalList -ScriptPath $script:RemovalScriptPath | Should -Be @('Google.Chrome', '7zip.7zip', 'Git.Git')
    }

    It 'Throws when the removal script has no -PackageId default' {
        $path = Join-Path $TestDrive 'NoDefault.ps1'
        Set-Content -LiteralPath $path -Value 'param ([string[]]$PackageId)'

        { Get-PreinstalledAppRemovalList -ScriptPath $path } | Should -Throw '*has no default value for -PackageId*'
    }

    It 'Evaluates Windows Terminal''s condition as SYSTEM, where it applies even when Windows Terminal hosts this session' {
        $terminal = Get-DefaultAppCatalog | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }
        # A local stand-in, not a Mock: Pester's mock would take precedence over the one
        # Get-SystemRunApplicability defines, which is the mechanism under test.
        function Test-IsSystemAccount { return $false }

        Test-AppApplicability -App $terminal | Should -BeFalse
        (Get-SystemRunApplicability -Catalog @($terminal))['Microsoft.WindowsTerminal'] | Should -BeTrue
        Test-AppApplicability -App $terminal | Should -BeFalse
    }

    It 'Evaluates the conditions in the imported module''s session state, where they are bound, without changing the module' {
        $probe = Join-Path $TestDrive 'Probe-SystemRunApplicability.ps1'
        $lines = @(
            '$ErrorActionPreference = ''Stop'''
            ('$module = Import-Module -Name ''{0}'' -Force -PassThru' -f (Join-Path $script:RepoRoot 'WingetAppSetup/WingetAppSetup.psd1').Replace("'", "''"))
            ('. ''{0}''' -f (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1').Replace("'", "''"))
            '& $module { function script:Test-IsSystemAccount { $false }; function script:Test-WindowsTerminalHostsCurrentSession { $true }; function script:Get-OSArchitecture { ''X64'' }; function script:Get-ComputerManufacturer { ''Dell Inc.'' } }'
            '$catalog = @(Get-DefaultAppCatalog)'
            '$terminal = $catalog | Where-Object { $_.name -eq ''Microsoft.WindowsTerminal'' }'
            '$before = Test-AppApplicability -App $terminal'
            '$verdicts = Get-SystemRunApplicability -Catalog $catalog -Module $module'
            '$after = Test-AppApplicability -App $terminal'
            '[pscustomobject]@{ Before = $before; System = $verdicts[''Microsoft.WindowsTerminal'']; After = $after; Dell = $verdicts[''Dell.CommandUpdate.Universal'']; Reader32 = $verdicts[''Adobe.Acrobat.Reader.32-bit''] } | ConvertTo-Json -Compress'
        )
        Set-Content -LiteralPath $probe -Value $lines

        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $probe 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $verdict = ConvertFrom-Json -InputObject ([string]($output | Select-Object -Last 1))

        $verdict.Before | Should -BeFalse
        $verdict.System | Should -BeTrue
        $verdict.After | Should -BeFalse
        $verdict.Dell | Should -BeTrue
        $verdict.Reader32 | Should -BeFalse
    }

    It 'Expects every app on windows-latest, as SYSTEM: Installed or already there, the removed apps Installed, the ARM64 Reader and Dell Command Update not applicable' {
        $byId = Get-ExpectationById

        @($byId.Keys).Count | Should -Be @(Get-DefaultAppCatalog).Count
        @($byId.Values | Where-Object { $_.Expected -eq 'Installed' } | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @('7zip.7zip', 'Adobe.Acrobat.Reader.64-bit', 'Git.Git', 'GlavSoft.TightVNC', 'Google.Chrome', 'Google.GoogleDrive', 'Klocman.BulkCrapUninstaller', 'Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
        @($byId.Values | Where-Object { $_.MustInstall } | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @('7zip.7zip', 'Git.Git', 'Google.Chrome')
        $byId['Dell.CommandUpdate.Universal'].Expected | Should -Be 'NotApplicable'
        $byId['Dell.CommandUpdate.Universal'].Reason | Should -Be 'not applicable: Dell hardware with x64 Windows only; winget has no ARM64 installer for it'
        $byId['Adobe.Acrobat.Reader.32-bit'].Reason | Should -Be 'not applicable: ARM64 and 32-bit Windows only; x64 PCs get the 64-bit Reader'
        # A run as SYSTEM checks an MSIX app by its provisioning, not with winget list.
        $byId['Microsoft.WindowsTerminal'].AlreadyPresentReasons | Should -Be @('already provisioned for every user on this PC')
        $byId['Microsoft.PowerShell'].AlreadyPresentReasons | Should -Be @('already installed')
    }

    It 'Follows the catalog''s conditions on another PC: ARM64 Dell' {
        Mock Get-OSArchitecture { 'Arm64' }
        Mock Get-ComputerManufacturer { 'Dell Inc.' }

        $byId = Get-ExpectationById

        $byId['Adobe.Acrobat.Reader.64-bit'].Expected | Should -Be 'NotApplicable'
        $byId['Adobe.Acrobat.Reader.64-bit'].Reason | Should -Be 'not applicable: its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows'
        $byId['Adobe.Acrobat.Reader.32-bit'].Expected | Should -Be 'Installed'
        # Dell Command Update is x64-only in winget (wgt-gq8.44), so even a Dell PC skips it on ARM64.
        $byId['Dell.CommandUpdate.Universal'].Expected | Should -Be 'NotApplicable'
        $byId['Dell.CommandUpdate.Universal'].Reason | Should -Be 'not applicable: Dell hardware with x64 Windows only; winget has no ARM64 installer for it'
    }

    It 'Expects per-user work Deferred with its reason, an app that does not apply Skipped first, and fails open without a verdict' {
        $catalog = @(
            @{ name = 'Contoso.UserApp'; scope = 'user' }
            @{ name = 'Contoso.UserSetting'; userPhase = $true }
            @{ name = 'Contoso.Elsewhere'; userPhase = $true; condition = { $false }; conditionDescription = 'never here' }
            @{ name = 'Contoso.NoVerdict' }
        )
        $verdicts = @{ 'Contoso.UserApp' = $true; 'Contoso.UserSetting' = $true; 'Contoso.Elsewhere' = $false }

        $expectations = @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability $verdicts)

        $expectations[0].Expected | Should -Be 'Deferred'
        $expectations[0].Reason | Should -Be (Get-AppDeferReasonText -DeferReason 'UserScope')
        $expectations[1].Expected | Should -Be 'Deferred'
        $expectations[1].Reason | Should -Be (Get-AppDeferReasonText -DeferReason 'UserPhase')
        $expectations[2].Expected | Should -Be 'NotApplicable'
        $expectations[2].Reason | Should -Be 'not applicable: never here'
        $expectations[3].Expected | Should -Be 'Installed'
        $expectations[3].MustInstall | Should -BeFalse
    }

    It 'Matches the reasons the installer records: <Text>' -ForEach @(
        @{ Text = '$skipReason = ''already installed''' }
        @{ Text = '$skipReason = ''already provisioned for every user on this PC''' }
        @{ Text = 'New-AppRunRecord -Id $app.name -Status ''Skipped'' -Reason $skipReason' }
        @{ Text = '$skipReason = "not applicable: $conditionText"' }
        @{ Text = 'New-AppRunRecord -Id $app.name -Status ''Deferred'' -Reason $deferText' }
    ) {
        Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'WingetAppSetup/Public/Install.ps1') | Should -Match ([regex]::Escape($Text))
    }
}

Describe 'Get-SystemInstallPassResult: each catalog app in last-run.json' {
    BeforeAll {
        $script:SystemRecordPath = Join-Path $script:RepoRoot 'tests/fixtures/e2e/system-last-run.json'

        function Get-FixtureRecord {
            return (Read-SystemPassRunRecord -Path $script:SystemRecordPath).Record
        }

        function Get-WindowsLatestExpectation {
            $catalog = @(Get-DefaultAppCatalog)
            return @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability (Get-SystemRunApplicability -Catalog $catalog) -RemovedApps (Get-PreinstalledAppRemovalList -ScriptPath (Join-Path $script:RepoRoot 'e2e/Remove-PreinstalledApps.ps1')))
        }

        function Get-AppCheckResult {
            param ($RunRecord, [string]$RunRecordProblem, [string]$KnownPlatformIncompatible = '', [switch]$NoExpectation, [string]$AppExpectationProblem)
            # The summary's Deferred row agrees with the record, as in a real run.
            $deferredIds = @()
            if ($null -ne $RunRecord -and $null -ne $RunRecord.PSObject.Properties['apps']) {
                $deferredIds = @($RunRecord.apps | Where-Object { $_.status -eq 'Deferred' } | ForEach-Object { $_.id })
            }
            $arguments = @{
                TaskExitCode              = 0
                Transcript                = (New-TestTranscript -Deferred $deferredIds)
                WrapperLog                = $script:GoodWrapperLog
                RunRecord                 = $RunRecord
                RunRecordProblem          = $RunRecordProblem
                KnownPlatformIncompatible = $KnownPlatformIncompatible
            }
            if ($AppExpectationProblem) {
                $arguments.AppExpectationProblem = $AppExpectationProblem
            }
            elseif (-not $NoExpectation) {
                $arguments.AppExpectation = Get-WindowsLatestExpectation
            }
            return (Get-SystemInstallPassResult @arguments)
        }

        function Get-FailedAssertion {
            param ($Result)
            return @($Result.Results | Where-Object Result -EQ 'FAIL' | ForEach-Object { $_.Assertion })
        }
    }

    BeforeEach {
        Mock Get-OSArchitecture { 'X64' }
        Mock Get-ComputerManufacturer { 'Microsoft Corporation' }
        Mock Test-WindowsTerminalHostsCurrentSession { $true }
    }

    It 'Has the shape New-InstallerRunRecord and New-AppRunRecord give last-run.json' {
        $record = Get-FixtureRecord
        $built = New-InstallerRunRecord -ExitCode 0 -Apps @(New-AppRunRecord -Id '7zip.7zip' -Status 'Installed')

        @($record.PSObject.Properties.Name) | Should -Be @($built.Keys)
        $record.schemaVersion | Should -Be $built.schemaVersion
        foreach ($entry in $record.apps) {
            @($entry.PSObject.Properties.Name) | Should -Be @($built.apps[0].Keys)
        }
        @($record.apps | ForEach-Object { $_.id }) | Should -Be @(Get-DefaultAppCatalog | ForEach-Object { $_.name })
    }

    It 'Passes the record of a SYSTEM run on windows-latest, with one row per catalog app' {
        $result = Get-AppCheckResult -RunRecord (Get-FixtureRecord)

        Get-FailedAssertion $result | Should -BeNullOrEmpty
        $result.StepExitCode | Should -Be 0
        @($result.Results).Count | Should -Be (10 + 1 + @(Get-DefaultAppCatalog).Count)
        (Get-Row $result 'last-run.json lists the catalog''s apps').Detail | Should -Be 'schemaVersion 1, 11 entries for the catalog''s 11 apps'
        (Get-Row $result 'App installed: Google.Chrome').Detail | Should -Be 'last-run.json: Installed'
        (Get-Row $result 'App installed: GlavSoft.TightVNC').Detail | Should -Be 'last-run.json: Installed, post-install NotConfigured'
        (Get-Row $result 'App installed: Microsoft.PowerShell').Detail | Should -Be 'last-run.json: Skipped (already installed)'
        (Get-Row $result 'App installed: Microsoft.WindowsTerminal').Detail | Should -Be 'last-run.json: Skipped (already provisioned for every user on this PC)'
        (Get-Row $result 'Not-applicable skip recorded: Dell.CommandUpdate.Universal').Detail | Should -Be 'last-run.json: Skipped (not applicable: Dell hardware with x64 Windows only; winget has no ARM64 installer for it)'
        (Get-Row $result 'Not-applicable skip recorded: Adobe.Acrobat.Reader.32-bit').Result | Should -Be 'PASS'
    }

    It 'Notes a restart and a non-zero install code on an installed app' {
        $record = Get-FixtureRecord
        $entry = $record.apps | Where-Object id -EQ 'Git.Git'
        $entry.code = 3010
        $entry.codeHex = '0x00000BC2'
        $entry.restartRequired = $true

        $result = Get-AppCheckResult -RunRecord $record

        (Get-Row $result 'App installed: Git.Git').Detail | Should -Be 'last-run.json: Installed, code 0x00000BC2, restart required'
        $result.StepExitCode | Should -Be 0
    }

    It 'Fails <Case>' -ForEach @(
        @{ Case = 'an app with no entry'; Change = { param ($r) $r.apps = @($r.apps | Where-Object id -NE 'Google.GoogleDrive') }; Assertion = 'App installed: Google.GoogleDrive'; Detail = 'no entry in last-run.json' }
        @{ Case = 'a Failed app'; Change = { param ($r) $e = $r.apps | Where-Object id -EQ 'Klocman.BulkCrapUninstaller'; $e.status = 'Failed'; $e.reason = 'winget install exited 0x8A15002B' }; Assertion = 'App installed: Klocman.BulkCrapUninstaller'; Detail = 'last-run.json: Failed (winget install exited 0x8A15002B)' }
        @{ Case = 'a Deferred machine-wide app'; Change = { param ($r) $e = $r.apps | Where-Object id -EQ 'Adobe.Acrobat.Reader.64-bit'; $e.status = 'Deferred'; $e.reason = 'winget found no machine-wide installer for it' }; Assertion = 'App installed: Adobe.Acrobat.Reader.64-bit'; Detail = 'last-run.json: Deferred (winget found no machine-wide installer for it); its catalog entry is not per-user, so the run as SYSTEM had to install it for the whole PC' }
        @{ Case = 'an app the job removed first that the run only skipped'; Change = { param ($r) $e = $r.apps | Where-Object id -EQ 'Google.Chrome'; $e.status = 'Skipped'; $e.reason = 'already installed' }; Assertion = 'App installed: Google.Chrome'; Detail = 'last-run.json: Skipped (already installed); the job uninstalled it before the run (e2e/Remove-PreinstalledApps.ps1), so the run had to install it: see that step''s warnings' }
        @{ Case = 'Windows Terminal skipped as not applicable, although it applies as SYSTEM'; Change = { param ($r) $e = $r.apps | Where-Object id -EQ 'Microsoft.WindowsTerminal'; $e.reason = 'not applicable: winget cannot self-update Windows Terminal from a session Windows Terminal itself is hosting (issue #271)' }; Assertion = 'App installed: Microsoft.WindowsTerminal'; Detail = '; it applies to this PC as SYSTEM, so expected Installed, or Skipped (already provisioned for every user on this PC)' }
        @{ Case = 'an MSIX app skipped by winget list, not by its provisioning'; Change = { param ($r) ($r.apps | Where-Object id -EQ 'Microsoft.WindowsTerminal').reason = 'already installed' }; Assertion = 'App installed: Microsoft.WindowsTerminal'; Detail = 'last-run.json: Skipped (already installed); it applies to this PC as SYSTEM' }
        @{ Case = 'an app that does not apply but was installed'; Change = { param ($r) $e = $r.apps | Where-Object id -EQ 'Dell.CommandUpdate.Universal'; $e.status = 'Installed'; $e.reason = $null }; Assertion = 'Not-applicable skip recorded: Dell.CommandUpdate.Universal'; Detail = 'last-run.json: Installed; expected Skipped (not applicable: Dell hardware with x64 Windows only; winget has no ARM64 installer for it)' }
        @{ Case = 'an app that does not apply, skipped for another reason'; Change = { param ($r) ($r.apps | Where-Object id -EQ 'Adobe.Acrobat.Reader.32-bit').reason = 'already installed' }; Assertion = 'Not-applicable skip recorded: Adobe.Acrobat.Reader.32-bit'; Detail = 'last-run.json: Skipped (already installed); expected Skipped (not applicable: ARM64 and 32-bit Windows only; x64 PCs get the 64-bit Reader)' }
        @{ Case = 'an app recorded twice'; Change = { param ($r) $r.apps = @($r.apps) + @($r.apps | Where-Object id -EQ '7zip.7zip') }; Assertion = 'App installed: 7zip.7zip'; Detail = '2 entries in last-run.json: Installed; Installed' }
    ) {
        $record = Get-FixtureRecord
        & $Change $record

        $result = Get-AppCheckResult -RunRecord $record

        Get-FailedAssertion $result | Should -Be @($Assertion)
        (Get-Row $result $Assertion).Detail | Should -BeLike "*$Detail*"
        $result.StepExitCode | Should -Be 1
    }

    It 'Fails an entry for an app the catalog does not have, and checks every catalog app still' {
        $record = Get-FixtureRecord
        $record.apps = @($record.apps) + @([pscustomobject]@{ id = 'Contoso.Extra'; status = 'Installed'; reason = $null })

        $result = Get-AppCheckResult -RunRecord $record

        Get-FailedAssertion $result | Should -Be @('last-run.json lists the catalog''s apps')
        (Get-Row $result 'last-run.json lists the catalog''s apps').Detail | Should -Be 'entries for apps the catalog does not have: Contoso.Extra'
        $result.StepExitCode | Should -Be 1
    }

    It 'Fails with one row, and no per-app rows, when last-run.json <Case>' -ForEach @(
        @{ Case = 'is another schema version'; Change = { param ($r) $r.schemaVersion = 2 }; Detail = 'schemaVersion ''2'', not 1, the record New-InstallerRunRecord writes and this check reads' }
        @{ Case = 'has no apps list'; Change = { param ($r) $r.PSObject.Properties.Remove('apps') }; Detail = 'the record has no apps list' }
    ) {
        $record = Get-FixtureRecord
        & $Change $record

        $result = Get-AppCheckResult -RunRecord $record

        Get-FailedAssertion $result | Should -Be @('last-run.json lists the catalog''s apps')
        (Get-Row $result 'last-run.json lists the catalog''s apps').Detail | Should -Be $Detail
        @($result.Results | Where-Object { $_.Assertion -like 'App installed: *' -or $_.Assertion -like 'Not-applicable skip recorded: *' }) | Should -BeNullOrEmpty
        $result.StepExitCode | Should -Be 1
    }

    It 'Fails, saying why, when last-run.json <Case>' -ForEach @(
        @{ Case = 'is cut off'; Content = '{ "schemaVersion": 1, "apps": [ { "id": "7zip.7zip"'; Detail = 'could not read *' }
        @{ Case = 'is empty'; Content = ''; Detail = '* is empty' }
        @{ Case = 'is missing'; Content = $null; Detail = 'no last-run.json at *' }
    ) {
        $path = Join-Path $TestDrive ('last-run-{0}.json' -f [guid]::NewGuid().ToString('N'))
        if ($null -ne $Content) {
            [System.IO.File]::WriteAllText($path, $Content)
        }
        $read = Read-SystemPassRunRecord -Path $path

        $result = Get-AppCheckResult -RunRecord $read.Record -RunRecordProblem $read.Problem

        $read.Record | Should -BeNullOrEmpty
        $read.Problem | Should -BeLike $Detail
        (Get-Row $result 'last-run.json lists the catalog''s apps').Detail | Should -Be $read.Problem
        (Get-Row $result 'last-run.json records the run').Detail | Should -Be $read.Problem
        $result.StepExitCode | Should -Be 1
    }

    It 'Reads the sample record' {
        $read = Read-SystemPassRunRecord -Path $script:SystemRecordPath

        $read.Problem | Should -BeNullOrEmpty
        $read.Record.exitCode | Should -Be 0
    }

    It 'Fails when the catalog could not be read' {
        $result = Get-AppCheckResult -RunRecord (Get-FixtureRecord) -AppExpectationProblem 'could not work out what the catalog expects: boom'

        Get-FailedAssertion $result | Should -Be @('last-run.json lists the catalog''s apps')
        (Get-Row $result 'last-run.json lists the catalog''s apps').Detail | Should -Be 'could not work out what the catalog expects: boom'
        $result.StepExitCode | Should -Be 1
    }

    It 'Leaves out an app on KNOWN_PLATFORM_INCOMPATIBLE, and says so' {
        $record = Get-FixtureRecord
        ($record.apps | Where-Object id -EQ 'Google.GoogleDrive').status = 'Failed'

        $result = Get-AppCheckResult -RunRecord $record -KnownPlatformIncompatible 'Google.GoogleDrive'

        Get-FailedAssertion $result | Should -BeNullOrEmpty
        Get-Row $result 'App installed: Google.GoogleDrive' | Should -BeNullOrEmpty
        (Get-Row $result 'last-run.json lists the catalog''s apps').Detail | Should -Be 'schemaVersion 1, 11 entries for the catalog''s 11 apps; not checked (KNOWN_PLATFORM_INCOMPATIBLE): Google.GoogleDrive'
    }

    It 'Passes per-user work recorded as Deferred with its reason, and fails it installed' {
        $catalog = @(@{ name = 'Contoso.UserSetting'; userPhase = $true })
        $expectation = @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability @{ 'Contoso.UserSetting' = $true })
        $deferred = [pscustomobject]@{ schemaVersion = 1; apps = @([pscustomobject]@{ id = 'Contoso.UserSetting'; status = 'Deferred'; reason = (Get-AppDeferReasonText -DeferReason 'UserPhase') }) }
        $installed = [pscustomobject]@{ schemaVersion = 1; apps = @([pscustomobject]@{ id = 'Contoso.UserSetting'; status = 'Installed'; reason = $null }) }

        $pass = @(Get-SystemPassAppResult -RunRecord $deferred -AppExpectation $expectation)
        $fail = @(Get-SystemPassAppResult -RunRecord $installed -AppExpectation $expectation)

        $pass[1].Assertion | Should -Be 'Deferred to the user phase: Contoso.UserSetting'
        $pass[1].Result | Should -Be 'PASS'
        $fail[1].Result | Should -Be 'FAIL'
        $fail[1].Detail | Should -Be ('last-run.json: Installed; expected Deferred ({0})' -f (Get-AppDeferReasonText -DeferReason 'UserPhase'))
    }

    It 'Adds no per-app rows when given no expectations (the other checks'' tests)' {
        @((Get-AppCheckResult -RunRecord (Get-FixtureRecord) -NoExpectation).Results).Count | Should -Be 10
    }
}

Describe 'e2e/Invoke-SystemInstallPass.ps1 per-app wiring' {
    It 'Works out the expectations from the checkout''s module before the run, as SYSTEM, and passes them and the record''s problem on' {
        $script = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')
        $main = $script.Substring($script.IndexOf('if ($MyInvocation.InvocationName -ne ''.'')'))

        $main | Should -Match 'Import-Module \(Join-Path \$repositoryRoot ''WingetAppSetup\\WingetAppSetup\.psd1''\)[^\r\n]*-PassThru'
        $main | Should -Match 'Get-SystemRunApplicability -Catalog \$catalog -Module \$wingetAppSetupModule'
        $main | Should -Match 'Get-PreinstalledAppRemovalList -ScriptPath \(Join-Path \$PSScriptRoot ''Remove-PreinstalledApps\.ps1''\)'
        $main | Should -Match 'Get-SystemInstallPassResult [^\r\n]*-RunRecordProblem \$runRecordRead\.Problem[^\r\n]*-AppExpectation \$appExpectation -AppExpectationProblem \$appExpectationProblem'
        $main.IndexOf('Invoke-SystemPassTask') | Should -BeGreaterThan 0
        $main.IndexOf('Get-SystemPassAppExpectation') | Should -BeLessThan $main.IndexOf('Invoke-SystemPassTask')
    }

    It 'Runs e2e/Remove-PreinstalledApps.ps1 in the e2e-install-system job with its defaults, the list the checks read' {
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
        $start = $workflow.IndexOf("`n  e2e-install-system:")
        $job = $workflow.Substring($start, $workflow.IndexOf("`n  report-failure:") - $start)

        $job | Should -Match '(?m)^\s+& \.\\e2e\\Remove-PreinstalledApps\.ps1\s*$'
        $job | Should -Not -Match 'Remove-PreinstalledApps\.ps1 +-'
    }
}

# wgt-gq8.42: the e2e-install-system-winget-client job runs the SYSTEM pass twice with
# -SystemInstallEngine WinGetClient, and fails unless the module did the installs.
Describe 'The SYSTEM pass with the Microsoft.WinGet.Client engine' {
    BeforeAll {
        $script:Pin = Get-WingetClientModulePin
        $script:EngineWrapperLog = $script:GoodWrapperLog + "`r`nInstall engine requested: WinGetClient (WINGET_APP_SETUP_SYSTEM_ENGINE, read by installer builds that support it)."

        function Get-EngineFixtureTranscript {
            param ([string]$Name = 'system-winget-client-transcript')
            $text = [string](Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "tests/fixtures/e2e/$Name.txt"))
            [pscustomobject]@{ Name = 'install-20261006-061430.log'; Parsed = (ConvertFrom-InstallTranscript -Content $text) }
        }

        function Get-EngineFixtureRecord {
            (Read-SystemPassRunRecord -Path (Join-Path $script:RepoRoot 'tests/fixtures/e2e/system-winget-client-last-run.json')).Record
        }

        function Get-EngineExpectation {
            param ([switch]$AlreadyPresent)
            $catalog = @(Get-DefaultAppCatalog)
            @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability (Get-SystemRunApplicability -Catalog $catalog) -RemovedApps (Get-PreinstalledAppRemovalList -ScriptPath (Join-Path $script:RepoRoot 'e2e/Remove-PreinstalledApps.ps1')) -AlreadyPresent:$AlreadyPresent)
        }

        function Get-EngineRows {
            param ($WrapperLog = $script:EngineWrapperLog, $Transcript = (Get-EngineFixtureTranscript), $RunRecord = (Get-EngineFixtureRecord), [int]$PassNumber = 1, $Expectation = (Get-EngineExpectation))
            @(Get-SystemPassEngineResult -WrapperLog $WrapperLog -Transcript $Transcript -RunRecord $RunRecord -Pin $script:Pin -AppExpectation $Expectation -PassNumber $PassNumber)
        }
    }

    BeforeEach {
        Mock Get-OSArchitecture { 'X64' }
        Mock Get-ComputerManufacturer { 'Microsoft Corporation' }
        Mock Test-WindowsTerminalHostsCurrentSession { $true }
    }

    It 'Builds the task''s arguments with the engine request, and without it as before' {
        Get-SystemPassTaskArgument -WrapperPath 'D:\a\rmm\Invoke-WingetAppSetup.ps1' -InstallerPath 'D:\a\winget-app-install.ps1' -InstallerSha256 $script:Sha256 -SystemInstallEngine 'WinGetClient' |
            Should -Be "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""D:\a\rmm\Invoke-WingetAppSetup.ps1"" -InstallerPath ""D:\a\winget-app-install.ps1"" -InstallerSha256 $($script:Sha256) -SystemInstallEngine WinGetClient"
        Get-SystemPassTaskArgument -WrapperPath 'D:\a\rmm\Invoke-WingetAppSetup.ps1' -InstallerPath 'D:\a\winget-app-install.ps1' -InstallerSha256 $script:Sha256 -SystemInstallEngine '' |
            Should -Not -Match 'SystemInstallEngine'
    }

    It 'Passes a run that installed with the pinned module, as the fixtures show it' {
        $rows = Get-EngineRows

        @($rows | ForEach-Object { $_.Assertion }) | Should -Be @('Wrapper passed the engine request', 'WinGet client module verified as SYSTEM', 'Installs ran through Microsoft.WinGet.Client')
        @($rows | Where-Object Result -EQ 'FAIL') | Should -BeNullOrEmpty
        $rows[2].Detail | Should -BeLike 'Install engine: Microsoft.WinGet.Client 1.29.380 (*; Install-WinGetPackage for: 7zip.7zip, *; last-run.json installEngine.used WinGetClient'
    }

    It 'Fails a run that fell back to winget.exe, saying why' {
        $record = Get-EngineFixtureRecord
        $record.installEngine.used = 'Cli'
        $record.installEngine.module = $null
        $record.installEngine.fallbackReason = 'the module is not ready: downloading failed'

        $rows = Get-EngineRows -Transcript (Get-EngineFixtureTranscript -Name 'system-winget-client-fallback-transcript') -RunRecord $record

        ($rows | Where-Object Assertion -EQ 'WinGet client module verified as SYSTEM').Result | Should -Be 'FAIL'
        $engine = $rows | Where-Object Assertion -EQ 'Installs ran through Microsoft.WinGet.Client'
        $engine.Result | Should -Be 'FAIL'
        $engine.Detail | Should -Match "the run's 'Install engine:' line is 'winget\.exe \("
        $engine.Detail | Should -Match 'WinGet client module: NOT READY - downloading'
        $engine.Detail | Should -Match "7 '> winget install' line\(s\): winget\.exe installed apps"
        $engine.Detail | Should -Match "no '> Install-WinGetPackage -Id <id>' line for 7zip\.7zip, Google\.Chrome, Git\.Git"
        $engine.Detail | Should -Match "last-run\.json says installEngine\.used 'Cli' \(the module is not ready: downloading failed\)"
    }

    It 'Fails <Case>' -ForEach @(
        @{ Case = 'a run where one app still went through winget.exe'; Edit = 'wingetexe'; Expected = "1 '> winget install' line(s)*" }
        @{ Case = 'a last-run.json that says winget.exe installed'; Edit = 'record'; Expected = "*last-run.json says installEngine.used 'Cli'*" }
        @{ Case = 'a last-run.json from an installer without the engine'; Edit = 'norecord'; Expected = '*last-run.json has no installEngine*' }
        @{ Case = 'a module at another version'; Edit = 'version'; Expected = '*not the pinned 1.29.380*' }
        @{ Case = 'a removed app the module did not install'; Edit = 'missing'; Expected = "*no '> Install-WinGetPackage -Id <id>' line for Git.Git*" }
    ) {
        $transcriptText = [string](Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'tests/fixtures/e2e/system-winget-client-transcript.txt'))
        $record = Get-EngineFixtureRecord
        switch ($Edit) {
            'wingetexe' { $transcriptText = $transcriptText.Replace('  > Install-WinGetPackage -Id Git.Git -Source', '  > winget install -e --id Git.Git --scope machine -Source') }
            'record' { $record.installEngine.used = 'Cli' }
            'norecord' { $record.PSObject.Properties.Remove('installEngine') }
            'version' { $transcriptText = $transcriptText.Replace('Install engine: Microsoft.WinGet.Client 1.29.380 (', 'Install engine: Microsoft.WinGet.Client 1.28.240 (') }
            'missing' { $transcriptText = $transcriptText.Replace('  > Install-WinGetPackage -Id Git.Git -Source', '  installed Git.Git -Source') }
        }
        $transcript = [pscustomobject]@{ Name = 'install-20261006-061430.log'; Parsed = (ConvertFrom-InstallTranscript -Content $transcriptText) }

        $engine = (Get-EngineRows -Transcript $transcript -RunRecord $record) | Where-Object Assertion -EQ 'Installs ran through Microsoft.WinGet.Client'

        $engine.Result | Should -Be 'FAIL'
        $engine.Detail | Should -BeLike $Expected
    }

    It 'Fails a wrapper that did not pass the request on' {
        $row = (Get-EngineRows -WrapperLog $script:GoodWrapperLog) | Where-Object Assertion -EQ 'Wrapper passed the engine request'

        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be 'the wrapper log has no ''Install engine requested: WinGetClient'' line'
    }

    It 'Fails a module whose SHA256 is not the pin''s' {
        $transcriptText = ([string](Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'tests/fixtures/e2e/system-winget-client-transcript.txt'))).Replace($script:Pin.Sha256, ('0' * 64))
        $transcript = [pscustomobject]@{ Name = 'x.log'; Parsed = (ConvertFrom-InstallTranscript -Content $transcriptText) }

        $row = (Get-EngineRows -Transcript $transcript) | Where-Object Assertion -EQ 'WinGet client module verified as SYSTEM'

        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -BeLike "*(expected Microsoft.WinGet.Client 1.29.380, SHA256 $($script:Pin.Sha256))"
    }

    It 'Passes a second run that took the module from the cache, and fails one that downloaded it again' {
        $second = Get-EngineRows -Transcript (Get-EngineFixtureTranscript -Name 'system-winget-client-second-pass') -PassNumber 2 -Expectation (Get-EngineExpectation -AlreadyPresent)
        $redownloaded = Get-EngineRows -Transcript (Get-EngineFixtureTranscript) -PassNumber 2 -Expectation (Get-EngineExpectation -AlreadyPresent)

        @($second | Where-Object Result -EQ 'FAIL') | Should -BeNullOrEmpty
        ($redownloaded | Where-Object Assertion -EQ 'WinGet client module verified as SYSTEM').Result | Should -Be 'FAIL'
        ($redownloaded | Where-Object Assertion -EQ 'WinGet client module verified as SYSTEM').Detail | Should -BeLike '*(the second run must take it from the cache)'
    }

    It 'Expects every app that applies already there on the second run, and nothing the job must install' {
        $byId = @{}
        foreach ($expectation in Get-EngineExpectation -AlreadyPresent) {
            $byId[$expectation.Id] = $expectation
        }

        $byId['Google.Chrome'].Expected | Should -Be 'AlreadyPresent'
        $byId['Google.Chrome'].MustInstall | Should -BeFalse
        $byId['Microsoft.WindowsTerminal'].AlreadyPresentReasons | Should -Be @('already provisioned for every user on this PC')
        $byId['Dell.CommandUpdate.Universal'].Expected | Should -Be 'NotApplicable'
        @($byId.Values | Where-Object { $_.MustInstall }) | Should -BeNullOrEmpty
    }

    It 'Passes a second run that skipped every app as already there, and fails one that installed one' {
        $skippedRecord = Get-EngineFixtureRecord
        foreach ($entry in $skippedRecord.apps) {
            if ($entry.status -eq 'Installed') {
                $entry.status = 'Skipped'
                $entry.reason = 'already installed'
            }
        }
        $installedAgain = Get-EngineFixtureRecord

        $pass = @(Get-SystemPassAppResult -RunRecord $skippedRecord -AppExpectation (Get-EngineExpectation -AlreadyPresent))
        $fail = @(Get-SystemPassAppResult -RunRecord $installedAgain -AppExpectation (Get-EngineExpectation -AlreadyPresent))

        @($pass | Where-Object Result -EQ 'FAIL') | Should -BeNullOrEmpty
        ($pass | Where-Object Assertion -EQ 'App already present on the second run: Google.Chrome').Detail | Should -Be 'last-run.json: Skipped (already installed)'
        $chrome = $fail | Where-Object Assertion -EQ 'App already present on the second run: Google.Chrome'
        $chrome.Result | Should -Be 'FAIL'
        $chrome.Detail | Should -Be 'last-run.json: Installed; the first run installed or found it, so the second run had to find it: expected Skipped (already installed)'
    }

    It 'Checks the second run without accepting the framework installed again' {
        $transcript = New-TestTranscript -RuntimeLines @()
        $again = New-TestTranscript

        $pass = Get-SystemInstallPassResult -TaskExitCode 0 -Transcript $transcript -WrapperLog $script:GoodWrapperLog -RunRecord (New-TestRunRecord) -SecondPass
        $fail = Get-SystemInstallPassResult -TaskExitCode 0 -Transcript $again -WrapperLog $script:GoodWrapperLog -RunRecord (New-TestRunRecord) -SecondPass

        ($pass.Results | Where-Object Assertion -EQ 'Windows App Runtime not installed again').Result | Should -Be 'PASS'
        $row = $fail.Results | Where-Object Assertion -EQ 'Windows App Runtime not installed again'
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -BeLike '*installed it again: Windows App Runtime: installed*'
        $fail.StepExitCode | Should -Be 1
    }

    It 'Looks the removed apps up with winget list as the runner account, retrying before it fails' {
        Mock Start-Sleep { }
        $script:answers = @{ '7zip.7zip' = 0; 'Google.Chrome' = 0; 'Git.Git' = 0 }
        $check = {
            param ($Id)
            $script:answers[$Id]++
            if ($Id -eq 'Git.Git') {
                return @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = -1978335212 }
            }
            if ($Id -eq 'Google.Chrome' -and $script:answers[$Id] -lt 2) {
                return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
            }
            @{ Installed = $true; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 }
        }

        $rows = @(Get-SystemPassIndependentInstallResult -AppExpectation (Get-EngineExpectation) -TestInstalled $check -RetryDelaySeconds 20)

        @($rows | ForEach-Object { $_.Assertion }) | Should -Be @('Installed per winget list as the runner account: 7zip.7zip', 'Installed per winget list as the runner account: Google.Chrome', 'Installed per winget list as the runner account: Git.Git')
        @($rows | ForEach-Object { $_.Result }) | Should -Be @('PASS', 'PASS', 'FAIL')
        $rows[2].Detail | Should -Be 'winget list does not list it (3 checks)'
        $script:answers['Git.Git'] | Should -Be 3
        $script:answers['Google.Chrome'] | Should -Be 2
        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 20 }
    }

    It 'Leaves out a removed app on KNOWN_PLATFORM_INCOMPATIBLE from the independent check' {
        $rows = @(Get-SystemPassIndependentInstallResult -AppExpectation (Get-EngineExpectation) -TestInstalled { @{ Installed = $true } } -SkipApps @('Git.Git'))

        @($rows | ForEach-Object { $_.Assertion }) | Should -Not -Contain 'Installed per winget list as the runner account: Git.Git'
        $rows.Count | Should -Be 2
    }

    It 'Prefixes every row with its pass when the job runs two' {
        $rows = Add-SystemPassPrefix -Rows @([pscustomobject]@{ Assertion = 'SYSTEM run exit code'; Result = 'PASS'; Detail = 'x' }) -PassNumber 2

        $rows[0].Assertion | Should -Be 'Pass 2: SYSTEM run exit code'
        $rows[0].Result | Should -Be 'PASS'
    }

    It 'Is run by its own job, which passes the engine and two passes, checks the pin, and reports to report-failure' {
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
        $start = $workflow.IndexOf("`n  e2e-install-system-winget-client:")
        $job = $workflow.Substring($start, $workflow.IndexOf("`n  report-failure:") - $start)

        $job | Should -Match 'Invoke-SystemInstallPass\.ps1 -SystemInstallEngine WinGetClient -PassCount 2'
        $job | Should -Match 'Set-WingetClientModulePin\.ps1 -Check'
        # The job's backstop covers its steps' own limits, plus a few minutes for checkout and uploads.
        $jobLimit = [int][regex]::Match($job, '(?m)^    timeout-minutes: (\d+)').Groups[1].Value
        $stepLimits = @([regex]::Matches($job, '(?m)^        timeout-minutes: (\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
        $stepLimits.Count | Should -Be 5
        $jobLimit | Should -BeGreaterOrEqual ((($stepLimits | Measure-Object -Sum).Sum) + 5)
        $job | Should -Match 'name: e2e-install-transcripts-system-winget-client'
        $job | Should -Match 'name: e2e-diagnostics-system-winget-client'
        $workflow | Should -Match "needs\.e2e-install-system-winget-client\.result != 'success'"
        $workflow | Should -Match "leg_section e2e-install-system-winget-client 'run as SYSTEM with the Microsoft\.WinGet\.Client engine'"
    }

    It 'Behaves as before without the new parameters: no engine rows and one pass' {
        $script = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')
        $main = $script.Substring($script.IndexOf('if ($MyInvocation.InvocationName -ne ''.'')'))

        $main | Should -Match 'for \(\$passNumber = 1; \$passNumber -le \$PassCount; \$passNumber\+\+\)'
        $main | Should -Match "if \(\`$SystemInstallEngine -eq 'WinGetClient'\) \{"
        $main | Should -Match "& \`$wingetAppSetupModule \{ Get-WingetClientModulePin \}"
        $main | Should -Match 'Test-WingetPackageInstalled -PackageId \$PackageId -TimeoutSeconds 60'
        (Get-Command -Name (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')).Parameters['PassCount'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateRangeAttribute] }).MaxRange | Should -Be 2
    }
}
