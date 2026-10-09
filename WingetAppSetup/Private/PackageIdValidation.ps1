# The package-id pattern from CLAUDE.md ("Winget Notes"), in one place for the catalog check and the
# `winget list` matching.

# publisher.product, each side starting with a word character. Anchored at both ends, with \z
# rather than $ (which also matches before a final newline): it validates a whole id, so trailing
# text such as 'Google.Chrome --override /S' never reaches winget as extra switches (P3-49).
$script:WingetPackageIdPattern = '^[\w][\w.\-]+\.[\w][\w.\-]+\z'

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
    Returns whether `winget list` output contains the package id as a whole id, not as part of a
    longer one ('Foo.Bar' inside 'Foo.BarBaz' does not count).
.PARAMETER Output
    The `winget list` output.
.PARAMETER PackageId
    The package id to look for.
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
