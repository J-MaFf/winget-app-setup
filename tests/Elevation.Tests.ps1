# Elevation.Tests.ps1
# Tests for WingetAppSetup/Public/Elevation.ps1 and Private/Elevation.ps1:
# Restart-WithElevation and its parts (the elevated relaunch, review findings P2-11, P2-12, P3-11),
# the uninstaller's use of it, the module-context invocation detection, Test-IsSystemAccount and
# Get-InstallAccountContext.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-IsAdmin' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'Returns $true when the current principal is in the Administrator role' {
        Mock Get-CurrentWindowsPrincipal {
            [PSCustomObject]@{ } | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($role) $true } -PassThru
        }

        Test-IsAdmin | Should -Be $true
    }

    It 'Returns $false when the current principal is not in the Administrator role' {
        Mock Get-CurrentWindowsPrincipal {
            [PSCustomObject]@{ } | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($role) $false } -PassThru
        }

        Test-IsAdmin | Should -Be $false
    }

    It 'Fails safe: returns $true and warns instead of propagating when the identity check throws (issue: consolidate-admin-check-helper)' {
        # This is the behavior PowerShell7Bootstrap.ps1 already had before consolidation and the
        # other two call sites (Install.ps1, winget-app-uninstall.ps1) lacked; Test-IsAdmin now
        # applies it everywhere. Mocking Get-CurrentWindowsPrincipal (rather than the static
        # WindowsIdentity/WindowsPrincipal .NET calls, which Pester cannot mock directly) simulates
        # the underlying check throwing.
        Mock Get-CurrentWindowsPrincipal { throw 'simulated identity check failure' }
        Mock Write-WarningMessage { }

        Test-IsAdmin | Should -Be $true
        Should -Invoke Write-WarningMessage -Times 1
    }
}

Describe 'Restart-WithElevation (review findings P2-11, P2-12, P3-11)' {
    BeforeAll {
        # A stand-in for the Process that Start-ElevatedProcess returns: WaitForExit(ms) reports
        # 'still running' -PendingWaits times first, so the wait loop is exercised.
        function New-FakeElevatedProcess {
            param ([int]$ExitCode, [int]$PendingWaits = 0)
            $process = [pscustomobject]@{ ExitCode = $ExitCode; PendingWaits = $PendingWaits; WaitCalls = 0 }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param ($Milliseconds)
                $this.WaitCalls++
                return ($this.WaitCalls -gt $this.PendingWaits)
            }
            $process
        }
    }

    BeforeEach {
        Mock Write-Host { }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        # Someone is at the console unless a test says otherwise; never the runner's real console.
        Mock Test-EffectiveNonInteractive { [bool]$NonInteractive }

        $script:scriptPath = Join-Path $TestDrive 'winget-app-install.ps1'
        Set-Content -LiteralPath $script:scriptPath -Value "Write-Output 'installer'" -Encoding UTF8
        $script:scriptSha256 = (Get-FileHash -LiteralPath $script:scriptPath -Algorithm SHA256).Hash

        $script:launch = $null
        $script:fakeProcess = New-FakeElevatedProcess -ExitCode 0
        Mock Start-ElevatedProcess {
            $script:launch = @{ FilePath = $FilePath; ArgumentString = $ArgumentString }
            $script:fakeProcess
        }
    }

    It 'Starts System32''s Windows PowerShell elevated, never wt.exe or a per-user pwsh.exe alias' {
        $result = Restart-WithElevation -ScriptPath $script:scriptPath

        $result.Started | Should -BeTrue
        Should -Invoke Start-ElevatedProcess -Times 1 -Exactly
        $script:launch.FilePath | Should -Be (Get-WindowsPowerShellPath)
        $script:launch.FilePath | Should -Match '\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $script:launch.ArgumentString | Should -Not -Match 'wt\.exe|pwsh'
    }

    It 'Waits for the elevated run and returns its exit code <_>' -ForEach @(0, 1, 2, 3010) {
        $script:fakeProcess = New-FakeElevatedProcess -ExitCode $_ -PendingWaits 2

        $result = Restart-WithElevation -ScriptPath $script:scriptPath

        $result.Started | Should -BeTrue
        $result.ExitCode | Should -Be $_
        # It kept waiting while the elevated run was still going.
        $script:fakeProcess.WaitCalls | Should -Be 3
        $script:infoMessages | Should -Contain "The elevated run ended with exit code $_."
    }

    It 'Returns 4 after a declined UAC prompt (Win32 error 1223, ERROR_CANCELLED), with one prompt and no retry' {
        # What Process.Start throws through PowerShell: the Win32Exception wrapped in a
        # MethodInvocationException. The code is read, not the (translated) message.
        Mock Start-ElevatedProcess {
            throw [System.Management.Automation.MethodInvocationException]::new('Exception calling "Start" with "1" argument(s): "Translated text"', [System.ComponentModel.Win32Exception]::new(1223))
        }

        $result = Restart-WithElevation -ScriptPath $script:scriptPath

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 4
        Should -Invoke Start-ElevatedProcess -Times 1 -Exactly
        $script:errorMessages | Should -Contain 'The administrator (UAC) prompt was declined, so no elevated run was started. Run it again and approve the prompt, or start it from an elevated session.'
    }

    It 'Returns 4 and says why when the elevated process cannot be started for another reason' {
        Mock Start-ElevatedProcess { throw [System.ComponentModel.Win32Exception]::new(2) }

        $result = Restart-WithElevation -ScriptPath $script:scriptPath

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 4
        Should -Invoke Start-ElevatedProcess -Times 1 -Exactly
        ($script:errorMessages -join "`n") | Should -Match 'Could not start an elevated Windows PowerShell'
    }

    It 'Shows no UAC prompt and returns 4 when nobody is at the console (<Case>)' -ForEach @(
        @{ Case = 'non-interactive session'; Detected = $true; Switch = $false }
        @{ Case = '-NonInteractive'; Detected = $false; Switch = $true }
    ) {
        $script:detected = $Detected
        Mock Test-EffectiveNonInteractive { $script:detected -or [bool]$NonInteractive }

        $result = Restart-WithElevation -ScriptPath $script:scriptPath -NonInteractive:$Switch

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 4
        Should -Invoke Start-ElevatedProcess -Times 0 -Exactly
        ($script:errorMessages -join "`n") | Should -Match 'non-interactive, so there is nobody to approve a UAC prompt'
    }

    It 'Stages the bytes it checked in this account''s %TEMP% and has the elevated process check that copy against their SHA256, never running the file itself' {
        Mock Start-ElevatedProcess {
            $script:launch = @{ FilePath = $FilePath; ArgumentString = $ArgumentString }
            if ($ArgumentString -match "ReadAllBytes\('([^']+)'\)") {
                $script:stagedPath = $Matches[1]
                $script:stagedSha256 = (Get-FileHash -LiteralPath $script:stagedPath -Algorithm SHA256).Hash
            }
            $script:fakeProcess
        }
        $script:stagedPath = $null
        $script:stagedSha256 = $null

        Restart-WithElevation -ScriptPath $script:scriptPath -AdditionalArguments '-SkipSystemCheck'

        # A copy where the elevating account can read it (a mapped drive or share may be out of its
        # reach), with the same bytes.
        $script:stagedPath | Should -Not -BeNullOrEmpty
        $script:stagedPath | Should -Not -Be $script:scriptPath
        $script:stagedPath | Should -BeLike (Join-Path ([System.IO.Path]::GetTempPath()) 'winget-app-setup-elevate-*')
        (Split-Path -Leaf $script:stagedPath) | Should -Be 'winget-app-install.ps1'
        $script:stagedSha256 | Should -Be $script:scriptSha256
        $expectedCommand = New-ElevationVerifierCommand -ScriptPath $script:stagedPath -Sha256 $script:scriptSha256 -PowerShellPath (Get-WindowsPowerShellPath) -CopyRoot (Get-ElevatedCopyRoot) -AdditionalArguments '-SkipSystemCheck'
        $script:launch.ArgumentString | Should -BeExactly ('-NoProfile -Command "' + $expectedCommand + '"')
        # The only -File in the command line is the one that runs the checked copy.
        ([regex]::Matches($script:launch.ArgumentString, '-File ')).Count | Should -Be 1
        $script:launch.ArgumentString | Should -Match ([regex]::Escape('-File $copy -SkipSystemCheck;'))
        # Removed once the elevated run has ended.
        Test-Path -LiteralPath (Split-Path -Parent $script:stagedPath) | Should -BeFalse
    }

    It 'Removes the staged copy when the UAC prompt is declined too' {
        Mock Start-ElevatedProcess {
            if ($ArgumentString -match "ReadAllBytes\('([^']+)'\)") {
                $script:stagedPath = $Matches[1]
            }
            throw [System.ComponentModel.Win32Exception]::new(1223)
        }
        $script:stagedPath = $null

        (Restart-WithElevation -ScriptPath $script:scriptPath).ExitCode | Should -Be 4

        $script:stagedPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Split-Path -Parent $script:stagedPath) | Should -BeFalse
    }

    It 'Starts nothing and returns 5 when the file changed after the run started' {
        $result = Restart-WithElevation -ScriptPath $script:scriptPath -ExpectedSha256 ('0' * 64)

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 5
        Should -Invoke Start-ElevatedProcess -Times 0 -Exactly
        ($script:errorMessages -join "`n") | Should -Match 'changed after this run started'
    }

    It 'Starts the elevated run when the file still has the SHA256 it had when the run started' {
        $result = Restart-WithElevation -ScriptPath $script:scriptPath -ExpectedSha256 $script:scriptSha256.ToLowerInvariant()

        $result.Started | Should -BeTrue
        $script:launch.ArgumentString | Should -Match ([regex]::Escape("-ne '$($script:scriptSha256)'"))
    }

    It 'Returns 5 when the file cannot be read' {
        $result = Restart-WithElevation -ScriptPath (Join-Path $TestDrive 'missing.ps1')

        $result.ExitCode | Should -Be 5
        Should -Invoke Start-ElevatedProcess -Times 0 -Exactly
    }

    It '-InPlace runs the script itself with -File, quoted, followed by the forwarded switches' {
        Restart-WithElevation -ScriptPath 'C:\Repo Clone\winget-app-uninstall.ps1' -InPlace -AdditionalArguments '-WhatIf', '-SkipSystemCheck'

        $script:launch.ArgumentString | Should -BeExactly '-NoProfile -ExecutionPolicy Bypass -File "C:\Repo Clone\winget-app-uninstall.ps1" -WhatIf -SkipSystemCheck'
    }

    It 'Accepts only switch names as forwarded arguments, since they become part of a command line' {
        { Restart-WithElevation -ScriptPath $script:scriptPath -AdditionalArguments '-SkipSystemCheck; Remove-Item C:\' } | Should -Throw
        Should -Invoke Start-ElevatedProcess -Times 0 -Exactly
    }

    It 'Returns 4 without starting anything when the command line would be too long for ShellExecuteEx' {
        $result = Restart-WithElevation -ScriptPath ('C:\' + ('d' * 2100) + '\x.ps1') -InPlace

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 4
        Should -Invoke Start-ElevatedProcess -Times 0 -Exactly
        # -InPlace puts the path itself on the command line, so a shorter path is the fix.
        ($script:errorMessages -join "`n") | Should -Match 'is too long to start it elevated\. Move it to a shorter path'
    }

    It 'Points at the file name and %TEMP%, not the folder, when the checked-copy command would be too long' {
        # In the default mode the command holds the staged copy's path (under %TEMP%) and the file
        # name, not the folder the script is in, so moving the script would not help.
        Mock New-ElevationVerifierCommand { 'x' * 2100 }
        $tempRoot = [System.IO.Path]::GetTempPath()
        $stagingBefore = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'winget-app-setup-elevate-*' -ErrorAction SilentlyContinue).Count

        $result = Restart-WithElevation -ScriptPath $script:scriptPath

        $result.Started | Should -BeFalse
        $result.ExitCode | Should -Be 4
        Should -Invoke Start-ElevatedProcess -Times 0 -Exactly
        $message = $script:errorMessages -join "`n"
        $message | Should -Match ([regex]::Escape("%TEMP% path ($tempRoot)"))
        $message | Should -Match 'Give the file a shorter name, or start it from an elevated session\.'
        $message | Should -Not -Match 'Move it to a shorter path'
        # The staged copy is removed on this path too.
        @(Get-ChildItem -LiteralPath $tempRoot -Filter 'winget-app-setup-elevate-*' -ErrorAction SilentlyContinue).Count | Should -Be $stagingBefore
    }

    It 'Clears the PowerShell 7 bootstrap''s relaunch-loop guard before starting the elevated Windows PowerShell' {
        # The elevated Windows PowerShell enters the bootstrap legitimately; inheriting the guard
        # would make it stop with exit code 7 ('re-entered itself').
        $savedGuard = $env:WINGET_APP_SETUP_PS7_BOOTSTRAP
        $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = '1'
        try {
            $script:guardAtLaunch = 'not launched'
            Mock Start-ElevatedProcess {
                $script:guardAtLaunch = $env:WINGET_APP_SETUP_PS7_BOOTSTRAP
                $script:fakeProcess
            }

            Restart-WithElevation -ScriptPath $script:scriptPath

            $script:guardAtLaunch | Should -BeNullOrEmpty
        }
        finally {
            $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = $savedGuard
        }
    }

    It 'Returns 5 when Windows returns no process to wait for' {
        Mock Start-ElevatedProcess { $null }

        $result = Restart-WithElevation -ScriptPath $script:scriptPath

        $result.ExitCode | Should -Be 5
    }
}

Describe 'Start-ElevatedProcess' {
    It 'Starts the program through ShellExecuteEx with the runas verb, where a declined prompt surfaces as a Win32Exception' {
        # Calling the seam would raise a real UAC prompt, so only its shape is pinned here.
        $definition = ${function:Start-ElevatedProcess}.ToString()
        $definition | Should -Match '\.UseShellExecute = \$true'
        $definition | Should -Match ([regex]::Escape(".Verb = 'runas'"))
        $definition | Should -Match ([regex]::Escape('[System.Diagnostics.Process]::Start($startInfo)'))
    }
}

Describe 'Get-WindowsPowerShellPath and Get-ElevatedCopyRoot' {
    BeforeEach {
        $script:savedSystemRoot = $env:SystemRoot
        $script:savedWindir = $env:windir
    }

    AfterEach {
        $env:SystemRoot = $script:savedSystemRoot
        $env:windir = $script:savedWindir
    }

    It 'Builds both under %SystemRoot%' {
        $env:SystemRoot = 'D:\WINDOWS\'

        Get-WindowsPowerShellPath | Should -BeExactly 'D:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
        Get-ElevatedCopyRoot | Should -BeExactly 'D:\WINDOWS\Temp'
    }

    It 'Falls back to %windir%, then C:\Windows' {
        $env:SystemRoot = $null
        $env:windir = 'E:\Win'
        Get-WindowsPowerShellPath | Should -BeExactly 'E:\Win\System32\WindowsPowerShell\v1.0\powershell.exe'

        $env:windir = $null
        Get-ElevatedCopyRoot | Should -BeExactly 'C:\Windows\Temp'
    }
}

Describe 'New-ElevationVerifierCommand (review finding P3-11)' {
    BeforeDiscovery {
        # Discovery-time, because -Skip is bound during discovery. Off Windows, GetCurrent() throws.
        $script:isElevatedWindows = $false
        if ($IsWindows) {
            $script:isElevatedWindows = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
    }

    BeforeAll {
        $script:sampleSha256 = 'ab' * 32
        $script:currentPowerShell = (Get-Process -Id $PID).Path
    }

    It 'Is one line of PowerShell without double quotes, so it survives a quoted command-line argument' {
        $command = New-ElevationVerifierCommand -ScriptPath 'C:\Users\o''brien\AppData\Local\Temp\winget-app-setup-1\winget-app-install.ps1' -Sha256 $script:sampleSha256 -PowerShellPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -CopyRoot 'C:\Windows\Temp' -AdditionalArguments '-SkipSystemCheck'

        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $command | Should -Not -Match '["\r\n]'
        # Paths are single-quoted literals with quotes doubled; the hash is compared upper-case.
        $command | Should -Match ([regex]::Escape("ReadAllBytes('C:\Users\o''brien\AppData\Local\Temp\winget-app-setup-1\winget-app-install.ps1')"))
        $command | Should -Match ([regex]::Escape("-ne '$($script:sampleSha256.ToUpperInvariant())'"))
        $command | Should -Match ([regex]::Escape('-File $copy -SkipSystemCheck;'))
    }

    It 'Escapes the typographic single quote <Name> in a path, which PowerShell reads as a quote too' -ForEach @(
        @{ Name = 'U+2018'; Code = 0x2018 }
        @{ Name = 'U+2019'; Code = 0x2019 }
        @{ Name = 'U+201A'; Code = 0x201A }
        @{ Name = 'U+201B'; Code = 0x201B }
    ) {
        # A profile folder such as O'Brien typed with a curly apostrophe: left as it is, the quote
        # ends the literal, the elevated command does not parse, and powershell.exe exits 1 at once.
        $quoteCharacter = [string][char]$Code
        $path = 'C:\Users\O' + $quoteCharacter + 'Brien\AppData\Local\Temp\winget-app-setup-elevate-1\o' + $quoteCharacter + 's.ps1'
        $command = New-ElevationVerifierCommand -ScriptPath $path -Sha256 $script:sampleSha256 -PowerShellPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -CopyRoot 'C:\Windows\Temp'

        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        # The literals still hold the exact path and file name.
        $constants = @($ast.FindAll({ param ($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
        $constants | Should -Contain $path
        $constants | Should -Contain ('o' + $quoteCharacter + 's.ps1')
    }

    It 'Replaces each placeholder once, so placeholder-like text in a path stays as it is' {
        $command = New-ElevationVerifierCommand -ScriptPath 'C:\x\@SHA256@\@NAME@.ps1' -Sha256 $script:sampleSha256 -PowerShellPath 'p' -CopyRoot 'r'

        $command | Should -Match ([regex]::Escape("ReadAllBytes('C:\x\@SHA256@\@NAME@.ps1')"))
        $command | Should -Not -Match '@(SOURCE|COPYROOT|POWERSHELL|ARGUMENTS)@'
    }

    It 'Leaves room for a MAX_PATH script path within ShellExecuteEx''s command-line limit' {
        $longPath = 'C:\' + ('p' * 240) + '\winget-app-install.ps1'
        $command = New-ElevationVerifierCommand -ScriptPath $longPath -Sha256 $script:sampleSha256 -PowerShellPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -CopyRoot 'C:\Windows\Temp' -AdditionalArguments '-WhatIf', '-SkipSystemCheck'

        ('-NoProfile -Command "' + $command + '"').Length | Should -BeLessOrEqual 2000
    }

    It 'Does not run the script, and exits 5, when the file no longer has the expected SHA256' {
        # Real execution in a child PowerShell: the check runs before any of the file does.
        $markerPath = Join-Path $TestDrive 'ran.txt'
        $sourcePath = Join-Path $TestDrive 'tampered.ps1'
        Set-Content -LiteralPath $sourcePath -Value "Set-Content -LiteralPath '$markerPath' -Value 'ran'; exit 0" -Encoding UTF8
        $copyRoot = Join-Path $TestDrive 'copies-tampered'
        [void](New-Item -ItemType Directory -Path $copyRoot)
        $command = New-ElevationVerifierCommand -ScriptPath $sourcePath -Sha256 ('0' * 64) -PowerShellPath $script:currentPowerShell -CopyRoot $copyRoot

        $output = & $script:currentPowerShell -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 5
        Test-Path -LiteralPath $markerPath | Should -BeFalse
        $output | Should -Match 'Did not run tampered\.ps1: the file changed after administrator rights were requested'
        @(Get-ChildItem -LiteralPath $copyRoot).Count | Should -Be 0
    }

    It 'Runs its check, rather than failing to parse, when the path holds a typographic apostrophe (U+2019)' {
        # Real execution in a child PowerShell, as above. Before the quotes were escaped, the
        # command did not parse and exited 1 with nothing run or explained.
        $apostrophe = [string][char]0x2019
        $folder = Join-Path $TestDrive ('o' + $apostrophe + 'brien')
        [void](New-Item -ItemType Directory -Path $folder)
        $markerPath = Join-Path $TestDrive 'ran-apostrophe.txt'
        $sourcePath = Join-Path $folder ('tampered' + $apostrophe + 's.ps1')
        Set-Content -LiteralPath $sourcePath -Value "Set-Content -LiteralPath '$markerPath' -Value 'ran'; exit 0" -Encoding UTF8
        $copyRoot = Join-Path $TestDrive 'copies-apostrophe'
        [void](New-Item -ItemType Directory -Path $copyRoot)
        $command = New-ElevationVerifierCommand -ScriptPath $sourcePath -Sha256 ('0' * 64) -PowerShellPath $script:currentPowerShell -CopyRoot $copyRoot

        $output = & $script:currentPowerShell -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 5
        Test-Path -LiteralPath $markerPath | Should -BeFalse
        # The console may not render U+2019, so the name is matched around it.
        $output | Should -Match 'Did not run tampered.{1,3}s\.ps1: the file changed after administrator rights were requested'
        @(Get-ChildItem -LiteralPath $copyRoot).Count | Should -Be 0
    }

    It 'Under elevated Windows PowerShell, runs a copy in a new folder only SYSTEM and Administrators can change, forwards the switches, exits with its code and removes the copy' -Skip:(-not $script:isElevatedWindows) {
        # Windows only: creating a folder with its access list is .NET Framework only, and the
        # elevated process is always Windows PowerShell. Elevated only: the access list names no
        # other account, so only an administrator can write the copy (the Windows CI runners run
        # elevated). The elevating account's own entry is left out on purpose: in same-account
        # elevation it would let that account's non-elevated processes rewrite the copy.
        $windowsPowerShell = Get-WindowsPowerShellPath
        $resultPath = Join-Path $TestDrive 'result.json'
        $sourcePath = Join-Path $TestDrive 'source.ps1'
        $fixture = @'
param ([switch]$SkipSystemCheck)
$acl = Get-Acl -LiteralPath (Split-Path -Parent $PSCommandPath)
$identities = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
@{ Path = $PSCommandPath; SkipSystemCheck = [bool]$SkipSystemCheck; Protected = $acl.AreAccessRulesProtected; Inherited = @($acl.Access | Where-Object { $_.IsInherited }).Count; Identities = $identities } | ConvertTo-Json | Set-Content -LiteralPath '@RESULT@'
exit 42
'@
        Set-Content -LiteralPath $sourcePath -Value $fixture.Replace('@RESULT@', $resultPath) -Encoding UTF8
        $sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $copyRoot = Join-Path $TestDrive 'copies-elevated'
        [void](New-Item -ItemType Directory -Path $copyRoot)
        $command = New-ElevationVerifierCommand -ScriptPath $sourcePath -Sha256 $sha256 -PowerShellPath $windowsPowerShell -CopyRoot $copyRoot -AdditionalArguments '-SkipSystemCheck'

        & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command | Out-Null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 42
        $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        $result.Path | Should -Not -Be $sourcePath
        $result.Path | Should -BeLike (Join-Path $copyRoot 'winget-app-setup-*\source.ps1')
        $result.SkipSystemCheck | Should -BeTrue
        $result.Protected | Should -BeTrue
        $result.Inherited | Should -Be 0
        (@($result.Identities | Sort-Object -Unique) -join ',') | Should -BeExactly 'S-1-5-18,S-1-5-32-544'
        @(Get-ChildItem -LiteralPath $copyRoot).Count | Should -Be 0
    }
}

Describe 'winget-app-uninstall.ps1 elevation (review findings P2-11, P2-12)' {
    It 'Relaunches itself in place through Restart-WithElevation and exits with the elevated run''s exit code' {
        # The real uninstaller, next to a stand-in module (it imports the module from its own
        # folder), run in a child PowerShell so its exit ends that child.
        $root = Join-Path $TestDrive 'uninstaller'
        $moduleRoot = Join-Path $root 'WingetAppSetup'
        [void](New-Item -ItemType Directory -Path $moduleRoot -Force)
        Copy-Item -LiteralPath $script:UninstallerScriptPath -Destination $root
        Set-Content -LiteralPath (Join-Path $moduleRoot 'WingetAppSetup.psd1') -Value "@{ RootModule = 'WingetAppSetup.psm1'; ModuleVersion = '1.0.0'; FunctionsToExport = '*' }"
        Set-Content -LiteralPath (Join-Path $moduleRoot 'WingetAppSetup.psm1') -Value @'
function Test-IsAdmin { $false }
function Write-ErrorMessage { param ([string]$Message) Write-Host "ERROR: $Message" }
function Write-Success { param ([string]$Message) Write-Host "SUCCESS: $Message" }
function Write-Info { param ([string]$Message) Write-Host "INFO: $Message" }
function Get-DefaultAppCatalog { Write-Host 'UNINSTALL RAN'; @() }
function Restart-WithElevation {
    param ([string]$ScriptPath, [string[]]$AdditionalArguments, [string]$ExpectedSha256, [switch]$InPlace, [switch]$NonInteractive)
    Write-Host "RELAUNCH InPlace=$([bool]$InPlace) Path=$ScriptPath"
    [pscustomobject]@{ Started = $true; ExitCode = 42 }
}
'@
        $uninstallerCopy = Join-Path $root 'winget-app-uninstall.ps1'

        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $uninstallerCopy 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 42
        $output | Should -Match ([regex]::Escape("RELAUNCH InPlace=True Path=$uninstallerCopy"))
        $output | Should -Not -Match 'UNINSTALL RAN'
    }
}

Describe 'Test-InvokedFromModuleContext' {
    It 'Should return true when the invocation carries module info' {
        $fakeModule = New-Module -Name 'FakeWingetAppSetup' -ScriptBlock { }

        Test-InvokedFromModuleContext -InvocationModule $fakeModule -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be $true
    }

    It 'Should return true when the command path is the module Install.ps1 (Windows separators)' {
        Test-InvokedFromModuleContext -CommandPath 'C:\repo\WingetAppSetup\Public\Install.ps1' | Should -Be $true
    }

    It 'Should return true when the command path is the module Install.ps1 (forward slashes)' {
        Test-InvokedFromModuleContext -CommandPath '/home/user/repo/WingetAppSetup/Public/Install.ps1' | Should -Be $true
    }

    It 'Should return false for the generated single-file installer path' {
        Test-InvokedFromModuleContext -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be $false
    }

    It 'Should return false for an installer that merely lives under a WingetAppSetup directory' {
        Test-InvokedFromModuleContext -CommandPath 'C:\Users\admin\WingetAppSetup\winget-app-install.ps1' | Should -Be $false
    }

    It 'Should return false when the command path is empty' {
        Test-InvokedFromModuleContext -CommandPath '' | Should -Be $false
    }
}

Describe 'Test-IsSystemAccount' {
    It 'Returns a bool that matches the LocalSystem SID S-1-5-18, and false instead of throwing where the identity cannot be read' {
        # Off Windows, WindowsIdentity.GetCurrent() throws a MethodInvocationException wrapping
        # PlatformNotSupportedException; the function must catch that (an untyped catch) and say
        # $false. On Windows it must agree with the token's SID, whichever account runs the suite.
        $expected = try {
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
        }
        catch {
            $false
        }

        $result = Test-IsSystemAccount

        $result | Should -BeOfType [bool]
        $result | Should -Be $expected
    }
}

Describe 'Get-InstallAccountContext (review findings P2-24, P3-22, P3-23)' {
    It 'Says SYSTEM, and not cross-user elevation, for a run as SYSTEM while a user is signed in' {
        Mock Test-IsSystemAccount { $true }
        Mock Get-ProcessUserName { 'NT AUTHORITY\SYSTEM' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }

        $context = Get-InstallAccountContext

        $context.IsSystem | Should -BeTrue
        $context.IsCrossUserElevation | Should -BeFalse
        $context.ProcessUser | Should -Be 'NT AUTHORITY\SYSTEM'
        $context.SessionUser | Should -Be 'CONTOSO\jdoe'
    }

    It 'Says cross-user elevation for an admin account elevating on a signed-in user''s PC' {
        Mock Test-IsSystemAccount { $false }
        Mock Get-ProcessUserName { 'CONTOSO\admin-tech' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }

        $context = Get-InstallAccountContext

        $context.IsSystem | Should -BeFalse
        $context.IsCrossUserElevation | Should -BeTrue
    }

    It 'Says neither for <Case>' -ForEach @(
        @{ Case = 'the signed-in user''s own run'; Session = 'CONTOSO\jdoe' }
        @{ Case = 'the same account in other letter case'; Session = 'contoso\JDOE' }
        @{ Case = 'no console user reported'; Session = $null }
    ) {
        Mock Test-IsSystemAccount { $false }
        Mock Get-ProcessUserName { 'CONTOSO\jdoe' }
        Mock Get-InteractiveSessionUserName { $Session }

        $context = Get-InstallAccountContext

        $context.IsSystem | Should -BeFalse
        $context.IsCrossUserElevation | Should -BeFalse
    }
}
