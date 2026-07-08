@{
    RootModule        = 'WingetAppSetup.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0572ca47-4e31-4bb0-ac40-f10bcc37e428'
    Author            = 'Joey Maffiola'
    Description       = 'Shared functions for installing and updating curated apps via winget (issue #106 refactor of winget-app-install.ps1).'
    PowerShellVersion = '5.1'

    # Single export authority (issue #191): this list must exactly match the functions defined
    # under Public/*.ps1 — build/Build-WingetInstallScript.ps1 asserts that in build and -Check
    # modes, and the psm1 exports this same list.
    FunctionsToExport = @(
        # Logging (consumed by winget-app-uninstall.ps1)
        'Write-Info', 'Write-Success', 'Write-WarningMessage', 'Write-ErrorMessage', 'Format-AppList', 'Write-Table',
        # App validation
        'Test-AppDefinitions',
        # Winget core
        'Test-AndInstallWingetModule', 'Test-AndInstallWinget', 'Test-WingetSources',
        'Initialize-WingetSourcesForUser', 'Install-WingetPackage',
        'Test-WingetPackageInstalled', 'Test-AppxPackageProvisioned', 'Invoke-AppxProvisioning', 'Install-MsixProvisionedPackage', 'Install-PowerShellLatest',
        # Automatic updates (Winget-AutoUpdate)
        'Get-WauPin', 'Test-WauInstalled', 'Install-WingetAutoUpdate', 'Uninstall-WingetAutoUpdate', 'Remove-LegacyScheduledUpdates',
        # Windows Terminal configuration
        'Get-WindowsTerminalSettingsPath', 'Get-WindowsTerminalSettingsPaths',
        'Set-WindowsTerminalDefaultProfile', 'Set-WindowsTerminalAsDefaultTerminalApplication', 'Set-WindowsTerminalDefaults',
        # System pre-flight checks
        'Test-SystemRequirements',
        # Install orchestration
        'Invoke-WingetInstall'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('winget', 'installation', 'automation')
            ProjectUri = 'https://github.com/J-MaFf/winget-app-setup'
        }
    }
}
