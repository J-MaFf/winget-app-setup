<#
.SYNOPSIS
    Returns the shared agreement/interactivity flag set used by every winget install-family call.
.DESCRIPTION
    `--accept-source-agreements --accept-package-agreements --disable-interactivity` was hand-
    duplicated across three call sites (Install-WingetPackage, Install-MsixProvisionedPackage, and
    the PowerShell 7 bootstrap's winget install). That duplication is exactly how issue #230
    shipped: one of the three literal arrays was missing `--disable-interactivity`, and it went
    unnoticed until winget stopped on the one code path every install takes and asked a human that
    was never watching. Routing all three call sites through this single helper makes that class of
    bug structurally impossible - there is only one place left to forget the flag.

    This is deliberately scoped to the install/download flag combination, not a generic wrapper for
    every winget subcommand: none of the `winget source` subcommands except `source add` accepts
    `--accept-source-agreements` (`source update`, issues #174/#175; `source list` and
    `source reset` reject it the same way, with 0x8A150002), and `search` and `list` pass their own
    subset. Callers with those different needs keep building their own argument lists.
.RETURNS
    [string[]] @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
#>
function Get-WingetAgreementArgs {
    [CmdletBinding()]
    param ()

    return @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
}
