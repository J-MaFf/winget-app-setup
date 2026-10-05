@{
    RootModule        = 'WingetAppSetup.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0572ca47-4e31-4bb0-ac40-f10bcc37e428'
    Author            = 'Joey Maffiola'
    Description       = 'Shared functions for installing and updating curated apps via winget (issue #106 refactor of winget-app-install.ps1).'
    PowerShellVersion = '5.1'

    # Every function the module defines, Public/ and Private/ alike (review finding P3-44). The
    # module's only consumers are this repository's entry scripts (winget-app-uninstall.ps1,
    # e2e/Assert-Install.ps1); the installer itself is the generated single file, which does not
    # read this manifest. An explicit list had to be kept equal to Public/*.ps1 by a build check,
    # and a function missing from it was filtered out of manifest imports without a word (#191).
    FunctionsToExport = '*'

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
