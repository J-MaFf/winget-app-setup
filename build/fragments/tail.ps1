if ($MyInvocation.InvocationName -ne '.') {
    if (-not $SkipSystemCheck) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run pre-flight system checks (OS version, disk space, network).'
        }
        elseif (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
            exit 1
        }
    }

    Invoke-WingetInstall -WhatIf:$WhatIf
}
