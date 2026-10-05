# BuildGuards.Tests.ps1
# Tests for the guards in build/Build-WingetInstallScript.ps1 and for the .githooks/pre-commit
# drift check (review findings P3-46, P3-47 and P3-48), for both generated scripts, the installer and
# the uninstaller (wgt-gq8.43):
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

    # Copies what the build reads (build/, WingetAppSetup/, the committed installer and uninstaller)
    # into TestDrive and optionally plants an extra Private/ module file.
    function New-BuildFixture {
        param (
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$ProbeSource,
            [string[]]$ExtraWindowsOnlyCommand,
            [string[]]$ExtraItem
        )

        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($item in @('build', 'WingetAppSetup', 'winget-app-install.ps1', 'winget-app-uninstall.ps1') + $ExtraItem) {
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
        $result.Output | Should -Match "Reference check failed: a catalog entry's 'install' or 'postInstall' field names function\(s\) that are not defined in the module and do not resolve as external cmdlets: Install-ZzNoSuchApp\."
    }

    # Work-order item 38: a post-install hook named by a string is dispatched the same indirect way
    # (& $App.postInstall), so a renamed hook function must fail the build, not the install.
    It 'fails the build when a catalog postInstall field names a function the module does not define' {
        $root = New-BuildFixture -Name 'undefined-postinstall' -ProbeSource "function Get-ZzProbeCatalog { @(@{ name = 'Zz.Probe'; postInstall = 'Set-ZzNoSuchConfiguration' }) }`n"

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "Reference check failed: a catalog entry's 'install' or 'postInstall' field names function\(s\) that are not defined in the module and do not resolve as external cmdlets: Set-ZzNoSuchConfiguration\."
    }

    It 'accepts a catalog postInstall field that names a module function' {
        $root = New-BuildFixture -Name 'defined-postinstall' -ProbeSource "function Set-ZzProbeConfiguration { 'Configured' }`nfunction Get-ZzProbeCatalog { @(@{ name = 'Zz.Probe'; postInstall = 'Set-ZzProbeConfiguration' }) }`n"

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Be 0 -Because $result.Output
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

Describe 'Build id covers the whole generated script (review finding P3-12)' {
    BeforeAll {
        # Builds the fixture and returns the id the build stamped into its installer.
        function Get-FixtureBuildId {
            param ([Parameter(Mandatory = $true)][string]$Root)

            $result = Invoke-FixtureBuild -Root $Root
            $result.ExitCode | Should -Be 0 -Because $result.Output
            $installer = Get-Content -Raw -Encoding UTF8 -Path (Join-Path $Root 'winget-app-install.ps1')
            if ($installer -notmatch "\`$script:InstallerBuildId = '([^']+)'") { throw 'The fixture build stamped no build id.' }
            $Matches[1]
        }

        $script:unchangedBuildId = Get-FixtureBuildId -Root (New-BuildFixture -Name 'build-id-unchanged')
    }

    It 'changes the id when only build/fragments/<_> changes' -ForEach @('tail.ps1', 'head.ps1') {
        # Before P3-12 only the functions were hashed, so a fix to the entry dispatch shipped under
        # the same 'Installer build:' id as the code it fixed. The build keeps head.ps1's comments
        # (the script's help) and removes tail.ps1's, so tail.ps1 gets a code change.
        $root = New-BuildFixture -Name "build-id-$($_ -replace '\.ps1$', '')"
        $fragmentPath = Join-Path $root "build/fragments/$_"
        $fragment = Get-Content -Raw -Encoding UTF8 -Path $fragmentPath
        if ($_ -eq 'head.ps1') {
            $fragment = $fragment.Replace('param (', "# build id probe`nparam (")
        }
        else {
            $fragment = $fragment.TrimEnd() + "`n`$script:ZzBuildIdProbe = 1`n"
        }
        [System.IO.File]::WriteAllText($fragmentPath, $fragment)

        Get-FixtureBuildId -Root $root | Should -Not -Be $script:unchangedBuildId
    }

    It 'derives the id from the whole script with the id slots blanked, so it can be recomputed' {
        $installer = Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath
        $installer -match "\`$script:InstallerBuildId = '(?<version>[^+']+)\+(?<hash>[0-9a-f]{8})'" | Should -BeTrue
        $buildId = '{0}+{1}' -f $Matches.version, $Matches.hash
        $template = ($installer -replace "`r`n", "`n").Replace($buildId, '{{BUILD_ID}}')

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($template)) } finally { $sha256.Dispose() }

        ([System.BitConverter]::ToString($hash, 0, 4).Replace('-', '').ToLowerInvariant()) | Should -Be $Matches.hash
    }

    It 'fails the build when a source file contains the reserved build id placeholder' {
        $root = New-BuildFixture -Name 'build-id-placeholder' -ProbeSource "function Get-ZzProbeValue { '{{BUILD_ID}}' }`n"

        $result = Invoke-FixtureBuild -Root $root

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Build id check failed'
    }
}

Describe 'The generated installer leaves out the comments of the module and tail.ps1 (review finding P3-53)' {
    BeforeAll {
        . ([scriptblock]::Create((Import-BuildScriptFunction -Name 'Remove-PowerShellComment')))
        . ([scriptblock]::Create((Import-BuildScriptFunction -Name 'Get-CodeTokenSignature')))

        # The lines Remove-PowerShellComment keeps of -Source.
        function Get-StrippedLine {
            param ([Parameter(Mandatory = $true)][string]$Source)

            $result = Remove-PowerShellComment -Source $Source
            if ($null -eq $result) { throw 'The test snippet does not parse.' }
            $result.Text -split "`n"
        }

        # The module files in the order the build assembles them.
        function Get-ModuleFileInBuildOrder {
            foreach ($folder in 'Private', 'Public') {
                $files = @(Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot $folder) -Filter '*.ps1')
                [Array]::Sort($files, [System.Comparison[object]] { param($a, $b) [System.StringComparer]::Ordinal.Compare($a.Name, $b.Name) })
                $files
            }
        }
    }

    Context 'Remove-PowerShellComment' {
        It 'removes help blocks, whole-line comments and end-of-line comments with the spaces before them' {
            $source = "<#`n.SYNOPSIS`n    Help.`n#>`nfunction Get-ZzValue {`n    # Why.`n    `$a = 1   # trailing`n    <# block #>`n    return `$a`n}"

            Get-StrippedLine -Source $source | Should -Be @('function Get-ZzValue {', '    $a = 1', '    return $a', '}')
        }

        It 'keeps a # inside strings and regexes, and keeps #Requires' {
            $source = "#Requires -Version 5.1`n`$a = 'x # y'`n`$b = `"#{0}`" -f 1`n`$c = `$d -match '^#'"

            Get-StrippedLine -Source $source | Should -Be ($source -split "`n")
        }

        It 'keeps the lines of a here-string exactly, blank and comment-like ones included' {
            $source = "`$text = @'`n# not a comment`n`n`n<# nor this #>`n  `n'@`n`$next = 1"

            Get-StrippedLine -Source $source | Should -Be ($source -split "`n")
        }

        It 'collapses blank lines to one and drops them at the edges of a block' {
            $source = "function Get-ZzValue {`n`n    `$a = 1`n`n`n    # gone`n`n    `$b = 2`n`n}`n`n"

            Get-StrippedLine -Source $source | Should -Be @('function Get-ZzValue {', '    $a = 1', '', '    $b = 2', '}')
        }

        It 'removes only the comments that end their line' {
            # PowerShell reads $a<#c#>.Length as $a.Length, but $a .Length is an error.
            Get-StrippedLine -Source '$a<#c#>.Length' | Should -Be @('$a<#c#>.Length')
            Get-StrippedLine -Source '$x = 1 <#a#> <#b#>' | Should -Be @('$x = 1')
            Get-StrippedLine -Source "`$x = <#a#> 1 # b`n<# c`n#> `$y = 2" | Should -Be @('$x = <#a#> 1', '<# c', '#> $y = 2')
        }

        It 'keeps the line after a line continuation, so the continued command still ends there' {
            $source = "Write-Output 1 ```n    # ends the command`nWrite-Output 2"

            $lines = Get-StrippedLine -Source $source

            $lines | Should -Be @('Write-Output 1 `', '', 'Write-Output 2')
            Get-CodeTokenSignature -Source ($lines -join "`n") | Should -BeExactly (Get-CodeTokenSignature -Source $source)
        }

        It 'maps each line it keeps to the source line it came from' {
            $result = Remove-PowerShellComment -Source "# a`n# b`n`$x = 1`n`n# c`n`$y = 2"

            $result.Text | Should -BeExactly "`$x = 1`n`n`$y = 2"
            $result.SourceLine | Should -Be @(3, 4, 6)
        }

        It 'returns nothing for source that does not parse' {
            Remove-PowerShellComment -Source "function Get-ZzValue {`n    'x'" | Should -BeNullOrEmpty
        }
    }

    Context 'Get-CodeTokenSignature' {
        It 'is the same for code that differs only in comments, blank lines and indentation' {
            $a = "function Get-ZzValue {`n    # why`n    `$a = 1 # note`n`n`n    `$a`n}"
            $b = "function Get-ZzValue {`n`$a = 1`n`$a`n}"

            Get-CodeTokenSignature -Source $a | Should -BeExactly (Get-CodeTokenSignature -Source $b)
        }

        It 'differs when <Case>' -ForEach @(
            @{ Case = 'a token changes'; A = '$a = 1'; B = '$a = 2' }
            @{ Case = 'two lines are joined'; A = "Write-Output 1`nWrite-Output 2"; B = 'Write-Output 1 Write-Output 2' }
            @{ Case = 'a space comes between a variable and its index'; A = 'Write-Output $a[0]'; B = 'Write-Output $a [0]' }
        ) {
            Get-CodeTokenSignature -Source $B | Should -Not -BeExactly (Get-CodeTokenSignature -Source $A)
        }
    }

    Context 'The committed installer' {
        It 'has no comment between the start of the module functions and the entry block but the file markers' {
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($script:InstallerScriptPath, [ref]$tokens, [ref]$null)
            $comments = @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment })
            $start = @($comments | Where-Object { $_.Text -match '^# -+Functions-+$' })
            $end = @($comments | Where-Object { $_.Text -match '^# -+Main Script-+$' })
            $start.Count | Should -Be 1
            $end.Count | Should -Be 1

            $moduleComments = @($comments | Where-Object { $_.Extent.StartOffset -gt $start[0].Extent.StartOffset -and $_.Extent.StartOffset -lt $end[0].Extent.StartOffset })

            @($moduleComments | Where-Object { $_.Text -notmatch '^# --- \w+ ---$' } | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Text)" }) | Should -BeNullOrEmpty
            $moduleComments.Count | Should -Be @(Get-ModuleFileInBuildOrder).Count
        }

        It 'has no comment in the entry block from build/fragments/tail.ps1' {
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($script:InstallerScriptPath, [ref]$tokens, [ref]$null)
            $comments = @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment })
            $end = @($comments | Where-Object { $_.Text -match '^# -+Main Script-+$' })
            $end.Count | Should -Be 1

            @($comments | Where-Object { $_.Extent.StartOffset -gt $end[0].Extent.StartOffset } | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Text)" }) | Should -BeNullOrEmpty
        }

        It 'carries the code of build/fragments/tail.ps1, token for token' {
            $installer = (Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath) -replace "`r`n", "`n"
            $marker = [regex]::Match($installer, '(?m)^# -+Main Script-+$')
            $marker.Success | Should -BeTrue
            $tail = (Get-Content -Raw -Encoding UTF8 -Path (Join-Path $script:RepoRoot 'build/fragments/tail.ps1')) -replace "`r`n", "`n"

            Get-CodeTokenSignature -Source $installer.Substring($marker.Index + $marker.Length) | Should -BeExactly (Get-CodeTokenSignature -Source $tail)
        }

        It 'carries the code of every module file, token for token' {
            $installer = (Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath) -replace "`r`n", "`n"
            $end = $installer.IndexOf("`n# ------------------------------------------------Main Script")
            $markers = @([regex]::Matches($installer.Substring(0, $end), '(?m)^# --- (\w+) ---$'))
            $files = @(Get-ModuleFileInBuildOrder)
            @($markers | ForEach-Object { $_.Groups[1].Value }) | Should -Be @($files | ForEach-Object { $_.BaseName })

            $mismatched = for ($index = 0; $index -lt $files.Count; $index++) {
                $sectionStart = $markers[$index].Index + $markers[$index].Length
                $sectionEnd = if ($index + 1 -lt $markers.Count) { $markers[$index + 1].Index } else { $end }
                $source = (Get-Content -Raw -Encoding UTF8 -Path $files[$index].FullName) -replace "`r`n", "`n"
                if ((Get-CodeTokenSignature -Source $installer.Substring($sectionStart, $sectionEnd - $sectionStart)) -cne (Get-CodeTokenSignature -Source $source)) {
                    $files[$index].FullName
                }
            }
            @($mismatched) | Should -BeNullOrEmpty
        }
    }

    Context 'The module source' {
        It 'gives every function comment-based help that Get-Help can read' {
            # An unknown keyword (.RETURNS, or a line that starts with .NET) makes PowerShell ignore
            # the whole help block.
            $unreadable = foreach ($file in Get-ModuleFileInBuildOrder) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                    $help = $function.GetHelpContent()
                    if (-not $help -or -not $help.Synopsis) { '{0}: {1}' -f $file.Name, $function.Name }
                }
            }

            @($unreadable) | Should -BeNullOrEmpty
        }
    }

    Context 'Build and -Check' {
        It 'leaves the installer unchanged when only module comments change' {
            $root = New-BuildFixture -Name 'comment-only-change'
            $modulePath = Join-Path $root 'WingetAppSetup/Private/SystemInfo.ps1'
            $module = Get-Content -Raw -Encoding UTF8 -Path $modulePath
            $function = $module.IndexOf('function ')
            $module = $module.Insert($module.IndexOf('{', $function) + 1, "`n    # A comment inside a function.`n")
            [System.IO.File]::WriteAllText($modulePath, "# A new file comment.`n" + $module + "`n<# A trailing block comment. #>`n")

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Be 0 -Because $result.Output
        }

        It 'leaves the installer unchanged when only build/fragments/tail.ps1 comments change' {
            $root = New-BuildFixture -Name 'tail-comment-only-change'
            $tailPath = Join-Path $root 'build/fragments/tail.ps1'
            $tail = Get-Content -Raw -Encoding UTF8 -Path $tailPath
            $tail = $tail.Insert($tail.IndexOf('{') + 1, "`n    # A comment in the entry block.`n")
            [System.IO.File]::WriteAllText($tailPath, "# A new file comment.`n" + $tail.TrimEnd() + " # A trailing comment.`n")

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Be 0 -Because $result.Output
        }

        It 'fails the build when removing the comments would change the code' {
            # A stripper broken on purpose: it drops the code before an end-of-line comment too.
            $root = New-BuildFixture -Name 'comment-check' -ProbeSource "function Get-ZzProbeValue {`n    'kept' # note`n}`n"
            $buildPath = Join-Path $root 'build/Build-WingetInstallScript.ps1'
            $build = Get-Content -Raw -Encoding UTF8 -Path $buildPath
            $cut = '$text = $text.Substring(0, $cutAt[$line])'
            $build.Contains($cut) | Should -BeTrue
            [System.IO.File]::WriteAllText($buildPath, $build.Replace($cut, '$text = '''''))

            $result = Invoke-FixtureBuild -Root $root

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Comment check failed: removing the comments from WingetAppSetup/Private/\w+\.ps1 would change its code'
        }

        It 'compares the code tokens before and after removing the comments case-sensitively' {
            # A stripper broken on purpose: it changes the case of a string, which PowerShell's
            # -ne would not notice.
            $root = New-BuildFixture -Name 'comment-check-case' -ProbeSource "function Get-ZzProbeValue {`n    'zzprobe' # note`n}`n"
            $buildPath = Join-Path $root 'build/Build-WingetInstallScript.ps1'
            $build = Get-Content -Raw -Encoding UTF8 -Path $buildPath
            $join = 'Text       = $kept -join "`n"'
            $build.Contains($join) | Should -BeTrue
            [System.IO.File]::WriteAllText($buildPath, $build.Replace($join, 'Text       = ($kept -join "`n").Replace(''zzprobe'', ''ZZPROBE'')'))

            $result = Invoke-FixtureBuild -Root $root

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Comment check failed: removing the comments from WingetAppSetup/Private/ZzBuildGuardProbe\.ps1 would change its code'
        }

        It 'names the tail.ps1 line behind a 5.1 syntax finding in the entry block' {
            $root = New-BuildFixture -Name 'origin-tail-ps7-syntax'
            $tailPath = Join-Path $root 'build/fragments/tail.ps1'
            $tailLines = @((Get-Content -Raw -Encoding UTF8 -Path $tailPath) -replace "`r`n", "`n" -split "`n")
            $index = [Array]::FindIndex($tailLines, [Predicate[string]] { param($line) $line -match '^\s*if \(-not \(Test-FullLanguageMode\)\) \{$' })
            $index | Should -BeGreaterThan 1 -Because 'comment lines come before it in tail.ps1'
            $tailLines[$index] = "    `$zzProbe = `$env:ZZ_PROBE ?? 'fallback'`n" + $tailLines[$index]
            [System.IO.File]::WriteAllText($tailPath, ($tailLines -join "`n"))

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match ("'\?\?' \(QuestionQuestion\) \[build/fragments/tail\.ps1:{0}\]" -f ($index + 1))
        }

        It 'names the module file and line behind a 5.1 syntax finding' {
            $root = New-BuildFixture -Name 'origin-ps7-syntax' -ProbeSource "# One.`n# Two.`nfunction Get-ZzProbeValue { `$env:ZZ_PROBE ?? 'fallback' }`n"

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match "'\?\?' \(QuestionQuestion\) \[WingetAppSetup/Private/ZzBuildGuardProbe\.ps1:3\]"
        }

        It 'names the module file and line behind a syntax error' {
            $root = New-BuildFixture -Name 'origin-parse-error' -ProbeSource "# One.`nfunction Get-ZzProbeValue {`n    'x'`n"

            $result = Invoke-FixtureBuild -Root $root

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Parse check failed'
            $result.Output | Should -Match '\[WingetAppSetup/Private/ZzBuildGuardProbe\.ps1:2\]'
        }
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

        # A code change: the installer leaves out module comments, so a comment would not change it.
        function Add-ModuleEdit {
            param ([Parameter(Mandatory = $true)][string]$Root)

            Add-Content -Path (Join-Path $Root 'WingetAppSetup/Private/SystemInfo.ps1') -Value "function Get-ZzPreCommitProbe { 'pre-commit hook test edit' }"
        }
    }

    It 'blocks a module change staged without its rebuilt scripts, then passes once both are staged' {
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

        & git -C $root add -- winget-app-install.ps1 winget-app-uninstall.ps1 2>&1 | Out-Null
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

    It 'blocks a module change staged with the rebuilt installer but not the rebuilt uninstaller (wgt-gq8.43)' {
        if ($script:hookPrerequisitesMissing) { Set-ItResult -Skipped -Because 'git and a POSIX sh are required to run the hook'; return }
        $root = New-HookFixture -Name 'hook-unstaged-uninstaller'
        Add-ModuleEdit -Root $root
        $build = Invoke-FixtureBuild -Root $root
        $build.ExitCode | Should -Be 0 -Because $build.Output
        & git -C $root add -- WingetAppSetup/Private/SystemInfo.ps1 winget-app-install.ps1 2>&1 | Out-Null

        $blocked = Invoke-PreCommitHook -Root $root
        $blocked.ExitCode | Should -Not -Be 0 -Because $blocked.Output
        $blocked.Output | Should -Match 'pre-commit: drift check FAILED'

        & git -C $root add -- winget-app-uninstall.ps1 2>&1 | Out-Null
        $passed = Invoke-PreCommitHook -Root $root
        $passed.ExitCode | Should -Be 0 -Because $passed.Output
        $passed.Output | Should -Match 'Check passed: .*winget-app-uninstall\.ps1'
    }

    It 'checks a staged edit of the generated uninstaller alone (wgt-gq8.43)' {
        if ($script:hookPrerequisitesMissing) { Set-ItResult -Skipped -Because 'git and a POSIX sh are required to run the hook'; return }
        $root = New-HookFixture -Name 'hook-hand-edited-uninstaller'
        Add-Content -Path (Join-Path $root 'winget-app-uninstall.ps1') -Value "Write-Output 'edited by hand'"
        & git -C $root add -- winget-app-uninstall.ps1 2>&1 | Out-Null

        $blocked = Invoke-PreCommitHook -Root $root

        $blocked.ExitCode | Should -Not -Be 0 -Because $blocked.Output
        $blocked.Output | Should -Match 'pre-commit: drift check FAILED'
    }
}

Describe 'The generated uninstaller gets every guard the installer gets (wgt-gq8.43)' {
    BeforeAll {
        . ([scriptblock]::Create((Import-BuildScriptFunction -Name 'Get-CodeTokenSignature')))

        # A fixture whose build/fragments/uninstall-tail.ps1 has -Probe inserted before its first
        # statement, after the comment lines that open it; returns the root and the probe's line.
        function New-UninstallerTailFixture {
            param ([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Probe)

            $root = New-BuildFixture -Name $Name
            $tailPath = Join-Path $root 'build/fragments/uninstall-tail.ps1'
            $tailLines = @((Get-Content -Raw -Encoding UTF8 -Path $tailPath) -replace "`r`n", "`n" -split "`n")
            $index = [Array]::FindIndex($tailLines, [Predicate[string]] { param($line) $line -match '^\$exitCode = 5$' })
            $index | Should -BeGreaterThan 0 -Because 'comment lines come before it in uninstall-tail.ps1'
            $tailLines[$index] = "$Probe`n" + $tailLines[$index]
            [System.IO.File]::WriteAllText($tailPath, ($tailLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
            [pscustomobject]@{ Root = $root; Line = $index + 1 }
        }

        $script:committedUninstaller = (Get-Content -Raw -Encoding UTF8 -Path $script:UninstallerScriptPath) -replace "`r`n", "`n"
    }

    Context 'Build and -Check' {
        It 'fails on <Case> in build/fragments/uninstall-tail.ps1, naming the uninstaller and the tail line' -ForEach @(
            @{ Case = 'a syntax error'; Probe = 'function Get-ZzProbeValue {'; Expected = 'winget-app-uninstall\.ps1: Parse check failed'; NamesLine = $true }
            @{ Case = 'a non-ASCII code token'; Probe = "`$zzProbe = 'caf$([char]0x00E9)'"; Expected = 'winget-app-uninstall\.ps1: ASCII check failed: 1 non-comment token'; NamesLine = $true }
            @{ Case = 'PowerShell-7-only syntax'; Probe = "`$zzProbe = `$env:ZZ_PROBE ?? 'fallback'"; Expected = 'winget-app-uninstall\.ps1: PowerShell 5\.1 syntax check failed: 1 place'; NamesLine = $true }
            @{ Case = 'a call to a function the module does not define'; Probe = 'Invoke-ZzNoSuchHelper'; Expected = 'winget-app-uninstall\.ps1: Reference check failed: the generated script invokes command\(s\) that are not defined in the module and do not resolve as external cmdlets: Invoke-ZzNoSuchHelper\.'; NamesLine = $false }
            @{ Case = 'the reserved build id placeholder'; Probe = "`$zzProbe = '{{BUILD_ID}}'"; Expected = 'winget-app-uninstall\.ps1: Build id check failed'; NamesLine = $false }
        ) {
            $fixture = New-UninstallerTailFixture -Name ('uninstaller-tail-' + ($Case -replace '\W', '-')) -Probe $Probe

            $result = Invoke-FixtureBuild -Root $fixture.Root -Check

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match $Expected
            if ($NamesLine) {
                $result.Output | Should -Match ('\[build/fragments/uninstall-tail\.ps1:{0}\]' -f $fixture.Line)
            }
        }

        It 'checks that removing the comments from build/fragments/uninstall-tail.ps1 leaves its code as it was' {
            # A stripper broken on purpose: it changes the case of a string only the uninstaller's
            # tail holds.
            $fixture = New-UninstallerTailFixture -Name 'uninstaller-tail-comment-check' -Probe "`$zzProbe = 'zzprobe' # note"
            $buildPath = Join-Path $fixture.Root 'build/Build-WingetInstallScript.ps1'
            $build = Get-Content -Raw -Encoding UTF8 -Path $buildPath
            $join = 'Text       = $kept -join "`n"'
            $build.Contains($join) | Should -BeTrue
            [System.IO.File]::WriteAllText($buildPath, $build.Replace($join, 'Text       = ($kept -join "`n").Replace(''zzprobe'', ''ZZPROBE'')'))

            $result = Invoke-FixtureBuild -Root $fixture.Root

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Comment check failed: removing the comments from build/fragments/uninstall-tail\.ps1 would change its code'
        }

        It 'writes neither script when the uninstaller fails a guard' {
            $fixture = New-UninstallerTailFixture -Name 'uninstaller-tail-writes-nothing' -Probe 'Invoke-ZzNoSuchHelper'
            $installerPath = Join-Path $fixture.Root 'winget-app-install.ps1'
            $uninstallerPath = Join-Path $fixture.Root 'winget-app-uninstall.ps1'
            Set-Content -LiteralPath $installerPath -Value '# stale installer' -Encoding UTF8
            Set-Content -LiteralPath $uninstallerPath -Value '# stale uninstaller' -Encoding UTF8

            $result = Invoke-FixtureBuild -Root $fixture.Root

            $result.ExitCode | Should -Not -Be 0
            (Get-Content -Raw -LiteralPath $installerPath).Trim() | Should -Be '# stale installer'
            (Get-Content -Raw -LiteralPath $uninstallerPath).Trim() | Should -Be '# stale uninstaller'
        }

        It 'fails -Check when winget-app-uninstall.ps1 <Case>' -ForEach @(
            @{ Case = 'is out of date'; Change = 'Stale'; Expected = "winget-app-uninstall\.ps1' is out of date" }
            @{ Case = 'starts with a UTF-8 BOM'; Change = 'Bom'; Expected = "winget-app-uninstall\.ps1' starts with a UTF-8 BOM" }
            @{ Case = 'is missing'; Change = 'Missing'; Expected = "winget-app-uninstall\.ps1' does not exist" }
            # The compare is ordinal: -ne ignored case, and culture comparison ignores U+00AD, which
            # breaks the command name it sits in.
            @{ Case = 'differs from the build only in letter case'; Change = 'CaseOnly'; Find = '$global:LASTEXITCODE = 5'; Replace = '$GLOBAL:LASTEXITCODE = 5'; Expected = "winget-app-uninstall\.ps1' is out of date" }
            @{ Case = 'has a soft hyphen (U+00AD) typed into a command name'; Change = 'SoftHyphen'; Find = '(Test-IsAdmin)'; Replace = "(Test-Is$([char]0x00AD)Admin)"; Expected = "winget-app-uninstall\.ps1' is out of date" }
        ) {
            $root = New-BuildFixture -Name "uninstaller-check-$Change"
            $uninstallerPath = Join-Path $root 'winget-app-uninstall.ps1'
            switch ($Change) {
                'Stale' { Add-Content -LiteralPath $uninstallerPath -Value "Write-Output 'edited by hand'" }
                'Bom' { [System.IO.File]::WriteAllBytes($uninstallerPath, [byte[]](0xEF, 0xBB, 0xBF) + [System.IO.File]::ReadAllBytes($uninstallerPath)) }
                'Missing' { Remove-Item -LiteralPath $uninstallerPath }
                default {
                    # A hand edit: Find becomes Replace.
                    $text = [System.IO.File]::ReadAllText($uninstallerPath)
                    $text.Contains($Find) | Should -BeTrue
                    [System.IO.File]::WriteAllText($uninstallerPath, $text.Replace($Find, $Replace), [System.Text.UTF8Encoding]::new($false))
                }
            }

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match $Expected
            # The installer is still checked first, and is in sync.
            $result.Output | Should -Match "Check passed: '.*winget-app-install\.ps1' is up to date"
        }

        It 'leaves the uninstaller unchanged when only build/fragments/uninstall-tail.ps1 comments change' {
            $root = New-BuildFixture -Name 'uninstaller-tail-comment-only-change'
            $tailPath = Join-Path $root 'build/fragments/uninstall-tail.ps1'
            $tail = Get-Content -Raw -Encoding UTF8 -Path $tailPath
            $tail = $tail.Insert($tail.IndexOf('{') + 1, "`n    # A comment in the entry block.`n")
            [System.IO.File]::WriteAllText($tailPath, "# A new file comment.`n" + $tail.TrimEnd() + " # A trailing comment.`n")

            $result = Invoke-FixtureBuild -Root $root -Check

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match "Check passed: '.*winget-app-uninstall\.ps1' is up to date"
        }

        It 'refuses one path for both scripts' {
            $root = New-BuildFixture -Name 'same-output-path'
            $buildScript = (Join-Path $root 'build/Build-WingetInstallScript.ps1').Replace("'", "''")
            $target = (Join-Path $root 'both.ps1').Replace("'", "''")
            $command = "try { & '$buildScript' -OutputPath '$target' -UninstallerOutputPath '$target'; exit `$LASTEXITCODE } catch { [Console]::Out.WriteLine('BUILD ERROR: ' + `$_.Exception.Message); exit 1 }"

            $output = & $script:currentPowerShell -NoProfile -NonInteractive -Command $command 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Not -Be 0
            (ConvertTo-PlainOutput -Output $output) | Should -Match 'OutputPath and UninstallerOutputPath both name'
            Test-Path -LiteralPath (Join-Path $root 'both.ps1') | Should -BeFalse
        }
    }

    Context 'The committed uninstaller' {
        It 'starts with build/fragments/uninstall-head.ps1 as it is, and carries no build id' {
            $head = ((Get-Content -Raw -Encoding UTF8 -Path (Join-Path $script:RepoRoot 'build/fragments/uninstall-head.ps1')) -replace "`r`n", "`n").TrimEnd()

            $script:committedUninstaller.StartsWith($head + "`n") | Should -BeTrue
            # The module functions read $script:InstallerBuildId; only the installer's banner sets it.
            $script:committedUninstaller | Should -Not -Match '(?m)^\$script:InstallerBuildId = |^# Build id: |\{\{BUILD_ID\}\}'
            $script:committedUninstaller | Should -Match '(?m)^# GENERATED FILE - DO NOT EDIT BY HAND\.$'
            $script:committedUninstaller | Should -Match '(?m)^# build/fragments/uninstall-tail\.ps1, then re-run the build to regenerate this file\.$'
        }

        It 'carries the code of build/fragments/uninstall-tail.ps1, token for token, with no comment' {
            $marker = [regex]::Match($script:committedUninstaller, '(?m)^# -+Main Script-+$')
            $marker.Success | Should -BeTrue
            $entryBlock = $script:committedUninstaller.Substring($marker.Index + $marker.Length)
            $tail = (Get-Content -Raw -Encoding UTF8 -Path (Join-Path $script:RepoRoot 'build/fragments/uninstall-tail.ps1')) -replace "`r`n", "`n"

            Get-CodeTokenSignature -Source $entryBlock | Should -BeExactly (Get-CodeTokenSignature -Source $tail)
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($entryBlock, [ref]$tokens, [ref]$null)
            @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment }) | Should -BeNullOrEmpty
        }

        It 'carries the same module functions as the installer, between the same markers' {
            $installer = (Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath) -replace "`r`n", "`n"
            $functionsOf = {
                param ([string]$Text)
                $start = $Text.IndexOf("`n# ------------------------------------------------Functions")
                $end = $Text.IndexOf("`n# ------------------------------------------------Main Script")
                $start | Should -BeGreaterThan 0
                $end | Should -BeGreaterThan $start
                $Text.Substring($start, $end - $start)
            }

            & $functionsOf $script:committedUninstaller | Should -BeExactly (& $functionsOf $installer)
        }

        It 'has no syntax only PowerShell 7 parses' {
            . ([scriptblock]::Create((Import-BuildScriptFunction -Name 'Get-PowerShell7OnlySyntax')))
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:UninstallerScriptPath, [ref]$tokens, [ref]$parseErrors)

            $parseErrors | Should -BeNullOrEmpty
            Get-PowerShell7OnlySyntax -Ast $ast -Tokens $tokens | Should -BeNullOrEmpty
        }
    }
}
