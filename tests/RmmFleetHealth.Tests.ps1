# RmmFleetHealth.Tests.ps1
# Tests for the fleet health probe and its companion fix (work-order item 36):
# rmm/Get-WingetFleetHealth.ps1, a read-only probe an RMM pushes as SYSTEM, and
# rmm/Repair-WauLogonTrigger.ps1, which removes Winget-AutoUpdate's at-logon trigger on PCs deployed
# before the installer stopped adding it. Both are standalone single files (an RMM pushes one file),
# so each is dot-sourced (its run starts only when it is run) or run with & under the mocks, and
# every Windows-only source (Get-AppxPackage, the scheduled-task cmdlets, the registry, winget.exe)
# is mocked; the process runner is tested against small stand-in programs. The parts that repeat
# the installer's own logic are checked against the module's functions, so the two cannot drift.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ProbePath = Join-Path $script:RepoRoot 'rmm/Get-WingetFleetHealth.ps1'
    $script:RepairPath = Join-Path $script:RepoRoot 'rmm/Repair-WauLogonTrigger.ps1'
    $script:BuildScriptPath = Join-Path $script:RepoRoot 'build/Build-WingetInstallScript.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Get-FunctionText {
        param ([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        if ($definition) { return $definition.Extent.Text }
        return $null
    }

    function Get-FunctionName {
        param ([Parameter(Mandatory = $true)][string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
    }

    # A package as Get-AppxPackage -AllUsers returns it, with the properties the probe reads. Each
    # user is a hashtable with Sid, Account and State, or a string, the text form
    # ('S-1-5-18 [S-1-5-18]: Staged').
    function New-TestAppxPackage {
        param (
            [string]$Name = 'Microsoft.DesktopAppInstaller',
            [string]$Version = '1.29.380.0',
            [string]$Architecture = 'X64',
            [string]$Status = 'Ok',
            [string]$InstallLocation = '',
            [object[]]$Users = @()
        )
        $userInformation = @(foreach ($user in $Users) {
                if ($user -is [string]) {
                    $user
                }
                else {
                    [pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = $user.Sid; Username = $user.Account }; InstallState = $user.State }
                }
            })
        [pscustomobject]@{ Name = $Name; Version = $Version; Architecture = $Architecture; Status = $Status; InstallLocation = $InstallLocation; PackageUserInformation = $userInformation }
    }

    # A trigger as Get-ScheduledTask returns it.
    function New-TestTaskTrigger {
        param ([string]$ClassName = 'MSFT_TaskWeeklyTrigger', $DaysOfWeek = $null, [string]$StartBoundary = $null, $Enabled = $true)
        [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = $ClassName }; DaysOfWeek = $DaysOfWeek; StartBoundary = $StartBoundary; Enabled = $Enabled }
    }

    # An App Installer folder holding a winget.exe (an empty file: the probe only checks it exists;
    # its runs are mocked).
    function New-TestAppInstallerFolder {
        param ([Parameter(Mandatory = $true)][string]$Root, [string]$Name = 'Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe')
        $folder = Join-Path $Root $Name
        $null = New-Item -ItemType Directory -Path $folder -Force
        $null = New-Item -ItemType File -Path (Join-Path $folder 'winget.exe') -Force
        return $folder
    }

    $script:WauLogText = @'
#################################################################
#    10/4/2026 - CHECK FOR APP UPDATES (System context)
#################################################################
02:00:05 - Reading WAUConfig
02:00:06 - Checking prerequisites...
02:00:07 - WinGet installed version: 1.26.510 | WinGet available version: 1.29.380
02:00:07 - -> Downloading WinGet MSIXBundle for App Installer...
02:00:30 - -> Installing WinGet MSIXBundle for App Installer...
02:02:10 - -> Failed to install WinGet MSIXBundle for App Installer...
02:02:10 - Prerequisites check failed
02:02:11 - Checking application updates on Winget Repository named 'winget' ..
02:02:15 - No update found. 'Winget upgrade' output:
Program 'winget.exe' failed to run: Access is denied
At C:\Program Files\Winget-AutoUpdate\functions\Get-WingetOutdatedApps.ps1:41 char:26
+ more winget output that is not kept

02:02:15 - End of process!
'@

    . ([scriptblock]::Create((Get-FunctionText -Path $script:BuildScriptPath -Name 'Get-PowerShell7OnlySyntax')))
}

Describe 'The fleet health scripts: Windows PowerShell 5.1, one file each, shared code' {
    It 'Stays runnable by Windows PowerShell 5.1: <_> is ASCII only, parses cleanly, no PowerShell 7-only syntax' -ForEach @('rmm/Get-WingetFleetHealth.ps1', 'rmm/Repair-WauLogonTrigger.ps1') {
        $path = Join-Path $script:RepoRoot $_
        @([System.IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        @(Get-PowerShell7OnlySyntax -Ast $ast -Tokens $tokens | ForEach-Object { '{0} at line {1}' -f $_.Kind, $_.Line }) | Should -BeNullOrEmpty
    }

    It 'Needs nothing but itself: <_> dot-sources and imports nothing' -ForEach @('rmm/Get-WingetFleetHealth.ps1', 'rmm/Repair-WauLogonTrigger.ps1') {
        # An RMM pushes and runs the one file: anything it loaded from beside it would be missing.
        $path = Join-Path $script:RepoRoot $_
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $loads = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -or $node.GetCommandName() -in @('Import-Module', 'Invoke-Expression', 'iex')) }, $true)

        @($loads | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty
    }

    It 'Defines the helpers both scripts have the same way' {
        $probeFunctions = Get-FunctionName -Path $script:ProbePath
        $shared = @(Get-FunctionName -Path $script:RepairPath | Where-Object { $_ -in $probeFunctions })

        $shared | Should -Contain 'Invoke-RmmRelaunchWhenNeeded' -Because 'the 64-bit relaunch is shared'
        $shared | Should -Contain 'Test-RmmElevated'
        foreach ($name in $shared) {
            Get-FunctionText -Path $script:RepairPath -Name $name | Should -BeExactly (Get-FunctionText -Path $script:ProbePath -Name $name) -Because "$name must be the same in both scripts"
        }
    }

    It 'Runs nothing when dot-sourced: <_>' -ForEach @('rmm/Get-WingetFleetHealth.ps1', 'rmm/Repair-WauLogonTrigger.ps1') {
        $path = (Join-Path $script:RepoRoot $_).Replace("'", "''")
        $output = & $script:Pwsh -NoProfile -NonInteractive -Command ". '$path'; 'dot-sourced'; exit 0" 2>&1

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -BeExactly 'dot-sourced'
    }

    Context 'The shared helpers' {
        BeforeAll {
            . $script:ProbePath
        }

        It 'Runs a 32-bit PowerShell on 64-bit Windows again through Sysnative' {
            Get-RmmNativePowerShellRelaunchPath -Is64BitOperatingSystem $true -Is64BitProcess $false -Edition 'Desktop' | Should -BeLike '*\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
            Get-RmmNativePowerShellRelaunchPath -Is64BitOperatingSystem $true -Is64BitProcess $false -Edition 'Core' | Should -BeLike '*\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }

        It 'Runs PowerShell 7 again in Windows PowerShell, and leaves a 64-bit Windows PowerShell alone' {
            Get-RmmNativePowerShellRelaunchPath -Is64BitOperatingSystem $true -Is64BitProcess $true -Edition 'Core' | Should -BeLike '*\System32\WindowsPowerShell\v1.0\powershell.exe'
            Get-RmmNativePowerShellRelaunchPath -Is64BitOperatingSystem $true -Is64BitProcess $true -Edition 'Desktop' | Should -BeNullOrEmpty
            Get-RmmNativePowerShellRelaunchPath -Is64BitOperatingSystem $false -Is64BitProcess $false -Edition 'Desktop' | Should -BeNullOrEmpty
        }

        It 'Forwards the bound parameters, -WhatIf among them' {
            $bound = [ordered]@{ WingetTimeoutSeconds = 45; WhatIf = [System.Management.Automation.SwitchParameter]::new($true); Relaunched = [System.Management.Automation.SwitchParameter]::new($false) }

            ConvertTo-RmmForwardedArgument -BoundParameters $bound | Should -Be @('-WhatIf', '-WingetTimeoutSeconds', '45')
        }

        It 'Relaunches with -File, the forwarded arguments and -Relaunched, and passes the exit code and lines on' {
            Mock Get-RmmNativePowerShellRelaunchPath { 'C:\Windows\Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
            Mock Invoke-RmmNativeRelaunch { [pscustomobject]@{ Lines = @('a check', 'HEALTH: status=unhealthy problems=winget-launch'); ExitCode = 1; LaunchError = $null } }

            $result = Invoke-RmmRelaunchWhenNeeded -ScriptPath 'C:\probe.ps1' -ForwardedArguments @('-LogMatchCount', '5') -ResultPrefix 'HEALTH' -FailureStatus 'unhealthy' -FailureProblem 'probe-error'

            $result.ExitCode | Should -Be 1
            $result.Lines[0] | Should -BeLike '*ran again in C:\Windows\Sysnative\WindowsPowerShell\v1.0\powershell.exe*'
            $result.Lines[-1] | Should -BeExactly 'HEALTH: status=unhealthy problems=winget-launch'
            Should -Invoke Invoke-RmmNativeRelaunch -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -eq '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\probe.ps1 -LogMatchCount 5 -Relaunched'
            }
        }

        It 'Returns nothing when no relaunch is needed' {
            Mock Get-RmmNativePowerShellRelaunchPath { $null }
            Mock Invoke-RmmNativeRelaunch { throw 'must not run' }

            Invoke-RmmRelaunchWhenNeeded -ScriptPath 'C:\probe.ps1' -ResultPrefix 'HEALTH' -FailureStatus 'unhealthy' -FailureProblem 'probe-error' | Should -BeNullOrEmpty
        }

        It 'Fails with a result line when the relaunch <Case>' -ForEach @(
            @{ Case = 'cannot start'; Relaunch = @{ Lines = @(); ExitCode = $null; LaunchError = 'C:\x does not exist' }; ScriptPath = 'C:\probe.ps1'; Expected = '*could not run this script again*C:\x does not exist*' }
            @{ Case = 'prints no result line'; Relaunch = @{ Lines = @('Execution of scripts is disabled on this system.'); ExitCode = 1; LaunchError = $null }; ScriptPath = 'C:\probe.ps1'; Expected = '*ended without a HEALTH line*' }
            @{ Case = 'has no script file to run'; Relaunch = $null; ScriptPath = ''; Expected = '*not started from a file*' }
        ) {
            $relaunchResult = $Relaunch
            Mock Get-RmmNativePowerShellRelaunchPath { 'C:\Windows\Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
            Mock Invoke-RmmNativeRelaunch { [pscustomobject]$relaunchResult }

            $result = Invoke-RmmRelaunchWhenNeeded -ScriptPath $ScriptPath -ResultPrefix 'HEALTH' -FailureStatus 'unhealthy' -FailureProblem 'probe-error'

            $result.ExitCode | Should -Be 1
            ($result.Lines -join "`n") | Should -BeLike $Expected
            $result.Lines[-1] | Should -BeLike 'HEALTH: status=unhealthy problems=probe-error computer=*'
        }

        It 'Writes result values without spaces or =' {
            ConvertTo-RmmResultValue -Value 'PC 01=x' | Should -BeExactly 'PC_01_x'
            ConvertTo-RmmResultValue -Value '' | Should -BeExactly '-'
            ConvertTo-RmmResultValue -Value $null | Should -BeExactly '-'
        }
    }
}

Describe 'rmm/Get-WingetFleetHealth.ps1: the probe' {
    BeforeAll {
        . $script:ProbePath
    }

    BeforeEach {
        $script:appInstallerRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:newestFolder = New-TestAppInstallerFolder -Root $script:appInstallerRoot -Name 'Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe'
        $script:olderFolder = New-TestAppInstallerFolder -Root $script:appInstallerRoot -Name 'Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        $script:windowsApps = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:windowsApps
        $script:wauFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:wauFolder 'logs')
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $script:wauFolder 'logs') 'updates.log'), $script:WauLogText, [System.Text.Encoding]::Unicode)

        $script:appInstallerPackages = @(
            (New-TestAppxPackage -Version '1.26.510.0' -InstallLocation $script:olderFolder -Users @('S-1-5-18 [S-1-5-18]: Staged')),
            (New-TestAppxPackage -Version '1.29.380.0' -InstallLocation $script:newestFolder -Users @(@{ Sid = 'S-1-5-21-1-2-3-1001'; Account = 'CONTOSO\jdoe'; State = 'Installed' }, @{ Sid = 'S-1-5-18'; Account = ''; State = 'Staged' }))
        )
        $script:runtimePackages = @(
            (New-TestAppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -Version '8000.616.304.0' -Architecture 'X64'),
            (New-TestAppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -Version '8000.616.304.0' -Architecture 'X86')
        )
        $script:wauInstall = [pscustomobject]@{ Installed = $true; Version = '2.12.0'; InstallLocation = $script:wauFolder; UpdatesAtLogon = 0; PolicyUpdatesAtLogon = $null; Error = $null }
        $script:taskState = 'Ready'
        $script:taskTriggers = @(New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 4 -StartBoundary '2026-10-06T02:00:00')

        Mock Test-RmmElevated { $true }
        Mock Get-RmmOSArchitecture { 'X64' }
        Mock Get-RmmWindowsAppsDirectory { $script:windowsApps }
        Mock Get-AppxPackage { }
        Mock Get-AppxPackage { $script:appInstallerPackages } -ParameterFilter { $Name -eq 'Microsoft.DesktopAppInstaller' }
        Mock Get-AppxPackage { $script:runtimePackages } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
        Mock Invoke-RmmTimedProcess { [pscustomobject]@{ ExitCode = 0; TimedOut = $false; LaunchError = $null; LaunchErrorCode = $null; Output = @('v1.29.380'); DurationSeconds = 0.3 } }
        Mock Get-RmmWauInstall { $script:wauInstall }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = $script:taskState; Triggers = $script:taskTriggers } }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-10-04T02:00:00'; LastTaskResult = 0; NextRunTime = [datetime]'2026-10-11T02:00:00' } }
    }

    It 'Reports a healthy PC with one line per check, a HEALTH line last, and exit code 0' {
        $result = Invoke-RmmFleetHealthProbe

        $result.ExitCode | Should -Be 0
        $result.Problems | Should -BeNullOrEmpty
        $result.Lines[-1] | Should -BeLike 'HEALTH: status=healthy problems=none computer=* appinstaller=1.29.380.0 runtime=present winget=ok wingetversion=1.29.380 wau=2.12.0 wautask=Ready wauresult=0x00000000 logontrigger=no wauwingetinstalls=1'
        $result.Lines | Should -Contain 'Healthy.'
        $result.Lines | Should -Contain 'Windows App Runtime: present (Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 for X64; found X64 8000.616.304.0, X86 8000.616.304.0).'
        $result.Lines | Should -Contain 'WAU task \WAU\Winget-AutoUpdate: state Ready; triggers: Weekly on Tuesday from 2026-10-06T02:00:00; at-logon trigger: no; last run 2026-10-04 02:00, result 0x00000000 (success); next run 2026-10-11 02:00.'
        $result.Lines | Should -Contain 'Winget-AutoUpdate: installed: version 2.12.0; WAU_UpdatesAtLogon = 0.'
        @($result.Lines | Where-Object { $_ -match '[\r\n]' }) | Should -BeNullOrEmpty
    }

    It 'Lists each App Installer version, newest first, with each account''s install state' {
        $lines = (Invoke-RmmFleetHealthProbe).Lines

        $appInstaller = @($lines | Where-Object { $_ -like 'App Installer *' })
        $appInstaller | Should -Be @(
            'App Installer 1.29.380.0 X64, status Ok: CONTOSO\jdoe Installed; S-1-5-18 Staged',
            'App Installer 1.26.510.0 X64, status Ok: S-1-5-18 Staged'
        )
    }

    It 'Runs the newest winget.exe with --version and a time limit' {
        $lines = (Invoke-RmmFleetHealthProbe -WingetTimeoutSeconds 45).Lines

        Should -Invoke Invoke-RmmTimedProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $script:newestFolder 'winget.exe') -and ($ArgumentList -join ' ') -eq '--version' -and $TimeoutSeconds -eq 45
        }
        $lines | Should -Contain ('winget: {0} (App Installer 1.29.380.0, x64) --version printed v1.29.380 (exit 0, 0.3 s)' -f (Join-Path $script:newestFolder 'winget.exe'))
    }

    It 'Is unhealthy when the at-logon trigger is still there' {
        $script:taskTriggers = @((New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger'), (New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 4))

        $result = Invoke-RmmFleetHealthProbe

        $result.ExitCode | Should -Be 1
        $result.Problems | Should -Be @('wau-logon-trigger')
        $result.Lines[-1] | Should -BeLike 'HEALTH: status=unhealthy problems=wau-logon-trigger * logontrigger=yes *'
        ($result.Lines -join "`n") | Should -BeLike '*rmm/Repair-WauLogonTrigger.ps1*'
    }

    It 'Is unhealthy when WAU is installed and the Windows App Runtime is <Case>' -ForEach @(
        @{ Case = 'not installed'; Packages = @() }
        @{ Case = 'too old'; Packages = @(@{ Version = '8000.616.303.0'; Architecture = 'X64' }) }
        @{ Case = 'there for another architecture only'; Packages = @(@{ Version = '8000.616.304.0'; Architecture = 'X86' }) }
    ) {
        $script:runtimePackages = @(foreach ($package in $Packages) { New-TestAppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -Version $package.Version -Architecture $package.Architecture })

        $result = Invoke-RmmFleetHealthProbe

        $result.ExitCode | Should -Be 1
        $result.Problems | Should -Be @('runtime-missing')
        $result.Lines[-1] | Should -BeLike '* runtime=missing *'
    }

    It 'Is healthy when the Windows App Runtime is missing and WAU is not installed' {
        $script:runtimePackages = @()
        $script:wauInstall = [pscustomobject]@{ Installed = $false; Version = $null; InstallLocation = $null; UpdatesAtLogon = $null; PolicyUpdatesAtLogon = $null; Error = $null }
        Mock Get-ScheduledTask {
            Write-Error -Exception ([System.Exception]::new("No MSFT_ScheduledTask objects found with property 'TaskName' equal to 'Winget-AutoUpdate'.")) -ErrorId 'CmdletizationQuery_NotFound_TaskName' -Category ObjectNotFound
        }

        $result = Invoke-RmmFleetHealthProbe

        $result.ExitCode | Should -Be 0
        $result.Lines | Should -Contain 'Winget-AutoUpdate: not installed.'
        $result.Lines[-1] | Should -BeLike '* runtime=missing winget=ok * wau=none wautask=- wauresult=- logontrigger=- wauwingetinstalls=-'
        Should -Invoke Get-ScheduledTaskInfo -Times 0 -Exactly
    }

    It 'Is unhealthy when WAU is installed and the Windows App Runtime cannot be read' {
        Mock Get-AppxPackage { throw 'Access is denied.' } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }

        $result = Invoke-RmmFleetHealthProbe

        $result.Problems | Should -Be @('runtime-unknown')
        $result.Lines[-1] | Should -BeLike '* runtime=unknown *'
    }

    It 'Is unhealthy when winget.exe <Case>' -ForEach @(
        @{ Case = 'cannot be started'; Run = @{ ExitCode = $null; TimedOut = $false; LaunchError = 'Access is denied'; LaunchErrorCode = 5; Output = @(); DurationSeconds = 0 }; State = 'failed'; Expected = '*--version could not be started (error 5): Access is denied' }
        @{ Case = 'does not finish in time'; Run = @{ ExitCode = $null; TimedOut = $true; LaunchError = $null; LaunchErrorCode = $null; Output = @(); DurationSeconds = 30 }; State = 'timedout'; Expected = '*--version did not finish within 30 seconds and was stopped' }
        @{ Case = 'cannot load a DLL'; Run = @{ ExitCode = -1073741515; TimedOut = $false; LaunchError = $null; LaunchErrorCode = $null; Output = @(); DurationSeconds = 0.1 }; State = 'failed'; Expected = '*--version exited with 0xC0000135 (-1073741515), STATUS_DLL_NOT_FOUND*Visual C++*' }
        @{ Case = 'prints no version'; Run = @{ ExitCode = 0; TimedOut = $false; LaunchError = $null; LaunchErrorCode = $null; Output = @('Failed to initialize'); DurationSeconds = 0.1 }; State = 'failed'; Expected = '*--version exited with 0x00000000 (0) after 0.1 s: Failed to initialize' }
    ) {
        $run = $Run
        Mock Invoke-RmmTimedProcess { [pscustomobject]$run }

        $result = Invoke-RmmFleetHealthProbe

        $result.ExitCode | Should -Be 1
        $result.Problems | Should -Be @('winget-launch')
        $result.Lines[-1] | Should -BeLike "* winget=$State wingetversion=- *"
        @($result.Lines | Where-Object { $_ -like 'winget: *' })[0] | Should -BeLike $Expected
        Should -Invoke Invoke-RmmTimedProcess -Times 2 -Exactly
    }

    It 'Says when only an older winget.exe still runs, and is unhealthy: WAU runs the newest' {
        Mock Invoke-RmmTimedProcess { [pscustomobject]@{ ExitCode = $null; TimedOut = $false; LaunchError = 'Access is denied'; LaunchErrorCode = 5; Output = @(); DurationSeconds = 0 } } -ParameterFilter { $FilePath -like '*1.29.380.0*' }

        $result = Invoke-RmmFleetHealthProbe

        $result.Problems | Should -Be @('winget-launch')
        $result.Lines[-1] | Should -BeLike '* winget=fallback wingetversion=1.29.380 *'
        $lines = @($result.Lines | Where-Object { $_ -like 'winget: *' })
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeLike '*1.29.380.0*could not be started*'
        $lines[1] | Should -BeLike '*1.26.510.0*printed v1.29.380*'
    }

    It 'Is unhealthy when there is no machine-wide winget.exe' {
        $script:appInstallerPackages = @()

        $result = Invoke-RmmFleetHealthProbe

        $result.Problems | Should -Be @('winget-notfound')
        $result.Lines[-1] | Should -BeLike '* appinstaller=none * winget=notfound wingetversion=- *'
        $result.Lines | Should -Contain 'App Installer (Microsoft.DesktopAppInstaller): not installed for any account.'
        Should -Invoke Invoke-RmmTimedProcess -Times 0 -Exactly
    }

    It 'Finds winget.exe under WindowsApps when App Installer cannot be listed' {
        Mock Get-AppxPackage { throw 'Access is denied.' } -ParameterFilter { $Name -eq 'Microsoft.DesktopAppInstaller' }
        $folder = New-TestAppInstallerFolder -Root $script:windowsApps -Name 'Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe'

        $result = Invoke-RmmFleetHealthProbe

        $result.Lines[-1] | Should -BeLike '* appinstaller=unknown * winget=ok wingetversion=1.29.380 *'
        Should -Invoke Invoke-RmmTimedProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq (Join-Path $folder 'winget.exe') }
    }

    It 'Is unhealthy when WAU is installed and its task <Case>' -ForEach @(
        @{ Case = 'does not exist'; Problem = 'wau-task-missing'; Task = 'missing'; Mock = { Write-Error -Exception ([System.Exception]::new('No MSFT_ScheduledTask objects found.')) -ErrorId 'CmdletizationQuery_NotFound_TaskName' -Category ObjectNotFound } }
        @{ Case = 'cannot be read'; Problem = 'wau-task-unknown'; Task = 'unknown'; Mock = { Write-Error -Exception ([System.UnauthorizedAccessException]::new('Access is denied.')) -ErrorId 'HRESULT 0x80070005,Get-ScheduledTask' -Category PermissionDenied } }
        @{ Case = 'is disabled'; Problem = 'wau-task-disabled'; Task = 'Disabled'; Mock = { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Disabled'; Triggers = @(New-TestTaskTrigger) } } }
        @{ Case = 'has no enabled trigger'; Problem = 'wau-task-no-trigger'; Task = 'Ready'; Mock = { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Ready'; Triggers = @(New-TestTaskTrigger -Enabled $false) } } }
    ) {
        Mock Get-ScheduledTask $Mock

        $result = Invoke-RmmFleetHealthProbe

        $result.ExitCode | Should -Be 1
        $result.Problems | Should -Be @($Problem)
        $result.Lines[-1] | Should -BeLike "* wautask=$Task *"
    }

    It 'Is unhealthy when it cannot read the machine: not elevated' {
        Mock Test-RmmElevated { $false }

        $result = Invoke-RmmFleetHealthProbe

        $result.Problems | Should -Contain 'not-elevated'
        $result.ExitCode | Should -Be 1
    }

    It 'Names a Group Policy that puts the at-logon trigger back' {
        $script:wauInstall.PolicyUpdatesAtLogon = 1

        $lines = (Invoke-RmmFleetHealthProbe).Lines

        ($lines -join "`n") | Should -BeLike "*Group Policy WAU_UpdatesAtLogon = 1 (WAU's Winget-AutoUpdate-Policies task puts the at-logon trigger back every day)*"
    }

    It 'Shows the matching lines of WAU''s log, with the winget output after No update found' {
        $lines = (Invoke-RmmFleetHealthProbe).Lines

        @($lines | Where-Object { $_ -like 'WAU log | *' }) | Should -Be @(
            'WAU log | #    10/4/2026 - CHECK FOR APP UPDATES (System context)',
            'WAU log | 02:00:07 - WinGet installed version: 1.26.510 | WinGet available version: 1.29.380',
            'WAU log | 02:00:07 - -> Downloading WinGet MSIXBundle for App Installer...',
            'WAU log | 02:00:30 - -> Installing WinGet MSIXBundle for App Installer...',
            'WAU log | 02:02:10 - -> Failed to install WinGet MSIXBundle for App Installer...',
            'WAU log | 02:02:10 - Prerequisites check failed',
            'WAU log | 02:02:15 - No update found. ''Winget upgrade'' output:',
            'WAU log |     Program ''winget.exe'' failed to run: Access is denied',
            'WAU log |     At C:\Program Files\Winget-AutoUpdate\functions\Get-WingetOutdatedApps.ps1:41 char:26'
        )
        ($lines -join "`n") | Should -BeLike "*: 7 matching entries, the last 7 below; 'Installing WinGet MSIXBundle' 1 times.*"
    }

    It 'Shows only the last -LogMatchCount entries' {
        $lines = (Invoke-RmmFleetHealthProbe -LogMatchCount 2).Lines

        @($lines | Where-Object { $_ -like 'WAU log | *' }) | Should -Be @(
            'WAU log | 02:02:10 - Prerequisites check failed',
            'WAU log | 02:02:15 - No update found. ''Winget upgrade'' output:',
            'WAU log |     Program ''winget.exe'' failed to run: Access is denied',
            'WAU log |     At C:\Program Files\Winget-AutoUpdate\functions\Get-WingetOutdatedApps.ps1:41 char:26'
        )
    }

    It 'Says when WAU''s log does not exist yet' {
        Remove-Item -LiteralPath (Join-Path (Join-Path $script:wauFolder 'logs') 'updates.log')

        $result = Invoke-RmmFleetHealthProbe

        ($result.Lines -join "`n") | Should -BeLike '*updates.log does not exist (WAU creates it on its first run).*'
        $result.Lines[-1] | Should -BeLike '* wauwingetinstalls=-'
        $result.ExitCode | Should -Be 0
    }

    Context 'Run as a script' {
        # The script runs with & under the mocks. Its own script scope is what a mock body's
        # $script: variables read then, so these mocks return literals.
        BeforeEach {
            Mock Get-RmmNativePowerShellRelaunchPath { $null }
        }

        It 'Prints the report, the HEALTH line last, and exits with the probe''s exit code' {
            Mock Invoke-RmmFleetHealthProbe { [pscustomobject]@{ Lines = @('a check', 'HEALTH: status=unhealthy problems=wau-logon-trigger'); Problems = @('wau-logon-trigger'); ExitCode = 1 } }

            $output = @(& $script:ProbePath -Relaunched -WingetTimeoutSeconds 45 -LogMatchCount 3)
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Be 1
            $output | Should -Be @('a check', 'HEALTH: status=unhealthy problems=wau-logon-trigger')
            Should -Invoke Invoke-RmmFleetHealthProbe -Times 1 -Exactly -ParameterFilter { $WingetTimeoutSeconds -eq 45 -and $LogMatchCount -eq 3 -and $Note -eq 'Run again in 64-bit Windows PowerShell by the probe itself.' }
            Should -Invoke Get-RmmNativePowerShellRelaunchPath -Times 0 -Exactly
        }

        It 'Ends with a HEALTH line and exit code 1 when the probe stops on an unexpected error' {
            Mock Invoke-RmmFleetHealthProbe { throw 'boom' }

            $result = Invoke-RmmFleetHealthMain -Relaunched

            $result.ExitCode | Should -Be 1
            $result.Lines[0] | Should -BeExactly 'The probe stopped on an unexpected error: boom'
            $result.Lines[-1] | Should -BeLike 'HEALTH: status=unhealthy problems=probe-error computer=*'
        }
    }
}

Describe 'rmm/Get-WingetFleetHealth.ps1: its readers' {
    BeforeAll {
        . $script:ProbePath
    }

    Context 'Get-RmmAppxPackage' {
        It 'Reads each package and each account''s install state, in either form' {
            Mock Get-AppxPackage { New-TestAppxPackage -Version '1.29.380.0' -InstallLocation 'C:\x' -Users @(@{ Sid = 'S-1-5-21-1'; Account = 'CONTOSO\jdoe'; State = 'Installed' }, 'S-1-5-18 [S-1-5-18]: Staged') }

            $result = Get-RmmAppxPackage -Name 'Microsoft.DesktopAppInstaller'

            $result.Error | Should -BeNullOrEmpty
            $result.Packages[0].Version | Should -Be ([version]'1.29.380.0')
            $result.Packages[0].Users[0].Account | Should -Be 'CONTOSO\jdoe'
            $result.Packages[0].Users[0].InstallState | Should -Be 'Installed'
            $result.Packages[0].Users[1].Sid | Should -Be 'S-1-5-18'
            $result.Packages[0].Users[1].InstallState | Should -Be 'Staged'
            Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $AllUsers -and $Name -eq 'Microsoft.DesktopAppInstaller' }
        }

        It 'Returns the error when the query fails' {
            Mock Get-AppxPackage { throw 'Access is denied.' }

            $result = Get-RmmAppxPackage -Name 'Microsoft.DesktopAppInstaller'

            $result.Error | Should -Be 'Access is denied.'
            $result.Packages | Should -BeNullOrEmpty
        }
    }

    Context 'Get-RmmWauInstall' {
        BeforeEach {
            $script:uninstallRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            $script:settingsKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
            $script:policyKey = 'HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate'
            Mock Test-Path { $false }
            Mock Get-ChildItem { }
            Mock Get-ItemProperty { }
        }

        It 'Finds WAU by its uninstall entry' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:uninstallRoot }
            Mock Get-ChildItem { [pscustomobject]@{ PSPath = 'entry-1' }, [pscustomobject]@{ PSPath = 'entry-2' } } -ParameterFilter { $LiteralPath -eq $script:uninstallRoot }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = '7-Zip' } } -ParameterFilter { $LiteralPath -eq 'entry-1' }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Winget-AutoUpdate'; DisplayVersion = '2.12.0' } } -ParameterFilter { $LiteralPath -eq 'entry-2' }

            $result = Get-RmmWauInstall

            $result.Installed | Should -BeTrue
            $result.Version | Should -Be '2.12.0'
        }

        It 'Reads its settings and Group Policy keys' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:settingsKey -or $LiteralPath -eq $script:policyKey }
            Mock Get-ItemProperty { [pscustomobject]@{ InstallLocation = 'C:\Program Files\Winget-AutoUpdate\'; WAU_UpdatesAtLogon = 1; ProductVersion = '2.12.0' } } -ParameterFilter { $LiteralPath -eq $script:settingsKey }
            Mock Get-ItemProperty { [pscustomobject]@{ WAU_UpdatesAtLogon = 1 } } -ParameterFilter { $LiteralPath -eq $script:policyKey }

            $result = Get-RmmWauInstall

            $result.Installed | Should -BeTrue
            $result.Version | Should -Be '2.12.0'
            $result.InstallLocation | Should -Be 'C:\Program Files\Winget-AutoUpdate\'
            $result.UpdatesAtLogon | Should -Be 1
            $result.PolicyUpdatesAtLogon | Should -Be 1
        }

        It 'Finds no WAU when neither exists' {
            $result = Get-RmmWauInstall

            $result.Installed | Should -BeFalse
            $result.Error | Should -BeNullOrEmpty
        }
    }

    Context 'Get-RmmWauTask' {
        It 'Reads the state, the triggers, the last run and result, and leaves out a never-run time' {
            Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready'; Triggers = @((New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger'), (New-TestTaskTrigger -DaysOfWeek 4 -Enabled $false)) } }
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'1999-11-30'; LastTaskResult = 267011; NextRunTime = $null } }

            $result = Get-RmmWauTask

            $result.Exists | Should -BeTrue
            $result.State | Should -Be 'Ready'
            @($result.Triggers | ForEach-Object { $_.Text }) | Should -Be @('Logon', 'Weekly on Tuesday (disabled)')
            @($result.Triggers | ForEach-Object { $_.IsLogon }) | Should -Be @($true, $false)
            @($result.Triggers | ForEach-Object { $_.Enabled }) | Should -Be @($true, $false)
            $result.LastRunTime | Should -BeNullOrEmpty
            Format-RmmTaskResult -Result $result.LastTaskResult | Should -Be '0x00041303 (has not run yet)'
            Should -Invoke Get-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\WAU\' -and $TaskName -eq 'Winget-AutoUpdate' }
        }
    }

    Context 'Read-RmmWauLogMatch' {
        It 'Reads a <Case> log' -ForEach @(
            @{ Case = 'UTF-16 LE'; Bytes = { param ($text) [System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($text) } }
            @{ Case = 'UTF-16 LE (no byte order mark)'; Bytes = { param ($text) [System.Text.Encoding]::Unicode.GetBytes($text) } }
            @{ Case = 'UTF-8'; Bytes = { param ($text) [System.Text.Encoding]::UTF8.GetBytes($text) } }
        ) {
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
            [System.IO.File]::WriteAllBytes($path, [byte[]](& $Bytes $script:WauLogText))

            $result = Read-RmmWauLogMatch -Path $path -MaximumMatches 20

            $result.Exists | Should -BeTrue
            $result.MatchCount | Should -Be 7
            $result.WingetInstallCount | Should -Be 1
            @($result.Entries[-1]) | Should -Be @("02:02:15 - No update found. 'Winget upgrade' output:", "Program 'winget.exe' failed to run: Access is denied", 'At C:\Program Files\Winget-AutoUpdate\functions\Get-WingetOutdatedApps.ps1:41 char:26')
        }

        It 'Returns no entries for -MaximumMatches 0, and says when there is no log' {
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
            [System.IO.File]::WriteAllText($path, $script:WauLogText)

            (Read-RmmWauLogMatch -Path $path -MaximumMatches 0).Entries | Should -BeNullOrEmpty
            (Read-RmmWauLogMatch -Path (Join-Path $TestDrive 'missing.log')).Exists | Should -BeFalse
        }

        It 'Builds the log path from WAU''s InstallLocation, else Program Files' {
            $location = Join-Path $TestDrive 'Winget-AutoUpdate'

            Get-RmmWauLogPath -InstallLocation $location | Should -Be (Join-Path (Join-Path $location 'logs') 'updates.log')
            $programFiles = $env:ProgramW6432
            try {
                $env:ProgramW6432 = $TestDrive
                Get-RmmWauLogPath -InstallLocation '' | Should -Be (Join-Path (Join-Path (Join-Path $TestDrive 'Winget-AutoUpdate') 'logs') 'updates.log')
            }
            finally {
                $env:ProgramW6432 = $programFiles
            }
        }
    }

    Context 'Invoke-RmmTimedProcess' {
        BeforeAll {
            $script:programs = Join-Path $TestDrive 'programs'
            $null = New-Item -ItemType Directory -Path $script:programs -Force
        }

        It 'Returns the exit code and the output, standard error included' {
            $program = New-FakeExecutable -Directory $script:programs -Name 'prints' -StandardOutput @('v1.29.380') -StandardError @('a warning') -ExitCode 3

            $result = Invoke-RmmTimedProcess -FilePath $program -ArgumentList @('--version') -TimeoutSeconds 30

            $result.ExitCode | Should -Be 3
            $result.TimedOut | Should -BeFalse
            $result.Output | Should -Be @('v1.29.380', 'a warning')
        }

        It 'Stops a program at the time limit' {
            $program = New-FakeExecutable -Directory $script:programs -Name 'hangs' -StandardOutput @('started') -SleepSeconds 60

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-RmmTimedProcess -FilePath $program -TimeoutSeconds 1
            $stopwatch.Stop()

            $result.TimedOut | Should -BeTrue
            $result.ExitCode | Should -BeNullOrEmpty
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 30
        }

        It 'Says why a program could not be started' {
            $result = Invoke-RmmTimedProcess -FilePath (Join-Path $script:programs 'missing.exe') -TimeoutSeconds 5

            $result.LaunchError | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -BeNullOrEmpty
        }
    }
}

Describe 'rmm/Get-WingetFleetHealth.ps1: the same answers as the installer' {
    BeforeAll {
        . $script:ProbePath
    }

    It 'Asks for the Windows App Runtime the installer requires by default' {
        # The probe's constant against the module's built-in requirement, tested by behaviour so it
        # holds however the module spells it.
        $osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        ${function:Get-WindowsAppRuntimePackageInfo}.ToString() | Should -BeLike "*$script:RmmRuntimeName*"

        Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = $script:RmmRuntimeMinimumVersion; Architecture = $osArchitecture } }
        (Get-WindowsAppRuntimeStatus).Present | Should -BeTrue

        $justOlder = [version]::new($script:RmmRuntimeMinimumVersion.Major, $script:RmmRuntimeMinimumVersion.Minor, $script:RmmRuntimeMinimumVersion.Build - 1, 0)
        Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = $justOlder; Architecture = $osArchitecture } }
        (Get-WindowsAppRuntimeStatus).Present | Should -BeFalse
    }

    It 'Picks the winget.exe files in the order the installer''s run as SYSTEM tries them (<OSArchitecture>)' -ForEach @(
        @{ OSArchitecture = 'X64'; ProcessorArchitecture = 'AMD64' }
        @{ OSArchitecture = 'Arm64'; ProcessorArchitecture = 'ARM64' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $packages = @(
            @{ Version = '1.9.25200.0'; Architecture = 'X64'; Status = 'Ok' },
            @{ Version = '1.27.460.0'; Architecture = 'X64'; Status = 'Ok' },
            @{ Version = '1.29.380.0'; Architecture = 'X64'; Status = 'Tampered' },
            @{ Version = '1.28.240.0'; Architecture = 'Arm64'; Status = 'Ok' },
            @{ Version = '1.28.240.0'; Architecture = 'X86'; Status = 'Ok' }
        ) | ForEach-Object {
            $folder = New-TestAppInstallerFolder -Root $root -Name ('Microsoft.DesktopAppInstaller_{0}_{1}__8wekyb3d8bbwe' -f $_.Version, $_.Architecture.ToLowerInvariant())
            [pscustomobject]@{ Version = [version]$_.Version; VersionText = $_.Version; Architecture = $_.Architecture; Status = $_.Status; InstallLocation = $folder }
        }
        Mock Get-DesktopAppInstallerPackageInfo { $packages }
        Mock Write-WarningMessage { }

        $installer = @(Get-MachineWingetCandidate -ProcessorArchitecture $ProcessorArchitecture | ForEach-Object { $_.Path })
        $probe = @(Get-RmmWingetCandidate -AppInstaller ([pscustomobject]@{ Packages = $packages; Error = $null }) -OSArchitecture $OSArchitecture | ForEach-Object { $_.Path })

        $installer.Count | Should -BeGreaterThan 1
        $probe | Should -Be $installer
    }

    It 'Describes a trigger as the installer''s transcript does' {
        $triggers = @(
            (New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 4 -StartBoundary '2026-10-06T02:00:00'),
            (New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger'),
            (New-TestTaskTrigger -ClassName 'MSFT_TaskDailyTrigger' -Enabled $false),
            (New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 65)
        )

        foreach ($trigger in $triggers) {
            Format-RmmTaskTrigger -Trigger $trigger | Should -BeExactly (Format-ScheduledTaskTrigger -Trigger $trigger)
        }
    }
}

Describe 'rmm/Repair-WauLogonTrigger.ps1: the companion fix' {
    BeforeAll {
        . $script:RepairPath
        $script:settingsKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
        $script:policyKey = 'HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate'
    }

    BeforeEach {
        $script:taskTriggers = @((New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger'), (New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 4))
        $script:setting = 1
        $script:policy = $null

        Mock Test-RmmElevated { $true }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Ready'; Triggers = $script:taskTriggers } }
        # -RemoveParameterType: on Windows the real Set-ScheduledTask types -Trigger as CimInstance[],
        # which would reject these fake triggers before the mock body runs.
        Mock Set-ScheduledTask { $script:taskTriggers = @($Trigger) } -RemoveParameterType Trigger
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:settingsKey }
        Mock Test-Path { $null -ne $script:policy } -ParameterFilter { $LiteralPath -eq $script:policyKey }
        Mock Get-ItemProperty { }
        Mock Get-ItemProperty { [pscustomobject]@{ WAU_UpdatesAtLogon = $script:setting } } -ParameterFilter { $LiteralPath -eq $script:settingsKey }
        Mock Get-ItemProperty { [pscustomobject]@{ WAU_UpdatesAtLogon = $script:policy } } -ParameterFilter { $LiteralPath -eq $script:policyKey }
        Mock Set-ItemProperty { $script:setting = $Value }
        Mock Get-RmmNativePowerShellRelaunchPath { $null }
    }

    It 'Removes the at-logon trigger, keeps the schedule, sets WAU_UpdatesAtLogon to 0, and reads both back' {
        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 0
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=fixed problems=none computer=* logontrigger=removed updatesatlogon=set-0 policy=none'
        Should -Invoke Set-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskPath -eq '\WAU\' -and $TaskName -eq 'Winget-AutoUpdate' -and @($Trigger).Count -eq 1 -and @($Trigger)[0].CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger'
        }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $script:settingsKey -and $Name -eq 'WAU_UpdatesAtLogon' -and $Value -eq 0 -and $Value -is [int] }
        Should -Invoke Get-ScheduledTask -Times 2 -Exactly
        $result.Lines | Should -Contain 'Removed the at-logon trigger from the task \WAU\Winget-AutoUpdate; it keeps its other triggers (Weekly).'
    }

    It 'Changes nothing on a second run' {
        Invoke-RmmWauLogonTriggerRepair | Out-Null

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 0
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=unchanged problems=none * logontrigger=absent updatesatlogon=already-0 policy=none'
        Should -Invoke Set-ScheduledTask -Times 1 -Exactly
        Should -Invoke Set-ItemProperty -Times 1 -Exactly
    }

    It 'Chooses the same triggers to keep as the installer''s Disable-WauLogonTrigger' {
        $script:taskTriggers = @((New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger'), (New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger'), (New-TestTaskTrigger -ClassName 'MSFT_TaskDailyTrigger'))
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        $script:kept = @()
        Mock Set-ScheduledTask { $script:kept += , @($Trigger | ForEach-Object { $_.CimClass.CimClassName }) } -RemoveParameterType Trigger

        Disable-WauLogonTrigger | Out-Null
        Invoke-RmmWauLogonTriggerRepair | Out-Null

        $script:kept.Count | Should -Be 2
        $script:kept[1] | Should -Be $script:kept[0]
    }

    It 'Leaves a task alone whose only trigger is the at-logon one, and fails' {
        $script:taskTriggers = @(New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger')

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=failed problems=logon-only-trigger * logontrigger=only-trigger updatesatlogon=set-0 *'
        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
    }

    It 'Changes nothing with -WhatIf and says what it would change' {
        $result = Invoke-RmmWauLogonTriggerRepair -WhatIf

        $result.ExitCode | Should -Be 0
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=whatif problems=none * logontrigger=would-remove updatesatlogon=would-set-0 policy=none'
        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'Changes nothing when the script is run with -WhatIf' {
        # Run with & under the mocks: the script's own scope is what a mock body's $script:
        # variables read then, so these mocks use literals.
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Ready'; Triggers = @((New-TestTaskTrigger -ClassName 'MSFT_TaskLogonTrigger'), (New-TestTaskTrigger)) } }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' }
        Mock Get-ItemProperty { [pscustomobject]@{ WAU_UpdatesAtLogon = 1 } } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' }

        $output = @(& $script:RepairPath -Relaunched -WhatIf)
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $output[-1] | Should -BeLike 'REPAIR: status=whatif problems=none * logontrigger=would-remove updatesatlogon=would-set-0 policy=none'
        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'Fails when the trigger cannot be removed, and still sets WAU_UpdatesAtLogon' {
        Mock Set-ScheduledTask { throw 'Access is denied.' } -RemoveParameterType Trigger

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=failed problems=trigger-not-removed * logontrigger=failed updatesatlogon=set-0 *'
        $result.Lines | Should -Contain 'Could not remove the at-logon trigger from the task \WAU\Winget-AutoUpdate: Access is denied.'
    }

    It 'Fails when the trigger is still there when read back' {
        Mock Set-ScheduledTask { } -RemoveParameterType Trigger

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike '* problems=trigger-not-removed * logontrigger=still-present *'
    }

    It 'Fails when WAU_UpdatesAtLogon cannot be written' {
        Mock Set-ItemProperty { throw 'Requested registry access is not allowed.' }

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike '* problems=setting-not-written * logontrigger=removed updatesatlogon=failed *'
    }

    It 'Does nothing, and succeeds, when WAU is not installed' {
        Mock Get-ScheduledTask {
            Write-Error -Exception ([System.Exception]::new('No MSFT_ScheduledTask objects found.')) -ErrorId 'CmdletizationQuery_NotFound_TaskName' -Category ObjectNotFound
        }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $script:settingsKey }

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 0
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=unchanged problems=none * logontrigger=no-task updatesatlogon=no-key policy=none'
        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'Fails when the task cannot be read' {
        Mock Get-ScheduledTask {
            Write-Error -Exception ([System.UnauthorizedAccessException]::new('Access is denied.')) -ErrorId 'HRESULT 0x80070005,Get-ScheduledTask' -Category PermissionDenied
        }

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike '* problems=task-unknown * logontrigger=unknown *'
        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
    }

    It 'Fails when Group Policy puts the trigger back' {
        $script:policy = 1

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=failed problems=policy-logon * logontrigger=removed updatesatlogon=set-0 policy=1'
    }

    It 'Reads and changes nothing when not elevated' {
        Mock Test-RmmElevated { $false }

        $result = Invoke-RmmWauLogonTriggerRepair

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=failed problems=not-elevated * logontrigger=unknown updatesatlogon=unknown *'
        Should -Invoke Get-ScheduledTask -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'Prints the report, the REPAIR line last, and exits with its exit code when run as a script' {
        Mock Invoke-RmmWauLogonTriggerRepair { [pscustomobject]@{ Lines = @('a step', 'REPAIR: status=failed problems=policy-logon'); Problems = @('policy-logon'); ExitCode = 1 } }

        $output = @(& $script:RepairPath -Relaunched)
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        $output | Should -Be @('a step', 'REPAIR: status=failed problems=policy-logon')
        Should -Invoke Invoke-RmmWauLogonTriggerRepair -Times 1 -Exactly -ParameterFilter { $Note -eq 'Run again in 64-bit Windows PowerShell by the script itself.' }
        Should -Invoke Get-RmmNativePowerShellRelaunchPath -Times 0 -Exactly
    }

    It 'Ends with a REPAIR line and exit code 1 when it stops on an unexpected error' {
        Mock Invoke-RmmWauLogonTriggerRepair { throw 'boom' }

        $result = Invoke-RmmWauRepairMain -Relaunched

        $result.ExitCode | Should -Be 1
        $result.Lines[-1] | Should -BeLike 'REPAIR: status=failed problems=repair-error computer=*'
    }
}
