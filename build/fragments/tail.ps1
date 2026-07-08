if ($MyInvocation.InvocationName -ne '.') {
    if (-not $SkipSystemCheck) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Running pre-flight system checks (OS version, disk space, network).'
            if (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                Write-WarningMessage '[DRY-RUN] A blocking pre-flight check failed — a real run would abort here.'
            }
        }
        elseif (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
            exit 1
        }
    }

    Invoke-WingetInstall -WhatIf:$WhatIf -NonInteractive:$NonInteractive
}
