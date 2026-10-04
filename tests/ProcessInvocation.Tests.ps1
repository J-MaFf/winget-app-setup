# Tests for WingetAppSetup/Private/ProcessInvocation.ps1 (review findings P2-5, P2-6, P3-6): the one
# helper every winget and msiexec call goes through. Invoke-ExternalProcess is exercised against real
# programs written into TestDrive (New-FakeExecutable, and pwsh itself for the process-tree cases), so
# the time limit, the kill and the output capture really run, on Linux as on Windows.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:PwshPath = (Get-Process -Id $PID).Path
    $script:OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

    # A pwsh script the tests run as a program: pwsh -NoProfile -NonInteractive -File <script> <args>.
    function New-PwshScript {
        param ([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Body)
        $path = Join-Path $TestDrive "$Name.ps1"
        Set-Content -LiteralPath $path -Value $Body -Encoding utf8
        return $path
    }

    # True while the process runs. A killed child that nobody reaped shows as a zombie (state Z) on
    # Linux, which Get-Process still lists.
    function Test-ProcessRunning {
        param ([Parameter(Mandatory = $true)][int]$Id)
        if (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue)) {
            return $false
        }
        $statPath = "/proc/$Id/stat"
        if (Test-Path -LiteralPath $statPath) {
            $state = ((Get-Content -LiteralPath $statPath -Raw) -replace '^\d+ \(.*\) ', '').Substring(0, 1)
            return $state -ne 'Z'
        }
        return $true
    }

    function Wait-ForFile {
        param ([Parameter(Mandatory = $true)][string]$Path, [int]$Seconds = 20)
        $deadline = (Get-Date).AddSeconds($Seconds)
        while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        return (Test-Path -LiteralPath $Path)
    }
}

Describe 'Get-ProcessTimeoutSeconds' {
    It 'Gives every operation a positive limit' {
        foreach ($operation in 'WingetInstall', 'WingetDownload', 'WingetListCheck', 'WingetList', 'WingetSourceList', 'WingetSearch', 'WingetSourceReset', 'MsiExec', 'WebDownload', 'WebDownloadStall') {
            Get-ProcessTimeoutSeconds -Operation $operation | Should -BeGreaterThan 0 -Because $operation
        }
    }

    It 'Is generous for installs and downloads, and a few minutes at most for queries' {
        Get-ProcessTimeoutSeconds -Operation WingetInstall | Should -BeGreaterOrEqual 1200
        Get-ProcessTimeoutSeconds -Operation WingetDownload | Should -BeGreaterOrEqual 1200
        foreach ($operation in 'WingetList', 'WingetSourceList', 'WingetSearch', 'WingetSourceReset') {
            Get-ProcessTimeoutSeconds -Operation $operation | Should -BeLessOrEqual 300 -Because $operation
        }
    }

    It 'Keeps the 15-second limit the per-app list checks always had' {
        Get-ProcessTimeoutSeconds -Operation WingetListCheck | Should -Be 15
    }
}

Describe 'Get-WebDownloadTimeoutParameters' {
    It 'Always bounds the request with -TimeoutSec' {
        (Get-WebDownloadTimeoutParameters).TimeoutSec | Should -Be (Get-ProcessTimeoutSeconds -Operation WebDownload)
    }

    It 'Adds a stall limit where Invoke-WebRequest has -OperationTimeoutSeconds (PowerShell 7.4 and newer)' {
        $parameters = Get-WebDownloadTimeoutParameters
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $parameters.OperationTimeoutSeconds | Should -Be (Get-ProcessTimeoutSeconds -Operation WebDownloadStall)
        }
        else {
            $parameters.ContainsKey('OperationTimeoutSeconds') | Should -Be $false
        }
    }
}

Describe 'ConvertTo-ProcessArgumentString' {
    It 'Joins plain arguments with spaces' {
        ConvertTo-ProcessArgumentString -ArgumentList @('install', '--id', 'Google.Chrome', '--scope', 'machine') |
            Should -Be 'install --id Google.Chrome --scope machine'
    }

    It 'Quotes empty arguments and arguments with white space or quotes' {
        ConvertTo-ProcessArgumentString -ArgumentList @('a b', '', 'say "hi"') | Should -Be '"a b" "" "say \"hi\""'
    }

    It 'Doubles backslashes only before a quote' {
        ConvertTo-ProcessArgumentString -ArgumentList @('C:\dir with space\', 'C:\plain\path') | Should -Be '"C:\dir with space\\" C:\plain\path'
    }

    It 'Round-trips through a real program''s argument parsing' {
        $echoArgs = New-PwshScript -Name 'echo-args' -Body '$args | ForEach-Object { "[$_]" }'
        $arguments = @('plain', 'two words', 'quote"inside', 'trailing\', 'C:\dir with space\')

        $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $echoArgs) + $arguments) -TimeoutSeconds 60 -Echo None

        $result.ExitCode | Should -Be 0
        $result.StandardOutput | Should -Be @($arguments | ForEach-Object { "[$_]" })
    }
}

Describe 'Get-NativeErrorCode' {
    It 'Finds the Win32Exception inside the exception PowerShell wraps a failed launch in' {
        $inner = [System.ComponentModel.Win32Exception]::new(1920)
        $outer = [System.Management.Automation.MethodInvocationException]::new('Exception calling "Start"', $inner)

        Get-NativeErrorCode -Exception $outer | Should -Be 1920
    }

    It 'Returns $null when there is no Win32 error in the chain' {
        Get-NativeErrorCode -Exception ([System.InvalidOperationException]::new('nope')) | Should -Be $null
        Get-NativeErrorCode -Exception $null | Should -Be $null
    }
}

Describe 'Output filtering (ConvertTo-PlainProcessLine, Get-ProcessOutputLineKind, Write-ProcessOutput)' {
    BeforeAll {
        $script:Block = [string][char]0x2588
        $script:Shade = [string][char]0x2592
    }

    It 'Removes color and window-title control sequences and trailing blanks' {
        $escape = [char]27
        ConvertTo-PlainProcessLine -Line "$escape[32mSuccessfully installed$escape[0m   " | Should -Be 'Successfully installed'
        ConvertTo-PlainProcessLine -Line "$escape]0;winget$([char]7)Found Google Chrome" | Should -Be 'Found Google Chrome'
        ConvertTo-PlainProcessLine -Line $null | Should -Be ''
    }

    It 'Classifies <Line> as <Kind>' -ForEach @(
        @{ Line = ''; Kind = 'Blank' }
        @{ Line = '   '; Kind = 'Blank' }
        @{ Line = '   -'; Kind = 'Spinner' }
        @{ Line = '   \'; Kind = 'Spinner' }
        @{ Line = '   |'; Kind = 'Spinner' }
        @{ Line = '   /'; Kind = 'Spinner' }
        @{ Line = '   - Waiting for another install/uninstall to complete...'; Kind = 'Status' }
        @{ Line = '   | Waiting for another install/uninstall to complete...'; Kind = 'Status' }
        @{ Line = '  45%'; Kind = 'Progress' }
        @{ Line = '  1.50 MB / 3.00 MB'; Kind = 'Progress' }
        @{ Line = '  12.3 MB'; Kind = 'Progress' }
        @{ Line = '   512 KB'; Kind = 'Progress' }
        @{ Line = 'Found Google Chrome [Google.Chrome] Version 1.0'; Kind = 'Text' }
        @{ Line = 'Downloading https://example.com/setup-1.2.msi'; Kind = 'Text' }
        @{ Line = 'Installer failed with exit code: 1603'; Kind = 'Text' }
    ) {
        Get-ProcessOutputLineKind -Line $Line | Should -Be $Kind
    }

    It 'Classifies a progress bar as progress' {
        Get-ProcessOutputLineKind -Line ('  ' + ($script:Block * 10) + ($script:Shade * 20) + '  1.00 MB / 3.00 MB') | Should -Be 'Progress'
    }

    It 'Writes text lines indented, drops spinner and blank lines, and keeps only the last of a run of progress updates' {
        $script:written = @()
        Mock Write-Host { $script:written += [string]$Object }
        $firstBar = '  ' + ($script:Block * 2) + ($script:Shade * 2) + '  1.00 MB / 3.00 MB'
        $lastBar = '  ' + ($script:Block * 4) + '  3.00 MB / 3.00 MB'

        Write-ProcessOutput -Line @('Found Test App [Test.App]', '   -', '   \', '', $firstBar, $lastBar, 'Successfully verified installer hash', '  45%')

        $script:written | Should -Be @('    Found Test App [Test.App]', "    $lastBar", '    Successfully verified installer hash', '      45%')
    }

    It 'Writes only the last lines with -Tail' {
        $script:written = @()
        Mock Write-Host { $script:written += [string]$Object }

        Write-ProcessOutput -Line @('one', 'two', '   -', 'three') -Tail 2

        $script:written | Should -Be @('    two', '    three')
    }

    It 'Writes a status message winget redraws next to its spinner once, not once per redraw' {
        # winget redraws the spinner and its message every 250 ms while another install holds its
        # lock, which used to put four lines a second into the transcript for the whole wait.
        $script:written = @()
        Mock Write-Host { $script:written += [string]$Object }
        $waiting = 'Waiting for another install/uninstall to complete...'
        $redraws = foreach ($index in 0..39) { '   ' + @('-', '\', '|', '/')[$index % 4] + ' ' + $waiting }

        Write-ProcessOutput -Line (@('Found Test App [Test.App]') + @($redraws) + @('', '  12.3 MB', 'Successfully installed'))

        $script:written | Should -Be @('    Found Test App [Test.App]', "       - $waiting", '      12.3 MB', '    Successfully installed')
    }

    It 'Writes a status message again after other text, and each different message once' {
        $script:written = @()
        Mock Write-Host { $script:written += [string]$Object }

        Write-ProcessOutput -Line @('   - First wait', '   \ First wait', '   | Second wait', '   / Second wait', 'Text between', '   - Second wait')

        $script:written | Should -Be @('       - First wait', '       | Second wait', '    Text between', '       - Second wait')
    }
}

Describe 'Select-ProcessOutputLine' {
    It 'Holds a progress update back until the next line it shows, or until -Flush' {
        $state = @{}

        @(Select-ProcessOutputLine -State $state -Line '  1.00 MB / 3.00 MB').Count | Should -Be 0
        @(Select-ProcessOutputLine -State $state -Line '  3.00 MB / 3.00 MB').Count | Should -Be 0
        @(Select-ProcessOutputLine -State $state -Line 'Successfully verified installer hash') | Should -Be @('  3.00 MB / 3.00 MB', 'Successfully verified installer hash')
        @(Select-ProcessOutputLine -State $state -Line '  50%').Count | Should -Be 0
        @(Select-ProcessOutputLine -State $state -Flush) | Should -Be @('  50%')
        @(Select-ProcessOutputLine -State $state -Flush).Count | Should -Be 0
    }

    It 'Drops spinner and blank lines' {
        $state = @{}

        @(Select-ProcessOutputLine -State $state -Line '   -').Count | Should -Be 0
        @(Select-ProcessOutputLine -State $state -Line '').Count | Should -Be 0
        @(Select-ProcessOutputLine -State $state -Flush).Count | Should -Be 0
    }
}

Describe 'Invoke-ExternalProcess (real processes)' {
    AfterEach {
        if ($script:orphanPidFile -and (Test-Path -LiteralPath $script:orphanPidFile)) {
            $orphanPid = [int](Get-Content -LiteralPath $script:orphanPidFile -Raw)
            Stop-Process -Id $orphanPid -Force -ErrorAction SilentlyContinue
        }
        $script:orphanPidFile = $null
    }

    It 'Returns the exit code, standard output and standard error, without throwing' {
        $fake = New-FakeExecutable -Directory $TestDrive -Name 'fake-fail' -StandardOutput 'Found Test App [Test.App] Version 1.0', 'Starting package install...' -StandardError 'Installer failed with exit code: 1603' -ExitCode 3

        $result = Invoke-ExternalProcess -FilePath $fake -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 60 -Echo None

        $result.ExitCode | Should -Be 3
        $result.TimedOut | Should -Be $false
        $result.LaunchFailed | Should -Be $false
        $result.StandardOutput | Should -Be @('Found Test App [Test.App] Version 1.0', 'Starting package install...')
        $result.StandardError | Should -Be @('Installer failed with exit code: 1603')
        $result.Output | Should -Contain 'Installer failed with exit code: 1603'
        $result.Output.Count | Should -Be 3
        $result.Arguments | Should -Be 'install --id Test.App'
    }

    It 'Writes the command line and the program''s output into the transcript (review finding P2-6)' {
        $fake = New-FakeExecutable -Directory $TestDrive -Name 'fake-echo' -StandardOutput 'Found Test App [Test.App] Version 1.0' -StandardError 'Installer failed with exit code: 1603' -ExitCode 1
        $transcript = Join-Path $TestDrive 'live-transcript.log'

        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $result = Invoke-ExternalProcess -FilePath $fake -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 60
        }
        finally {
            Stop-Transcript | Out-Null
        }

        $result.ExitCode | Should -Be 1
        $logged = Get-Content -LiteralPath $transcript -Raw
        $logged | Should -Match ([regex]::Escape('install --id Test.App'))
        $logged | Should -Match ([regex]::Escape('    Found Test App [Test.App] Version 1.0'))
        $logged | Should -Match ([regex]::Escape('    Installer failed with exit code: 1603'))
    }

    It 'Writes nothing with -Echo None' {
        $fake = New-FakeExecutable -Directory $TestDrive -Name 'fake-quiet' -StandardOutput 'QUIET-MARKER-LINE'
        $transcript = Join-Path $TestDrive 'quiet-transcript.log'

        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $result = Invoke-ExternalProcess -FilePath $fake -TimeoutSeconds 60 -Echo None
        }
        finally {
            Stop-Transcript | Out-Null
        }

        $result.StandardOutput | Should -Be @('QUIET-MARKER-LINE')
        (Get-Content -LiteralPath $transcript -Raw) | Should -Not -Match 'QUIET-MARKER-LINE'
    }

    It 'Leaves $LASTEXITCODE alone: the exit code comes from the process object' {
        $fake = New-FakeExecutable -Directory $TestDrive -Name 'fake-exit' -ExitCode 4
        $global:LASTEXITCODE = 12345

        $result = Invoke-ExternalProcess -FilePath $fake -TimeoutSeconds 60 -Echo None

        $result.ExitCode | Should -Be 4
        $global:LASTEXITCODE | Should -Be 12345
    }

    It 'Stops a process that runs past its time limit and reports TimedOut (review finding P2-5)' {
        $fake = New-FakeExecutable -Directory $TestDrive -Name 'fake-hang' -StandardOutput 'started' -SleepSeconds 60
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-ExternalProcess -FilePath $fake -TimeoutSeconds 3 -Echo None

        $stopwatch.Stop()
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
        $result.LaunchFailed | Should -Be $false
        $result.StandardOutput | Should -Contain 'started'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'Stops a process at its time limit even while it writes faster than its output is read' {
        # A writer that never pauses kept every ReadLineAsync completed at once, so the read loop
        # never got back to its time-limit check. This one stops by itself after 30 seconds, so
        # without the fix the test fails instead of hanging.
        $flood = New-PwshScript -Name 'flood' -Body @'
$chunk = "flood line`n" * 2000
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
while ($stopwatch.Elapsed.TotalSeconds -lt 30) { [Console]::Out.Write($chunk) }
'@
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $flood) -TimeoutSeconds 3 -Echo None

        $stopwatch.Stop()
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
        $result.StandardOutput | Should -Contain 'flood line'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It 'Writes the message winget shows next to its spinner into the transcript once, however often it is redrawn' {
        # winget's wait for another install: '\r   - Waiting for another install/uninstall to
        # complete...' every 250 ms, each redraw a line of its own once the output is redirected.
        $spinner = New-PwshScript -Name 'spinner-wait' -Body @'
[Console]::Out.Write("Found Test App [Test.App] Version 1.0`n")
$characters = '-', '\', '|', '/'
for ($index = 0; $index -lt 12; $index++) {
    [Console]::Out.Write("`r   " + $characters[$index % 4] + " Waiting for another install/uninstall to complete...")
    [Console]::Out.Flush()
    Start-Sleep -Milliseconds 50
}
[Console]::Out.Write("`r" + (' ' * 60) + "`rSuccessfully installed`n")
'@
        $transcript = Join-Path $TestDrive 'spinner-transcript.log'

        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $spinner) -TimeoutSeconds 60
        }
        finally {
            Stop-Transcript | Out-Null
        }

        $result.ExitCode | Should -Be 0
        @($result.Output | Where-Object { $_ -match 'Waiting for another install' }).Count | Should -Be 12
        $logged = Get-Content -LiteralPath $transcript -Raw
        [regex]::Matches($logged, 'Waiting for another install/uninstall to complete').Count | Should -Be 1
        $logged | Should -Match ([regex]::Escape('    Found Test App [Test.App] Version 1.0'))
        $logged | Should -Match ([regex]::Escape('    Successfully installed'))
    }

    It 'Stops every process the timed-out process started, not just the process itself' {
        $pidFile = Join-Path $TestDrive 'grandchild.pid'
        $script:orphanPidFile = $pidFile
        $parent = New-PwshScript -Name 'tree-parent' -Body @"
`$child = Start-Process -FilePath '$($script:PwshPath)' -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120' -PassThru -NoNewWindow
Set-Content -LiteralPath '$pidFile' -Value `$child.Id
'parent started its child'
Start-Sleep -Seconds 120
"@

        $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $parent) -TimeoutSeconds 15 -Echo None

        $result.TimedOut | Should -Be $true
        (Wait-ForFile -Path $pidFile -Seconds 1) | Should -Be $true -Because 'the parent must have started its child before the time limit'
        $grandchildPid = [int](Get-Content -LiteralPath $pidFile -Raw)
        $deadline = (Get-Date).AddSeconds(10)
        while ((Test-ProcessRunning -Id $grandchildPid) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        Test-ProcessRunning -Id $grandchildPid | Should -Be $false
    }

    It 'Returns soon after the process exits even when a child it left running keeps the output pipe open' {
        $pidFile = Join-Path $TestDrive 'orphan.pid'
        $script:orphanPidFile = $pidFile
        $parent = New-PwshScript -Name 'orphan-parent' -Body @"
`$child = Start-Process -FilePath '$($script:PwshPath)' -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120' -PassThru -NoNewWindow
Set-Content -LiteralPath '$pidFile' -Value `$child.Id
'parent done'
exit 0
"@
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $parent) -TimeoutSeconds 100 -Echo None

        $stopwatch.Stop()
        $result.TimedOut | Should -Be $false
        $result.ExitCode | Should -Be 0
        $result.StandardOutput | Should -Contain 'parent done'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 60
    }

    It 'Closes standard input, so a program that reads it cannot wait for a key press' {
        $reader = New-PwshScript -Name 'stdin-reader' -Body '$null = [Console]::In.ReadToEnd(); "read to the end"'

        $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $reader) -TimeoutSeconds 60 -Echo None

        $result.TimedOut | Should -Be $false
        $result.StandardOutput | Should -Contain 'read to the end'
    }

    It 'Passes -ArgumentString unchanged' {
        $echoArgs = New-PwshScript -Name 'echo-args-raw' -Body '$args | ForEach-Object { "[$_]" }'

        $result = Invoke-ExternalProcess -FilePath $script:PwshPath -ArgumentString ('-NoProfile -NonInteractive -File "{0}" /i "two words" PROP=1' -f $echoArgs) -TimeoutSeconds 60 -Echo None

        $result.StandardOutput | Should -Be @('[/i]', '[two words]', '[PROP=1]')
    }

    It 'Reports a program that does not exist as a launch failure with its Win32 code, without throwing (review finding P3-6)' {
        $result = Invoke-ExternalProcess -FilePath (Join-Path $TestDrive 'no-such-program.exe') -TimeoutSeconds 60 -Echo None

        $result.LaunchFailed | Should -Be $true
        $result.LaunchErrorCode | Should -Be 2
        $result.LaunchException | Should -BeOfType [System.ComponentModel.Win32Exception]
        $result.LaunchError | Should -Not -BeNullOrEmpty
        $result.ExitCode | Should -Be $null
        $result.TimedOut | Should -Be $false
    }

    It 'Looks a bare program name up on PATH only, and reports a missing one as not found' {
        $result = Invoke-ExternalProcess -FilePath 'no-such-program-on-path-7f3a' -TimeoutSeconds 60 -Echo None

        $result.LaunchFailed | Should -Be $true
        $result.LaunchErrorCode | Should -Be 2
        $result.LaunchError | Should -Match 'was not found on PATH'
    }

    It 'Runs a program found on PATH by its bare name' {
        if ($script:OnWindows) {
            $result = Invoke-ExternalProcess -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo found-on-path') -TimeoutSeconds 60 -Echo None
        }
        else {
            $result = Invoke-ExternalProcess -FilePath 'sh' -ArgumentList @('-c', 'echo found-on-path') -TimeoutSeconds 60 -Echo None
        }

        $result.ExitCode | Should -Be 0
        $result.StandardOutput | Should -Contain 'found-on-path'
    }
}

Describe 'Invoke-WingetProcess' {
    BeforeEach {
        Mock Resolve-WingetExecutable { 'winget' }
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
        $script:savedInstallLogPath = $script:InstallLogPath
        $script:InstallLogPath = $null
    }
    AfterEach {
        $script:InstallLogPath = $script:savedInstallLogPath
    }

    It 'Resolves winget once and passes the arguments, time limit and echo mode through' {
        $result = Invoke-WingetProcess -ArgumentList @('list', '--id', 'Test.App') -TimeoutSeconds 42 -Echo None

        $result.ExitCode | Should -Be 0
        Should -Invoke Resolve-WingetExecutable -Times 1 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'winget' -and ($ArgumentList -join ' ') -eq 'list --id Test.App' -and $TimeoutSeconds -eq 42 -and $Echo -eq 'None'
        }
    }

    It 'Runs the winget the caller already resolved' {
        [void](Invoke-WingetProcess -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 5 -WingetPath 'C:\pf\winget.exe' -LogDirectory '')

        Should -Invoke Resolve-WingetExecutable -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\pf\winget.exe' }
    }

    It 'Gives an install its installer log in the run''s logs folder, creating the folder first (review finding P2-6)' {
        $logs = Join-Path $TestDrive 'logs-install'
        $script:InstallLogPath = Join-Path $logs 'install-20261004-101500.log'

        $result = Invoke-WingetProcess -ArgumentList @('install', '-e', '--id', 'Google.Chrome') -TimeoutSeconds 5

        Test-Path -LiteralPath $logs | Should -Be $true
        $result.LogPath | Should -BeLike (Join-Path $logs 'winget-install-Google.Chrome-*.log')
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $index = [array]::IndexOf($ArgumentList, '--log')
            $index -ge 0 -and $ArgumentList[$index + 1] -like (Join-Path $logs 'winget-install-Google.Chrome-*.log')
        }
    }

    It 'Uses -LogDirectory over the transcript folder' {
        $logs = Join-Path $TestDrive 'logs-explicit'

        $result = Invoke-WingetProcess -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 5 -LogDirectory $logs

        $result.LogPath | Should -BeLike (Join-Path $logs 'winget-install-Test.App-*.log')
    }

    It 'Never overwrites an earlier installer log' {
        $logs = Join-Path $TestDrive 'logs-unique'
        [void](New-Item -ItemType Directory -Path $logs)
        Mock Get-Date { '20261004-101500' } -ParameterFilter { $Format -eq 'yyyyMMdd-HHmmss' }
        Set-Content -LiteralPath (Join-Path $logs 'winget-install-Test.App-20261004-101500.log') -Value 'first attempt'

        $result = Invoke-WingetProcess -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 5 -LogDirectory $logs

        $result.LogPath | Should -Be (Join-Path $logs 'winget-install-Test.App-20261004-101500-2.log')
    }

    It 'Passes no --log to <Subcommand>, which runs no installer' -ForEach @(
        @{ Subcommand = 'list' }
        @{ Subcommand = 'download' }
        @{ Subcommand = 'source' }
        @{ Subcommand = 'search' }
    ) {
        $result = Invoke-WingetProcess -ArgumentList @($Subcommand, '--id', 'Test.App') -TimeoutSeconds 5 -LogDirectory (Join-Path $TestDrive 'logs-none')

        $result.LogPath | Should -Be $null
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--log' }
    }

    It 'Passes no --log when there is no logs folder' {
        $result = Invoke-WingetProcess -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 5

        $result.LogPath | Should -Be $null
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--log' }
    }

    It 'Keeps a --log the caller passed' {
        [void](Invoke-WingetProcess -ArgumentList @('install', '--id', 'Test.App', '--log', 'C:\mine.log') -TimeoutSeconds 5 -LogDirectory (Join-Path $TestDrive 'logs-keep'))

        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { @($ArgumentList | Where-Object { $_ -eq '--log' }).Count -eq 1 -and $ArgumentList -contains 'C:\mine.log' }
    }

    It 'Installs without an installer log rather than not at all when the logs folder cannot be created' {
        Mock New-Item { throw 'Access to the path is denied.' }

        $result = Invoke-WingetProcess -ArgumentList @('install', '--id', 'Test.App') -TimeoutSeconds 5 -LogDirectory (Join-Path $TestDrive 'logs-denied')

        $result.LogPath | Should -Be $null
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--log' }
    }
}
