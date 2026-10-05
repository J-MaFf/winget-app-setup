<#
.SYNOPSIS
    Reads installer transcripts and turns them into end-to-end assertion results.
.DESCRIPTION
    Dot-sourced by e2e/Assert-Install.ps1. Everything here reads files and text only and calls
    nothing Windows-specific, so tests/E2EAssertions.Tests.ps1 checks it against the sample
    transcripts in tests/fixtures/e2e on any OS (review finding P3-39: the parsing used to live
    inline in Assert-Install.ps1 with no tests, and its failure regex missed the timeout lines and
    the #279 bulk failure).

    The functions key on lines the installer writes with Write-Host, which a transcript records
    verbatim, one per line: Invoke-WingetInstall (WingetAppSetup/Public/Install.ps1), the entry
    script (build/fragments/tail.ps1) and the Windows PowerShell 5.1 bootstrap
    (WingetAppSetup/Private/PowerShell7Bootstrap.ps1). tests/E2EAssertions.Tests.ps1 checks that
    the installer source still writes each of them, so a reworded message fails a unit test
    instead of quietly matching nothing here.

    Runs under PowerShell 7 (Assert-Install.ps1) and stays ASCII with no 7-only syntax, like the
    other e2e scripts.
#>

<#
.SYNOPSIS
    Lists the installer transcripts in a log folder, oldest first.
.DESCRIPTION
    Real-run transcripts are install-<yyyyMMdd-HHmmss>.log. A dry run adds '-whatif': those are
    left out, they prove nothing about an install. The Windows PowerShell 5.1 phase of a run
    (finding or installing PowerShell 7, then relaunching) adds '-bootstrap'. The 5.1 bootstrap
    transcripts are returned separately: they hold no install, and the 5.1 parent keeps its
    transcript open until the PowerShell 7 run it started has ended, so a bootstrap transcript is
    always written after the run it belongs to and would otherwise pass for the latest run. So are
    the RMM wrapper's ('-rmm', rmm/Invoke-WingetAppSetup.ps1), for the same reason: the wrapper
    starts before the installer and ends after it, and its log repeats the installer's output.
.PARAMETER LogDirectory
    The installer's log folder (%ProgramData%\winget-app-setup\logs on a real machine).
.RETURNS
    [pscustomobject] with RealRun, Bootstrap and Rmm, each an array of FileInfo sorted by
    LastWriteTime (then name).
#>
function Get-InstallTranscriptFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory
    )

    $files = @(Get-ChildItem -Path $LogDirectory -Filter 'install-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '-whatif\.log$' } |
            Sort-Object -Property LastWriteTime, Name)
    return [pscustomobject]@{
        RealRun   = @($files | Where-Object { $_.Name -notmatch '-(bootstrap|rmm)\.log$' })
        Bootstrap = @($files | Where-Object { $_.Name -match '-bootstrap\.log$' })
        Rmm       = @($files | Where-Object { $_.Name -match '-rmm\.log$' })
    }
}

# Splits transcript text into trimmed lines (transcripts are CRLF on Windows).
function Get-TranscriptLine {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    return @($Content -split '\r?\n' | ForEach-Object { $_.Trim() })
}

# An app id captured from a message such as 'Failed to install: Git.Git. Error: ...' keeps the
# sentence's full stop; ids never end in one.
function ConvertTo-TranscriptAppId {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return $Text.TrimEnd('.', ',', ':', ';')
}

<#
.SYNOPSIS
    Reads what one PowerShell 7 run of the installer did from its transcript.
.DESCRIPTION
    Per-app lines come from Invoke-WingetInstall:
      - first pass: 'Successfully installed: <id>', 'Skipping: <id> (already installed)',
        'Skipping: <id> (not applicable: <reason>)', and the three failure forms
        'Failed to install: <id> ...', 'Winget list timed out for <id>. ...' and
        'Verification timed out for: <id>. ...';
      - retry pass: 'Retry succeeded: <id>', and 'Retry failed: <id> ...',
        'Winget list timed out for retry: <id>. ...' and 'Verification timed out for retry: <id>. ...'.
    The summary table under 'Summary:' ('Status  Apps', then one 'Installed', 'Skipped',
    'Deferred' and 'Failed' row each; a run as SYSTEM or under cross-user elevation lists the apps
    it left for the signed-in user as Deferred) lists the final outcome. A 'RESULT: ' line after
    it (the machine-readable outcome) is not read here. When winget cannot be launched, the circuit
    breaker logs 'winget cannot be launched on this machine (...)' once and every remaining app
    fails with its own 'Failed to install: <id> (not attempted: ...)' line. The table is printed at
    full width since review finding P3-13; an older transcript can still cut a long row off with an
    ellipsis, so a cut-off id is dropped and SummaryTruncated is set.
.PARAMETER Content
    The transcript text.
.RETURNS
    [pscustomobject] with:
      BuildId            'Installer build: <id>' (first one), or $null.
      Installed          ids with 'Successfully installed'.
      AlreadyInstalled   ids skipped as already installed.
      NotApplicable      ordered dictionary of id -> reason for the not-applicable skips.
      FirstPassFailed    ids with a first-pass failure line (any of the three forms).
      RetrySucceeded     ids with 'Retry succeeded'.
      RetryFailed        ids with a retry-pass failure line (any of the three forms).
      HasSummary         whether the run reached its 'Summary:' line.
      SummaryInstalled, SummarySkipped, SummaryDeferred, SummaryFailed   the summary table's rows.
      SummaryTruncated   whether a summary row was cut off.
      FinalFailed        the apps still failed at the end of the run: first-pass failures that
                         did not succeed on retry, retry-pass failures and the summary's Failed row.
      RecoveredOnRetry   first-pass failures that succeeded on retry.
      WingetNotLaunchable the circuit breaker found that winget cannot be launched ('winget cannot
                         be launched on this machine ...'), so the remaining apps were not
                         attempted.
      Aborted            the run was aborted or stopped before it finished.
      EarlyExitCode      the code in 'The installer stopped early with exit code N', or $null.
      AutoUpdatesLine    the text after the last 'Auto-updates: ', or $null.
      AutoUpdatesStatus  'Configured', 'Already present', 'AT RISK', 'NOT CONFIGURED',
                         'UNHEALTHY' or 'FAILED', or $null.
      AutoUpdatesFrameworkMissing  the line is 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8
                         is missing ...': Winget-AutoUpdate was skipped because that framework is
                         missing and the installer could not install it, the one reason
                         e2e/Invoke-InstallPass.ps1 accepts exit 8 for.
      WindowsAppRuntimeLine  the text after the last 'Windows App Runtime: ', or $null: the
                         installer's own install of the pinned framework (Install-WindowsAppRuntimeFramework,
                         work-order item 31), 'installed Microsoft.WindowsAppRuntime.1.8 <version>
                         (<arch>) for all users.' or 'NOT INSTALLED - <reason>.'. A run that found
                         the framework writes none.
      WindowsAppRuntimeInstalled  the run installed the framework ('Windows App Runtime: installed').
      WindowsAppRuntimeInstallCount  how many 'Windows App Runtime: installed' lines the run wrote:
                         one run installs the framework at most once (the SYSTEM leg checks it).
      WindowsAppRuntimeAttempted  the run started that install ('Microsoft.WindowsAppRuntime.1.8 is
                         missing; installing the pinned Windows App Runtime ...'): every
                         precondition held (elevated, an architecture and Windows build the
                         framework supports, no framework already provisioned), so a
                         'NOT INSTALLED' after it is a failed download, check or provisioning.
      WindowsAppRuntimePinStale  the 'Windows App Runtime:' line says the installer's pinned
                         framework does not meet what the latest winget release needs ('NOT
                         INSTALLED - the latest winget release needs ...', work-order item 32), for
                         a newer 1.8 build or another family alike: the pin has to move.
      WingetNotUsable    the end-of-run check printed 'winget: NOT USABLE'.
      RanAsSystem        the run said it runs as SYSTEM ('Running as SYSTEM (for example from an
                         RMM agent): ...').
#>
function ConvertFrom-InstallTranscript {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $buildId = $null
    $installed = [System.Collections.Generic.List[string]]::new()
    $alreadyInstalled = [System.Collections.Generic.List[string]]::new()
    $notApplicable = [ordered]@{}
    $firstPassFailed = [System.Collections.Generic.List[string]]::new()
    $retrySucceeded = [System.Collections.Generic.List[string]]::new()
    $retryFailed = [System.Collections.Generic.List[string]]::new()
    $summaryRows = @{ Installed = @(); Skipped = @(); Deferred = @(); Failed = @() }
    $hasSummary = $false
    $summaryTruncated = $false
    $wingetNotLaunchable = $false
    $aborted = $false
    $earlyExitCode = $null
    $autoUpdatesLine = $null
    $windowsAppRuntimeLine = $null
    $windowsAppRuntimeInstalled = $false
    $windowsAppRuntimeInstallCount = 0
    $windowsAppRuntimeAttempted = $false
    $windowsAppRuntimePinStale = $false
    $wingetNotUsable = $false
    $ranAsSystem = $false

    # Summary table state: 'none' until 'Summary:', 'header' until the dashes under the column
    # names, then 'rows' until the first line that is not a row. A line that ends the table is
    # still read as an ordinary line below (a run with no table goes straight on to
    # 'Auto-updates:').
    $tableState = 'none'

    foreach ($line in (Get-TranscriptLine -Content $Content)) {
        if ($tableState -eq 'header') {
            if (-not $line -or $line -match '^Status\s+Apps$') {
                continue
            }
            if ($line -match '^-+\s+-+$') {
                $tableState = 'rows'
                continue
            }
            $tableState = 'done'
        }
        elseif ($tableState -eq 'rows') {
            if ($line -match '^(?<status>Installed|Skipped|Deferred|Failed)\s+(?<apps>\S.*)$') {
                $summaryRows[$Matches.status] += @($Matches.apps)
                continue
            }
            $tableState = 'done'
        }

        if ($line -eq 'Summary:') {
            $hasSummary = $true
            $tableState = 'header'
            continue
        }
        if ($null -eq $buildId -and $line -match '^Installer build:\s+(?<id>\S+)$') {
            $buildId = $Matches.id
            continue
        }
        if ($line -match '^Successfully installed:\s+(?<app>\S+)') {
            $installed.Add((ConvertTo-TranscriptAppId -Text $Matches.app))
            continue
        }
        if ($line -match '^Skipping:\s+(?<app>\S+) \(already installed\)$') {
            $alreadyInstalled.Add($Matches.app)
            continue
        }
        if ($line -match '^Skipping:\s+(?<app>\S+) \(not applicable: (?<reason>.*)\)$') {
            $notApplicable[$Matches.app] = $Matches.reason
            continue
        }
        if ($line -match '^Retry succeeded:\s+(?<app>\S+)') {
            $retrySucceeded.Add((ConvertTo-TranscriptAppId -Text $Matches.app))
            continue
        }
        # Retry-pass forms first: 'Winget list timed out for retry: <id>' would otherwise read as
        # a first-pass timeout of an app called 'retry:'.
        if ($line -match '^(Retry failed:|Winget list timed out for retry:|Verification timed out for retry:)\s+(?<app>[^\s(]+)') {
            $retryFailed.Add((ConvertTo-TranscriptAppId -Text $Matches.app))
            continue
        }
        if ($line -match '^(Failed to install:|Winget list timed out for|Verification timed out for:)\s+(?<app>[^\s(]+)') {
            $firstPassFailed.Add((ConvertTo-TranscriptAppId -Text $Matches.app))
            continue
        }
        if ($line -match '^winget cannot be launched on this machine ') {
            $wingetNotLaunchable = $true
            continue
        }
        if ($line -match '^(UNEXPECTED ERROR - the run was aborted|The run was stopped before it finished)') {
            $aborted = $true
            continue
        }
        if ($null -eq $earlyExitCode -and $line -match '^The installer stopped early with exit code (?<code>-?\d+)') {
            $earlyExitCode = [int]$Matches.code
            continue
        }
        if ($line -match '^Auto-updates:\s+(?<text>.+)$') {
            $autoUpdatesLine = $Matches.text
            continue
        }
        if ($line -match '^Microsoft\.WindowsAppRuntime\.1\.8 is missing; installing the pinned Windows App Runtime\b') {
            $windowsAppRuntimeAttempted = $true
            continue
        }
        if ($line -match '^Windows App Runtime:\s+(?<text>.+)$') {
            $windowsAppRuntimeLine = $Matches.text
            if ($windowsAppRuntimeLine -match '^installed\b') {
                $windowsAppRuntimeInstalled = $true
                $windowsAppRuntimeInstallCount++
            }
            if ($windowsAppRuntimeLine -match '^NOT INSTALLED - the latest winget release needs \S') {
                $windowsAppRuntimePinStale = $true
            }
            continue
        }
        if ($line -match '^winget: NOT USABLE') {
            $wingetNotUsable = $true
            continue
        }
        if ($line -match '^Running as SYSTEM \(for example from an RMM agent\)') {
            $ranAsSystem = $true
            continue
        }
    }

    $summary = @{}
    foreach ($status in @('Installed', 'Skipped', 'Deferred', 'Failed')) {
        $ids = [System.Collections.Generic.List[string]]::new()
        foreach ($cell in $summaryRows[$status]) {
            foreach ($item in ($cell -split ',')) {
                $id = $item.Trim()
                if (-not $id) {
                    continue
                }
                # U+2026 (ellipsis) is what Format-Table used to cut a long cell with.
                if ($id.EndsWith([string][char]0x2026) -or $id.EndsWith('...')) {
                    $summaryTruncated = $true
                    continue
                }
                $ids.Add($id)
            }
        }
        $summary[$status] = @($ids | Sort-Object -Unique)
    }

    $retrySucceededIds = @($retrySucceeded | Sort-Object -Unique)
    $firstPassFailedIds = @($firstPassFailed | Sort-Object -Unique)
    $stillFailedAfterFirstPass = @($firstPassFailedIds | Where-Object { $retrySucceededIds -notcontains $_ })
    $finalFailed = @(@($stillFailedAfterFirstPass) + @($retryFailed) + @($summary['Failed']) | Where-Object { $_ } | Sort-Object -Unique)

    $autoUpdatesStatus = $null
    if ($autoUpdatesLine -and $autoUpdatesLine -match '^(?<status>NOT CONFIGURED|AT RISK|UNHEALTHY|FAILED|Configured|Already present)\b') {
        $autoUpdatesStatus = $Matches.status
    }
    $autoUpdatesFrameworkMissing = $autoUpdatesStatus -eq 'NOT CONFIGURED' -and $autoUpdatesLine -match '^NOT CONFIGURED - Microsoft\.WindowsAppRuntime\.1\.8 is missing\b'

    return [pscustomobject]@{
        BuildId             = $buildId
        Installed           = @($installed | Sort-Object -Unique)
        AlreadyInstalled    = @($alreadyInstalled | Sort-Object -Unique)
        NotApplicable       = $notApplicable
        FirstPassFailed     = $firstPassFailedIds
        RetrySucceeded      = $retrySucceededIds
        RetryFailed         = @($retryFailed | Sort-Object -Unique)
        HasSummary          = $hasSummary
        SummaryInstalled    = $summary['Installed']
        SummarySkipped      = $summary['Skipped']
        SummaryDeferred     = $summary['Deferred']
        SummaryFailed       = $summary['Failed']
        SummaryTruncated    = $summaryTruncated
        FinalFailed         = $finalFailed
        RecoveredOnRetry    = @($firstPassFailedIds | Where-Object { $retrySucceededIds -contains $_ })
        WingetNotLaunchable = $wingetNotLaunchable
        Aborted             = $aborted
        EarlyExitCode       = $earlyExitCode
        AutoUpdatesLine     = $autoUpdatesLine
        AutoUpdatesStatus   = $autoUpdatesStatus
        AutoUpdatesFrameworkMissing = $autoUpdatesFrameworkMissing
        WindowsAppRuntimeLine = $windowsAppRuntimeLine
        WindowsAppRuntimeInstalled = $windowsAppRuntimeInstalled
        WindowsAppRuntimeInstallCount = $windowsAppRuntimeInstallCount
        WindowsAppRuntimeAttempted = $windowsAppRuntimeAttempted
        WindowsAppRuntimePinStale = $windowsAppRuntimePinStale
        WingetNotUsable     = $wingetNotUsable
        RanAsSystem         = $ranAsSystem
    }
}

<#
.SYNOPSIS
    Reads what the Windows PowerShell 5.1 phase of a run did from its bootstrap transcript.
.DESCRIPTION
    Lines from Invoke-PowerShell7Bootstrap: 'PowerShell 7 is installed.' after it had to install
    PowerShell 7, 'Relaunching the installer under PowerShell 7: <path>' and, once that run has
    ended, 'The PowerShell 7 run ended with exit code <n>.'
.PARAMETER Content
    The bootstrap transcript text.
.RETURNS
    [pscustomobject] with BuildId, InstalledPowerShell7 (bool), RelaunchPath (or $null) and
    ChildExitCode ([int] or $null).
#>
function ConvertFrom-BootstrapTranscript {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $result = [pscustomobject]@{
        BuildId              = $null
        InstalledPowerShell7 = $false
        RelaunchPath         = $null
        ChildExitCode        = $null
    }
    foreach ($line in (Get-TranscriptLine -Content $Content)) {
        if ($null -eq $result.BuildId -and $line -match '^Installer build:\s+(?<id>\S+)$') {
            $result.BuildId = $Matches.id
        }
        elseif ($line -eq 'PowerShell 7 is installed.') {
            $result.InstalledPowerShell7 = $true
        }
        elseif ($line -match '^Relaunching the installer under PowerShell 7:\s+(?<path>.+)$') {
            $result.RelaunchPath = $Matches.path
        }
        elseif ($line -match '^The PowerShell 7 run ended with exit code (?<code>-?\d+)\.?$') {
            $result.ChildExitCode = [int]$Matches.code
        }
    }
    return $result
}

<#
.SYNOPSIS
    Reads the build id stamped into a generated installer.
.PARAMETER Content
    The text of winget-app-install.ps1. Read with a regex, never dot-sourced: dot-sourcing runs
    the installer.
.RETURNS
    [string] The $script:InstallerBuildId value, or $null.
#>
function Get-InstallerBuildIdFromScript {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $match = [regex]::Match($Content, "(?m)^\`$script:InstallerBuildId = '(?<id>[^']+)'")
    if ($match.Success) {
        return $match.Groups['id'].Value
    }
    return $null
}

<#
.SYNOPSIS
    Checks that every app still failed at the end of a run is on the skip list.
.DESCRIPTION
    The workflow tolerates installer exit 1 only on this promise: every failure belongs to the
    justified KNOWN_PLATFORM_INCOMPATIBLE list. It is checked against the run's final outcome
    (FinalFailed: the summary's Failed row plus every failure line the retry pass did not
    recover), which is what the installer's exit code is decided from. A first-pass failure that
    succeeded on retry does not fail it, but the detail names it.

    A transcript without a summary fails: the run stopped before it finished (aborted, or an early
    exit such as winget missing), so nothing shows which apps failed.
.PARAMETER Transcript
    ConvertFrom-InstallTranscript's result.
.PARAMETER SkipApps
    The skip-listed package ids.
.RETURNS
    [pscustomobject] with Passed ([bool]) and Detail ([string]).
#>
function Test-InstallFailureContainment {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Transcript,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$SkipApps = @()
    )

    $notes = @()
    if ($Transcript.WingetNotLaunchable) {
        $notes += 'winget could not be launched, so the remaining apps failed without an install attempt'
    }
    if ($Transcript.SummaryTruncated) {
        $notes += 'the summary table was cut off, so only the per-app failure lines were read for the cut-off part'
    }

    if (-not $Transcript.HasSummary) {
        $why = 'the run stopped before its summary'
        if ($Transcript.Aborted) {
            $why = 'the run was aborted before its summary'
        }
        elseif ($null -ne $Transcript.EarlyExitCode) {
            $why = "the run stopped early with exit code $($Transcript.EarlyExitCode)"
        }
        $detail = "$why, so its failures cannot be checked"
        if ($Transcript.FinalFailed.Count -gt 0) {
            $detail += "; failed before that: $($Transcript.FinalFailed -join ', ')"
        }
        return [pscustomobject]@{ Passed = $false; Detail = (@($detail) + $notes) -join '; ' }
    }

    $uncontained = @($Transcript.FinalFailed | Where-Object { $SkipApps -notcontains $_ })
    if ($uncontained.Count -gt 0) {
        return [pscustomobject]@{ Passed = $false; Detail = (@("apps outside -SkipApps failed: $($uncontained -join ', ')") + $notes) -join '; ' }
    }

    $detail = 'no failed apps'
    if ($Transcript.FinalFailed.Count -gt 0) {
        $detail = "failed apps all skip-listed: $($Transcript.FinalFailed -join ', ')"
    }
    if ($Transcript.RecoveredOnRetry.Count -gt 0) {
        $detail += "; recovered on retry: $($Transcript.RecoveredOnRetry -join ', ')"
    }
    return [pscustomobject]@{ Passed = $true; Detail = (@($detail) + $notes) -join '; ' }
}

# One assertion row, in the shape Assert-Install.ps1 prints.
function New-TranscriptAssertionResult {
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Detail = ''
    )

    $result = 'FAIL'
    if ($Passed) {
        $result = 'PASS'
    }
    return [pscustomobject]@{
        Assertion = $Name
        Result    = $result
        Detail    = $Detail
    }
}

<#
.SYNOPSIS
    Runs every assertion that reads the installer's transcripts.
.DESCRIPTION
    The transcript half of e2e/Assert-Install.ps1 (the other half asks the machine: winget list
    per app and the Winget-AutoUpdate task). Assertions, in order:
      - a real-run transcript exists, and the latest one logs 'Installer build';
      - with -ExpectedAutoUpdatesStatus: the latest one reports 'Auto-updates: <status>' (the
        detail adds its 'Windows App Runtime:' line, which says why the installer could not install
        the framework);
      - with -InstallerPath: every transcript, the 5.1 bootstrap ones included, logs the build id
        stamped into that file, so each pass provably ran the installer under test;
      - every not-applicable app shows its 'Skipping: <id> (not applicable: <reason>)' line in
        the latest transcript;
      - containment (Test-InstallFailureContainment) for every real-run transcript;
      - with -ExpectAllSkippedOnSecondRun: the latest transcript (the second pass) skipped every
        app in -ExpectedAppIds as already installed, and installed and failed none of them, and did
        not install the Windows App Runtime framework again (work-order item 31: a first pass that
        installed it must leave it where the second pass's check finds it);
      - with -ExpectPowerShell7Bootstrap: every pass went through the Windows PowerShell 5.1
        bootstrap (one bootstrap transcript per real-run transcript), and each bootstrap
        relaunched the installer under PowerShell 7 and recorded how that run ended;
      - with -ExpectPowerShell7Installed: the earliest bootstrap (the first pass's) installed
        PowerShell 7 rather than finding one, so the bootstrap's install path really ran.
.PARAMETER LogDirectory
    The installer's log folder.
.PARAMETER ExpectedAppIds
    The applicable, not skip-listed catalog apps (the idempotence assertions).
.PARAMETER NotApplicableApps
    Ordered dictionary of id -> reason for the apps whose catalog condition is false here.
.PARAMETER SkipApps
    Skip-listed package ids (containment).
.PARAMETER ExpectAllSkippedOnSecondRun
    Adds the idempotence assertions.
.PARAMETER InstallerPath
    The installer file the runs were given; adds the build-id assertions.
.PARAMETER ExpectedAutoUpdatesStatus
    The 'Auto-updates:' status the latest run must report (e.g. 'NOT CONFIGURED').
.PARAMETER ExpectPowerShell7Bootstrap
    Adds the Windows PowerShell 5.1 bootstrap assertions.
.PARAMETER ExpectPowerShell7Installed
    Adds the assertion that the first pass's bootstrap installed PowerShell 7. For runs that
    start on a machine without it (the 5.1 leg removes it first).
.RETURNS
    Assertion rows ([pscustomobject] with Assertion, Result and Detail).
#>
function Get-TranscriptAssertionResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ExpectedAppIds = @(),
        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$NotApplicableApps = @{},
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$SkipApps = @(),
        [Parameter(Mandatory = $false)]
        [switch]$ExpectAllSkippedOnSecondRun,
        [Parameter(Mandatory = $false)]
        [string]$InstallerPath,
        [Parameter(Mandatory = $false)]
        [string]$ExpectedAutoUpdatesStatus,
        [Parameter(Mandatory = $false)]
        [switch]$ExpectPowerShell7Bootstrap,
        [Parameter(Mandatory = $false)]
        [switch]$ExpectPowerShell7Installed
    )

    $files = Get-InstallTranscriptFile -LogDirectory $LogDirectory
    $realRuns = @(foreach ($file in $files.RealRun) {
            [pscustomobject]@{ File = $file; Parsed = (ConvertFrom-InstallTranscript -Content ([string](Get-Content -LiteralPath $file.FullName -Raw))) }
        })
    $bootstraps = @(foreach ($file in $files.Bootstrap) {
            [pscustomobject]@{ File = $file; Parsed = (ConvertFrom-BootstrapTranscript -Content ([string](Get-Content -LiteralPath $file.FullName -Raw))) }
        })

    if ($realRuns.Count -eq 0) {
        New-TranscriptAssertionResult -Name 'Transcript exists' -Passed $false -Detail "no install-*.log under $LogDirectory"
        New-TranscriptAssertionResult -Name "Transcript contains 'Installer build'" -Passed $false -Detail 'no transcript to inspect'
        if ($ExpectedAutoUpdatesStatus) {
            New-TranscriptAssertionResult -Name "Transcript reports 'Auto-updates: $ExpectedAutoUpdatesStatus'" -Passed $false -Detail 'no real-run transcript'
        }
        foreach ($id in $NotApplicableApps.Keys) {
            New-TranscriptAssertionResult -Name "Not-applicable skip logged: $id" -Passed $false -Detail 'no transcript to inspect'
        }
    }
    else {
        $latest = $realRuns[-1]
        $existsDetail = "$($realRuns.Count) transcript(s); latest: $($latest.File.Name)"
        if ($bootstraps.Count -gt 0) {
            $existsDetail = "$($realRuns.Count) transcript(s) and $($bootstraps.Count) bootstrap transcript(s); latest: $($latest.File.Name)"
        }
        New-TranscriptAssertionResult -Name 'Transcript exists' -Passed $true -Detail $existsDetail
        if ($latest.Parsed.BuildId) {
            New-TranscriptAssertionResult -Name "Transcript contains 'Installer build'" -Passed $true -Detail "Installer build: $($latest.Parsed.BuildId)"
        }
        else {
            New-TranscriptAssertionResult -Name "Transcript contains 'Installer build'" -Passed $false -Detail "no 'Installer build' line in $($latest.File.Name)"
        }

        if ($ExpectedAutoUpdatesStatus) {
            $autoUpdatesDetail = "$($latest.File.Name) has no 'Auto-updates:' line"
            if ($latest.Parsed.AutoUpdatesLine) {
                $autoUpdatesDetail = "$($latest.File.Name): Auto-updates: $($latest.Parsed.AutoUpdatesLine)"
            }
            if ($latest.Parsed.WindowsAppRuntimeLine) {
                $autoUpdatesDetail += " (Windows App Runtime: $($latest.Parsed.WindowsAppRuntimeLine))"
            }
            New-TranscriptAssertionResult -Name "Transcript reports 'Auto-updates: $ExpectedAutoUpdatesStatus'" -Passed ($latest.Parsed.AutoUpdatesStatus -eq $ExpectedAutoUpdatesStatus) -Detail $autoUpdatesDetail
        }

        # Not-applicable apps: the gated skip line must appear. An app that is simply absent from
        # the transcript would mean the installer dropped it silently instead of reporting the skip.
        foreach ($id in $NotApplicableApps.Keys) {
            $expectedLine = "Skipping: $id (not applicable: $($NotApplicableApps[$id]))"
            $passed = $latest.Parsed.NotApplicable.Contains($id) -and $latest.Parsed.NotApplicable[$id] -eq $NotApplicableApps[$id]
            $detail = $expectedLine
            if (-not $passed) {
                $detail = "transcript $($latest.File.Name) has no '$expectedLine'"
            }
            New-TranscriptAssertionResult -Name "Not-applicable skip logged: $id" -Passed $passed -Detail $detail
        }

        foreach ($run in $realRuns) {
            $verdict = Test-InstallFailureContainment -Transcript $run.Parsed -SkipApps $SkipApps
            New-TranscriptAssertionResult -Name "Failures contained ($($run.File.Name))" -Passed $verdict.Passed -Detail $verdict.Detail
        }

        if ($ExpectAllSkippedOnSecondRun) {
            foreach ($id in $ExpectedAppIds) {
                $passed = $latest.Parsed.AlreadyInstalled -contains $id
                $detail = ''
                if (-not $passed) {
                    $detail = "transcript $($latest.File.Name) has no 'Skipping: $id (already installed)'"
                }
                New-TranscriptAssertionResult -Name "Second run skipped: $id" -Passed $passed -Detail $detail
            }
            # Per app, so skip-listed apps (which can legitimately install-retry-fail on this
            # platform) do not trip the idempotence assertions for everything else.
            $installedOnSecondRun = @($latest.Parsed.Installed) + @($latest.Parsed.RetrySucceeded) + @($latest.Parsed.SummaryInstalled)
            $installedOffenders = @($ExpectedAppIds | Where-Object { $installedOnSecondRun -contains $_ })
            $failedOnSecondRun = @($latest.Parsed.FirstPassFailed) + @($latest.Parsed.FinalFailed)
            $failedOffenders = @($ExpectedAppIds | Where-Object { $failedOnSecondRun -contains $_ })
            $installedDetail = ''
            if ($installedOffenders.Count -gt 0) {
                $installedDetail = "installed on second run: $($installedOffenders -join ', ')"
            }
            $failedDetail = ''
            if ($failedOffenders.Count -gt 0) {
                $failedDetail = "failed on second run: $($failedOffenders -join ', ')"
            }
            New-TranscriptAssertionResult -Name 'Second run installed nothing (non-skip-listed)' -Passed ($installedOffenders.Count -eq 0) -Detail $installedDetail
            New-TranscriptAssertionResult -Name 'Second run failed nothing (non-skip-listed)' -Passed ($failedOffenders.Count -eq 0) -Detail $failedDetail
            $runtimeDetail = ''
            if ($latest.Parsed.WindowsAppRuntimeInstalled) {
                $runtimeDetail = "$($latest.File.Name): Windows App Runtime: $($latest.Parsed.WindowsAppRuntimeLine)"
            }
            New-TranscriptAssertionResult -Name 'Second run did not install the Windows App Runtime again' -Passed (-not $latest.Parsed.WindowsAppRuntimeInstalled) -Detail $runtimeDetail
        }
    }

    # Every pass ran the installer under test: each transcript, the 5.1 bootstrap ones included,
    # logs the build id stamped into -InstallerPath.
    if ($InstallerPath -and ($realRuns.Count + $bootstraps.Count) -gt 0) {
        $expectedBuildId = $null
        if (Test-Path -LiteralPath $InstallerPath -PathType Leaf) {
            $expectedBuildId = Get-InstallerBuildIdFromScript -Content ([string](Get-Content -LiteralPath $InstallerPath -Raw))
        }
        if (-not $expectedBuildId) {
            New-TranscriptAssertionResult -Name 'Build id of the installer under test' -Passed $false -Detail "no `$script:InstallerBuildId line in '$InstallerPath'"
        }
        else {
            $expectedBuildLine = "Installer build: $expectedBuildId"
            foreach ($run in @($realRuns) + @($bootstraps)) {
                if ($run.Parsed.BuildId -eq $expectedBuildId) {
                    New-TranscriptAssertionResult -Name "Ran the installer under test ($($run.File.Name))" -Passed $true -Detail $expectedBuildLine
                }
                else {
                    $logged = "no 'Installer build' line"
                    if ($run.Parsed.BuildId) {
                        $logged = "logged 'Installer build: $($run.Parsed.BuildId)'"
                    }
                    New-TranscriptAssertionResult -Name "Ran the installer under test ($($run.File.Name))" -Passed $false -Detail "expected '$expectedBuildLine' from $InstallerPath, $logged"
                }
            }
        }
    }

    if ($ExpectPowerShell7Bootstrap) {
        # One bootstrap per pass: a 5.1 start always writes one, and a pass whose bootstrap could
        # not start PowerShell 7 leaves a bootstrap transcript with no PowerShell 7 transcript.
        $countDetail = "$($bootstraps.Count) bootstrap transcript(s), $($realRuns.Count) PowerShell 7 run transcript(s)"
        New-TranscriptAssertionResult -Name 'Every pass went through the PowerShell 7 bootstrap' -Passed ($bootstraps.Count -gt 0 -and $bootstraps.Count -eq $realRuns.Count) -Detail $countDetail
        foreach ($bootstrap in $bootstraps) {
            $parsed = $bootstrap.Parsed
            $passed = [bool]$parsed.RelaunchPath -and $null -ne $parsed.ChildExitCode
            if ($passed) {
                $how = 'found PowerShell 7'
                if ($parsed.InstalledPowerShell7) {
                    $how = 'installed PowerShell 7'
                }
                $detail = "$how, relaunched under $($parsed.RelaunchPath), that run ended with exit code $($parsed.ChildExitCode)"
            }
            elseif ($parsed.RelaunchPath) {
                $detail = "relaunched under $($parsed.RelaunchPath) but never logged how that run ended"
            }
            else {
                $detail = 'never relaunched the installer under PowerShell 7 (see the bootstrap transcript)'
            }
            New-TranscriptAssertionResult -Name "Bootstrap relaunched under PowerShell 7 ($($bootstrap.File.Name))" -Passed $passed -Detail $detail
        }
    }

    if ($ExpectPowerShell7Installed) {
        # The first pass starts without PowerShell 7, so its bootstrap must install it. A bootstrap
        # that found one instead (runner preparation left it in place, or another pwsh is on the
        # machine) leaves the install path, which is what this run is for, untested.
        $name = 'First pass installed PowerShell 7'
        if ($bootstraps.Count -eq 0) {
            New-TranscriptAssertionResult -Name $name -Passed $false -Detail 'no bootstrap transcript'
        }
        else {
            $first = $bootstraps[0]
            if ($first.Parsed.InstalledPowerShell7) {
                New-TranscriptAssertionResult -Name $name -Passed $true -Detail "$($first.File.Name): PowerShell 7 is installed."
            }
            else {
                $found = 'never logged installing it'
                if ($first.Parsed.RelaunchPath) {
                    $found = "found $($first.Parsed.RelaunchPath) instead of installing it"
                }
                New-TranscriptAssertionResult -Name $name -Passed $false -Detail "$($first.File.Name) $found; runner preparation did not remove PowerShell 7 (see its warning), or the bootstrap found another pwsh"
            }
        }
    }
}
