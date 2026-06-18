@{
    RootModule        = 'WingetAppSetup.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0572ca47-4e31-4bb0-ac40-f10bcc37e428'
    Author            = 'Joey Maffiola'
    Description       = 'Shared functions for installing and updating curated apps via winget (issue #106 refactor of winget-app-install.ps1).'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        # Logging
        'Write-Info', 'Write-Success', 'Write-WarningMessage', 'Write-ErrorMessage', 'Write-Prompt', 'Format-AppList', 'Write-Table',
        # App validation
        'Test-AppDefinitions',
        # Winget core
        'Test-AndInstallWingetModule', 'Test-AndInstallWinget', 'Test-WingetSourceTrusted', 'Set-Sources', 'Test-WingetSources',
        'Invoke-WingetCommand', 'Test-UpdatesAvailable', 'Get-UpdateReport', 'Initialize-WingetSourcesForUser',
        # Scheduled / on-demand updates
        'Get-UpdateSettingsPaths', 'New-DefaultUpdateConfiguration', 'Get-UpdateConfiguration', 'Save-UpdateConfiguration',
        'Test-ScheduledUpdatesTaskExists', 'Install-UpdateHelperScript', 'Enable-ScheduledUpdatesCheck',
        'Disable-ScheduledUpdatesCheck', 'Invoke-OnDemandUpdateCheck',
        # Windows Terminal configuration
        'ConvertFrom-TerminalSettingsJson', 'Get-WindowsTerminalSettingsPath', 'Get-WindowsTerminalSettingsPaths',
        'Set-WindowsTerminalDefaultProfile', 'Set-WindowsTerminalAsDefaultTerminalApplication', 'Set-WindowsTerminalDefaults',
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
