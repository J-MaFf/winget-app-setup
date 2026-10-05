<#
.SYNOPSIS
    Returns the curated default application catalog shared by the installer and uninstaller.
.DESCRIPTION
    Single source of truth for the app list (issue #190). Invoke-WingetInstall consumes it as the
    default value of its -Apps parameter, and Invoke-WingetUninstall (winget-app-uninstall.ps1)
    removes the same apps. Each entry is a hashtable with at least:
      - name: the winget package id (validated by Test-AppDefinitions before use).
    Optional fields:
      - install: name of a package-specific install function that performs its own verification
        (dispatched by Install-AppWithVerification instead of the generic winget path). This
        string is validated against the module's defined functions by
        build/Build-WingetInstallScript.ps1's Get-UndefinedCatalogInstallReference guard (issue
        #236), which covers postInstall too - if you add another field carrying a function name
        the same way (e.g. 'uninstall', 'verify'), extend that guard to cover it too, or a
        stale/renamed function will pass every build check and only fail at runtime.
      - installerType: forwarded to Install-WingetPackage for machine-scope handling.
      - condition: scriptblock returning a boolean, evaluated once per run by Invoke-WingetInstall
        (Test-AppApplicability) before anything is installed, and the verdict used by both passes
        (review finding P3-34). Falsy means the app does not apply to this machine and is
        reported as Skipped (not applicable) instead of installed (issue #217). Fail open = attempt
        the install: a condition that throws or writes an error is warned about and treated as
        applicable, so a broken probe can never silently drop an app. A probe a condition calls
        must therefore throw when it has no answer, never return an empty or default value that
        reads as "does not apply" (Get-ComputerManufacturer, Get-OSArchitecture; review finding
        P3-33). The uninstaller honours it too (Uninstall-CatalogApp, review finding P3-18): an
        installed app whose condition is falsy is not this tool's to remove.
      - conditionDescription: short human-readable reason shown in the skip message, e.g.
        "Skipping: <id> (not applicable: <conditionDescription>)", for the condition and the arch
        list alike (Get-AppNotApplicableReason). Without one, an arch skip says
        "for <arch list> Windows only; this PC is <architecture>" and a condition skip
        "condition not met".
      - msixName: the app's MSIX package name. In a run for the whole PC (SYSTEM, or cross-user
        elevation), whether that package is provisioned for every user decides whether the app is
        installed, before and after the install, instead of `winget list`, which only sees the
        packages registered for the account running it (review finding P3-24).
    The declarative fields (work-order item 38), all optional, checked by Test-AppDefinitions
    before a run uses them (a wrong value stops the run with exit code 3, and a field it does not
    know is a warning):
      - scope: 'machine', 'user' or 'any' (the default). 'any' is the behaviour of an entry without
        a scope: winget installs at machine scope, and falls back to its default scope when the
        package has no machine-scope installer, except in a run as SYSTEM or under cross-user
        elevation, which defers the app instead (Deferred). 'machine' never falls back, in any
        run: a package with no machine-scope installer fails (exit code 1) rather than being
        installed for one account or deferred. 'user' installs with `--scope user` in a run as the
        signed-in user, and is Deferred, before any winget call, in a run as SYSTEM or under
        cross-user elevation. A package-specific installer (install) gets -MachineScopeOnly for
        'machine', and -Scope when it declares that parameter. The scope is how the app is
        installed, not a condition on an install that is already there: an app `winget list`
        already shows for the account running the installer, at either scope, is skipped.
      - arch: the OS architectures the app is for, as Get-OSArchitecture names them ('X86', 'X64',
        'Arm', 'Arm64'; one string or a list). Part of the applicability decision
        (Test-AppApplicability), with the same fail-open rule: on another architecture the app is
        Skipped (not applicable). Get-OSArchitecture throws when it has no answer, and the app
        is then attempted. Note: e2e/Assert-Install.ps1 predicts the not-applicable skips from
        'condition' alone, so the Reader entries below keep their conditions until it uses
        Test-AppApplicability.
      - postInstall: a scriptblock, or the name of a function of this installer, that configures
        the app once it is installed (Invoke-AppPostInstall). It runs after the install is
        verified and on every run that finds the app already installed, so it must be idempotent:
        check the setting and change only what differs. It is called with the catalog entry as its
        one argument and returns 'Configured', or @{ Status = 'NotConfigured' or 'Failed'; Reason =
        '<why>' } (its last output is its result). Failed, a throw, an error it writes, or any other
        result makes the app Failed (exit code 1) with the reason, and the retry pass runs the hook
        again. NotConfigured leaves the app installed, prints its own line under the summary and
        does not change the exit code. The result is in the app's run record (postInstall,
        postInstallReason). It runs in the run's account (SYSTEM in an RMM run), never in a dry
        run, and never for an app that was not installed. GlavSoft.TightVNC's hook
        (Set-TightVncServerPassword) sets the server and control passwords.
      - userPhase: $true marks an app or setting that needs the signed-in user's own account (for
        example a hook that writes the user's settings). A run as SYSTEM or under cross-user
        elevation defers it, before any winget call; any other run installs it as usual.
    A deferred app counts neither as installed nor as failed. Its run record says why: no
    machine-wide installer, catalog scope 'user', or catalog userPhase (Get-AppDeferReasonText), so
    a later run as the signed-in user can pick it up from last-run.json.
    Add or remove apps HERE — never inline a copy of this list at a call site (the previous
    duplicates in Invoke-WingetInstall and winget-app-uninstall.ps1 had already drifted).
.RETURNS
    [array] of app-definition hashtables.
#>
function Get-DefaultAppCatalog {
    return @(
        @{name = '7zip.7zip' },
        # TightVNC Server installs with no password, so it refused every viewer, and with no control
        # password any signed-in user could reconfigure it from its tray icon (review finding P2-22).
        # The hook sets both from WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and
        # WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD), or from a prompt at the start of an
        # interactive run, never from this public repo (WingetAppSetup/Private/TightVnc.ps1).
        # Without a password TightVNC is reported installed but NOT configured.
        @{name = 'GlavSoft.TightVNC'; postInstall = 'Set-TightVncServerPassword' },
        # One Adobe Reader per PC, chosen by the OS architecture (review finding P3-32). The 64-bit
        # package's only installer is x64, and Adobe supports only the 32-bit (x86) Reader on
        # Windows on ARM: on an ARM64 PC winget ran the x64 installer under emulation and it
        # failed, in both passes, on every run. So ARM64 PCs get the 32-bit package (x86, machine
        # scope, run under emulation) and every other PC the 64-bit one; the other entry reports
        # Skipped (not applicable) with its reason. The two conditions are exact opposites, so
        # exactly one applies; only if Get-OSArchitecture threw (when .NET reports no architecture)
        # would both fail open and be attempted.
        @{name = 'Adobe.Acrobat.Reader.64-bit'; condition = { (Get-OSArchitecture) -ne 'Arm64' }; conditionDescription = 'its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows' },
        @{name = 'Adobe.Acrobat.Reader.32-bit'; condition = { (Get-OSArchitecture) -eq 'Arm64' }; conditionDescription = 'ARM64 Windows only; other PCs get the 64-bit Reader' },
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
