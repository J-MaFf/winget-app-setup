# Windows PowerShell 5.1 bootstrap (issue #225). EVERYTHING in this file runs under Windows
# PowerShell 5.1 - the one engine the rest of the module explicitly does not support - because the
# tail dispatch calls it BEFORE handing off to PowerShell 7. Keep every statement 5.1-runtime
# compatible: no ternary, no null-coalescing, no 3-argument Join-Path, only .NET Framework 4.x
# APIs, and only helpers that are themselves 5.1-safe. Currently that is: Write-Info/
# Write-WarningMessage/Write-ErrorMessage/Write-Success (plain Write-Host wrappers), Test-IsAdmin
# and its Get-CurrentWindowsPrincipal seam (Public/Elevation.ps1, Private/Elevation.ps1 - a
# try/catch and a type cast, issue #239), Get-WingetAgreementArgs (a literal array,
# Private/WingetAgreementArgs.ps1, issue #240), and this file's own
# Get-PowerShell7MsiInfo/Save-WebFileWithTimeout/Install-PowerShell7FromMsi (issue #263). Check
# any function added to this list - or any
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
    Resolves the current stable PowerShell 7 release into an MSI download URL for this machine.
.DESCRIPTION
    Reads the same tools/metadata.json the official aka.ms/install-powershell.ps1 script reads
    (issue #263), so the direct-download path below tracks whatever Microsoft currently ships
    without this repo pinning a version that would go stale. That endpoint is a raw.githubusercontent
    file rather than the GitHub releases API on purpose: the API's unauthenticated 60-requests-per-
    hour budget is per source IP, which an office behind one NAT can exhaust for everyone.

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
    [hashtable] @{ Version; FileName; Url }, or $null when the release or architecture could not be
    resolved (the caller then falls back to the upstream install script).
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

    $release = $null
    try {
        $metadata = Invoke-RestMethod -Uri $MetadataUrl -TimeoutSec $TimeoutSeconds
        if ($metadata) {
            $release = $metadata.ReleaseTag
        }
    }
    catch {
        Write-WarningMessage "Could not read the PowerShell release metadata: $_"
        return $null
    }
    if (-not $release) {
        Write-WarningMessage 'The PowerShell release metadata did not contain a ReleaseTag.'
        return $null
    }

    $version = ($release -replace '^v', '')
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
    Installs PowerShell 7 by downloading the official MSI and running msiexec, all time-bounded.
.DESCRIPTION
    Replaces blind delegation to aka.ms/install-powershell.ps1 -UseMSI -Quiet as the first-choice
    fallback when winget is unavailable (issue #263). That script is not wrong, it is just opaque
    and unbounded: it suppresses the progress bar on Windows PowerShell, downloads with an untimed
    Invoke-WebRequest, logs its install step through a Write-Verbose that never prints, and waits on
    msiexec forever. Doing the same two steps here buys the three things this bootstrap needs to
    stay honest on an unattended run - visible progress, a bounded download, and a bounded install -
    while the upstream script stays as the caller's last-resort fallback.

    Exit code 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) counts as success: pwsh.exe is on disk and
    launchable at that point, and the relaunch does not need the pending reboot.
.PARAMETER MetadataUrl
    Forwarded to Get-PowerShell7MsiInfo. Parameterized for tests.
.PARAMETER InstallTimeoutSeconds
    Maximum seconds to wait for msiexec before killing it. The common cause of a long wait here is
    another MSI install holding the Windows Installer mutex (msiexec 1618).
.RETURNS
    [bool] True when msiexec reported success. False sends the caller to the upstream script.
#>
function Install-PowerShell7FromMsi {
    param (
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl = 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json',
        [Parameter(Mandatory = $false)]
        [int]$InstallTimeoutSeconds = 900
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
        if (-not (Save-WebFileWithTimeout -Uri $msiInfo.Url -DestinationPath $msiPath)) {
            return $false
        }

        Write-Info 'Installing PowerShell 7 (this takes about a minute)...'
        $msiProcess = $null
        try {
            # Quoted because the MSI path contains a GUID-named directory under the user's temp
            # path, which can sit under a profile directory containing spaces.
            $msiArguments = @('/i', ('"' + $msiPath + '"'), '/quiet', '/norestart')
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
            Write-WarningMessage ('The PowerShell 7 MSI install did not finish within {0} seconds and was stopped. Another installation may be holding the Windows Installer service.' -f $InstallTimeoutSeconds)
            return $false
        }

        $msiExitCode = $msiProcess.ExitCode
        if ($msiExitCode -eq 0 -or $msiExitCode -eq 3010) {
            return $true
        }
        Write-WarningMessage ('The PowerShell 7 MSI install failed (msiexec exit code {0}).' -f $msiExitCode)
        return $false
    }
    finally {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
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
           the official MSI downloaded and run directly by Install-PowerShell7FromMsi, with
           aka.ms/install-powershell.ps1 behind that as a last resort (issue #263). -WhatIf never
           installs anything and previews the plan instead.
        3. Relaunch the installer under pwsh with -NoProfile -ExecutionPolicy Bypass in the SAME
           console (output and prompts stay in the caller's window), forwarding the caller's
           switches, and return the child's exit code for the tail dispatch to propagate.

    Relaunch source: a file-based run relaunches the caller's own $PSCommandPath (so a PR's e2e
    run keeps testing the PR's bytes). An `irm | iex` run has no file on disk, and the in-memory
    text is NOT recoverable - under iex, $MyInvocation.MyCommand.Definition/.ScriptBlock reflect
    the OUTER command line, not the piped script body (verified empirically) - so the installer is
    re-downloaded from the canonical raw URL to a temp file. That temp file is deliberately not
    cleaned up: a non-admin relaunch self-elevates by spawning a third process from the same path,
    which can outlive this one.
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
    Raw URL the iex relaunch path re-downloads the installer from. Defaults to the canonical
    one-liner URL; parameterized for tests.
.RETURNS
    [int] Exit code for the tail dispatch to propagate: the relaunched run's exit code, 0 for a
    -WhatIf preview of a would-be install, or 1 when PowerShell 7 could not be provisioned.
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
        [string]$InstallerUrl = 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1'
    )

    Write-WarningMessage 'This installer requires PowerShell 7+ (pwsh), but this session is Windows PowerShell. Handing off...'

    # Relaunch-loop guard: this env var is set just before the relaunch below and is inherited by
    # the child, so reaching this line with it already set means a bootstrapped child re-entered
    # the version dispatch - Test-PowerShell7Executable should make that impossible, but if the
    # machine's pwsh is that broken, fail fast instead of spawning processes forever.
    if ($env:WINGET_APP_SETUP_PS7_BOOTSTRAP -eq '1') {
        Write-ErrorMessage 'The PowerShell 7 bootstrap re-entered itself after a relaunch: the relaunched PowerShell still reports a version below 7. Install PowerShell 7 manually (winget install Microsoft.PowerShell) and re-run this installer from a pwsh prompt.'
        return 1
    }

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
            # A Start-Process launch failure is non-terminating under 5.1's default
            # $ErrorActionPreference and would leave $wingetProcess $null - catch it explicitly
            # so a broken winget shim degrades to the MSI fallback with a real message.
            $wingetProcess = $null
            try {
                $wingetProcess = Start-Process -FilePath 'winget' -ArgumentList $wingetArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
            }
            catch {
                Write-WarningMessage "winget could not be started: $_"
            }
            if ($wingetProcess -and $wingetProcess.ExitCode -ne 0) {
                Write-WarningMessage ('winget could not install PowerShell 7 (exit code {0}).' -f $wingetProcess.ExitCode)
            }
            $pwshPath = Find-PowerShell7
        }
        else {
            Write-WarningMessage 'winget is not available on this machine.'
        }

        if (-not $pwshPath) {
            # Direct MSI first, upstream script only if that fails (issue #263). Delegating
            # straight to aka.ms/install-powershell.ps1 used to park the console for minutes with
            # no output whatsoever - see Install-PowerShell7FromMsi's help for why - which on a
            # stalled link is indistinguishable from the run having died. Doing the download here
            # makes progress visible and both steps time-bounded.
            Write-Info 'Falling back to the official PowerShell MSI installer...'
            if (-not (Install-PowerShell7FromMsi)) {
                Write-WarningMessage 'Falling back to the official installer script (https://aka.ms/install-powershell.ps1). It reports no download progress, so this step can run for several minutes with no output.'
                try {
                    # -TimeoutSec bounds the script download itself; the script's own MSI download
                    # is the unbounded part this path accepts as a last resort.
                    $msiInstallScript = Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1' -TimeoutSec 60
                    # Out-Host: the downloaded script's pipeline output must not leak into this
                    # function's return value (the tail dispatch exits with it).
                    & ([ScriptBlock]::Create($msiInstallScript)) -UseMSI -Quiet | Out-Host
                }
                catch {
                    Write-WarningMessage "The MSI fallback failed: $_"
                }
            }
            $pwshPath = Find-PowerShell7
        }

        if (-not $pwshPath) {
            Write-ErrorMessage 'PowerShell 7 could not be installed automatically. Install it manually (winget install Microsoft.PowerShell, or see https://aka.ms/powershell) and re-run this installer from a pwsh prompt.'
            return 1
        }
        Write-Success 'PowerShell 7 is installed.'
    }

    $relaunchPath = $CommandPath
    if (-not $relaunchPath) {
        Write-Info 'Downloading the installer for the PowerShell 7 relaunch...'
        try {
            $installerContent = Invoke-RestMethod -Uri $InstallerUrl -TimeoutSec 60
            # Unique per-run directory (issue #225 review): a fixed temp filename could be
            # pre-planted or swapped by another same-user process before the relaunch - which
            # matters extra here because the relaunched run may self-elevate from this very path -
            # and concurrent runs would overwrite each other. A fresh GUID-named directory removes
            # predictability and cross-run collisions; the residual risk (a same-user process
            # racing the write) is inherent to executing any script from a user-writable location,
            # and the UAC prompt still names this exact path.
            $relaunchDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-' + [System.Guid]::NewGuid().ToString('N'))
            [void](New-Item -Path $relaunchDirectory -ItemType Directory -Force)
            $relaunchPath = Join-Path $relaunchDirectory 'winget-app-install.ps1'
            Set-Content -LiteralPath $relaunchPath -Value $installerContent -Encoding UTF8
        }
        catch {
            Write-ErrorMessage "Could not download the installer for the relaunch: $_"
            Write-ErrorMessage "Run it from a pwsh prompt instead: pwsh -Command `"irm '$InstallerUrl' | iex`""
            return 1
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
        return 1
    }
    if (-not $relaunchProcess) {
        Write-ErrorMessage "PowerShell 7 could not be started ($pwshPath)."
        return 1
    }
    return $relaunchProcess.ExitCode
}
