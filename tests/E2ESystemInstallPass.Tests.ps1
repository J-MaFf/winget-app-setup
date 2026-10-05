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
        $workflow | Should -Match 'needs: \[e2e-install, e2e-install-windows-powershell, e2e-install-system\]'
    }
}
