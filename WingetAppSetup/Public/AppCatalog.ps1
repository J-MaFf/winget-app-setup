<#
.SYNOPSIS
    Returns the curated default application catalog shared by the installer and uninstaller.
.DESCRIPTION
    Single source of truth for the app list (issue #190). Invoke-WingetInstall consumes it as the
    default value of its -Apps parameter, and winget-app-uninstall.ps1 iterates the same catalog
    for removal. Each entry is a hashtable with at least:
      - name: the winget package id (validated by Test-AppDefinitions before use).
    Optional fields:
      - install: name of a package-specific install function that performs its own verification
        (dispatched by Install-AppWithVerification instead of the generic winget path).
      - installerType: forwarded to Install-WingetPackage for machine-scope handling.
      - condition: scriptblock returning a boolean — evaluated by Install-AppWithVerification
        BEFORE any winget probe. Falsy means the app does not apply to this machine and is
        reported as Skipped (not applicable) instead of installed (issue #217). Fail-open: a
        condition that throws is warned about and treated as applicable, so a broken probe can
        never silently drop an app.
      - conditionDescription: short human-readable reason shown in the skip message, e.g.
        "Skipping: <id> (not applicable: <conditionDescription>)".
    Add or remove apps HERE — never inline a copy of this list at a call site (the previous
    duplicates in Invoke-WingetInstall and winget-app-uninstall.ps1 had already drifted).
.RETURNS
    [array] of app-definition hashtables.
#>
function Get-DefaultAppCatalog {
    return @(
        @{name = '7zip.7zip' },
        @{name = 'GlavSoft.TightVNC' },
        @{name = 'Adobe.Acrobat.Reader.64-bit' },
        @{name = 'Google.Chrome' },
        @{name = 'Google.GoogleDrive' },
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        # Dell Command Update is useless on non-Dell hardware, and its DotNet Desktop Runtime
        # dependency cannot even install on Server-based images (0x8A150104 on GitHub-hosted
        # runners). Manufacturer-gated so non-Dell machines report it Skipped (not applicable)
        # instead of failing a pointless install (issue #217).
        @{name = 'Dell.CommandUpdate.Universal'; condition = { (Get-ComputerManufacturer) -match 'Dell' }; conditionDescription = 'Dell hardware only' },
        # PowerShell needs a version-agnostic install strategy (no pinning — always the latest):
        # winget installs PowerShell 7.6+ as an MSIX by default, which registers per-user and fails
        # to deploy in an elevated cross-user / machine-scope context ("The current system
        # configuration does not support the installation of this package"). Install-PowerShellLatest
        # prefers the MSI while it exists (<= 7.6), and once the MSI is gone (7.7+) installs the latest
        # MSIX machine-wide — natively on Windows 24H2+, or via DISM provisioning on older Windows
        # (issues #163/#166). It self-verifies, so the loop must not re-check it with `winget list`.
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
        @{name = 'Microsoft.WindowsTerminal' }
    )
}
