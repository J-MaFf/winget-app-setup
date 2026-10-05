# Windows PowerShell 5.1 bootstrap (issue #225). Everything in this file, and everything it and the
# tail's 5.1 branch call, runs under Windows PowerShell 5.1 before the hand-off to PowerShell 7, so it
# must stay 5.1-runtime compatible: no ternary or null-coalescing, no 3-argument Join-Path, .NET
# Framework 4.x APIs only. That covers this file's functions and: Write-Info, Write-WarningMessage,
# Write-ErrorMessage, Write-Success, Test-IsAdmin, Get-CurrentWindowsPrincipal, Test-IsSystemAccount,
# Get-WingetAgreementArgs, Invoke-WingetProcess with Private/ProcessInvocation.ps1,
# Resolve-WingetExecutable and the Private/MachineContext.ps1 helpers it reaches,
# Get-WingetExitCodeInfo, Format-WingetExitCode and Test-WingetRestartRequiredResult
# (Private/WingetResultCodes.ps1), Get-ScriptExecutionPolicyBlock, Test-LaunchedByGroupPolicyScript,
# Test-FullLanguageMode, Get-PowerShellLanguageMode, Test-EffectiveNonInteractive,
# Test-NonInteractiveRequested, Test-IsContinuousIntegration, Resolve-InstallerRunBudget and
# Get-InstallerRunBudgetArgument (Private/RunBudget.ps1), Start-InstallerTranscript,
# Grant-InstallLogReadAccess, Write-Prompt, Exit-Installer, Write-InstallerExitNotice,
# Wait-InstallerExitKeyPress, Write-InstallerReportHint, Get-DiagnosticsCommandLine,
# Write-InstallerNotStartedResult, Complete-InstallerRun and the Private/RunRecord.ps1 functions
# they reach, and Unlock-InstallerRun; and, for -CollectDiagnostics, Invoke-DiagnosticsCollection
# and what Private/Diagnostics.ps1 lists. Check a function against these constraints before calling
# it from here: the build's guards keep the file 5.1-parseable, not 5.1-runnable.
# tests/PowerShell7Bootstrap.Tests.ps1 pins this file's behaviour.

<#
.SYNOPSIS
    Verifies a candidate pwsh executable actually launches and is version 7 or newer.
.DESCRIPTION
    Existence is not enough: a pwsh.exe on PATH can be PowerShell 6 (relaunching under it would loop
    through the version dispatch), and a WindowsApps alias passes Test-Path even when its package is
    broken. One version query checks both.
.PARAMETER Path
    Candidate executable path.
.OUTPUTS
    [bool] True when the executable runs and reports PSVersion.Major 7 or newer.
#>
function Test-PowerShell7Executable {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $majorVersion = & $Path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null
        return ([int]($majorVersion | Select-Object -Last 1) -ge 7)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Locates a working PowerShell 7+ executable, or returns $null.
.DESCRIPTION
    PATH first, then the known install locations: this process's PATH is stale right after an
    install, a 32-bit host (some RMM agents) sees 'Program Files (x86)' as ProgramFiles (hence
    ProgramW6432), and the MSIX build lands an alias under the user's WindowsApps. Every candidate
    must pass Test-PowerShell7Executable.
.OUTPUTS
    [string] Full path to a validated pwsh.exe, or $null when PowerShell 7 is not available.
#>
function Find-PowerShell7 {
    $candidatePaths = @()
    $pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $candidatePaths += ($pwshCommand | Select-Object -First 1).Source
    }
    if ($env:ProgramFiles) {
        $candidatePaths += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    }
    if ($env:ProgramW6432) {
        $candidatePaths += (Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe')
    }
    if ($env:LOCALAPPDATA) {
        $candidatePaths += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    }
    foreach ($candidate in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        if (Test-PowerShell7Executable -Path $candidate) {
            return $candidate
        }
    }
    return $null
}

<#
.SYNOPSIS
    Tests whether an error looks like GitHub's rate limiting ("429" / "Too Many Requests" in its
    text, issue #274), to tell throttling apart from any other network failure.
.PARAMETER ErrorRecord
    The $_ caught from a failed Invoke-RestMethod call.
.OUTPUTS
    [bool] True when the error text mentions HTTP 429 / "Too Many Requests".
#>
function Test-GitHubRateLimitError {
    param (
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )
    return ($ErrorRecord.ToString() -match '429|Too Many Requests')
}

<#
.SYNOPSIS
    Resolves a PowerShell 7 release that ships an MSI into an MSI download URL for this machine.
.DESCRIPTION
    Reads tools/metadata.json, as aka.ms/install-powershell.ps1 does (issue #263), so no version is
    pinned here; a raw.githubusercontent.com file, not the releases API, whose 60 requests an hour
    per IP an office NAT can use up. The current release (ReleaseTag) while it ships an MSI,
    otherwise the newest LTS release that does (P2-17): 7.7 and later ship no MSI, while 7.6 LTS
    keeps one. LTSReleaseTag is a list, so the newest is picked by version. The architecture comes
    from PROCESSOR_ARCHITEW6432, then PROCESSOR_ARCHITECTURE (a 32-bit host sees x86 on 64-bit
    Windows), not the slow Get-ComputerInfo.
.PARAMETER MetadataUrl
    Release metadata endpoint. Parameterized for tests.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the metadata request.
.OUTPUTS
    [hashtable] @{ Version; FileName; Url }, or $null when the metadata could not be read, lists no
    release that ships an MSI, or the architecture is unknown.
#>
function Get-PowerShell7MsiInfo {
    param (
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl = 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json',
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 30
    )

    $architectureName = $env:PROCESSOR_ARCHITEW6432
    if (-not $architectureName) {
        $architectureName = $env:PROCESSOR_ARCHITECTURE
    }
    $architecture = $null
    switch ($architectureName) {
        'AMD64' { $architecture = 'x64' }
        'ARM64' { $architecture = 'arm64' }
        'x86' { $architecture = 'x86' }
    }
    if (-not $architecture) {
        Write-WarningMessage ("Unrecognized processor architecture '{0}'; cannot pick a PowerShell 7 MSI." -f $architectureName)
        return $null
    }

    $currentTag = ''
    $ltsTags = @()
    try {
        $metadata = Invoke-RestMethod -Uri $MetadataUrl -TimeoutSec $TimeoutSeconds
        if ($metadata) {
            $currentTag = [string]$metadata.ReleaseTag
            $ltsTags = @($metadata.LTSReleaseTag | Where-Object { $_ })
        }
    }
    catch {
        Write-WarningMessage "Could not read the PowerShell release metadata: $_"
        if (Test-GitHubRateLimitError -ErrorRecord $_) {
            $script:PowerShell7BootstrapGitHubThrottled = $true
        }
        return $null
    }

    # The newest listed release below 7.7, the first version with no MSI. [version] compares Major,
    # then Minor, then Build, so every 7.6.x sorts below 7.7.0. The current release is never older
    # than an LTS one, so it wins whenever it still ships an MSI.
    $firstVersionWithoutMsi = [version]'7.7.0'
    $releaseTag = $null
    $releaseVersion = $null
    foreach ($candidateTag in (@($currentTag) + $ltsTags)) {
        if ([string]$candidateTag -match '^v?(\d+\.\d+\.\d+)$') {
            $candidateVersion = [version]$Matches[1]
            if ($candidateVersion -lt $firstVersionWithoutMsi -and (-not $releaseVersion -or $candidateVersion -gt $releaseVersion)) {
                $releaseTag = [string]$candidateTag
                $releaseVersion = $candidateVersion
            }
        }
    }
    if (-not $releaseTag) {
        Write-WarningMessage ('The PowerShell release metadata lists no release that ships an MSI installer (current release: {0}; LTS releases: {1}). PowerShell 7.7 and later ship none.' -f $currentTag, ($ltsTags -join ', '))
        return $null
    }

    $version = ($releaseTag -replace '^v', '')
    if ($currentTag -and $releaseTag -ne $currentTag) {
        Write-Info ('PowerShell {0}, the current release, ships no MSI installer, so this installs PowerShell {1} (LTS) instead. The installer runs on any PowerShell 7.' -f ($currentTag -replace '^v', ''), $version)
    }
    $fileName = 'PowerShell-' + $version + '-win-' + $architecture + '.msi'
    return @{
        Version  = $version
        FileName = $fileName
        Url      = 'https://github.com/PowerShell/PowerShell/releases/download/v' + $version + '/' + $fileName
    }
}

<#
.SYNOPSIS
    Downloads a URL to a file with a stall timeout, an overall time limit, and progress output.
.DESCRIPTION
    Under Windows PowerShell 5.1, Invoke-WebRequest has no read timeout, so a link that stops
    sending blocks forever with no output (issue #263). HttpWebRequest's ReadWriteTimeout bounds
    each read, -MaximumSeconds bounds a trickle that never stalls, and a progress line tells a slow
    download from a hung one.
.PARAMETER Uri
    Source URL.
.PARAMETER DestinationPath
    File to write. Its parent directory must already exist.
.PARAMETER StallTimeoutSeconds
    Maximum seconds the connection may go without delivering data before the download is abandoned.
    Also bounds the initial connect/response phase.
.PARAMETER MaximumSeconds
    Maximum total seconds for the whole download.
.PARAMETER ProgressIntervalSeconds
    How often to print a progress line.
.OUTPUTS
    [bool] True when the file was written completely.
#>
function Save-WebFileWithTimeout {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [int]$StallTimeoutSeconds = 60,
        [Parameter(Mandatory = $false)]
        [int]$MaximumSeconds = 900,
        [Parameter(Mandatory = $false)]
        [int]$ProgressIntervalSeconds = 10
    )

    $response = $null
    $responseStream = $null
    $fileStream = $null
    try {
        $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = $StallTimeoutSeconds * 1000
        $request.ReadWriteTimeout = $StallTimeoutSeconds * 1000
        $request.UserAgent = 'winget-app-setup'
        # Use the machine's configured (WinINET) proxy and authenticate to it as the current user.
        # An authenticating corporate proxy that 407s otherwise looks like just another stall, and
        # this bootstrap's whole job is to work on managed machines.
        if ($request.Proxy) {
            $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }

        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $totalText = 'unknown size'
        if ($totalBytes -gt 0) {
            $totalText = ('{0:N1} MB' -f ($totalBytes / 1MB))
        }
        Write-Info ('  Downloading {0}...' -f $totalText)

        $responseStream = $response.GetResponseStream()
        $fileStream = New-Object System.IO.FileStream($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $buffer = New-Object byte[] 131072
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastReportSeconds = 0
        $bytesReceived = 0

        while ($true) {
            $count = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) {
                break
            }
            $fileStream.Write($buffer, 0, $count)
            $bytesReceived = $bytesReceived + $count

            $elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
            if ($elapsedSeconds -gt $MaximumSeconds) {
                throw ('the download exceeded the {0}-second limit after {1:N1} MB' -f $MaximumSeconds, ($bytesReceived / 1MB))
            }
            if (($elapsedSeconds - $lastReportSeconds) -ge $ProgressIntervalSeconds) {
                $lastReportSeconds = $elapsedSeconds
                if ($totalBytes -gt 0) {
                    Write-Info ('  {0:N1} MB of {1:N1} MB ({2:N0}%)' -f ($bytesReceived / 1MB), ($totalBytes / 1MB), (($bytesReceived / $totalBytes) * 100))
                }
                else {
                    Write-Info ('  {0:N1} MB downloaded' -f ($bytesReceived / 1MB))
                }
            }
        }

        $fileStream.Close()
        $fileStream = $null
        # A truncated response still "completes" the read loop, and msiexec's failure on a partial
        # MSI is far less legible than saying so here.
        if ($totalBytes -gt 0 -and $bytesReceived -ne $totalBytes) {
            Write-WarningMessage ('The download ended early: got {0:N1} MB of {1:N1} MB.' -f ($bytesReceived / 1MB), ($totalBytes / 1MB))
            return $false
        }
        Write-Info ('  Downloaded {0:N1} MB in {1:N0}s.' -f ($bytesReceived / 1MB), $stopwatch.Elapsed.TotalSeconds)
        return $true
    }
    catch {
        Write-WarningMessage "The download failed: $_"
        return $false
    }
    finally {
        if ($fileStream) { try { $fileStream.Close() } catch { } }
        if ($responseStream) { try { $responseStream.Close() } catch { } }
        if ($response) { try { $response.Close() } catch { } }
    }
}

<#
.SYNOPSIS
    Tests that a downloaded PowerShell MSI carries a valid Authenticode signature from Microsoft.
.DESCRIPTION
    msiexec, usually elevated, installs an altered package without complaint (P3-17), and a proxy's
    error page would only give msiexec's 1620. Status 'Valid' (matches the content, chains to a
    trusted root) and a certificate common name of exactly 'Microsoft Corporation'.
.PARAMETER Path
    The downloaded MSI.
.OUTPUTS
    [bool] True when the signature is valid and Microsoft's.
#>
function Test-PowerShell7MsiSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not check the signature of the downloaded PowerShell MSI, so it was not installed: $_"
        return $false
    }

    $status = 'unknown'
    $signer = 'none'
    if ($signature) {
        if ("$($signature.Status)") {
            $status = "$($signature.Status)"
        }
        if ($signature.SignerCertificate -and $signature.SignerCertificate.Subject) {
            $signer = [string]$signature.SignerCertificate.Subject
        }
    }
    if ($status -eq 'Valid' -and $signer -match '(^|,\s*)CN=Microsoft Corporation(\s*,|$)') {
        Write-Info ('  Signature verified: {0}' -f $signer)
        return $true
    }
    Write-WarningMessage ('The downloaded file is not a PowerShell installer signed by Microsoft (signature status: {0}; signer: {1}), so it was not installed. A proxy or captive portal may have answered with a web page instead of the MSI, or the file was altered on the way.' -f $status, $signer)
    return $false
}

<#
.SYNOPSIS
    Installs PowerShell 7 by downloading the official MSI and running msiexec, all time-bounded.
.DESCRIPTION
    The fallback when winget is unavailable (issue #263): visible progress, a bounded download, a
    bounded install, and Microsoft's signature checked before msiexec sees the file
    (Test-PowerShell7MsiSignature).
      - 3010 counts as success (pwsh.exe is there) and sets $script:PowerShell7BootstrapRestartRequired,
        so the bootstrap ends a successful run with 3010: the relaunched run cannot see this restart.
      - 1618 (another installation holds Windows Installer, common on a new PC) is retried after a
        wait (P2-13).
      - -MsiLogDirectory gets msiexec's verbose log (/l*v), one file per attempt.
    Nothing runs after this path, so its download limit is generous (60 minutes, about 30 KB/s for
    110 MB); the 60-second stall timeout catches a dead link.
.PARAMETER MetadataUrl
    Forwarded to Get-PowerShell7MsiInfo. Parameterized for tests.
.PARAMETER DownloadTimeoutSeconds
    Maximum seconds for the whole MSI download, forwarded to Save-WebFileWithTimeout as
    -MaximumSeconds. A link that is slow but still delivering data gets this long; one that stops
    delivering data fails after the 60-second stall timeout instead.
.PARAMETER InstallTimeoutSeconds
    Maximum seconds for one msiexec attempt before it is killed. msiexec does not wait for another
    installation (it returns 1618), so reaching this means it hung.
.PARAMETER MsiLogDirectory
    Folder for msiexec's verbose logs, named pwsh-msi-<timestamp>-<attempt>.log. Empty: no msiexec
    log. msiexec fails the whole install (1622) when it cannot open its log.
.PARAMETER BusyRetryCount
    How many times to retry after msiexec exit code 1618.
.PARAMETER BusyRetryDelaySeconds
    Seconds to wait before each of those retries.
.OUTPUTS
    [bool] True when msiexec reported success (0 or 3010).
#>
function Install-PowerShell7FromMsi {
    param (
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl = 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json',
        [Parameter(Mandatory = $false)]
        [int]$DownloadTimeoutSeconds = 3600,
        [Parameter(Mandatory = $false)]
        [int]$InstallTimeoutSeconds = 900,
        [Parameter(Mandatory = $false)]
        [string]$MsiLogDirectory,
        [Parameter(Mandatory = $false)]
        [int]$BusyRetryCount = 6,
        [Parameter(Mandatory = $false)]
        [int]$BusyRetryDelaySeconds = 30
    )

    $msiInfo = Get-PowerShell7MsiInfo -MetadataUrl $MetadataUrl
    if (-not $msiInfo) {
        return $false
    }

    # Unique per-run directory for the same reason the relaunch path uses one: a predictable temp
    # filename for a file this process is about to hand to an elevated msiexec is a swap target.
    $downloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-pwsh-' + [System.Guid]::NewGuid().ToString('N'))
    $msiPath = Join-Path $downloadDirectory $msiInfo.FileName
    try {
        # -ErrorAction Stop, without which this catch would be decorative: a New-Item failure is
        # non-terminating under 5.1's default preference, so the run would continue to a download
        # into a directory that does not exist and report the far less legible stream error.
        [void](New-Item -Path $downloadDirectory -ItemType Directory -Force -ErrorAction Stop)
    }
    catch {
        Write-WarningMessage "Could not create a temporary directory for the PowerShell 7 MSI: $_"
        return $false
    }

    try {
        Write-Info ('Downloading PowerShell {0} ({1})...' -f $msiInfo.Version, $msiInfo.FileName)
        if (-not (Save-WebFileWithTimeout -Uri $msiInfo.Url -DestinationPath $msiPath -MaximumSeconds $DownloadTimeoutSeconds)) {
            return $false
        }
        # msiexec checks no signature itself (review finding P3-17).
        if (-not (Test-PowerShell7MsiSignature -Path $msiPath)) {
            return $false
        }

        Write-Info 'Installing PowerShell 7 (this takes about a minute)...'
        $attempt = 0
        while ($true) {
            $attempt = $attempt + 1
            # Quoted because the MSI path contains a GUID-named directory under the user's temp
            # path, which can sit under a profile directory containing spaces.
            $msiArguments = @('/i', ('"' + $msiPath + '"'), '/quiet', '/norestart')
            $msiLogPath = $null
            if ($MsiLogDirectory) {
                $msiLogPath = Join-Path $MsiLogDirectory ('pwsh-msi-{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), $attempt)
                $msiArguments += @('/l*v', ('"' + $msiLogPath + '"'))
                Write-Info ('  msiexec log: {0}' -f $msiLogPath)
            }

            $msiProcess = $null
            try {
                $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -PassThru -ErrorAction Stop
            }
            catch {
                Write-WarningMessage "msiexec could not be started: $_"
                return $false
            }
            if (-not $msiProcess) {
                Write-WarningMessage 'msiexec could not be started.'
                return $false
            }

            if (-not $msiProcess.WaitForExit($InstallTimeoutSeconds * 1000)) {
                try { $msiProcess.Kill() } catch { }
                Write-WarningMessage ('The PowerShell 7 MSI install did not finish within {0} seconds and was stopped.' -f $InstallTimeoutSeconds)
                return $false
            }

            $msiExitCode = $msiProcess.ExitCode
            if ($msiExitCode -eq 3010) {
                $script:PowerShell7BootstrapRestartRequired = $true
                Write-WarningMessage 'PowerShell 7 is installed, and a restart finishes the installation (msiexec exit code 3010). The run continues; restart this PC once it has finished.'
                return $true
            }
            if ($msiExitCode -eq 0) {
                return $true
            }
            if ($msiExitCode -eq 1618 -and $attempt -le $BusyRetryCount) {
                Write-WarningMessage ('Windows Installer is busy with another installation (msiexec exit code 1618). Waiting {0} seconds before trying again (retry {1} of {2})...' -f $BusyRetryDelaySeconds, $attempt, $BusyRetryCount)
                Start-Sleep -Seconds $BusyRetryDelaySeconds
                continue
            }
            if ($msiExitCode -eq 1618) {
                Write-WarningMessage ('The PowerShell 7 MSI install failed: Windows Installer was still busy with another installation after {0} retries (msiexec exit code 1618). Re-run the installer once that installation has finished.' -f $BusyRetryCount)
            }
            else {
                Write-WarningMessage ('The PowerShell 7 MSI install failed (msiexec exit code {0}).' -f $msiExitCode)
            }
            if ($msiLogPath) {
                Write-WarningMessage ('msiexec''s log of the failed attempt: {0}' -f $msiLogPath)
            }
            return $false
        }
    }
    finally {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Reads the build id stamped into a copy of the generated installer: a line of its own that starts
    with the $script:InstallerBuildId assignment (issue #189), so indented code mentioning the
    variable never counts.
.PARAMETER Text
    The installer text.
.OUTPUTS
    [string] The build id, or $null when the text carries none (it is not the installer).
#>
function Get-InstallerBuildIdFromText {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, '(?m)^\$script:InstallerBuildId = ''([^'']+)''')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

<#
.SYNOPSIS
    Downloads the running installer build again, for the PowerShell 7 relaunch of an irm | iex run.
.DESCRIPTION
    An irm | iex run has no file to relaunch, so it downloads the installer again (P2-18). Each URL
    is tried in order (raw.githubusercontent.com, then the jsDelivr mirror for its throttling), and a
    copy is used only when its build id is the running build's, so a branch run never relaunches
    main's code and an error page is never run.
.PARAMETER Url
    URLs to try, in order.
.PARAMETER ExpectedBuildId
    The running installer's build id. Empty: any copy that carries a build id is accepted.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for each download.
.OUTPUTS
    [string] The installer text, or $null when no URL served the expected build.
#>
function Get-PowerShell7RelaunchInstaller {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Url,
        [Parameter(Mandatory = $false)]
        [string]$ExpectedBuildId,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    foreach ($candidateUrl in $Url) {
        Write-Info ('Downloading the installer for the PowerShell 7 relaunch from {0}...' -f $candidateUrl)
        $installerText = $null
        try {
            $installerText = [string](Invoke-RestMethod -Uri $candidateUrl -TimeoutSec $TimeoutSeconds)
        }
        catch {
            Write-WarningMessage ('  The download failed: {0}' -f $_)
            continue
        }
        $downloadedBuildId = Get-InstallerBuildIdFromText -Text $installerText
        if (-not $downloadedBuildId) {
            Write-WarningMessage '  That download is not the installer: it carries no installer build id.'
            continue
        }
        if ($ExpectedBuildId -and $downloadedBuildId -ne $ExpectedBuildId) {
            Write-WarningMessage ('  That is installer build {0}, not build {1} that this run started with, so it is not used.' -f $downloadedBuildId, $ExpectedBuildId)
            continue
        }
        return $installerText
    }
    return $null
}

<#
.SYNOPSIS
    Finds or installs PowerShell 7, then relaunches the installer under pwsh in the same console.
.DESCRIPTION
    New PCs have only Windows PowerShell 5.1, so the one-liner bootstraps from it (issue #225):
      1. An existing pwsh.exe (Find-PowerShell7) is used at once.
      2. Otherwise it is installed, without asking (issue #230): winget first; when winget is absent
         or fails, the signed MSI (Install-PowerShell7FromMsi). -WhatIf previews instead.
      3. The installer is relaunched under pwsh -NoProfile -ExecutionPolicy Bypass in the same
         console, with the caller's switches, and the child's exit code is returned.
    A file-based run relaunches its own $PSCommandPath (so a PR's e2e run tests the PR's bytes). An
    irm | iex run has no file, and under iex $MyInvocation holds the outer command line, not the
    script, so the installer is downloaded again and only the same build is used
    (Get-PowerShell7RelaunchInstaller). Its temp folder is removed once the relaunched run ends
    (P3-42); an elevated relaunch runs a checked copy (P3-11).

    No aka.ms/install-powershell.ps1 fallback (P2-17, P3-17): it skips the signature check, runs an
    unchecked script, has no time limits, and 404s once the current release is 7.7.
.PARAMETER WhatIf
    Dry-run intent, forwarded to the relaunch. When PowerShell 7 is missing, the bootstrap prints
    what a real run would do and returns 0 without installing anything.
.PARAMETER NonInteractive
    Forwarded to the relaunch, and nothing else: the install never asks, and its winget call always
    passes --disable-interactivity.
.PARAMETER SkipSystemCheck
    Forwarded to the relaunch untouched.
.PARAMETER CommandPath
    The caller's $PSCommandPath (inside a function it would name this file). Empty under
    `irm | iex`, which takes the download path.
.PARAMETER InstallerUrl
    URLs the iex relaunch path downloads the installer from, tried in order: by default the
    one-liner's raw.githubusercontent.com URL, then the jsDelivr mirror the readme offers when raw
    is rate-limiting the network. Parameterized for tests.
.PARAMETER ExpectedBuildId
    The running installer's build id ($script:InstallerBuildId). The iex relaunch path uses only a
    download of this same build.
.PARAMETER LogDirectory
    The bootstrap transcript's folder, or empty. Forwarded to Install-PowerShell7FromMsi for
    msiexec's log, and to the winget install for its --log.
.PARAMETER AdditionalArguments
    Further arguments for the relaunch, after the switches: the run's time budget
    (Get-InstallerRunBudgetArgument), so the PowerShell 7 run keeps the deadline this run started
    with. The pattern Restart-WithElevation accepts: parameter names, and values without spaces or
    quotes.
.OUTPUTS
    [int] Exit code for the tail dispatch to propagate: the relaunched run's exit code, 0 for a
    -WhatIf preview, or 7 when PowerShell 7 could not be installed or relaunched (including a Group
    Policy execution policy for PowerShell 7 of AllSigned or Restricted, checked before anything is
    installed). When installing PowerShell 7 needs a restart and the relaunched run returned 0, the
    result is 3010, since that run cannot see this restart; any other code it returned is kept.
    Sets $script:PowerShell7BootstrapRelaunched once a relaunched run has ended, so the tail knows
    that run already showed its outcome.
#>
function Invoke-PowerShell7Bootstrap {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,
        [Parameter(Mandatory = $false)]
        [string]$CommandPath,
        [Parameter(Mandatory = $false)]
        [string[]]$InstallerUrl = @(
            'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1',
            'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1'
        ),
        [Parameter(Mandatory = $false)]
        [string]$ExpectedBuildId,
        [Parameter(Mandatory = $false)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(?:-[A-Za-z][A-Za-z0-9]*|[0-9][0-9A-Za-z:.-]*)\z')]
        [string[]]$AdditionalArguments = @()
    )

    $script:PowerShell7BootstrapRelaunched = $false

    Write-WarningMessage 'This installer requires PowerShell 7+ (pwsh), but this session is Windows PowerShell. Handing off...'

    # Relaunch-loop guard: set before the relaunch and inherited by the child, so seeing it here
    # means a relaunched child came back to the version dispatch. Fail fast instead of looping.
    if ($env:WINGET_APP_SETUP_PS7_BOOTSTRAP -eq '1') {
        Write-ErrorMessage 'The PowerShell 7 bootstrap re-entered itself after a relaunch: the relaunched PowerShell still reports a version below 7. Install PowerShell 7 manually (winget install Microsoft.PowerShell) and re-run this installer from a pwsh prompt.'
        return 7
    }

    # Group Policy's PowerShell 7 execution policy overrides the relaunch's -ExecutionPolicy Bypass;
    # under AllSigned or Restricted pwsh would refuse the file. Checked before anything is installed,
    # both scopes, since the relaunch runs as this same account.
    $relaunchPolicyBlock = Get-ScriptExecutionPolicyBlock -Engine PowerShell7
    if ($relaunchPolicyBlock) {
        $policyMessage = '{0}, which -ExecutionPolicy Bypass on the command line cannot override, so PowerShell 7 cannot run this installer from a file, and the run cannot continue in PowerShell 7. Ask whoever manages this PC''s policies to allow scripts ({1}), then re-run the installer.' -f $relaunchPolicyBlock.Description, $relaunchPolicyBlock.GroupPolicyPath
        if ($WhatIf) {
            Write-Info "[DRY-RUN] $policyMessage A real run would stop here with exit code 7."
            return 0
        }
        Write-ErrorMessage "$policyMessage Nothing was installed."
        return 7
    }

    # Reset per call: set deep in Get-PowerShell7MsiInfo and read by the failure message below
    # (issue #274), so a later call in the same process must not inherit it.
    $script:PowerShell7BootstrapGitHubThrottled = $false
    # Set by the PowerShell 7 install below when it needs a restart to finish; reset per call for
    # the same reason.
    $script:PowerShell7BootstrapRestartRequired = $false

    # 5.1's .NET Framework can default to a protocol set without TLS 1.2 on older Windows 10
    # builds, which breaks the Invoke-RestMethod calls below. Opt in additively; never downgrade.
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Best-effort: on anything modern the default already includes TLS 1.2.
    }

    $pwshPath = Find-PowerShell7

    if (-not $pwshPath) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] PowerShell 7 is not installed. A real run would install it (winget install Microsoft.PowerShell, with an MSI fallback) and relaunch this installer under pwsh. Run from a pwsh prompt for the full preview.'
            return 0
        }

        # No consent prompt (issue #230): PowerShell 7 is required, and the prompt stalled the
        # one-liner. -NonInteractive is only forwarded to the relaunch.
        Write-Info 'PowerShell 7 (pwsh) is required but not installed. Installing it now...'

        # Not elevated, a machine-wide install may show a UAC prompt or fail: warn and go on.
        $isAdmin = Test-IsAdmin
        if (-not $isAdmin) {
            Write-WarningMessage 'Not running as administrator: the PowerShell 7 install may show a UAC prompt or fail. If it fails, re-run this installer from an elevated prompt.'
        }

        $wingetCommand = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
        if ($wingetCommand) {
            Write-Info 'Installing PowerShell 7 via winget...'
            # --disable-interactivity always (issue #230): the one-liner reads as interactive, so it
            # was the run most likely to let winget stop and ask. Get-WingetAgreementArgs keeps this
            # call in line with the others.
            $wingetArguments = @('install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget') + (Get-WingetAgreementArgs)
            if (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) {
                # Unattended: the MSI installs with /quiet instead of /passive.
                $wingetArguments += '--silent'
            }
            # Invoke-WingetProcess (review findings P2-5, P2-6): time-limited, winget's output goes
            # into the bootstrap transcript, the MSI's log into the logs folder, and a winget that
            # cannot start is reported instead of thrown, so it degrades to the MSI fallback below.
            $wingetRun = Invoke-WingetProcess -ArgumentList $wingetArguments -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetInstall) -LogDirectory $LogDirectory
            if ($wingetRun.LaunchFailed) {
                Write-WarningMessage "winget could not be started: $($wingetRun.LaunchError)"
            }
            elseif ($wingetRun.TimedOut) {
                Write-WarningMessage 'winget did not finish installing PowerShell 7 in time and was stopped.'
            }
            elseif (Test-WingetRestartRequiredResult -ExitCode $wingetRun.ExitCode -Output $wingetRun.Output) {
                # Installed, and a restart finishes it (review finding P3-16): winget's restart
                # warning on exit 0, or 0x8A150109 / 0x8A15010B.
                $script:PowerShell7BootstrapRestartRequired = $true
                $restartDetail = ''
                if ($wingetRun.ExitCode -ne 0) {
                    $restartDetail = ' (exit code {0})' -f (Format-WingetExitCode -ExitCode $wingetRun.ExitCode)
                }
                Write-WarningMessage ('winget reported that a restart finishes the PowerShell 7 installation{0}. The run continues; restart this PC once it has finished.' -f $restartDetail)
            }
            elseif ($wingetRun.ExitCode -ne 0) {
                Write-WarningMessage ('winget could not install PowerShell 7 (exit code {0}).' -f (Format-WingetExitCode -ExitCode $wingetRun.ExitCode))
                if ($wingetRun.LogPath -and (Test-Path -LiteralPath $wingetRun.LogPath)) {
                    Write-Info "Installer log: $($wingetRun.LogPath)"
                }
            }
            $pwshPath = Find-PowerShell7
        }
        elseif (Test-IsSystemAccount) {
            # SYSTEM has no `winget` command (winget is set up per user account). Using the
            # machine-wide winget.exe here too is a follow-up.
            Write-Info 'Running as SYSTEM, which has no winget command of its own (winget is set up for each user account), so PowerShell 7 is installed without winget.'
        }
        else {
            Write-WarningMessage 'winget is not available on this machine.'
        }

        if (-not $pwshPath) {
            # The signed MSI, with progress and time limits; nothing follows it. PowerShell 7 is
            # looked for again even after a failure, in case msiexec installed it anyway.
            Write-Info 'Falling back to the official PowerShell MSI installer...'
            [void](Install-PowerShell7FromMsi -MsiLogDirectory $LogDirectory)
            $pwshPath = Find-PowerShell7
        }

        if (-not $pwshPath) {
            if ($script:PowerShell7BootstrapGitHubThrottled) {
                # winget already failed, so pointing at 'source reset' costs nothing, and that path
                # does not depend on GitHub (issue #274).
                Write-ErrorMessage 'PowerShell 7 could not be installed automatically: GitHub is rate-limiting this network (429 Too Many Requests), and the MSI fallback reads its release list from GitHub. If winget failed above with a source error, try "winget source reset --force" and re-run - that path does not depend on GitHub. Otherwise wait a while for the throttle to clear, or install PowerShell 7 manually (winget install Microsoft.PowerShell, or see https://aka.ms/powershell) from a machine on a different network.'
            }
            else {
                Write-ErrorMessage 'PowerShell 7 could not be installed automatically. Install it manually (winget install Microsoft.PowerShell, or see https://aka.ms/powershell) and re-run this installer from a pwsh prompt.'
            }
            return 7
        }
        Write-Success 'PowerShell 7 is installed.'
    }

    $relaunchPath = $CommandPath
    $relaunchDirectory = $null
    if (-not $relaunchPath) {
        $installerContent = Get-PowerShell7RelaunchInstaller -Url $InstallerUrl -ExpectedBuildId $ExpectedBuildId
        if (-not $installerContent) {
            if ($ExpectedBuildId) {
                Write-ErrorMessage ('Could not download installer build {0}, the build this run started with, for the PowerShell 7 relaunch (see above).' -f $ExpectedBuildId)
            }
            else {
                Write-ErrorMessage 'Could not download the installer for the PowerShell 7 relaunch (see above).'
            }
            # From a pwsh prompt the one-liner runs in PowerShell 7 straight away, with no second
            # download, so whatever URL the run started from works there.
            Write-ErrorMessage 'PowerShell 7 is installed on this machine. Open PowerShell 7 (pwsh) as administrator and run the same one-liner there: it needs no second download. If raw.githubusercontent.com answers 429 Too Many Requests, use the jsDelivr one-liner from the readme.'
            return 7
        }
        try {
            # A fresh GUID-named folder, so the file cannot be planted in advance or collide with
            # another run. It stays writable by this user, so an elevated relaunch runs a copy
            # checked against the SHA256 the relaunched run takes at startup (P3-11).
            $relaunchDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-' + [System.Guid]::NewGuid().ToString('N'))
            [void](New-Item -Path $relaunchDirectory -ItemType Directory -Force -ErrorAction Stop)
            $relaunchPath = Join-Path $relaunchDirectory 'winget-app-install.ps1'
            Set-Content -LiteralPath $relaunchPath -Value $installerContent -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-ErrorMessage "Could not save the installer for the relaunch: $_"
            if ($relaunchDirectory) {
                Remove-Item -LiteralPath $relaunchDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
            return 7
        }
    }

    Write-Info ('Relaunching the installer under PowerShell 7: {0}' -f $pwshPath)
    $quotedRelaunchPath = '"' + $relaunchPath.Replace('"', '`"') + '"'
    $relaunchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedRelaunchPath)
    if ($WhatIf) {
        $relaunchArguments += '-WhatIf'
    }
    if ($NonInteractive) {
        $relaunchArguments += '-NonInteractive'
    }
    if ($SkipSystemCheck) {
        $relaunchArguments += '-SkipSystemCheck'
    }
    $relaunchArguments += @($AdditionalArguments)
    # Set the relaunch-loop sentinel (checked at the top of this function) so a child that
    # somehow re-enters the version dispatch fails fast instead of relaunching forever.
    $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = '1'
    # Guard the launch itself: under 5.1 a Start-Process failure is non-terminating, so without
    # the try/catch $relaunchProcess would stay $null and the tail's 'exit ($null)' would report
    # SUCCESS (exit 0) to the RMM/CI callers this exit code exists for (issue #225 review).
    $relaunchProcess = $null
    $relaunchError = $null
    try {
        $relaunchProcess = Start-Process -FilePath $pwshPath -ArgumentList $relaunchArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
    }
    catch {
        $relaunchError = $_
    }
    # The downloaded copy of an irm | iex run is not needed any more (review finding P3-42): the
    # relaunched run has ended, and an elevated run it started has ended too and ran its own copy.
    # Only the folder this function made; a file the caller started from is never removed.
    if ($relaunchDirectory) {
        Remove-Item -LiteralPath $relaunchDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($relaunchError) {
        Write-ErrorMessage "PowerShell 7 could not be started ($pwshPath): $relaunchError"
        return 7
    }
    if (-not $relaunchProcess) {
        Write-ErrorMessage "PowerShell 7 could not be started ($pwshPath)."
        return 7
    }
    $script:PowerShell7BootstrapRelaunched = $true
    # Into the bootstrap transcript: a relaunched run that failed before it could start its own
    # transcript (pwsh rejecting the arguments, a crash on load) leaves only this line behind.
    Write-Info ('The PowerShell 7 run ended with exit code {0}.' -f $relaunchProcess.ExitCode)
    $relaunchExitCode = $relaunchProcess.ExitCode
    if ($script:PowerShell7BootstrapRestartRequired) {
        # The relaunched run took this restart as already pending (it checked after the install),
        # so it is reported here and made 3010 when nothing else went wrong (P3-16).
        Write-WarningMessage 'Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.'
        if ($relaunchExitCode -eq 0) {
            Write-Info 'Exit code 3010: the apps installed, and the PowerShell 7 installation needs a restart to finish.'
            return 3010
        }
    }
    return $relaunchExitCode
}
