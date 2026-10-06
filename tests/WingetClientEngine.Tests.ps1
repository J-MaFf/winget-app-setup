# WingetClientEngine.Tests.ps1
# Tests for WingetAppSetup/Private/WingetClientEngine.ps1 (wgt-gq8.42): the opt-in
# Microsoft.WinGet.Client engine of runs as SYSTEM. The request protocol is read from the sample
# results in tests/fixtures/winget-client, and run end to end against a stand-in
# Microsoft.WinGet.Client 1.29.380 module in TestDrive, by a real child pwsh under the real
# Invoke-ExternalProcess.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/winget-client'

    function Get-ClientFixture {
        param ([Parameter(Mandatory = $true)][string]$Name)
        Get-Content -Raw -LiteralPath (Join-Path $script:FixtureRoot "$Name.json")
    }

    # Invoke-ExternalProcess's result for a child that printed the given result line.
    function New-ClientRun {
        param ([string]$Json, [string[]]$Before = @(), [AllowNull()]$ExitCode = 0, [switch]$TimedOut, [switch]$LaunchFailed, [string[]]$StandardError = @())
        $lines = @($Before)
        if ($Json) {
            $lines += ('WINGET-CLIENT-RESULT ' + ($Json.Trim()))
        }
        $parameters = @{ ExitCode = $ExitCode; Output = $lines; StandardError = $StandardError; TimedOut = $TimedOut; LaunchFailed = $LaunchFailed }
        if ($LaunchFailed) {
            $parameters['LaunchErrorCode'] = 2
            $parameters['LaunchError'] = 'The system cannot find the file specified.'
        }
        New-TestProcessResult @parameters
    }

    # Invoke-WingetClientRequest's result for a fixture.
    function New-ClientRequest {
        param ([string]$Fixture, [string]$Json)
        if ($Fixture) {
            $Json = Get-ClientFixture -Name $Fixture
        }
        $run = New-ClientRun -Json $Json
        $parsed = ConvertFrom-WingetClientResponse -StandardOutput $run.StandardOutput -StandardError $run.StandardError -ExitCode $run.ExitCode
        [pscustomobject]@{ Run = $run; Response = $parsed.Response; ProtocolError = $parsed.ProtocolError }
    }

    function New-TestClientModule {
        param ([string]$Directory = (Join-Path $TestDrive 'wingetclient-0123456789abcdef0123456789abcdef'))
        [pscustomobject]@{
            Ready           = $true
            Reason          = $null
            Version         = '1.29.380'
            Sha256          = 'AB' * 32
            Source          = 'Download'
            Directory       = $Directory
            ManifestPath    = (Join-Path $Directory 'Microsoft.WinGet.Client/Microsoft.WinGet.Client.psd1')
            ChildScriptPath = (Join-Path $Directory 'Invoke-WingetClientRequest.ps1')
            PowerShellPath  = [Environment]::ProcessPath
            Architecture    = 'x64'
        }
    }

    function Set-TestEngineActive {
        param ($Module = (New-TestClientModule))
        $script:WingetClientEngine = [pscustomobject]@{ Module = $Module; EngineVersion = 'v1.29.380'; PowerShellVersion = '7.6.6'; Architecture = 'X64' }
    }
}

AfterAll {
    $script:WingetClientEngine = $null
    $script:InstallEngineRecord = $null
}

Describe 'Get-SystemInstallEngineRequest (WINGET_APP_SETUP_SYSTEM_ENGINE)' {
    BeforeEach {
        $script:savedEngineVariable = $env:WINGET_APP_SETUP_SYSTEM_ENGINE
        Mock Write-WarningMessage { }
    }

    AfterEach {
        $env:WINGET_APP_SETUP_SYSTEM_ENGINE = $script:savedEngineVariable
    }

    It 'Reads <Value> as <Engine> from <Source>' -ForEach @(
        @{ Value = $null; Engine = 'Cli'; Source = 'Default' }
        @{ Value = '   '; Engine = 'Cli'; Source = 'Default' }
        @{ Value = 'WinGetClient'; Engine = 'WinGetClient'; Source = 'Environment' }
        @{ Value = ' wingetclient '; Engine = 'WinGetClient'; Source = 'Environment' }
        @{ Value = 'Cli'; Engine = 'Cli'; Source = 'Environment' }
        @{ Value = 'CLI'; Engine = 'Cli'; Source = 'Environment' }
    ) {
        [Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_SYSTEM_ENGINE', $Value)

        $request = Get-SystemInstallEngineRequest

        $request.Engine | Should -Be $Engine
        $request.Source | Should -Be $Source
        Should -Invoke Write-WarningMessage -Times 0 -Exactly
    }

    It 'Warns about any other value and keeps winget.exe' {
        $env:WINGET_APP_SETUP_SYSTEM_ENGINE = 'Module'

        $request = Get-SystemInstallEngineRequest

        $request.Engine | Should -Be 'Cli'
        $request.RawValue | Should -Be 'Module'
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq "WINGET_APP_SETUP_SYSTEM_ENGINE='Module' is not Cli or WinGetClient; using winget.exe." }
    }
}

Describe 'ConvertFrom-WingetClientResponse' {
    It 'Reads the last result line' {
        $first = '{"protocol":1,"operation":"Version","stage":"call","ok":true,"version":"v1.0.0"}'
        $last = '{"protocol":1,"operation":"Version","stage":"call","ok":true,"version":"v1.29.380"}'

        $parsed = ConvertFrom-WingetClientResponse -StandardOutput @('Microsoft.WinGet.Client Version: v1.29.380', "WINGET-CLIENT-RESULT $first", 'WARNING: something', "WINGET-CLIENT-RESULT $last") -ExitCode 0

        $parsed.ProtocolError | Should -BeNullOrEmpty
        $parsed.Response.version | Should -Be 'v1.29.380'
    }

    It 'Is a protocol error when <Case>' -ForEach @(
        @{ Case = 'there is no result line'; Output = @('Import-Module: Could not load file'); StdErr = @('', 'Import-Module: Could not load file or assembly.'); ExitCode = 1; Expected = 'the WinGet client request ended without a result (exit code 1): Import-Module: Could not load file or assembly.' }
        @{ Case = 'there is no output at all'; Output = @(); StdErr = @(); ExitCode = -1073741515; Expected = 'the WinGet client request ended without a result (exit code -1073741515)' }
        @{ Case = 'the JSON does not parse'; Output = @('WINGET-CLIENT-RESULT {protocol 1}'); StdErr = @(); ExitCode = 0; Expected = "the WinGet client request's result is not valid JSON:*" }
        @{ Case = 'the protocol is not 1'; Output = @('WINGET-CLIENT-RESULT {"protocol":2,"ok":true}'); StdErr = @(); ExitCode = 0; Expected = "the WinGet client request answered in protocol '2', not 1" }
    ) {
        $parsed = ConvertFrom-WingetClientResponse -StandardOutput $Output -StandardError $StdErr -ExitCode $ExitCode

        $parsed.Response | Should -BeNullOrEmpty
        $parsed.ProtocolError | Should -BeLike $Expected
    }
}

Describe 'Get-WingetClientResultCode' {
    It 'Maps <Fixture> to exit code <ExitCode>' -ForEach @(
        @{ Fixture = 'install-ok'; ExitCode = 0; Status = 'Ok'; InstallerErrorCode = 0 }
        @{ Fixture = 'install-ok-3010'; ExitCode = 0; Status = 'Ok'; InstallerErrorCode = 3010 }
        @{ Fixture = 'install-no-applicable-installers'; ExitCode = -1978335216; Status = 'NoApplicableInstallers'; InstallerErrorCode = $null }
        @{ Fixture = 'install-msi-failed'; ExitCode = -1978335159; Status = 'InstallError'; InstallerErrorCode = 1603 }
        @{ Fixture = 'install-no-package-found'; ExitCode = -1978335212; Status = 'NoPackageFoundException'; InstallerErrorCode = $null }
        @{ Fixture = 'install-vague-criteria'; ExitCode = -1978335210; Status = 'VagueCriteriaException'; InstallerErrorCode = $null }
        @{ Fixture = 'installed-catalog-connect'; ExitCode = -1978335217; Status = 'CatalogConnectException'; InstallerErrorCode = $null }
        @{ Fixture = 'version-group-policy'; ExitCode = -1978335174; Status = 'GroupPolicyException'; InstallerErrorCode = $null }
        @{ Fixture = 'installed-none'; ExitCode = 0; Status = $null; InstallerErrorCode = $null }
        @{ Fixture = 'probe-ok'; ExitCode = 0; Status = $null; InstallerErrorCode = $null }
    ) {
        $result = Get-WingetClientResultCode -Request (New-ClientRequest -Fixture $Fixture)

        $result.ExitCode | Should -Be $ExitCode
        $result.Status | Should -Be $Status
        $result.InstallerErrorCode | Should -Be $InstallerErrorCode
        $result.LaunchFailed | Should -BeFalse
        $result.TimedOut | Should -BeFalse
    }

    It 'Reports the installer''s own exit code only when an installer ran: <Status> with <Code> -> <Expected>' -ForEach @(
        @{ Status = 'Ok'; Code = 0; Expected = 0 }
        @{ Status = 'Ok'; Code = 3010; Expected = 3010 }
        @{ Status = 'InstallError'; Code = 1603; Expected = 1603 }
        @{ Status = 'InstallError'; Code = 0; Expected = $null }
        @{ Status = 'NoApplicableInstallers'; Code = 0; Expected = $null }
        @{ Status = 'DownloadError'; Code = 0; Expected = $null }
        @{ Status = 'BlockedByPolicy'; Code = 0; Expected = $null }
    ) {
        $json = '{"protocol":1,"operation":"Install","stage":"call","ok":true,"status":"' + $Status + '","hresult":0,"installerErrorCode":' + $Code + ',"rebootRequired":false,"id":"Contoso.App"}'

        (Get-WingetClientResultCode -Request (New-ClientRequest -Json $json)).InstallerErrorCode | Should -Be $Expected
    }

    It 'Maps a failed Status without an HRESULT: <Status> to <Hex>' -ForEach @(
        @{ Status = 'NoApplicableInstallers'; Hex = '0x8A150010' }
        @{ Status = 'BlockedByPolicy'; Hex = '0x8A15003A' }
        @{ Status = 'PackageAgreementsNotAccepted'; Hex = '0x8A150041' }
        @{ Status = 'NoApplicableUpgrade'; Hex = '0x8A15002B' }
        @{ Status = 'CatalogError'; Hex = '0x8A150045' }
        @{ Status = 'InvalidOptions'; Hex = '0x8A150002' }
        @{ Status = 'ManifestError'; Hex = '0x8A150001' }
        @{ Status = 'InternalError'; Hex = '0x8A150001' }
        @{ Status = 'DownloadError'; Hex = '0x8A150003' }
        @{ Status = 'InstallError'; Hex = '0x8A150003' }
        @{ Status = 'SomethingNew'; Hex = '0x8A150003' }
    ) {
        $json = '{"protocol":1,"operation":"Install","stage":"call","ok":true,"status":"' + $Status + '","hresult":0,"installerErrorCode":0,"rebootRequired":false,"id":"Contoso.App"}'

        $result = Get-WingetClientResultCode -Request (New-ClientRequest -Json $json)

        '0x{0:X8}' -f $result.ExitCode | Should -Be $Hex
        $result.Status | Should -Be $Status
    }

    It 'Maps the exceptions a call can throw: <Names> to <Hex>' -ForEach @(
        @{ Names = 'NoPackageFoundException'; HResults = @(-2146233087); Hex = '0x8A150014' }
        @{ Names = 'VagueCriteriaException'; HResults = @(-2146233088); Hex = '0x8A150016' }
        @{ Names = 'InvalidSourceException'; HResults = @(-2146233088); Hex = '0x8A150012' }
        @{ Names = 'GroupPolicyException'; HResults = @(-2146233088); Hex = '0x8A15003A' }
        @{ Names = 'CatalogConnectException,COMException'; HResults = @(-2146233088, -1978335217); Hex = '0x8A15000F' }
        @{ Names = 'CatalogConnectException'; HResults = @(-2146233088); Hex = '0x8A150045' }
        @{ Names = 'FindPackagesException'; HResults = @(-1978335163); Hex = '0x8A150045' }
        @{ Names = 'FindPackagesException'; HResults = @(-2146233088); Hex = '0x8A150003' }
        @{ Names = 'RuntimeException,COMException'; HResults = @(-2146233087, -1978335230); Hex = '0x8A150002' }
        @{ Names = 'InvalidOperationException'; HResults = @(-2146233079); Hex = '0x80131509' }
        @{ Names = 'NoResult'; HResults = @(0); Hex = '0x8A150001' }
    ) {
        $records = @()
        $names = $Names -split ','
        for ($index = 0; $index -lt $names.Count; $index++) {
            $records += @{ type = "Contoso.$($names[$index])"; name = $names[$index]; hresult = $HResults[$index]; message = 'test' }
        }
        $json = ConvertTo-Json -InputObject @{ protocol = 1; operation = 'Install'; stage = 'call'; ok = $false; exceptions = $records } -Depth 5 -Compress

        $result = Get-WingetClientResultCode -Request (New-ClientRequest -Json $json)

        $result.Failure | Should -Be 'Call'
        '0x{0:X8}' -f $result.ExitCode | Should -Be $Hex
        $result.LaunchFailed | Should -BeFalse
    }

    It 'Treats a module that does not load as an engine that cannot start' {
        $result = Get-WingetClientResultCode -Request (New-ClientRequest -Fixture 'load-failed')

        $result.Failure | Should -Be 'Load'
        $result.LaunchFailed | Should -BeTrue
        $result.LaunchErrorCode | Should -BeNullOrEmpty
        $result.ExitCode | Should -BeNullOrEmpty
        $result.LaunchError | Should -Be "the WinGet client engine could not start: FileLoadException: Could not load file or assembly 'Microsoft.WinGet.Client.Engine'"
    }

    It 'Treats a call that fails because the engine cannot work here as an engine that cannot start' {
        $result = Get-WingetClientResultCode -Request (New-ClientRequest -Fixture 'install-type-initialization')

        $result.Failure | Should -Be 'Load'
        $result.LaunchFailed | Should -BeTrue
        $result.LaunchError | Should -Be "the WinGet client engine could not start: TypeInitializationException: The type initializer for 'Microsoft.WinGet.Client.Engine.Helpers.ManagementDeploymentFactory' threw an exception"
    }

    It 'Treats a request without a result as an engine that cannot start' {
        $run = New-ClientRun -Json $null -ExitCode 1 -StandardError @('boom')
        $request = [pscustomobject]@{ Run = $run; Response = $null; ProtocolError = 'the WinGet client request ended without a result (exit code 1): boom' }

        $result = Get-WingetClientResultCode -Request $request

        $result.Failure | Should -Be 'Protocol'
        $result.LaunchFailed | Should -BeTrue
        $result.LaunchError | Should -Be 'the WinGet client engine could not start: the WinGet client request ended without a result (exit code 1): boom'
    }

    It 'Passes a pwsh that could not start through, transient codes included' {
        $request = [pscustomobject]@{ Run = (New-TestProcessResult -LaunchFailed -LaunchErrorCode 32 -LaunchError 'The process cannot access the file because it is being used by another process.'); Response = $null; ProtocolError = $null }

        $result = Get-WingetClientResultCode -Request $request

        $result.Failure | Should -Be 'Launch'
        $result.LaunchErrorCode | Should -Be 32
        Test-TransientWingetLaunchError -NativeErrorCode $result.LaunchErrorCode -Message $result.LaunchError | Should -BeTrue
    }

    It 'Reports a request that ran out of time' {
        $request = [pscustomobject]@{ Run = (New-TestProcessResult -TimedOut); Response = $null; ProtocolError = $null }

        $result = Get-WingetClientResultCode -Request $request

        $result.Failure | Should -Be 'Timeout'
        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-WingetClientRequest' {
    BeforeEach {
        Set-TestEngineActive
        Mock Invoke-ExternalProcess { New-ClientRun -Json (Get-ClientFixture -Name 'install-ok') }
    }

    AfterEach {
        $script:WingetClientEngine = $null
    }

    It 'Runs the request script in a child pwsh, quietly, with the module''s manifest and version' {
        $request = Invoke-WingetClientRequest -Operation Install -PackageId 'Contoso.App' -InstallerType 'wix' -Mode Silent -Log 'X:\logs\l.log' -TimeoutSeconds 1800

        $request.Response.status | Should -Be 'Ok'
        $module = $script:WingetClientEngine.Module
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $module.PowerShellPath -and $TimeoutSeconds -eq 1800 -and $Echo -eq 'None' -and
            ($ArgumentList -join '|') -eq ('-NoProfile|-NonInteractive|-ExecutionPolicy|Bypass|-File|{0}|-ModuleManifest|{1}|-ExpectedVersion|1.29.380|-Operation|Install|-PackageId|Contoso.App|-Mode|Silent|-InstallerType|wix|-Log|X:\logs\l.log' -f $module.ChildScriptPath, $module.ManifestPath)
        }
    }

    It 'Passes no empty argument' {
        [void](Invoke-WingetClientRequest -Operation Version -TimeoutSeconds 60)

        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { @($ArgumentList | Where-Object { [string]::IsNullOrEmpty($_) }).Count -eq 0 -and $ArgumentList[-1] -eq 'Version' }
    }

    It 'Refuses to run without a ready module' {
        $script:WingetClientEngine = $null

        { Invoke-WingetClientRequest -Operation Version -TimeoutSeconds 60 } | Should -Throw '*not ready*'
    }
}

Describe 'Invoke-WingetClientInstall' {
    BeforeEach {
        Set-TestEngineActive
        $script:savedInstallLogPath = $script:InstallLogPath
        $script:logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:InstallLogPath = Join-Path $script:logs 'install-20261006-010203.log'
        $script:hostLines = @()
        Mock Write-Host { $script:hostLines += [string]$Object }
        $script:fixture = 'install-ok'
        Mock Invoke-ExternalProcess { New-ClientRun -Json (Get-ClientFixture -Name $script:fixture) -Before @('Microsoft.WinGet.Client Install Contoso.App: Ok') }
    }

    AfterEach {
        $script:InstallLogPath = $script:savedInstallLogPath
        $script:WingetClientEngine = $null
    }

    It 'Installs for the whole PC, from the winget source, by exact id, silently, with its installer log next to the transcript' {
        $result = Invoke-WingetClientInstall -PackageId 'Contoso.App' -Scope machine -InstallerType 'wix' -Silent -TimeoutSeconds 1800

        $result.ExitCode | Should -Be 0
        $result.Engine | Should -Be 'WinGetClient'
        $result.WingetClientStatus | Should -Be 'Ok'
        $result.InstallerErrorCode | Should -Be 0
        $result.LogPath | Should -Match ('^{0}[\\/]winget-install-Contoso\.App-\d{{8}}-\d{{6}}\.log$' -f [regex]::Escape($script:logs))
        $result.Output | Should -Be @('Microsoft.WinGet.Client Install Contoso.App: Ok')
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $joined = $ArgumentList -join ' '
            $joined -match '-Operation Install -PackageId Contoso\.App -Mode Silent -InstallerType wix -Log \S+winget-install-Contoso\.App-\d{8}-\d{6}\.log$' -and $TimeoutSeconds -eq 1800
        }
        $script:hostLines[0] | Should -Be ('  > Install-WinGetPackage -Id Contoso.App -Source winget -MatchOption Equals -Scope System -Mode Silent -InstallerType wix -Log {0}' -f $result.LogPath)
        $script:hostLines | Should -Contain '    WinGet client result: Ok, 0x00000000, installer exit code 0 (0 s)'
    }

    It 'Uses -Mode Default without -Silent, and no -Log without a logs folder' {
        $script:InstallLogPath = $null

        $result = Invoke-WingetClientInstall -PackageId 'Contoso.App' -Scope machine -TimeoutSeconds 1800

        $result.LogPath | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '-Mode Default$' }
        $script:hostLines[0] | Should -Be '  > Install-WinGetPackage -Id Contoso.App -Source winget -MatchOption Equals -Scope System -Mode Default'
    }

    It 'Refuses any scope but the whole PC: <Scope>' -ForEach @(@{ Scope = 'user' }, @{ Scope = 'default' }, @{ Scope = 'any' }) {
        { Invoke-WingetClientInstall -PackageId 'Contoso.App' -Scope $Scope -TimeoutSeconds 1800 } | Should -Throw -ExceptionType ([System.ArgumentException])

        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
    }

    It 'Returns the winget code of a package with no machine-scope installer, and says so' {
        $script:fixture = 'install-no-applicable-installers'

        $result = Invoke-WingetClientInstall -PackageId 'Spotify.Spotify' -Scope machine -Silent -TimeoutSeconds 1800

        $result.ExitCode | Should -Be -1978335216
        $result.WingetClientStatus | Should -Be 'NoApplicableInstallers'
        $result.InstallerErrorCode | Should -BeNullOrEmpty
        $script:hostLines | Should -Contain '    WinGet client result: NoApplicableInstallers, 0x8A150010 NO_APPLICABLE_INSTALLER, no installer exit code (0 s)'
    }

    It 'Keeps the installer''s own exit code' {
        $script:fixture = 'install-ok-3010'

        $result = Invoke-WingetClientInstall -PackageId 'Contoso.MsiApp' -Scope machine -Silent -TimeoutSeconds 1800

        $result.ExitCode | Should -Be 0
        $result.InstallerErrorCode | Should -Be 3010
    }

    It 'Reports an engine that cannot start as a launch failure with no Win32 code' {
        $script:fixture = 'load-failed'

        $result = Invoke-WingetClientInstall -PackageId 'Contoso.App' -Scope machine -Silent -TimeoutSeconds 1800

        $result.LaunchFailed | Should -BeTrue
        $result.LaunchErrorCode | Should -BeNullOrEmpty
        $result.ExitCode | Should -BeNullOrEmpty
        $result.LaunchError | Should -BeLike 'the WinGet client engine could not start: FileLoadException:*'
    }

    It 'Reports a request that ran out of time' {
        Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }

        $result = Invoke-WingetClientInstall -PackageId 'Contoso.App' -Scope machine -Silent -TimeoutSeconds 1800

        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -BeNullOrEmpty
        $script:hostLines | Should -Contain '    WinGet client result: no answer within 1800 s; the request and its installer were stopped'
    }
}

Describe 'Invoke-WingetClientInstalledCheck' {
    BeforeEach {
        Set-TestEngineActive
        $script:fixture = 'installed-listed'
        Mock Invoke-ExternalProcess { New-ClientRun -Json (Get-ClientFixture -Name $script:fixture) }
    }

    AfterEach {
        $script:WingetClientEngine = $null
    }

    It 'Answers installed, as winget list would, when the id is listed (ignoring case)' {
        $result = Invoke-WingetClientInstalledCheck -PackageId '7ZIP.7zip' -TimeoutSeconds 15

        $result.Installed | Should -BeTrue
        $result.ExitCode | Should -Be 0
        $result.CheckFailed | Should -BeFalse
    }

    It 'Answers not installed with 0x8A150014 when nothing is listed, or another id' {
        $script:fixture = 'installed-none'
        $none = Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip' -TimeoutSeconds 15
        $script:fixture = 'installed-listed'
        $other = Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip.Beta' -TimeoutSeconds 15

        foreach ($result in $none, $other) {
            $result.Installed | Should -BeFalse
            $result.CheckFailed | Should -BeFalse
            $result.ExitCode | Should -Be -1978335212
        }
    }

    It 'Is a failed check, with the mapped code, when Get-WinGetPackage throws' {
        $script:fixture = 'installed-catalog-connect'

        $result = Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip' -TimeoutSeconds 15

        $result.Installed | Should -BeFalse
        $result.CheckFailed | Should -BeTrue
        $result.ExitCode | Should -Be -1978335217
    }

    It 'Is no answer when the engine cannot start, or the check ran out of time' {
        $script:fixture = 'load-failed'
        $launch = Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip' -TimeoutSeconds 15
        Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }
        $timeout = Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip' -TimeoutSeconds 15

        $launch.LaunchFailed | Should -BeTrue
        $launch.LaunchError | Should -BeLike 'the WinGet client engine could not start:*'
        $launch.ExitCode | Should -BeNullOrEmpty
        $timeout.TimedOut | Should -BeTrue
        $timeout.ExitCode | Should -BeNullOrEmpty
    }

    It 'Has the keys Test-WingetPackageInstalled returns' {
        @((Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip' -TimeoutSeconds 15).Keys | Sort-Object) | Should -Be @('CheckFailed', 'ExitCode', 'Installed', 'LaunchError', 'LaunchFailed', 'TimedOut')
    }

    It 'Gives each check at least 45 seconds, which a pwsh start and a module load need: <Caller> -> <Expected>' -ForEach @(
        @{ Caller = 15; Expected = 45 }
        @{ Caller = 90; Expected = 90 }
    ) {
        [void](Invoke-WingetClientInstalledCheck -PackageId '7zip.7zip' -TimeoutSeconds $Caller)

        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq $Expected -and ($ArgumentList -join ' ') -match '-Operation Installed -PackageId 7zip\.7zip$' }
    }
}

Describe 'Test-WingetClientEngineLaunchable' {
    BeforeEach {
        Set-TestEngineActive
        Mock Start-Sleep { }
        Mock Write-WarningMessage { }
        $script:runs = @()
        $script:runIndex = 0
        Mock Invoke-ExternalProcess {
            $run = $script:runs[$script:runIndex]
            $script:runIndex++
            $run
        }
        $script:versionJson = '{"protocol":1,"operation":"Version","stage":"call","ok":true,"version":"v1.29.380"}'
    }

    AfterEach {
        $script:WingetClientEngine = $null
    }

    It 'Is launchable when Get-WinGetVersion answers, within the WingetClientVersion limit' {
        $script:runs = @(New-ClientRun -Json $script:versionJson)

        $result = Test-WingetClientEngineLaunchable -Attempts 6 -RetryDelaySeconds 15

        $result.Launchable | Should -BeTrue
        $result.Version | Should -Be 'v1.29.380'
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 60 -and $ArgumentList[-1] -eq 'Version' }
    }

    It 'Checks again after <Case>' -ForEach @(
        @{ Case = 'a timeout'; First = 'timeout' }
        @{ Case = 'a missing result line'; First = 'protocol' }
        @{ Case = 'a transient pwsh launch failure'; First = 'transient' }
    ) {
        $firstRun = switch ($First) {
            'timeout' { New-TestProcessResult -TimedOut }
            'protocol' { New-ClientRun -Json $null -ExitCode 1 }
            'transient' { New-TestProcessResult -LaunchFailed -LaunchErrorCode 32 -LaunchError 'The process cannot access the file because it is being used by another process.' }
        }
        $script:runs = @($firstRun, (New-ClientRun -Json $script:versionJson))

        $result = Test-WingetClientEngineLaunchable -Attempts 6 -RetryDelaySeconds 15

        $result.Launchable | Should -BeTrue
        $result.Attempts | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
    }

    It 'Gives up at once when <Case>' -ForEach @(
        @{ Case = 'the module does not load'; Fixture = 'load-failed'; Reason = 'the WinGet client engine could not start: FileLoadException:*' }
        @{ Case = 'Group Policy turns the engine off'; Fixture = 'version-group-policy'; Reason = 'Get-WinGetVersion failed with 0x8A15003A BLOCKED_BY_POLICY*' }
    ) {
        $script:runs = @((New-ClientRun -Json (Get-ClientFixture -Name $Fixture)), (New-ClientRun -Json $script:versionJson))

        $result = Test-WingetClientEngineLaunchable -Attempts 6 -RetryDelaySeconds 15

        $result.Launchable | Should -BeFalse
        $result.Reason | Should -BeLike $Reason
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Gives up after its attempts, saying why' {
        $script:runs = @((New-TestProcessResult -TimedOut), (New-TestProcessResult -TimedOut), (New-TestProcessResult -TimedOut))

        $result = Test-WingetClientEngineLaunchable -Attempts 3 -RetryDelaySeconds 15

        $result.Launchable | Should -BeFalse
        $result.Attempts | Should -Be 3
        $result.Reason | Should -Be 'Get-WinGetVersion did not answer within 60 seconds and was stopped'
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }
}

Describe 'Initialize-WingetClientEngine' {
    BeforeEach {
        $script:WingetClientEngine = $null
        $script:InstallEngineRecord = $null
        $script:moduleDirectory = Join-Path $TestDrive ('wingetclient-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:moduleDirectory -Force)
        Mock Initialize-WingetClientModule { New-TestClientModule -Directory $script:moduleDirectory }
        $script:probe = 'probe-ok'
        Mock Invoke-ExternalProcess { New-ClientRun -Json (Get-ClientFixture -Name $script:probe) }
        $script:lines = @()
        Mock Write-WarningMessage { $script:lines += $Message }
    }

    AfterEach {
        $script:WingetClientEngine = $null
        $script:InstallEngineRecord = $null
    }

    It 'Is ready when the probe answers, and records the module for the run' {
        $result = Initialize-WingetClientEngine

        $result.Ready | Should -BeTrue
        $result.EngineVersion | Should -Be 'v1.29.380'
        Test-WingetClientEngineActive | Should -BeTrue
        $script:WingetClientEngine.PowerShellVersion | Should -Be '7.6.6'
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 180 -and ($ArgumentList -join ' ') -match '-Operation Probe$' }
        $record = Get-InstallEngineRecord
        $record.requested | Should -Be 'WinGetClient'
        $record.used | Should -Be 'WinGetClient'
        $record.module.version | Should -Be '1.29.380'
        $record.module.sha256 | Should -Be ('AB' * 32)
        $record.module.engineVersion | Should -Be 'v1.29.380'
        $record.fallbackReason | Should -BeNullOrEmpty
    }

    It 'Accepts a probe that found no Microsoft.PowerShell' {
        $script:probe = $null
        Mock Invoke-ExternalProcess { New-ClientRun -Json '{"protocol":1,"operation":"Probe","stage":"call","ok":true,"version":"v1.29.380","packages":[],"installedChecked":true}' }

        (Initialize-WingetClientEngine).Ready | Should -BeTrue
    }

    It 'Is not ready when the probe fails, removes the module''s folder, and records why' {
        $script:probe = 'installed-catalog-connect'

        $result = Initialize-WingetClientEngine

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be 'the module''s probe failed: CatalogConnectException: An error occurred while connecting to the catalog (0x8A15000F SOURCE_DATA_MISSING)'
        Test-WingetClientEngineActive | Should -BeFalse
        Test-Path -LiteralPath $script:moduleDirectory | Should -BeFalse
        $script:lines | Should -Contain "WinGet client module: NOT READY - $($result.Reason)."
        $record = Get-InstallEngineRecord
        $record.used | Should -Be 'Cli'
        $record.module | Should -BeNullOrEmpty
        $record.fallbackReason | Should -Be $result.Reason
    }

    It 'Is not ready, without a probe, when the module is not' {
        Mock Initialize-WingetClientModule { [pscustomobject]@{ Ready = $false; Reason = 'its SHA256 pin is not set in this build' } }

        $result = Initialize-WingetClientEngine

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be 'the module is not ready: its SHA256 pin is not set in this build'
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        (Get-InstallEngineRecord).fallbackReason | Should -Be $result.Reason
    }
}

Describe 'Remove-WingetClientEngine' {
    It 'Removes the module''s folder and ends the engine''s use, keeping the run''s record; a second call does nothing' {
        $directory = Join-Path $TestDrive ('wingetclient-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $directory 'Microsoft.WinGet.Client') -Force)
        Set-TestEngineActive -Module (New-TestClientModule -Directory $directory)
        $script:InstallEngineRecord = New-InstallEngineRecord -Requested WinGetClient -Used WinGetClient -Module $script:WingetClientEngine.Module -EngineVersion 'v1.29.380'

        Remove-WingetClientEngine
        Remove-WingetClientEngine

        Test-Path -LiteralPath $directory | Should -BeFalse
        Test-WingetClientEngineActive | Should -BeFalse
        (Get-InstallEngineRecord).used | Should -Be 'WinGetClient'
        $script:InstallEngineRecord = $null
    }
}

Describe 'The install engine line and record' {
    AfterEach {
        $script:WingetClientEngine = $null
        $script:InstallEngineRecord = $null
        $script:MachineWingetPath = $null
    }

    It 'Names <Case>' -ForEach @(
        @{ Case = 'the module'; Active = $true; Requested = 'WinGetClient'; Expected = 'Install engine: Microsoft.WinGet.Client 1.29.380 (WinGet engine v1.29.380, PowerShell 7.6.6 x64; engine log folder *WinGet*defaultState).' }
        @{ Case = 'winget.exe'; Active = $false; Requested = 'Cli'; Expected = 'Install engine: winget.exe (X:\WindowsApps\winget.exe).' }
        @{ Case = 'winget.exe instead of the requested module'; Active = $false; Requested = 'WinGetClient'; Expected = 'Install engine: winget.exe (X:\WindowsApps\winget.exe), not the requested Microsoft.WinGet.Client: the module is not ready: blocked.' }
    ) {
        Mock Write-Info { $script:engineLine = $Message }
        $script:MachineWingetPath = 'X:\WindowsApps\winget.exe'
        if ($Active) {
            Set-TestEngineActive
        }
        $script:InstallEngineRecord = New-InstallEngineRecord -Requested $Requested -FallbackReason $(if (-not $Active -and $Requested -eq 'WinGetClient') { 'the module is not ready: blocked' } else { $null })

        Write-InstallEngineLine

        $script:engineLine | Should -BeLike $Expected
    }

    It 'Records winget.exe for a run that set nothing' {
        $script:InstallEngineRecord = $null

        $record = Get-InstallEngineRecord

        @($record.Keys) | Should -Be @('requested', 'used', 'module', 'fallbackReason')
        $record.requested | Should -Be 'Cli'
        $record.used | Should -Be 'Cli'
        $record.module | Should -BeNullOrEmpty
    }

    It 'Names the SystemTemp folder first when there is one, then the temp folder' {
        $savedSystemRoot = $env:SystemRoot
        $savedTmp = $env:TMP
        try {
            $env:SystemRoot = Join-Path $TestDrive 'Windows'
            [void](New-Item -ItemType Directory -Path (Join-Path $env:SystemRoot 'SystemTemp') -Force)
            $env:TMP = Join-Path $TestDrive 'Temp'

            Get-WingetEngineLogDirectory | Should -Be @(($env:SystemRoot + '\SystemTemp\WinGet\defaultState'), ($env:TMP + '\WinGet\defaultState'))
        }
        finally {
            $env:SystemRoot = $savedSystemRoot
            $env:TMP = $savedTmp
        }
    }
}

# The protocol end to end: a real child pwsh runs the request script against a stand-in
# Microsoft.WinGet.Client 1.29.380 whose behaviour FAKE_WINGET_CLIENT_MODE picks, through the real
# Invoke-ExternalProcess.
Describe 'Microsoft.WinGet.Client requests in a child pwsh' {
    BeforeAll {
        $script:fakeRoot = Join-Path $TestDrive 'wingetclient-fake'
        $moduleDirectory = Join-Path $script:fakeRoot 'Microsoft.WinGet.Client'
        [void](New-Item -ItemType Directory -Path $moduleDirectory -Force)
        Set-Content -LiteralPath (Join-Path $moduleDirectory 'Microsoft.WinGet.Client.psd1') -Value @"
@{
    RootModule        = 'Microsoft.WinGet.Client.psm1'
    ModuleVersion     = '1.29.380'
    GUID              = 'e11157e2-cd24-4250-83b8-c6654ea4926a'
    FunctionsToExport = @('Install-WinGetPackage', 'Get-WinGetPackage', 'Get-WinGetVersion')
}
"@
        Set-Content -LiteralPath (Join-Path $moduleDirectory 'Microsoft.WinGet.Client.psm1') -Value @'
Add-Type -TypeDefinition @"
namespace Microsoft.WinGet.Client.Engine.Exceptions {
    public class NoPackageFoundException : System.Exception {
        public NoPackageFoundException() : base("No packages matched the given input criteria.") { HResult = unchecked((int)0x80131501); }
    }
    public class CatalogConnectException : System.Exception {
        public CatalogConnectException(System.Exception inner) : base("An error occurred while connecting to the catalog.", inner) { HResult = unchecked((int)0x80131500); }
    }
}
"@
function New-FakeResult {
    param ($Status, $HResult, $InstallerErrorCode)
    $extended = $null
    if ($HResult -ne 0) {
        $extended = [System.Runtime.InteropServices.COMException]::new('fake', $HResult)
    }
    [pscustomobject]@{ Id = $script:id; Status = $Status; ExtendedErrorCode = $extended; InstallerErrorCode = [uint32]$InstallerErrorCode; RebootRequired = $false }
}
function Get-WinGetVersion { 'v1.29.380' }
function Get-WinGetPackage {
    param ([string]$Id, [string]$MatchOption, [string]$Source)
    if ($env:FAKE_WINGET_CLIENT_MODE -eq 'catalog') {
        throw [Microsoft.WinGet.Client.Engine.Exceptions.CatalogConnectException]::new([System.Runtime.InteropServices.COMException]::new('source', -1978335217))
    }
    if ($Id -eq 'Microsoft.PowerShell' -and $MatchOption -eq 'Equals' -and $Source -eq 'winget') {
        [pscustomobject]@{ Id = $Id; InstalledVersion = '7.6.6.0'; Source = 'winget' }
    }
}
function Install-WinGetPackage {
    param ([string]$Id, [string]$Source, [string]$MatchOption, [string]$Scope, [string]$Mode, [string]$InstallerType, [string]$Log)
    $script:id = $Id
    Write-Output ('called with {0} {1} {2} {3} {4} {5}' -f $Source, $MatchOption, $Scope, $Mode, $InstallerType, $Log) | Out-Host
    switch ($env:FAKE_WINGET_CLIENT_MODE) {
        'ok' { New-FakeResult -Status 'Ok' -HResult 0 -InstallerErrorCode 0 }
        'restart' { New-FakeResult -Status 'Ok' -HResult 0 -InstallerErrorCode 3010 }
        'noinstaller' { New-FakeResult -Status 'NoApplicableInstallers' -HResult -1978335216 -InstallerErrorCode 0 }
        'nopackage' { throw [Microsoft.WinGet.Client.Engine.Exceptions.NoPackageFoundException]::new() }
        'sleep' {
            $child = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -PassThru -NoNewWindow
            Set-Content -LiteralPath $env:FAKE_WINGET_CLIENT_PID_FILE -Value $child.Id
            Start-Sleep -Seconds 120
        }
    }
}
'@
        $script:childScriptPath = Join-Path $script:fakeRoot 'Invoke-WingetClientRequest.ps1'
        [System.IO.File]::WriteAllText($script:childScriptPath, (Get-WingetClientChildScript))
        $script:fakeModule = [pscustomobject]@{
            Ready           = $true
            Version         = '1.29.380'
            Sha256          = 'AB' * 32
            Directory       = $script:fakeRoot
            ManifestPath    = (Join-Path $moduleDirectory 'Microsoft.WinGet.Client.psd1')
            ChildScriptPath = $script:childScriptPath
            PowerShellPath  = [Environment]::ProcessPath
            Architecture    = 'x64'
        }
    }

    BeforeEach {
        $script:savedMode = $env:FAKE_WINGET_CLIENT_MODE
        Mock Write-Host { }
    }

    AfterEach {
        $env:FAKE_WINGET_CLIENT_MODE = $script:savedMode
        $script:WingetClientEngine = $null
    }

    It 'Installs: <Mode> -> <Status>, exit code <ExitCode>, installer code <InstallerCode>' -ForEach @(
        @{ Mode = 'ok'; Status = 'Ok'; ExitCode = 0; InstallerCode = 0 }
        @{ Mode = 'restart'; Status = 'Ok'; ExitCode = 0; InstallerCode = 3010 }
        @{ Mode = 'noinstaller'; Status = 'NoApplicableInstallers'; ExitCode = -1978335216; InstallerCode = $null }
        @{ Mode = 'nopackage'; Status = 'NoPackageFoundException'; ExitCode = -1978335212; InstallerCode = $null }
    ) {
        $env:FAKE_WINGET_CLIENT_MODE = $Mode

        $request = Invoke-WingetClientRequest -Module $script:fakeModule -Operation Install -PackageId 'Contoso.App' -InstallerType 'wix' -Log (Join-Path $TestDrive 'install.log') -TimeoutSeconds 120
        $result = Get-WingetClientResultCode -Request $request

        $request.ProtocolError | Should -BeNullOrEmpty
        $result.Status | Should -Be $Status
        $result.ExitCode | Should -Be $ExitCode
        $result.InstallerErrorCode | Should -Be $InstallerCode
        $request.Response.moduleVersion | Should -Be '1.29.380'
        if ($Mode -ne 'nopackage') {
            $request.Run.StandardOutput | Should -Contain ('called with winget Equals System Silent wix {0}' -f (Join-Path $TestDrive 'install.log'))
        }
        $request.Run.StandardOutput | Should -Contain "Microsoft.WinGet.Client Install Contoso.App: $Status"
    }

    It 'Reads a catalog that cannot be opened as its inner HRESULT' {
        $env:FAKE_WINGET_CLIENT_MODE = 'catalog'

        $result = Get-WingetClientResultCode -Request (Invoke-WingetClientRequest -Module $script:fakeModule -Operation Installed -PackageId 'Microsoft.PowerShell' -TimeoutSeconds 120)

        $result.Failure | Should -Be 'Call'
        $result.ExitCode | Should -Be -1978335217
    }

    It 'Probes: the version, and the installed check for Microsoft.PowerShell by exact id from the winget source' {
        $env:FAKE_WINGET_CLIENT_MODE = 'ok'

        $request = Invoke-WingetClientRequest -Module $script:fakeModule -Operation Probe -TimeoutSeconds 120

        $request.Response.version | Should -Be 'v1.29.380'
        $request.Response.installedChecked | Should -BeTrue
        @($request.Response.packages | ForEach-Object { $_.id }) | Should -Be @('Microsoft.PowerShell')
    }

    It 'Refuses a module of another version, as an engine that cannot start' {
        $other = $script:fakeModule.PSObject.Copy()
        $other.Version = '1.30.50'

        $request = Invoke-WingetClientRequest -Module $other -Operation Version -TimeoutSeconds 120
        $result = Get-WingetClientResultCode -Request $request

        $request.Run.ExitCode | Should -Be 3
        $request.Response.stage | Should -Be 'load'
        $result.LaunchFailed | Should -BeTrue
        $result.LaunchError | Should -Be 'the WinGet client engine could not start: InvalidOperationException: Microsoft.WinGet.Client 1.29.380 was loaded, not 1.30.50'
    }

    It 'Stops an install that outlives its time limit, with the processes it started' {
        $env:FAKE_WINGET_CLIENT_MODE = 'sleep'
        $pidFile = Join-Path $TestDrive 'grandchild.pid'
        $env:FAKE_WINGET_CLIENT_PID_FILE = $pidFile
        try {
            $request = Invoke-WingetClientRequest -Module $script:fakeModule -Operation Install -PackageId 'Contoso.App' -TimeoutSeconds 8
        }
        finally {
            Remove-Item Env:FAKE_WINGET_CLIENT_PID_FILE -ErrorAction SilentlyContinue
        }
        $result = Get-WingetClientResultCode -Request $request

        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -BeNullOrEmpty
        $grandchild = [int](Get-Content -LiteralPath $pidFile)
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((Get-Process -Id $grandchild -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        Get-Process -Id $grandchild -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
