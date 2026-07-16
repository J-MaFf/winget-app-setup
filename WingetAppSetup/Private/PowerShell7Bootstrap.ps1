# Windows PowerShell 5.1 bootstrap (issue #225). EVERYTHING in this file runs under Windows
# PowerShell 5.1 - the one engine the rest of the module explicitly does not support - because the
# tail dispatch calls it BEFORE handing off to PowerShell 7. Keep every statement 5.1-runtime
# compatible: no ternary, no null-coalescing, no 3-argument Join-Path, only .NET Framework 4.x
# APIs, and only helpers that are themselves 5.1-safe (Write-Info/Write-WarningMessage/
# Write-ErrorMessage/Write-Success are plain Write-Host wrappers). The build's parse + ASCII guards
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
    Finds or installs PowerShell 7, then relaunches the installer under pwsh in the same console.
.DESCRIPTION
    The generated installer requires PowerShell 7+, but new machines ship with only Windows
    PowerShell 5.1 (issue #225). Instead of failing fast with manual instructions (the pre-#225
    behavior from issue #210), this bootstrap makes the documented one-liner work from any
    PowerShell prompt:

        1. Find an existing pwsh.exe (Find-PowerShell7). Present -> relaunch immediately; this
           alone fixes the "opened the built-in Windows PowerShell out of habit" case.
        2. Missing -> install it, no consent prompt (issue #230): winget first (an exe,
           version-agnostic, preinstalled on consumer Windows 11), falling back to the official
           aka.ms/install-powershell.ps1 MSI script when winget is absent or fails. -WhatIf never
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
        # Warn and let it ride - GetCurrent() is wrapped only so the unit tests stay runnable on
        # non-Windows hosts; in production this file always runs on Windows.
        $isAdmin = $true
        try {
            $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
        }
        catch {
        }
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
            Write-Info 'Falling back to the official PowerShell MSI installer (https://aka.ms/install-powershell.ps1)...'
            try {
                $msiInstallScript = Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1'
                # Out-Host: the downloaded script's pipeline output must not leak into this
                # function's return value (the tail dispatch exits with it).
                & ([ScriptBlock]::Create($msiInstallScript)) -UseMSI -Quiet | Out-Host
            }
            catch {
                Write-WarningMessage "The MSI fallback failed: $_"
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
            $installerContent = Invoke-RestMethod -Uri $InstallerUrl
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
