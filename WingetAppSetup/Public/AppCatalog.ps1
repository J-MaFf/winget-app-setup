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
        (dispatched by Install-AppWithVerification instead of the generic winget path). This
        string is validated against the module's defined functions by
        build/Build-WingetInstallScript.ps1's Get-UndefinedCatalogInstallReference guard (issue
        #236) - if you add another field carrying a function name the same way (e.g.
        'uninstall', 'verify'), extend that guard to cover it too, or a stale/renamed function
        will pass every build check and only fail at runtime.
      - installerType: forwarded to Install-WingetPackage for machine-scope handling.
      - condition: scriptblock returning a boolean, evaluated once per run by Invoke-WingetInstall
        (Test-AppApplicability) before anything is installed, and the verdict used by both passes
        (review finding P3-34). Falsy means the app does not apply to this machine and is
        reported as Skipped (not applicable) instead of installed (issue #217). Fail open = attempt
        the install: a condition that throws or writes an error is warned about and treated as
        applicable, so a broken probe can never silently drop an app. A probe a condition calls
        must therefore throw when it has no answer, never return an empty or default value that
        reads as "does not apply" (Get-ComputerManufacturer, Get-OSArchitecture; review finding
        P3-33).
      - conditionDescription: short human-readable reason shown in the skip message, e.g.
        "Skipping: <id> (not applicable: <conditionDescription>)".
      - msixName: the app's MSIX package name. In a run for the whole PC (SYSTEM, or cross-user
        elevation), whether that package is provisioned for every user decides whether the app is
        installed, before and after the install, instead of `winget list`, which only sees the
        packages registered for the account running it (review finding P3-24).
    Add or remove apps HERE — never inline a copy of this list at a call site (the previous
    duplicates in Invoke-WingetInstall and winget-app-uninstall.ps1 had already drifted).
.RETURNS
    [array] of app-definition hashtables.
#>
function Get-DefaultAppCatalog {
    return @(
        @{name = '7zip.7zip' },
        @{name = 'GlavSoft.TightVNC' },
        # The manifest's only installer is x64, and Adobe supports only the 32-bit (x86) Reader on
        # Windows on ARM: on an ARM64 PC winget runs the x64 installer under emulation and it
        # fails, in both passes, on every run (review finding P3-32). Architecture-gated so an
        # ARM64 PC reports it Skipped (not applicable) with the reason instead.
        @{name = 'Adobe.Acrobat.Reader.64-bit'; condition = { (Get-OSArchitecture) -ne 'Arm64' }; conditionDescription = 'its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows' },
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
        # winget cannot reliably install/upgrade Microsoft.WindowsTerminal from a session that
        # Windows Terminal itself is hosting: doing so would require replacing files belonging to
        # the very console host rendering the session, which self-locks winget.exe's own launch
        # ("Access is denied" / "The file cannot be accessed by the system") instead of failing
        # transiently - retries never recover (issue #271: 5 launch attempts plus a full final
        # retry pass all failed identically in the reported E2E run, while every other catalog app
        # installed fine in the same run). Gated with the same condition mechanism as Dell Command
        # Update above (issue #217): evaluated before any winget probe runs, so the
        # structurally-doomed attempt is skipped instead of retried. A run as SYSTEM has no
        # Terminal session, so the check does not apply to it (review finding P3-24); a run for
        # the whole PC decides from msixName whether Terminal is provisioned for every user, as
        # Windows 11 provisions it, and defers it where winget has no machine-wide installer.
        @{name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal'; condition = { (Test-IsSystemAccount) -or -not (Test-WindowsTerminalHostsCurrentSession) }; conditionDescription = 'winget cannot self-update Windows Terminal from a session Windows Terminal itself is hosting (issue #271)' }
    )
}
