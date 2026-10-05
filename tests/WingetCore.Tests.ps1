# WingetCore.Tests.ps1
# Tests for WingetAppSetup/Public/WingetCore.ps1: the winget setup ladder (Initialize-Winget),
# package install (0x80073d19 backoff, scope fallback), installed-checks, and the PowerShell
# always-latest / MSIX provisioning strategies.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # Every message the ladder prints, in order, with its kind.
    function Register-LadderMessageCapture {
        $script:log = @()
        Mock Write-Host { }
        Mock Write-Info { $script:log += "INFO: $Message" }
        Mock Write-Success { $script:log += "OK: $Message" }
        Mock Write-WarningMessage { $script:log += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:log += "ERROR: $Message" }
    }

    function New-LaunchProbe {
        param ([switch]$Launchable, [string]$Reason = "winget could not be started: 'winget' was not found on PATH", $ExitCode = $null)
        if ($Launchable) {
            return [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; ExitCode = 0; Attempts = 1 }
        }
        [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $Reason; ExitCode = $ExitCode; Attempts = 1 }
    }

    function New-SourceProbe {
        param ($ExitCode = 0, [switch]$TimedOut, [string]$LaunchError)
        if ($LaunchError) {
            return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false; LaunchError = $LaunchError }
        }
        if ($TimedOut) {
            return @{ Succeeded = $false; ExitCode = $null; TimedOut = $true; LaunchError = $null }
        }
        @{ Succeeded = ($ExitCode -eq 0); ExitCode = $ExitCode; TimedOut = $false; LaunchError = $null }
    }

    # The ladder's helpers, mocked: winget starts unless a test says otherwise, no fix changes
    # anything, and the source updates. Commands that would change the machine throw.
    function Register-LadderMocks {
        param ([switch]$RealLaunchCheck)
        Register-LadderMessageCapture
        Mock Start-Sleep { }
        Mock Get-WingetPolicyBlock { $null }
        $script:wingetLaunchable = $true
        if (-not $RealLaunchCheck) {
            Mock Test-WingetLaunchable { New-LaunchProbe -Launchable:$script:wingetLaunchable }
        }
        Mock Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $false; ErrorCodes = @() } }
        Mock Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = @() } }
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 for X64 required; found: X64 8000.994.2142.0' } }
        Mock Invoke-WingetSourceProbe { New-SourceProbe -ExitCode 0 }
        Mock Reset-WingetSource { $true }
        Mock Repair-WinGetPackageManager { throw 'must not run the real repair cmdlet' }
        Mock Invoke-WebRequest { throw 'must not download App Installer' }
        Mock Add-AppxPackage { throw 'must not register a package' }
        Mock Invoke-AppxRegistration { throw 'must not register a package' }
        $script:account = New-TestAccountContext
    }
}

# Initialize-Winget: one probe, classify, fix ladder (review findings P3-25 to P3-31), in place of
# Test-AndInstallWinget, Initialize-WingetSourcesForUser and Test-WingetSources. The helpers it calls
# are tested in WingetBootstrap.Tests.ps1; here they are mocked, except where a Describe says it runs
# them for real.
Describe 'Initialize-Winget: can winget start? (review findings P3-9, P3-25)' {
    BeforeEach {
        Register-LadderMocks
    }

    It 'Checks winget once, waiting up to 75 seconds for a failure that can clear, runs no fix and updates the source' {
        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $true
        $result.Diagnosis | Should -Be 'Ok'
        Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 6 -and $RetryDelaySeconds -eq 15 }
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
        $script:log | Should -Contain 'OK: Winget is available (v1.12.350).'
    }

    It 'Registers the App Installer already on this PC first, and stops there when winget then starts' {
        $script:wingetLaunchable = $false
        Mock Register-WingetAppInstallerForUser { $script:wingetLaunchable = $true; [pscustomobject]@{ Registered = $true; ErrorCodes = @() } }

        (Initialize-Winget -AccountContext $script:account).Ready | Should -Be $true

        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 2 -and $RetryDelaySeconds -eq 5 }
    }

    It 'Repairs when registering does not make winget start' {
        $script:wingetLaunchable = $false
        Mock Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $true; ErrorCodes = @() } }
        Mock Invoke-WingetPackageManagerRepair { $script:wingetLaunchable = $true; [pscustomobject]@{ Available = $true; Succeeded = $true; ErrorCodes = @() } }

        (Initialize-Winget -AccountContext $script:account).Ready | Should -Be $true

        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        Should -Invoke Test-WingetLaunchable -Times 2 -Exactly -ParameterFilter { $Attempts -eq 2 }
    }

    It 'Stops with one line that says why and what to do when no fix makes winget start, without the aka.ms download or the source steps' {
        $script:wingetLaunchable = $false

        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $false
        $result.Diagnosis | Should -Be 'NotLaunchable'
        $errors = @($script:log | Where-Object { $_ -like 'ERROR: *' })
        $errors.Count | Should -Be 1
        $errors[0] | Should -Be "ERROR: Winget cannot be started for 'CONTOSO\admin-tech': winget could not be started: 'winget' was not found on PATH. Fix: install or update App Installer from the Microsoft Store or https://aka.ms/getwinget, then re-run the installer."
        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
    }

    It 'Names the codes it saw and the missing framework when the all-users check finds Microsoft.WindowsAppRuntime.1.8 missing (issue #279, review finding P3-27)' {
        $script:wingetLaunchable = $false
        Mock Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $false; ErrorCodes = @(-2147009293, -2147009274) } }
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 for X64 required; found: none registered' } }

        [void](Initialize-Winget -AccountContext $script:account)

        $line = @($script:log | Where-Object { $_ -like 'ERROR: *' })[0]
        $line | Should -Match 'App Installer could not be registered or repaired \(0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED, 0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE\)'
        $line | Should -Match 'Fix: install the Microsoft\.WindowsAppRuntime\.1\.8 framework App Installer depends on, which this PC lacks \(.*found: none registered\)'
        # The repair was told to go for all users first (review finding P3-28).
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly -ParameterFilter { $AllUsersFirst }
    }

    It 'Says to update App Installer from the Store when a newer framework rejected the repair (0x80073D06, issue #265)' {
        $script:wingetLaunchable = $false
        Mock Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = @(-2147009274) } }

        [void](Initialize-Winget -AccountContext $script:account)

        @($script:log | Where-Object { $_ -like 'ERROR: *' })[0] | Should -Match 'Fix: a framework package on this PC is newer than the one the WinGet release deploys.*update App Installer from the Microsoft Store'
    }

    It 'Says the repair could not run when its module could not be installed (review finding P3-26)' {
        $script:wingetLaunchable = $false
        Mock Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $false; Succeeded = $false; ErrorCodes = @() } }

        [void](Initialize-Winget -AccountContext $script:account)

        @($script:log | Where-Object { $_ -like 'ERROR: *' })[0] | Should -Match 'Repair-WinGetPackageManager could not run: its PowerShell module could not be installed'
        # Nothing was repaired, so winget is not checked again for it.
        Should -Invoke Test-WingetLaunchable -Times 0 -Exactly -ParameterFilter { $Attempts -eq 2 }
    }

    It 'Says who it sets winget up for under cross-user elevation' {
        Initialize-Winget -AccountContext (New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe') | Out-Null

        $script:log | Should -Contain "WARN: Cross-user elevation detected: running as 'CONTOSO\admin-tech' while 'CONTOSO\jdoe' owns the interactive session."
    }

    It 'Does not mention cross-user elevation for a same-account run' {
        Initialize-Winget -AccountContext $script:account | Out-Null

        ($script:log -join "`n") | Should -Not -Match 'Cross-user elevation'
    }

    It 'Reads the account context itself when the run does not pass it' {
        Mock Get-InstallAccountContext { New-TestAccountContext -ProcessUser 'CONTOSO\admin-other' -SessionUser 'CONTOSO\admin-other' }

        (Initialize-Winget).Ready | Should -Be $true

        Should -Invoke Get-InstallAccountContext -Times 1 -Exactly
        $script:log | Should -Contain "OK: The winget source is up to date for 'CONTOSO\admin-other'."
    }
}

# Review finding P3-9: `Get-Command winget` only proved the alias was on PATH. Run 35406706712 printed
# 'Winget bootstrapped successfully' after both repair attempts failed, then every winget call failed
# with 'No applicable app licenses found'. The real Test-WingetLaunchable runs against a mocked
# Invoke-WingetProcess.
Describe 'Initialize-Winget with winget on PATH but unable to run (review finding P3-9)' {
    BeforeEach {
        Register-LadderMocks -RealLaunchCheck
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335230 -Output @('No applicable app licenses found.') } -ParameterFilter { $ArgumentList[0] -eq '--version' }
        Mock Invoke-WingetProcess { throw "unexpected winget call: $($ArgumentList -join ' ')" }
    }

    It 'Does not report success after the fixes failed, and says that winget cannot run' {
        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $false
        Should -Invoke Write-Success -Times 0 -Exactly
        $script:log | Should -Contain "WARN: Winget is not available: 'winget --version' exited with 0x8A150002 INVALID_CL_ARGUMENTS."
        @($script:log | Where-Object { $_ -like 'ERROR: *' })[0] | Should -Match "^ERROR: Winget cannot be started for 'CONTOSO\\admin-tech': 'winget --version' exited with 0x8A150002 INVALID_CL_ARGUMENTS\."
    }
}

# Review of item 9: an App Installer update in progress (issues #253/#258) must not be repaired
# underneath. The real Test-WingetLaunchable runs; time is simulated (each launch takes a second,
# Start-Sleep advances it).
Describe 'Initialize-Winget with winget locked at the start of the run' {
    BeforeEach {
        Register-LadderMocks -RealLaunchCheck
        $script:clock = 0
        Mock Start-Sleep { $script:clock += $Seconds }
    }

    It 'Waits out a <Seconds>-second lock without registering or repairing App Installer' -ForEach @(
        @{ Seconds = 30 }
        @{ Seconds = 60 }
    ) {
        $script:lockSeconds = $Seconds
        Mock Invoke-WingetProcess {
            $script:clock++
            if ($script:clock -le $script:lockSeconds) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            New-TestProcessResult -ExitCode 0 -Output @('v1.12.350')
        }

        (Initialize-Winget -AccountContext $script:account).Ready | Should -Be $true

        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        # Six tries 15 seconds apart at most: the 75 seconds the install's launch retries cover.
        $script:clock | Should -BeLessOrEqual 81
    }

    It 'Goes to the fixes after one check when waiting cannot help (<Case>)' -ForEach @(
        @{ Case = 'winget not on PATH'; Code = 2; Message = "'winget' was not found on PATH." }
        @{ Case = 'access denied'; Code = 5; Message = 'Access is denied.' }
    ) {
        $script:launchCode = $Code
        $script:launchMessage = $Message
        Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage }

        (Initialize-Winget -AccountContext $script:account).Ready | Should -Be $false

        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

Describe 'Initialize-Winget: the winget source (review findings P3-25, P3-28)' {
    BeforeEach {
        Register-LadderMocks
        # Exit codes the source update answers, one per call; the last one repeats.
        $script:sourceAnswers = @(0)
        $script:sourceCalls = 0
        Mock Invoke-WingetSourceProbe {
            $answer = $script:sourceAnswers[[Math]::Min($script:sourceCalls, $script:sourceAnswers.Count - 1)]
            $script:sourceCalls++
            if ($answer -is [hashtable]) { return $answer }
            New-SourceProbe -ExitCode $answer
        }
    }

    It 'Registers App Installer, then repairs, for an account Windows blocked with 0x80073D19, checking the source after each fix (issue #159)' {
        $script:sourceAnswers = @(-2147009255, -2147009255, 0)
        Mock Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $true; ErrorCodes = @() } }

        $result = Initialize-Winget -AccountContext $script:account

        $result.Diagnosis | Should -Be 'Ok'
        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 3 -Exactly
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
    }

    It 'Runs no fix twice in a run: none is left for the source when the launch check used them' {
        $script:wingetLaunchable = $false
        Mock Invoke-WingetPackageManagerRepair { $script:wingetLaunchable = $true; [pscustomobject]@{ Available = $true; Succeeded = $true; ErrorCodes = @() } }
        $script:sourceAnswers = @(-2147009255)

        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $true
        $result.Diagnosis | Should -Be 'SourceFailed'
        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
    }

    It 'Resets a missing or corrupted source once and checks it again (<Name>)' -ForEach @(
        @{ Name = '0x8A15000F SOURCE_DATA_MISSING'; Code = -1978335217 }
        @{ Name = '0x8A150012 SOURCE_NAME_DOES_NOT_EXIST'; Code = -1978335214 }
        @{ Name = '0x8A15003F SOURCE_DATA_INTEGRITY_FAILURE'; Code = -1978335169 }
    ) {
        $script:sourceAnswers = @($Code, 0)

        (Initialize-Winget -AccountContext $script:account).Diagnosis | Should -Be 'Ok'

        Should -Invoke Reset-WingetSource -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
    }

    It 'Resets only once when the source is still broken after the reset' {
        $script:sourceAnswers = @(-1978335217)

        (Initialize-Winget -AccountContext $script:account).Diagnosis | Should -Be 'SourceFailed'

        Should -Invoke Reset-WingetSource -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
        @($script:log | Where-Object { $_ -like 'WARN: The winget source could not be set up*' }) | Should -Be @("WARN: The winget source could not be set up for 'CONTOSO\admin-tech' (exit code 0x8A15000F SOURCE_DATA_MISSING). Fix: check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer. Installations may fail.")
    }

    It 'Fixes nothing when <Case>, which no repair fixes (review finding P3-28)' -ForEach @(
        @{ Case = 'the update times out'; Answer = @{ Succeeded = $false; ExitCode = $null; TimedOut = $true; LaunchError = $null }; Detail = 'it did not finish in time and was stopped' }
        @{ Case = 'the network fails'; Answer = -2147012889; Detail = 'exit code 0x80072EE7 WININET_E_NAME_NOT_RESOLVED' }
        @{ Case = 'winget cannot be started for it'; Answer = @{ Succeeded = $false; ExitCode = $null; TimedOut = $false; LaunchError = 'The file cannot be accessed by the system.' }; Detail = 'winget could not be started: The file cannot be accessed by the system.' }
    ) {
        $script:sourceAnswers = @(, $Answer)

        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $true
        $result.Diagnosis | Should -Be 'SourceFailed'
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
        $script:log | Should -Contain "WARN: The winget source could not be set up for 'CONTOSO\admin-tech' ($Detail). Fix: check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer. Installations may fail."
    }

    It 'Gives one diagnosis, the sign-in advice, when 0x80073D19 outlasts every fix under cross-user elevation' {
        $script:sourceAnswers = @(-2147009255)

        [void](Initialize-Winget -AccountContext (New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe'))

        $lines = @($script:log | Where-Object { $_ -like 'WARN: The winget source could not be set up*' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be "WARN: The winget source could not be set up for 'CONTOSO\admin-tech' (exit code 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF). Fix: sign in to Windows as 'CONTOSO\admin-tech' once (that sets winget up for the account), or run 'winget source update' in a session running as 'CONTOSO\admin-tech', then re-run the installer. Installations may fail."
        ($script:log -join "`n") | Should -Not -Match 'appears to be missing|source\.msix|Run as local user'
    }

    It 'Takes unaccepted source agreements (0x8A150046) as no fault: each install accepts them' {
        $script:sourceAnswers = @(-1978335162)

        (Initialize-Winget -AccountContext $script:account).Diagnosis | Should -Be 'Ok'

        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        @($script:log | Where-Object { $_ -like 'WARN:*' }).Count | Should -Be 0
    }
}

Describe 'Initialize-Winget: Group Policy (review finding P3-30)' {
    BeforeEach {
        Register-LadderMocks
    }

    It 'Stops before running winget when <Policy> is Disabled' -ForEach @(
        @{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' }
        @{ Name = 'EnableDefaultSource'; Policy = 'Enable App Installer Default Source' }
    ) {
        $script:block = [pscustomobject]@{ Name = $Name; Policy = $Policy }
        Mock Get-WingetPolicyBlock { $script:block }

        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $false
        $result.Diagnosis | Should -Be 'PolicyBlocked'
        @($script:log | Where-Object { $_ -like 'ERROR: *' }) | Should -Be @("ERROR: Group Policy on this PC blocks winget: '$Policy' is Disabled ($Name = 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller). This installer cannot install apps until the policy allows it; ask whoever manages this PC's policies (Computer Configuration > Administrative Templates > Windows Components > Desktop App Installer) to allow it, then re-run the installer.")
        Should -Invoke Test-WingetLaunchable -Times 0 -Exactly
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
    }

    It 'Stops when the source update answers 0x8A15003A, without resetting the source' {
        Mock Invoke-WingetSourceProbe { New-SourceProbe -ExitCode -1978335174 }

        (Initialize-Winget -AccountContext $script:account).Diagnosis | Should -Be 'PolicyBlocked'

        Should -Invoke Reset-WingetSource -Times 0 -Exactly
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
    }

    It 'A dry run says a real run would stop here' {
        Mock Get-WingetPolicyBlock { [pscustomobject]@{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' } }

        (Initialize-Winget -AccountContext $script:account -WhatIf).Ready | Should -Be $false

        @($script:log | Where-Object { $_ -like 'INFO: `[DRY-RUN`] Group Policy on this PC blocks winget*A real run would stop here with exit code 2.' }).Count | Should -Be 1
        @($script:log | Where-Object { $_ -like 'ERROR: *' }).Count | Should -Be 0
    }
}

# The real Test-WingetLaunchable: a policy block does not clear by waiting (review finding P3-30).
Describe 'Initialize-Winget when winget answers 0x8A15003A BLOCKED_BY_POLICY' {
    BeforeEach {
        Register-LadderMocks -RealLaunchCheck
    }

    It 'Stops at once, with no wait and no fix, when winget answers 0x8A15003A BLOCKED_BY_POLICY' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335174 -Output @('This operation is disabled by Group Policy : Enable Windows Package Manager') }

        $result = Initialize-Winget -AccountContext $script:account

        $result.Diagnosis | Should -Be 'PolicyBlocked'
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        @($script:log | Where-Object { $_ -like 'ERROR: *' })[0] | Should -Match "^ERROR: Group Policy on this PC blocks winget: 'winget --version' answered 0x8A15003A BLOCKED_BY_POLICY\."
    }
}

# Review finding P2-24: as SYSTEM, every account fix sets winget up for one account, which SYSTEM
# cannot have. A SYSTEM run finds and checks the machine-wide winget.exe instead
# (Test-MachineWingetAvailable, tested in MachineContext.Tests.ps1).
Describe 'Initialize-Winget as SYSTEM (review findings P2-24, P3-23)' {
    BeforeEach {
        Register-LadderMocks
        Mock Test-WingetLaunchable { throw 'the per-account check must not run for SYSTEM' }
        Mock Register-WingetAppInstallerForUser { throw 'must not register App Installer for SYSTEM' }
        Mock Invoke-WingetPackageManagerRepair { throw 'must not repair winget for SYSTEM' }
        Mock Test-MachineWingetAvailable { $true }
        $script:account = New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe'
    }

    It 'Checks the machine-wide winget.exe, updates the source and runs no per-account fix' {
        $result = Initialize-Winget -AccountContext $script:account

        $result.Ready | Should -Be $true
        Should -Invoke Test-MachineWingetAvailable -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
        $script:log | Should -Contain 'OK: The winget source is up to date for SYSTEM.'
    }

    It 'Is not ready, so the run stops with exit code 2, when no machine-wide winget starts' {
        Mock Test-MachineWingetAvailable { $false }

        (Initialize-Winget -AccountContext $script:account).Ready | Should -Be $false

        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
    }

    It 'Fixes nothing for 0x80073D19 and gives no advice to sign in, nor any cross-user banner' {
        Mock Invoke-WingetSourceProbe { New-SourceProbe -ExitCode -2147009255 }

        (Initialize-Winget -AccountContext $script:account).Diagnosis | Should -Be 'SourceFailed'

        $text = $script:log -join "`n"
        $text | Should -Match 'could not be set up for SYSTEM \(exit code 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF\)\. The steps that set winget up for a signed-in account do not apply to SYSTEM'
        $text | Should -Not -Match 'Cross-user elevation|sign in to Windows|NT AUTHORITY'
    }

    It 'Still resets a corrupted source, without registering any package' {
        $script:sourceCalls = 0
        Mock Invoke-WingetSourceProbe { $script:sourceCalls++; if ($script:sourceCalls -eq 1) { return New-SourceProbe -ExitCode -1978335217 } New-SourceProbe -ExitCode 0 }

        (Initialize-Winget -AccountContext $script:account).Diagnosis | Should -Be 'Ok'

        Should -Invoke Reset-WingetSource -Times 1 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
    }

    It 'Passes a dry run on' {
        [void](Initialize-Winget -AccountContext $script:account -WhatIf)

        Should -Invoke Test-MachineWingetAvailable -Times 1 -Exactly -ParameterFilter { $WhatIf }
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
    }
}

# P2-16: a dry run used to register or repair App Installer, download it, and run
# `winget source reset --force`.
Describe 'Initialize-Winget dry run (P2-16)' {
    BeforeEach {
        Register-LadderMocks
    }

    It 'Says what a real run would do to set winget up, and runs none of it, when winget cannot start' {
        $script:wingetLaunchable = $false

        $result = Initialize-Winget -AccountContext $script:account -WhatIf

        $result.Ready | Should -Be $false
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
        ($script:log -join "`n") | Should -Match "\[DRY-RUN\] Winget is not available for this account \(winget could not be started: 'winget' was not found on PATH\)\. A real run would set it up: register the App Installer package already on this PC for this account, then run Repair-WinGetPackageManager \(installing its Microsoft\.WinGet\.Client module from the PowerShell Gallery first if it is missing\)"
        @($script:log | Where-Object { $_ -like 'WARN: *' -or $_ -like 'ERROR: *' }).Count | Should -Be 0
    }

    It 'Neither updates nor resets the source when winget starts, and says what a real run would do' {
        $result = Initialize-Winget -AccountContext $script:account -WhatIf

        $result.Ready | Should -Be $true
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
        $script:log | Should -Contain "INFO: [DRY-RUN] Would update the winget source for 'CONTOSO\admin-tech' (winget source update --name winget), and fix it if that fails: winget source reset --force for a missing or corrupted source, which also removes any source added beyond the defaults."
    }
}

# The #279/#284 wedge as E2E run 36384683838 (second pass) saw it, from the cmdlets up: winget.exe
# cannot be accessed, App Installer's registration is rejected with 0x80073CF3 (the
# Microsoft.WindowsAppRuntime.1.8 framework is missing) and then 0x80073D06, and
# Repair-WinGetPackageManager throws 'Try running with -AllUsers'. Three ladders gave three wrong
# diagnoses there: 'Installations may fail with 0x80073D19', 'source "winget" appears to be missing'
# and a source.msix rejection. Only the cmdlets, Windows PowerShell (where Invoke-AppxRegistration
# runs Add-AppxPackage under PowerShell 7, review finding P3-29) and the winget process are mocked.
Describe 'Initialize-Winget on the #279 wedge (review findings P3-25, P3-27, P3-28, P3-31)' {
    BeforeEach {
        Register-LadderMessageCapture
        Mock Start-Sleep { }
        Mock Get-WingetPolicyBlock { $null }
        Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.' } -ParameterFilter { $ArgumentList[0] -eq '--version' }
        Mock Invoke-WingetProcess { throw "unexpected winget call: $($ArgumentList -join ' ')" }
        $script:newFolder = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe'
        $script:oldFolder = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        Mock Get-DesktopAppInstallerPackageInfo {
            [pscustomobject]@{ Version = [version]'1.29.290.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $script:newFolder }
            [pscustomobject]@{ Version = [version]'1.26.510.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $script:oldFolder }
        }
        Mock Test-Path { $true } -ParameterFilter { "$LiteralPath" -like '*AppXManifest.xml' }
        Mock Test-Path { $false }
        Mock Add-AppxPackage {
            throw [System.Runtime.InteropServices.COMException]::new('Deployment failed with HRESULT: 0x80073CF3, Package failed updates, dependency or conflict validation. Windows cannot install package Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe because this package depends on a framework that could not be found. Provide the framework "Microsoft.WindowsAppRuntime.1.8"', -2147009293)
        } -ParameterFilter { $RegisterByFamilyName }
        Mock Add-AppxPackage { throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.' }
        # Under PowerShell 7 the registrations run in Windows PowerShell, which prints the HRESULT.
        Mock powershell.exe { $global:LASTEXITCODE = 1; 'ERR|-2147009293|Deployment failed with HRESULT: 0x80073CF3, Package failed updates, dependency or conflict validation. Windows cannot install package Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe because this package depends on a framework that could not be found. Provide the framework "Microsoft.WindowsAppRuntime.1.8"' } -ParameterFilter { "$args" -match 'Add-AppxPackage -RegisterByFamilyName' }
        Mock powershell.exe { $global:LASTEXITCODE = 1; 'ERR|-2147009274|Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.' } -ParameterFilter { "$args" -match 'Add-AppxPackage -Path' }
        Mock Get-WindowsAppRuntimePackageInfo { }
        Mock Test-AndInstallWingetModule { $true }
        Mock Repair-WinGetPackageManager { throw 'Failed to repair winget. Try running with -AllUsers in administrator mode.' }
        Mock Invoke-WebRequest { throw 'must not download App Installer (the aka.ms/getwinget rung is gone)' }
    }

    It 'Repairs for all users first and ends with one diagnosis that names the missing framework' {
        $result = Initialize-Winget -AccountContext (New-TestAccountContext)

        $result.Ready | Should -Be $false
        $result.Diagnosis | Should -Be 'NotLaunchable'
        # -AllUsers first, as the cmdlet asks, because the framework is missing; then this account,
        # but not forced: the codes the registration saw say forcing cannot help (P3-27).
        Should -Invoke Repair-WinGetPackageManager -Times 2 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $AllUsers -and $Latest }
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly -ParameterFilter { $Force }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        # winget never started, so the source was not touched: no update, no reset, no source.msix.
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -ne '--version' }
        Should -Invoke Add-AppxPackage -Times 0 -Exactly -ParameterFilter { "$Path" -match '^https?:' }

        $errors = @($script:log | Where-Object { $_ -like 'ERROR: *' })
        $errors.Count | Should -Be 1
        $errors[0] | Should -Match '0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED, 0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE'
        $errors[0] | Should -Match 'Fix: install the Microsoft\.WindowsAppRuntime\.1\.8 framework'
        ($script:log -join "`n") | Should -Not -Match 'Installations may fail with 0x80073D19|appears to be missing|source\.msix|Run as local user|Update functionality'
    }
}

Describe 'Install-WingetPackage (0x80073d19 session-error backoff)' {
    BeforeAll {
        # 0x80073D19 (ERROR_INSTALL_USER_LOGOFF) as the signed Int32 winget reports.
        $script:SessionLogoffExitCode = -2147009255
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        # Never actually wait during tests; the backoff is verified via Should -Invoke.
        Mock Start-Sleep { }

        # An attended run unless a test says otherwise (no --silent).
        Mock Test-EffectiveNonInteractive { $false }

        # Each winget run returns the next exit code from the queue, simulating winget.
        $script:exitCodeQueue = @()
        $script:procCallIndex = 0
        Mock Invoke-WingetProcess {
            $code = $script:exitCodeQueue[$script:procCallIndex]
            $script:procCallIndex++
            New-TestProcessResult -ExitCode $code
        }
    }

    It 'Succeeds on the first attempt without sleeping' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Retries with backoff and recovers when the session error is transient' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        # One backoff wait between the failed first attempt and the successful second.
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Exhausts MaxAttempts when the session error persists' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, $script:SessionLogoffExitCode, $script:SessionLogoffExitCode)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be $script:SessionLogoffExitCode
        $result.Attempts | Should -Be 3
        $result.SessionErrorExhausted | Should -Be $true
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        # Sleeps between attempts only (1->2 and 2->3), never after the final attempt.
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'Does not retry a non-session failure (lets the caller verify)' {
        # -1978335189 = "No applicable update found"; any non-session code must stop immediately.
        $script:exitCodeQueue = @(-1978335189)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335189
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Prefers machine scope on the first attempt (issue #159)' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.MachineScopeFellBack | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -contains '--scope') -and ($ArgumentList -contains 'machine')
        }
    }

    It 'Falls back to default scope when the package has no machine-scope installer' {
        # -1978335216 = 0x8A150010 NO_APPLICABLE_INSTALLER (e.g. MSIX-only Microsoft.WindowsTerminal).
        $script:exitCodeQueue = @(-1978335216, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        # The scope fallback is not a session-error retry: it must not consume an attempt or sleep.
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--scope' }
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Falls back on scope at most once' {
        # NO_APPLICABLE_INSTALLER at both scopes is a real failure and must be returned, not looped.
        $script:exitCodeQueue = @(-1978335216, -1978335216)

        $result = Install-WingetPackage -PackageId 'Broken.Package' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335216
        $result.MachineScopeFellBack | Should -Be $true
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Never falls back to the default (per-user) scope with -MachineScopeOnly, and says why it stopped (review finding P3-22)' {
        $script:exitCodeQueue = @(-1978335216, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1 -MachineScopeOnly

        # One install, at machine scope; none at winget's default scope, which as SYSTEM or under
        # cross-user elevation installs for the wrong account.
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList -notcontains '--scope' }
        $result.NoMachineScopeInstaller | Should -Be $true
        $result.MachineScopeFellBack | Should -Be $false
        $result.ExitCode | Should -Be -1978335216
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Installs at machine scope as usual with -MachineScopeOnly when the package has a machine-scope installer' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId '7zip.7zip' -MaxAttempts 3 -InitialDelaySeconds 1 -MachineScopeOnly

        $result.ExitCode | Should -Be 0
        $result.NoMachineScopeInstaller | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -contains '--scope') -and ($ArgumentList -contains 'machine') }
    }

    # Work-order item 38: the catalog entry's scope.
    It 'Never falls back with -Scope machine, in a run as the signed-in user too, and says the catalog allows only machine scope' {
        $script:exitCodeQueue = @(-1978335216, 0)
        Mock Write-Info { }

        $result = Install-WingetPackage -PackageId 'Contoso.MachineOnly' -MaxAttempts 3 -InitialDelaySeconds 1 -Scope machine

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '--scope machine' }
        $result.NoMachineScopeInstaller | Should -Be $true
        $result.MachineScopeFellBack | Should -Be $false
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match "its catalog entry allows only a machine-wide install \(scope 'machine'\)" }
    }

    It 'Installs with --scope user from the first attempt with -Scope user, and never asks for machine scope' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Contoso.UserApp' -MaxAttempts 3 -InitialDelaySeconds 1 -Scope user

        $result.ExitCode | Should -Be 0
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '--scope user' }
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'machine' }
    }

    It 'Returns 0x8A150010 at once with -Scope user when the package has no per-user installer, without a scope fallback' {
        $script:exitCodeQueue = @(-1978335216, 0)

        $result = Install-WingetPackage -PackageId 'Contoso.MachineOnly' -MaxAttempts 3 -InitialDelaySeconds 1 -Scope user

        $result.ExitCode | Should -Be -1978335216
        $result.MachineScopeFellBack | Should -Be $false
        $result.NoMachineScopeInstaller | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
    }

    It 'Refuses -Scope user together with -MachineScopeOnly, without running winget' {
        { Install-WingetPackage -PackageId 'Contoso.UserApp' -Scope user -MachineScopeOnly } | Should -Throw '*-MachineScopeOnly rules out*'

        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
    }

    # Work-order item 34: the user phase installs, as the signed-in user and not elevated, what a run
    # for the whole PC deferred. It must never land on a machine-wide installer, which would ask for
    # administrator rights.
    It 'Installs with --scope user only, and never at another scope, with -UserScopeOnly' {
        $script:exitCodeQueue = @(-1978335216, 0)

        $result = Install-WingetPackage -PackageId 'Contoso.UserOnly' -MaxAttempts 3 -InitialDelaySeconds 1 -UserScopeOnly

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '--scope user' -and ($ArgumentList -join ' ') -notmatch '--scope machine' }
        $result.NoUserScopeInstaller | Should -Be $true
        $result.NoMachineScopeInstaller | Should -Be $false
        $result.MachineScopeFellBack | Should -Be $false
        $result.ExitCode | Should -Be -1978335216
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Installs at user scope as usual with -UserScopeOnly when the package has a per-user installer' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Contoso.UserOnly' -MaxAttempts 3 -InitialDelaySeconds 1 -UserScopeOnly

        $result.ExitCode | Should -Be 0
        $result.NoUserScopeInstaller | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '--scope user' }
    }

    It 'Refuses -MachineScopeOnly together with -UserScopeOnly' {
        { Install-WingetPackage -PackageId 'Contoso.App' -MachineScopeOnly -UserScopeOnly } | Should -Throw '*cannot be used together*'
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
    }

    It 'Uses the caller''s time limit when one is given, and the WingetInstall limit otherwise' {
        $script:exitCodeQueue = @(0, 0)

        $limited = Install-WingetPackage -PackageId 'Contoso.App' -MaxAttempts 1 -TimeoutSeconds 90
        $default = Install-WingetPackage -PackageId 'Contoso.App' -MaxAttempts 1

        $limited.TimeoutSeconds | Should -Be 90
        $default.TimeoutSeconds | Should -Be (Get-ProcessTimeoutSeconds -Operation WingetInstall)
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 90 }
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetInstall) }
    }

    It 'Refuses -UserScopeOnly together with -Scope machine, without running winget' {
        { Install-WingetPackage -PackageId 'Contoso.MachineOnly' -Scope machine -UserScopeOnly } | Should -Throw '*-Scope machine rules out*'
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
    }

    It 'Installs with --scope user only with -UserScopeOnly and -Scope user together' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Contoso.UserApp' -MaxAttempts 3 -InitialDelaySeconds 1 -Scope user -UserScopeOnly

        $result.ExitCode | Should -Be 0
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { (($ArgumentList -join ' ') -split '--scope').Count -eq 2 -and ($ArgumentList -join ' ') -match '--scope user' }
    }

    It 'Still retries the session error with backoff after a scope fallback' {
        $script:exitCodeQueue = @(-1978335216, $script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Passes --installer-type to winget when an installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Microsoft.PowerShell' -InstallerType 'wix' -MaxAttempts 1 | Out-Null

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '--installer-type\s+wix'
        }
    }

    It 'Omits --installer-type when no installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -notcontains '--installer-type'
        }
    }

    It 'Installs from the winget source with both agreement-acceptance flags (issue #172)' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            (($ArgumentList -join ' ') -match '--source winget') -and
            ($ArgumentList -contains '--accept-source-agreements') -and
            ($ArgumentList -contains '--accept-package-agreements')
        }
    }
}

# Review findings P2-15 and P3-16. 0x8A150102 is winget's code for msiexec 1618: Windows Installer
# was busy with another installation (on a fresh PC, the management agent, OEM tools or Teams) and
# said so at once. It used to fail after one launch with no wait.
Describe 'Install-WingetPackage (another installation in progress, in use, restart required; review findings P2-15, P3-16)' {
    BeforeAll {
        $script:InstallInProgress = -1978334974   # 0x8A150102 INSTALL_INSTALL_IN_PROGRESS
        $script:RestartFirst = -1978334966        # 0x8A15010A INSTALL_REBOOT_REQUIRED_FOR_INSTALL
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
        # Each wait for Windows Installer "takes" 30 seconds and ends with it idle.
        Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = 30; Busy = $false } }

        $script:runQueue = @()
        $script:runIndex = 0
        Mock Invoke-WingetProcess {
            $next = $script:runQueue[$script:runIndex]
            $script:runIndex++
            if ($next -is [hashtable]) {
                return New-TestProcessResult @next
            }
            New-TestProcessResult -ExitCode $next
        }
    }

    It 'Waits for Windows Installer and retries after 0x8A150102, instead of failing after one launch' {
        $script:runQueue = @($script:InstallInProgress, 0)

        $result = Install-WingetPackage -PackageId 'Google.Chrome'

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 2
        $result.InstallInProgressWaitedSeconds | Should -Be 30
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Wait-WindowsInstallerIdle -Times 1 -Exactly -ParameterFilter { $MaximumSeconds -eq 600 }
        ($script:warnings -join "`n") | Should -Match 'Windows Installer is busy with another installation \(0x8A150102 INSTALL_INSTALL_IN_PROGRESS\)'
    }

    It 'Retries 0x8A150102 at most InstallInProgressRetries times' {
        $script:runQueue = @($script:InstallInProgress, $script:InstallInProgress, $script:InstallInProgress, $script:InstallInProgress, 0)

        $result = Install-WingetPackage -PackageId 'Google.Chrome'

        $result.ExitCode | Should -Be $script:InstallInProgress
        $result.Attempts | Should -Be 4
        $result.InstallInProgressWaitedSeconds | Should -Be 90
        Should -Invoke Invoke-WingetProcess -Times 4 -Exactly
        Should -Invoke Wait-WindowsInstallerIdle -Times 3 -Exactly
    }

    It 'Stops waiting once its share of the wait budget is spent' {
        # The first wait uses up all 100 seconds this call was given (Windows Installer still busy).
        Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = $MaximumSeconds; Busy = $true } }
        $script:runQueue = @($script:InstallInProgress, $script:InstallInProgress, 0)

        $result = Install-WingetPackage -PackageId 'Google.Chrome' -InstallInProgressWaitSeconds 100

        $result.ExitCode | Should -Be $script:InstallInProgress
        $result.Attempts | Should -Be 2
        $result.InstallInProgressWaitedSeconds | Should -Be 100
        Should -Invoke Wait-WindowsInstallerIdle -Times 1 -Exactly -ParameterFilter { $MaximumSeconds -eq 100 }
    }

    It 'Fails 0x8A150102 at once when the run has no wait budget left' {
        $script:runQueue = @($script:InstallInProgress, 0)

        $result = Install-WingetPackage -PackageId 'Google.Chrome' -InstallInProgressWaitSeconds 0

        $result.ExitCode | Should -Be $script:InstallInProgress
        $result.Attempts | Should -Be 1
        Should -Invoke Wait-WindowsInstallerIdle -Times 0 -Exactly
    }

    It 'Retries an in-use result (<Hex>) once, after a delay' -ForEach @(
        @{ Hex = '8A150101' }
        @{ Hex = '8A150103' }
        @{ Hex = '8A150111' }
    ) {
        $code = [Convert]::ToInt32($Hex, 16)
        $script:runQueue = @($code, 0)

        $result = Install-WingetPackage -PackageId 'Contoso.App'

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
        Should -Invoke Wait-WindowsInstallerIdle -Times 0 -Exactly
    }

    It 'Retries an in-use result only once' {
        $script:runQueue = @(-1978334975, -1978334975, 0)

        $result = Install-WingetPackage -PackageId 'Contoso.App' -InUseRetryDelaySeconds 5

        $result.ExitCode | Should -Be -1978334975
        $result.Attempts | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'Never retries 0x8A15010A: only a restart lets that installer run' {
        $script:runQueue = @($script:RestartFirst, 0)

        $result = Install-WingetPackage -PackageId 'Git.Git'

        $result.ExitCode | Should -Be $script:RestartFirst
        $result.Attempts | Should -Be 1
        $result.RestartRequired | Should -BeFalse
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Wait-WindowsInstallerIdle -Times 0 -Exactly
    }

    It 'Says a restart finishes the install for <Case>, without retrying' -ForEach @(
        @{ Case = 'winget 1.6 and older (0x8A150109)'; Run = @{ ExitCode = -1978334967 } }
        @{ Case = 'an installer that started a restart (0x8A15010B, MSI 1641)'; Run = @{ ExitCode = -1978334965 } }
        @{ Case = 'winget 1.7 and later (exit 0 with its restart warning)'; Run = @{ ExitCode = 0; Output = @('Starting package install...', 'Restart your PC to finish installation.') } }
    ) {
        $script:runQueue = @($Run, 0)

        $result = Install-WingetPackage -PackageId '7zip.7zip'

        $result.RestartRequired | Should -BeTrue
        $result.ExitCode | Should -Be $Run.ExitCode
        $result.Attempts | Should -Be 1
    }

    It 'Does not say a restart is needed for a plain success' {
        $script:runQueue = @(@{ ExitCode = 0; Output = @('Starting package install...', 'Successfully installed') })

        $result = Install-WingetPackage -PackageId '7zip.7zip'

        $result.RestartRequired | Should -BeFalse
        $result.InstallInProgressWaitedSeconds | Should -Be 0
    }
}

Describe 'Install-WingetPackage (transient launch-exception backoff, issue #253)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        # Never actually wait during tests; the backoff is verified via Should -Invoke.
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
    }

    It 'Retries with backoff and recovers when winget fails to launch with a transient file-lock error' {
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Klocman.BulkCrapUninstaller' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        # A failed launch never ran winget, so it does not consume an install attempt (issue #258).
        $result.Attempts | Should -Be 1
        $result.LaunchAttempts | Should -Be 1
        $result.LaunchErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Retries the same winget, never a winget.exe under the App Installer package folder (review finding P3-7)' {
        # The package folder launch (Resolve-WingetExecutable -BypassAlias) failed with 'Access is
        # denied' in every E2E run and was removed. A registered package is visible here, so a
        # leftover lookup would hand its path to the retry.
        $script:installLocation = Join-Path $TestDrive 'WindowsApps/Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; Version = '1.26.510.0'; InstallLocation = $script:installLocation } }
        Mock Test-Path { $true }
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -lt 3) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.LaunchAttempts | Should -Be 2
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $WingetPath -and $WingetPath -ne 'winget' }
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }

    It 'Also retries the sibling sharing-violation launch exception' {
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 32 -LaunchError 'The process cannot access the file because it is being used by another process.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.LaunchErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
    }

    It 'Exhausts MaxLaunchAttempts when winget.exe stays transiently inaccessible, returning a null ExitCode' {
        Mock Invoke-WingetProcess {
            New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
        }

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1 -MaxLaunchAttempts 3

        $result.ExitCode | Should -Be $null
        # No install ever ran: failed launches have their own budget and counter (issue #258).
        $result.Attempts | Should -Be 0
        $result.LaunchAttempts | Should -Be 3
        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchError | Should -Be 'The file cannot be accessed by the system.'
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        # Sleeps between launch attempts only (1->2 and 2->3), never after the final attempt.
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'Gives launch failures a larger default budget than install attempts (75s window, issue #258)' {
        Mock Invoke-WingetProcess {
            New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
        }
        $script:launchWaits = @()
        Mock Start-Sleep { $script:launchWaits += $Seconds }

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 5

        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchAttempts | Should -Be 5
        Should -Invoke Invoke-WingetProcess -Times 5 -Exactly
        # Doubling backoff sized to outlast an App Installer re-registration window.
        $script:launchWaits | Should -Be @(5, 10, 20, 40)
    }

    It 'Reports a launch failure that waiting does not change (<Case>) at once, without retrying or throwing' -ForEach @(
        @{ Case = 'file not found'; Code = 2; Message = 'The system cannot find the file specified.' }
        @{ Case = 'access denied'; Code = 5; Message = 'Access is denied.' }
    ) {
        # It used to throw, so the run reported an 'Unexpected error' and Invoke-WingetInstall's
        # circuit breaker never saw that winget could not be launched.
        $script:launchCode = $Code
        $script:launchMessage = $Message
        Mock Invoke-WingetProcess {
            New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage
        }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchError | Should -Be $Message
        $result.ExitCode | Should -Be $null
        $result.Attempts | Should -Be 0
        $result.LaunchAttempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

Describe 'Install-WingetPackage (time limit, installer log, --silent and launch codes; review findings P2-5, P2-6, P3-6)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
    }

    It 'Runs winget install through Invoke-WingetProcess under the install time limit' {
        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1)

        # No -WingetPath: Invoke-WingetProcess resolves winget itself (Resolve-WingetExecutable).
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'install' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetInstall) -and -not $WingetPath
        }
    }

    It 'Passes --silent when the run is unattended' {
        Mock Test-EffectiveNonInteractive { $true }

        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1)

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--silent' }
    }

    It 'Leaves --silent out when someone is at the console' {
        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1)

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--silent' }
    }

    It 'Follows an explicit -Silent over the detection (<Case>)' -ForEach @(
        @{ Case = '-Silent on an attended console'; Detected = $false; Silent = $true; Expected = $true }
        @{ Case = '-Silent:$false in an unattended run'; Detected = $true; Silent = $false; Expected = $false }
    ) {
        $script:detected = $Detected
        Mock Test-EffectiveNonInteractive { $script:detected }

        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 -Silent:$Silent)

        $script:expected = $Expected
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -contains '--silent') -eq $script:expected }
    }

    It 'Reports a timed-out install with no exit code and does not retry it' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3

        $result.TimedOut | Should -Be $true
        $result.TimeoutSeconds | Should -Be (Get-ProcessTimeoutSeconds -Operation WingetInstall)
        $result.ExitCode | Should -Be $null
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'Install of Test.App did not finish within 30 minutes and was stopped.' }
    }

    It 'Returns the installer log winget wrote, and names it when the install failed' {
        $script:installerLog = Join-Path $TestDrive 'winget-install-Test.App-20261004-101500.log'
        Set-Content -LiteralPath $script:installerLog -Value 'MSI (s) Return value 3.'
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335226 -LogPath $script:installerLog }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1

        $result.InstallerLogPath | Should -Be $script:installerLog
        $result.TimedOut | Should -Be $false
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq "Installer log for Test.App: $script:installerLog" }
    }

    It 'Returns no installer log when the installer wrote none' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -LogPath (Join-Path $TestDrive 'never-written.log') }

        (Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1).InstallerLogPath | Should -Be $null
    }

    It 'Retries a launch failure recognized by its Win32 code, whatever language the message is in' {
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'Das System kann auf die Datei nicht zugreifen.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.LaunchAttempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
    }
}

Describe 'Install-WingetPackage with a real process (review findings P2-5, P2-6)' {
    # The fake winget below really runs: Resolve-WingetExecutable hands its path to the install.
    BeforeEach {
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
        Mock Write-Info { }
        Mock Write-ErrorMessage { }
    }

    It 'Writes winget''s own output, including the installer''s exit code, into the transcript' {
        $script:fakeWinget = New-FakeExecutable -Directory $TestDrive -Name 'fake-winget' -StandardOutput 'Found Test App [Test.App] Version 1.0', 'Starting package install...', 'Installer failed with exit code: 1603' -ExitCode 1
        Mock Resolve-WingetExecutable { $script:fakeWinget }
        $transcript = Join-Path $TestDrive 'install-transcript.log'

        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1
        }
        finally {
            Stop-Transcript | Out-Null
        }

        $result.ExitCode | Should -Be 1
        $logged = Get-Content -LiteralPath $transcript -Raw
        $logged | Should -Match ([regex]::Escape('Found Test App [Test.App] Version 1.0'))
        $logged | Should -Match ([regex]::Escape('Installer failed with exit code: 1603'))
    }

    It 'Stops an install that runs past its time limit instead of waiting for ever' {
        $script:fakeWinget = New-FakeExecutable -Directory $TestDrive -Name 'fake-winget-hang' -StandardOutput 'Starting package install...' -SleepSeconds 30
        Mock Resolve-WingetExecutable { $script:fakeWinget }
        Mock Get-ProcessTimeoutSeconds { 3 }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3

        $stopwatch.Stop()
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 25
    }
}

Describe 'Test-WingetPackageInstalled (timeout support, issue #188)' {
    BeforeEach {
        Mock Write-Host { }
    }

    It 'Requires -TimeoutSeconds, so every call gets the three-way answer (work-order item 26, review finding P3-43)' {
        # Without -TimeoutSeconds the check used to return a plain [bool] under a 2-minute limit,
        # reading a winget it could not start, or one that ran out of time, as "not installed". No
        # caller used that mode; every caller passes the per-app limit (WingetListCheck).
        $timeoutParameter = (Get-Command Test-WingetPackageInstalled).Parameters['TimeoutSeconds']
        @($timeoutParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 1
    }

    Context 'With -TimeoutSeconds' {
        It 'Reports installed with the process exit code when the id appears in the output' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('Test.App  1.2.3  winget') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $true
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'list') -and
                ($ArgumentList -contains '--exact') -and
                ($ArgumentList -contains '--id') -and
                ($ArgumentList -contains 'Test.App') -and
                ($ArgumentList -contains '--accept-source-agreements') -and
                $TimeoutSeconds -eq 15 -and
                # Quiet: the per-app checks would otherwise print winget's table twice per app.
                $Echo -eq 'None'
            }
        }

        It 'Reports not-installed when the output only contains a different id that has the target as a substring' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('Foo.BarBaz  1.0.0  winget') }

            $result = Test-WingetPackageInstalled -PackageId 'Foo.Bar' -TimeoutSeconds 15

            $result.Installed | Should -Be $false
        }

        It 'Still reports installed for a real matching line when a substring-only lookalike is also listed' {
            Mock Invoke-WingetProcess { New-TestProcessResult -Output @('Name       Id           Version', 'Foo Bar    Foo.Bar      1.0', 'Foo BarBaz Foo.BarBaz  1.0') }

            (Test-WingetPackageInstalled -PackageId 'Foo.Bar' -TimeoutSeconds 15).Installed | Should -Be $true
        }

        It 'Reports not-installed when the output does not mention the id' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be -1978335212
        }

        It 'Looks for the id in standard output only, as before' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -StandardError @('Test.App could not be listed') }

            (Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15).Installed | Should -Be $false
        }

        It 'Reports a timed-out winget list distinctly from not-installed (issue #176)' {
            Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut -Output @('Test.App  1.2.3  winget') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 1

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $true
            $result.ExitCode | Should -Be $null
        }

        It 'Reports a winget that could not be started as LaunchFailed, not as not installed (review finding P2-9, <Case>)' -ForEach @(
            @{ Case = 'transient lock'; Code = 1920; Message = 'The file cannot be accessed by the system.' }
            @{ Case = 'access denied'; Code = 5; Message = 'Access is denied.' }
        ) {
            # It used to read as not installed, so the pipeline installed apps that were already
            # there and reported them as 'package not found after install'. Not retried here: the
            # caller decides, and Invoke-WingetInstall's circuit breaker checks once for the run.
            $script:launchCode = $Code
            $script:launchMessage = $Message
            Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.LaunchFailed | Should -Be $true
            $result.LaunchError | Should -Be $Message
            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be $null
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        }

        It 'Says LaunchFailed is false whenever winget answered (<Case>)' -ForEach @(
            @{ Case = 'installed'; Result = { New-TestProcessResult -ExitCode 0 -Output @('Test.App  1.0  winget') } }
            @{ Case = 'not installed'; Result = { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') } }
            @{ Case = 'timed out'; Result = { New-TestProcessResult -TimedOut } }
        ) {
            $script:processResult = & $Result
            Mock Invoke-WingetProcess { $script:processResult }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.LaunchFailed | Should -Be $false
            $result.LaunchError | Should -Be $null
        }

        It 'Reports a winget list that ran and failed as CheckFailed, not as not installed (review finding P2-9, <Case>)' -ForEach @(
            @{ Case = 'every source failed to open, 0x8A15004B'; Code = -1978335157 }
            @{ Case = 'blocked by policy, 0x8A15003A'; Code = -1978335174 }
            @{ Case = 'invalid arguments, 0x8A150002'; Code = -1978335230 }
        ) {
            # `winget list` exits 0 when it lists the package and 0x8A150014 when nothing matches;
            # it only warns about a source it could not search. Any other code is no answer.
            $script:listExitCode = $Code
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode $script:listExitCode -Output @('Failed when opening source(s); try the ''source reset'' command if the problem persists.') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.CheckFailed | Should -Be $true
            $result.ExitCode | Should -Be $Code
            $result.Installed | Should -Be $false
            $result.LaunchFailed | Should -Be $false
            $result.TimedOut | Should -Be $false
        }

        It 'Does not report CheckFailed for an answer from winget list (<Case>)' -ForEach @(
            @{ Case = 'listed, exit 0'; Result = { New-TestProcessResult -ExitCode 0 -Output @('Test.App  1.0  winget') }; Installed = $true }
            @{ Case = 'not found, 0x8A150014'; Result = { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') }; Installed = $false }
            @{ Case = 'exit 0 without the id'; Result = { New-TestProcessResult -ExitCode 0 -Output @('Other.App  1.0  winget') }; Installed = $false }
            @{ Case = 'listed with a non-zero exit'; Result = { New-TestProcessResult -ExitCode -1978335157 -Output @('Test.App  1.0  winget') }; Installed = $true }
            @{ Case = 'timed out'; Result = { New-TestProcessResult -TimedOut }; Installed = $false }
            @{ Case = 'launch failed'; Result = { New-TestProcessResult -LaunchFailed -LaunchErrorCode 5 -LaunchError 'Access is denied.' }; Installed = $false }
        ) {
            $script:processResult = & $Result
            Mock Invoke-WingetProcess { $script:processResult }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.CheckFailed | Should -Be $false
            $result.Installed | Should -Be $Installed
        }
    }
}

Describe 'Install-PowerShellLatest (always-latest strategy, issue #166)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
    }

    It 'installs the MSI while one is available and verifies via winget' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $true
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $InstallerType -eq 'wix' }
        Should -Invoke Install-MsixProvisionedPackage -Times 0 -Exactly
        # Timeout-guarded verification is pinned separately below ('passes a 15-second timeout...').
    }

    It 'installs the native MSIX on Windows 24H2+ when no MSI is available' {
        # -1978335216 = NO_APPLICABLE_INSTALLER: the wix (MSI) installer is gone at 7.7+.
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-native'
        $result.Installed | Should -Be $true
        Should -Invoke Install-MsixProvisionedPackage -Times 0 -Exactly
        # Timeout-guarded verification is pinned separately below ('passes a 15-second timeout...').
    }

    It 'provisions the MSIX via DISM on older Windows when no MSI is available' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } }
        Mock Get-WindowsBuildNumber { 19045 }
        Mock Install-MsixProvisionedPackage { @{ ExitCode = 0; Installed = $true } }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-provisioned'
        $result.Installed | Should -Be $true
        Should -Invoke Install-MsixProvisionedPackage -Times 1 -Exactly
    }

    It 'passes a 15-second timeout (matching Install-AppWithVerification) to the MSI-path verification call' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        [void](Install-PowerShellLatest)

        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'passes a 15-second timeout to the native-MSIX-path verification call' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        [void](Install-PowerShellLatest)

        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'treats a timed-out MSI-path verification as not installed rather than throwing' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; ExitCode = $null } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $false
    }

    It 'forwards -Silent:<Value> to both winget installs, and leaves it out when not given' -ForEach @(
        @{ Value = $true }
        @{ Value = $false }
    ) {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        [void](Install-PowerShellLatest -Silent:$Value)

        $script:expectedSilent = $Value
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { $PesterBoundParameters.ContainsKey('Silent') -and [bool]$Silent -eq $script:expectedSilent }

        [void](Install-PowerShellLatest)

        # Not given: Install-WingetPackage decides itself (Test-EffectiveNonInteractive).
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('Silent') }
    }

    It 'never installs at winget''s default scope with -MachineScopeOnly, and reports a package with no machine-scope installer without checking it (review finding P3-22)' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216; NoMachineScopeInstaller = [bool]$MachineScopeOnly } }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { throw 'nothing was installed, so nothing to check' }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        $result = Install-PowerShellLatest -MachineScopeOnly

        Should -Invoke Install-WingetPackage -Times 2 -Exactly
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { $MachineScopeOnly }
        $result.Method | Should -Be 'msix-native'
        $result.Installed | Should -Be $false
        $result.NoMachineScopeInstaller | Should -Be $true
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
    }

    It 'leaves -MachineScopeOnly off both installs when it is not given' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }

        [void](Install-PowerShellLatest)

        Should -Invoke Install-WingetPackage -Times 0 -Exactly -ParameterFilter { $MachineScopeOnly }
    }

    It 'shares the run''s wait budget for another installation between its MSI and MSIX attempts (review finding P2-15)' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216; InstallInProgressWaitedSeconds = 120 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0; InstallInProgressWaitedSeconds = 30 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        $result = Install-PowerShellLatest -InstallInProgressWaitSeconds 500

        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $InstallerType -eq 'wix' -and $InstallInProgressWaitSeconds -eq 500 }
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { -not $InstallerType -and $InstallInProgressWaitSeconds -eq 380 }
        $result.InstallInProgressWaitedSeconds | Should -Be 150
    }

    It 'returns a stopped install''s time limit and installer log, so the failure reason names them (review of P2-5/P2-6, <Method>)' -ForEach @(
        @{ Method = 'msi'; WixExitCode = $null }
        @{ Method = 'msix-native'; WixExitCode = -1978335216 }
    ) {
        $script:wixExitCode = $WixExitCode
        $script:logPath = Join-Path $TestDrive 'winget-install-Microsoft.PowerShell-20261004-101500.log'
        Mock Install-WingetPackage {
            if ($InstallerType -eq 'wix' -and $null -ne $script:wixExitCode) {
                return @{ ExitCode = $script:wixExitCode; TimedOut = $false; TimeoutSeconds = 1800; InstallerLogPath = $null }
            }
            @{ ExitCode = $null; Attempts = 1; TimedOut = $true; TimeoutSeconds = 1800; InstallerLogPath = $script:logPath }
        }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run here' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be $Method
        $result.Installed | Should -Be $false
        $result.TimedOut | Should -Be $true
        $result.TimeoutSeconds | Should -Be 1800
        $result.InstallerLogPath | Should -Be $script:logPath
        $reason = Format-InstallFailureReason -FailureReason 'CustomInstallFailed' -InstallResult $result
        $reason | Should -Match 'winget install stopped after 30 minutes'
        $reason | Should -Match ([regex]::Escape("installer log: $($script:logPath)"))
    }

    It 'returns Install-WingetPackage''s whole result, so PowerShell''s failure reason says why like every other app''s (review finding P3-8)' {
        # The #284 summary read 'Microsoft.PowerShell  installer reported failure' while every other
        # app named its exit code, attempts and launch errors: only ExitCode survived.
        Mock Install-WingetPackage { @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $true; MachineScopeFellBack = $false; LaunchErrorExhausted = $false; LaunchAttempts = 0; LaunchError = $null; TimedOut = $false; TimeoutSeconds = 1800; InstallerLogPath = $null } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; ExitCode = -1978335212 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $false
        $result.Attempts | Should -Be 3
        $result.SessionErrorExhausted | Should -Be $true
        $result.MachineScopeFellBack | Should -Be $false
        $result.VerifyTimedOut | Should -Be $false
        $result.VerifyLaunchFailed | Should -Be $false
        Format-InstallFailureReason -FailureReason 'CustomInstallFailed' -InstallResult $result |
            Should -Be 'the installing account has no logon session, so Windows blocked the app package deployment; winget exit 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF, 3 attempts, machine-scope fallback: no, session error 0x80073D19 persisted through every retry'
    }

    It 'says whether its winget check timed out or could not start winget' {
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; MachineScopeFellBack = $false; LaunchErrorExhausted = $false } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; ExitCode = $null } }
        $timedOut = Install-PowerShellLatest
        $timedOut.VerifyTimedOut | Should -Be $true
        $timedOut.VerifyLaunchFailed | Should -Be $false

        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = 'Access is denied.'; ExitCode = $null } }
        $launchFailed = Install-PowerShellLatest
        $launchFailed.VerifyLaunchFailed | Should -Be $true
        $launchFailed.VerifyLaunchError | Should -Be 'Access is denied.'
        $launchFailed.Installed | Should -Be $false
        $launchFailed.VerifyCheckFailed | Should -Be $false

        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $true; ExitCode = -1978335157 } }
        $checkFailed = Install-PowerShellLatest
        $checkFailed.VerifyCheckFailed | Should -Be $true
        $checkFailed.VerifyExitCode | Should -Be -1978335157
        $checkFailed.Installed | Should -Be $false
    }

    It 'skips its winget check when winget could not be launched for the install' {
        Mock Install-WingetPackage { @{ ExitCode = $null; Attempts = 0; LaunchErrorExhausted = $true; LaunchAttempts = 1; LaunchError = 'Access is denied.' } }
        Mock Test-WingetPackageInstalled { throw 'the check must not run: winget did not start for the install' }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Installed | Should -Be $false
        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchError | Should -Be 'Access is denied.'
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
    }
}

Describe 'Install-MsixProvisionedPackage (DISM provisioning, issue #166)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-ErrorMessage { }
        Mock New-Item { }
        Mock Remove-Item { }
    }

    It 'downloads, provisions, and verifies the MSIX for all users' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
        Mock Get-ChildItem {
            @(
                [pscustomobject]@{ Name = 'PowerShell-7.7.0-win.msixbundle'; Extension = '.msixbundle'; FullName = 'C:\dl\PowerShell-7.7.0-win.msixbundle' },
                [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.msix'; Extension = '.msix'; FullName = 'C:\dl\Dependencies\Microsoft.WindowsAppRuntime.msix' },
                [pscustomobject]@{ Name = 'PowerShell_License1.xml'; Extension = '.xml'; FullName = 'C:\dl\PowerShell_License1.xml' }
            )
        }
        Mock Invoke-AppxProvisioning { $true }
        Mock Test-AppxPackageProvisioned { $true }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $true
        Should -Invoke Invoke-AppxProvisioning -Times 1 -Exactly -ParameterFilter {
            $PackagePath -like '*PowerShell-7.7.0-win.msixbundle' -and (($DependencyPackagePath -join '') -like '*WindowsAppRuntime*')
        }
        # Time-limited (review finding P2-5): it used to wait with no limit.
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'download' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetDownload)
        }
    }

    It 'returns not-installed when winget download fails' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run after a failed download' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
        $result.ExitCode | Should -Be 1
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
    }

    It 'returns not-installed without provisioning when winget download times out' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run after a timed-out download' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
        $result.ExitCode | Should -Be $null
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
        Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish in time' }
    }

    It 'returns not-installed when no MSIX is found in the download' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
        Mock Get-ChildItem { @() }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run when no package was found' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
    }
}

Describe 'Invoke-AppxProvisioning (delegated command quoting, issue #178)' {
    # Under pwsh, Invoke-AppxProvisioning delegates to Windows PowerShell 5.1 by string-building
    # an elevated powershell.exe -Command payload. Every path interpolated into that string sits
    # inside a single-quoted literal, so embedded apostrophes must be doubled — otherwise a path
    # like C:\Users\O'Brien\... unbalances the quoting (or breaks out of the literal entirely).
    # These tests mock the powershell.exe invocation boundary and inspect the -Command argument.
    BeforeEach {
        Mock Write-ErrorMessage { }
        $script:capturedCommand = $null
        Mock powershell.exe { $script:capturedCommand = "$($args[-1])"; $global:LASTEXITCODE = 0 }
    }

    It 'escapes an apostrophe in PackagePath by doubling the single quote' {
        [void](Invoke-AppxProvisioning -PackagePath "C:\Users\O'Brien\pkg.msix")

        Should -Invoke powershell.exe -Times 1 -Exactly
        $script:capturedCommand | Should -BeLike "*-PackagePath 'C:\Users\O''Brien\pkg.msix'*"
        $script:capturedCommand | Should -Not -BeLike "*-PackagePath 'C:\Users\O'Brien*"
    }

    It 'escapes apostrophes in every DependencyPackagePath element before joining' {
        [void](Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msix' -DependencyPackagePath @(
                "C:\Users\O'Brien\dep1.msix",
                "C:\Users\D'Arcy\dep2.msix"
            ))

        $script:capturedCommand | Should -BeLike "*-DependencyPackagePath @('C:\Users\O''Brien\dep1.msix','C:\Users\D''Arcy\dep2.msix')*"
    }

    It 'escapes an apostrophe in LicensePath' {
        Mock Test-Path { $true }

        [void](Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msix' -LicensePath "C:\Users\O'Brien\license.xml")

        $script:capturedCommand | Should -BeLike "*-LicensePath 'C:\Users\O''Brien\license.xml'*"
    }

    It 'leaves apostrophe-free paths unchanged and skips the license when none exists' {
        $result = Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msixbundle' -DependencyPackagePath @('C:\dl\Dependencies\runtime.msix')

        $result | Should -Be $true
        $script:capturedCommand | Should -BeLike "*-PackagePath 'C:\dl\pkg.msixbundle' -DependencyPackagePath @('C:\dl\Dependencies\runtime.msix') -SkipLicense*"
    }
}

Describe 'Invoke-AppxProvisioning -TimeoutSeconds (work-order item 31)' {
    # The Windows App Runtime framework install provisions with a time limit, so a DISM call that
    # hangs cannot hold an unattended run for ever (review finding P2-5). The Windows PowerShell
    # child then runs through Invoke-ExternalProcess, which echoes its output into the transcript.
    BeforeEach {
        $script:errors = @()
        Mock Write-ErrorMessage { $script:errors += $Message }
        Mock powershell.exe { throw 'the time-limited path must not call powershell.exe directly' }
    }

    It 'runs Add-AppxProvisionedPackage in Windows PowerShell with the time limit and no progress bar' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

        $result = Invoke-AppxProvisioning -PackagePath "C:\Users\O'Brien\fw.msix" -TimeoutSeconds 600

        $result | Should -BeTrue
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'powershell.exe' -and $TimeoutSeconds -eq 600 -and
            $ArgumentList[0] -eq '-NoProfile' -and $ArgumentList[-2] -eq '-Command' -and
            $ArgumentList[-1] -like "`$ProgressPreference = 'SilentlyContinue'; Add-AppxProvisionedPackage -Online -PackagePath 'C:\Users\O''Brien\fw.msix'  -SkipLicense -ErrorAction Stop*"
        }
        Should -Invoke powershell.exe -Times 0 -Exactly
    }

    # Review of item 31: Windows PowerShell writes redirected output in the console's code page, so
    # read as UTF-8 a localized DISM error would lose its non-ASCII letters in the transcript.
    It 'reads Windows PowerShell''s output in the console''s encoding, not as UTF-8' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

        Invoke-AppxProvisioning -PackagePath 'C:\dl\fw.msix' -TimeoutSeconds 600 | Should -BeTrue

        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $null -ne $Encoding -and $Encoding.CodePage -eq [Console]::OutputEncoding.CodePage
        }
    }

    # Work-order item 35's review: Windows PowerShell started through Process.Start from PowerShell 7
    # inherits PowerShell 7's PSModulePath and then cannot load its own modules.
    It 'starts Windows PowerShell without PowerShell 7''s PSModulePath' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

        Invoke-AppxProvisioning -PackagePath 'C:\dl\fw.msix' -TimeoutSeconds 600 | Should -BeTrue

        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            @($RemoveEnvironmentVariable) -contains 'PSModulePath'
        }
    }

    It 'returns false, and says so, when <Case>' -Skip:($PSVersionTable.PSEdition -ne 'Core') -ForEach @(
        @{ Case = 'Add-AppxProvisionedPackage fails'; Result = { New-TestProcessResult -ExitCode 1 }; Message = $null }
        @{ Case = 'it runs past the time limit'; Result = { New-TestProcessResult -TimedOut }; Message = "Add-AppxProvisionedPackage did not finish within 10 minutes for 'C:\dl\fw.msix' and was stopped." }
        @{ Case = 'Windows PowerShell cannot be started'; Result = { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'The system cannot find the file specified.' }; Message = "Add-AppxProvisionedPackage failed for 'C:\dl\fw.msix': Windows PowerShell could not be started (The system cannot find the file specified.)." }
    ) {
        $script:processResult = & $Result
        Mock Invoke-ExternalProcess { $script:processResult }

        Invoke-AppxProvisioning -PackagePath 'C:\dl\fw.msix' -TimeoutSeconds 600 | Should -BeFalse

        if ($Message) {
            $script:errors | Should -Be @($Message)
        }
    }
}
