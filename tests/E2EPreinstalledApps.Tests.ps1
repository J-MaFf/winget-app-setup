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
        if ($FilePath -eq 'winget' -and $ArgumentList[0] -eq 'list') {
            if ($script:ListHangs) { return (New-FakeProcess -Hang) }
            if ($script:ListFails) { return (New-FakeProcess -ExitCode -1978335217) }
            if ($script:Installed[$id]) { return (New-FakeProcess -ExitCode 0) }
            return (New-FakeProcess -ExitCode -1978335212)
        }
        if ($FilePath -eq 'winget' -and $ArgumentList[0] -eq 'uninstall') {
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
        $script:MsiRemovesPwsh = $true
        $script:KilledProcesses = 0

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
            $FilePath -eq 'winget' -and ($ArgumentList -join ' ') -eq 'uninstall --id Google.Chrome --exact --silent --accept-source-agreements --disable-interactivity'
        }
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and ($ArgumentList -join ' ') -match '--id Google\.Chrome --exact' }
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
}

Describe 'The time limits of runner preparation' {
    It 'Adds up the worst case of every bounded call' {
        Get-RunnerPreparationWorstCase -PackageCount 3 -ListTimeoutSeconds 45 -UninstallTimeoutSeconds 150 | Should -Be 720
        Get-RunnerPreparationWorstCase -PackageCount 3 -IncludePowerShell7 -ListTimeoutSeconds 45 -UninstallTimeoutSeconds 150 | Should -Be 1110
    }

    It 'Fits the defaults into the timeout-minutes of the workflow step <Step>, with a minute to spare' -ForEach @(
        @{ Step = 'Remove the catalog apps the runner image ships with'; IncludePowerShell7 = $false }
        @{ Step = 'Remove the catalog apps the runner image ships with, and PowerShell 7'; IncludePowerShell7 = $true }
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
        $worstCase = Get-RunnerPreparationWorstCase -PackageCount @($defaults['PackageId']).Count -IncludePowerShell7:$IncludePowerShell7 -ListTimeoutSeconds $defaults['ListTimeoutSeconds'] -UninstallTimeoutSeconds $defaults['UninstallTimeoutSeconds']

        $workflow = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/e2e-install.yml')
        $stepPattern = '(?ms)^\s+- name: ' + [regex]::Escape($Step) + '\r?\n(?<body>.*?)(?=^\s+- name: |\z)'
        $match = [regex]::Match($workflow, $stepPattern)
        $match.Success | Should -BeTrue
        $match.Groups['body'].Value | Should -Match 'Remove-PreinstalledApps\.ps1'
        ($match.Groups['body'].Value -match '-IncludePowerShell7') | Should -Be $IncludePowerShell7
        $limit = [regex]::Match($match.Groups['body'].Value, 'timeout-minutes: (?<minutes>\d+)')
        $limit.Success | Should -BeTrue
        $limitSeconds = 60 * [int]$limit.Groups['minutes'].Value

        $worstCase + 60 | Should -BeLessOrEqual $limitSeconds
    }
}
