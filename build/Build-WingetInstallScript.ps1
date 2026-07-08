<#
.SYNOPSIS
    Generates the distributable single-file winget-app-install.ps1 from the WingetAppSetup module.
.DESCRIPTION
    The WingetAppSetup module (under WingetAppSetup/) is the source of truth. End users, however,
    run the installer either locally or via the documented `irm <url> | iex` one-liner, both of
    which need a single self-contained script. This build concatenates, in order:

        1. build/fragments/head.ps1   - PSScriptInfo, comment-based help, and the param() block
        2. an auto-generated banner   - warns against hand-editing the output and stamps the
                                        content-derived $script:InstallerBuildId (issue #189)
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

$builder = [System.Text.StringBuilder]::new()

# 1. Header (PSScriptInfo + help + param)
[void]$builder.AppendLine((Get-Content -Path (Join-Path $fragmentsRoot 'head.ps1') -Raw -Encoding UTF8).TrimEnd())

# 3. Function bodies (assembled before the banner because the build id below is derived from
#    them): Private first, then Public, each glob ordered for stable output.
#    Sort-Object compares linguistically, which varies across locales and ICU/NLS versions, so pin
#    the concatenation order with an ordinal (byte-wise) comparison that is identical everywhere.
$ordinalByName = [System.Comparison[object]] { param($a, $b) [System.StringComparer]::Ordinal.Compare($a.Name, $b.Name) }
$privateFiles = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Private') -Filter '*.ps1')
$publicFiles = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1')
[Array]::Sort($privateFiles, $ordinalByName)
[Array]::Sort($publicFiles, $ordinalByName)
$functionFiles = $privateFiles + $publicFiles

$functionsBuilder = [System.Text.StringBuilder]::new()
[void]$functionsBuilder.AppendLine('')
[void]$functionsBuilder.AppendLine('# ------------------------------------------------Functions------------------------------------------------')
[void]$functionsBuilder.AppendLine('')

foreach ($file in $functionFiles) {
    [void]$functionsBuilder.AppendLine("# --- $($file.BaseName) ---")
    [void]$functionsBuilder.AppendLine((Get-Content -Path $file.FullName -Raw -Encoding UTF8).TrimEnd())
    [void]$functionsBuilder.AppendLine('')
}

# Normalize to LF before hashing so the id is identical regardless of the checkout's line endings
# or the build platform (the final output gets the same normalization below).
$functionsSection = ($functionsBuilder.ToString() -replace "`r`n", "`n")

# 2. Generated banner, stamped with a content-derived build id (issue #189):
#    <module version from the psd1>+<first 8 hex chars of the SHA256 of the functions section>.
#    Deterministic on purpose: rebuilding the same tree MUST produce a byte-identical installer or
#    the -Check verification in CI would always fail. Do NOT switch this to git describe, a commit
#    SHA, or a timestamp - those change without the content changing (or vice versa) and would
#    break the byte-compare. The tail logs the id at startup so a transcript from a remote machine
#    identifies exactly which installer build produced it.
$manifestPath = Join-Path $moduleRoot 'WingetAppSetup.psd1'
$manifest = Import-PowerShellDataFile -Path $manifestPath
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $functionsHash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($functionsSection))
}
finally {
    $sha256.Dispose()
}
$hashFragment = [System.BitConverter]::ToString($functionsHash, 0, 4).Replace('-', '').ToLowerInvariant()
$buildId = '{0}+{1}' -f $manifest.ModuleVersion, $hashFragment

$banner = @'

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1.
# Edit the function source under WingetAppSetup/Public and WingetAppSetup/Private, then re-run the
# build to regenerate this file. See readme.md ("Project layout") for details.
# Build id: {{BUILD_ID}} (module version + SHA256 fragment of the function content; issue #189).
# ------------------------------------------------------------------------------------------------

# Content-derived build identity, logged at startup so a transcript from a remote machine
# identifies exactly which installer build produced it (issue #189).
$script:InstallerBuildId = '{{BUILD_ID}}'
'@
$banner = $banner.Replace('{{BUILD_ID}}', $buildId)

[void]$builder.AppendLine($banner)
[void]$builder.Append($functionsSection)

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
$assembledTokens = $null
$assembledAst = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$assembledTokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    $details = foreach ($parseError in $parseErrors) {
        "line $($parseError.Extent.StartLineNumber), column $($parseError.Extent.StartColumnNumber): $($parseError.Message)"
    }
    Write-Error ("Parse check failed: the assembled script has $($parseErrors.Count) syntax error(s). Fix the offending source file under WingetAppSetup/ or build/fragments/, then re-run the build.`n" + ($details -join "`n"))
    exit 1
}

# Fail fast on non-ASCII in code tokens (issue #210). The installer ships as BOM-less UTF-8, which
# Windows PowerShell 5.1 decodes as ANSI: a multi-byte character inside a string literal misdecodes
# into garbage, and some byte sequences terminate the string early (an em dash's 0x94 byte becomes
# a closing curly quote), cascading into dozens of parser errors before the tail's PowerShell-7
# fail-fast can run. Keeping every NON-COMMENT token pure ASCII keeps the file 5.1-PARSEABLE, so
# 5.1 reaches the version check and prints a real message. Comment tokens are exempt: misdecoded
# bytes inside a comment cannot change tokenization, so doc comments may keep typographic
# characters. Token-based and platform-independent, so it runs in both build and -Check modes.
$nonAsciiTokens = @($assembledTokens | Where-Object {
        $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -match '[^\x00-\x7F]'
    })
if ($nonAsciiTokens.Count -gt 0) {
    $details = foreach ($token in $nonAsciiTokens) {
        $chars = ([regex]::Matches($token.Text, '[^\x00-\x7F]') | ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } | Select-Object -Unique) -join ', '
        "line $($token.Extent.StartLineNumber), column $($token.Extent.StartColumnNumber): $($token.Kind) token contains $chars"
    }
    Write-Error ("ASCII check failed: $($nonAsciiTokens.Count) non-comment token(s) in the assembled script contain non-ASCII characters, which break Windows PowerShell 5.1 parsing of the BOM-less UTF-8 installer (issue #210). Replace them with ASCII equivalents (em/en dash -> '-', curly quotes -> straight, ellipsis -> '...') in the offending source under WingetAppSetup/ or build/fragments/, then re-run the build.`n" + ($details -join "`n"))
    exit 1
}

# Fail fast on export drift (issue #191). The manifest's FunctionsToExport is the single export
# authority: winget-app-uninstall.ps1 imports the module via the psd1, so a Public function
# missing from that list is silently filtered at import time while Pester (which dot-sources the
# files) stays green. Assert the psd1 list EXACTLY equals the set of functions defined under
# WingetAppSetup/Public/*.ps1 so the mismatch fails the build (and -Check) instead.
$declaredExports = @($manifest.FunctionsToExport)
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
