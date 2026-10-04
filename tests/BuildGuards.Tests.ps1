# BuildGuards.Tests.ps1
# Tests for the guards in build/Build-WingetInstallScript.ps1 and for the .githooks/pre-commit
# drift check (review findings P3-46, P3-47 and P3-48):
#   - -Check rejects syntax that only PowerShell 7 parses, because Windows PowerShell 5.1 parses
#     the whole installer before it runs any of it;
#   - the undefined-reference guards run off Windows too, with build/windows-only-commands.txt
#     standing in for the cmdlets only Windows can resolve;
#   - the pre-commit hook checks the staged files, not the working tree.
# The end-to-end tests copy the build inputs into TestDrive, plant a crafted module file there and
# run the copied build script (or hook) in a child process, so the real tree is never touched.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:buildScriptPath = Join-Path $script:RepoRoot 'build/Build-WingetInstallScript.ps1'
    $script:windowsOnlyCommandsPath = Join-Path $script:RepoRoot 'build/windows-only-commands.txt'
    $script:currentPowerShell = (Get-Process -Id $PID).Path

    # Loads one helper function from the build script itself (not a copy), so the unit tests
    # below exercise the code the build runs.
    function Import-BuildScriptFunction {
        param ([Parameter(Mandatory = $true)][string]$Name)

        $buildAst = [System.Management.Automation.Language.Parser]::ParseFile($script:buildScriptPath, [ref]$null, [ref]$null)
        $definition = $buildAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $false)
        if (-not $definition) { throw "build/Build-WingetInstallScript.ps1 defines no function '$Name'." }
        $definition.Extent.Text
    }
    . ([scriptblock]::Create((Import-BuildScriptFunction -Name 'Get-PowerShell7OnlySyntax')))

    function Get-SnippetPowerShell7OnlySyntax {
        param ([Parameter(Mandatory = $true)][string]$Source)

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "Test snippet does not parse: $($parseErrors[0].Message)" }
        @(Get-PowerShell7OnlySyntax -Ast $ast -Tokens $tokens)
    }

    # Copies what the build reads (build/, WingetAppSetup/, the committed installer) into
    # TestDrive and optionally plants an extra Private/ module file.
    function New-BuildFixture {
        param (
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$ProbeSource,
            [string[]]$ExtraWindowsOnlyCommand,
            [string[]]$ExtraItem
        )

        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($item in @('build', 'WingetAppSetup', 'winget-app-install.ps1') + $ExtraItem) {
            if ($item) { Copy-Item -Path (Join-Path $script:RepoRoot $item) -Destination $root -Recurse }
        }
        if ($ProbeSource) {
            [System.IO.File]::WriteAllText((Join-Path $root 'WingetAppSetup/Private/ZzBuildGuardProbe.ps1'), $ProbeSource)
        }
        if ($ExtraWindowsOnlyCommand) {
            Add-Content -Path (Join-Path $root 'build/windows-only-commands.txt') -Value $ExtraWindowsOnlyCommand
        }
        $root
    }

    function ConvertTo-PlainOutput {
        param ([object[]]$Output)

        (@($Output | ForEach-Object { "$_" }) -join "`n") -replace "\x1b\[[0-9;]*[A-Za-z]", ''
    }

    # Runs the fixture's build script in a child pwsh. A guard failure is a Write-Error under
    # $ErrorActionPreference = 'Stop', which the default error view word-wraps at the console
    # width; catching it and printing the message as one plain line keeps the names the tests
    # look for in one piece.
    function Invoke-FixtureBuild {
        param ([Parameter(Mandatory = $true)][string]$Root, [switch]$Check)

        $buildScript = (Join-Path $Root 'build/Build-WingetInstallScript.ps1').Replace("'", "''")
        $checkArgument = if ($Check) { ' -Check' } else { '' }
        $command = "try { & '$buildScript'$checkArgument; exit `$LASTEXITCODE } catch { [Console]::Out.WriteLine('BUILD ERROR: ' + `$_.Exception.Message); exit 1 }"
        $output = & $script:currentPowerShell -NoProfile -NonInteractive -Command $command 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (ConvertTo-PlainOutput -Output $output) }
    }
}

Describe 'Build guard: PowerShell-7-only syntax (review finding P3-46)' {
    Context 'Get-PowerShell7OnlySyntax' {
        It 'finds <Kind> in: <Source>' -ForEach @(
            @{ Kind = 'QuestionQuestion'; Source = '$x = $env:FOO ?? ''bar''' }
            @{ Kind = 'QuestionQuestionEquals'; Source = '$x ??= 1' }
            @{ Kind = 'QuestionDot'; Source = '$y = ${x}?.Name' }
            @{ Kind = 'QuestionLBracket'; Source = '$y = ${x}?[0]' }
            @{ Kind = 'QuestionMark'; Source = '$z = $a ? 1 : 2' }
            @{ Kind = 'AndAnd'; Source = 'Get-Item . && Get-Item ..' }
            @{ Kind = 'OrOr'; Source = 'Get-Item . || Get-Item ..' }
            @{ Kind = 'CleanBlock'; Source = 'function Test-Clean { process { } clean { } }' }
            @{ Kind = 'BackgroundOperator'; Source = 'Get-Item . &' }
            @{ Kind = 'BackgroundOperator'; Source = '$job = Get-Process -Id $PID &' }
            @{ Kind = 'BackgroundOperator'; Source = 'function Test-Background { if ($true) { Get-Item . & } }' }
        ) {
            $found = Get-SnippetPowerShell7OnlySyntax -Source $Source

            $found.Count | Should -Be 1
            $found[0].Kind | Should -Be $Kind
            $found[0].Line | Should -Be 1
        }

        It 'finds operators inside the $( ) subexpressions of expandable strings and here-strings' {
            $source = @'
$a = "x $($b ?? 'c') y"
$d = @"
x $(Get-Item . && Get-Item ..) y
"@
$e = "x $("inner $(${f}?.Name)")"
$g = "x $(Get-Item . &) y"
'@
            $found = Get-SnippetPowerShell7OnlySyntax -Source $source

            @($found | Sort-Object -Property Line, Column | ForEach-Object { $_.Kind }) | Should -Be @('QuestionQuestion', 'AndAnd', 'QuestionDot', 'BackgroundOperator')
        }

        It 'reports the position of the background operator itself' {
            $found = Get-SnippetPowerShell7OnlySyntax -Source "`$x = 1`n`$job = Get-Process -Id `$PID   &"

            $found.Count | Should -Be 1
            $found[0].Line | Should -Be 2
            $found[0].Column | Should -Be 31
            $found[0].Text | Should -Be '&'
        }

        It 'does not flag 5.1-valid code that uses the same characters' {
            # Strings, comments and regexes holding the operators, the Where-Object alias ?, a
            # variable named x? (legal in 5.1, which is why 7 needs ${x}?. for null-conditional),
            # clean as a hashtable key, member, switch clause and class method name, and the call
            # and dot-source operators, which share the background operator's & token.
            $source = @'
# A comment with ?? and ?. and $a ? 1 : 2 and && and || and clean { } and Get-Item . &
$s = 'a || b && c ?? d ?. e ?[ f & g'
$t = "x || y && $($s.Length) ?? z"
$u = @"
here || there && ?? $($s.Length)
"@
$m = $s -match '^a?b$'
$n = @(1, 2) | ? { $_ -gt 1 }
$x? = 1
$o = $x?
Write-Output ?
$h = @{ clean = 1 }
$p = $h.clean
$q = $m -and $n -or $o
switch ($s) { clean { 1 } default { 2 } }
class ZzC { [void] clean() { } }
$v = { Get-Item . }
& $v
& { Get-Item . }
. { Get-Item . }
& Get-Item .
$w = & $v | Where-Object { $_ }
$y = "x $(& $v) & y"
'@
            Get-SnippetPowerShell7OnlySyntax -Source $source | Should -BeNullOrEmpty
        }

        It 'finds nothing in the committed installer' {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallerScriptPath, [ref]$tokens, [ref]$parseErrors)

            Get-PowerShell7OnlySyntax -Ast $ast -Tokens $tokens | Should -BeNullOrEmpty
        }
    }

    Context 'Build and -Check' {
        It 'fails -Check when a module file uses ?? and names the line' {
            $root = New-BuildFixture -Name 'ps7-syntax' -ProbeSource "function Get-ZzProbeValue { `$env:ZZ_PROBE ?? 'fallback' }`n"

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'PowerShell 5\.1 syntax check failed: 1 place'
            $result.Output | Should -Match "line \d+, column \d+: '\?\?' \(QuestionQuestion\)"
        }
    }
}

Describe 'Build guard: undefined references on every platform (review finding P3-48)' {
    It 'fails the build when the installer calls a function the module does not define' {
        $root = New-BuildFixture -Name 'undefined-call' -ProbeSource "function Test-ZzProbe { Invoke-ZzNoSuchHelper -Name 'x' }`n"

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Reference check failed: the generated script invokes command\(s\) that are not defined in the module and do not resolve as external cmdlets: Invoke-ZzNoSuchHelper\.'
    }

    It 'fails the build when a catalog install field names a function the module does not define' {
        $root = New-BuildFixture -Name 'undefined-install' -ProbeSource "function Get-ZzProbeCatalog { @(@{ name = 'Zz.Probe'; install = 'Install-ZzNoSuchApp' }) }`n"

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "Reference check failed: a catalog entry's 'install' field names function\(s\) that are not defined in the module and do not resolve as external cmdlets: Install-ZzNoSuchApp\."
    }

    It 'treats the names in build/windows-only-commands.txt as resolvable off Windows' -Skip:$IsWindows {
        $root = New-BuildFixture -Name 'allowlisted-call' -ProbeSource "function Test-ZzProbe { Get-ZzWindowsOnlyProbe }`n" -ExtraWindowsOnlyCommand 'Get-ZzWindowsOnlyProbe'

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'fails on Windows when a build/windows-only-commands.txt entry does not resolve there' -Skip:(-not $IsWindows) {
        $root = New-BuildFixture -Name 'allowlist-unresolvable' -ExtraWindowsOnlyCommand 'Get-ZzWindowsOnlyProbe'

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Allowlist check failed: build/windows-only-commands.txt lists name\(s\) that do not resolve as commands on Windows: Get-ZzWindowsOnlyProbe\.'
    }

    It 'warns, without failing, about a build/windows-only-commands.txt entry the installer no longer calls' {
        # Get-Random resolves on every platform and the installer never calls it.
        $root = New-BuildFixture -Name 'allowlist-stale' -ExtraWindowsOnlyCommand 'Get-Random'

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'no longer invokes: Get-Random'
    }

    It 'lists in build/windows-only-commands.txt only commands the generated installer calls and the module does not define' {
        $entries = @(Get-Content -Path $script:windowsOnlyCommandsPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallerScriptPath, [ref]$null, [ref]$null)
        $invoked = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        $defined = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })

        $entries.Count | Should -BeGreaterThan 0
        @($entries | Where-Object { $invoked -notcontains $_ }) | Should -BeNullOrEmpty
        @($entries | Where-Object { $defined -contains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'pre-commit hook checks the staged files (review finding P3-47)' {
    BeforeAll {
        # Git for Windows' sh.exe lives next to git; elsewhere sh is on PATH. Resolved here so a
        # machine without a POSIX shell skips these tests instead of failing them.
        $script:shPath = $null
        $gitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($IsWindows -and $gitCommand) {
            $gitShell = Join-Path (Split-Path -Parent (Split-Path -Parent $gitCommand.Source)) 'bin/sh.exe'
            if (Test-Path -LiteralPath $gitShell) { $script:shPath = $gitShell }
        }
        if (-not $script:shPath) {
            $shCommand = Get-Command -Name sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($shCommand) { $script:shPath = $shCommand.Source }
        }
        $script:hookPrerequisitesMissing = -not ($gitCommand -and $script:shPath)

        # A git repository holding the tracked build inputs and the hook, everything staged.
        function New-HookFixture {
            param ([Parameter(Mandatory = $true)][string]$Name)

            $root = New-BuildFixture -Name $Name -ExtraItem '.githooks', '.gitattributes'
            & git -C $root init --quiet 2>&1 | Out-Null
            & git -C $root add --all 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git add failed in $root" }
            $root
        }

        function Invoke-PreCommitHook {
            param ([Parameter(Mandatory = $true)][string]$Root)

            # The hook needs pwsh on PATH; put the running one first.
            $savedPath = $env:PATH
            $env:PATH = (Split-Path -Parent $script:currentPowerShell) + [System.IO.Path]::PathSeparator + $env:PATH
            Push-Location -LiteralPath $Root
            try {
                $output = & $script:shPath .githooks/pre-commit 2>&1
                $exitCode = $LASTEXITCODE
            }
            finally {
                Pop-Location
                $env:PATH = $savedPath
            }
            [pscustomobject]@{ ExitCode = $exitCode; Output = (ConvertTo-PlainOutput -Output $output) }
        }

        function Add-ModuleEdit {
            param ([Parameter(Mandatory = $true)][string]$Root)

            Add-Content -Path (Join-Path $Root 'WingetAppSetup/Private/SystemInfo.ps1') -Value '# pre-commit hook test edit'
        }
    }

    It 'blocks a module change staged without its rebuilt installer, then passes once the installer is staged' {
        if ($script:hookPrerequisitesMissing) { Set-ItResult -Skipped -Because 'git and a POSIX sh are required to run the hook'; return }
        $root = New-HookFixture -Name 'hook-unstaged-installer'
        Add-ModuleEdit -Root $root
        $build = Invoke-FixtureBuild -Root $root
        $build.ExitCode | Should -Be 0 -Because $build.Output
        & git -C $root add -- WingetAppSetup/Private/SystemInfo.ps1 2>&1 | Out-Null

        # The working tree is in sync; the staged installer is not. (Matched on the hook's own
        # lines: -Check's error is word-wrapped at the console width.)
        $blocked = Invoke-PreCommitHook -Root $root
        $blocked.ExitCode | Should -Not -Be 0 -Because $blocked.Output
        $blocked.Output | Should -Match 'pre-commit: drift check FAILED'
        $blocked.Output | Should -Match 'The check ran against the STAGED files'

        & git -C $root add -- winget-app-install.ps1 2>&1 | Out-Null
        $passed = Invoke-PreCommitHook -Root $root
        $passed.ExitCode | Should -Be 0 -Because $passed.Output
    }

    It 'passes when the staged files are in sync, even with an unstaged module edit in the working tree' {
        if ($script:hookPrerequisitesMissing) { Set-ItResult -Skipped -Because 'git and a POSIX sh are required to run the hook'; return }
        $root = New-HookFixture -Name 'hook-unstaged-edit'
        Add-ModuleEdit -Root $root

        $result = Invoke-PreCommitHook -Root $root

        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'Check passed'
    }
}
