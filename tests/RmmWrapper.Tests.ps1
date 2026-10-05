# RmmWrapper.Tests.ps1
# Tests for the Endpoint Central wrappers (work-order item 34): rmm/Invoke-WingetAppSetup.ps1, the
# machine phase run as SYSTEM, rmm/Invoke-WingetAppSetupUserPhase.ps1, the user phase run at each
# sign-in, and build/Set-RmmInstallerPin.ps1, which pins both to one installer. Each wrapper is
# dot-sourced (its run starts only when it is run) and its parts tested with stand-in installers
# run by the current pwsh; the Windows-only parts (the Sysnative relaunch, Windows PowerShell, the
# protected copy folder) are mocked at their seams, and the folder's access list is checked on
# Windows only.

BeforeDiscovery {
    $wrapperText = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'rmm/Invoke-WingetAppSetup.ps1')
    $script:PinsSet = $wrapperText -match "(?m)^\`$PinnedInstallerCommit = '[0-9a-f]{40}'"
    $script:GitAvailable = [bool](Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:MachineWrapperPath = Join-Path $script:RepoRoot 'rmm/Invoke-WingetAppSetup.ps1'
    $script:UserPhaseWrapperPath = Join-Path $script:RepoRoot 'rmm/Invoke-WingetAppSetupUserPhase.ps1'
    $script:PinScriptPath = Join-Path $script:RepoRoot 'build/Set-RmmInstallerPin.ps1'
    $script:BuildScriptPath = Join-Path $script:RepoRoot 'build/Build-WingetInstallScript.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Get-PinValue {
        param ([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
        $text = Get-Content -Raw -LiteralPath $Path
        $found = [regex]::Matches($text, "(?m)^\`$$Name = '([^']*)'")
        if ($found.Count -ne 1) { throw "$Path sets `$$Name $($found.Count) times." }
        return $found[0].Groups[1].Value
    }

    function Get-FunctionText {
        param ([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        if ($definition) { return $definition.Extent.Text }
        return $null
    }

    function New-TestScript {
        param ([Parameter(Mandatory = $true)][string]$Body, [string]$Name = 'stand-in.ps1')
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        $path = Join-Path $directory $Name
        Set-Content -LiteralPath $path -Value $Body
        return $path
    }

    function New-TestFolder {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path
        return $path
    }

    # A copy of a wrapper with its pins emptied, so a run of it never downloads, whatever the
    # repository's pins are.
    function New-UnpinnedWrapperCopy {
        param ([Parameter(Mandatory = $true)][string]$Path)
        $text = Get-Content -Raw -LiteralPath $Path
        $text = [regex]::Replace($text, "(?m)^(\`$PinnedInstaller(Commit|Sha256)) = '[^']*'", "`$1 = ''")
        $copy = Join-Path (New-TestFolder) (Split-Path -Leaf $Path)
        [System.IO.File]::WriteAllText($copy, $text)
        return $copy
    }

    . ([scriptblock]::Create((Get-FunctionText -Path $script:BuildScriptPath -Name 'Get-PowerShell7OnlySyntax')))
}

Describe 'The RMM wrappers: pins, shared code, Windows PowerShell 5.1' {
    It 'Pins both wrappers to the same installer: both pins set and well-formed, or both empty' {
        $commit = Get-PinValue -Path $script:MachineWrapperPath -Name 'PinnedInstallerCommit'
        $sha256 = Get-PinValue -Path $script:MachineWrapperPath -Name 'PinnedInstallerSha256'

        Get-PinValue -Path $script:UserPhaseWrapperPath -Name 'PinnedInstallerCommit' | Should -BeExactly $commit
        Get-PinValue -Path $script:UserPhaseWrapperPath -Name 'PinnedInstallerSha256' | Should -BeExactly $sha256
        if ($commit -or $sha256) {
            $commit | Should -Match '^[0-9a-f]{40}$'
            $sha256 | Should -Match '^[0-9A-F]{64}$'
        }
    }

    It 'Pins the winget-app-install.ps1 of the pinned commit' -Skip:(-not ($script:PinsSet -and $script:GitAvailable)) {
        $commit = Get-PinValue -Path $script:MachineWrapperPath -Name 'PinnedInstallerCommit'
        $listed = & git -C $script:RepoRoot cat-file -e "${commit}:winget-app-install.ps1" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because "commit $commit is not in this clone (a shallow checkout)"
            return
        }
        $blob = Join-Path $TestDrive 'pinned-installer.ps1'
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new('git')
        foreach ($argument in @('-C', $script:RepoRoot, 'cat-file', 'blob', "${commit}:winget-app-install.ps1")) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.RedirectStandardOutput = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $file = [System.IO.File]::Create($blob)
        $process.StandardOutput.BaseStream.CopyTo($file)
        $file.Dispose()
        $process.WaitForExit()

        (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash | Should -Be (Get-PinValue -Path $script:MachineWrapperPath -Name 'PinnedInstallerSha256')
    }

    It 'Defines the helpers both wrappers have the same way: <_>' -ForEach @('Write-RmmLine', 'Test-RmmPinnedCommit', 'Test-RmmSha256', 'Get-RmmInstallerUrl', 'Get-RmmFileSha256', 'Save-RmmInstallerDownload') {
        $machine = Get-FunctionText -Path $script:MachineWrapperPath -Name $_
        $machine | Should -Not -BeNullOrEmpty
        Get-FunctionText -Path $script:UserPhaseWrapperPath -Name $_ | Should -BeExactly $machine
    }

    It 'Stays runnable by Windows PowerShell 5.1: <Name> is ASCII only, parses cleanly, no PowerShell 7-only syntax' -ForEach @(
        @{ Name = 'rmm/Invoke-WingetAppSetup.ps1' }
        @{ Name = 'rmm/Invoke-WingetAppSetupUserPhase.ps1' }
    ) {
        $path = Join-Path $script:RepoRoot $Name
        @([System.IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        @(Get-PowerShell7OnlySyntax -Ast $ast -Tokens $tokens | ForEach-Object { '{0} at line {1}' -f $_.Kind, $_.Line }) | Should -BeNullOrEmpty
    }

    It 'Can dot-source winget-app-install.ps1 for its functions: at its top level only functions, script variables and the guarded run' {
        # The user phase dot-sources the installer to call Invoke-WingetUserPhase. That must define
        # functions and nothing else: any other top-level statement would run at every sign-in.
        # Parsed, never run (tests load the module source, not the generated file).
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallerScriptPath, [ref]$null, [ref]$null)
        $other = foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                continue
            }
            if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -like '$script:*' -and
                $statement.Right.Expression -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                continue
            }
            if ($statement -is [System.Management.Automation.Language.IfStatementAst] -and $statement.Clauses.Count -eq 1 -and $null -eq $statement.ElseClause -and
                $statement.Clauses[0].Item1.Extent.Text -eq "`$MyInvocation.InvocationName -ne '.'") {
                continue
            }
            '{0}: {1}' -f $statement.Extent.StartLineNumber, ($statement.Extent.Text -split "`n")[0]
        }

        @($other) | Should -BeNullOrEmpty
        $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WingetUserPhase' }, $false) | Should -Not -BeNullOrEmpty
    }

    It 'Runs nothing when dot-sourced: <_>' -ForEach @('rmm/Invoke-WingetAppSetup.ps1', 'rmm/Invoke-WingetAppSetupUserPhase.ps1') {
        $path = (Join-Path $script:RepoRoot $_).Replace("'", "''")
        $output = & $script:Pwsh -NoProfile -NonInteractive -Command ". '$path'; 'dot-sourced'; exit 0" 2>&1

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -BeExactly 'dot-sourced'
    }
}

Describe 'rmm/Invoke-WingetAppSetup.ps1: the machine phase' {
    BeforeAll {
        . $script:MachineWrapperPath
    }

    BeforeEach {
        $script:lines = @()
        Mock Write-RmmLine { $script:lines += $Message }
        Mock Test-Rmm32BitHostOn64BitWindows { $false }
        Mock Get-RmmWindowsPowerShellPath { $script:Pwsh }
        Mock New-RmmRestrictedDirectory {
            $path = Join-Path $Root ('winget-app-setup-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $path
            $path
        }
        Mock Save-RmmInstallerDownload { throw 'no download in this test' }
        $script:copyRoot = New-TestFolder
        $script:logs = Join-Path (New-TestFolder) 'logs'
        $script:resultPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $script:installer = New-TestScript -Name 'winget-app-install.ps1' -Body @"
param ([switch]`$NonInteractive, [switch]`$SkipSystemCheck)
Set-Content -LiteralPath '$($script:resultPath)' -Value @(`$PSCommandPath, "NonInteractive=`$NonInteractive", "SkipSystemCheck=`$SkipSystemCheck")
Write-Host 'stand-in installer output'
exit 8
"@
        $script:installerSha256 = (Get-FileHash -LiteralPath $script:installer -Algorithm SHA256).Hash
    }

    It 'Runs a checked copy of the installer in a protected folder with -NonInteractive, passes its exit code back unchanged, and removes the copy' {
        $exitCode = Invoke-RmmMachinePhase -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -LogDirectory $script:logs -CopyRoot $script:copyRoot

        $exitCode | Should -Be 8
        $result = Get-Content -LiteralPath $script:resultPath
        $result[0] | Should -BeLike (Join-Path $script:copyRoot 'winget-app-setup-*')
        Split-Path -Leaf $result[0] | Should -Be 'winget-app-install.ps1'
        $result[1..2] | Should -Be @('NonInteractive=True', 'SkipSystemCheck=False')
        @(Get-ChildItem -LiteralPath $script:copyRoot).Count | Should -Be 0
        Should -Invoke New-RmmRestrictedDirectory -Times 1 -Exactly -ParameterFilter { $Root -eq $script:copyRoot }
        $script:lines | Should -Contain "Installer checked (SHA256 $($script:installerSha256))."
        $script:lines | Should -Contain ('The installer exited with 8. Its transcripts and last-run.json are in {0}.' -f $script:logs)
    }

    It 'Passes -SkipSystemCheck on' {
        Invoke-RmmMachinePhase -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -SkipSystemCheck -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 8

        (Get-Content -LiteralPath $script:resultPath)[2] | Should -Be 'SkipSystemCheck=True'
    }

    It 'Logs to an install-(time)-rmm.log next to the installer''s logs, the installer''s output included' {
        Mock Write-RmmLine { Write-Host $Message }

        Invoke-RmmMachinePhase -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 8

        $log = @(Get-ChildItem -LiteralPath $script:logs)
        $log.Count | Should -Be 1
        $log[0].Name | Should -Match '^install-\d{8}-\d{6}-rmm\.log$'
        $text = Get-Content -Raw -LiteralPath $log[0].FullName
        $text | Should -Match 'winget-app-setup RMM wrapper \(machine phase\)'
        $text | Should -Match 'stand-in installer output'
        $text | Should -Match 'The installer exited with 8\.'
    }

    It 'Runs nothing and exits 5 when the installer''s SHA256 is not the expected one' {
        Invoke-RmmMachinePhase -InstallerPath $script:installer -InstallerSha256 ('0' * 64) -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 5

        Test-Path -LiteralPath $script:resultPath | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:copyRoot).Count | Should -Be 0
        $script:lines | Should -Contain "The installer's SHA256 is $($script:installerSha256), not the expected $('0' * 64), so it was not run. Nothing was installed."
    }

    It 'Refuses to run anything, with exit 5, when the pins are not set and no local installer is given' {
        Invoke-RmmMachinePhase -PinnedCommit '' -PinnedSha256 '' -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 5

        Should -Invoke Save-RmmInstallerDownload -Times 0 -Exactly
        Should -Invoke New-RmmRestrictedDirectory -Times 0 -Exactly
        ($script:lines -join "`n") | Should -Match 'no pinned installer yet: set PinnedInstallerCommit and PinnedInstallerSha256 .*build/Set-RmmInstallerPin\.ps1'
    }

    It 'Refuses a local installer without a SHA256 to check it against' {
        Invoke-RmmMachinePhase -InstallerPath $script:installer -PinnedCommit '' -PinnedSha256 '' -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 5

        Test-Path -LiteralPath $script:resultPath | Should -BeFalse
    }

    It 'Downloads the installer of the pinned commit, never main, and checks it against the pinned SHA256' {
        $commit = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
        Mock Save-RmmInstallerDownload {
            Copy-Item -LiteralPath $script:installer -Destination $Destination
            $true
        }

        Invoke-RmmMachinePhase -PinnedCommit $commit -PinnedSha256 $script:installerSha256 -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 8

        Should -Invoke Save-RmmInstallerDownload -Times 1 -Exactly -ParameterFilter {
            $Url -eq "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/$commit/winget-app-install.ps1" -and $Destination -like (Join-Path $script:copyRoot 'winget-app-setup-*')
        }
    }

    It 'Exits 5 when the download fails' {
        Mock Save-RmmInstallerDownload { $false }

        Invoke-RmmMachinePhase -PinnedCommit ('a' * 40) -PinnedSha256 $script:installerSha256 -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 5

        Test-Path -LiteralPath $script:resultPath | Should -BeFalse
    }

    It 'Relaunches a 32-bit PowerShell in 64-bit Windows PowerShell through Sysnative, with its arguments, and returns that run''s exit code' {
        Mock Test-Rmm32BitHostOn64BitWindows { $true }
        Mock Get-RmmSysnativePowerShellPath { $script:Pwsh }
        Mock Start-RmmTranscript { throw 'the 32-bit stage must not log' }
        $relaunchResult = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $wrapper = New-TestScript -Body @"
param ([string]`$InstallerPath, [switch]`$SkipSystemCheck, [switch]`$From32BitHost)
Set-Content -LiteralPath '$relaunchResult' -Value @(`$InstallerPath, "SkipSystemCheck=`$SkipSystemCheck", "From32BitHost=`$From32BitHost")
exit 6
"@

        $exitCode = Invoke-RmmMachinePhase -ScriptPath $wrapper -ForwardedArguments @('-InstallerPath', 'C:\Program Files\x\winget-app-install.ps1', '-SkipSystemCheck') -LogDirectory $script:logs -CopyRoot $script:copyRoot

        $exitCode | Should -Be 6
        Get-Content -LiteralPath $relaunchResult | Should -Be @('C:\Program Files\x\winget-app-install.ps1', 'SkipSystemCheck=True', 'From32BitHost=True')
        Should -Invoke Get-RmmSysnativePowerShellPath -Times 1 -Exactly
        Should -Invoke New-RmmRestrictedDirectory -Times 0 -Exactly
    }

    It 'Exits 5 from a 32-bit PowerShell when it cannot relaunch itself (not run from a file)' {
        Mock Test-Rmm32BitHostOn64BitWindows { $true }

        Invoke-RmmMachinePhase -ScriptPath '' -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 5
    }

    It 'Logs that it was relaunched from a 32-bit PowerShell' {
        Invoke-RmmMachinePhase -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -From32BitHost -LogDirectory $script:logs -CopyRoot $script:copyRoot | Should -Be 8

        $script:lines | Should -Contain 'Started by a 32-bit PowerShell on 64-bit Windows, and relaunched in 64-bit Windows PowerShell through Sysnative.'
    }

    It 'Turns its bound parameters back into arguments for the relaunch' {
        $bound = [ordered]@{ InstallerPath = 'C:\a b\i.ps1'; SkipSystemCheck = [System.Management.Automation.SwitchParameter]::new($true); InstallerSha256 = ''; From32BitHost = [System.Management.Automation.SwitchParameter]::new($false) }

        ConvertTo-RmmForwardedArgument -BoundParameters $bound | Should -Be @('-InstallerPath', 'C:\a b\i.ps1', '-SkipSystemCheck')
    }

    It 'Accepts only a full commit id and a SHA256 as pins (<Value>)' -ForEach @(
        @{ Value = ''; Commit = $false; Sha = $false }
        @{ Value = 'main'; Commit = $false; Sha = $false }
        @{ Value = 'a1b2c3d'; Commit = $false; Sha = $false }
        @{ Value = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'; Commit = $true; Sha = $false }
        @{ Value = 'A1B2C3D4E5F60718293A4B5C6D7E8F9012345678'; Commit = $false; Sha = $false }
        @{ Value = ('ab' * 32); Commit = $false; Sha = $true }
    ) {
        Test-RmmPinnedCommit -Commit $Value | Should -Be $Commit
        Test-RmmSha256 -Hash $Value | Should -Be $Sha
    }

    It 'Exits 5, saying so, when run without pins' {
        $copy = New-UnpinnedWrapperCopy -Path $script:MachineWrapperPath
        $programData = New-TestFolder
        $savedProgramData = $env:ProgramData
        try {
            $env:ProgramData = $programData
            $output = & $script:Pwsh -NoProfile -NonInteractive -File $copy 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $env:ProgramData = $savedProgramData
        }

        $exitCode | Should -Be 5
        ($output -join "`n") | Should -Match 'no pinned installer yet'
        @(Get-ChildItem -LiteralPath (Join-Path $programData 'winget-app-setup/logs') -Filter 'install-*-rmm.log').Count | Should -Be 1
    }
}

Describe 'rmm/Invoke-WingetAppSetup.ps1 and rmm/Invoke-WingetAppSetupUserPhase.ps1: where they find PowerShell' {
    BeforeAll {
        . $script:MachineWrapperPath
        . $script:UserPhaseWrapperPath
    }

    It 'Finds Windows PowerShell through Sysnative and System32' {
        $saved = $env:SystemRoot
        try {
            $env:SystemRoot = 'C:\Windows\'
            Get-RmmSysnativePowerShellPath | Should -Be 'C:\Windows\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
            Get-RmmWindowsPowerShellPath | Should -Be 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        finally {
            $env:SystemRoot = $saved
        }
    }

    It 'Finds the machine-wide PowerShell 7 first' {
        $programFiles = New-TestFolder
        $pwshPath = Join-Path $programFiles 'PowerShell/7/pwsh.exe'
        $null = New-Item -ItemType File -Path $pwshPath -Force
        $saved = $env:ProgramW6432
        try {
            $env:ProgramW6432 = $programFiles
            Find-RmmPowerShell7 | Should -Be (Join-Path $programFiles 'PowerShell\7\pwsh.exe')
        }
        finally {
            $env:ProgramW6432 = $saved
        }
    }
}

Describe 'rmm/Invoke-WingetAppSetup.ps1: the protected copy folder' -Skip:(-not $IsWindows) {
    BeforeAll {
        . $script:MachineWrapperPath
    }

    It 'Creates it for SYSTEM and Administrators only, with no inherited entries' {
        $folder = New-RmmRestrictedDirectory -Root $TestDrive

        Split-Path -Leaf $folder | Should -Match '^winget-app-setup-[0-9a-f]{32}$'
        $acl = Get-Acl -LiteralPath $folder
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
        $sids | Should -Be @('S-1-5-18', 'S-1-5-32-544')
    }
}

Describe 'rmm/Invoke-WingetAppSetupUserPhase.ps1: the user phase' {
    BeforeAll {
        . $script:UserPhaseWrapperPath

        function New-TestRecord {
            param ([string]$Directory, [AllowNull()]$ExitCode = 0, [string[]]$Deferred = @('Contoso.UserOnly'))
            $null = New-Item -ItemType Directory -Path $Directory -Force
            $apps = @($Deferred | ForEach-Object { New-AppRunRecord -Id $_ -Status 'Deferred' })
            $record = New-InstallerRunRecord -ExitCode 0 -Apps $apps -SummaryReached
            $record.exitCode = $ExitCode
            Save-InstallerRunRecord -Record $record -Directory $Directory
        }
    }

    BeforeEach {
        $script:lines = @()
        Mock Write-RmmLine { $script:lines += $Message }
        Mock Test-RmmIsSystem { $false }
        Mock Save-RmmInstallerDownload { throw 'no download in this test' }
        Mock Find-RmmPowerShell7 { $script:Pwsh }
        # The record as the machine phase leaves it: owned by SYSTEM, which the wrapper and the
        # module both check (Get-RmmRunRecordTrustProblem, Get-RunRecordTrustProblem).
        Mock Get-Acl { New-TestFileAcl }
        $script:root = New-TestFolder
        $script:recordPath = Join-Path $script:root 'logs/last-run.json'
        $script:statePath = Join-Path $script:root 'state/user-phase.json'
        $script:tempRoot = Join-Path $script:root 'temp'
        $null = New-Item -ItemType Directory -Path $script:tempRoot
        $script:resultPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $script:entryMarker = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.entry')
        # A stand-in installer: dot-sourced it defines Invoke-WingetUserPhase; run, its entry would
        # write the marker.
        $script:installer = New-TestScript -Name 'winget-app-install.ps1' -Body @"
param ([switch]`$WhatIf)
function Invoke-WingetUserPhase {
    param ([int]`$MaxMinutes, [int]`$MaxAttempts)
    Set-Content -LiteralPath '$($script:resultPath)' -Value "MaxMinutes=`$MaxMinutes MaxAttempts=`$MaxAttempts"
    return 1
}
if (`$MyInvocation.InvocationName -ne '.') { Set-Content -LiteralPath '$($script:entryMarker)' -Value 'entry ran'; exit 99 }
"@
        $script:installerSha256 = (Get-FileHash -LiteralPath $script:installer -Algorithm SHA256).Hash
    }

    It 'Decides like the module''s Get-UserPhaseDecision: <Case>' -ForEach @(
        @{ Case = 'no record'; Record = 'none'; State = $null }
        @{ Case = 'a record that is not JSON'; Record = 'broken'; State = $null }
        @{ Case = 'JSON that is not a run record'; Record = 'noapps'; State = $null }
        @{ Case = 'a run that has not reported'; Record = 'running'; State = $null }
        @{ Case = 'no state'; Record = 'done'; State = $null }
        @{ Case = 'a state that is not JSON'; Record = 'done'; State = 'broken' }
        @{ Case = 'this run, complete'; Record = 'done'; State = @{ complete = $true; attempts = 1 } }
        @{ Case = 'this run, attempts left'; Record = 'done'; State = @{ complete = $false; attempts = 2 } }
        @{ Case = 'this run, attempts used up'; Record = 'done'; State = @{ complete = $false; attempts = 3 } }
        @{ Case = 'an older run, complete'; Record = 'done'; State = @{ complete = $true; attempts = 1; other = $true } }
        @{ Case = 'a record a user owns'; Record = 'done'; State = $null; Acl = @{ OwnerSid = 'S-1-5-21-1-2-3-1001' } }
        @{ Case = 'a record Users can write to'; Record = 'done'; State = $null; Acl = @{ Rules = @(@{ Sid = 'S-1-5-18'; Rights = 2032127 }, @{ Sid = 'S-1-5-32-545'; Rights = 0x116 }) } }
        @{ Case = 'a record whose access list cannot be read'; Record = 'done'; State = $null; Acl = 'unreadable' }
    ) {
        Mock Write-WarningMessage { }
        $acl = $Acl
        if ($acl -eq 'unreadable') {
            Mock Get-Acl { throw 'Attempted to perform an unauthorized operation.' }
        }
        elseif ($acl) {
            Mock Get-Acl { New-TestFileAcl @acl }
        }
        $recordDirectory = Split-Path -Parent $script:recordPath
        switch ($Record) {
            'broken' { $null = New-Item -ItemType Directory -Path $recordDirectory -Force; Set-Content -LiteralPath $script:recordPath -Value '{ not json' }
            'noapps' { $null = New-Item -ItemType Directory -Path $recordDirectory -Force; Set-Content -LiteralPath $script:recordPath -Value '{"exitCode":0}' }
            'running' { $null = New-TestRecord -Directory $recordDirectory -ExitCode $null }
            'done' { $null = New-TestRecord -Directory $recordDirectory }
        }
        if ($State -eq 'broken') {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:statePath) -Force
            Set-Content -LiteralPath $script:statePath -Value 'not json'
        }
        elseif ($State) {
            $sha = (Get-FileHash -LiteralPath $script:recordPath -Algorithm SHA256).Hash
            if ($State.other) { $sha = 'FF' * 32 }
            $null = Save-UserPhaseState -Path $script:statePath -State ([ordered]@{ recordSha256 = $sha.ToLowerInvariant(); complete = $State.complete; attempts = $State.attempts })
        }

        $wrapper = Test-RmmUserPhasePending -RunRecordPath $script:recordPath -StatePath $script:statePath -MaxAttempts 3
        $module = Get-UserPhaseDecision -Record (Read-InstallerRunRecord -Path $script:recordPath) -State (Read-UserPhaseState -Path $script:statePath) -MaxAttempts 3

        $wrapper.Pending | Should -Be $module.Run
        $wrapper.Reason | Should -Be $module.Reason
        if ($acl) {
            $wrapper.Reason | Should -Be 'NoRecord'
            $wrapper.Detail | Should -Match '^winget-app-setup user phase: ignoring .*last-run\.json, which SYSTEM or an administrator must have written: '
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -like 'Ignoring the run record *' }
        }
        else {
            $wrapper.Detail | Should -BeNullOrEmpty
        }
    }

    It 'Says so, exits 0 and starts nothing, for a record someone other than SYSTEM or an administrator could have written' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath) -Deferred @('Contoso.Chosen')
        Mock Get-Acl { New-TestFileAcl -OwnerSid 'S-1-5-21-1-2-3-1001' }

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 0

        Should -Invoke Find-RmmPowerShell7 -Times 0 -Exactly
        Test-Path -LiteralPath $script:resultPath | Should -BeFalse
        $script:lines.Count | Should -Be 1
        $script:lines[0] | Should -BeLike "winget-app-setup user phase: ignoring $($script:recordPath), which SYSTEM or an administrator must have written: it is owned by S-1-5-21-1-2-3-1001, not by SYSTEM or Administrators. The next run of the machine phase replaces it."
    }

    It 'Ends at once, printing nothing and starting nothing, when there is no work' {
        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 0

        $script:lines | Should -BeNullOrEmpty
        Should -Invoke Find-RmmPowerShell7 -Times 0 -Exactly
    }

    It 'Does nothing as SYSTEM, and says so' {
        Mock Test-RmmIsSystem { $true }
        Mock Test-RmmUserPhasePending { throw 'must not look' }

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 0

        ($script:lines -join "`n") | Should -Match 'nothing to do as SYSTEM'
    }

    It 'Runs the user phase under PowerShell 7 from a checked copy it dot-sources, and passes its exit code back' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath)

        $exitCode = Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -MaxMinutes 7 -MaxAttempts 2 -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot

        $exitCode | Should -Be 1
        Get-Content -LiteralPath $script:resultPath | Should -Be 'MaxMinutes=7 MaxAttempts=2'
        Test-Path -LiteralPath $script:entryMarker | Should -BeFalse -Because "dot-sourced, the installer's own run must not start"
        @(Get-ChildItem -LiteralPath $script:tempRoot).Count | Should -Be 0
    }

    It 'Exits 7, starting nothing, when PowerShell 7 is not installed' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath)
        Mock Find-RmmPowerShell7 { $null }
        Mock Invoke-RmmProcessWithTimeout { throw 'must not start anything' }

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 7
    }

    It 'Exits 5, downloading nothing, when the pins are not set' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath)

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -PinnedCommit '' -PinnedSha256 '' -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 5

        Should -Invoke Save-RmmInstallerDownload -Times 0 -Exactly
    }

    It 'Downloads the installer of the pinned commit when there is work' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath)
        $commit = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
        Mock Save-RmmInstallerDownload {
            Copy-Item -LiteralPath $script:installer -Destination $Destination
            $true
        }

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -PinnedCommit $commit -PinnedSha256 $script:installerSha256 -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 1

        Should -Invoke Save-RmmInstallerDownload -Times 1 -Exactly -ParameterFilter { $Url -eq "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/$commit/winget-app-install.ps1" }
    }

    It 'Runs nothing and exits 5 when the installer''s SHA256 is not the expected one' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath)
        Mock Invoke-RmmProcessWithTimeout { throw 'must not start anything' }

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -InstallerPath $script:installer -InstallerSha256 ('0' * 64) -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 5

        @(Get-ChildItem -LiteralPath $script:tempRoot).Count | Should -Be 0
    }

    It 'Stops the PowerShell 7 run MaxMinutes + 5 minutes after it started, and exits 5' {
        $null = New-TestRecord -Directory (Split-Path -Parent $script:recordPath)
        Mock Invoke-RmmProcessWithTimeout { $null }

        Invoke-RmmUserPhaseLauncher -ScriptPath $script:UserPhaseWrapperPath -InstallerPath $script:installer -InstallerSha256 $script:installerSha256 -MaxMinutes 10 -RunRecordPath $script:recordPath -StatePath $script:statePath -TempRoot $script:tempRoot | Should -Be 5

        Should -Invoke Invoke-RmmProcessWithTimeout -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 900 -and $FilePath -eq $script:Pwsh -and $ArgumentList -contains '-RunUserPhaseWith' }
    }

    It 'Does not dot-source a copy that changed after it was checked' {
        $exitCode = Invoke-RmmUserPhaseRunner -InstallerCopyPath $script:installer -InstallerSha256 ('0' * 64)

        $exitCode | Should -Be 5
        Test-Path -LiteralPath $script:resultPath | Should -BeFalse
    }

    It 'Exits 5, saying why, when the checked installer has no user phase (a commit older than it)' {
        # In a process of its own: this one has the module's Invoke-WingetUserPhase loaded.
        $old = New-TestScript -Name 'winget-app-install.ps1' -Body "param ([switch]`$WhatIf)`nfunction Invoke-WingetInstall { return 0 }`n"
        $oldSha256 = (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash
        $copy = New-UnpinnedWrapperCopy -Path $script:UserPhaseWrapperPath

        $output = & $script:Pwsh -NoProfile -NonInteractive -File $copy -RunUserPhaseWith $old -InstallerSha256 $oldSha256 2>&1

        $LASTEXITCODE | Should -Be 5
        ($output -join "`n") | Should -Match 'has no user phase \(Invoke-WingetUserPhase\): it is from a commit older than the user phase'
    }

    It 'Returns a child''s exit code, and stops a child that outlives its time limit' {
        Invoke-RmmProcessWithTimeout -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 3') -TimeoutSeconds 60 | Should -Be 3

        $started = Get-Date
        Invoke-RmmProcessWithTimeout -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSeconds 2 | Should -BeNullOrEmpty
        ((Get-Date) - $started).TotalSeconds | Should -BeLessThan 30
    }

    It 'Quotes arguments the way Windows programs split them: <Name>' -ForEach @(
        @{ Name = 'plain'; Arguments = @('-File', 'C:\a\b.ps1'); Expected = '-File C:\a\b.ps1' }
        @{ Name = 'a space'; Arguments = @('C:\Users\Jo Doe\x.ps1'); Expected = '"C:\Users\Jo Doe\x.ps1"' }
        @{ Name = 'a space and a trailing backslash'; Arguments = @('C:\Jo Doe\'); Expected = '"C:\Jo Doe\\"' }
        @{ Name = 'a quote'; Arguments = @('say "hi"'); Expected = '"say \"hi\""' }
        @{ Name = 'empty'; Arguments = @(''); Expected = '""' }
    ) {
        ConvertTo-RmmArgumentString -ArgumentList $Arguments | Should -BeExactly $Expected
    }

    It 'Ends at once, printing nothing, when run with no run record' {
        $copy = New-UnpinnedWrapperCopy -Path $script:UserPhaseWrapperPath
        $saved = @{ ProgramData = $env:ProgramData; LOCALAPPDATA = $env:LOCALAPPDATA }
        try {
            $env:ProgramData = Join-Path $script:root 'pd'
            $env:LOCALAPPDATA = Join-Path $script:root 'la'
            $output = & $script:Pwsh -NoProfile -NonInteractive -File $copy 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $env:ProgramData = $saved.ProgramData
            $env:LOCALAPPDATA = $saved.LOCALAPPDATA
        }

        $exitCode | Should -Be 0
        $output | Should -BeNullOrEmpty
    }
}

# The real Get-Acl, on Windows only, where Windows PowerShell 5.1 runs the same code: the property
# names the check reads (FileSystemRights, PropagationFlags) and a real owner.
Describe 'rmm/Invoke-WingetAppSetupUserPhase.ps1: the run record''s access list on real Windows' -Skip:(-not $IsWindows) {
    BeforeAll {
        . $script:UserPhaseWrapperPath
    }

    It 'Names an account that was given write access to the record' {
        $path = Join-Path $TestDrive ('trust-' + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $path -Value '{}'
        $grant = Start-Process -FilePath 'icacls.exe' -ArgumentList "`"$path`" /grant *S-1-5-32-545:(W) /q" -Wait -PassThru -WindowStyle Hidden
        $grant.ExitCode | Should -Be 0

        Get-RmmRunRecordTrustProblem -Path $path | Should -Match '(^|; )S-1-5-32-545 can change it'
    }
}

Describe 'build/Set-RmmInstallerPin.ps1' -Skip:(-not $script:GitAvailable) {
    BeforeEach {
        $script:repository = New-TestFolder
        $null = New-Item -ItemType Directory -Path (Join-Path $script:repository 'rmm')
        foreach ($wrapper in @($script:MachineWrapperPath, $script:UserPhaseWrapperPath)) {
            Copy-Item -LiteralPath (New-UnpinnedWrapperCopy -Path $wrapper) -Destination (Join-Path $script:repository 'rmm')
        }
        # '# installer' CRLF 'function Invoke-WingetUserPhase { }' LF: raw bytes, so the hash
        # checks that git's bytes are used as they are.
        $script:committed = [byte[]](@(0x23, 0x20, 0x69, 0x6E, 0x73, 0x74, 0x61, 0x6C, 0x6C, 0x65, 0x72, 0x0D, 0x0A) + [System.Text.Encoding]::ASCII.GetBytes('function Invoke-WingetUserPhase { }') + @(0x0A))
        [System.IO.File]::WriteAllBytes((Join-Path $script:repository 'winget-app-install.ps1'), $script:committed)
        foreach ($command in @(
                @('init', '-q'), @('config', 'user.email', 'test@example.com'), @('config', 'user.name', 'test'), @('config', 'commit.gpgsign', 'false'),
                @('config', 'core.autocrlf', 'false'), @('add', '.'), @('commit', '-q', '-m', 'test'))) {
            $null = & git -C $script:repository @command 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($command -join ' ') failed" }
        }
        $script:commit = (& git -C $script:repository rev-parse HEAD).Trim()
    }

    It 'Pins both wrappers to the committed file''s SHA256, not the working tree''s, and changes only the pin lines' {
        Set-Content -LiteralPath (Join-Path $script:repository 'winget-app-install.ps1') -Value 'edited after the commit'
        $expectedSha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($script:committed))

        $output = & $script:Pwsh -NoProfile -NonInteractive -File $script:PinScriptPath -Commit HEAD -RepositoryRoot $script:repository 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

        foreach ($name in @('Invoke-WingetAppSetup.ps1', 'Invoke-WingetAppSetupUserPhase.ps1')) {
            $path = Join-Path $script:repository "rmm/$name"
            Get-PinValue -Path $path -Name 'PinnedInstallerCommit' | Should -Be $script:commit
            Get-PinValue -Path $path -Name 'PinnedInstallerSha256' | Should -Be $expectedSha256
            $diff = @(& git -C $script:repository diff --numstat -- "rmm/$name")
            $diff | Should -Be @("2`t2`trmm/$name")
        }
    }

    It 'Refuses, changing nothing, an installer without the user phase' {
        Set-Content -LiteralPath (Join-Path $script:repository 'winget-app-install.ps1') -Value 'function Invoke-WingetInstall { }'
        $null = & git -C $script:repository commit -q -am 'an installer from before the user phase' 2>&1

        $output = & $script:Pwsh -NoProfile -NonInteractive -File $script:PinScriptPath -Commit HEAD -RepositoryRoot $script:repository 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'has no user phase \(function Invoke-WingetUserPhase\)'
        @(& git -C $script:repository status --porcelain) | Should -BeNullOrEmpty
    }

    It 'Fails, changing nothing, when a wrapper has no pin line' {
        $path = Join-Path $script:repository 'rmm/Invoke-WingetAppSetupUserPhase.ps1'
        $text = Get-Content -Raw -LiteralPath $path
        [System.IO.File]::WriteAllText($path, ($text -replace "(?m)^\`$PinnedInstallerSha256 = ''\r?\n?", ''))
        $null = & git -C $script:repository commit -q -am 'drop a pin' 2>&1

        $null = & $script:Pwsh -NoProfile -NonInteractive -File $script:PinScriptPath -Commit HEAD -RepositoryRoot $script:repository 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        @(& git -C $script:repository status --porcelain) | Should -BeNullOrEmpty
    }
}
