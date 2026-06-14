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

# Normalize to a single trailing newline
$content = $builder.ToString().TrimEnd() + "`n"

if ($Check) {
    if (-not (Test-Path $OutputPath)) {
        Write-Error "Check failed: '$OutputPath' does not exist. Run the build to generate it."
        exit 1
    }
    $current = (Get-Content -Path $OutputPath -Raw)
    if ($current -ne $content) {
        Write-Error "Check failed: '$OutputPath' is out of date. Re-run build/Build-WingetInstallScript.ps1."
        exit 1
    }
    Write-Host "Check passed: '$OutputPath' is up to date."
    exit 0
}

Set-Content -Path $OutputPath -Value $content -Encoding UTF8 -NoNewline
Write-Host "Generated '$OutputPath' from the WingetAppSetup module."
