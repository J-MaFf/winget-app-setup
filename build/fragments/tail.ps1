if ($MyInvocation.InvocationName -ne '.') {
    if ($EnableScheduledUpdates -and $DisableScheduledUpdates) {
        Write-ErrorMessage 'EnableScheduledUpdates and DisableScheduledUpdates cannot be used together.'
        exit 1
    }

    if ($DisableScheduledUpdates) {
        [void](Disable-ScheduledUpdatesCheck -WhatIf:$WhatIf)
        exit 0
    }

    if ($EnableScheduledUpdates) {
        $config = Get-UpdateConfiguration
        $autoInstall = if ($PSBoundParameters.ContainsKey('AutoInstallUpdates')) { [bool]$AutoInstallUpdates } else { [bool]$config.AutoInstall }
        [void](Enable-ScheduledUpdatesCheck -UpdateFrequency $UpdateFrequency -AutoInstall:$autoInstall -SkipPrompt:$true -WhatIf:$WhatIf)
        exit 0
    }

    if ($CheckForUpdates) {
        Invoke-OnDemandUpdateCheck -AutoInstallUpdates:$AutoInstallUpdates -WhatIf:$WhatIf
        exit 0
    }

    Invoke-WingetInstall -WhatIf:$WhatIf
}
