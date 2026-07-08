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
        broken concatenation. Walking the assembled script's AST and confirming every hyphenated
        command resolves catches it at build time instead of at the user's prompt.

        Module-defined names are matched case-sensitively (ordinal) first. A call site that matches
        a module function only case-insensitively is reported as a build failure instead of falling
        through to Get-Command: module function names can differ from external cmdlets only by case
        (the module's Install-WingetPackage vs Microsoft.WinGet.Client's Install-WinGetPackage), so
        Get-Command could otherwise resolve the external cmdlet and mask a dropped or renamed module
        function behind a stale call site (issue #183).
    .PARAMETER Ast
        The parsed AST of the fully assembled installer.
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

    # Only hyphenated (Verb-Noun) names — this is how the module's own functions and PowerShell
    # cmdlets are named, and it excludes native commands (winget), keywords, and operators that
    # GetCommandName also returns.
    $invoked = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $_.Contains('-') } |
        Sort-Object -Unique

    foreach ($name in $invoked) {
        if ($definedExact.Contains($name)) { continue }
        if ($definedFolded.ContainsKey($name)) {
            "$name (case-insensitive collision with module function '$($definedFolded[$name])'; match the definition's casing at the call site)"
            continue
        }
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
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    # The .NET file APIs used below resolve relative paths against the process working directory,
    # which can differ from the PowerShell location; root the path explicitly so both agree.
    $OutputPath = Join-Path (Get-Location).ProviderPath $OutputPath
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
[void]$builder.AppendLine((Get-Content -Path (Join-Path $fragmentsRoot 'head.ps1') -Raw -Encoding UTF8).TrimEnd())

# 2. Generated banner
[void]$builder.AppendLine($banner)

# 3. Function bodies: Private first, then Public, each glob ordered for stable output.
#    Sort-Object compares linguistically, which varies across locales and ICU/NLS versions, so pin
#    the concatenation order with an ordinal (byte-wise) comparison that is identical everywhere.
$ordinalByName = [System.Comparison[object]] { param($a, $b) [System.StringComparer]::Ordinal.Compare($a.Name, $b.Name) }
$privateFiles = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Private') -Filter '*.ps1')
$publicFiles = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1')
[Array]::Sort($privateFiles, $ordinalByName)
[Array]::Sort($publicFiles, $ordinalByName)
$functionFiles = $privateFiles + $publicFiles

[void]$builder.AppendLine('')
[void]$builder.AppendLine('# ------------------------------------------------Functions------------------------------------------------')
[void]$builder.AppendLine('')

foreach ($file in $functionFiles) {
    [void]$builder.AppendLine("# --- $($file.BaseName) ---")
    [void]$builder.AppendLine((Get-Content -Path $file.FullName -Raw -Encoding UTF8).TrimEnd())
    [void]$builder.AppendLine('')
}

# 4. Tail (entry-point dispatch)
[void]$builder.AppendLine('# ------------------------------------------------Main Script------------------------------------------------')
[void]$builder.AppendLine('')
[void]$builder.AppendLine((Get-Content -Path (Join-Path $fragmentsRoot 'tail.ps1') -Raw -Encoding UTF8).TrimEnd())

# Normalize to LF line endings with a single trailing newline so the output is
# byte-identical across platforms. StringBuilder.AppendLine emits [Environment]::NewLine
# (CRLF on Windows, LF on Linux), and the source files may be checked out with CRLF under
# core.autocrlf, so collapse everything to LF here. The installer is stored with LF (see
# .gitattributes), keeping the -Check round-trip deterministic on Windows and Linux alike.
$content = (($builder.ToString() -replace "`r`n", "`n").TrimEnd()) + "`n"

# Fail fast on syntax errors (issue #183). Without this, a module file with an unbalanced brace
# would ship a broken installer: the reference guard would walk the truncated AST and pass, and
# -Check would pass because the on-disk file faithfully reproduces the same broken concatenation.
$parseErrors = $null
$assembledAst = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    $details = foreach ($parseError in $parseErrors) {
        "line $($parseError.Extent.StartLineNumber), column $($parseError.Extent.StartColumnNumber): $($parseError.Message)"
    }
    Write-Error ("Parse check failed: the assembled script has $($parseErrors.Count) syntax error(s). Fix the offending source file under WingetAppSetup/ or build/fragments/, then re-run the build.`n" + ($details -join "`n"))
    exit 1
}

# Fail fast on export drift (issue #191). The manifest's FunctionsToExport is the single export
# authority: winget-app-uninstall.ps1 imports the module via the psd1, so a Public function
# missing from that list is silently filtered at import time while Pester (which dot-sources the
# files) stays green. Assert the psd1 list EXACTLY equals the set of functions defined under
# WingetAppSetup/Public/*.ps1 so the mismatch fails the build (and -Check) instead.
$manifestPath = Join-Path $moduleRoot 'WingetAppSetup.psd1'
$declaredExports = @((Import-PowerShellDataFile -Path $manifestPath).FunctionsToExport)
$publicFunctionNames = @(foreach ($file in $publicFiles) {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $fileAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
            ForEach-Object { $_.Name }
    })
# Case-sensitive on purpose: a casing mismatch between the manifest and the definition is drift too.
$missingFromManifest = @($publicFunctionNames | Where-Object { $declaredExports -cnotcontains $_ })
$extraInManifest = @($declaredExports | Where-Object { $publicFunctionNames -cnotcontains $_ })
if ($missingFromManifest.Count -gt 0 -or $extraInManifest.Count -gt 0) {
    $details = @()
    if ($missingFromManifest.Count -gt 0) {
        $details += "defined under WingetAppSetup/Public but missing from FunctionsToExport: $($missingFromManifest -join ', ')"
    }
    if ($extraInManifest.Count -gt 0) {
        $details += "listed in FunctionsToExport but not defined under WingetAppSetup/Public: $($extraInManifest -join ', ')"
    }
    Write-Error ("Export check failed: WingetAppSetup.psd1 FunctionsToExport must exactly match the functions defined under WingetAppSetup/Public/*.ps1. " + ($details -join '; ') + '. Update the manifest (or move the function between Public/ and Private/), then re-run the build.')
    exit 1
}

# Fail fast on reference drift (issue #154). Enforced on Windows only: the installer relies on
# Windows-only cmdlets (Test-NetConnection, Get-ScheduledTask, the WinGet client module) that do
# not resolve via Get-Command on Linux/macOS and would false-positive there. The dev machine and CI
# are Windows, so this runs where it matters. Windows PowerShell 5.1 leaves $IsWindows unset but is
# always Windows, so treat pre-6 as Windows too.
if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
    $undefinedReferences = Get-UndefinedCommandReference -Ast $assembledAst
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
    # Get-Content -Raw silently strips a UTF-8 BOM, so a re-saved-with-BOM copy would pass a text
    # comparison while not being what the build produces. Reject a BOM explicitly; the build always
    # writes BOM-less UTF-8.
    $onDiskBytes = [System.IO.File]::ReadAllBytes($OutputPath)
    if ($onDiskBytes.Length -ge 3 -and $onDiskBytes[0] -eq 0xEF -and $onDiskBytes[1] -eq 0xBB -and $onDiskBytes[2] -eq 0xBF) {
        Write-Error "Check failed: '$OutputPath' starts with a UTF-8 BOM; the build writes BOM-less UTF-8. Re-run build/Build-WingetInstallScript.ps1 to regenerate it."
        exit 1
    }
    # Normalize the on-disk copy to LF before comparing; a Windows checkout with
    # core.autocrlf=true can present the file with CRLF even when it is in sync.
    $current = ((Get-Content -Path $OutputPath -Raw -Encoding UTF8) -replace "`r`n", "`n")
    if ($current -ne $content) {
        Write-Error "Check failed: '$OutputPath' is out of date. Re-run build/Build-WingetInstallScript.ps1."
        exit 1
    }
    Write-Host "Check passed: '$OutputPath' is up to date."
    exit 0
}

# Write BOM-less UTF-8 explicitly: under Windows PowerShell 5.1, Set-Content -Encoding UTF8 would
# prepend a BOM, which the -Check BOM guard above rejects on the next verification.
[System.IO.File]::WriteAllText($OutputPath, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "Generated '$OutputPath' from the WingetAppSetup module."
