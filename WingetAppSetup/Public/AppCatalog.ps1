<#
.SYNOPSIS
    Returns the app catalog the installer and the uninstaller share.
.DESCRIPTION
    The one list of apps (issue #190): add or remove apps here, never in a copy at a call site.
    Invoke-WingetInstall installs it and Invoke-WingetUninstall removes it. Test-AppDefinitions
    checks every entry before a run uses it: a wrong value stops the run with exit code 3, and an
    unknown field is a warning. Each entry is a hashtable:
      - name: the winget package id. Required.
      - install: a module function that installs and verifies the app itself, instead of winget.
        The build's Get-UndefinedCatalogInstallReference guard checks this name and a string
        postInstall; extend it for any new field that names a function.
      - installerType: passed to Install-WingetPackage.
      - condition: a scriptblock, decided once per run before anything is installed
        (Test-AppApplicability); false makes the app Skipped (not applicable). It fails open: a
        condition that throws or writes an error is warned about and the app is attempted, so a
        probe it calls must throw, never return an empty value, when it has no answer. The
        uninstaller leaves an app that does not apply alone.
      - conditionDescription: the reason shown when the condition or the arch list skips the app.
      - msixName: the app's MSIX package name. In a run for the whole PC (SYSTEM or cross-user
        elevation), whether it is provisioned for every user decides whether the app is installed,
        since `winget list` sees only the running account's packages.
      - scope: 'any' (the default), 'machine' or 'user'. 'any' installs at machine scope and falls
        back to winget's default scope, except as SYSTEM or under cross-user elevation, where the app
        is Deferred instead. 'machine' never falls back: no machine-scope installer is a failure.
        'user' installs with --scope user, and is Deferred as SYSTEM or under cross-user elevation.
        An app already installed at either scope is skipped.
      - arch: the OS architectures the app is for ('X86', 'X64', 'Arm', 'Arm64'; one or a list),
        part of the applicability decision with the same fail-open rule. e2e/Assert-Install.ps1
        reads only 'condition', so the Reader entries keep theirs until it uses
        Test-AppApplicability.
      - postInstall: a scriptblock, or the name of a module function, called with the entry once the
        app is installed and on every run that finds it installed, so it must be idempotent. It
        returns 'Configured', or @{ Status = 'NotConfigured' or 'Failed'; Reason = '<why>' }
        (Invoke-AppPostInstall). Anything but Configured or NotConfigured makes the app Failed
        (exit code 1); NotConfigured adds a line under the summary. It runs in the run's account,
        and never in a dry run.
      - userPhase: $true for an app or setting that needs the signed-in user's own account; it is
        Deferred as SYSTEM or under cross-user elevation.
    A Deferred app is neither installed nor failed; last-run.json records why, for the user phase.
.OUTPUTS
    [array] of app-definition hashtables.
#>
function Get-DefaultAppCatalog {
    return @(
        @{name = '7zip.7zip' },
        # TightVNC Server installs with no password: the hook sets the server and control passwords
        # from WINGET_APP_SETUP_TIGHTVNC_PASSWORD or a prompt, never from this public repo (P2-22).
        @{name = 'GlavSoft.TightVNC'; postInstall = 'Set-TightVncServerPassword' },
        # One Adobe Reader per PC (P3-32): Adobe supports only the 32-bit Reader on ARM64 Windows,
        # and the 64-bit package's only installer is x64. The conditions are opposites, so exactly
        # one applies unless Get-OSArchitecture throws.
        @{name = 'Adobe.Acrobat.Reader.64-bit'; condition = { (Get-OSArchitecture) -ne 'Arm64' }; conditionDescription = 'its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows' },
        @{name = 'Adobe.Acrobat.Reader.32-bit'; condition = { (Get-OSArchitecture) -eq 'Arm64' }; conditionDescription = 'ARM64 Windows only; other PCs get the 64-bit Reader' },
        @{name = 'Google.Chrome' },
        @{name = 'Google.GoogleDrive' },
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        # Dell hardware only; its .NET Desktop Runtime dependency cannot even install on Server
        # images (0x8A150104 on GitHub-hosted runners) (issue #217).
        @{name = 'Dell.CommandUpdate.Universal'; condition = { (Get-ComputerManufacturer) -match 'Dell' }; conditionDescription = 'Dell hardware only' },
        # Install-PowerShellLatest installs the MSI while one exists (7.6 and older), then the MSIX
        # machine-wide (natively on 24H2+, through DISM before): winget's default MSIX registers per
        # user (issues #163, #166). It verifies its own install.
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
        # winget cannot update Windows Terminal from a session Terminal hosts: that locks winget.exe's
        # own launch, and retries never recover (issue #271). SYSTEM has no Terminal session; a run
        # for the whole PC decides from msixName whether Terminal is provisioned for every user.
        @{name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal'; condition = { (Test-IsSystemAccount) -or -not (Test-WindowsTerminalHostsCurrentSession) }; conditionDescription = 'winget cannot self-update Windows Terminal from a session Windows Terminal itself is hosting (issue #271)' }
    )
}
