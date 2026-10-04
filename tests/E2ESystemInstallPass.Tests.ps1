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
        'The installer exited with 8. Its transcripts and last-run.json are in C:\ProgramData\winget-app-setup\logs.'
    ) -join "`r`n"

    function New-TestTranscript {
        param ([switch]$NotSystem, [string]$AutoUpdates = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.')
        $lines = @('Installer build: 1.0.0+5ea1f00d')
        if (-not $NotSystem) {
            $lines += 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only.'
        }
        $lines += @('Summary:', "Auto-updates: $AutoUpdates")
        [pscustomobject]@{ Name = 'install-20261005-060010.log'; Parsed = (ConvertFrom-InstallTranscript -Content ($lines -join "`n")) }
    }

    function New-TestRunRecord {
        param ($ExitCode = 8, $SummaryReached = $true)
        [pscustomobject]@{
            exitCode       = $ExitCode
            summaryReached = $SummaryReached
            apps           = @([pscustomobject]@{ id = '7zip.7zip'; status = 'Installed' }, [pscustomobject]@{ id = 'Microsoft.WindowsTerminal'; status = 'Deferred' })
        }
    }

    function Get-TestResult {
        param ($TaskExitCode = 8, $Transcript = (New-TestTranscript), $WrapperLog = $script:GoodWrapperLog, $RunRecord = (New-TestRunRecord), [string[]]$NewEntries = @())
        Get-SystemInstallPassResult -TaskExitCode $TaskExitCode -Transcript $Transcript -WrapperLog $WrapperLog -RunRecord $RunRecord -NewSystemProfileEntries $NewEntries
    }

    function Get-Row {
        param ($Result, [string]$Assertion)
        $Result.Results | Where-Object Assertion -EQ $Assertion
    }
}

Describe 'Get-SystemInstallPassResult' {
    It 'Passes a SYSTEM run that relaunched in 64-bit, ran the checked installer as SYSTEM and exited 8 for the missing framework' {
        $result = Get-TestResult

        $result.StepExitCode | Should -Be 0
        @($result.Results | Where-Object Result -EQ 'FAIL') | Should -BeNullOrEmpty
        @($result.Results).Count | Should -Be 7
        (Get-Row $result 'last-run.json records the run').Detail | Should -Be 'exitCode 8, summaryReached True, deferred: Microsoft.WindowsTerminal'
    }

    It 'Passes exit <Code>' -ForEach @(@{ Code = 0 }, @{ Code = 3010 }) {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 8', "exited with $Code"

        (Get-TestResult -TaskExitCode $Code -WrapperLog $wrapper -RunRecord (New-TestRunRecord -ExitCode $Code)).StepExitCode | Should -Be 0
    }

    It 'Fails with the run''s own code when the exit code fails the pass policy (<Case>)' -ForEach @(
        @{ Case = 'winget unavailable'; Code = 2; AutoUpdates = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing.' }
        @{ Case = '8 for another reason'; Code = 8; AutoUpdates = 'FAILED - Winget-AutoUpdate could not be installed.' }
    ) {
        $wrapper = $script:GoodWrapperLog -replace 'exited with 8', "exited with $Code"

        $result = Get-TestResult -TaskExitCode $Code -WrapperLog $wrapper -Transcript (New-TestTranscript -AutoUpdates $AutoUpdates) -RunRecord (New-TestRunRecord -ExitCode $Code)

        $result.StepExitCode | Should -Be $Code
        (Get-Row $result 'SYSTEM run exit code').Result | Should -Be 'FAIL'
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
        $result = Get-TestResult -TaskExitCode 0 -RunRecord (New-TestRunRecord -ExitCode 0)

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

    It 'Is run by the e2e-install-system job, which also watches rmm/ for pull requests' {
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')

        $workflow | Should -Match '(?m)^  e2e-install-system:'
        $workflow | Should -Match 'Invoke-SystemInstallPass\.ps1'
        $workflow | Should -Match "pattern='\^\(WingetAppSetup/\|build/\|e2e/\|rmm/\)"
        $workflow | Should -Match 'needs: \[e2e-install, e2e-install-windows-powershell, e2e-install-system\]'
    }
}
