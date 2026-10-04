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

    # Abort guard state (see the catch and finally blocks below). Reset on every run: under
    # irm | iex these live in the caller's scope and would otherwise carry over into a second run in
    # the same console. Exit-Installer sets InstallerExitRequested right before every intended exit,
    # and InstallerPendingExitCode before it waits for a key press; Invoke-WingetInstall records
    # InstallerPendingExitCode once it has decided its exit code, just before its final 'Press any
    # key' prompt.
    $script:InstallerExitRequested = $false
    $script:InstallerPendingExitCode = $null
    $script:InstallLogPath = $null
    $script:InstallerScriptSha256 = $null
    $installerRunCompleted = $false

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        # The bootstrap phase gets its own transcript, install-<timestamp>-bootstrap.log, next to the
        # PowerShell 7 run's (review finding P2-13): the PowerShell 7 install (winget, the MSI and
        # its msiexec log), GitHub throttling and relaunch errors used to leave no log at all. It
        # stays open while the relaunched run works, so it also records the exit code that run
        # ended with. A bootstrap that fails before it can relaunch exits 7.
        $script:PowerShell7BootstrapRelaunched = $false
        $script:InstallLogPath = Start-InstallerTranscript -Bootstrap -WhatIf:$WhatIf
        $bootstrapLogDirectory = ''
        if ($script:InstallLogPath) {
            $bootstrapLogDirectory = Split-Path -Parent $script:InstallLogPath
        }
        $bootstrapExitCode = 7
        try {
            if ($script:InstallLogPath) {
                Write-Info "Logging the PowerShell 7 bootstrap to: $script:InstallLogPath"
            }
            Write-Info "Installer build: $script:InstallerBuildId"
            # try/catch, not a bare `exit (Invoke-PowerShell7Bootstrap ...)`: a statement-terminating
            # error inside the bootstrap would abort only that `exit` statement, and 5.1 would then
            # fall through into the PowerShell-7-only body below. The build id goes along so an
            # irm | iex run relaunches this same build and never another one (review finding P2-18).
            try {
                $bootstrapExitCode = Invoke-PowerShell7Bootstrap -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck -CommandPath $PSCommandPath -ExpectedBuildId $script:InstallerBuildId -LogDirectory $bootstrapLogDirectory
            }
            catch {
                Write-ErrorMessage "The PowerShell 7 bootstrap failed unexpectedly: $_"
                $bootstrapExitCode = 7
            }
            # A relaunched PowerShell 7 run reported its own outcome (and waited for a key press when
            # someone was there); a bootstrap that failed before it could relaunch reports here.
            Exit-Installer -Code $bootstrapExitCode -NonInteractive:$NonInteractive -OutcomeShown:$script:PowerShell7BootstrapRelaunched
        }
        finally {
            # Ctrl+C or a console stop reaches this 5.1 parent too while it waits for the relaunched
            # pwsh (same console), and cannot be caught; without this the parent would exit 0.
            if (-not $script:InstallerExitRequested -and $forceExitCodeOnAbort) {
                if ($null -ne $script:InstallerPendingExitCode) {
                    # Stopped while waiting for a key press after the failure notice.
                    $host.SetShouldExit([int]$script:InstallerPendingExitCode)
                }
                else {
                    $host.SetShouldExit(5)
                }
            }
            if ($script:InstallLogPath) {
                try {
                    [void](Stop-Transcript)
                }
                catch {
                    # Best-effort, as in the PowerShell 7 branch below.
                }
            }
        }
        # Never reached unless Exit-Installer itself failed: never fall through into the
        # PowerShell-7-only body below.
        exit $bootstrapExitCode
    }

    # The SHA256 of this file as this run read it, taken before anything else runs (review finding
    # P3-11). A run that is not elevated relaunches itself elevated, and the elevated window runs
    # only a copy of this file with this hash, so a file rewritten in the meantime (it may sit in a
    # user-writable folder, such as the bootstrap's copy in %TEMP%) is not run with administrator
    # rights. Under irm | iex there is no file and nothing to relaunch.
    if ($PSCommandPath) {
        try {
            $script:InstallerScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            # Restart-WithElevation then hashes the file when it relaunches.
        }
    }

    # Persistent transcript (issue #189); see Start-InstallerTranscript. Logging never blocks an
    # install: when it cannot start, the run continues untranscribed and InstallLogPath stays $null.
    $script:InstallLogPath = Start-InstallerTranscript -WhatIf:$WhatIf
    $transcriptStarted = [bool]$script:InstallLogPath

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
                Exit-Installer -Code 1 -Reason 'a blocking pre-flight system check failed (see above)' -NonInteractive:$NonInteractive
            }
        }

        # Forward -SkipSystemCheck so an elevated relaunch inherits the caller's intent to bypass the
        # pre-flight checks (issue #185); the checks themselves already ran (or were skipped) above.
        # Invoke-WingetInstall returns its exit code instead of exiting, and its return value is the
        # last thing it writes to the output stream: taking the last element keeps the code right
        # even if a helper ever leaks a value into that stream.
        $installerExitCode = [int](@(Invoke-WingetInstall -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck)[-1])
        # Exit only for a non-zero code: a successful run ends normally (exit code 0 under -File), so
        # an interactive irm | iex console stays open afterwards. A run that reached its summary set
        # InstallerPendingExitCode before its final prompt and has shown its outcome; any other
        # non-zero code is an early exit (winget missing, a bad catalog, elevation declined), which
        # Exit-Installer explains before the window closes.
        if ($installerExitCode -ne 0) {
            Exit-Installer -Code $installerExitCode -NonInteractive:$NonInteractive -OutcomeShown:($null -ne $script:InstallerPendingExitCode)
        }
        $installerRunCompleted = $true
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
            Exit-Installer -Code 5 -NonInteractive:$NonInteractive
        }
        # Interactive console: exiting would close the window (under irm | iex the host itself),
        # so leave the error on screen and the code in $LASTEXITCODE instead. The console stays
        # open, so the notice needs no key press.
        Write-InstallerExitNotice -Code 5 -NoPause
        $script:InstallerExitRequested = $true
        $global:LASTEXITCODE = 5
    }
    finally {
        # An outside stop (Ctrl+C, closing the console, or an installer such as an MSI upgrade of
        # PowerShell itself sending a console stop - issue #283) skips the catch above, because a
        # PipelineStoppedException cannot be caught. A run from a file would then exit 0.
        if (-not $installerRunCompleted -and -not $script:InstallerExitRequested -and $forceExitCodeOnAbort) {
            if ($null -ne $script:InstallerPendingExitCode) {
                # Stopped at a 'Press any key' prompt (the run's final one, or Exit-Installer's
                # after an early failure): the exit code was already decided, so report that
                # rather than an abort.
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
