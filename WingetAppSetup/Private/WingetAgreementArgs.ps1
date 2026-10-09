<#
.SYNOPSIS
    Returns the agreement and interactivity flags every winget install and download call passes.
.DESCRIPTION
    One list, so no call site can leave out --disable-interactivity again (issue #230). Only for
    install and download: the winget source subcommands other than 'source add' reject
    --accept-source-agreements (0x8A150002, issues #174/#175), and search and list pass their own.
.OUTPUTS
    [string[]] '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity'
#>
function Get-WingetAgreementArgs {
    [CmdletBinding()]
    param ()

    return @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
}
