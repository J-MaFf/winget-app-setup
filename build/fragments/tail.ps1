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

    # Forward -SkipSystemCheck so an elevated relaunch inherits the caller's intent to bypass the
    # pre-flight checks (issue #185); the checks themselves already ran (or were skipped) above.
    Invoke-WingetInstall -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck
}
