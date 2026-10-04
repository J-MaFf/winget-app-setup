if ($MyInvocation.InvocationName -ne '.') {
    # Windows PowerShell 5.1 bootstrap (issue #225; supersedes the #210 fail-fast). The
    # installer's logic requires PowerShell 7+, and 5.1 parses the WHOLE file before running any
    # of it - which is why this dispatch can exist at all: the build guards the assembled script
    # to stay 5.1-PARSEABLE (ASCII-only code tokens) so 5.1 gets far enough to run this branch.
    # The bootstrap finds-or-installs PowerShell 7 and relaunches this installer under pwsh in
    # the same console, forwarding the caller's switches; the exit below propagates the
    # relaunched run's exit code. Everything the bootstrap touches MUST stay 5.1-runtime
    # compatible - see WingetAppSetup/Private/PowerShell7Bootstrap.ps1.
    # Forcing an exit code after an abort is only safe where the process ends anyway: when this
    # process was started to run this script (`pwsh -File <path>`, including the bootstrap and
    # elevation relaunches), or in a non-interactive session (RMM, CI, `pwsh -Command "irm | iex"`).
    # In a console where someone typed `irm ... | iex` or `.\winget-app-install.ps1`, exiting would
    # close their window and take the error with it.
    $launchedForScript = $false
    if ($PSCommandPath) {
        foreach ($commandLineArgument in [Environment]::GetCommandLineArgs()) {
            try {
                if ([System.IO.Path]::GetFullPath($commandLineArgument) -eq $PSCommandPath) {
                    $launchedForScript = $true
                    break
                }
            }
            catch {
                # Not a path (e.g. a switch with characters GetFullPath rejects); keep looking.
            }
        }
    }
    $forceExitCodeOnAbort = $launchedForScript -or (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive)

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        # try/catch, not a bare `exit (Invoke-PowerShell7Bootstrap ...)`: a statement-terminating
        # error inside the bootstrap would abort only that `exit` statement, and 5.1 would then fall
        # through into the PowerShell-7-only body below.
        $bootstrapExitCode = 1
        $bootstrapReturned = $false
        try {
            $bootstrapExitCode = Invoke-PowerShell7Bootstrap -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck -CommandPath $PSCommandPath
            $bootstrapReturned = $true
        }
        catch {
            Write-ErrorMessage "The PowerShell 7 bootstrap failed unexpectedly: $_"
            $bootstrapExitCode = 1
            $bootstrapReturned = $true
        }
        finally {
            # Ctrl+C or a console stop reaches this 5.1 parent too while it waits for the relaunched
            # pwsh (same console), and cannot be caught; without this the parent would exit 0.
            if (-not $bootstrapReturned -and $forceExitCodeOnAbort) {
                $host.SetShouldExit(5)
            }
        }
        exit $bootstrapExitCode
    }

    # Abort guard state (see the catch and finally at the end of this block). Reset on every run:
    # under irm | iex these live in the caller's scope and would otherwise carry over into a second
    # run in the same console. Exit-Installer sets InstallerExitRequested before every intended
    # exit below; Invoke-WingetInstall records InstallerPendingExitCode once it has decided its exit
    # code, just before its final 'Press any key' prompt.
    $script:InstallerExitRequested = $false
    $script:InstallerPendingExitCode = $null
    $installerRunCompleted = $false

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

        # No -NonInteractive to forward: the pre-flight checks no longer prompt at all (issue
        # #230), so there is no interactive behavior left for it to gate. Measured-low disk warns
        # and continues for every run, and the only thing that can still return false here is the
        # blocking network probe.
        if (-not $SkipSystemCheck) {
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Running pre-flight system checks (OS version, disk space, network).'
                if (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                    Write-WarningMessage '[DRY-RUN] A blocking pre-flight check failed - a real run would abort here.'
                }
            }
            elseif (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                Exit-Installer 1
            }
        }

        # Forward -SkipSystemCheck so an elevated relaunch inherits the caller's intent to bypass the
        # pre-flight checks (issue #185); the checks themselves already ran (or were skipped) above.
        # Invoke-WingetInstall returns its exit code instead of exiting, and its return value is the
        # last thing it writes to the output stream: taking the last element keeps the code right
        # even if a helper ever leaks a value into that stream.
        $installerExitCode = [int](@(Invoke-WingetInstall -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck)[-1])
        $installerRunCompleted = $true
        # Exit only for a non-zero code: a successful run ends normally (exit code 0 under -File), so
        # an interactive irm | iex console stays open afterwards.
        if ($installerExitCode -ne 0) {
            Exit-Installer $installerExitCode
        }
    }
    catch {
        # Any unexpected error lands here instead of silently ending the run with exit 0: inside
        # this try, a .NET exception, a method call on $null or a parameter-binding error anywhere
        # in the run aborts the whole block - no retry pass, no summary. Logged while the transcript
        # is still open, so the log a teammate attaches to a GitHub issue carries the stack trace.
        Write-ErrorMessage 'UNEXPECTED ERROR - the run was aborted before it finished. No summary was produced, and apps may be only partly installed.'
        Write-ErrorMessage "Error: $($_.Exception.Message)"
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            Write-ErrorMessage $_.InvocationInfo.PositionMessage
        }
        if ($_.ScriptStackTrace) {
            Write-ErrorMessage "Stack trace:`n$($_.ScriptStackTrace)"
        }
        if ($forceExitCodeOnAbort) {
            Exit-Installer 5
        }
        # Interactive console: exiting would close the window (under irm | iex the host itself),
        # so leave the error on screen and the code in $LASTEXITCODE instead.
        if ($script:InstallLogPath) {
            Write-Info "Full transcript of this run: $script:InstallLogPath"
        }
        $script:InstallerExitRequested = $true
        $global:LASTEXITCODE = 5
    }
    finally {
        # An outside stop (Ctrl+C, closing the console, or an installer such as an MSI upgrade of
        # PowerShell itself sending a console stop - issue #283) skips the catch above, because a
        # PipelineStoppedException cannot be caught. A run from a file would then exit 0.
        if (-not $installerRunCompleted -and -not $script:InstallerExitRequested -and $forceExitCodeOnAbort) {
            if ($null -ne $script:InstallerPendingExitCode) {
                # Stopped at the final 'Press any key' prompt: the run had already finished and
                # decided its exit code, so report that rather than an abort.
                $host.SetShouldExit([int]$script:InstallerPendingExitCode)
            }
            else {
                $abortMessage = 'The run was stopped before it finished (exit code 5).'
                try {
                    Write-ErrorMessage $abortMessage
                }
                catch {
                    [Console]::Error.WriteLine($abortMessage)
                }
                $host.SetShouldExit(5)
            }
        }
        # The exit statements above unwind through here (PowerShell runs finally blocks for the
        # exit statement), so the transcript closes on every path.
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
