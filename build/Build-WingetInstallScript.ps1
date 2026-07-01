<#
.SYNOPSIS
    Generates the distributable single-file winget-app-install.ps1 from the WingetAppSetup module.
.DESCRIPTION
    The WingetAppSetup module (under WingetAppSetup/) is the source of truth. End users, however,
    run the installer either locally or via the documented `irm <url> | iex` one-liner, both of
    which need a single self-contained script. This build concatenates, in order:

        1. build/fragments/head.ps1   - PSScriptInfo, comment-based help, and the param() block
        2. an auto-generated banner   - warns against hand-editing the output
        3. WingetAppSetup/Private/*.ps1 then WingetAppSetup/Public/*.ps1 - every function, verbatim
        4. build/fragments/tail.ps1   - the `if ($MyInvocation.InvocationName -ne '.')` dispatch block

    The result is byte-for-byte behaviour-equivalent to the pre-refactor monolith: it keeps the
    correct $PSScriptRoot / $PSCommandPath / IEX-detection semantics that the module form cannot
    provide on its own.
.PARAMETER OutputPath
    Where to write the generated script. Defaults to winget-app-install.ps1 at the repository root.
.PARAMETER Check
    When set, the script is generated to a temporary file and compared against OutputPath instead of
    overwriting it. Exits non-zero if they differ. Intended for CI / pre-commit verification.
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

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
        broken concatenation. Parsing the assembled script and confirming every hyphenated command
        resolves catches it at build time instead of at the user's prompt.
    .PARAMETER ScriptContent
        The fully assembled installer text to validate.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptContent
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($ScriptContent, [ref]$null, [ref]$null)

    $defined = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
    $definedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$defined, [System.StringComparer]::OrdinalIgnoreCase)

    # Only hyphenated (Verb-Noun) names — this is how the module's own functions and PowerShell
    # cmdlets are named, and it excludes native commands (winget), keywords, and operators that
    # GetCommandName also returns.
    $invoked = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $_.Contains('-') } |
        Sort-Object -Unique

    foreach ($name in $invoked) {
        if ($definedSet.Contains($name)) { continue }
        if (Get-Command -Name $name -ErrorAction SilentlyContinue) { continue }
        $name
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repoRoot 'WingetAppSetup'
$fragmentsRoot = Join-Path $PSScriptRoot 'fragments'

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'winget-app-install.ps1'
}

$banner = @'

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1.
# Edit the function source under WingetAppSetup/Public and WingetAppSetup/Private, then re-run the
# build to regenerate this file. See readme.md ("Project layout") for details.
# ------------------------------------------------------------------------------------------------
'@

$builder = [System.Text.StringBuilder]::new()

# 1. Header (PSScriptInfo + help + param)
[void]$builder.AppendLine((Get-Content -Path (Join-Path $fragmentsRoot 'head.ps1') -Raw).TrimEnd())

# 2. Generated banner
[void]$builder.AppendLine($banner)

# 3. Function bodies: Private first, then Public, each glob ordered for stable output
$functionFiles = @(
    Get-ChildItem -Path (Join-Path $moduleRoot 'Private') -Filter '*.ps1' | Sort-Object Name
    Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1' | Sort-Object Name
)

[void]$builder.AppendLine('')
[void]$builder.AppendLine('# ------------------------------------------------Functions------------------------------------------------')
[void]$builder.AppendLine('')

foreach ($file in $functionFiles) {
    [void]$builder.AppendLine("# --- $($file.BaseName) ---")
    [void]$builder.AppendLine((Get-Content -Path $file.FullName -Raw).TrimEnd())
    [void]$builder.AppendLine('')
}

# 4. Tail (entry-point dispatch)
[void]$builder.AppendLine('# ------------------------------------------------Main Script------------------------------------------------')
[void]$builder.AppendLine('')
[void]$builder.AppendLine((Get-Content -Path (Join-Path $fragmentsRoot 'tail.ps1') -Raw).TrimEnd())

# Normalize to LF line endings with a single trailing newline so the output is
# byte-identical across platforms. StringBuilder.AppendLine emits [Environment]::NewLine
# (CRLF on Windows, LF on Linux), and the source files may be checked out with CRLF under
# core.autocrlf, so collapse everything to LF here. The installer is stored with LF (see
# .gitattributes), keeping the -Check round-trip deterministic on Windows and Linux alike.
$content = (($builder.ToString() -replace "`r`n", "`n").TrimEnd()) + "`n"

# Fail fast on reference drift (issue #154). Enforced on Windows only: the installer relies on
# Windows-only cmdlets (Test-NetConnection, Get-ScheduledTask, the WinGet client module) that do
# not resolve via Get-Command on Linux/macOS and would false-positive there. The dev machine and CI
# are Windows, so this runs where it matters. Windows PowerShell 5.1 leaves $IsWindows unset but is
# always Windows, so treat pre-6 as Windows too.
if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
    $undefinedReferences = Get-UndefinedCommandReference -ScriptContent $content
    if ($undefinedReferences) {
        Write-Error ("Reference check failed: the generated script invokes command(s) that are not defined in the module and do not resolve as external cmdlets: $($undefinedReferences -join ', '). Add the missing function under WingetAppSetup/Public or WingetAppSetup/Private (or fix the calling fragment), then re-run the build.")
        exit 1
    }
}
else {
    Write-Host 'Skipping undefined-reference check: Windows-only cmdlets are unavailable on this platform.'
}

if ($Check) {
    if (-not (Test-Path $OutputPath)) {
        Write-Error "Check failed: '$OutputPath' does not exist. Run the build to generate it."
        exit 1
    }
    # Normalize the on-disk copy to LF before comparing; a Windows checkout with
    # core.autocrlf=true can present the file with CRLF even when it is in sync.
    $current = ((Get-Content -Path $OutputPath -Raw) -replace "`r`n", "`n")
    if ($current -ne $content) {
        Write-Error "Check failed: '$OutputPath' is out of date. Re-run build/Build-WingetInstallScript.ps1."
        exit 1
    }
    Write-Host "Check passed: '$OutputPath' is up to date."
    exit 0
}

Set-Content -Path $OutputPath -Value $content -Encoding UTF8 -NoNewline
Write-Host "Generated '$OutputPath' from the WingetAppSetup module."
