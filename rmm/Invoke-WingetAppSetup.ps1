<#
.SYNOPSIS
    Runs winget-app-install.ps1 for the whole PC from an RMM agent: the machine phase of an
    Endpoint Central deployment (Computer Configuration, run as SYSTEM).
.DESCRIPTION
    Upload this script to ManageEngine Endpoint Central's Script Repository and deploy it as a
    Computer Configuration custom script that runs as the System user (frequency Once, with
    'Enable logging for troubleshooting', success exit codes 0,3010). It:

      1. Relaunches itself in 64-bit Windows PowerShell
         (%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe) when it was started by a
         32-bit PowerShell on 64-bit Windows: Endpoint Central's agent lives in Program Files (x86),
         and a 32-bit process sees the 32-bit System32, Program Files and registry.
      2. Logs everything it does to %ProgramData%\winget-app-setup\logs\install-<time>-rmm.log, next
         to the installer's own transcripts and last-run.json, including the installer's console
         output.
      3. Downloads winget-app-install.ps1 from the pinned commit below
         (https://raw.githubusercontent.com/J-MaFf/winget-app-setup/<commit>/winget-app-install.ps1),
         never from main, into a new folder under %SystemRoot%\Temp that only SYSTEM and
         Administrators can change, and checks its SHA256 against the pinned one before any of it
         runs.
      4. Runs it: powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <copy>
         -NonInteractive. The installer finds or installs PowerShell 7 and relaunches under it.
      5. Exits with the installer's exit code, unchanged.

    No -Unattended switch is needed: as SYSTEM the installer is non-interactive by itself (no grid
    view, no key press, --silent), it is elevated, and it installs for the whole PC only, reporting
    an app with no machine-wide installer as Deferred in last-run.json. -NonInteractive is passed
    anyway, for an RMM that runs the wrapper as an administrator account instead of SYSTEM.
    The deferred apps and the per-user Windows Terminal defaults are left to the user phase,
    rmm/Invoke-WingetAppSetupUserPhase.ps1 (a User Configuration script run at each sign-in).
.PARAMETER InstallerPath
    Run this local copy of winget-app-install.ps1 instead of downloading the pinned one (the e2e
    test runs the checkout this way). It is copied into the same protected folder and its SHA256 is
    still checked: against -InstallerSha256, or the pinned one.
.PARAMETER InstallerSha256
    The SHA256 the installer must have. Default: the pinned one.
.PARAMETER SkipSystemCheck
    Passed on to the installer (skips its OS, disk and network pre-flight checks).
.PARAMETER From32BitHost
    Set by the wrapper itself when it relaunches from a 32-bit PowerShell, so the log says so.
.NOTES
    Exit codes: the installer's own, unchanged (0 OK, 1 app failures, 2 winget unavailable, 3
    catalog validation failed, 4 elevation required, 5 aborted, 6 another run in progress, 7
    PowerShell 7 bootstrap failed, 8 apps OK but auto-updates not configured or unhealthy, 3010 OK,
    restart required; see readme.md). Before the installer runs, the wrapper exits 5 when it cannot
    run it: the pins are not set, the download failed, the SHA256 does not match, or the 64-bit
    relaunch could not start.

    Runs under Windows PowerShell 5.1: ASCII only, no PowerShell-7-only syntax.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $false)]
    [string]$InstallerSha256,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck,

    [Parameter(Mandatory = $false)]
    [switch]$From32BitHost
)

# ---- The pinned installer ------------------------------------------------------------------------
# Which winget-app-install.ps1 this wrapper runs: the file in commit PinnedInstallerCommit (its full
# 40-character id, a commit on main), whose SHA256 must be PinnedInstallerSha256. Set both together,
# here and in rmm/Invoke-WingetAppSetupUserPhase.ps1, with:
#     pwsh -File build/Set-RmmInstallerPin.ps1 -Commit <commit on main>
# It reads the file from that commit with git and writes both pins into both scripts. Then upload
# the changed scripts to the Script Repository again. Both empty: not set yet, and the wrapper
# refuses to run anything until they are.
$PinnedInstallerCommit = ''
$PinnedInstallerSha256 = ''
# --------------------------------------------------------------------------------------------------

function Write-RmmLine {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Color = 'Gray'
    )

    Write-Host $Message -ForegroundColor $Color
}

<#
.SYNOPSIS
    Returns whether a pinned commit is a full 40-character commit id.
#>
function Test-RmmPinnedCommit {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Commit
    )

    return ($Commit -cmatch '^[0-9a-f]{40}$')
}

<#
.SYNOPSIS
    Returns whether a text is a SHA256 in hex.
#>
function Test-RmmSha256 {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Hash
    )

    return ($Hash -match '^[0-9A-Fa-f]{64}$')
}

<#
.SYNOPSIS
    Returns the raw.githubusercontent.com URL of winget-app-install.ps1 in a commit.
#>
function Get-RmmInstallerUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Commit
    )

    return ('https://raw.githubusercontent.com/J-MaFf/winget-app-setup/{0}/winget-app-install.ps1' -f $Commit)
}

<#
.SYNOPSIS
    Returns the SHA256 of a file as upper-case hex, or $null when it cannot be read.
#>
function Get-RmmFileSha256 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Downloads a file, with three tries.
.DESCRIPTION
    TLS 1.2 is turned on first: Windows PowerShell 5.1 on older Windows may not offer it by default,
    and GitHub requires it. The progress bar is off, which makes Invoke-WebRequest in Windows
    PowerShell many times faster.
.RETURNS
    [bool] True when the file was downloaded.
#>
function Save-RmmInstallerDownload {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [int]$Attempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelaySeconds = 10
    )

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Not settable here (PowerShell 7 uses TLS 1.2 or later anyway).
    }
    $ProgressPreference = 'SilentlyContinue'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            return $true
        }
        catch {
            Write-RmmLine ('Download attempt {0} of {1} failed: {2}' -f $attempt, $Attempts, $_.Exception.Message) 'Yellow'
            if ($attempt -lt $Attempts) {
                Start-Sleep -Seconds ($RetryDelaySeconds * $attempt)
            }
        }
    }
    return $false
}

<#
.SYNOPSIS
    Runs a program, its output shown (and transcribed), and returns its exit code, or $null when it
    could not be started.
#>
function Invoke-RmmProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    $global:LASTEXITCODE = $null
    try {
        # Through Out-Host: the output then reaches the console (and the RMM's log) and this
        # wrapper's transcript, and never the caller's return value.
        & $FilePath @ArgumentList | Out-Host
    }
    catch {
        Write-RmmLine "Could not start ${FilePath}: $($_.Exception.Message)" 'Red'
        return $null
    }
    return $global:LASTEXITCODE
}

<#
.SYNOPSIS
    Returns whether this is a 32-bit PowerShell on 64-bit Windows.
#>
function Test-Rmm32BitHostOn64BitWindows {
    return ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
}

<#
.SYNOPSIS
    Returns the Windows directory, without a trailing backslash.
#>
function Get-RmmWindowsDirectory {
    $windowsDirectory = $env:SystemRoot
    if (-not $windowsDirectory) {
        $windowsDirectory = $env:windir
    }
    if (-not $windowsDirectory) {
        $windowsDirectory = 'C:\Windows'
    }
    return $windowsDirectory.TrimEnd('\')
}

<#
.SYNOPSIS
    Returns the 64-bit Windows PowerShell as a 32-bit process reaches it: through Sysnative, which
    exists only for 32-bit processes.
#>
function Get-RmmSysnativePowerShellPath {
    return (Get-RmmWindowsDirectory) + '\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
}

<#
.SYNOPSIS
    Returns Windows PowerShell's path in this process's own System32.
#>
function Get-RmmWindowsPowerShellPath {
    return (Get-RmmWindowsDirectory) + '\System32\WindowsPowerShell\v1.0\powershell.exe'
}

<#
.SYNOPSIS
    Returns the account this process runs as, or 'unknown'.
#>
function Get-RmmAccountName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return 'unknown'
    }
}

<#
.SYNOPSIS
    Turns the wrapper's bound parameters back into arguments, for the 64-bit relaunch.
.PARAMETER BoundParameters
    The script's $PSBoundParameters.
.RETURNS
    [string[]]
#>
function ConvertTo-RmmForwardedArgument {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$BoundParameters
    )

    $arguments = @()
    foreach ($name in @($BoundParameters.Keys | Sort-Object)) {
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $arguments += "-$name"
            }
        }
        elseif ($null -ne $value -and "$value" -ne '') {
            $arguments += @("-$name", "$value")
        }
    }
    return $arguments
}

<#
.SYNOPSIS
    Creates a new folder that only SYSTEM and Administrators can change, for the installer's copy.
.DESCRIPTION
    Named winget-app-setup-<32 hex digits>, the name the installer's housekeeping removes once it is
    a day old, should a run be killed before it removes the folder itself. The access list is set
    when the folder is created (no inherited entries), so no other account can add or replace a
    file in it in between.
.PARAMETER Root
    The folder to create it in (%SystemRoot%\Temp).
.RETURNS
    [string] The folder's path.
#>
function New-RmmRestrictedDirectory {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $path = Join-Path $Root ('winget-app-setup-' + [Guid]::NewGuid().ToString('N'))
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
    }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [void][System.IO.FileSystemAclExtensions]::Create((New-Object System.IO.DirectoryInfo($path)), $security)
    }
    else {
        [void][System.IO.Directory]::CreateDirectory($path, $security)
    }
    return $path
}

<#
.SYNOPSIS
    Starts the wrapper's transcript: <LogDirectory>\install-<time>-rmm.log.
.RETURNS
    [string] The transcript's path, or $null when it could not be started (the run goes on).
#>
function Start-RmmTranscript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory
    )

    try {
        if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
            [void](New-Item -Path $LogDirectory -ItemType Directory -Force -ErrorAction Stop)
        }
        $path = Join-Path $LogDirectory ('install-{0:yyyyMMdd-HHmmss}-rmm.log' -f (Get-Date))
        [void](Start-Transcript -Path $path -ErrorAction Stop)
        return $path
    }
    catch {
        Write-RmmLine "Could not start the wrapper's log: $($_.Exception.Message). Continuing without it." 'Yellow'
        return $null
    }
}

<#
.SYNOPSIS
    The machine phase: gets the pinned installer, checks it and runs it, and returns its exit code.
.DESCRIPTION
    See the script's description. Returns 5, without running anything, when it cannot run the
    installer it was asked for.
.PARAMETER ScriptPath
    This script's path, for the 64-bit relaunch.
.PARAMETER ForwardedArguments
    The arguments the relaunch passes on (ConvertTo-RmmForwardedArgument).
.PARAMETER PinnedCommit
    The pinned commit.
.PARAMETER PinnedSha256
    The pinned SHA256.
.PARAMETER LogDirectory
    Where the transcript goes. Default: %ProgramData%\winget-app-setup\logs.
.PARAMETER CopyRoot
    Where the installer's copy goes. Default: %SystemRoot%\Temp.
.RETURNS
    [int]
#>
function Invoke-RmmMachinePhase {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string[]]$ForwardedArguments = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InstallerPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InstallerSha256,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,

        [Parameter(Mandatory = $false)]
        [switch]$From32BitHost,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PinnedCommit,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PinnedSha256,

        [Parameter(Mandatory = $false)]
        [string]$LogDirectory = (Join-Path $env:ProgramData 'winget-app-setup\logs'),

        [Parameter(Mandatory = $false)]
        [string]$CopyRoot = ((Get-RmmWindowsDirectory) + '\Temp')
    )

    if (Test-Rmm32BitHostOn64BitWindows) {
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
            Write-RmmLine 'This is a 32-bit PowerShell on 64-bit Windows, and the wrapper cannot relaunch itself in 64-bit Windows PowerShell because it was not started from a file. Run it as a script file (-File). Nothing was installed.' 'Red'
            return 5
        }
        $nativePowerShell = Get-RmmSysnativePowerShellPath
        Write-RmmLine "This is a 32-bit PowerShell on 64-bit Windows (as Endpoint Central's 32-bit agent starts scripts): relaunching in 64-bit Windows PowerShell ($nativePowerShell)."
        # A wrapper started without parameters forwards none: ConvertTo-RmmForwardedArgument's empty
        # array reaches here as $null, and @($null) would add one empty argument. Windows PowerShell
        # drops an empty argument to a program; a 32-bit PowerShell 7.3 or later passes it on as "",
        # which the relaunched wrapper binds to its first positional parameter, -InstallerPath (the
        # same flaw rmm/Get-WingetFleetHealth.ps1 and rmm/Repair-WauLogonTrigger.ps1 had).
        $forwarded = @($ForwardedArguments | Where-Object { -not [string]::IsNullOrEmpty($_) })
        $relaunchArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $forwarded + @('-From32BitHost')
        $relaunchExitCode = Invoke-RmmProcess -FilePath $nativePowerShell -ArgumentList $relaunchArguments
        if ($null -eq $relaunchExitCode) {
            Write-RmmLine 'The 64-bit relaunch could not be started. Nothing was installed.' 'Red'
            return 5
        }
        return [int]$relaunchExitCode
    }

    $transcriptPath = Start-RmmTranscript -LogDirectory $LogDirectory
    $copyDirectory = $null
    try {
        Write-RmmLine ('winget-app-setup RMM wrapper (machine phase): running as {0}, 64-bit process: {1}, PowerShell {2}.' -f (Get-RmmAccountName), [Environment]::Is64BitProcess, $PSVersionTable.PSVersion)
        if ($From32BitHost) {
            Write-RmmLine 'Started by a 32-bit PowerShell on 64-bit Windows, and relaunched in 64-bit Windows PowerShell through Sysnative.'
        }

        $expectedSha256 = $InstallerSha256
        if ([string]::IsNullOrWhiteSpace($expectedSha256)) {
            $expectedSha256 = $PinnedSha256
        }
        $url = $null
        if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
            if (-not (Test-RmmSha256 -Hash $expectedSha256)) {
                Write-RmmLine "There is no SHA256 to check $InstallerPath against: pass -InstallerSha256, or set the pins at the top of this script. Nothing was installed." 'Red'
                return 5
            }
            Write-RmmLine "Installer: the local file $InstallerPath, expected SHA256 $expectedSha256."
        }
        else {
            if (-not (Test-RmmPinnedCommit -Commit $PinnedCommit) -or -not (Test-RmmSha256 -Hash $PinnedSha256)) {
                Write-RmmLine 'This wrapper has no pinned installer yet: set PinnedInstallerCommit and PinnedInstallerSha256 at the top of the script (pwsh -File build/Set-RmmInstallerPin.ps1 -Commit <commit on main>), then upload it again. Nothing was installed.' 'Red'
                return 5
            }
            $url = Get-RmmInstallerUrl -Commit $PinnedCommit
            Write-RmmLine "Installer: $url, expected SHA256 $expectedSha256."
        }

        $copyDirectory = New-RmmRestrictedDirectory -Root $CopyRoot
        $copyPath = Join-Path $copyDirectory 'winget-app-install.ps1'
        if ($url) {
            if (-not (Save-RmmInstallerDownload -Url $url -Destination $copyPath)) {
                Write-RmmLine "Could not download $url. Nothing was installed." 'Red'
                return 5
            }
        }
        else {
            Copy-Item -LiteralPath $InstallerPath -Destination $copyPath -ErrorAction Stop
        }
        $actualSha256 = Get-RmmFileSha256 -Path $copyPath
        if ($actualSha256 -ne $expectedSha256.ToUpperInvariant()) {
            Write-RmmLine "The installer's SHA256 is $actualSha256, not the expected $expectedSha256, so it was not run. Nothing was installed." 'Red'
            return 5
        }
        Write-RmmLine "Installer checked (SHA256 $actualSha256)."

        $installerArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $copyPath, '-NonInteractive')
        if ($SkipSystemCheck) {
            $installerArguments += '-SkipSystemCheck'
        }
        $windowsPowerShell = Get-RmmWindowsPowerShellPath
        Write-RmmLine ('Running: {0} {1}' -f $windowsPowerShell, ($installerArguments -join ' '))
        $installerExitCode = Invoke-RmmProcess -FilePath $windowsPowerShell -ArgumentList $installerArguments
        if ($null -eq $installerExitCode) {
            Write-RmmLine 'The installer could not be started. Nothing was installed.' 'Red'
            return 5
        }
        Write-RmmLine ('The installer exited with {0}. Its transcripts and last-run.json are in {1}.' -f $installerExitCode, $LogDirectory)
        return [int]$installerExitCode
    }
    catch {
        Write-RmmLine "The wrapper stopped on an unexpected error: $($_.Exception.Message)" 'Red'
        return 5
    }
    finally {
        if ($copyDirectory) {
            Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($transcriptPath) {
            try {
                [void](Stop-Transcript)
            }
            catch {
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $machinePhaseExitCode = Invoke-RmmMachinePhase -ScriptPath $PSCommandPath -ForwardedArguments (ConvertTo-RmmForwardedArgument -BoundParameters $PSBoundParameters) -InstallerPath $InstallerPath -InstallerSha256 $InstallerSha256 -SkipSystemCheck:$SkipSystemCheck -From32BitHost:$From32BitHost -PinnedCommit $PinnedInstallerCommit -PinnedSha256 $PinnedInstallerSha256
    exit ([int](@($machinePhaseExitCode)[-1]))
}
