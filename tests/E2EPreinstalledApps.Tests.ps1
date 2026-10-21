# E2EPreinstalledApps.Tests.ps1
# Tests for e2e/Remove-PreinstalledApps.ps1, which uninstalls the catalog apps the GitHub-hosted
# runner image ships with (Chrome, 7-Zip, Git, and in the Windows PowerShell 5.1 leg PowerShell 7)
# before the first e2e install pass (review finding P3-40). The promises the workflow relies on: an
# app that is not installed is fine, one that cannot be removed is reported as a warning and never
# fails the run, and every winget and msiexec call is bounded.
#
# winget and msiexec are never run: Start-Process is mocked with a small fake machine that knows
# which packages are installed. Only Invoke-BoundedProcess itself is tested against real (pwsh)
# processes.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:RepoRoot 'e2e/Remove-PreinstalledApps.ps1')
    $script:Pwsh = (Get-Process -Id $PID).Path

    # What Start-Process hands back: WaitForExit(ms) reports whether the process ended in time.
    function New-FakeProcess {
        param ([int]$ExitCode, [switch]$Hang)
        $process = [pscustomobject]@{ Handle = [IntPtr]::Zero; ExitCode = $ExitCode; Hang = [bool]$Hang }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return -not ($null -ne $Milliseconds -and $this.Hang) }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:KilledProcesses++ }
        return $process
    }

    # The fake machine behind the Start-Process mock.
    function Invoke-FakeMachine {
        param ([string]$FilePath, [string[]]$ArgumentList)
        $id = $null
        $idIndex = [array]::IndexOf($ArgumentList, '--id')
        if ($idIndex -ge 0) {
            $id = $ArgumentList[$idIndex + 1]
        }
        # winget is the alias, or the path Resolve-PreparationWingetPath gave (wgt-gq8.50).
        if ($FilePath -eq $script:WingetCommand -and $script:SourceBroken) {
            # A winget source that cannot open (0x8A15000F): with --source winget the call fails;
            # without it, winget only warns and finds nothing (0x8A150014).
            if ($ArgumentList -contains '--source') { return (New-FakeProcess -ExitCode -1978335217) }
            return (New-FakeProcess -ExitCode -1978335212)
        }
        if ($FilePath -eq $script:WingetCommand -and $ArgumentList[0] -eq 'list') {
            if ($script:ListHangs) { return (New-FakeProcess -Hang) }
            if ($script:ListFails) { return (New-FakeProcess -ExitCode -1978335217) }
            if ($script:Installed[$id]) { return (New-FakeProcess -ExitCode 0) }
            return (New-FakeProcess -ExitCode -1978335212)
        }
        if ($FilePath -eq $script:WingetCommand -and $ArgumentList[0] -eq 'uninstall') {
            if ($script:RemovableByWinget -contains $id) {
                $script:Installed[$id] = $false
                if ($id -eq 'Microsoft.PowerShell') { Remove-Item -LiteralPath $script:FakePwsh -Force }
                return (New-FakeProcess -ExitCode 0)
            }
            return (New-FakeProcess -ExitCode -1978335184)
        }
        if ($FilePath -eq 'msiexec.exe') {
            if ($script:MsiRemovesPwsh) {
                Remove-Item -LiteralPath $script:FakePwsh -Force
                return (New-FakeProcess -ExitCode 0)
            }
            return (New-FakeProcess -ExitCode 1605)
        }
        throw "unexpected process: $FilePath $($ArgumentList -join ' ')"
    }
}

Describe 'Invoke-BoundedProcess (real processes)' {
    It 'Returns the exit code and output of a process that ends in time' {
        $result = Invoke-BoundedProcess -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'Write-Output from-child; exit 3') -TimeoutSeconds 60

        $result.ExitCode | Should -Be 3
        $result.TimedOut | Should -BeFalse
        $result.Output | Should -Match 'from-child'
        $result.Error | Should -BeNullOrEmpty
    }

    It 'Stops a process that runs past its limit' {
        $result = Invoke-BoundedProcess -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSeconds 2

        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -BeNullOrEmpty
    }

    It 'Reports a program that cannot start instead of throwing' {
        $result = Invoke-BoundedProcess -FilePath (Join-Path $TestDrive 'no-such-program.exe') -ArgumentList @('list') -TimeoutSeconds 5

        $result.ExitCode | Should -BeNullOrEmpty
        $result.Error | Should -Not -BeNullOrEmpty
        (Format-ProcessOutcome -Outcome $result -TimeoutSeconds 5) | Should -Match '^could not start: '
    }
}

Describe 'Removing the preinstalled apps' {
    BeforeEach {
        $script:Installed = @{ 'Google.Chrome' = $true; '7zip.7zip' = $true; 'Git.Git' = $false; 'Microsoft.PowerShell' = $true }
        $script:RemovableByWinget = @('Google.Chrome', '7zip.7zip', 'Git.Git')
        $script:ListFails = $false
        $script:ListHangs = $false
        $script:SourceBroken = $false
        $script:MsiRemovesPwsh = $true
        $script:KilledProcesses = 0
        $script:WingetCommand = 'winget'
        Mock Resolve-PreparationWingetPath { $script:WingetCommand }
        # Set by Invoke-RunnerPreparation; the tests that call the helpers directly start from it.
        $script:PreparationWinget = 'winget'

        # PowerShell 7 lives in a Program Files under TestDrive; the real ones are never looked at.
        $script:SavedProgramFiles = $env:ProgramFiles
        $script:SavedProgramW6432 = $env:ProgramW6432
        $env:ProgramFiles = Join-Path $TestDrive 'Program Files'
        $env:ProgramW6432 = $env:ProgramFiles
        $pwshDirectory = Join-Path $env:ProgramFiles 'PowerShell\7'
        $null = New-Item -ItemType Directory -Path $pwshDirectory -Force
        $script:FakePwsh = Join-Path $pwshDirectory 'pwsh.exe'
        Set-Content -LiteralPath $script:FakePwsh -Value 'fake'

        Mock Start-Process { Invoke-FakeMachine -FilePath $FilePath -ArgumentList $ArgumentList }
        # The Windows Installer entries: PowerShell 7's MSI and an unrelated Inno Setup app.
        Mock Get-ChildItem {
            [pscustomobject]@{ PSPath = 'fake::pwsh'; PSChildName = '{11111111-2222-3333-4444-555555555555}' }
            [pscustomobject]@{ PSPath = 'fake::git'; PSChildName = 'Git_is1' }
        }
        Mock Get-ItemProperty {
            if ($LiteralPath -eq 'fake::pwsh') {
                [pscustomobject]@{ DisplayName = 'PowerShell 7.6.5.0-x64'; WindowsInstaller = 1 }
            }
            else {
                [pscustomobject]@{ DisplayName = 'Git'; WindowsInstaller = 0 }
            }
        }
    }

    AfterEach {
        $env:ProgramFiles = $script:SavedProgramFiles
        $env:ProgramW6432 = $script:SavedProgramW6432
    }

    It 'Runs every winget call through App Installer''s own winget.exe when the account has no alias (wgt-gq8.50)' {
        $script:WingetCommand = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.29.379.0_arm64__8wekyb3d8bbwe\winget.exe'

        $results = Invoke-RunnerPreparation -PackageId @('Google.Chrome.EXE', '7zip.7zip', 'Git.Git') -ListTimeoutSeconds 45 -UninstallTimeoutSeconds 150 6>$null

        @($results | ForEach-Object { $_.Result }) | Should -Be @('removed', 'removed', 'absent')
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'winget' }
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $FilePath -eq $script:WingetCommand -and $ArgumentList[0] -eq 'uninstall' }
    }

    It 'Leaves an app that is not installed alone' {
        $result = Remove-PreinstalledPackage -Id 'Git.Git' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'absent'
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
    }

    It 'Uninstalls an installed app silently and checks that winget no longer finds it' {
        $result = Remove-PreinstalledPackage -Id 'Google.Chrome' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'removed'
        $result.Detail | Should -Be 'winget uninstall exit 0x00000000'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'winget' -and ($ArgumentList -join ' ') -eq 'uninstall --id Google.Chrome --exact --source winget --silent --accept-source-agreements --disable-interactivity'
        }
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and ($ArgumentList -join ' ') -match '--id Google\.Chrome --exact --source winget' }
    }

    It 'Removes the catalog''s Google.Chrome.EXE as the image''s MSI package, Google.Chrome, and says whether winget lists that under the catalog id (<Listed>; wgt-zu3)' -ForEach @(
        @{ Listed = 'listed'; CatalogView = 'winget list found it' }
        @{ Listed = 'not listed'; CatalogView = 'winget list does not find it' }
    ) {
        $script:Installed['Google.Chrome.EXE'] = ($Listed -eq 'listed')

        $result = Remove-PreinstalledPackage -Id 'Google.Chrome.EXE' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.App | Should -Be 'Google.Chrome.EXE'
        $result.Result | Should -Be 'removed'
        $result.Detail | Should -Be "as Google.Chrome (as Google.Chrome.EXE: $CatalogView); winget uninstall exit 0x00000000"
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'winget' -and ($ArgumentList -join ' ') -eq 'uninstall --id Google.Chrome --exact --source winget --silent --accept-source-agreements --disable-interactivity'
        }
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' -and $ArgumentList -contains 'Google.Chrome.EXE' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and $ArgumentList -contains 'Google.Chrome.EXE' }
    }

    It 'Says Google.Chrome.EXE is absent when the image has no Chrome MSI' {
        $script:Installed['Google.Chrome'] = $false

        $result = Remove-PreinstalledPackage -Id 'Google.Chrome.EXE' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'absent'
        $result.Detail | Should -Be 'as Google.Chrome (as Google.Chrome.EXE: winget list does not find it); not installed on this runner'
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
    }

    It 'Reads a winget source that cannot open as unknown, never as not installed (wgt-gq8.65)' {
        # Without --source, winget answered 'not installed' for an installed app and it was left
        # in place as 'absent'.
        $script:SourceBroken = $true

        $result = Remove-PreinstalledPackage -Id 'Google.Chrome' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'unknown'
        $result.Detail | Should -Be 'winget uninstall exit 0x8A15000F; then winget list exit 0x8A15000F'
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and ($ArgumentList -join ' ') -match '--source winget' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' -and ($ArgumentList -join ' ') -match '--source winget' }
    }

    It 'Reports an app the uninstall left installed' {
        $script:RemovableByWinget = @()

        $result = Remove-PreinstalledPackage -Id '7zip.7zip' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'still present'
        $result.Detail | Should -Be 'winget uninstall exit 0x8A150030; winget list found it'
    }

    It 'Still tries the uninstall when winget list fails, and reports the state as unknown' {
        $script:ListFails = $true

        $result = Remove-PreinstalledPackage -Id 'Google.Chrome' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'unknown'
        $result.Detail | Should -Be 'winget uninstall exit 0x00000000; then winget list exit 0x8A15000F'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
    }

    It 'Stops a winget list that hangs' {
        $script:ListHangs = $true

        $result = Remove-PreinstalledPackage -Id 'Google.Chrome' -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'unknown'
        $result.Detail | Should -Match 'winget list timed out after 5 s$'
        $script:KilledProcesses | Should -Be 2
    }

    It 'Removes PowerShell 7 through its MSI entry' {
        $result = Remove-PowerShell7 -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'removed'
        $result.Detail | Should -Be 'msiexec /x {11111111-2222-3333-4444-555555555555} exit 0x00000000'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' -and ($ArgumentList -join ' ') -eq '/x {11111111-2222-3333-4444-555555555555} /qn /norestart' }
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'winget' }
    }

    It 'Falls back to winget when the MSI leaves pwsh.exe behind' {
        $script:MsiRemovesPwsh = $false
        $script:RemovableByWinget = @('Microsoft.PowerShell')

        $result = Remove-PowerShell7 -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5

        $result.Result | Should -Be 'removed'
        $result.Detail | Should -Be 'msiexec /x {11111111-2222-3333-4444-555555555555} exit 0x00000645; winget: removed (winget uninstall exit 0x00000000)'
    }

    It 'Reports PowerShell 7 left in place, and leaves a machine without it alone' {
        $script:MsiRemovesPwsh = $false
        $script:RemovableByWinget = @()

        $left = Remove-PowerShell7 -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5
        $left.Result | Should -Be 'still present'
        $left.Detail | Should -Match ([regex]::Escape("still there: $script:FakePwsh") + '$')

        Remove-Item -LiteralPath $script:FakePwsh -Force
        (Remove-PowerShell7 -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5).Result | Should -Be 'absent'
    }

    It 'Warns, on one line each, about the apps it could not remove, and only those' {
        $script:RemovableByWinget = @('Google.Chrome')
        $script:MsiRemovesPwsh = $false

        $output = @(Invoke-RunnerPreparation -PackageId @('Google.Chrome', '7zip.7zip', 'Git.Git') -IncludePowerShell7 -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5 6>&1)

        $lines = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
        $warnings = @($lines | Where-Object { $_ -like '::warning*' })
        $warnings.Count | Should -Be 2
        $warnings[0] | Should -Match '^::warning title=E2E runner preparation::7zip\.7zip could not be removed \(still present\): '
        $warnings[1] | Should -Match '^::warning title=E2E runner preparation::Microsoft\.PowerShell could not be removed \(still present\): '
        $warnings | ForEach-Object { $_ | Should -Not -Match '[\r\n%]' }
        # Printed as each app finishes, so a step stopped part-way still shows the apps it did.
        [array]::IndexOf($lines, $warnings[0]) | Should -BeLessThan ([array]::IndexOf($lines, 'Removing Git.Git...'))
        $chromeLine = @($lines | Where-Object { $_ -match '^Google\.Chrome\s+removed\s' })[0]
        [array]::IndexOf($lines, $chromeLine) | Should -BeLessThan ([array]::IndexOf($lines, 'Removing 7zip.7zip...'))
        $results = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        @($results | ForEach-Object { "$($_.App)=$($_.Result)" }) | Should -Be @('Google.Chrome=removed', '7zip.7zip=still present', 'Git.Git=absent', 'Microsoft.PowerShell=still present')
    }

    It 'Writes what it removed to -ResultPath, the record the SYSTEM legs read (wgt-gq8.53)' {
        $script:RemovableByWinget = @('Google.Chrome')
        $path = Join-Path $TestDrive ('new-folder-' + [guid]::NewGuid().ToString('N') + '/preinstalled-apps.json')

        $null = Invoke-RunnerPreparation -PackageId @('Google.Chrome', '7zip.7zip', 'Git.Git') -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5 -ResultPath $path 6>$null

        $record = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $record.schemaVersion | Should -Be 1
        $record.complete | Should -BeTrue
        @($record.removed) | Should -Be @('Google.Chrome')
        @($record.absent) | Should -Be @('Git.Git')
        @($record.leftInstalled) | Should -Be @('7zip.7zip')
        @($record.unknown) | Should -BeNullOrEmpty
    }

    It 'Writes the record after each app, so a step stopped part-way leaves what it got through' {
        $script:PartialPath = Join-Path $TestDrive ('partial-' + [guid]::NewGuid().ToString('N') + '.json')
        $path = $script:PartialPath
        $script:Snapshots = @()
        Mock Write-PreparationResult { if (Test-Path -LiteralPath $script:PartialPath) { $script:Snapshots += (Get-Content -Raw -LiteralPath $script:PartialPath | ConvertFrom-Json) } }

        $null = Invoke-RunnerPreparation -PackageId @('Google.Chrome', '7zip.7zip') -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5 -ResultPath $path 6>$null

        # Before the second app's line: the first app's record, not yet complete.
        $script:Snapshots.Count | Should -Be 1
        @($script:Snapshots[0].removed) | Should -Be @('Google.Chrome')
        $script:Snapshots[0].complete | Should -BeFalse
        (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).complete | Should -BeTrue
    }

    It 'Writes no record without -ResultPath' {
        Mock Save-PreparationRecord { }

        $null = Invoke-RunnerPreparation -PackageId @('Google.Chrome') -ListTimeoutSeconds 5 -UninstallTimeoutSeconds 5 6>$null

        Should -Invoke Save-PreparationRecord -Times 0 -Exactly
    }
}

Describe 'Resolve-PreparationWingetPath (wgt-gq8.50)' {
    BeforeEach {
        # Two registered App Installers, each with its own winget.exe, and one without a folder.
        $script:Older = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.28.240.0_arm64__8wekyb3d8bbwe'
        $script:Newer = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.29.379.0_arm64__8wekyb3d8bbwe'
        foreach ($folder in @($script:Older, $script:Newer)) {
            $null = New-Item -ItemType Directory -Path $folder -Force
            Set-Content -LiteralPath (Join-Path $folder 'winget.exe') -Value 'fake'
        }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = '1.9.25200.0'; InstallLocation = '' }
            [pscustomobject]@{ Version = '1.28.240.0'; InstallLocation = $script:Older }
            [pscustomobject]@{ Version = '1.29.379.0'; InstallLocation = $script:Newer }
        }
    }

    It 'Runs the alias when the account has one, and looks no further' {
        Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe' } } -ParameterFilter { $Name -eq 'winget' }

        Resolve-PreparationWingetPath | Should -Be 'winget'
        Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter { $Name -eq 'winget' -and $CommandType -eq 'Application' }
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }

    It 'Otherwise runs the winget.exe of the newest App Installer registered for any user' {
        Resolve-PreparationWingetPath | Should -Be (Join-Path $script:Newer 'winget.exe')
        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $AllUsers -and $Name -eq 'Microsoft.DesktopAppInstaller' }
    }

    It 'Passes over a package without winget.exe' {
        Remove-Item -LiteralPath (Join-Path $script:Newer 'winget.exe')

        Resolve-PreparationWingetPath | Should -Be (Join-Path $script:Older 'winget.exe')
    }

    It 'Falls back to the alias''s name when <Case>, so the calls fail and read as unknown' -ForEach @(
        @{ Case = 'no App Installer is registered'; Throws = $false }
        @{ Case = 'the AppX packages cannot be read'; Throws = $true }
    ) {
        if ($Throws) {
            Mock Get-AppxPackage { throw 'Get-AppxPackage failed.' }
        }
        else {
            Mock Get-AppxPackage { }
        }

        Resolve-PreparationWingetPath | Should -Be 'winget'
    }
}

Describe 'ConvertTo-PreparationRecord' {
    It 'Sorts the results by what is true now, and counts an unexpected result as unknown' {
        $record = ConvertTo-PreparationRecord -Results @(
            [pscustomobject]@{ App = 'Google.Chrome'; Result = 'removed' }
            [pscustomobject]@{ App = 'Git.Git'; Result = 'absent' }
            [pscustomobject]@{ App = '7zip.7zip'; Result = 'still present' }
            [pscustomobject]@{ App = 'Microsoft.PowerShell'; Result = 'unknown' }
            [pscustomobject]@{ App = 'Contoso.Odd'; Result = 'something else' }
        ) -Complete

        $record.complete | Should -BeTrue
        $record.removed | Should -Be @('Google.Chrome')
        $record.absent | Should -Be @('Git.Git')
        $record.leftInstalled | Should -Be @('7zip.7zip')
        $record.unknown | Should -Be @('Microsoft.PowerShell', 'Contoso.Odd')
    }

    It 'Writes empty lists as JSON arrays, and one id as a one-element array' {
        $json = ConvertTo-Json -InputObject (ConvertTo-PreparationRecord -Results @([pscustomobject]@{ App = 'Google.Chrome'; Result = 'removed' })) -Depth 3

        $json | Should -Match '"removed":\s*\[\s*"Google\.Chrome"\s*\]'
        $json | Should -Match '"absent":\s*\[\s*\]'
        $json | Should -Match '"complete":\s*false'
    }
}

Describe 'The time limits of runner preparation' {
    It 'Adds up the worst case of every bounded call' {
        Get-RunnerPreparationWorstCase -PackageCount 3 -ListTimeoutSeconds 45 -UninstallTimeoutSeconds 150 | Should -Be 720
        Get-RunnerPreparationWorstCase -PackageCount 3 -IncludePowerShell7 -ListTimeoutSeconds 45 -UninstallTimeoutSeconds 150 | Should -Be 1110
        # Chrome's extra list under its catalog id (wgt-zu3).
        Get-RunnerPreparationWorstCase -PackageCount 3 -AliasedCount 1 -IncludePowerShell7 -ListTimeoutSeconds 45 -UninstallTimeoutSeconds 150 | Should -Be 1155
    }

    It 'Fits the defaults into the timeout-minutes of every workflow step <Step> (<Count>), with a minute to spare' -ForEach @(
        # The two PowerShell 7 legs and the three SYSTEM legs have a step each with the first name.
        @{ Step = 'Remove the catalog apps the runner image ships with'; IncludePowerShell7 = $false; Count = 5 }
        @{ Step = 'Remove the catalog apps the runner image ships with, and PowerShell 7'; IncludePowerShell7 = $true; Count = 1 }
    ) {
        # Over the limit, the runner stops the step part-way, and a killed winget's uninstaller
        # can still be running when the first pass starts.
        $scriptPath = Join-Path $script:RepoRoot 'e2e/Remove-PreinstalledApps.ps1'
        $defaults = @{}
        foreach ($parameter in [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null).ParamBlock.Parameters) {
            if ($parameter.DefaultValue) {
                $defaults[$parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.SafeGetValue()
            }
        }
        $aliasedCount = @($defaults['PackageId'] | Where-Object { (Get-PreinstalledRemovalId -Id $_) -ne $_ }).Count
        $aliasedCount | Should -Be 1
        $worstCase = Get-RunnerPreparationWorstCase -PackageCount @($defaults['PackageId']).Count -AliasedCount $aliasedCount -IncludePowerShell7:$IncludePowerShell7 -ListTimeoutSeconds $defaults['ListTimeoutSeconds'] -UninstallTimeoutSeconds $defaults['UninstallTimeoutSeconds']

        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
        $stepPattern = '(?ms)^\s+- name: ' + [regex]::Escape($Step) + '\r?\n(?<body>.*?)(?=^\s+- name: |\z)'
        $steps = [regex]::Matches($workflow, $stepPattern)
        $steps.Count | Should -Be $Count
        foreach ($match in $steps) {
            $match.Groups['body'].Value | Should -Match 'Remove-PreinstalledApps\.ps1'
            ($match.Groups['body'].Value -match '-IncludePowerShell7') | Should -Be $IncludePowerShell7
            $limit = [regex]::Match($match.Groups['body'].Value, 'timeout-minutes: (?<minutes>\d+)')
            $limit.Success | Should -BeTrue
            $limitSeconds = 60 * [int]$limit.Groups['minutes'].Value

            $worstCase + 60 | Should -BeLessOrEqual $limitSeconds
        }
    }

    It 'Is run only by the steps whose time limit the test above checks' {
        # A step under another name would escape that check: 5 + 1 steps above.
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
        $calls = [regex]::Matches($workflow, '(?m)^\s+&?\s*\.[\\/]e2e[\\/]Remove-PreinstalledApps\.ps1\b')
        $calls.Count | Should -Be 6
    }
}
