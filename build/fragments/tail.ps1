if ($MyInvocation.InvocationName -ne '.') {
    # Fail fast on Windows PowerShell 5.1 (issue #210): the installer's logic requires PowerShell
    # 7+, and 5.1 parses the WHOLE file before running any of it - which is why this check can
    # exist at all: the build guards the assembled script to stay 5.1-PARSEABLE (ASCII-only code
    # tokens) so 5.1 gets far enough to run this line and print a real message instead of a wall
    # of parser errors. Write-Host (not Write-Error) so the message renders identically regardless
    # of the caller's $ErrorActionPreference, then exit 1.
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host 'This installer requires PowerShell 7+ (pwsh). Install it (winget install Microsoft.PowerShell) and run the one-liner from a pwsh prompt, or run: pwsh -Command "irm https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1 | iex"' -ForegroundColor Red
        exit 1
    }

    # Persistent transcript (issue #189): a failed install on a remote user's machine used to
    # leave zero artifacts. The log lands under ProgramData - not the elevating account's TEMP -
    # so it survives cross-user elevation and stays findable afterwards. Logging must never block
    # an install: any failure here downgrades to a warning and the run continues untranscribed.
    $script:InstallLogPath = $null
    $transcriptStarted = $false
    try {
        $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            [void](New-Item -Path $logDirectory -ItemType Directory -Force)
        }
        # The -whatif suffix keeps dry-run transcripts from being mistaken for real install logs.
        $logSuffix = if ($WhatIf) { '-whatif' } else { '' }
        $logCandidate = Join-Path $logDirectory ('install-{0:yyyyMMdd-HHmmss}{1}.log' -f (Get-Date), $logSuffix)
        [void](Start-Transcript -Path $logCandidate -ErrorAction Stop)
        $transcriptStarted = $true
        $script:InstallLogPath = $logCandidate
    }
    catch {
        Write-WarningMessage "Transcript logging could not be started: $_. Continuing without a log file."
    }

    try {
        if ($script:InstallLogPath) {
            Write-Info "Logging this run to: $script:InstallLogPath"
        }
        # Content-derived build id stamped by build/Build-WingetInstallScript.ps1 (issue #189), so
        # a transcript identifies exactly which installer build produced it.
        Write-Info "Installer build: $script:InstallerBuildId"

        if (-not $SkipSystemCheck) {
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Running pre-flight system checks (OS version, disk space, network).'
                if (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                    Write-WarningMessage '[DRY-RUN] A blocking pre-flight check failed - a real run would abort here.'
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
    finally {
        # Exit statements inside Invoke-WingetInstall unwind through here (PowerShell runs finally
        # blocks for the exit statement), so the transcript closes on every path.
        if ($transcriptStarted) {
            try {
                [void](Stop-Transcript)
            }
            catch {
                # Best-effort: the transcript is flushed progressively, and PowerShell stops any
                # remaining transcript at process exit anyway.
            }
        }
    }
}
