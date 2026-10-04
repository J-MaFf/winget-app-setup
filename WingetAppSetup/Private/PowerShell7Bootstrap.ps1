# Windows PowerShell 5.1 bootstrap (issue #225). EVERYTHING in this file runs under Windows
# PowerShell 5.1 - the one engine the rest of the module explicitly does not support - because the
# tail dispatch calls it BEFORE handing off to PowerShell 7. Keep every statement 5.1-runtime
# compatible: no ternary, no null-coalescing, no 3-argument Join-Path, only .NET Framework 4.x
# APIs, and only helpers that are themselves 5.1-safe. Currently that is: Write-Info/
# Write-WarningMessage/Write-ErrorMessage/Write-Success (plain Write-Host wrappers), Test-IsAdmin
# and its Get-CurrentWindowsPrincipal seam (Public/Elevation.ps1, Private/Elevation.ps1 - a
# try/catch and a type cast, issue #239), Get-WingetAgreementArgs (a literal array,
# Private/WingetAgreementArgs.ps1, issue #240), and this file's own
# Get-PowerShell7MsiInfo/Save-WebFileWithTimeout/Install-PowerShell7FromMsi (issue #263),
# Test-GitHubRateLimitError (issue #274), Test-PowerShell7MsiSignature/
# Get-InstallerBuildIdFromText/Get-PowerShell7RelaunchInstaller (review findings P3-17, P2-18),
# and Invoke-WingetProcess with what it calls (Private/ProcessInvocation.ps1: Invoke-ExternalProcess,
# Get-ProcessTimeoutSeconds and their helpers, written against .NET Framework 4.5;
# Resolve-WingetExecutable, which returns a literal string) for the winget install (review
# findings P2-5/P2-6). Get-AuthenticodeSignature, which Test-PowerShell7MsiSignature calls, is a
# Windows PowerShell 5.1 cmdlet too. The tail's 5.1 branch also calls, around this file:
# Test-EffectiveNonInteractive and Test-IsContinuousIntegration (Private/Interactivity.ps1),
# Start-InstallerTranscript, Grant-InstallLogReadAccess and Write-Prompt (Private/LoggingInternal.ps1),
# and Exit-Installer and Write-InstallerExitNotice (Private/FailureReporting.ps1) - review findings
# P2-13/P2-14/P3-14. Check any function added to this list - or any
# future edit to one already on it - against the same constraints before calling it from here; the
# build's parse + ASCII guards only catch a parse-breaking token, not a PS7-only runtime construct
# that still parses under 5.1 but behaves differently or throws. The build's parse + ASCII guards
# keep the assembled installer 5.1-PARSEABLE (issue #210); runtime compatibility of this file is
# pinned by the unit tests in
# tests/PowerShell7Bootstrap.Tests.ps1.

<#
.SYNOPSIS
    Verifies a candidate pwsh executable actually launches and is version 7 or newer.
.DESCRIPTION
    Existence checks are not enough for either failure mode this guards (issue #225 review):
    a PATH-resolved pwsh.exe can be PowerShell 6.x (EOL, but present on old golden images) -
    relaunching under it would re-enter the version dispatch and loop forever - and the
    WindowsApps execution alias is a 0-byte reparse file that passes Test-Path even when its
    backing MSIX package is broken or removed. Running the candidate with a version query
    validates launchability and version in one probe (a couple of seconds, only ever paid on
    the 5.1 bootstrap path).
.PARAMETER Path
    Candidate executable path.
.RETURNS
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
    Probes PATH first, then the well-known install locations. The explicit paths matter because
    the current process's PATH is stale immediately after an install (a new PowerShell 7 install
    updates the machine PATH, but running processes never see that), because a 32-bit host (some
    RMM agents) has $env:ProgramFiles pointing at 'Program Files (x86)' while pwsh is 64-bit
    (ProgramW6432 covers that), and because winget installs the MSIX build on Windows 11 24H2+,
    which lands an execution alias under the user's WindowsApps instead of Program Files.
    Every candidate must pass Test-PowerShell7Executable - existence alone proves neither
    launchability nor version (see that function's help).
.RETURNS
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
    Tests whether an error looks like a GitHub rate-limit / throttling response.
.DESCRIPTION
    The MSI fallback's metadata.json read below surfaces the underlying exception text verbatim via
    Write-WarningMessage, which is where a throttled machine actually sees
    "429: Too Many Requests" or "(429) Too Many Requests" (issue #274). Matching that text is
    how the caller distinguishes "GitHub is throttling this network" from any other network
    failure without parsing a structured status code out of a caught ErrorRecord.
.PARAMETER ErrorRecord
    The $_ caught from a failed Invoke-RestMethod call.
.RETURNS
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
    Reads the same tools/metadata.json the official aka.ms/install-powershell.ps1 script reads
    (issue #263), so the direct-download path below tracks whatever Microsoft currently ships
    without this repo pinning a version that would go stale. That endpoint is a raw.githubusercontent
    file rather than the GitHub releases API on purpose: the API's unauthenticated 60-requests-per-
    hour budget is per source IP, which an office behind one NAT can exhaust for everyone.

    Which release (review finding P2-17): the current one (ReleaseTag) while it still ships an MSI,
    otherwise the newest LTS release (LTSReleaseTag) that does. PowerShell 7.7 and later ship no MSI,
    only the MSIX bundle and ZIP files (the PowerShell team's "PowerShell MSI package deprecation"
    post; 7.7.0-preview.5 has no .msi asset), while 7.6, an LTS release, keeps its MSI for its
    support life. Building the URL from ReleaseTag alone would 404 as soon as ReleaseTag moves to
    7.7, and when the elevating admin account has no winget this MSI is the only way the bootstrap
    can install PowerShell 7. Any PowerShell 7 can run the installer. LTSReleaseTag is a list
    (["v7.4.20", "v7.6.6"] in October 2026), so the newest entry is picked by version, not position.

    Architecture comes from the environment rather than Get-ComputerInfo (which the upstream script
    uses): Get-ComputerInfo takes seconds to populate every property just to read one, and it does
    not exist before PowerShell 5.1. PROCESSOR_ARCHITEW6432 is checked first because a 32-bit host
    process (some RMM agents) reports PROCESSOR_ARCHITECTURE as x86 on a 64-bit OS - the same
    stale-view problem Find-PowerShell7 handles with ProgramW6432.
.PARAMETER MetadataUrl
    Release metadata endpoint. Parameterized for tests.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the metadata request.
.RETURNS
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
    The reason this exists instead of Invoke-WebRequest -OutFile (issue #263). Under Windows
    PowerShell 5.1 - the only engine this file ever runs on - Invoke-WebRequest has no read timeout,
    so a proxy or link that accepts the connection and then stops sending blocks the pipeline
    forever with no output and no error. That is exactly how the old MSI fallback failed: a 110 MB
    download behind a suppressed progress bar was indistinguishable from a dead one.

    HttpWebRequest's ReadWriteTimeout bounds every individual read on the response stream, which is
    the guarantee Invoke-WebRequest cannot give. -MaximumSeconds additionally bounds a link that
    trickles just fast enough to never trip the stall timeout, and the periodic progress line makes
    a healthy slow download visibly different from a hung one.
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
.RETURNS
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
    Review finding P3-17. The MSI goes to msiexec, usually elevated, and msiexec installs an
    unsigned or altered package without complaint. Checking the signature first keeps a substituted
    file (from a TLS-inspecting proxy, or a swapped release asset) off the machine, and turns a
    download that is not an MSI at all, such as an error or sign-in page a proxy answered with,
    into a clear message instead of msiexec's exit code 1620 ("This installation package could not
    be opened").

    Status 'Valid' means Windows checked the signature against the file's content and chained the
    signing certificate to a trusted root. The signer must also be Microsoft: the certificate
    subject's common name must be exactly 'Microsoft Corporation', the name PowerShell's release
    packages are signed with. Get-AuthenticodeSignature exists in Windows PowerShell 5.1, the
    engine this runs on.
.PARAMETER Path
    The downloaded MSI.
.RETURNS
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
    Replaces blind delegation to aka.ms/install-powershell.ps1 -UseMSI -Quiet as the fallback when
    winget is unavailable (issue #263). That script is opaque and unbounded: it suppresses the
    progress bar on Windows PowerShell, downloads with an untimed Invoke-WebRequest, logs its install
    step through a Write-Verbose that never prints, and waits on msiexec forever. Doing the same two
    steps here buys the three things this bootstrap needs to stay honest on an unattended run -
    visible progress, a bounded download, and a bounded install - plus a check that the download is
    Microsoft's signed MSI before msiexec sees it (Test-PowerShell7MsiSignature, review finding
    P3-17).

    Exit code 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) counts as success: pwsh.exe is on disk and
    launchable at that point, and the relaunch does not need the pending reboot. It still sets
    $script:PowerShell7BootstrapRestartRequired, so Invoke-PowerShell7Bootstrap ends a run that
    otherwise succeeded with 3010 (review finding P3-16): the relaunched run checks Windows'
    pending-restart state only after this install, so it cannot see the restart this install needs.

    Exit code 1618 (ERROR_INSTALL_ALREADY_RUNNING) is retried after a wait (review finding P2-13).
    msiexec returns it at once, without waiting, whenever another installation holds the Windows
    Installer - common on a freshly enrolled machine whose management agent, OEM tools or Teams are
    still installing. It used to fail the bootstrap on the spot.

    With -MsiLogDirectory, msiexec writes a verbose log (/l*v) there, one file per attempt, so a
    failed install can be diagnosed from the logs folder the teammate attaches.

    Nothing runs after this path any more: the aka.ms/install-powershell.ps1 tier is gone (see
    Invoke-PowerShell7Bootstrap). That script had no time limits at all, so on a slow but working
    link it could finish a download this path had given up on. The download limit here is
    therefore generous (-DownloadTimeoutSeconds, 60 minutes, about 30 KB/s for the 110 MB MSI); the
    60-second stall timeout in Save-WebFileWithTimeout is what catches a dead or hung link.
.PARAMETER MetadataUrl
    Forwarded to Get-PowerShell7MsiInfo. Parameterized for tests.
.PARAMETER DownloadTimeoutSeconds
    Maximum seconds for the whole MSI download, forwarded to Save-WebFileWithTimeout as
    -MaximumSeconds. A link that is slow but still delivering data gets this long; one that stops
    delivering data fails after the 60-second stall timeout instead.
.PARAMETER InstallTimeoutSeconds
    Maximum seconds to wait for one msiexec attempt before killing it. Another installation in
    progress does not make msiexec wait (it returns 1618, see above), so reaching this limit means
    msiexec itself hung.
.PARAMETER MsiLogDirectory
    Folder for msiexec's verbose logs, named pwsh-msi-<timestamp>-<attempt>.log. Empty: no msiexec
    log. The caller passes the folder its own transcript is in, which this account can write to;
    msiexec fails the whole install (1622) when it cannot open its log.
.PARAMETER BusyRetryCount
    How many times to retry after msiexec exit code 1618.
.PARAMETER BusyRetryDelaySeconds
    Seconds to wait before each of those retries.
.RETURNS
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
    Reads the build id stamped into a copy of the generated installer.
.DESCRIPTION
    build/Build-WingetInstallScript.ps1 stamps the content-derived id into the installer as a line
    of its own that assigns it to $script:InstallerBuildId (issue #189). Only a line that starts
    with that assignment counts, so this file's own code, which mentions the variable indented,
    never reads as one.
.PARAMETER Text
    The installer text.
.RETURNS
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
    Review finding P2-18. An irm | iex run has no file to relaunch under pwsh, so the bootstrap
    downloads the installer again. It used to fetch raw main only, whatever URL the run started
    from, and run whatever came back. Three things went wrong with that:
      - The jsDelivr mirror the readme offers for raw.githubusercontent.com's 429 throttling only
        served the first copy: the relaunch went back to the throttled host and failed.
      - A run started from a branch URL silently relaunched main's code.
      - Nothing checked that the second copy was the installer at all.

    Each URL is tried in order, and a copy is used only when it is the build that is already
    running. The installer itself cannot say which URL it came from, so the build id is what ties
    the two copies together: a branch build, or a main that changed since the run started, is
    refused instead of run.
.PARAMETER Url
    URLs to try, in order.
.PARAMETER ExpectedBuildId
    The running installer's build id. Empty: any copy that carries a build id is accepted.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for each download.
.RETURNS
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
    The generated installer requires PowerShell 7+, but new machines ship with only Windows
    PowerShell 5.1 (issue #225). Instead of failing fast with manual instructions (the pre-#225
    behavior from issue #210), this bootstrap makes the documented one-liner work from any
    PowerShell prompt:

        1. Find an existing pwsh.exe (Find-PowerShell7). Present -> relaunch immediately; this
           alone fixes the "opened the built-in Windows PowerShell out of habit" case.
        2. Missing -> install it, no consent prompt (issue #230): winget first (an exe,
           version-agnostic, preinstalled on consumer Windows 11); when winget is absent or fails,
           the official MSI, downloaded, signature-checked and run directly by
           Install-PowerShell7FromMsi (issue #263). -WhatIf never installs anything and previews
           the plan instead.
        3. Relaunch the installer under pwsh with -NoProfile -ExecutionPolicy Bypass in the SAME
           console (output and prompts stay in the caller's window), forwarding the caller's
           switches, and return the child's exit code for the tail dispatch to propagate.

    Relaunch source: a file-based run relaunches the caller's own $PSCommandPath (so a PR's e2e
    run keeps testing the PR's bytes). An `irm | iex` run has no file on disk, and the in-memory
    text is NOT recoverable - under iex, $MyInvocation.MyCommand.Definition/.ScriptBlock reflect
    the OUTER command line, not the piped script body (verified empirically) - so the installer is
    downloaded again to a temp file, from raw.githubusercontent.com or else its jsDelivr mirror, and
    only a copy of the running build is used (Get-PowerShell7RelaunchInstaller, review finding
    P2-18). That temp file is not cleaned up. A non-admin relaunch elevates from it: the elevated
    window checks it against the SHA256 the relaunched run took at startup and runs a copy kept in
    a folder only administrators can change (Restart-WithElevation, review finding P3-11).

    There is no aka.ms/install-powershell.ps1 tier behind the MSI any more (review findings P2-17
    and P3-17). That script reads the same metadata.json and downloads the same MSI with no
    signature check, so it would install an MSI the signature check had just rejected, and it runs
    a downloaded script with no check at all. Once the current release is 7.7 it 404s, because it
    can only build the URL from ReleaseTag. The one thing it could do that the MSI path could not
    was outlast a time limit, because it has none: its download and its msiexec run are unbounded.
    So the MSI path's download limit is 60 minutes, not 15, with the 60-second stall timeout still
    catching a dead link (Install-PowerShell7FromMsi -DownloadTimeoutSeconds). Its 15-minute msiexec
    limit stays: the PowerShell MSI installs in about a minute, so an msiexec run still going after
    15 minutes is treated as hung rather than given a second, unbounded attempt.
.PARAMETER WhatIf
    Dry-run intent, forwarded to the relaunch. When PowerShell 7 is missing, the bootstrap prints
    what a real run would do and returns 0 without installing anything.
.PARAMETER NonInteractive
    Forwarded to the relaunch, and nothing else. Since issue #230 this function has no interactive
    behavior of its own to gate: the install proceeds without asking, and its winget call always
    passes --disable-interactivity.
.PARAMETER SkipSystemCheck
    Forwarded to the relaunch untouched.
.PARAMETER CommandPath
    The caller's $PSCommandPath. Empty when running via `irm | iex`, which triggers the
    re-download relaunch path. ($PSCommandPath cannot be read here directly - inside a function it
    resolves to the file that defines the function, not the running script.)
.PARAMETER InstallerUrl
    URLs the iex relaunch path downloads the installer from, tried in order: by default the
    one-liner's raw.githubusercontent.com URL, then the jsDelivr mirror the readme offers when raw
    is rate-limiting the network. Parameterized for tests.
.PARAMETER ExpectedBuildId
    The running installer's build id ($script:InstallerBuildId). The iex relaunch path uses only a
    download of this same build.
.PARAMETER LogDirectory
    The folder of the bootstrap transcript the tail started, or empty when it could not start one.
    Forwarded to Install-PowerShell7FromMsi for msiexec's verbose log (review finding P2-13), and to
    the winget install for the installer's log (--log, review finding P2-6).
.RETURNS
    [int] Exit code for the tail dispatch to propagate: the relaunched run's exit code, 0 for a
    -WhatIf preview of a would-be install, or 7 when PowerShell 7 could not be installed or the
    installer could not be relaunched under it. When installing PowerShell 7 needs a restart to
    finish (msiexec 3010, or winget's restart result, see Test-WingetRestartRequiredResult) and the
    relaunched run returned 0, the result is 3010 (review finding P3-16): that run checks Windows'
    pending-restart state only after this install, so it cannot see this restart itself. Any other
    code the relaunched run returned is kept: a failure at the end of the run ranks above 3010, and
    an early exit stays what it is.
    Sets
    $script:PowerShell7BootstrapRelaunched to $true once a relaunched PowerShell 7 run has ended,
    so the tail knows that run already reported its outcome to whoever is at the console.
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
        [string]$LogDirectory
    )

    $script:PowerShell7BootstrapRelaunched = $false

    Write-WarningMessage 'This installer requires PowerShell 7+ (pwsh), but this session is Windows PowerShell. Handing off...'

    # Relaunch-loop guard: this env var is set just before the relaunch below and is inherited by
    # the child, so reaching this line with it already set means a bootstrapped child re-entered
    # the version dispatch - Test-PowerShell7Executable should make that impossible, but if the
    # machine's pwsh is that broken, fail fast instead of spawning processes forever.
    if ($env:WINGET_APP_SETUP_PS7_BOOTSTRAP -eq '1') {
        Write-ErrorMessage 'The PowerShell 7 bootstrap re-entered itself after a relaunch: the relaunched PowerShell still reports a version below 7. Install PowerShell 7 manually (winget install Microsoft.PowerShell) and re-run this installer from a pwsh prompt.'
        return 7
    }

    # Reset per-call, not per-process: this flag is set deep in Get-PowerShell7MsiInfo and read
    # back at the terminal failure message further down (issue #274). Without
    # the reset here, a throttled call would leave a stale $true that a later, unrelated call in
    # the same process (or Pester run) could inherit.
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

        # No consent prompt (issue #230). PowerShell 7 is a hard requirement of everything below,
        # so the question only ever had one useful answer - and asking it stalled the documented
        # one-liner: an interactive `irm | iex` does not redirect stdin, so the session read as
        # interactive and the prompt fired. This function no longer consults the interactivity
        # detection at all; -NonInteractive survives here purely to be forwarded to the relaunch.
        Write-Info 'PowerShell 7 (pwsh) is required but not installed. Installing it now...'

        # The bootstrap runs before the module's elevation logic ever loads; a machine-wide
        # PowerShell 7 install from a non-admin session may surface a UAC prompt or fail outright.
        # Warn and let it ride - Test-IsAdmin (WingetAppSetup/Public/Elevation.ps1) already fails
        # safe (assumes elevated) if the underlying check throws, which is what kept this call
        # site's own try/catch runnable on non-Windows test hosts before consolidation.
        $isAdmin = Test-IsAdmin
        if (-not $isAdmin) {
            Write-WarningMessage 'Not running as administrator: the PowerShell 7 install may show a UAC prompt or fail. If it fails, re-run this installer from an elevated prompt.'
        }

        $wingetCommand = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
        if ($wingetCommand) {
            Write-Info 'Installing PowerShell 7 via winget...'
            # --disable-interactivity unconditionally (issue #230). It used to be added only when
            # the session read as non-interactive, which is exactly backwards for the case that
            # matters: the documented one-liner reports INTERACTIVE (an `irm | iex` pipe leaves
            # stdin alone), so the run most likely to be walked away from was the one run that let
            # winget stop and ask. Nothing here needs winget's UI - the agreements are accepted by
            # flag, and a failure falls through to the MSI fallback below. The shared flags come
            # from Get-WingetAgreementArgs so this call site cannot drift from the others again.
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
        else {
            Write-WarningMessage 'winget is not available on this machine.'
        }

        if (-not $pwshPath) {
            # The direct MSI download, with progress, time limits and a signature check (issue
            # #263, review finding P3-17). Nothing follows it: see the help above for why the
            # aka.ms/install-powershell.ps1 tier is gone. PowerShell 7 is looked for again even
            # when this reports failure, in case msiexec installed it before failing or being
            # stopped.
            Write-Info 'Falling back to the official PowerShell MSI installer...'
            [void](Install-PowerShell7FromMsi -MsiLogDirectory $LogDirectory)
            $pwshPath = Find-PowerShell7
        }

        if (-not $pwshPath) {
            if ($script:PowerShell7BootstrapGitHubThrottled) {
                # winget already failed by construction (this branch is only reached after it did),
                # so pointing at 'source reset' costs nothing even when that is not the actual root
                # cause - unlike the MSI path above, it does not depend on the same throttled
                # network path (issue #274).
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
            # Unique per-run directory (issue #225 review): a fixed temp filename could be
            # pre-planted or swapped by another same-user process before the relaunch - which
            # matters extra here because the relaunched run may self-elevate from this very path -
            # and concurrent runs would overwrite each other. A fresh GUID-named directory removes
            # predictability and cross-run collisions. The file stays writable by this user, so an
            # elevated relaunch never runs it directly: it runs a copy checked against the SHA256
            # the relaunched run took at startup (Restart-WithElevation, review finding P3-11).
            $relaunchDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-' + [System.Guid]::NewGuid().ToString('N'))
            [void](New-Item -Path $relaunchDirectory -ItemType Directory -Force -ErrorAction Stop)
            $relaunchPath = Join-Path $relaunchDirectory 'winget-app-install.ps1'
            Set-Content -LiteralPath $relaunchPath -Value $installerContent -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-ErrorMessage "Could not save the installer for the relaunch: $_"
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
    # Set the relaunch-loop sentinel (checked at the top of this function) so a child that
    # somehow re-enters the version dispatch fails fast instead of relaunching forever.
    $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = '1'
    # Guard the launch itself: under 5.1 a Start-Process failure is non-terminating, so without
    # the try/catch $relaunchProcess would stay $null and the tail's 'exit ($null)' would report
    # SUCCESS (exit 0) to the RMM/CI callers this exit code exists for (issue #225 review).
    $relaunchProcess = $null
    try {
        $relaunchProcess = Start-Process -FilePath $pwshPath -ArgumentList $relaunchArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
    }
    catch {
        Write-ErrorMessage "PowerShell 7 could not be started ($pwshPath): $_"
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
        # The relaunched run read Windows' pending-restart state after the PowerShell 7 install
        # above, so it took this restart as already pending and did not report it (review finding
        # P3-16). Repeated here, after that run's summary, and turned into 3010 when nothing else
        # went wrong.
        Write-WarningMessage 'Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.'
        if ($relaunchExitCode -eq 0) {
            Write-Info 'Exit code 3010: the apps installed, and the PowerShell 7 installation needs a restart to finish.'
            return 3010
        }
    }
    return $relaunchExitCode
}
