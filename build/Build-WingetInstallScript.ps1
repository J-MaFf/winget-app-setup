<#
.SYNOPSIS
    Generates the distributable single-file winget-app-install.ps1 and winget-app-uninstall.ps1
    from the WingetAppSetup module.
.DESCRIPTION
    The WingetAppSetup module (under WingetAppSetup/) is the source of truth. End users, however,
    run the installer either locally or via the documented `irm <url> | iex` one-liner, and both
    scripts relaunch themselves elevated as a checked copy of one file (review finding P3-11), so
    each needs a single self-contained script. For each, this build concatenates, in order:

        1. its head fragment          - the comment-based help and the param() block
        2. an auto-generated banner   - warns against hand-editing the output; the installer's also
                                        stamps the content-derived $script:InstallerBuildId (issue #189)
        3. WingetAppSetup/Private/*.ps1 then WingetAppSetup/Public/*.ps1 - every function, with
                                        its comments removed (Remove-PowerShellComment)
        4. its tail fragment          - the entry block, its comments removed too

    winget-app-install.ps1 is build/fragments/head.ps1 (with PSScriptInfo) and tail.ps1 around the
    module; winget-app-uninstall.ps1 is build/fragments/uninstall-head.ps1 and uninstall-tail.ps1
    around it. Every guard runs on both, and nothing is written unless both pass.

    The comments are left out because about half of the module is comments, which every
    irm | iex run would download (review finding P3-53); they stay in the source. The head
    fragments are kept as they are: they hold the scripts' help. A change to a comment in the
    module or in a tail fragment alone therefore leaves both scripts, and the installer's build id,
    unchanged.
.PARAMETER OutputPath
    Where to write the generated installer. Defaults to winget-app-install.ps1 at the repository root.
.PARAMETER UninstallerOutputPath
    Where to write the generated uninstaller. Defaults to winget-app-uninstall.ps1 in the folder of
    OutputPath (the repository root by default).
.PARAMETER Check
    When set, the scripts are generated in memory and compared against OutputPath and
    UninstallerOutputPath instead of overwriting them. Exits non-zero if either differs. Intended for
    CI / pre-commit verification.
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$UninstallerOutputPath,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

function Get-DefinedFunctionLookup {
    <#
    .SYNOPSIS
        Builds the case-sensitive and case-insensitive lookups of every function defined in the
        assembled script's AST, shared by the direct- and indirect-dispatch reference guards below.
    .PARAMETER Ast
        The parsed AST of a fully assembled script.
    .OUTPUTS
        A two-element array: [0] a case-sensitive (ordinal) HashSet[string] of defined names,
        [1] a case-insensitive Dictionary[string,string] mapping folded name -> defined name.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $defined = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
    $definedExact = [System.Collections.Generic.HashSet[string]]::new([string[]]$defined, [System.StringComparer]::Ordinal)
    $definedFolded = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($functionName in $defined) { $definedFolded[$functionName] = $functionName }

    return , @($definedExact, $definedFolded)
}

function Get-InvokedCommandName {
    <#
    .SYNOPSIS
        Returns the distinct hyphenated (Verb-Noun) command names the assembled script invokes
        directly, for the direct-dispatch reference guard and the Windows-only allowlist check.
    .DESCRIPTION
        Only hyphenated names: this is how the module's own functions and PowerShell cmdlets are
        named, and it excludes native commands (winget), keywords, and operators that
        GetCommandName also returns.
    .PARAMETER Ast
        The parsed AST of a fully assembled script.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $_.Contains('-') } |
        Sort-Object -Unique
}

function Get-WindowsOnlyCommandName {
    <#
    .SYNOPSIS
        Reads build/windows-only-commands.txt: the Windows-only commands the module invokes,
        which the undefined-reference guards treat as resolvable off Windows.
    .PARAMETER Path
        Path to the list. One command name per line; blank lines and lines starting with # are
        ignored.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Get-Content -Path $Path -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Get-PowerShell7OnlySyntax {
    <#
    .SYNOPSIS
        Returns the places where the assembled script uses syntax that PowerShell 7 parses and
        Windows PowerShell 5.1 does not.
    .DESCRIPTION
        Windows PowerShell 5.1 parses the whole installer before it runs any of it, so a single
        PowerShell-7-only construct anywhere in the file (even inside a function that only ever
        runs under pwsh) stops the irm | iex one-liner before the PowerShell 7 bootstrap in the tail
        can run (review finding P3-46). The parse guard cannot see this, because it uses the
        PowerShell 7 parser that the build itself runs on.

        Operators are found by token kind: ?? and ??= (QuestionQuestion, QuestionQuestionEquals),
        ?. and ?[ (QuestionDot, QuestionLBracket), the ternary ? (QuestionMark) and the && / ||
        pipeline-chain operators (AndAnd, OrOr). The tokenizer only emits these kinds for the
        operators themselves: the same characters inside a string, a comment or a regex are part
        of that string or comment token, and the Where-Object alias ? is a command-name token.
        Expandable strings carry the tokens of their $( ) subexpressions as nested tokens, so
        those are searched too. Kinds are compared by name because Windows PowerShell 5.1's
        TokenKind enum lacks most of them.

        clean { } blocks (PowerShell 7.3) are found in the AST instead: the Clean token kind also
        marks a class method named clean, which 5.1 accepts. ScriptBlockAst.CleanBlock does not
        exist under 5.1 and reads as $null there.

        So is the background operator & (PowerShell 6.0, as in 'Get-Process &'): its token kind,
        Ampersand, is also the call operator (& $exe, & { }), which 5.1 accepts.
        PipelineAst.Background is set only for a pipeline that ends in &, and does not exist
        under 5.1, where it reads as $null. The pipeline's extent stops before the &, so the
        report points at the first & token after it.
    .PARAMETER Ast
        The parsed AST of a fully assembled script.
    .PARAMETER Tokens
        The tokens the parser returned for the assembled script.
    .OUTPUTS
        One object per offending construct, with Line, Column, Text and Kind.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Token[]]$Tokens
    )

    $ps7OnlyTokenKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'QuestionMark', 'AndAnd', 'OrOr')

    $ampersandTokens = [System.Collections.Generic.List[System.Management.Automation.Language.Token]]::new()
    $pending = [System.Collections.Generic.Queue[System.Management.Automation.Language.Token]]::new()
    foreach ($token in $Tokens) { $pending.Enqueue($token) }
    while ($pending.Count -gt 0) {
        $token = $pending.Dequeue()
        if ($token -is [System.Management.Automation.Language.StringExpandableToken] -and $token.NestedTokens) {
            foreach ($nestedToken in $token.NestedTokens) { $pending.Enqueue($nestedToken) }
        }
        if ($token.Kind.ToString() -eq 'Ampersand') { $ampersandTokens.Add($token) }
        if ($ps7OnlyTokenKinds -contains $token.Kind.ToString()) {
            [pscustomobject]@{
                Line   = $token.Extent.StartLineNumber
                Column = $token.Extent.StartColumnNumber
                Text   = $token.Text
                Kind   = $token.Kind.ToString()
            }
        }
    }

    $cleanBlocks = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ScriptBlockAst] -and $node.CleanBlock }, $true)
    foreach ($scriptBlock in $cleanBlocks) {
        [pscustomobject]@{
            Line   = $scriptBlock.CleanBlock.Extent.StartLineNumber
            Column = $scriptBlock.CleanBlock.Extent.StartColumnNumber
            Text   = 'clean { }'
            Kind   = 'CleanBlock'
        }
    }

    $backgroundPipelines = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.PipelineAst] -and $node.Background }, $true)
    foreach ($pipeline in $backgroundPipelines) {
        $operator = $ampersandTokens |
            Where-Object { $_.Extent.StartOffset -ge $pipeline.Extent.EndOffset } |
            Sort-Object -Property { $_.Extent.StartOffset } |
            Select-Object -First 1
        $line = $pipeline.Extent.EndLineNumber
        $column = $pipeline.Extent.EndColumnNumber
        if ($operator) {
            $line = $operator.Extent.StartLineNumber
            $column = $operator.Extent.StartColumnNumber
        }
        [pscustomobject]@{
            Line   = $line
            Column = $column
            Text   = '&'
            Kind   = 'BackgroundOperator'
        }
    }
}

function Get-UndefinedName {
    <#
    .SYNOPSIS
        Shared name-resolution loop for the direct- and indirect-dispatch reference guards below:
        reports which of the given candidate names fail to resolve to a defined function or an
        external command.
    .DESCRIPTION
        Get-UndefinedCommandReference and Get-UndefinedCatalogInstallReference differ only in how
        they COLLECT candidate names from the AST (a direct CommandAst walk vs. an indirect
        catalog-hashtable walk); once collected, both resolved the same way. Factored out so a
        future change to resolution semantics (e.g. also checking Get-Alias, or narrowing the
        Get-Command fallback) cannot land in one guard and silently not the other.
    .PARAMETER Names
        Candidate hyphenated names to resolve (already deduplicated by the caller).
    .PARAMETER DefinedExact
        Case-sensitive (ordinal) HashSet[string] of function names defined in the assembled script,
        from Get-DefinedFunctionLookup.
    .PARAMETER DefinedFolded
        Case-insensitive Dictionary[string,string] of folded name -> defined name, from
        Get-DefinedFunctionLookup.
    .PARAMETER CollisionFixHint
        Short phrase naming where a case-insensitive collision should be fixed, used only in the
        reported collision message (e.g. "the definition's casing at the call site").
    .PARAMETER AssumeResolvable
        Case-insensitive set of command names to treat as resolvable without asking Get-Command:
        off Windows, the Windows-only commands from build/windows-only-commands.txt. Checked after
        the module lookups, so a case-insensitive collision with a module function is still
        reported. Empty on Windows.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$DefinedExact,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$DefinedFolded,
        [Parameter(Mandatory = $true)]
        [string]$CollisionFixHint,
        [System.Collections.Generic.HashSet[string]]$AssumeResolvable
    )

    foreach ($name in $Names) {
        if ($DefinedExact.Contains($name)) { continue }
        if ($DefinedFolded.ContainsKey($name)) {
            "$name (case-insensitive collision with module function '$($DefinedFolded[$name])'; match $CollisionFixHint)"
            continue
        }
        if ($AssumeResolvable -and $AssumeResolvable.Contains($name)) { continue }
        if (Get-Command -Name $name -ErrorAction SilentlyContinue) { continue }
        $name
    }
}

function Get-UndefinedCommandReference {
    <#
    .SYNOPSIS
        Returns Verb-Noun command invocations in the assembled script that are neither defined as a
        function within it nor resolvable as an external command.
    .DESCRIPTION
        Guards against reference drift: the entry-point fragments (build/fragments/{head,tail}.ps1)
        can invoke a module function that was never carried into WingetAppSetup/ — exactly how
        Test-SystemRequirements went missing and broke the one-liner (issue #154). The byte-for-byte
        -Check comparison cannot see this, because the on-disk file faithfully reproduces the same
        broken concatenation. Walking the assembled script's AST and confirming every hyphenated
        command resolves catches it at build time instead of at the user's prompt.

        Module-defined names are matched case-sensitively (ordinal) first. A call site that matches
        a module function only case-insensitively is reported as a build failure instead of falling
        through to Get-Command: module function names can differ from external cmdlets only by case
        (the module's Install-WingetPackage vs Microsoft.WinGet.Client's Install-WinGetPackage), so
        Get-Command could otherwise resolve the external cmdlet and mask a dropped or renamed module
        function behind a stale call site (issue #183).
    .PARAMETER Ast
        The parsed AST of a fully assembled script.
    .PARAMETER DefinedExact
        Case-sensitive (ordinal) HashSet[string] of function names defined in the assembled script,
        from Get-DefinedFunctionLookup.
    .PARAMETER DefinedFolded
        Case-insensitive Dictionary[string,string] of folded name -> defined name, from
        Get-DefinedFunctionLookup.
    .PARAMETER AssumeResolvable
        Passed through to Get-UndefinedName: the Windows-only command names to treat as
        resolvable off Windows.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$DefinedExact,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$DefinedFolded,
        [System.Collections.Generic.HashSet[string]]$AssumeResolvable
    )

    $invoked = Get-InvokedCommandName -Ast $Ast

    Get-UndefinedName -Names $invoked -DefinedExact $DefinedExact -DefinedFolded $DefinedFolded `
        -CollisionFixHint "the definition's casing at the call site" -AssumeResolvable $AssumeResolvable
}

function Get-UndefinedCatalogInstallReference {
    <#
    .SYNOPSIS
        Returns catalog 'install' and 'postInstall' function names (from Get-DefaultAppCatalog)
        that are neither defined as a function within the assembled script nor resolvable as an
        external command.
    .DESCRIPTION
        Get-UndefinedCommandReference walks CommandAst.GetCommandName(), which returns $null for an
        indirect invocation - the call operator `&` applied to a variable/member-expression rather
        than a literal command name. InstallVerification.ps1's Install-AppWithVerification does
        exactly this: `& $App.install`. The invoked name is carried as DATA in AppCatalog.ps1 (e.g.
        `install = 'Install-PowerShellLatest'`), not as code, so it is invisible to the AST-walk of
        CommandAst nodes above and a rename of the target function (updating its definition and its
        direct callers, but leaving the catalog string stale) passes every other guard and
        only breaks at runtime with a CommandNotFoundException the moment that one app is installed.

        This guard closes that blind spot by walking the assembled AST for HashtableAst key-value
        pairs whose key is the literal 'install' or 'postInstall' and whose value is a string
        literal (exactly the shape Get-DefaultAppCatalog's entries use), then validating each such
        string against the same defined-function lookups the direct-dispatch guard above uses.
        'postInstall' (work-order item 38) is the post-install hook, invoked the same indirect way
        by Invoke-AppPostInstall (`& $App.postInstall $App`); a scriptblock hook is code, which the
        direct-dispatch guard already sees. So no other hashtable in the module may give either key
        a string literal that is not a function name.

        Chosen over a Pester-only test (the spec's alternative) because it lives in the same
        AST-walking guard-stack as Get-UndefinedCommandReference right above it, runs on every build
        and -Check (not only when `Invoke-Pester ./tests` happens to be run), and reuses the same
        defined-function lookup - one guard family, one place to look when a reference-drift bug
        report comes in, per this repo's existing convention (issue #154 / #183).
    .PARAMETER Ast
        The parsed AST of a fully assembled script.
    .PARAMETER DefinedExact
        Case-sensitive (ordinal) HashSet[string] of function names defined in the assembled script,
        from Get-DefinedFunctionLookup.
    .PARAMETER DefinedFolded
        Case-insensitive Dictionary[string,string] of folded name -> defined name, from
        Get-DefinedFunctionLookup.
    .PARAMETER AssumeResolvable
        Passed through to Get-UndefinedName: the Windows-only command names to treat as
        resolvable off Windows.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$DefinedExact,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$DefinedFolded,
        [System.Collections.Generic.HashSet[string]]$AssumeResolvable
    )

    $hashtables = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)

    $installNames = foreach ($hashtable in $hashtables) {
        foreach ($pair in $hashtable.KeyValuePairs) {
            # StringConstantExpressionAst covers every key shape this guard needs: bare-word
            # hashtable keys (install = ...) parse as string constants with
            # StringConstantType.BareWord — there is no separate "bare word" Ast type. An
            # interpolated or computed key is not a constant the guard could resolve anyway,
            # so anything else is skipped.
            $keyAst = $pair.Item1
            if ($keyAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            if (@('install', 'postInstall') -notcontains $keyAst.Value) { continue }

            $valueAst = $pair.Item2
            if ($valueAst -is [System.Management.Automation.Language.PipelineAst] -and $valueAst.PipelineElements.Count -eq 1) {
                $valueAst = $valueAst.PipelineElements[0]
            }
            if ($valueAst -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $valueAst = $valueAst.Expression
            }
            if ($valueAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $valueAst.Value
            }
        }
    }
    $installNames = @($installNames | Sort-Object -Unique)

    Get-UndefinedName -Names $installNames -DefinedExact $DefinedExact -DefinedFolded $DefinedFolded `
        -CollisionFixHint "the catalog entry's casing to the definition" -AssumeResolvable $AssumeResolvable
}

function Remove-PowerShellComment {
    <#
    .SYNOPSIS
        Removes the comments from PowerShell source, for the generated installer (review finding
        P3-53).
    .DESCRIPTION
        Comments are the tokenizer's Comment tokens, so a # inside a string, a here-string or a
        regex stays, and so does #Requires, which is a statement. Only a comment that ends its line
        goes, with the spaces before it: PowerShell does not always read a comment that has code
        after it as a space (a block comment between $a and .Length still reads as $a.Length, and
        $a .Length is an error).

        A line the removal leaves empty is dropped. Outside strings, blank lines collapse to one,
        and none is kept at either end or just inside a { } or ( ) block. A line after a backtick
        line continuation is kept as it is, because dropping it would join the next line to the
        continued command.
    .PARAMETER Source
        The source text, with LF line endings.
    .OUTPUTS
        [pscustomobject] with Text (the source without comments) and SourceLine ([int[]]: for each
        line of Text, the line of Source it comes from), or $null when Source does not parse.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Source
    )

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        return $null
    }

    $lines = $Source -split "`n"
    $lineStarts = [int[]]::new($lines.Count)
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $lineStarts[$index] = $lineStarts[$index - 1] + $lines[$index - 1].Length + 1
    }

    # By line number: whether the line is string content (after the first line of a multi-line
    # string), and the column from which a removed comment takes the rest of the line.
    $inString = [bool[]]::new($lines.Count + 1)
    $cutAt = @{}
    $commentKind = [System.Management.Automation.Language.TokenKind]::Comment
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = $tokens[$index]
        $extent = $token.Extent
        if ($token -is [System.Management.Automation.Language.StringToken]) {
            for ($line = $extent.StartLineNumber + 1; $line -le $extent.EndLineNumber; $line++) { $inString[$line] = $true }
        }
        if ($token.Kind -ne $commentKind -or $token.Text -match '^#requires\s') {
            continue
        }
        $next = $index + 1
        while ($tokens[$next].Kind -eq $commentKind) { $next++ }
        if (@('NewLine', 'EndOfInput') -notcontains $tokens[$next].Kind.ToString()) {
            continue
        }

        $from = $extent.StartOffset
        $floor = $lineStarts[$extent.StartLineNumber - 1]
        if ($index -gt 0 -and $tokens[$index - 1].Extent.EndOffset -gt $floor) { $floor = $tokens[$index - 1].Extent.EndOffset }
        while ($from -gt $floor -and ($Source[$from - 1] -eq ' ' -or $Source[$from - 1] -eq "`t")) { $from-- }
        for ($line = $extent.StartLineNumber; $line -le $extent.EndLineNumber; $line++) {
            if (-not $cutAt.ContainsKey($line)) { $cutAt[$line] = [Math]::Max(0, $from - $lineStarts[$line - 1]) }
        }
    }

    $kept = [System.Collections.Generic.List[string]]::new()
    $keptLine = [System.Collections.Generic.List[int]]::new()
    # A kept line that must stay as it is: string content, or the line after a line continuation.
    $keptFixed = [System.Collections.Generic.List[bool]]::new()
    for ($line = 1; $line -le $lines.Count; $line++) {
        $text = $lines[$line - 1]
        if ($cutAt.ContainsKey($line)) {
            $text = $text.Substring(0, $cutAt[$line])
        }

        $last = $kept.Count - 1
        if ($inString[$line] -or ($last -ge 0 -and $kept[$last].EndsWith('`'))) {
            $kept.Add($text)
            $keptLine.Add($line)
            $keptFixed.Add($true)
            continue
        }
        if ($text.Trim().Length -eq 0) {
            if ($cutAt.ContainsKey($line) -or $last -lt 0) { continue }
            if (-not $keptFixed[$last] -and ($kept[$last].Length -eq 0 -or $kept[$last] -match '[{(]\s*$')) { continue }
            $text = ''
        }
        elseif ($text -match '^\s*[})]' -and $last -ge 0 -and $kept[$last].Length -eq 0 -and -not $keptFixed[$last]) {
            $kept.RemoveAt($last)
            $keptLine.RemoveAt($last)
            $keptFixed.RemoveAt($last)
        }
        $kept.Add($text)
        $keptLine.Add($line)
        $keptFixed.Add($false)
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Length -eq 0 -and -not $keptFixed[$kept.Count - 1]) {
        $kept.RemoveAt($kept.Count - 1)
        $keptLine.RemoveAt($keptLine.Count - 1)
        $keptFixed.RemoveAt($keptFixed.Count - 1)
    }

    [pscustomobject]@{
        Text       = $kept -join "`n"
        SourceLine = $keptLine.ToArray()
    }
}

function Get-CodeTokenSignature {
    <#
    .SYNOPSIS
        Returns the code of PowerShell source as one string of its tokens, to check that removing
        the comments changed nothing else.
    .DESCRIPTION
        Comments are left out and a run of line breaks counts as one. Each token records whether it
        touches the code token before it, since PowerShell reads $a[0] and $a [0], or $a.b and
        $a .b, differently. So two sources get the same signature only when they differ in nothing
        but comments, indentation, blank lines and the spaces around comments.
    .PARAMETER Source
        The source text.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Source
    )

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$parseErrors)
    $signature = [System.Text.StringBuilder]::new()
    $previous = $null
    $atLineBreak = $true
    foreach ($token in $tokens) {
        $kind = $token.Kind.ToString()
        if ($kind -eq 'Comment') {
            $previous = $token
            continue
        }
        if ($kind -eq 'NewLine' -or $kind -eq 'EndOfInput') {
            if (-not $atLineBreak) { [void]$signature.Append("`n") }
            $atLineBreak = $true
        }
        else {
            $atLineBreak = $false
            $touches = $previous -and $previous.Kind.ToString() -notin @('NewLine', 'LineContinuation', 'Comment') -and $previous.Extent.EndOffset -eq $token.Extent.StartOffset
            [void]$signature.AppendFormat('{0}{1}:{2}:{3} ', $(if ($touches) { '+' } else { '' }), $kind, $token.Text.Length, $token.Text)
        }
        $previous = $token
    }
    return $signature.ToString()
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repoRoot 'WingetAppSetup'

# The .NET file APIs used below resolve relative paths against the process working directory,
# which can differ from the PowerShell location; root the paths explicitly so both agree.
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'winget-app-install.ps1'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location).ProviderPath $OutputPath
}
if (-not $UninstallerOutputPath) {
    $UninstallerOutputPath = Join-Path (Split-Path -Parent $OutputPath) 'winget-app-uninstall.ps1'
}
elseif (-not [System.IO.Path]::IsPathRooted($UninstallerOutputPath)) {
    $UninstallerOutputPath = Join-Path (Get-Location).ProviderPath $UninstallerOutputPath
}
if ([System.IO.Path]::GetFullPath($OutputPath) -eq [System.IO.Path]::GetFullPath($UninstallerOutputPath)) {
    Write-Error "OutputPath and UninstallerOutputPath both name '$OutputPath'; give the installer and the uninstaller different paths."
    exit 1
}

# The assembled script, one entry per line, with where each line comes from ('<path>:<line>', or
# '' for the build's own lines), so the guards below can name the source line behind a problem:
# the line numbers of the assembled script match no file once the module's comments are removed.
# Emptied for each generated script.
$assembledLines = [System.Collections.Generic.List[string]]::new()
$lineOrigins = [System.Collections.Generic.List[string]]::new()

# Appends LF-separated text. -SourceLine maps each line to its line in -Path; without it the text
# is -Path's from line 1.
function Add-AssembledText {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Path,
        [int[]]$SourceLine
    )

    $textLines = $Text.Split("`n")
    for ($index = 0; $index -lt $textLines.Count; $index++) {
        $assembledLines.Add($textLines[$index])
        $origin = ''
        if ($Path) {
            $line = $index + 1
            if ($SourceLine) { $line = $SourceLine[$index] }
            $origin = '{0}:{1}' -f $Path, $line
        }
        $lineOrigins.Add($origin)
    }
}

# ' [<path>:<line>]': the source of a line of the assembled script, for a guard's report; '' for a
# line the build itself adds.
function Get-LineOrigin {
    param ([Parameter(Mandatory = $true)][int]$Line)

    if ($Line -ge 1 -and $Line -le $lineOrigins.Count -and $lineOrigins[$Line - 1]) {
        return ' [{0}]' -f $lineOrigins[$Line - 1]
    }
    return ''
}

# Source text with LF line endings (a checkout under core.autocrlf has CRLF) and no trailing space.
function Read-SourceText {
    param ([Parameter(Mandatory = $true)][string]$Path)

    ((Get-Content -Path $Path -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
}

# Each source file without its comments, by -Path, so a module file both scripts carry is
# stripped and checked once.
$strippedSources = @{}

# Appends a source file without its comments, -Path naming it in the guards' reports. Removing the
# comments must leave the code as it was, token for token (compared case-sensitively), or the build
# fails. A file that does not parse goes in as it is, and the parse guard below reports where.
function Add-SourceWithoutComment {
    param (
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not $strippedSources.ContainsKey($Path)) {
        $source = Read-SourceText -Path $FullName
        $stripped = Remove-PowerShellComment -Source $source
        if ($null -eq $stripped) {
            $strippedSources[$Path] = [pscustomobject]@{ Text = $source; SourceLine = $null }
        }
        else {
            if ((Get-CodeTokenSignature -Source $source) -cne (Get-CodeTokenSignature -Source $stripped.Text)) {
                Write-Error "Comment check failed: removing the comments from $Path would change its code. Move the comment that sits inside a statement in an unusual place (for example after a line continuation) onto a line of its own, then re-run the build."
                exit 1
            }
            $strippedSources[$Path] = $stripped
        }
    }
    Add-AssembledText -Text $strippedSources[$Path].Text -Path $Path -SourceLine $strippedSources[$Path].SourceLine
}

# The build id slot. The installer's banner carries this placeholder while the whole script is
# hashed, and the id replaces it afterwards (see New-GeneratedScriptContent, step 5).
$buildIdPlaceholder = '{{BUILD_ID}}'

$installerBanner = @'

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1,
# without the comments of the module and of the entry block below: read them in the source. Edit
# the function source under WingetAppSetup/Public and WingetAppSetup/Private, or the entry block in
# build/fragments/tail.ps1, then re-run the build to regenerate this file.
# See readme.md ("Project layout") for details.
# Build id: {{BUILD_ID}} (module version + SHA256 fragment of this whole script; issue #189).
# ------------------------------------------------------------------------------------------------

# Content-derived build identity, logged at startup so a transcript from a remote machine
# identifies exactly which installer build produced it (issue #189).
$script:InstallerBuildId = '{{BUILD_ID}}'
'@

# No build id: the uninstaller keeps no transcript to log one in, and its elevated relaunch checks
# the file's SHA256 instead.
$uninstallerBanner = @'

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1,
# without the comments of the module and of the entry block below: read them in the source. Edit
# the function source under WingetAppSetup/Public and WingetAppSetup/Private, or the entry block in
# build/fragments/uninstall-tail.ps1, then re-run the build to regenerate this file.
# See readme.md ("Project layout") for details.
# ------------------------------------------------------------------------------------------------
'@

# The generated scripts. BuildIdSlots is how often the banner holds the placeholder.
$targets = @(
    [pscustomobject]@{ Name = 'winget-app-install.ps1'; Head = 'build/fragments/head.ps1'; Tail = 'build/fragments/tail.ps1'; Banner = $installerBanner; BuildIdSlots = 2; OutputPath = $OutputPath }
    [pscustomobject]@{ Name = 'winget-app-uninstall.ps1'; Head = 'build/fragments/uninstall-head.ps1'; Tail = 'build/fragments/uninstall-tail.ps1'; Banner = $uninstallerBanner; BuildIdSlots = 0; OutputPath = $UninstallerOutputPath }
)

# Off Windows the Windows-only commands the module calls count as resolvable (see the reference
# guards in New-GeneratedScriptContent). Windows PowerShell 5.1 leaves $IsWindows unset but is
# always Windows, so treat pre-6 as Windows too.
$onWindows = $IsWindows -or $PSVersionTable.PSVersion.Major -lt 6
$windowsOnlyCommandsPath = Join-Path $PSScriptRoot 'windows-only-commands.txt'
$windowsOnlyCommands = @(Get-WindowsOnlyCommandName -Path $windowsOnlyCommandsPath)
$assumeResolvable = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$allowlistHint = ''
if (-not $onWindows) {
    foreach ($commandName in $windowsOnlyCommands) { [void]$assumeResolvable.Add($commandName) }
    $allowlistHint = ' If a name is a Windows-only cmdlet that cannot resolve on this platform, add it to build/windows-only-commands.txt; a Windows build then checks that it resolves there.'
}

function New-GeneratedScriptContent {
    <#
    .SYNOPSIS
        Assembles one generated script and runs the guards on it; a guard that fails ends the build.
    .PARAMETER Target
        An entry of $targets: Name, Head, Tail, Banner, BuildIdSlots.
    .OUTPUTS
        [pscustomobject] with Content (the script text, LF line endings) and InvokedCommandNames.
    #>
    param ([Parameter(Mandatory = $true)][pscustomobject]$Target)

    $assembledLines.Clear()
    $lineOrigins.Clear()
    # Every guard report names the script it is about.
    $label = "$($Target.Name): "

    # 1. Header (help + param), as it is.
    Add-AssembledText -Text (Read-SourceText -Path (Join-Path $repoRoot $Target.Head)) -Path $Target.Head

    # 2. Generated banner, with any build id slot left as the placeholder.
    Add-AssembledText -Text ($Target.Banner -replace "`r`n", "`n")

    # 3. Function bodies: Private first, then Public, each glob ordered for stable output.
    #    Sort-Object compares linguistically, which varies across locales and ICU/NLS versions, so pin
    #    the concatenation order with an ordinal (byte-wise) comparison that is identical everywhere.
    $ordinalByName = [System.Comparison[object]] { param($a, $b) [System.StringComparer]::Ordinal.Compare($a.Name, $b.Name) }
    $privateFiles = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Private') -Filter '*.ps1')
    $publicFiles = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1')
    [Array]::Sort($privateFiles, $ordinalByName)
    [Array]::Sort($publicFiles, $ordinalByName)
    $functionFiles = $privateFiles + $publicFiles

    Add-AssembledText -Text ''
    Add-AssembledText -Text '# ------------------------------------------------Functions------------------------------------------------'
    Add-AssembledText -Text ''

    foreach ($file in $functionFiles) {
        Add-AssembledText -Text "# --- $($file.BaseName) ---"
        Add-SourceWithoutComment -FullName $file.FullName -Path ('WingetAppSetup/{0}/{1}' -f $file.Directory.Name, $file.Name)
        Add-AssembledText -Text ''
    }

    # 4. Tail (the entry block), without its comments too.
    Add-AssembledText -Text '# ------------------------------------------------Main Script------------------------------------------------'
    Add-AssembledText -Text ''
    Add-SourceWithoutComment -FullName (Join-Path $repoRoot $Target.Tail) -Path $Target.Tail

    # LF line endings with a single trailing newline, so the output is byte-identical across
    # platforms. The scripts are stored with LF (see .gitattributes), keeping the -Check round-trip
    # deterministic on Windows and Linux alike.
    $contentTemplate = (($assembledLines -join "`n").TrimEnd()) + "`n"

    # The placeholder may appear only in the banner's slots: anywhere else in the sources, the
    # substitution below would rewrite that code too.
    $placeholderCount = ([regex]::Matches($contentTemplate, [regex]::Escape($buildIdPlaceholder))).Count
    if ($placeholderCount -ne $Target.BuildIdSlots) {
        Write-Error "$($label)Build id check failed: '$buildIdPlaceholder' is reserved for the installer's generated banner, but the sources under WingetAppSetup/ or build/fragments/ contain it too ($placeholderCount occurrences in total, expected $($Target.BuildIdSlots)). Remove it from the source, then re-run the build."
        exit 1
    }

    # 5. Content-derived build id (issue #189), for a banner with slots: <module version from the
    #    psd1>+<first 8 hex chars of the SHA256 of the whole assembled script, LF-normalized, with
    #    the id slots still holding the placeholder>. The whole script, not only the functions
    #    (review finding P3-12): a change to the param block, the help, or the entry dispatch in
    #    build/fragments/tail.ps1 (transcript, PowerShell 7 bootstrap, exit handling) must change
    #    the id too, or two different installers log the same 'Installer build:' line.
    #    Deterministic on purpose: rebuilding the same tree MUST produce a byte-identical script or
    #    the -Check verification in CI would always fail. Do NOT switch this to git describe, a
    #    commit SHA, or a timestamp - those change without the content changing (or vice versa) and
    #    would break the byte-compare. The tail logs the id at startup so a transcript from a remote
    #    machine identifies exactly which installer build produced it.
    $content = $contentTemplate
    if ($Target.BuildIdSlots -gt 0) {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $moduleRoot 'WingetAppSetup.psd1')
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $contentHash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($contentTemplate))
        }
        finally {
            $sha256.Dispose()
        }
        $hashFragment = [System.BitConverter]::ToString($contentHash, 0, 4).Replace('-', '').ToLowerInvariant()
        $buildId = '{0}+{1}' -f $manifest.ModuleVersion, $hashFragment
        $content = $contentTemplate.Replace($buildIdPlaceholder, $buildId)
    }

    # Fail fast on syntax errors (issue #183). Without this, a module file with an unbalanced brace
    # would ship a broken script: the reference guard would walk the truncated AST and pass, and
    # -Check would pass because the on-disk file faithfully reproduces the same broken concatenation.
    $parseErrors = $null
    $assembledTokens = $null
    $assembledAst = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$assembledTokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $details = foreach ($parseError in $parseErrors) {
            "line $($parseError.Extent.StartLineNumber), column $($parseError.Extent.StartColumnNumber): $($parseError.Message)$(Get-LineOrigin -Line $parseError.Extent.StartLineNumber)"
        }
        Write-Error ("$($label)Parse check failed: the assembled script has $($parseErrors.Count) syntax error(s). Fix the offending source file under WingetAppSetup/ or build/fragments/, then re-run the build.`n" + ($details -join "`n"))
        exit 1
    }

    # Fail fast on non-ASCII in code tokens (issue #210). Both scripts ship as BOM-less UTF-8, which
    # Windows PowerShell 5.1 decodes as ANSI: a multi-byte character inside a string literal
    # misdecodes into garbage, and some byte sequences terminate the string early (an em dash's 0x94
    # byte becomes a closing curly quote), cascading into dozens of parser errors before the
    # installer's PowerShell-7 bootstrap can run, or before the uninstaller (which runs under 5.1 in
    # its elevated window) runs at all. Keeping every NON-COMMENT token pure ASCII keeps the files
    # 5.1-PARSEABLE. Comment tokens are exempt: misdecoded bytes inside a comment cannot change
    # tokenization, so doc comments may keep typographic characters. Token-based and
    # platform-independent, so it runs in both build and -Check modes.
    $nonAsciiTokens = @($assembledTokens | Where-Object {
            $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -match '[^\x00-\x7F]'
        })
    if ($nonAsciiTokens.Count -gt 0) {
        $details = foreach ($token in $nonAsciiTokens) {
            $chars = ([regex]::Matches($token.Text, '[^\x00-\x7F]') | ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } | Select-Object -Unique) -join ', '
            "line $($token.Extent.StartLineNumber), column $($token.Extent.StartColumnNumber): $($token.Kind) token contains $chars$(Get-LineOrigin -Line $token.Extent.StartLineNumber)"
        }
        Write-Error ("$($label)ASCII check failed: $($nonAsciiTokens.Count) non-comment token(s) in the assembled script contain non-ASCII characters, which break Windows PowerShell 5.1 parsing of the BOM-less UTF-8 script (issue #210). Replace them with ASCII equivalents (em/en dash -> '-', curly quotes -> straight, ellipsis -> '...') in the offending source under WingetAppSetup/ or build/fragments/, then re-run the build.`n" + ($details -join "`n"))
        exit 1
    }

    # Fail fast on PowerShell-7-only syntax (review finding P3-46). The parse guard above uses the
    # parser of the PowerShell 7 running this build, so ??, ?., the ternary ?:, && / || and clean { }
    # all pass it, yet Windows PowerShell 5.1 rejects the whole file over any one of them: the
    # one-liner dies before the installer's PowerShell 7 bootstrap runs, and the uninstaller's
    # elevated Windows PowerShell window runs nothing. Token- and AST-based, so the same characters
    # inside strings, comments and regexes do not trip it; runs in both build and -Check modes on
    # every platform.
    $ps7OnlySyntax = @(Get-PowerShell7OnlySyntax -Ast $assembledAst -Tokens $assembledTokens | Sort-Object -Property Line, Column)
    if ($ps7OnlySyntax.Count -gt 0) {
        $details = foreach ($finding in $ps7OnlySyntax) {
            "line $($finding.Line), column $($finding.Column): '$($finding.Text)' ($($finding.Kind))$(Get-LineOrigin -Line $finding.Line)"
        }
        Write-Error ("$($label)PowerShell 5.1 syntax check failed: $($ps7OnlySyntax.Count) place(s) in the assembled script use syntax only PowerShell 7 parses. Windows PowerShell 5.1 parses the whole script before running any of it, so one of these anywhere breaks the irm | iex one-liner before the PowerShell 7 bootstrap can run, and the uninstaller's elevated run. Rewrite them in 5.1 syntax (if/else instead of ?? and ?:, an explicit `$null check instead of ?. and ?[, separate statements that test `$? or `$LASTEXITCODE instead of && and ||, end { } or try/finally instead of clean { }, Start-Job instead of a trailing &) in the offending source under WingetAppSetup/ or build/fragments/, then re-run the build.`n" + ($details -join "`n"))
        exit 1
    }

    # Fail fast on reference drift (issue #154), on every platform. The module calls Windows-only
    # cmdlets (Get-AppxPackage, Get-ScheduledTask, the WinGet client module, ...) that Get-Command
    # cannot resolve on Linux/macOS, so off Windows the names in build/windows-only-commands.txt
    # count as resolvable and every other name is checked exactly as on Windows. The guard used to be
    # skipped off Windows entirely, which let the #154 regression pass a Linux build, -Check and the
    # pre-commit hook (review finding P3-48). On Windows the list is not used to resolve anything,
    # and every entry must resolve there, so the list cannot hide a missing module function.
    $lookup = Get-DefinedFunctionLookup -Ast $assembledAst
    $definedExact, $definedFolded = $lookup[0], $lookup[1]

    $undefinedReferences = Get-UndefinedCommandReference -Ast $assembledAst -DefinedExact $definedExact -DefinedFolded $definedFolded -AssumeResolvable $assumeResolvable
    if ($undefinedReferences) {
        Write-Error ("$($label)Reference check failed: the generated script invokes command(s) that are not defined in the module and do not resolve as external cmdlets: $($undefinedReferences -join ', '). Add the missing function under WingetAppSetup/Public or WingetAppSetup/Private (or fix the calling fragment), then re-run the build." + $allowlistHint)
        exit 1
    }

    # Fail fast on catalog-carried indirect-dispatch drift (full-repo review finding, 2026-07-16).
    # See Get-UndefinedCatalogInstallReference's help for why GetCommandName() alone misses this.
    $undefinedCatalogInstallReferences = Get-UndefinedCatalogInstallReference -Ast $assembledAst -DefinedExact $definedExact -DefinedFolded $definedFolded -AssumeResolvable $assumeResolvable
    if ($undefinedCatalogInstallReferences) {
        Write-Error ("$($label)Reference check failed: a catalog entry's 'install' or 'postInstall' field names function(s) that are not defined in the module and do not resolve as external cmdlets: $($undefinedCatalogInstallReferences -join ', '). Fix the string in WingetAppSetup/Public/AppCatalog.ps1 (or add the missing function), then re-run the build.")
        exit 1
    }

    [pscustomobject]@{
        Content             = $content
        InvokedCommandNames = @(Get-InvokedCommandName -Ast $assembledAst)
    }
}

# Both scripts are assembled and checked before either is written or compared, so a guard that
# fails on one leaves both files as they were.
$builds = foreach ($target in $targets) {
    $generated = New-GeneratedScriptContent -Target $target
    [pscustomobject]@{ Target = $target; Content = $generated.Content; InvokedCommandNames = $generated.InvokedCommandNames }
}

# Keep build/windows-only-commands.txt honest. On Windows every entry must resolve, so a name
# cannot be listed to silence the guard off Windows; Windows CI runs this on every push and pull
# request. On every platform, an entry neither generated script invokes any more only widens what
# an off-Windows build assumes, so it is reported but does not fail the build.
if ($onWindows) {
    $unresolvableEntries = @($windowsOnlyCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($unresolvableEntries.Count -gt 0) {
        Write-Error ("Allowlist check failed: build/windows-only-commands.txt lists name(s) that do not resolve as commands on Windows: $($unresolvableEntries -join ', '). The list may only hold real Windows-only cmdlets that the module calls. Fix the spelling or remove the entry (a missing module function belongs under WingetAppSetup/), then re-run the build.")
        exit 1
    }
}
$invokedCommandNames = @($builds | ForEach-Object { $_.InvokedCommandNames })
$staleEntries = @($windowsOnlyCommands | Where-Object { $invokedCommandNames -notcontains $_ })
if ($staleEntries.Count -gt 0) {
    Write-Warning "build/windows-only-commands.txt lists command(s) that the code of the generated scripts no longer invokes: $($staleEntries -join ', '). Remove them so the list stays accurate."
}

if ($Check) {
    foreach ($build in $builds) {
        $path = $build.Target.OutputPath
        if (-not (Test-Path $path)) {
            Write-Error "Check failed: '$path' does not exist. Run the build to generate it."
            exit 1
        }
        # Get-Content -Raw silently strips a UTF-8 BOM, so a re-saved-with-BOM copy would pass a
        # text comparison while not being what the build produces. Reject a BOM explicitly; the
        # build always writes BOM-less UTF-8.
        $onDiskBytes = [System.IO.File]::ReadAllBytes($path)
        if ($onDiskBytes.Length -ge 3 -and $onDiskBytes[0] -eq 0xEF -and $onDiskBytes[1] -eq 0xBB -and $onDiskBytes[2] -eq 0xBF) {
            Write-Error "Check failed: '$path' starts with a UTF-8 BOM; the build writes BOM-less UTF-8. Re-run build/Build-WingetInstallScript.ps1 to regenerate it."
            exit 1
        }
        # Normalize the on-disk copy to LF before comparing; a Windows checkout with
        # core.autocrlf=true can present the file with CRLF even when it is in sync.
        $current = ((Get-Content -Path $path -Raw -Encoding UTF8) -replace "`r`n", "`n")
        # Ordinal: -ne ignores case, and culture comparison (with -cne too) ignores characters such
        # as U+00AD or U+200B, so a hand edit that only adds one would pass.
        if (-not [string]::Equals($current, $build.Content, [System.StringComparison]::Ordinal)) {
            Write-Error "Check failed: '$path' is out of date. Re-run build/Build-WingetInstallScript.ps1."
            exit 1
        }
        Write-Host "Check passed: '$path' is up to date."
    }
    exit 0
}

# Write BOM-less UTF-8 explicitly: under Windows PowerShell 5.1, Set-Content -Encoding UTF8 would
# prepend a BOM, which the -Check BOM guard above rejects on the next verification.
foreach ($build in $builds) {
    [System.IO.File]::WriteAllText($build.Target.OutputPath, $build.Content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Generated '$($build.Target.OutputPath)' from the WingetAppSetup module."
}
