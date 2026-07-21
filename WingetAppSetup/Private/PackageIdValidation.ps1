<#
.SYNOPSIS
    Shared package-id shape validation, per CLAUDE.md's "Winget Notes" section.
.DESCRIPTION
    CLAUDE.md documents the exact regex a winget package id must satisfy before it is trusted (in
    catalog entries or in `winget list` output matching). This file is the single place that regex
    lives so Test-AppDefinitions (catalog load time) and Test-WingetPackageInstalled (runtime output
    matching) cannot drift apart on the pattern.
#>

# Exact pattern from CLAUDE.md ("Winget Notes"): publisher.product shape, each side starting with a
# word character and allowing word characters, dots, and hyphens after that.
$script:WingetPackageIdPattern = '^[\w][\w.\-]+\.[\w][\w.\-]+'

<#
.SYNOPSIS
    Returns whether a string has the publisher.product shape CLAUDE.md mandates for package ids.
.PARAMETER PackageId
    The candidate package id string.
#>
function Test-WingetPackageIdFormat {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PackageId
    )

    return $PackageId -match $script:WingetPackageIdPattern
}

<#
.SYNOPSIS
    Returns whether `winget list` output contains the given package id as a whole id token, not
    merely as a substring of a different (longer) id.
.DESCRIPTION
    A plain .Contains($PackageId) check against raw `winget list` text is an unanchored substring
    match: an installed id like 'Foo.BarBaz' contains 'Foo.Bar' as a pure substring, which would
    false-positive a "Foo.Bar is installed" verdict. CLAUDE.md's "Winget Notes" section mandates
    validating package ids with a regex before trusting winget output; this tightens the match by
    requiring that neither side of the matched substring continue with an id-shape character
    ([\w.\-], the same character class the CLAUDE.md pattern is built from), so a match can only
    land on a complete id token.
.PARAMETER Output
    The raw `winget list` stdout text to search.
.PARAMETER PackageId
    The winget package id being checked for.
#>
function Test-WingetListOutputContainsPackageId {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Output,

        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $escapedId = [regex]::Escape($PackageId)
    $boundaryPattern = "(?<![\w.\-])$escapedId(?![\w.\-])"
    return [regex]::IsMatch($Output, $boundaryPattern)
}
