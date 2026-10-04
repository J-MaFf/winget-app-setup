<#PSScriptInfo

.VERSION 1.0.0

.GUID b5b5f614-90c3-42a9-94e3-b7dd6e6de262

.AUTHOR Joey Maffiola

.EXTERNALMODULEDEPENDENCIES winget, Microsoft.WinGet.Client

.TAGS winget, installation, automation

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES Initial version

.Changelog
    1.0.0 - This is the initial version of the script. It installs a list of programs using winget.
#>


<#
.SYNOPSIS
 Installs a list of programs using winget.

.DESCRIPTION
 This script installs a curated list of programs from winget. The authoritative
 list is returned by Get-DefaultAppCatalog (WingetAppSetup/Public/AppCatalog.ps1,
 inlined below in this generated file) and shared with winget-app-uninstall.ps1.
 Run the script with -WhatIf to preview the exact set of planned installs without
 making any system changes.

.PARAMETER WhatIf
 When specified, performs all pre-flight checks and displays planned actions without making any system changes.

.PARAMETER SkipSystemCheck
 Bypasses the pre-flight system checks (OS version, disk space, network) for headless or automated use.

.PARAMETER NonInteractive
 Suppresses the interactive extras for unattended runs (RMM, CI, scheduled tasks): the summary
 grid-view window and the "press any key to exit" that holds the window at the end of a run or
 after an early failure. Also auto-detected when the session is non-interactive or stdin is
 redirected; under CI the early-failure key press is skipped too. The installer asks no yes/no
 questions on any path (issue #230), so this switch is only about those extras - it is not needed
 to keep a run from blocking on a prompt.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck,
    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive
)

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1.
# Edit the function source under WingetAppSetup/Public and WingetAppSetup/Private, then re-run the
# build to regenerate this file. See readme.md ("Project layout") for details.
# Build id: 1.0.0+1b230a41 (module version + SHA256 fragment of this whole script; issue #189).
# ------------------------------------------------------------------------------------------------

# Content-derived build identity, logged at startup so a transcript from a remote machine
# identifies exactly which installer build produced it (issue #189).
$script:InstallerBuildId = '1.0.0+1b230a41'

# ------------------------------------------------Functions------------------------------------------------

# --- Elevation ---
<#
.SYNOPSIS
    Detects if the script is running locally or from a remote source (e.g., via IEX).
.DESCRIPTION
    Checks if $PSScriptRoot is non-empty and represents a valid directory.
    Returns $true for local execution (file on disk), $false for remote execution (piped script).
.RETURNS
    [bool] True if running locally, False if running remotely.
#>
function Test-IsRunningLocally {
    # Check if $PSScriptRoot is non-empty and valid
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $false
    }

    # Verify it's an actual directory path
    try {
        $null = Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns the account name the current process is running as (DOMAIN\user), or $null.
#>
function Get-ProcessUserName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Returns $true when the current process runs as LocalSystem (NT AUTHORITY\SYSTEM, S-1-5-18).
.DESCRIPTION
    RMM agents (ManageEngine Endpoint Central, Intune) run scripts as SYSTEM. SYSTEM is not a
    logged-on person: it has no interactive session, no per-user app registrations, and its HKCU
    is not any user's, so per-user steps must not run as if it were the user.
    WindowsIdentity.IsSystem compares the token's user SID with S-1-5-18 on both .NET Framework
    (Windows PowerShell 5.1) and .NET. The catch is untyped on purpose: off Windows, GetCurrent()
    throws a MethodInvocationException wrapping PlatformNotSupportedException, which a typed catch
    would miss. A separate function so tests can Mock it.
.RETURNS
    [bool] True when running as SYSTEM; False otherwise or when the identity cannot be read.
#>
function Test-IsSystemAccount {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return [bool]$identity.IsSystem
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns the account name that owns the interactive console session (DOMAIN\user), or $null.
.DESCRIPTION
    Win32_ComputerSystem.UserName reports the interactively logged-on console user regardless of
    which account the current (possibly elevated) process runs as. Comparing it with
    Get-ProcessUserName detects cross-user elevation — running elevated as a different account
    than the logged-on user — where winget's per-user MSIX bootstrap is blocked by the AppX
    deployment service with 0x80073D19 because the process account has no interactive logon
    session (issue #159).
#>
function Get-InteractiveSessionUserName {
    try {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ([string]::IsNullOrWhiteSpace($userName)) {
            return $null
        }
        return $userName
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Says which account this run installs as, and whether that account is the signed-in user.
.DESCRIPTION
    Invoke-WingetInstall reads this once and passes the answer to the steps that depend on it
    (review findings P2-24, P3-22, P3-23):
      - IsSystem: the process runs as SYSTEM (Test-IsSystemAccount), as under an RMM agent such as
        ManageEngine Endpoint Central. SYSTEM is not a person: it has no per-user winget, and its
        per-user installs would land in its own profile.
      - IsCrossUserElevation: the process runs as a different account than the user signed in at
        the console (the #159 detection), such as a technician elevating as an admin-* account on a
        user's PC. Per-user state then belongs to the admin, not to the user. Always False for
        SYSTEM, which is not "elevating as another person" and gets its own messages.
    In both cases the run installs machine-wide only: an app that has no machine-wide installer is
    deferred instead of being installed for the wrong account.
.RETURNS
    [pscustomobject] with IsSystem, ProcessUser, SessionUser (either may be $null when unknown) and
    IsCrossUserElevation.
#>
function Get-InstallAccountContext {
    $isSystem = [bool](Test-IsSystemAccount)
    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    $isCrossUser = (-not $isSystem) -and (-not [string]::IsNullOrWhiteSpace($processUser)) -and (-not [string]::IsNullOrWhiteSpace($sessionUser)) -and ($processUser -ne $sessionUser)
    return [pscustomobject]@{
        IsSystem             = $isSystem
        ProcessUser          = $processUser
        SessionUser          = $sessionUser
        IsCrossUserElevation = [bool]$isCrossUser
    }
}

<#
.SYNOPSIS
    Detects whether Invoke-WingetInstall is executing from the WingetAppSetup module rather than
    the generated single-file installer.
.DESCRIPTION
    Auto-elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the imported
    module, $PSCommandPath resolves to WingetAppSetup/Public/Install.ps1 — a functions-only file —
    so the elevated window would define a function and exit without installing anything
    (issue #185). Callers use this check to fail fast with guidance instead of silently
    relaunching a no-op.
.PARAMETER InvocationModule
    The caller's $MyInvocation.MyCommand.Module. Non-null when the function was invoked from an
    imported module.
.PARAMETER CommandPath
    The caller's $PSCommandPath. Matched against the module layout to also catch a dot-sourced
    WingetAppSetup/Public/Install.ps1, where the module info is null but the defining file is
    still functions-only.
.RETURNS
    [bool] True when running from module context (relaunching $PSCommandPath would be a no-op).
#>
function Test-InvokedFromModuleContext {
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSModuleInfo]$InvocationModule,

        [Parameter(Mandatory = $false)]
        [string]$CommandPath
    )

    if ($null -ne $InvocationModule) {
        return $true
    }

    return [bool]($CommandPath -match '[\\/]WingetAppSetup[\\/]Public[\\/]Install\.ps1$')
}

<#
.SYNOPSIS
    Returns a WindowsPrincipal wrapping the current process's WindowsIdentity.
.DESCRIPTION
    Thin wrapper around the static [Security.Principal.WindowsIdentity]::GetCurrent() /
    [Security.Principal.WindowsPrincipal] construction, split out purely so Test-IsAdmin
    (Public/Elevation.ps1) has a command it can Mock in unit tests to simulate the underlying
    .NET call throwing (a static method call can't be mocked directly).
.RETURNS
    [Security.Principal.WindowsPrincipal] for the current process.
#>
function Get-CurrentWindowsPrincipal {
    [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
}

# Restart-WithElevation lives in Public/Elevation.ps1 (issue #190): it is exported so
# winget-app-uninstall.ps1 can reuse it instead of hand-rolling its own relaunch. The helpers below
# are its parts. Restart-WithElevation also runs under Windows PowerShell 5.1 (the uninstaller can
# be started from it), so they stay 5.1-runtime compatible.

<#
.SYNOPSIS
    Returns the Windows directory (%SystemRoot%, normally C:\Windows), without a trailing backslash.
.DESCRIPTION
    Falls back to %windir%, then C:\Windows, so it never returns an empty path (off Windows in
    tests, or in a process started with an emptied environment).
.RETURNS
    [string]
#>
function Get-WindowsDirectoryPath {
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
    Returns the path of Windows PowerShell (System32\WindowsPowerShell\v1.0\powershell.exe).
.DESCRIPTION
    Review finding P2-11. The elevated relaunch has to start a program that every account can run.
    It used to start 'wt.exe' or a bare 'pwsh.exe', which resolve through the invoking user's PATH
    and per-user app execution aliases (%LOCALAPPDATA%\Microsoft\WindowsApps). A separate admin
    account that elevates has neither when PowerShell 7 or Windows Terminal is a per-user MSIX of
    the end user, so the elevated window failed to start and nothing was installed. Windows
    PowerShell ships with Windows at this path for every account; the installer re-enters its
    Windows PowerShell 5.1 dispatch there and finds or installs PowerShell 7 as the elevating
    account. Built by string concatenation, not Join-Path, which off Windows rejects a C: path.
.RETURNS
    [string] The full path of powershell.exe.
#>
function Get-WindowsPowerShellPath {
    return (Get-WindowsDirectoryPath) + '\System32\WindowsPowerShell\v1.0\powershell.exe'
}

<#
.SYNOPSIS
    Returns the folder under which the elevated relaunch copies the installer: %SystemRoot%\Temp.
.DESCRIPTION
    Review finding P3-11. The elevated process copies the installer, after checking it, into a new
    folder here whose access list it sets itself. Standard users can create entries in this folder
    but cannot list it, rename or delete what another account created in it, so an account that is
    not an administrator cannot reach the copy. A folder under the end user's %TEMP% would not do:
    that user can rename anything in it. A function so tests can point it elsewhere.
.RETURNS
    [string]
#>
function Get-ElevatedCopyRoot {
    return (Get-WindowsDirectoryPath) + '\Temp'
}

<#
.SYNOPSIS
    Builds the command the elevated Windows PowerShell runs to check a script, copy it into a folder
    only administrators can change, and run the copy.
.DESCRIPTION
    Review finding P3-11. The non-elevated run used to relaunch `-File <its own path>` elevated. On
    the Windows PowerShell 5.1 one-liner that path is a copy in the end user's %TEMP%, which that
    user (or malware running as them) can rewrite while the UAC prompt is up, so the administrator
    who approves it would run whatever the file holds by then.

    A check inside the script itself would not help: whatever replaced the file would not contain
    it. The check has to run before any of the file does, so it is this command, given on the
    elevated process's command line (-Command), which the non-elevated run builds and the file
    cannot change. It:
      1. reads the file's bytes once and compares their SHA256 with the one the non-elevated run
         computed, and stops (exit code 5) when they differ;
      2. creates a new folder under -CopyRoot with an access list of its own (SYSTEM and
         Administrators, no inherited entries) and writes those same bytes into it;
      3. runs that copy with Windows PowerShell -File, in the same window, forwarding the
         arguments, and exits with its exit code;
      4. deletes the folder.
    The copy has to be made by the elevated process: a non-elevated process cannot create a folder
    that it cannot change itself, because it would own the folder and keep the right to change its
    access list.

    The access list does not name the elevating account itself: its elevated token always has
    Administrators enabled, and Windows normally makes Administrators the owner of what it creates.
    When a user elevates their own account (Admin Approval Mode), that account's own entry would
    let any of its processes that are not elevated rewrite the copy until the elevated PowerShell 7
    reads it, which can be minutes later while PowerShell 7 installs (review of finding P3-11). A
    process that is not an administrator cannot write the copy, so it stops with exit code 5.

    On failure it prints why and waits for Enter, since this window closes when it exits; the
    elevated relaunch only happens when someone is at the console.

    One line, single quotes only: it is passed in double quotes on the command line, and
    ShellExecuteEx limits that command line to about 2048 characters. It always runs under Windows
    PowerShell 5.1 (Directory.CreateDirectory with a DirectorySecurity is .NET Framework only).
.PARAMETER ScriptPath
    The script to check and run.
.PARAMETER Sha256
    The SHA256 (hex) the script must have.
.PARAMETER PowerShellPath
    The Windows PowerShell that runs the copy.
.PARAMETER CopyRoot
    The folder the per-run copy folder is created in (Get-ElevatedCopyRoot).
.PARAMETER AdditionalArguments
    Switches forwarded to the script, for example '-SkipSystemCheck'.
.RETURNS
    [string] The PowerShell command text.
#>
function New-ElevationVerifierCommand {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9A-Fa-f]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,

        [Parameter(Mandatory = $true)]
        [string]$CopyRoot,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^-[A-Za-z][A-Za-z0-9]*$')]
        [string[]]$AdditionalArguments = @()
    )

    # Each statement ends with ';' or a closing brace, so joining the lines with spaces keeps it valid.
    $template = @'
$ErrorActionPreference = 'Stop';
$exitCode = 5;
$copyDirectory = $null;
try {
    $bytes = [IO.File]::ReadAllBytes(@SOURCE@);
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '');
    if ($hash -ne @SHA256@) { throw 'the file changed after administrator rights were requested'; }
    $security = New-Object Security.AccessControl.DirectorySecurity;
    $security.SetAccessRuleProtection($true, $false);
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); }
    $copyDirectory = Join-Path @COPYROOT@ ('winget-app-setup-' + [Guid]::NewGuid().ToString('N'));
    [void][IO.Directory]::CreateDirectory($copyDirectory, $security);
    $copy = Join-Path $copyDirectory @NAME@;
    [IO.File]::WriteAllBytes($copy, $bytes);
    & @POWERSHELL@ -NoProfile -ExecutionPolicy Bypass -File $copy@ARGUMENTS@;
    $exitCode = $LASTEXITCODE;
} catch {
    Write-Host ('Did not run ' + @NAME@ + ': ' + $_) -ForegroundColor Red;
    try { [void](Read-Host 'Press Enter to close this window'); } catch { }
} finally {
    if ($copyDirectory) { Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue; }
}
exit $exitCode
'@

    # Single-quoted PowerShell literals. EscapeSingleQuotedStringContent doubles every character the
    # tokenizer reads as a single quote: the ASCII apostrophe and the typographic U+2018 to U+201B,
    # which a profile folder name can hold (an O'Brien account typed with a curly apostrophe) and
    # which would otherwise end the literal and break the whole command. Windows paths cannot
    # contain the double quote that would end the command-line argument.
    $quote = { param ([string]$Text) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'" }
    $forwardedArguments = ''
    if ($AdditionalArguments.Count -gt 0) {
        $forwardedArguments = ' ' + ($AdditionalArguments -join ' ')
    }
    $values = @{
        SOURCE     = (& $quote $ScriptPath)
        SHA256     = (& $quote $Sha256.ToUpperInvariant())
        COPYROOT   = (& $quote $CopyRoot)
        NAME       = (& $quote ($ScriptPath -split '[\\/]')[-1])
        POWERSHELL = (& $quote $PowerShellPath)
        ARGUMENTS  = $forwardedArguments
    }
    $command = (($template -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
    # One pass, so a placeholder-like text inside an inserted path is never replaced again.
    return [regex]::Replace($command, '@(SOURCE|SHA256|COPYROOT|NAME|POWERSHELL|ARGUMENTS)@', [System.Text.RegularExpressions.MatchEvaluator] { param ($match) $values[$match.Groups[1].Value] })
}

<#
.SYNOPSIS
    Starts a program elevated (ShellExecuteEx with the 'runas' verb) and returns its Process.
.DESCRIPTION
    Process.Start rather than Start-Process -Verb RunAs: Start-Process turns a failed launch into an
    InvalidOperationException that keeps only the translated message, while Process.Start throws
    the Win32Exception itself, so a declined UAC prompt is recognized by its code (1223,
    ERROR_CANCELLED) in every display language (review finding P2-12). A separate function so tests
    can Mock it.
.PARAMETER FilePath
    The program.
.PARAMETER ArgumentString
    Its command line, without the program name.
.RETURNS
    [System.Diagnostics.Process]. Throws when the program could not be started (or the UAC prompt
    was declined).
#>
function Start-ElevatedProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$ArgumentString
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentString
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = 'runas'
    return [System.Diagnostics.Process]::Start($startInfo)
}

# --- FailureReporting ---
# Failure-reporting helpers (issue #189). Install-WingetPackage returns a rich diagnostic
# hashtable (ExitCode, Attempts, SessionErrorExhausted, MachineScopeFellBack) built precisely
# because the 0x80073D19-era failures were only diagnosable by hex exit code — but both
# Invoke-WingetInstall call sites used to discard it, reporting every failure as a generic
# "No package found matching input criteria." These helpers turn that result into the failure
# messages and the per-app Reason column of the failed-apps summary.

<#
.SYNOPSIS
    Ends the installer run with the given exit code, marking the exit as intended.
.DESCRIPTION
    Used by the generated entry script (build/fragments/tail.ps1) for every deliberate exit, so its
    abort guard can tell a run that chose its exit code from one stopped from outside: an outside
    stop (Ctrl+C, a console-stop event) unwinds through the entry script's finally block without
    this marker set, and is then reported as exit code 5 instead of 0. Like a bare `exit`, this ends
    the whole script (and, under irm | iex, the host process), so module functions never call it:
    Invoke-WingetInstall returns its exit code and the entry script exits with it.

    A failed run that has not shown its outcome yet - an early exit, such as a failed pre-flight
    check, winget missing, a declined elevation, a failed PowerShell 7 bootstrap or an aborted run -
    first prints Write-InstallerExitNotice: the reason, the log path and the build id, then waits
    for a key press when someone is at the console (review finding P2-14). Under irm | iex the exit
    closes the window, which used to take the error and the log path with it before anyone could
    read them. Runs under Windows PowerShell 5.1 too (the bootstrap phase), so it stays
    5.1-runtime compatible.
.PARAMETER Code
    The process exit code. Default 0.
.PARAMETER Reason
    What stopped the run, when the caller knows more than the exit code says. Optional.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch: no key press is awaited.
.PARAMETER OutcomeShown
    The run already showed its outcome and waited for a key press (Invoke-WingetInstall's summary
    and final prompt, a PowerShell 7 run the bootstrap relaunched, or the elevated run of a run that
    relaunched itself elevated), so exit without the notice.
#>
function Exit-Installer {
    param (
        [Parameter(Mandatory = $false)]
        [int]$Code = 0,
        [Parameter(Mandatory = $false)]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$OutcomeShown
    )

    if ($Code -ne 0 -and -not $OutcomeShown) {
        # Recorded before the key press: Ctrl+C there still ends the run with this code, through the
        # entry script's abort guard, instead of as an abort (5).
        $script:InstallerPendingExitCode = $Code
        try {
            Write-InstallerExitNotice -Code $Code -Reason $Reason -NonInteractive:$NonInteractive
        }
        catch {
            # The notice is a courtesy; nothing may keep the run from exiting with its code.
        }
    }
    $script:InstallerExitRequested = $true
    exit $Code
}

<#
.SYNOPSIS
    Prints why the installer is stopping early, where its log is and which build ran, then waits for
    a key press when someone is at the console.
.DESCRIPTION
    Review findings P2-14 and P3-15. A teammate who runs the irm | iex one-liner in an elevated
    console files a GitHub issue when a run fails. Every early exit used to print one red line and
    close the window at once, so the issue said only that the window closed. This prints, in one
    block: the exit code with the caller's reason (or what the code means), the log file path, the
    installer build id and where to report the failure, with a privacy note (the repository is
    public, and a transcript header names the computer and the accounts). Then it waits for a key
    press, unless the run is non-interactive (Test-EffectiveNonInteractive) or under CI
    (Test-IsContinuousIntegration), so an unattended or RMM run never blocks.

    Runs under Windows PowerShell 5.1 too (the bootstrap phase): 5.1-runtime compatible only.
.PARAMETER Code
    The exit code the run is about to end with.
.PARAMETER Reason
    What stopped the run, when the caller knows more than the exit code says. Optional.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch: no key press is awaited.
.PARAMETER NoPause
    Print the notice without waiting for a key press (the console stays open anyway).
#>
function Write-InstallerExitNotice {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Code,
        [Parameter(Mandatory = $false)]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$NoPause
    )

    # What the code means for a run that stopped early. Without a reason from the caller, this is
    # the line under the specific error the run printed just above.
    $why = $Reason
    if (-not $why) {
        switch ($Code) {
            1 { $why = 'a pre-flight check failed (see above)' }
            2 { $why = 'winget is not available or could not be started (see above)' }
            3 { $why = 'the app catalog failed validation (see above)' }
            4 { $why = 'administrator rights are required, and this run was not elevated (see above)' }
            5 { $why = 'the run was aborted before it finished (see above)' }
            7 { $why = 'PowerShell 7 could not be installed, or the installer could not be relaunched under it (see above)' }
        }
    }

    Write-Host ''
    if ($why) {
        Write-ErrorMessage ('The installer stopped early with exit code {0}: {1}.' -f $Code, $why)
    }
    else {
        Write-ErrorMessage ('The installer stopped early with exit code {0}.' -f $Code)
    }
    if ($script:InstallLogPath) {
        Write-Info "Log file: $script:InstallLogPath"
    }
    else {
        Write-WarningMessage 'Log file: none - the transcript could not be started (see the warning at the start of the run).'
    }
    if ($script:InstallerBuildId) {
        Write-Info "Installer build: $script:InstallerBuildId"
    }
    Write-Info 'To report this, open https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml and give the exit code, the installer build and the log file.'
    Write-WarningMessage 'That repository is public, and the log names this computer and the accounts that ran the installer: remove or redact the log''s header before attaching it.'

    if ($NoPause) {
        return
    }
    if ((Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) -or (Test-IsContinuousIntegration)) {
        return
    }
    Write-Prompt 'Press any key to exit...'
    try {
        [void][System.Console]::ReadKey($true)
    }
    catch {
        # No console to read a key from after all: nothing to wait for.
    }
}

<#
.SYNOPSIS
    Decides Invoke-WingetInstall's final exit code from the run's outcome.
.DESCRIPTION
    Invoke-WingetInstall returns this as its exit code at the end of a run. The precedence is
    1 > 2 > 8 > 3010 > 0: failed apps first (1); then a winget that can no longer be launched at the
    end of the run (2, the same code as "winget unavailable" at the start), so a run can never exit 0
    while leaving winget broken; then a run that needs a restart to finish (3010, review finding
    P3-16: the code RMM tools and Intune read as "succeeded, restart required"). Code 8 (apps
    installed, but automatic updates not configured or unhealthy) is not returned yet; it belongs
    between 2 and 3010.
.PARAMETER FailedAppCount
    Number of apps still failed after the retry pass.
.PARAMETER WingetUsable
    Result of the end-of-run winget launch probe.
.PARAMETER RestartRequired
    The run's installs finished but need a restart: an install reported it, or Windows gained a
    pending restart during the run. A restart that was already pending before the run does not
    count. Default False.
.RETURNS
    [int] 0, 1, 2 or 3010.
#>
function Get-InstallerExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$FailedAppCount,

        [Parameter(Mandatory = $true)]
        [bool]$WingetUsable,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false
    )

    if ($FailedAppCount -gt 0) {
        return 1
    }
    if (-not $WingetUsable) {
        return 2
    }
    # Code 8 (auto-updates not configured or unhealthy) goes here once it exists.
    if ($RestartRequired) {
        return 3010
    }
    return 0
}

<#
.SYNOPSIS
    Formats a one-line, human-readable reason for a failed app install.
.DESCRIPTION
    Combines the shared install pipeline's FailureReason bucket with the diagnostic detail the
    installer result carries: the winget exit code (hex, with its name from Get-WingetExitCodeInfo),
    the attempt count, whether the machine-scope preference fell back to winget's default scope,
    whether the 0x80073D19 session-error retries were exhausted (issue #189), how long the install
    waited for another installation to finish, whether the install ran out of time (review finding
    P2-5), and where the installer's log is (P2-6). Used both for the console failure message and
    for the Reason column in the failed-apps summary table.

    When the package is missing after an install that winget reported as failed (VerifyNotFound, or
    a package-specific installer's CustomInstallFailed), the reason starts with what the exit code
    means, for example 'another installation was in progress (Windows Installer was busy) - re-run
    the installer once it has finished', or 'winget install failed' for a code the table does not
    know (review finding P2-15). 'package not found after install' is kept for an install that
    winget reported as successful.
.PARAMETER FailureReason
    The FailureReason string from the shared install pipeline ('PreCheckTimeout',
    'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed', 'VerifyTimeout',
    'VerifyLaunchFailed', 'VerifyFailed', 'VerifyNotFound', 'CustomInstallFailed',
    'WingetNotLaunchable', 'MachineCheckFailed'). Unknown or empty values fall back to a generic
    'install failed'.
.PARAMETER InstallResult
    The InstallResult hashtable from the shared install pipeline: Install-WingetPackage's
    ExitCode/Attempts/SessionErrorExhausted/MachineScopeFellBack shape, a custom installer's
    ExitCode/Installed shape, or $null when no installer ran (timeouts, dry runs). Keys are probed
    individually, so partial shapes format whatever detail they carry.
.PARAMETER LaunchError
    Why winget could not be started, for the launch-failure reasons (the pipeline's LaunchError).
    Shown last, so the table row says what Windows reported (review finding P2-9).
.PARAMETER CheckExitCode
    The exit code of the `winget list` check that failed, for PreCheckFailed and VerifyFailed (the
    pipeline's CheckExitCode). Shown with the reason, apart from the install's own exit code.
.RETURNS
    [string] e.g. 'another installation was in progress (Windows Installer was busy) - re-run the
    installer once it has finished; winget exit 0x8A150102 INSTALL_INSTALL_IN_PROGRESS, 4 attempts,
    machine-scope fallback: no, waited 600 seconds for another installation'. Never $null or empty.
#>
function Format-InstallFailureReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FailureReason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$InstallResult,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LaunchError,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$CheckExitCode
    )

    $base = switch ($FailureReason) {
        'PreCheckTimeout' { 'winget list timed out during the pre-install check' }
        'PreCheckLaunchFailed' { 'winget could not be launched for the pre-install check' }
        'PreCheckFailed' { 'winget list failed during the pre-install check' }
        'InstallLaunchFailed' { 'winget could not be launched to install it' }
        'VerifyTimeout' { 'post-install verification timed out' }
        'VerifyLaunchFailed' { 'winget could not be launched to verify the install' }
        'VerifyFailed' { 'winget list failed during the post-install check' }
        'VerifyNotFound' { 'package not found after install' }
        'CustomInstallFailed' { 'installer reported failure' }
        'WingetNotLaunchable' { 'not attempted: winget cannot be launched on this machine (see above)' }
        'MachineCheckFailed' { 'could not check whether it is provisioned for every user on this PC (see the warning above)' }
        default { 'install failed' }
    }
    if ($null -ne $CheckExitCode -and @('PreCheckFailed', 'VerifyFailed') -contains $FailureReason) {
        # The list's own exit code (review finding P2-9), kept apart from the install's 'winget exit'.
        $base = '{0} with exit {1}' -f $base, (Format-WingetExitCode -ExitCode $CheckExitCode)
    }

    $installExitCode = $null
    if ($InstallResult -and $InstallResult.ContainsKey('ExitCode') -and $null -ne $InstallResult.ExitCode) {
        $installExitCode = [int]$InstallResult.ExitCode
    }
    if ($null -ne $installExitCode -and $installExitCode -ne 0 -and @('VerifyNotFound', 'CustomInstallFailed') -contains $FailureReason) {
        # winget said the install failed, and the package is indeed missing: what winget's code
        # means is the reason, not 'package not found after install' (review finding P2-15).
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $installExitCode
        if ($codeInfo) {
            $base = $codeInfo.Meaning
        }
        elseif ($FailureReason -eq 'VerifyNotFound') {
            $base = 'winget install failed'
        }
    }

    $detailParts = @()
    if ($InstallResult) {
        if ($null -ne $installExitCode) {
            $detailParts += ('winget exit {0}' -f (Format-WingetExitCode -ExitCode $installExitCode))
        }
        if ($InstallResult.ContainsKey('Attempts') -and $InstallResult.Attempts) {
            $attemptWord = if ([int]$InstallResult.Attempts -eq 1) { 'attempt' } else { 'attempts' }
            $detailParts += ('{0} {1}' -f $InstallResult.Attempts, $attemptWord)
        }
        if ($InstallResult.ContainsKey('MachineScopeFellBack')) {
            $detailParts += ('machine-scope fallback: {0}' -f $(if ($InstallResult.MachineScopeFellBack) { 'yes' } else { 'no' }))
        }
        if ($InstallResult.ContainsKey('SessionErrorExhausted') -and $InstallResult.SessionErrorExhausted) {
            $detailParts += 'session error 0x80073D19 persisted through every retry'
        }
        if ($InstallResult.ContainsKey('InstallInProgressWaitedSeconds') -and $InstallResult.InstallInProgressWaitedSeconds) {
            $detailParts += ('waited {0} seconds for another installation' -f [int]$InstallResult.InstallInProgressWaitedSeconds)
        }
        if ($InstallResult.ContainsKey('LaunchErrorExhausted') -and $InstallResult.LaunchErrorExhausted) {
            # issue #253: winget.exe could not be launched, so no install ever actually ran (the
            # 'InstallLaunchFailed' reason says so); this counts the launches that failed.
            $launchAttempts = 0
            if ($InstallResult.ContainsKey('LaunchAttempts') -and $InstallResult.LaunchAttempts) {
                $launchAttempts = [int]$InstallResult.LaunchAttempts
            }
            if ($launchAttempts -gt 0) {
                $launchWord = if ($launchAttempts -eq 1) { 'failed launch' } else { 'failed launches' }
                $detailParts += ('{0} {1}' -f $launchAttempts, $launchWord)
            }
        }
        if ($InstallResult.ContainsKey('TimedOut') -and $InstallResult.TimedOut) {
            # Review finding P2-5: the install ran out of time and was stopped, so there is no exit
            # code to show.
            $limit = 'its time limit'
            if ($InstallResult.ContainsKey('TimeoutSeconds') -and $InstallResult.TimeoutSeconds) {
                $limit = '{0} minutes' -f [Math]::Round([int]$InstallResult.TimeoutSeconds / 60)
            }
            $detailParts += ('winget install stopped after {0}' -f $limit)
        }
        if ($InstallResult.ContainsKey('InstallerLogPath') -and $InstallResult.InstallerLogPath) {
            # Review finding P2-6: the installer's own log, next to the transcript.
            $detailParts += ('installer log: {0}' -f $InstallResult.InstallerLogPath)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($LaunchError)) {
        $detailParts += ('launch error: {0}' -f $LaunchError.Trim().TrimEnd('.'))
    }

    if ($detailParts.Count -gt 0) {
        return ('{0}; {1}' -f $base, ($detailParts -join ', '))
    }
    return $base
}

<#
.SYNOPSIS
    Prints what an installed app's install result adds to 'Successfully installed', and returns
    whether the install needs a restart to finish.
.DESCRIPTION
    Review finding P3-16. An app counts as installed when `winget list` finds it, whatever winget's
    exit code was, and the success line used to drop that code. This prints, after it:
      - '<app> has no machine-wide installer, so it was installed for this account only.' when the
        install fell back to winget's default scope (MachineScopeFellBack; review finding P3-22:
        that was shown only when the install failed);
      - '<app> needs a restart to finish installing (<why>).' when the result's RestartRequired is
        set (winget 0x8A150109 or 0x8A15010B, or winget's 'Restart your PC to finish installation.'
        warning; see Install-WingetPackage);
      - 'winget reported <code> for <app>, but it is installed.' for any other non-zero exit code,
        with the installer log when there is one, instead of dropping the code.
    Nothing for a plain success, or when there is no install result.
.PARAMETER AppName
    The winget package id.
.PARAMETER InstallResult
    The app's Install-AppWithVerification InstallResult, or $null.
.RETURNS
    [bool] True when the install needs a restart to finish.
#>
function Write-InstalledAppNote {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult
    )

    if ($null -eq $InstallResult) {
        return $false
    }
    $exitCode = $null
    if ($null -ne $InstallResult.ExitCode) {
        $exitCode = [int]$InstallResult.ExitCode
    }

    if ($InstallResult.MachineScopeFellBack) {
        Write-Info ('{0} has no machine-wide installer, so it was installed for this account only.' -f $AppName)
    }

    if ($InstallResult.RestartRequired) {
        $why = "winget printed 'Restart your PC to finish installation.'"
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            $why = 'winget exit {0}' -f (Format-WingetExitCode -ExitCode $exitCode)
        }
        Write-WarningMessage ('{0} needs a restart to finish installing ({1}).' -f $AppName, $why)
        return $true
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $logNote = ''
        if ($InstallResult.InstallerLogPath) {
            $logNote = '; installer log: {0}' -f $InstallResult.InstallerLogPath
        }
        Write-WarningMessage ('winget reported {0} for {1}, but it is installed{2}.' -f (Format-WingetExitCode -ExitCode $exitCode), $AppName, $logNote)
    }
    return $false
}

<#
.SYNOPSIS
    Explains, under the installation summary, why apps were deferred and who can install them.
.DESCRIPTION
    Review findings P3-22, P3-23. A run as SYSTEM or under cross-user elevation installs for the whole
    PC only, so an app whose package has no machine-wide installer is not installed by it: it is
    reported as Deferred, neither installed nor failed, and does not change the exit code. This
    says so once, for all of them, with what can still install them. That is only the signed-in
    user's own account (named under cross-user elevation): this installer run as that user works
    only when the account is an administrator, since the installer needs administrator rights and
    a standard user's UAC prompt elevates as another account, which defers the app again; on a
    standard user's PC it takes a per-user deployment. The line does not claim a per-user installer
    exists: winget answers 0x8A150010 at --scope machine also when no installer applies to the PC
    at all. No-op when nothing was deferred.
.PARAMETER DeferredApps
    The package ids of the deferred apps.
.PARAMETER AccountContext
    Get-InstallAccountContext's result for the run.
#>
function Write-DeferredAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DeferredApps,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    if (-not $DeferredApps -or $DeferredApps.Count -eq 0) {
        return
    }

    $pronoun = 'them'
    if ($DeferredApps.Count -eq 1) {
        $pronoun = 'it'
    }
    $why = 'this run installs for the whole PC only'
    $account = "the signed-in user's own account"
    $who = 'the signed-in user'
    if ($AccountContext -and $AccountContext.IsSystem) {
        $why = 'a run as SYSTEM installs for the whole PC only'
    }
    elseif ($AccountContext -and $AccountContext.IsCrossUserElevation) {
        $why = "installing per-user here would install for '$($AccountContext.ProcessUser)' instead of '$($AccountContext.SessionUser)'"
        $account = "the account '$($AccountContext.SessionUser)'"
        $who = "'$($AccountContext.SessionUser)'"
    }
    Write-WarningMessage ('Deferred: {0} - winget found no machine-wide installer for {1} that applies to this PC ({2} with --scope machine), and {3}. Not installed and not counted as failed. A per-user app can only be installed in {4}: by this installer run as {5} when that account is an administrator, otherwise by a per-user deployment (an RMM script that runs as the user, or the Microsoft Store).' -f ($DeferredApps -join ', '), $pronoun, (Format-WingetExitCode -ExitCode -1978335216), $why, $account, $who)
}

<#
.SYNOPSIS
    Renders the per-app failure-reason table shown under the installation summary.
.DESCRIPTION
    Prints one row per failed app with its Format-InstallFailureReason diagnostic (issue #189), so
    the summary — and the persistent transcript — carry the winget exit code and retry detail
    instead of just a list of failed names. No-ops when nothing failed. Kept separate from
    Invoke-WingetInstall so the rendering is unit-testable without driving the whole orchestrator.
.PARAMETER FailedApps
    Array of @{ Name = <winget package id>; Reason = <string> } hashtables tracked by
    Invoke-WingetInstall.
#>
function Write-FailedAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$FailedApps
    )

    if (-not $FailedApps -or $FailedApps.Count -eq 0) {
        return
    }

    $failedRows = @(foreach ($failedApp in $FailedApps) {
            , @([string]$failedApp.Name, [string]$failedApp.Reason)
        })
    Write-Table -Headers @('App', 'Reason') -Rows $failedRows -Title 'Failed Installations'
}

# --- GraphicalTools ---
<#
.SYNOPSIS
    Checks if Out-GridView is available in the current session.
.DESCRIPTION
    Determines whether Out-GridView can be used by checking if the session is
    interactive and if the Out-GridView command is available. This is used to
    decide whether to offer or use the interactive grid view functionality.
.OUTPUTS
    Returns $true if Out-GridView is available, $false otherwise.
#>
function Test-CanUseGridView {
    # Check if we're in an interactive session
    if (-not [Environment]::UserInteractive) {
        return $false
    }

    # Check if Out-GridView is available
    try {
        Get-Command Out-GridView -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Ensures Out-GridView is available by installing Microsoft.PowerShell.GraphicalTools when required.
.DESCRIPTION
    Checks for the Out-GridView cmdlet and, when missing, installs the Microsoft.PowerShell.GraphicalTools module including NuGet provider remediation.
.PARAMETER WhatIf
    Dry run: only checks whether Out-GridView is available and, when it is not, prints what a real
    run would install. Nothing is installed (P2-16: the dry run used to install the NuGet provider
    and the module for all users).
.RETURNS
    [bool] True when Out-GridView can be invoked, otherwise False.
    Under -WhatIf, True only when Out-GridView is already available.
#>
function Test-AndInstallGraphicalTools {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    try {
        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            return $true
        }

        if ($WhatIf) {
            Write-Info '[DRY-RUN] Out-GridView is not available. A real run would install Microsoft.PowerShell.GraphicalTools for all users from the PowerShell Gallery (and the NuGet package provider if it is missing) to show the summary in a grid view.'
            return $false
        }

        $graphicalModule = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.GraphicalTools'
        if (-not $graphicalModule) {
            Write-WarningMessage 'Microsoft.PowerShell.GraphicalTools module is missing. Installing to enable Out-GridView...'
        }
        else {
            Write-WarningMessage 'Microsoft.PowerShell.GraphicalTools module found but Out-GridView is unavailable. Importing module...'
        }

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-WarningMessage 'NuGet package provider not found. Installing...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        # -Repository PSGallery: elevated, for all users, so never from another registered
        # repository (review finding P3-20; see Test-AndInstallWingetModule).
        Install-Module -Name Microsoft.PowerShell.GraphicalTools -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.PowerShell.GraphicalTools -ErrorAction Stop
        Write-Success 'Microsoft.PowerShell.GraphicalTools is loaded for this session.'

        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            Write-Success 'Out-GridView is available for interactive summaries.'
            return $true
        }

        Write-Warning 'Microsoft.PowerShell.GraphicalTools installation completed, but Out-GridView is still unavailable.'
    }
    catch {
        Write-Warning "Failed to install Microsoft.PowerShell.GraphicalTools module: $_"
    }

    return $false
}

# --- InstallVerification ---
<#
.SYNOPSIS
    Decides whether a catalog app applies to this machine by evaluating its condition.
.DESCRIPTION
    The one place the catalog's applicability rule lives (issue #217; review findings P3-33,
    P3-34): an app with no 'condition' applies; otherwise the condition scriptblock decides, and
    a falsy result means the app does not apply (Skipped, 'not applicable').

    Fail open: a condition that throws or writes an error - a probe that has no answer, such as a
    CIM query that failed (Get-ComputerManufacturer) - is warned about and the app is treated as
    applicable, so the installer attempts the install. A broken probe must never silently drop
    an app: the worst case of failing open is an install attempt that fails loudly and shows in
    the summary and the exit code, while failing closed would skip the app and still exit 0.
    Probes must therefore throw when they cannot answer rather than return an empty or default
    value.

    Invoke-WingetInstall calls this once per app per run, before the first pass, and carries the
    verdict into the retry pass (Install-AppWithVerification -Applicable).
.PARAMETER App
    A validated app-definition hashtable with an optional 'condition' scriptblock.
.RETURNS
    [bool] True when the app applies to this machine (or its condition could not be evaluated).
#>
function Test-AppApplicability {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    if (-not $App.condition) {
        return $true
    }
    # A non-terminating error inside the condition (a probe that wrote an error and returned
    # nothing, as Get-CimInstance does without -ErrorAction Stop) counts as no answer too, not as
    # "does not apply": the preference reaches the condition and the probes it calls.
    $ErrorActionPreference = 'Stop'
    try {
        return [bool](& $App.condition)
    }
    catch {
        Write-WarningMessage "Condition for $($App.name) failed to evaluate ($($_.Exception.Message)); treating as applicable and attempting the install."
        return $true
    }
}

<#
.SYNOPSIS
    Installs a single curated app with pre-check and post-install verification, without prompting.
.DESCRIPTION
    Shared per-app install pipeline used by both the first pass and the retry pass of
    Invoke-WingetInstall (issue #188). It replaces the three drifted inline Start-Process
    `winget list` verify blocks with a single implementation:

      1. Applicability: if the app does not apply to this machine, it is Skipped with SkipReason
         'NotApplicable' BEFORE any winget probe runs - e.g. Dell Command Update on non-Dell
         hardware (issue #217). Invoke-WingetInstall evaluates each app's condition once per run
         and passes the verdict in -Applicable, so both passes use the same answer (review
         finding P3-34); without -Applicable the condition is evaluated here, by
         Test-AppApplicability, which fails open: a condition that throws or writes an error is
         warned about and the app is treated as applicable, so a broken probe never silently
         drops an app.
      2. Pre-check: Test-WingetPackageInstalled under a timeout guard. Already installed maps to
         Skipped; a hung `winget list` maps to Failed so the app flows into the retry pass and
         the non-zero exit code instead of being silently dropped (issue #176). A winget that
         could not be started maps to Failed too (PreCheckLaunchFailed), without an install
         attempt: "could not check" is not "not installed" (review finding P2-9). So does a
         `winget list` that ran but failed (PreCheckFailed, with its exit code).
      3. Dispatch: a package-specific self-verifying installer named in $App.install (e.g.
         Install-PowerShellLatest, whose DISM-provisioned MSIX path never shows up under
         `winget list` for the elevating account), or the default Install-WingetPackage, which
         retries the transient 0x80073d19 session error with backoff (issue #150). When winget
         could not be launched for the install, the app is Failed (InstallLaunchFailed) without a
         post-verify.
      4. Post-verify: winget installs are re-checked with Test-WingetPackageInstalled; an install
         that reported success but does not show up under `winget list` is Failed, and a check
         that could not start winget says so (VerifyLaunchFailed) instead of 'package not found
         after install', and so does a check that ran but failed (VerifyFailed).

    The three launch-failure reasons are what Invoke-WingetInstall's circuit breaker
    (Invoke-WingetLaunchCircuitBreaker) watches for.

    With -MachineWide (a run as SYSTEM or under cross-user elevation; review findings P3-22, P3-24)
    the app is installed for the whole PC or not at all: a package with no machine-scope installer
    comes back Deferred, left for the signed-in user's own account, instead of being installed at
    winget's default scope for the account running this. An app that names its MSIX package
    (msixName, e.g. Windows Terminal) is also checked, before and after the install, by whether that
    package is provisioned for every user on this PC (Test-AppxPackageProvisionedForMachine) instead
    of with `winget list`, which only sees what is registered for the account running it: as SYSTEM,
    nothing, so Windows Terminal, built into Windows 11, failed on every run.

    The helper contains no prompts, no Exit, and no ReadKey — user-facing messages, summary
    bucketing, and exit-code policy stay in Invoke-WingetInstall — which is what makes the install
    pipeline unit-testable (issue #188).
.PARAMETER App
    A validated app-definition hashtable: @{ name = '<winget package id>' } with optional
    'install' (name of a self-verifying installer command), 'installerType' (winget
    --installer-type override forwarded to Install-WingetPackage), 'condition' (applicability
    scriptblock, issue #217), and 'conditionDescription' (human reason for the skip message)
    entries.
.PARAMETER Applicable
    The run's applicability verdict for this app (Test-AppApplicability), evaluated once per run by
    Invoke-WingetInstall before anything is installed (review finding P3-34). $false skips the app
    as NotApplicable; $true installs it whatever its condition would say now. Not given: the
    condition is evaluated here.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (winget --silent): Invoke-WingetInstall passes its effective
    non-interactive state. Not given: Install-WingetPackage decides. A package-specific installer
    ($App.install) gets it too when it has a -Silent parameter, as Install-PowerShellLatest does.
.PARAMETER WhatIf
    Dry run: the applicability gate and the read-only pre-check still run, but no installer
    is dispatched. An app that is not yet installed reports Status 'Installed' so the caller's
    dry-run summary shows what would change, matching the pre-#188 dry-run bucket semantics; a
    not-applicable app reports the same Skipped/'NotApplicable' result as a real run. A pre-check
    that could not start winget counts as not installed here: the dry run's own winget check has
    already said that winget is unavailable, and a real run would bootstrap it first.
.PARAMETER WingetNotLaunchable
    Invoke-WingetInstall's circuit breaker found that winget cannot be started on this machine.
    The applicability gate still applies, so a not-applicable app is still Skipped; an
    applicable app is Failed ('WingetNotLaunchable') without running winget at all.
.PARAMETER MachineWide
    The run installs for the whole PC only (see the description). Invoke-WingetInstall passes it for
    a run as SYSTEM or under cross-user elevation. Forwarded to Install-WingetPackage, and to a
    package-specific installer that has it, as -MachineScopeOnly.
.PARAMETER InstallInProgressWaitSeconds
    The most the install may wait for another installation to finish (review finding P2-15):
    Invoke-WingetInstall passes what is left of the run's budget. Forwarded to Install-WingetPackage,
    and to a package-specific installer that has a parameter of that name (Install-PowerShellLatest
    does). Not given: Install-WingetPackage's default. The time waited comes back in the
    InstallResult's InstallInProgressWaitedSeconds.
.RETURNS
    [hashtable] @{
        Status        = 'Installed' | 'Failed' | 'Skipped' | 'Deferred'
        InstallResult = the Install-WingetPackage result hashtable — or the $App.install command's
                        result — returned intact so exit codes can be surfaced without
                        restructuring (issue #189); $null when no installer ran (skip, dry run,
                        pre-check timeout or launch failure)
        FailureReason = $null when Status is not 'Failed'; otherwise 'PreCheckTimeout',
                        'PreCheckLaunchFailed', 'PreCheckFailed', 'InstallLaunchFailed',
                        'CustomInstallFailed', 'VerifyTimeout', 'VerifyLaunchFailed',
                        'VerifyFailed', 'VerifyNotFound', 'WingetNotLaunchable' or
                        'MachineCheckFailed' (with -MachineWide, the provisioned packages could not
                        be read), so the caller can keep its per-situation message texts
        LaunchError   = for the three *LaunchFailed reasons, why winget could not be started;
                        otherwise $null
        CheckExitCode = for PreCheckFailed and VerifyFailed, the exit code of the `winget list`
                        that failed; otherwise $null
        SkipReason    = 'NotApplicable' when Status is 'Skipped' because the app's condition
                        evaluated falsy (issue #217); 'Provisioned' when, with -MachineWide, its
                        MSIX package is already provisioned for every user; absent/$null for an
                        already-installed skip, so the caller can tell the skip messages apart
        DeferReason   = 'NoMachineScopeInstaller' when Status is 'Deferred': with -MachineWide,
                        the package has no installer for the whole PC (review finding P3-22)
    }
#>
function Install-AppWithVerification {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [bool]$Applicable,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$WingetNotLaunchable,

        [Parameter(Mandatory = $false)]
        [switch]$MachineWide,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds
    )

    # Applicability gate (issue #217): checked BEFORE any winget probe so a not-applicable app
    # (e.g. Dell Command Update on non-Dell hardware) costs nothing and cannot fail. Both the
    # first pass and the retry pass call this helper, so the gate holds everywhere -- including
    # dry runs. The verdict comes from the caller when it has one: Invoke-WingetInstall evaluates
    # every condition once per run, before Set-WindowsTerminalDefaults changes HKCU, so the retry
    # pass cannot re-decide an app the first pass attempted (review finding P3-34).
    if ($PSBoundParameters.ContainsKey('Applicable')) {
        $isApplicable = $Applicable
    }
    else {
        $isApplicable = Test-AppApplicability -App $App
    }
    if (-not $isApplicable) {
        return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' }
    }

    # An MSIX app in a run for the whole PC (review finding P3-24): whether its package is
    # provisioned for every user answers "is it installed", where `winget list` would only see the
    # account running this. Read without winget, so it is answered even when winget cannot start.
    $checkProvisioning = $MachineWide -and -not [string]::IsNullOrWhiteSpace([string]$App.msixName)
    if ($checkProvisioning) {
        $provisioned = Test-AppxPackageProvisionedForMachine -Name $App.msixName
        if ($provisioned -eq $true) {
            return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'Provisioned' }
        }
        if ($null -eq $provisioned -and -not $WhatIf) {
            # No answer is not "not installed" (as for `winget list`, P2-9): fail into the retry pass.
            return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'MachineCheckFailed' }
        }
    }

    if ($WingetNotLaunchable) {
        # The run already found that winget cannot be started (Invoke-WingetInstall's circuit
        # breaker): another launch attempt per app is what made a wedged winget cost 24 minutes.
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'WingetNotLaunchable'; LaunchError = $null }
    }

    # Same 15-second guard the inlined blocks used: `winget list` can hang indefinitely on broken
    # sources or first-use prompts, and a hung check must not stall the whole install loop.
    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck

    $preCheck = @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    if (-not $checkProvisioning) {
        $preCheck = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    }
    if ($preCheck.TimedOut) {
        # Failed, not skipped: the app then flows through the retry pass, appears in the summary,
        # and drives the non-zero exit code (issue #176).
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' }
    }
    if ($preCheck.LaunchFailed -and -not $WhatIf) {
        # No answer is not "not installed" (P2-9): installing would run winget again, which just
        # failed to start, and its verify would then report an installed app as not found.
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckLaunchFailed'; LaunchError = $preCheck.LaunchError }
    }
    if ($preCheck.CheckFailed) {
        # winget ran but `winget list` failed (P2-9): no answer either. Like a timed-out check,
        # the app fails into the retry pass instead of being installed blind.
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckFailed'; CheckExitCode = $preCheck.ExitCode }
    }
    if ($preCheck.Installed) {
        return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
    }

    if ($WhatIf) {
        # Not installed and this is a dry run: report it as the install that would happen.
        return @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null }
    }

    Write-Info "Installing: $($App.name)"

    if ($App.install) {
        # Package-specific installer that performs its own verification (e.g. PowerShell, whose
        # DISM-provisioned MSIX path never shows up under `winget list` for the elevating
        # account). Trust its Installed result instead of re-checking with winget.
        #
        # This is indirect dispatch on a catalog-carried function-name string, which
        # build/Build-WingetInstallScript.ps1's AST-based undefined-reference guards cannot see
        # through a generic CommandAst walk (issue #236) - Get-UndefinedCatalogInstallReference
        # exists specifically to validate this 'install' field against the module's defined
        # functions. If AppCatalog.ps1 ever gains another string-carried function-name field
        # (e.g. 'uninstall' or 'verify') dispatched the same way, extend that guard to cover it too.
        #
        # -Silent goes to the custom installer when it takes one (Install-PowerShellLatest does), so
        # an explicit -NonInteractive installs PowerShell's MSI with /quiet like every other app. So
        # does the run's remaining wait budget for another installation (review finding P2-15).
        # A run for the whole PC passes -MachineScopeOnly the same way (review finding P3-22).
        $customParameters = @{}
        $forwardedValues = @{}
        foreach ($parameterName in @('Silent', 'InstallInProgressWaitSeconds')) {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $forwardedValues[$parameterName] = $PSBoundParameters[$parameterName]
            }
        }
        if ($MachineWide) {
            $forwardedValues['MachineScopeOnly'] = $true
        }
        if ($forwardedValues.Count -gt 0 -and $App.install -is [string]) {
            $customCommand = Get-Command -Name $App.install -ErrorAction SilentlyContinue | Select-Object -First 1
            foreach ($parameterName in $forwardedValues.Keys) {
                if ($customCommand -and $customCommand.Parameters -and $customCommand.Parameters.ContainsKey($parameterName)) {
                    $customParameters[$parameterName] = $forwardedValues[$parameterName]
                }
            }
        }
        $customResult = & $App.install @customParameters
        if ($customResult.Installed) {
            return @{ Status = 'Installed'; InstallResult = $customResult; FailureReason = $null }
        }
        if ($customResult.NoMachineScopeInstaller) {
            return @{ Status = 'Deferred'; InstallResult = $customResult; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
        }
        # Install-PowerShellLatest says why its own check failed (review finding P3-8), so a
        # launch failure or a timeout reads the same as for every other app.
        $customReason = 'CustomInstallFailed'
        $customLaunchError = $null
        $customCheckExitCode = $null
        if ($customResult.LaunchErrorExhausted) {
            $customReason = 'InstallLaunchFailed'
            $customLaunchError = $customResult.LaunchError
        }
        elseif ($customResult.VerifyLaunchFailed) {
            $customReason = 'VerifyLaunchFailed'
            $customLaunchError = $customResult.VerifyLaunchError
        }
        elseif ($customResult.VerifyTimedOut) {
            $customReason = 'VerifyTimeout'
        }
        elseif ($customResult.VerifyCheckFailed) {
            $customReason = 'VerifyFailed'
            $customCheckExitCode = $customResult.VerifyExitCode
        }
        return @{ Status = 'Failed'; InstallResult = $customResult; FailureReason = $customReason; LaunchError = $customLaunchError; CheckExitCode = $customCheckExitCode }
    }

    # Install through the helper so the transient 0x80073d19 session error is retried with
    # backoff (issue #150) instead of failing on the first hit.
    $installParameters = @{ PackageId = $App.name; InstallerType = $App.installerType }
    if ($PSBoundParameters.ContainsKey('Silent')) {
        $installParameters['Silent'] = $Silent
    }
    if ($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds')) {
        $installParameters['InstallInProgressWaitSeconds'] = $InstallInProgressWaitSeconds
    }
    if ($MachineWide) {
        $installParameters['MachineScopeOnly'] = $true
    }
    $installResult = Install-WingetPackage @installParameters
    if ($installResult.LaunchErrorExhausted) {
        # winget never started, so nothing was installed; a verify would only fail to launch too.
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'InstallLaunchFailed'; LaunchError = $installResult.LaunchError }
    }
    if ($installResult.NoMachineScopeInstaller) {
        # Nothing was installed: the package has no installer for the whole PC (review finding P3-22).
        return @{ Status = 'Deferred'; InstallResult = $installResult; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
    }

    if ($checkProvisioning) {
        $provisioned = Test-AppxPackageProvisionedForMachine -Name $App.msixName
        if ($provisioned -eq $true) {
            return @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null }
        }
        if ($null -eq $provisioned) {
            return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'MachineCheckFailed' }
        }
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
    }

    $verify = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    if ($verify.TimedOut) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyTimeout' }
    }
    if ($verify.LaunchFailed) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyLaunchFailed'; LaunchError = $verify.LaunchError }
    }
    if ($verify.CheckFailed) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyFailed'; CheckExitCode = $verify.ExitCode }
    }
    if ($verify.Installed) {
        return @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null }
    }
    return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
}

<#
.SYNOPSIS
    Invoke-WingetInstall's run-level circuit breaker: after an app could not launch winget, checks
    once whether winget can still be started.
.DESCRIPTION
    Review findings P2-8 and P2-10. With winget unable to start, every app used to spend its own
    launch retries (5 launches and 75 seconds of backoff for the install, plus the pre-check and
    verify), and the retry pass then did it all again: about 24 minutes on an already provisioned
    machine before the run reported failure, and every app named as 'package not found after
    install'. A detector for one specific AppX state (two DesktopAppInstaller versions in the
    current user's view) was meant to stop that and never fired on the real wedge.

    This is the generic replacement. When an outcome says winget could not be launched
    (PreCheckLaunchFailed, InstallLaunchFailed or VerifyLaunchFailed), one Test-WingetLaunchable
    check decides: winget starts again, so the run carries on with the next app (and the failed
    app gets its retry-pass attempt), or it still cannot be started, so the breaker trips. The
    caller then fails every remaining app at once with one reason and skips the retry pass.

    A failure that can clear on its own (winget.exe locked, a timeout, a non-zero exit) gets up to
    six tries 15 seconds apart: the same 75 seconds Install-WingetPackage's launch retries cover,
    because the most common cause is an App Installer update in progress (issues #253/#258), which
    outlasts a short check. The pre-check and the post-install check do not retry a failed launch
    themselves, so this wait is all the tolerance a lock that starts at one of them gets. winget
    missing or 'Access is denied' trips the breaker after one try: waiting does not change it.
.PARAMETER Outcome
    The app's Install-AppWithVerification result.
.RETURNS
    [bool] True when the breaker tripped: winget cannot be started on this machine.
#>
function Invoke-WingetLaunchCircuitBreaker {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Outcome
    )

    if (@('PreCheckLaunchFailed', 'InstallLaunchFailed', 'VerifyLaunchFailed') -notcontains $Outcome.FailureReason) {
        return $false
    }

    Write-WarningMessage 'winget could not be launched for that app. Checking whether winget can still be started...'
    $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
    if ($probe.Launchable) {
        Write-Info "winget starts again ($($probe.Version)); carrying on with the next app."
        return $false
    }

    Write-ErrorMessage "winget cannot be launched on this machine ($($probe.Reason)). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
    return $true
}

# --- Interactivity ---
<#
.SYNOPSIS
    Determines whether the current run has a human at the console.
.DESCRIPTION
    Single source of truth for the effective non-interactive detection (issues #176, #214). Since
    issue #230 this gates no prompt — there are none left — only the things that still depend on a
    human being present: whether Invoke-WingetInstall opens the summary grid view and holds the
    window with "press any key to exit", whether Write-InstallerExitNotice holds it the same way
    before an early exit (review finding P2-14), whether the entry script forces an exit code
    after an abort, and whether a run that is not elevated may show a UAC prompt at all
    (Invoke-WingetInstall and Restart-WithElevation return 4 instead; review finding P2-12).

    Note what it deliberately does NOT catch: an interactive `irm <url> | iex` reports INTERACTIVE
    here, because the pipe is a PowerShell-internal pipeline and leaves the process's stdin alone.
    That is correct — there really is a human there — but it is why prompts could never be the
    mechanism that kept the documented one-liner unattended (issue #230).

    A run is effectively non-interactive when ANY of the following holds:
      - the caller passed the explicit -NonInteractive switch;
      - the process runs as SYSTEM (Test-IsSystemAccount; review finding P3-23): an RMM agent or a
        scheduled task, never a person at a console, whatever its session reports. Nobody would
        answer a key press, so none is waited for;
      - the session is non-interactive ([Environment]::UserInteractive is false — services,
        scheduled tasks, pwsh -NonInteractive);
      - stdin is redirected (piped input, irm | iex wrappers, CI runners). A console probe
        failure means there is no usable console, so that counts as non-interactive too.
.PARAMETER NonInteractive
    The caller's explicit -NonInteractive switch, forwarded as -NonInteractive:$switch.
.RETURNS
    [bool] True when there is no human to interact with; otherwise false.
#>
function Test-EffectiveNonInteractive {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $true
    }
    if (Test-IsSystemAccount) {
        return $true
    }
    if (-not [Environment]::UserInteractive) {
        return $true
    }
    try {
        return [System.Console]::IsInputRedirected
    }
    catch {
        # No usable console to probe: treat as non-interactive rather than risk a blocked prompt.
        return $true
    }
}

<#
.SYNOPSIS
    Determines whether the run is under a CI system.
.DESCRIPTION
    Used by Write-InstallerExitNotice so a failed early exit never waits for a key press on a CI
    runner, even where the runner's console looks interactive. Checks the variables CI systems set:
    CI (GitHub Actions, GitLab, Azure Pipelines' agents and most others), GITHUB_ACTIONS and TF_BUILD
    (Azure Pipelines). A CI value of 'false' or '0' does not count. Runs under Windows PowerShell 5.1
    too.
.RETURNS
    [bool] True under CI.
#>
function Test-IsContinuousIntegration {
    if ($env:CI -and $env:CI -ne 'false' -and $env:CI -ne '0') {
        return $true
    }
    if ($env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD -eq 'True') {
        return $true
    }
    return $false
}

# --- Jsonc ---
<#
.SYNOPSIS
    Converts JSONC (JSON with comments) text to strict JSON.
.DESCRIPTION
    Character-scanner sanitizer for Windows Terminal settings files, which commonly carry
    // line comments (including trailing inline ones), /* */ block comments (possibly
    spanning lines), and trailing commas. The previous regex approach (issue #187) missed
    trailing inline comments and could corrupt string values containing comment-like
    sequences such as "/*" or "//". Set-WindowsTerminalDefaultProfile parses settings.json
    with it to read defaultProfile and to validate its own edit of the file.

    The scanner tracks JSON string state (honoring backslash escapes like \" and \\), so
    comment markers and commas inside string values are never touched. Outside strings it:
      - drops // comments up to (not including) the end-of-line, and
      - drops /* */ comments, spanning lines, replaced with a single space so adjacent
        tokens cannot fuse, and
      - drops a trailing comma whose next non-whitespace character is '}' or ']'
        (whitespace between comma and closer is preserved).

    Comment stripping and trailing-comma removal run as two passes so a comma separated
    from its closing brace only by a comment ("1, /* c */ }") is still removed.
.PARAMETER JsonText
    JSONC text to sanitize.
.RETURNS
    [string] Strict-JSON text suitable for ConvertFrom-Json on Windows PowerShell 5.1.
#>
function Convert-JsoncToJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    # Pass 1: strip // and /* */ comments, string-aware.
    $length = $JsonText.Length
    $withoutComments = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ($inString) {
            [void]$withoutComments.Append($currentChar)
            if ($currentChar -eq '\') {
                # Copy the escaped character verbatim so \" does not end the string.
                if ($i + 1 -lt $length) {
                    [void]$withoutComments.Append($JsonText[$i + 1])
                    $i += 2
                    continue
                }
            }
            elseif ($currentChar -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($currentChar -eq '"') {
            $inString = $true
            [void]$withoutComments.Append($currentChar)
            $i++
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length) {
            $nextChar = $JsonText[$i + 1]
            if ($nextChar -eq '/') {
                # Line comment: skip to end of line, keeping the line break itself.
                $i += 2
                while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                    $i++
                }
                continue
            }
            if ($nextChar -eq '*') {
                # Block comment: skip past the closing */ (an unterminated comment
                # swallows the rest of the text, matching JSONC tokenizer behavior).
                $i += 2
                while ($i + 1 -lt $length -and -not ($JsonText[$i] -eq '*' -and $JsonText[$i + 1] -eq '/')) {
                    $i++
                }
                $i = [System.Math]::Min($i + 2, $length)
                [void]$withoutComments.Append(' ')
                continue
            }
        }

        [void]$withoutComments.Append($currentChar)
        $i++
    }

    # Pass 2: drop trailing commas (a ',' whose next non-whitespace char is '}' or ']'),
    # string-aware for values like "a, ]" that must survive untouched.
    $commentFreeText = $withoutComments.ToString()
    $length = $commentFreeText.Length
    $sanitized = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $commentFreeText[$i]

        if ($inString) {
            [void]$sanitized.Append($currentChar)
            if ($currentChar -eq '\') {
                if ($i + 1 -lt $length) {
                    [void]$sanitized.Append($commentFreeText[$i + 1])
                    $i += 2
                    continue
                }
            }
            elseif ($currentChar -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($currentChar -eq '"') {
            $inString = $true
            [void]$sanitized.Append($currentChar)
            $i++
            continue
        }

        if ($currentChar -eq ',') {
            $lookahead = $i + 1
            while ($lookahead -lt $length -and [char]::IsWhiteSpace($commentFreeText[$lookahead])) {
                $lookahead++
            }
            if ($lookahead -lt $length -and ($commentFreeText[$lookahead] -eq '}' -or $commentFreeText[$lookahead] -eq ']')) {
                # Trailing comma: drop it; the whitespace and closer are appended normally.
                $i++
                continue
            }
        }

        [void]$sanitized.Append($currentChar)
        $i++
    }

    return $sanitized.ToString()
}

<#
.SYNOPSIS
    Attempts to parse Windows Terminal settings content, including JSONC variants.
.DESCRIPTION
    Tries ConvertFrom-Json first (PowerShell 7+ tolerates JSONC natively). If parsing
    fails — Windows PowerShell 5.1 rejects comments and trailing commas — sanitizes the
    text with the string-aware Convert-JsoncToJson scanner and retries. The previous
    regex sanitizer missed trailing inline // comments and could corrupt string values
    containing comment-like sequences (issue #187).

    Private (issue #191): only the module's Windows Terminal configuration functions call
    this; no standalone script consumes it.
.PARAMETER JsonText
    Raw settings content.
.RETURNS
    Parsed settings object when successful; otherwise $null.
#>
function ConvertFrom-TerminalSettingsJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return [pscustomobject]@{}
    }

    try {
        # ConvertFrom-Json -Depth is unavailable in Windows PowerShell 5.1.
        return $JsonText | ConvertFrom-Json
    }
    catch {
        # Windows Terminal settings are often JSONC; strip comments and trailing commas.
        $sanitizedJson = Convert-JsoncToJson -JsonText $JsonText

        try {
            # Keep parsing compatible with both Windows PowerShell and PowerShell 7+.
            return $sanitizedJson | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
}

<#
.SYNOPSIS
    Splits JSONC text into its JSON tokens, skipping whitespace and comments.
.DESCRIPTION
    Each token records its kind ('{', '}', '[', ']', ':', ',', 'String' or 'Literal' for
    true/false/null/numbers), where it starts, where it ends (exclusive) and its nesting depth:
    the root object's braces are at depth 0 and its own keys and values at depth 1. String
    tokens include their quotes and honor backslash escapes, so comment markers inside strings
    are never mistaken for comments. Comments follow the same rules as Convert-JsoncToJson
    (an unterminated /* runs to the end of the text). The tokens are positions in the original
    text, which lets Set-JsoncTopLevelStringProperty edit one value and leave every other byte
    alone. No validation is done: invalid JSON still yields tokens.
.PARAMETER JsonText
    JSONC text to scan.
.RETURNS
    [pscustomobject[]] Tokens with Kind, Start, End and Depth, in text order.
#>
function Get-JsoncToken {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    $tokens = New-Object System.Collections.Generic.List[object]
    $length = $JsonText.Length
    $depth = 0
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ([char]::IsWhiteSpace($currentChar)) {
            $i++
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length -and $JsonText[$i + 1] -eq '/') {
            $i += 2
            while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                $i++
            }
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length -and $JsonText[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $length -and -not ($JsonText[$i] -eq '*' -and $JsonText[$i + 1] -eq '/')) {
                $i++
            }
            $i = [System.Math]::Min($i + 2, $length)
            continue
        }

        $start = $i
        $tokenDepth = $depth
        if ($currentChar -eq '"') {
            $kind = 'String'
            $i++
            while ($i -lt $length -and $JsonText[$i] -ne '"') {
                if ($JsonText[$i] -eq '\') {
                    $i++
                }
                $i++
            }
            $i = [System.Math]::Min($i + 1, $length)
        }
        elseif ('{['.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $depth++
            $i++
        }
        elseif ('}]'.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $depth--
            $tokenDepth = $depth
            $i++
        }
        elseif (':,'.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $i++
        }
        else {
            $kind = 'Literal'
            while ($i -lt $length -and -not [char]::IsWhiteSpace($JsonText[$i]) -and '{}[]:,"/'.IndexOf($JsonText[$i]) -lt 0) {
                $i++
            }
            if ($i -eq $start) {
                # A lone '/' that does not start a comment: take it as a one-character token.
                $i++
            }
        }

        $tokens.Add([pscustomobject]@{ Kind = $kind; Start = $start; End = $i; Depth = $tokenDepth })
    }

    return , $tokens.ToArray()
}

<#
.SYNOPSIS
    Sets one top-level string property in JSONC text by editing only that value.
.DESCRIPTION
    Windows Terminal's settings.json is hand-maintained JSONC: header comments, admin notes and
    commented-out profiles kept for later. Parsing it and writing it back with ConvertTo-Json
    deleted all of that, reindented the file and moved keys around. This edits the text in place
    instead:
      - When the root object already has the property, only its value is replaced (every
        top-level occurrence, so a duplicated key cannot keep an old value).
      - Otherwise "Name": "Value", is inserted before the root object's first key, on a line of
        its own with that key's indentation (inline when the first key shares its line with
        something else), or inside the braces of an empty root object.
      - Text with no tokens at all (empty, whitespace or comments only) gets a new root object
        holding just the property, appended after what is there.
    Every other character - comments, whitespace, line endings, key order, trailing commas -
    stays as it was. Keys are matched case-sensitively, as Windows Terminal reads them, and only
    at the top level: a key inside a profile or inside a comment is never touched.

    This function locates tokens; it does not check that the text is valid JSON(C). The caller
    validates the result by parsing it (Set-WindowsTerminalDefaultProfile).
.PARAMETER JsonText
    JSONC text whose root is an object.
.PARAMETER Name
    Top-level property name, matched case-sensitively.
.PARAMETER Value
    New string value. Backslashes and double quotes are escaped.
.RETURNS
    [string] The edited text, or $null when the root is not an object or the property's current
    value is an object or an array (nothing is edited then).
#>
function Set-JsoncTopLevelStringProperty {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $quotedValue = '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
    $member = '"' + $Name + '": ' + $quotedValue
    $newLine = if ($JsonText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $tokens = Get-JsoncToken -JsonText $JsonText

    if ($tokens.Count -eq 0) {
        $separator = if ($JsonText.Length -gt 0 -and $JsonText[$JsonText.Length - 1] -ne "`n") { $newLine } else { '' }
        return $JsonText + $separator + '{' + $newLine + '    ' + $member + $newLine + '}' + $newLine
    }

    if ($tokens[0].Kind -ne '{') {
        return $null
    }

    $firstKey = $null
    $valueTokens = @()
    for ($t = 1; $t -lt $tokens.Count; $t++) {
        $token = $tokens[$t]
        if ($token.Depth -eq 0) {
            # The root object's closing brace.
            break
        }
        $isTopLevelKey = $token.Depth -eq 1 -and $token.Kind -eq 'String' -and
            $t + 1 -lt $tokens.Count -and $tokens[$t + 1].Kind -eq ':'
        if (-not $isTopLevelKey) {
            continue
        }
        if ($null -eq $firstKey) {
            $firstKey = $token
        }
        if ($JsonText.Substring($token.Start + 1, $token.End - $token.Start - 2) -cne $Name) {
            continue
        }
        if ($t + 2 -ge $tokens.Count -or ($tokens[$t + 2].Kind -ne 'String' -and $tokens[$t + 2].Kind -ne 'Literal')) {
            return $null
        }
        $valueTokens += $tokens[$t + 2]
    }

    if ($valueTokens.Count -gt 0) {
        $builder = [System.Text.StringBuilder]::new($JsonText)
        # Back to front, so the earlier positions stay valid.
        for ($v = $valueTokens.Count - 1; $v -ge 0; $v--) {
            [void]$builder.Remove($valueTokens[$v].Start, $valueTokens[$v].End - $valueTokens[$v].Start)
            [void]$builder.Insert($valueTokens[$v].Start, $quotedValue)
        }
        return $builder.ToString()
    }

    if ($null -eq $firstKey) {
        return $JsonText.Insert($tokens[0].End, ' ' + $member + ' ')
    }

    # [char] overload: the string overload of LastIndexOf is culture-sensitive, and on .NET's ICU
    # globalization it does not find "`n" right after "`r".
    $lineStart = $JsonText.LastIndexOf([char]10, $firstKey.Start - 1) + 1
    $indent = $JsonText.Substring($lineStart, $firstKey.Start - $lineStart)
    $insertion = if ([string]::IsNullOrWhiteSpace($indent)) {
        $member + ',' + $newLine + $indent
    }
    else {
        $member + ', '
    }
    return $JsonText.Insert($firstKey.Start, $insertion)
}

# --- LoggingInternal ---
# Logging helpers used only by module functions and the generated entry script (issue #191). The
# externally consumed logging primitives (Write-Info/Success/WarningMessage/ErrorMessage,
# Format-AppList, Write-Table) live in Public/Logging.ps1 because winget-app-uninstall.ps1 imports
# them through the manifest.

<#
.SYNOPSIS
    Writes a prompt message in blue color.
.DESCRIPTION
    Helper function for consistent user prompt messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Prompt {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Starts the run's transcript under %ProgramData%\winget-app-setup\logs and returns its path.
.DESCRIPTION
    Persistent transcript (issue #189): a failed install on a remote user's machine used to leave
    zero artifacts. The log lands under ProgramData - not the elevating account's TEMP - so it
    survives cross-user elevation and stays findable afterwards. Logging must never block an
    install: any failure here downgrades to a warning and the run continues untranscribed.

    Called by the generated entry script for both phases of a run: the Windows PowerShell 5.1
    bootstrap (-Bootstrap, review finding P2-13), whose PowerShell 7 install used to leave no log
    at all, and the PowerShell 7 run itself. Runs under Windows PowerShell 5.1, so it must stay
    5.1-runtime compatible (see WingetAppSetup/Private/PowerShell7Bootstrap.ps1).

    Once the transcript is running, the log folder is made readable for standard users
    (Grant-InstallLogReadAccess, review finding P3-14), so the log can be opened from the end
    user's own session after a cross-user elevated run.
.PARAMETER WhatIf
    A dry run: the file name gets a -whatif suffix, so dry-run transcripts are never mistaken for
    real install logs.
.PARAMETER Bootstrap
    The Windows PowerShell 5.1 bootstrap phase: the file name gets a -bootstrap suffix. The
    PowerShell 7 run it relaunches writes its own transcript next to it.
.RETURNS
    [string] The transcript path, or $null when the transcript could not be started.
#>
function Start-InstallerTranscript {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$Bootstrap
    )

    $phaseSuffix = ''
    if ($Bootstrap) {
        $phaseSuffix = '-bootstrap'
    }
    $whatIfSuffix = ''
    if ($WhatIf) {
        $whatIfSuffix = '-whatif'
    }
    try {
        $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            [void](New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop)
        }
        $logPath = Join-Path $logDirectory ('install-{0:yyyyMMdd-HHmmss}{1}{2}.log' -f (Get-Date), $phaseSuffix, $whatIfSuffix)
        [void](Start-Transcript -Path $logPath -ErrorAction Stop)
    }
    catch {
        Write-WarningMessage "Transcript logging could not be started: $_. Continuing without a log file."
        return $null
    }

    # After Start-Transcript, so a failure to change the folder's ACL is in the log too; the grant
    # is inheritable, so the transcript file already created inside the folder picks it up.
    [void](Grant-InstallLogReadAccess -Path $logDirectory)
    return $logPath
}

<#
.SYNOPSIS
    Lets standard users read the installer's log folder (and the logs inside it).
.DESCRIPTION
    Review finding P3-14. Installing Winget-AutoUpdate restricts %ProgramData%\winget-app-setup to
    SYSTEM and Administrators (New-WauStagingDirectory, issue #186), and that inheritance-removing
    ACL reaches the logs folder beneath it. From then on the teammate who elevated as an admin on
    the end user's machine got Access Denied opening the log from the end user's own session, which
    is where they file the GitHub issue from.

    This adds an explicit, inheritable read-and-execute grant for BUILTIN\Users (well-known SID
    S-1-5-32-545, so it works on non-English Windows) on the logs folder only. Explicit entries are
    kept when the parent's inheritable entries change, so the grant survives that restriction, and
    every elevated run re-applies it, which also repairs machines restricted by an earlier run. The
    WAU staging directory's lockdown is untouched: it is a sibling folder with its own ACL, and the
    grant gives no write access. The parent stays unlistable for standard users, so they open the
    log by its full path, which the installer prints.

    Only an elevated process changes the ACL: a non-elevated first launch could not change an admin-
    created folder, and the elevated run it starts does it instead. Best-effort: a failure warns and
    the run continues. Runs under Windows PowerShell 5.1 too (the bootstrap transcript).
.PARAMETER Path
    The log folder.
.RETURNS
    [bool] True when the grant was applied.
#>
function Grant-InstallLogReadAccess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-IsAdmin)) {
        return $false
    }
    try {
        # -WindowStyle Hidden, not -NoNewWindow: icacls prints a 'processed file' line per folder,
        # which would otherwise land on the console of every run.
        $icaclsArgs = '"{0}" /grant *S-1-5-32-545:(OI)(CI)RX' -f $Path
        $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList $icaclsArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            return $true
        }
        Write-WarningMessage ("Could not make the log folder readable for standard users (icacls exit code {0}). Open the log from an elevated session." -f $proc.ExitCode)
    }
    catch {
        Write-WarningMessage "Could not make the log folder readable for standard users: $_. Open the log from an elevated session."
    }
    return $false
}

# --- MachineContext ---
# Machine-wide helpers for runs whose account is not the signed-in user (review findings P2-24,
# P3-22, P3-24). A run as SYSTEM, which is how an RMM agent such as ManageEngine Endpoint Central
# runs a script, has no winget of its own: winget is a packaged app registered per user, and
# Microsoft documents that packages "can be registered for any user except NT AUTHORITY\SYSTEM",
# so "the WinGet CLI is not supported in the system context"
# (learn.microsoft.com/windows/package-manager/winget/troubleshooting#system-context). There is no
# `winget` on SYSTEM's PATH, and `winget list` run as SYSTEM cannot see the MSIX apps registered for
# the users. These helpers find the winget.exe that App Installer installed for the machine, so a
# SYSTEM run can start it by its full path (as Winget-AutoUpdate's own SYSTEM runs do), and read
# whether an MSIX app is provisioned for every user. Microsoft's supported way to use winget as
# SYSTEM is the Microsoft.WinGet.Client module on PowerShell 7; moving to it is a follow-up.
# Written for Windows PowerShell 5.1 too (.NET Framework 4.5 APIs and 5.1 syntax only), like the
# other helpers Resolve-WingetExecutable leads to.

<#
.SYNOPSIS
    Lists the App Installer (Microsoft.DesktopAppInstaller) packages installed for any account.
.DESCRIPTION
    Thin query seam for Get-MachineWingetCandidate (mocked in tests). `Get-AppxPackage -AllUsers`
    needs administrator rights, which SYSTEM has, and lists a package staged on the machine even
    when no account has it registered. Under PowerShell 7 the query runs in Windows PowerShell 5.1,
    where the Appx module always loads, the same delegation Get-WindowsAppRuntimePackageInfo uses.
    Throws when the query fails.
.RETURNS
    [pscustomobject[]] with Version ([version]), Architecture ([string], e.g. 'X64'), Status
    ([string], e.g. 'Ok') and InstallLocation ([string]).
#>
function Get-DesktopAppInstallerPackageInfo {
    $query = "Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | ForEach-Object { '{0}|{1}|{2}|{3}' -f `$_.Version, `$_.Architecture, `$_.Status, `$_.InstallLocation }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
                ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Version, $_.Architecture, $_.Status, $_.InstallLocation })
    }

    foreach ($line in $lines) {
        $parts = "$line".Trim() -split '\|'
        $parsedVersion = $null
        if ($parts.Count -eq 4 -and [version]::TryParse($parts[0], [ref]$parsedVersion)) {
            [pscustomobject]@{
                Version         = $parsedVersion
                Architecture    = $parts[1]
                Status          = $parts[2]
                InstallLocation = $parts[3]
            }
        }
    }
}

<#
.SYNOPSIS
    Returns the folder MSIX packages are installed to for the machine, or $null.
.DESCRIPTION
    %ProgramFiles%\WindowsApps. ProgramW6432 comes first: in a 32-bit process ProgramFiles is
    'Program Files (x86)', which holds no WindowsApps folder.
.RETURNS
    [string] or $null.
#>
function Get-WindowsAppsDirectory {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        return $null
    }
    return (Join-Path $programFiles 'WindowsApps')
}

<#
.SYNOPSIS
    Finds the winget.exe files App Installer installed for the machine, best first.
.DESCRIPTION
    Two sources, the first that yields a winget.exe wins:
      1. Get-DesktopAppInstallerPackageInfo (`Get-AppxPackage -AllUsers`): packages whose Status
         is Ok, with winget.exe under their InstallLocation.
      2. When that query fails or finds none: the
         Microsoft.DesktopAppInstaller_<version>_<architecture>__8wekyb3d8bbwe folders under
         Get-WindowsAppsDirectory that hold a winget.exe. SYSTEM can list that folder; an
         administrator account normally cannot. A folder whose package the query listed with a
         Status other than Ok (Tampered, Modified, NeedsRemediation, ...) is left out here too, so
         the folder scan never brings back a package the query turned down.
    Candidates for this PC's architecture come first (x64 on an x64 PC; arm64, then x64, then x86
    on an ARM64 PC), and within an architecture the highest version first. Versions are compared as
    [version], never as text: as text, 1.9.25200.0 sorts after 1.27.460.0.
.PARAMETER ProcessorArchitecture
    The PC's architecture as Windows names it (AMD64, ARM64, x86). Default: PROCESSOR_ARCHITEW6432,
    which a 32-bit process on 64-bit Windows has, else PROCESSOR_ARCHITECTURE.
.RETURNS
    [pscustomobject[]] with Path, Version ([version]), Architecture ('x64', 'arm64', 'x86') and
    Source; empty when there is none.
#>
function Get-MachineWingetCandidate {
    param (
        [Parameter(Mandatory = $false)]
        [string]$ProcessorArchitecture
    )

    if ([string]::IsNullOrWhiteSpace($ProcessorArchitecture)) {
        $ProcessorArchitecture = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($ProcessorArchitecture)) {
            $ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
        }
    }
    $preference = @('x64', 'x86')
    if ("$ProcessorArchitecture" -eq 'ARM64') {
        $preference = @('arm64', 'x64', 'x86')
    }
    elseif ("$ProcessorArchitecture" -eq 'x86') {
        $preference = @('x86')
    }

    $found = @()
    # Version_architecture of every package the query listed with a status other than Ok.
    $rejected = @()
    try {
        foreach ($package in @(Get-DesktopAppInstallerPackageInfo)) {
            if ("$($package.Status)" -ne 'Ok') {
                $rejected += ('{0}_{1}' -f $package.Version, "$($package.Architecture)".ToLowerInvariant())
                continue
            }
            if ([string]::IsNullOrWhiteSpace($package.InstallLocation)) {
                continue
            }
            $path = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $found += [pscustomobject]@{ Path = $path; Version = $package.Version; Architecture = "$($package.Architecture)".ToLowerInvariant(); Source = 'Get-AppxPackage -AllUsers' }
            }
        }
    }
    catch {
        Write-WarningMessage "Could not list App Installer for all accounts ($_); looking for winget.exe under WindowsApps instead."
    }

    if ($found.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if ($windowsApps) {
            try {
                $folders = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction Stop)
                foreach ($folder in $folders) {
                    if ($folder.Name -notmatch '^Microsoft\.DesktopAppInstaller_(?<version>\d+(\.\d+){1,3})_(?<architecture>x64|arm64|x86)__8wekyb3d8bbwe$') {
                        continue
                    }
                    if ($rejected -contains ('{0}_{1}' -f ([version]$Matches['version']), $Matches['architecture'].ToLowerInvariant())) {
                        continue
                    }
                    $path = Join-Path $folder.FullName 'winget.exe'
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        $found += [pscustomobject]@{ Path = $path; Version = [version]$Matches['version']; Architecture = $Matches['architecture'].ToLowerInvariant(); Source = 'WindowsApps' }
                    }
                }
            }
            catch {
                Write-WarningMessage "Could not look for winget.exe under ${windowsApps}: $_"
            }
        }
    }

    $ranked = @(foreach ($candidate in $found) {
            $rank = [array]::IndexOf($preference, $candidate.Architecture)
            if ($rank -ge 0) {
                $candidate | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -PassThru
            }
        })
    return @($ranked | Sort-Object -Property @{ Expression = 'Rank'; Ascending = $true }, @{ Expression = 'Version'; Descending = $true } |
            Select-Object -Property Path, Version, Architecture, Source)
}

<#
.SYNOPSIS
    The SYSTEM form of Initialize-Winget's launch check: finds the machine-wide winget.exe and
    checks it starts.
.DESCRIPTION
    Review finding P2-24. As SYSTEM the per-account steps Initialize-Winget otherwise works through
    cannot help: SYSTEM has no `winget` alias, App Installer cannot be registered for it, and
    Repair-WinGetPackageManager does nothing for it (and throws with -AllUsers). They used to run
    anyway, with minutes of downloads, before the run stopped with exit code 2.

    Instead, each winget.exe from Get-MachineWingetCandidate is tried, best first, with
    Test-WingetLaunchable: the first is checked for up to 75 seconds (for a lock or an App Installer
    update that clears on its own), the others twice, and a winget.exe that cannot load a DLL it
    needs (0xC0000135) only once, since that does not clear on its own. The first that starts and
    prints a version is kept for the rest of the run ($script:MachineWingetPath, which
    Resolve-WingetExecutable returns to every winget call). When none starts, the run cannot install anything, and the message says
    why: no App Installer for the machine, or the winget.exe found could not be started.

    Read-only, so a dry run runs it too.
.PARAMETER WhatIf
    Dry run: a failure is reported as what a real run would do (stop with exit code 2).
.RETURNS
    [bool] True when a machine-wide winget.exe starts.
#>
function Test-MachineWingetAvailable {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $script:MachineWingetPath = $null
    $candidates = @(Get-MachineWingetCandidate)
    if ($candidates.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if (-not $windowsApps) {
            $windowsApps = '%ProgramFiles%\WindowsApps'
        }
        $message = "No machine-wide winget was found: as SYSTEM the installer runs the winget.exe of the App Installer package (Microsoft.DesktopAppInstaller) installed for this PC, and Get-AppxPackage -AllUsers lists none with status Ok, nor is there one under $windowsApps. SYSTEM cannot set winget up for itself, so the per-account steps (registering App Installer, Repair-WinGetPackageManager) do not apply. Install or update App Installer for this PC, then re-run the installer."
        if ($WhatIf) {
            Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
        }
        else {
            Write-ErrorMessage $message
        }
        return $false
    }

    $probe = $null
    $tried = 0
    foreach ($candidate in $candidates) {
        $script:MachineWingetPath = $candidate.Path
        if ($tried -eq 0) {
            $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
        }
        else {
            $probe = Test-WingetLaunchable -Attempts 2 -RetryDelaySeconds 5
        }
        $tried++
        if ($probe.Launchable) {
            Write-Success ('Winget is available ({0}): {1} (App Installer for this PC, {2}).' -f $probe.Version, $candidate.Path, $candidate.Version)
            return $true
        }
        Write-WarningMessage ('{0} could not be used: {1}.' -f $candidate.Path, $probe.Reason)
    }

    $script:MachineWingetPath = $null
    $hint = ''
    if ("$($probe.Reason)" -match '0xC0000135') {
        $hint = ' winget.exe could not load a DLL it needs: when it runs outside its package, as it does for SYSTEM, a missing Microsoft Visual C++ 2015-2022 runtime is a reported cause.'
    }
    $wingetWord = 'winget.exe'
    if ($tried -gt 1) {
        $wingetWord = "$tried winget.exe files"
    }
    $message = "winget could not be started as SYSTEM (tried the machine-wide $wingetWord above).$hint The per-account steps a signed-in user's run would try (registering App Installer, Repair-WinGetPackageManager) do not apply to SYSTEM and were skipped."
    if ($WhatIf) {
        Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
    }
    else {
        Write-ErrorMessage $message
    }
    return $false
}

<#
.SYNOPSIS
    Lists the display names of the app packages provisioned for every user on this PC.
.DESCRIPTION
    Thin query seam for Test-AppxPackageProvisionedForMachine (mocked in tests). A provisioned
    package is registered for each account at its next sign-in, so it is installed for the PC as a
    whole: Windows 11 provisions Windows Terminal this way. `Get-AppxProvisionedPackage -Online`
    needs administrator rights. Under PowerShell 7 it runs in Windows PowerShell 5.1, where the DISM
    module always loads (the same delegation Invoke-AppxProvisioning uses). Throws when the query
    fails.
.RETURNS
    [string[]]
#>
function Get-ProvisionedAppxPackageName {
    $query = 'Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName }'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxProvisionedPackage failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName })
    }
    foreach ($line in $lines) {
        $name = "$line".Trim()
        if ($name.Length -gt 0) {
            $name
        }
    }
}

<#
.SYNOPSIS
    Returns whether an app package is provisioned for every user on this PC: $true, $false, or $null
    when that could not be read.
.DESCRIPTION
    Review finding P3-24. A run as SYSTEM, or as an admin elevating on a user's PC, cannot decide
    whether an MSIX app such as Windows Terminal is installed with `winget list`: that only sees the
    packages registered for the account running it, which for SYSTEM is none. Windows Terminal,
    built into Windows 11, then read as missing on every run, and its install was then verified the
    same way and failed. Whether the package is provisioned for every user is the machine-wide
    answer.
.PARAMETER Name
    The package name (the provisioned package's DisplayName), e.g. 'Microsoft.WindowsTerminal'.
.RETURNS
    [bool] or $null.
#>
function Test-AppxPackageProvisionedForMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $names = @(Get-ProvisionedAppxPackageName)
    }
    catch {
        Write-WarningMessage "Could not read the apps provisioned for every user on this PC: $_"
        return $null
    }
    return [bool](@($names | Where-Object { $_ -eq $Name }).Count -gt 0)
}

# --- PackageIdValidation ---
<#
.SYNOPSIS
    Shared package-id shape validation, per CLAUDE.md's "Winget Notes" section.
.DESCRIPTION
    CLAUDE.md documents the exact regex a winget package id must satisfy before it is trusted (in
    catalog entries or in `winget list` output matching). This file is the single place that regex
    lives so Test-AppDefinitions (catalog load time) and Test-WingetPackageInstalled (runtime output
    matching) cannot drift apart on the pattern.
#>

# Exact pattern from CLAUDE.md ("Winget Notes"): publisher.product shape, each side starting with a
# word character and allowing word characters, dots, and hyphens after that. Anchored at both
# ends: it validates a WHOLE id, so trailing text such as 'Google.Chrome --override /S' must fail.
# Without an end anchor any valid prefix passed, and Start-Process -ArgumentList (which joins its
# array with spaces, unquoted) would hand the rest to winget as extra switches (review finding
# P3-49). The end anchor is \z, not $: in .NET $ also matches before a final newline, so
# "Google.Chrome`n" would pass. Matching an id inside longer winget output is
# Test-WingetListOutputContainsPackageId's job below, not this pattern's.
$script:WingetPackageIdPattern = '^[\w][\w.\-]+\.[\w][\w.\-]+\z'

<#
.SYNOPSIS
    Returns whether a string has the publisher.product shape CLAUDE.md mandates for package ids.
.PARAMETER PackageId
    The candidate package id string.
#>
function Test-WingetPackageIdFormat {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PackageId
    )

    return $PackageId -match $script:WingetPackageIdPattern
}

<#
.SYNOPSIS
    Returns whether `winget list` output contains the given package id as a whole id token, not
    merely as a substring of a different (longer) id.
.DESCRIPTION
    A plain .Contains($PackageId) check against raw `winget list` text is an unanchored substring
    match: an installed id like 'Foo.BarBaz' contains 'Foo.Bar' as a pure substring, which would
    false-positive a "Foo.Bar is installed" verdict. CLAUDE.md's "Winget Notes" section mandates
    validating package ids with a regex before trusting winget output; this tightens the match by
    requiring that neither side of the matched substring continue with an id-shape character
    ([\w.\-], the same character class the CLAUDE.md pattern is built from), so a match can only
    land on a complete id token.
.PARAMETER Output
    The raw `winget list` stdout text to search.
.PARAMETER PackageId
    The winget package id being checked for.
#>
function Test-WingetListOutputContainsPackageId {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Output,

        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $escapedId = [regex]::Escape($PackageId)
    $boundaryPattern = "(?<![\w.\-])$escapedId(?![\w.\-])"
    return [regex]::IsMatch($Output, $boundaryPattern)
}

# --- PowerShell7Bootstrap ---
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
# Resolve-WingetExecutable, which returns 'winget' unless a SYSTEM run has resolved the machine-wide
# winget.exe, and the 5.1-safe Private/MachineContext.ps1 helpers it can reach) for the winget
# install (review findings P2-5/P2-6, P2-24), and Test-IsSystemAccount (Private/Elevation.ps1: a
# try/catch around WindowsIdentity.GetCurrent()) when there is no winget command.
# Get-AuthenticodeSignature, which Test-PowerShell7MsiSignature calls, is a Windows PowerShell 5.1
# cmdlet too. The tail's 5.1 branch also calls, around this file:
# Test-EffectiveNonInteractive (with Test-IsSystemAccount, Private/Elevation.ps1: a try/catch around
# WindowsIdentity.GetCurrent(), review finding P3-23) and Test-IsContinuousIntegration
# (Private/Interactivity.ps1),
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
        elseif (Test-IsSystemAccount) {
            # SYSTEM, as under an RMM agent, has no `winget` command even where App Installer is
            # installed for the PC: winget is set up per user account (review of finding P2-24).
            # Saying winget is not on the machine contradicted the main run, which goes on to find
            # the machine-wide winget.exe. Using that winget.exe here too is a follow-up.
            Write-Info 'Running as SYSTEM, which has no winget command of its own (winget is set up for each user account), so PowerShell 7 is installed without winget.'
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

# --- ProcessInvocation ---
# One way to run winget and msiexec (review findings P2-5, P2-6 and P3-6). Every call site used to
# launch its process its own way: Start-Process -Wait with no time limit (the install itself),
# Start-Process with temp files and WaitForExit, or an inline native call. So the installs had no
# time limit, winget's own output never reached the transcript, and a failed launch was classified
# by English error text. Invoke-ExternalProcess does all three in one place, and
# Invoke-WingetProcess adds what is specific to winget. Both run under Windows PowerShell 5.1 too
# (the PowerShell 7 bootstrap installs pwsh with winget), so they use only .NET Framework 4.5 APIs:
# ProcessStartInfo.Arguments rather than ArgumentList, and taskkill rather than Kill($true).

<#
.SYNOPSIS
    Returns the time limit, in seconds, for one kind of external process call.
.DESCRIPTION
    The single place the time limits live. Each limit bounds one process (and every process it
    starts): when it runs out, the process tree is stopped and the call reports TimedOut. The
    limits are generous on purpose. They exist so that a hung installer, a winget waiting on its
    own cross-process install lock or a stalled download cannot stop an unattended run forever
    with no summary and no exit code (P2-5), not to cut a slow machine short.
.PARAMETER Operation
    WingetInstall     one `winget install`: the download, the installer itself, and winget's wait
                      for another winget install on the machine (30 minutes).
    WingetDownload    one `winget download` (30 minutes).
    WingetListCheck   the per-app `winget list` check before and after an install (15 seconds, the
                      limit those checks have always had).
    WingetVersion     the `winget --version` launch check (30 seconds; it does no network or
                      source I/O).
    WingetList        any other `winget list` (2 minutes).
    WingetSourceUpdate `winget source update`, the source check before the installs (2 minutes).
    WingetSourceReset `winget source reset`, which downloads the source again (5 minutes).
    MsiExec           one msiexec install or uninstall (15 minutes, as for the PowerShell 7 MSI).
    WebDownload       a small file download, such as the Winget-AutoUpdate MSI: the connection
                      and the wait for the response headers (5 minutes). Invoke-WebRequest's
                      -TimeoutSec does not cover the body.
    WebDownloadStall  how long a download may receive nothing once the file is arriving, on
                      PowerShell 7.4 and newer (2 minutes). 7.3 and older have no such limit.
.RETURNS
    [int] Seconds.
#>
function Get-ProcessTimeoutSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('WingetInstall', 'WingetDownload', 'WingetListCheck', 'WingetVersion', 'WingetList', 'WingetSourceUpdate', 'WingetSourceReset', 'MsiExec', 'WebDownload', 'WebDownloadStall')]
        [string]$Operation
    )

    switch ($Operation) {
        'WingetInstall' { return 1800 }
        'WingetDownload' { return 1800 }
        'WingetListCheck' { return 15 }
        'WingetVersion' { return 30 }
        'WingetList' { return 120 }
        'WingetSourceUpdate' { return 120 }
        'WingetSourceReset' { return 300 }
        'MsiExec' { return 900 }
        'WebDownload' { return 300 }
        'WebDownloadStall' { return 120 }
    }
}

<#
.SYNOPSIS
    Returns the time-limit parameters for an Invoke-WebRequest download, for splatting.
.DESCRIPTION
    Invoke-WebRequest has no time limit by default, so a download that connects and then stops
    receiving waits for ever (review finding P2-5). -TimeoutSec bounds the connection and the wait
    for the response headers only (PowerShell sends the request with ResponseHeadersRead and reads
    the body after HttpClient's timeout has ended). PowerShell 7.4 and newer add
    -OperationTimeoutSeconds, which bounds a stall while the body arrives; both are passed where
    they exist. On 7.3 and older a download that stops mid-file still waits for ever.
.RETURNS
    [hashtable] TimeoutSec, plus OperationTimeoutSeconds when Invoke-WebRequest has it.
#>
function Get-WebDownloadTimeoutParameters {
    $parameters = @{ TimeoutSec = (Get-ProcessTimeoutSeconds -Operation WebDownload) }
    $command = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ($command -and $command.Parameters -and $command.Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $parameters['OperationTimeoutSeconds'] = (Get-ProcessTimeoutSeconds -Operation WebDownloadStall)
    }
    return $parameters
}

<#
.SYNOPSIS
    Joins arguments into one command line, quoted the way Windows programs split it again.
.DESCRIPTION
    ProcessStartInfo.ArgumentList does not exist on .NET Framework (Windows PowerShell 5.1), so the
    arguments go into ProcessStartInfo.Arguments as one string. An argument that is empty or holds
    white space or a double quote is wrapped in double quotes, with backslashes before a quote
    doubled, which is how CommandLineToArgvW and the C runtime read a command line back (the rules
    .NET's own ArgumentList quoting follows). Other arguments pass through unchanged.
.PARAMETER ArgumentList
    The arguments, one per element.
.RETURNS
    [string] The command line, without the program name.
#>
function ConvertTo-ProcessArgumentString {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$ArgumentList
    )

    if ($null -eq $ArgumentList) {
        return ''
    }
    $parts = foreach ($argument in $ArgumentList) {
        $text = [string]$argument
        if ($text.Length -gt 0 -and $text -notmatch '[\s"]') {
            $text
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $text.ToCharArray()) {
            if ($character -eq [char]'\') {
                $backslashes++
                continue
            }
            if ($character -eq [char]'"') {
                [void]$builder.Append([char]'\', (2 * $backslashes) + 1)
            }
            elseif ($backslashes -gt 0) {
                [void]$builder.Append([char]'\', $backslashes)
            }
            [void]$builder.Append($character)
            $backslashes = 0
        }
        [void]$builder.Append([char]'\', 2 * $backslashes)
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return (@($parts) -join ' ')
}

<#
.SYNOPSIS
    Returns the Win32 error code behind a failed process launch, or $null.
.DESCRIPTION
    Process.Start throws a Win32Exception whose NativeErrorCode says why the launch failed, and
    PowerShell wraps it (MethodInvocationException). This walks the InnerException chain to it, so
    callers classify a launch failure by its code (P3-6), which is the same in every display
    language, instead of by its message, which Windows translates.
.PARAMETER Exception
    The caught exception.
.RETURNS
    [int] The NativeErrorCode, or $null when no Win32Exception is in the chain.
#>
function Get-NativeErrorCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception]) {
            return $current.NativeErrorCode
        }
        $current = $current.InnerException
    }
    return $null
}

<#
.SYNOPSIS
    Removes terminal control sequences and trailing white space from a line of process output.
.PARAMETER Line
    One line as the process wrote it.
.RETURNS
    [string]
#>
function ConvertTo-PlainProcessLine {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($null -eq $Line) {
        return ''
    }
    # CSI sequences (colors, cursor moves) and OSC sequences (window title, taskbar progress).
    $plain = $Line -replace '\x1b\[[0-?]*[ -/]*[@-~]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', ''
    return $plain.TrimEnd()
}

<#
.SYNOPSIS
    Classifies one line of winget output for echoing: real text, a progress update or noise.
.DESCRIPTION
    With its output redirected, winget still draws its spinner (- \ | /) and its download progress
    bar, one carriage-return-separated update at a time, and each update arrives as a line of its
    own. Echoing every one of them would bury the lines that matter. 'Spinner' and 'Blank' lines
    are dropped, and of a run of 'Progress' lines only the last is shown. A 'Status' line is the
    spinner with a message after it, which winget redraws every 250 ms for as long as it waits,
    for example '   - Waiting for another install/uninstall to complete...' while another install
    holds its lock; Select-ProcessOutputLine shows it once per run of the same message.
.PARAMETER Line
    A line already passed through ConvertTo-PlainProcessLine.
.RETURNS
    [string] 'Blank', 'Spinner', 'Status', 'Progress' or 'Text'.
#>
function Get-ProcessOutputLineKind {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return 'Blank'
    }
    if ($Line -match '^\s*[-\\|/]\s*$') {
        return 'Spinner'
    }
    if ($Line -match '^\s*[-\\|/]\s+\S') {
        return 'Status'
    }
    # Progress bar cells (full block, light, medium and dark shade), or a bare percentage or byte
    # count such as '45%', '1.50 MB / 3.00 MB' or, for a download of unknown size, '12.3 MB'.
    if ($Line -match '[\u2588\u2591\u2592\u2593]' -or $Line -match '^\s*\d+(\.\d+)?\s*%\s*$' -or $Line -match '^\s*[\d.]+\s*[KMGT]?B(\s*/\s*[\d.]+\s*[KMGT]?B)?\s*$') {
        return 'Progress'
    }
    return 'Text'
}

<#
.SYNOPSIS
    Decides which lines of process output to show, one line at a time.
.DESCRIPTION
    The filter Write-ProcessOutput and Invoke-ExternalProcess's live echo share, so both show the
    same lines (Get-ProcessOutputLineKind classifies them):
      - 'Blank' and 'Spinner' lines are dropped.
      - Of a run of 'Progress' updates only the last is shown, just before the next line that is
        shown, or at the end through -Flush.
      - A 'Status' line is shown once per run of the same message (the spinner character in front
        of it changes on every redraw, so only the message is compared). Without this, winget's
        wait for another install, the case a run queued behind Winget-AutoUpdate hits, wrote four
        lines a second for up to the 30-minute install limit.
      - 'Text' lines are always shown.
.PARAMETER State
    A hashtable the caller keeps for one run of output, empty to begin with.
.PARAMETER Line
    The next line, already passed through ConvertTo-PlainProcessLine.
.PARAMETER Flush
    End of the output: return the progress update still held back, if any.
.RETURNS
    [string[]] The lines to show now, in order. Often none.
#>
function Select-ProcessOutputLine {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line,

        [Parameter(Mandatory = $false)]
        [switch]$Flush
    )

    $show = New-Object System.Collections.Generic.List[string]
    $kind = 'Flush'
    if (-not $Flush) {
        $kind = Get-ProcessOutputLineKind -Line $Line
    }
    switch ($kind) {
        'Progress' {
            $State['PendingProgress'] = $Line
        }
        'Status' {
            $message = $Line -replace '^\s*[-\\|/]\s+', ''
            if ($message -cne $State['LastStatus']) {
                if ($null -ne $State['PendingProgress']) {
                    $show.Add($State['PendingProgress'])
                    $State['PendingProgress'] = $null
                }
                $show.Add($Line)
                $State['LastStatus'] = $message
            }
        }
        'Text' {
            if ($null -ne $State['PendingProgress']) {
                $show.Add($State['PendingProgress'])
                $State['PendingProgress'] = $null
            }
            $show.Add($Line)
            $State['LastStatus'] = $null
        }
        'Flush' {
            if ($null -ne $State['PendingProgress']) {
                $show.Add($State['PendingProgress'])
                $State['PendingProgress'] = $null
            }
        }
    }
    return $show.ToArray()
}

<#
.SYNOPSIS
    Writes process output to the console, and so into the transcript, without the progress noise.
.DESCRIPTION
    Start-Transcript records what PowerShell writes to the host, never what a child process writes
    straight to the console, which is why the transcript used to hold none of winget's own lines
    (P2-6). Lines go out through Write-Host, indented, filtered by Select-ProcessOutputLine: spinner
    and blank lines dropped, a run of progress updates collapsed to its last one, and a status
    message winget redraws shown once. Invoke-ExternalProcess applies the same filter as lines
    arrive; callers that capture quietly call this afterwards, for example only when a command
    failed.
.PARAMETER Line
    The lines to write.
.PARAMETER Tail
    Write only the last this-many lines that survive the filter. 0 writes all of them.
#>
function Write-ProcessOutput {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Line,

        [Parameter(Mandatory = $false)]
        [int]$Tail = 0
    )

    $shown = New-Object System.Collections.Generic.List[string]
    $filterState = @{}
    foreach ($rawLine in @($Line)) {
        $plain = ConvertTo-PlainProcessLine -Line $rawLine
        foreach ($shownLine in @(Select-ProcessOutputLine -State $filterState -Line $plain)) {
            $shown.Add($shownLine)
        }
    }
    foreach ($shownLine in @(Select-ProcessOutputLine -State $filterState -Flush)) {
        $shown.Add($shownLine)
    }

    $start = 0
    if ($Tail -gt 0 -and $shown.Count -gt $Tail) {
        $start = $shown.Count - $Tail
    }
    for ($index = $start; $index -lt $shown.Count; $index++) {
        Write-Host ('    ' + $shown[$index]) -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
    Stops a process and every process it started.
.DESCRIPTION
    A timed-out winget is usually waiting on the installer it started, so stopping winget alone
    would leave the installer running, holding the Windows Installer mutex and the output pipes.
    On Windows this runs `taskkill /PID <id> /T /F`, which stops the whole tree and works under
    Windows PowerShell 5.1. Elsewhere, or when taskkill fails, it uses Process.Kill(true) (.NET
    Core 3.0 and newer), then Process.Kill().
.PARAMETER Process
    The process to stop.
#>
function Stop-ProcessTree {
    param (
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            $taskkillPath = Join-Path ([System.Environment]::SystemDirectory) 'taskkill.exe'
            $killerInfo = New-Object System.Diagnostics.ProcessStartInfo
            $killerInfo.FileName = $taskkillPath
            $killerInfo.Arguments = '/PID {0} /T /F' -f $Process.Id
            $killerInfo.UseShellExecute = $false
            $killerInfo.CreateNoWindow = $true
            $killerInfo.RedirectStandardOutput = $true
            $killerInfo.RedirectStandardError = $true
            $killer = [System.Diagnostics.Process]::Start($killerInfo)
            $null = $killer.StandardOutput.ReadToEndAsync()
            $null = $killer.StandardError.ReadToEndAsync()
            if ($killer.WaitForExit(30000) -and $Process.WaitForExit(10000)) {
                return
            }
        }
        catch {
            # Fall through to Kill below.
        }
    }

    try {
        $Process.Kill($true)
    }
    catch {
        # Kill(bool) does not exist on .NET Framework; the process may also be gone already.
        try {
            $Process.Kill()
        }
        catch {
        }
    }
    try {
        [void]$Process.WaitForExit(10000)
    }
    catch {
    }
}

<#
.SYNOPSIS
    Runs a program with a time limit, captures its output and echoes it into the transcript.
.DESCRIPTION
    The process primitive behind every winget and msiexec call (P2-5, P2-6, P3-6):
      - A bare program name is resolved on PATH with Get-Command, as Start-Process did, so the
        current directory is never searched for it.
      - Standard output and standard error are redirected, read line by line as they arrive, and
        with -Echo Live written to the host through Write-Host (Write-ProcessOutput's filter), so
        they reach the transcript and the console both. Standard input is closed: nothing may wait
        for a key press.
      - When TimeoutSeconds runs out, the process and everything it started are stopped
        (Stop-ProcessTree) and the result says TimedOut; the caller says so in its own words.
        Output that keeps a pipe open after the process itself exited (a child it left running) is
        read for a few seconds more, then left.
      - A launch failure never throws: the result says LaunchFailed, with the Win32 error code
        (LaunchErrorCode: 2 not found, 5 access denied, 32 sharing violation, 1920 the file cannot
        be accessed by the system), so callers classify it by code rather than by translated text.
    The exit code comes from the process object, so it cannot go stale the way $LASTEXITCODE does.
.PARAMETER FilePath
    The program: a full path, or a name to find on PATH.
.PARAMETER ArgumentList
    The arguments, quoted for the command line by ConvertTo-ProcessArgumentString.
.PARAMETER ArgumentString
    The whole command line after the program name, passed exactly as given. Used instead of
    ArgumentList for msiexec, which reads PROPERTY="value" pairs its own way.
.PARAMETER TimeoutSeconds
    The time limit (see Get-ProcessTimeoutSeconds).
.PARAMETER Echo
    Live (default): print the command line, then each output line as it arrives. None: print
    nothing; the caller can pass the captured Output to Write-ProcessOutput later.
.RETURNS
    [pscustomobject] with FilePath, Arguments, ExitCode ($null when the process timed out or did
    not start), TimedOut, LaunchFailed, LaunchErrorCode, LaunchError (message), LaunchException,
    Output (standard output and standard error lines in arrival order, control sequences removed),
    StandardOutput, StandardError, DurationSeconds and LogPath ($null; Invoke-WingetProcess sets it).
#>
function Invoke-ExternalProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [string]$ArgumentString,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Live', 'None')]
        [string]$Echo = 'Live'
    )

    $arguments = $ArgumentString
    if (-not $PSBoundParameters.ContainsKey('ArgumentString')) {
        $arguments = ConvertTo-ProcessArgumentString -ArgumentList $ArgumentList
    }
    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $output = New-Object System.Collections.Generic.List[string]
    $standardOutput = New-Object System.Collections.Generic.List[string]
    $standardError = New-Object System.Collections.Generic.List[string]
    $result = [pscustomobject]@{
        FilePath        = $FilePath
        Arguments       = $arguments
        ExitCode        = $null
        TimedOut        = $false
        LaunchFailed    = $false
        LaunchErrorCode = $null
        LaunchError     = $null
        LaunchException = $null
        Output          = @()
        StandardOutput  = @()
        StandardError   = @()
        DurationSeconds = 0
        LogPath         = $null
    }

    # A bare name is looked up on PATH the way Start-Process did. Process.Start would hand it to
    # CreateProcess, which searches the current directory first.
    $resolvedPath = $FilePath
    if (-not [System.IO.Path]::IsPathRooted($FilePath) -and $FilePath -notmatch '[\\/]') {
        $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            $result.LaunchFailed = $true
            $result.LaunchErrorCode = 2
            $result.LaunchException = New-Object System.ComponentModel.Win32Exception(2, "'$FilePath' was not found on PATH.")
            $result.LaunchError = $result.LaunchException.Message
            return $result
        }
        $resolvedPath = $command.Source
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # winget writes UTF-8 whatever the console code page is; msiexec writes nothing.
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    if ($Echo -eq 'Live') {
        Write-Host ('  > {0} {1}' -f $displayName, $arguments).TrimEnd() -ForegroundColor DarkGray
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        $exception = $_.Exception
        $nativeErrorCode = Get-NativeErrorCode -Exception $exception
        $message = $exception.Message
        $inner = $exception
        while ($null -ne $inner) {
            if ($inner -is [System.ComponentModel.Win32Exception]) {
                $message = $inner.Message
                $exception = $inner
                break
            }
            $inner = $inner.InnerException
        }
        $result.LaunchFailed = $true
        $result.LaunchErrorCode = $nativeErrorCode
        $result.LaunchError = $message
        $result.LaunchException = $exception
        return $result
    }

    try {
        $process.StandardInput.Close()
    }
    catch {
    }

    $echoState = @{}
    $readers = @($process.StandardOutput, $process.StandardError)
    $targets = @($standardOutput, $standardError)
    $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $exitSeenAt = $null
    $timedOut = $false
    # Lines read from one stream before the exit and time-limit checks below run again. Without a
    # cap, a program that writes faster than this loop reads keeps every ReadLineAsync completed
    # at once, and the loop never reaches the time limit.
    $maximumLinesPerPass = 500

    while ($true) {
        for ($stream = 0; $stream -lt 2; $stream++) {
            $linesThisPass = 0
            while ($linesThisPass -lt $maximumLinesPerPass -and $null -ne $pending[$stream] -and $pending[$stream].IsCompleted) {
                $line = $null
                if (-not $pending[$stream].IsFaulted -and -not $pending[$stream].IsCanceled) {
                    $line = $pending[$stream].Result
                }
                if ($null -eq $line) {
                    $pending[$stream] = $null
                    break
                }
                $linesThisPass++
                $plain = ConvertTo-PlainProcessLine -Line $line
                $output.Add($plain)
                $targets[$stream].Add($plain)
                if ($Echo -eq 'Live') {
                    foreach ($shownLine in @(Select-ProcessOutputLine -State $echoState -Line $plain)) {
                        Write-Host ('    ' + $shownLine) -ForegroundColor DarkGray
                    }
                }
                $pending[$stream] = $readers[$stream].ReadLineAsync()
            }
        }

        if ($null -eq $pending[0] -and $null -eq $pending[1]) {
            break
        }
        if ($process.HasExited) {
            # Both pipes normally close with the process. A child it left running can hold them
            # open; give its last lines a moment, then stop reading.
            if ($null -eq $exitSeenAt) {
                $exitSeenAt = [DateTime]::UtcNow
            }
            elseif (([DateTime]::UtcNow - $exitSeenAt).TotalSeconds -ge 5) {
                break
            }
        }
        elseif ([DateTime]::UtcNow -ge $deadline) {
            $timedOut = $true
            break
        }

        $waitFor = @($pending | Where-Object { $null -ne $_ })
        [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$waitFor, 200)
    }

    if (-not $timedOut) {
        $remainingMilliseconds = [int][Math]::Max(0, [Math]::Min([int]::MaxValue, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        if (-not $process.WaitForExit($remainingMilliseconds)) {
            $timedOut = $true
        }
    }

    if ($timedOut) {
        Stop-ProcessTree -Process $process
        # Collect what the stopped processes had already written.
        for ($stream = 0; $stream -lt 2; $stream++) {
            try {
                if ($null -ne $pending[$stream] -and $pending[$stream].Wait(2000)) {
                    $line = $pending[$stream].Result
                    if ($null -ne $line) {
                        $plain = ConvertTo-PlainProcessLine -Line $line
                        $output.Add($plain)
                        $targets[$stream].Add($plain)
                    }
                }
            }
            catch {
                # The pipe broke when the process was stopped: nothing more to read.
            }
        }
    }

    if ($Echo -eq 'Live') {
        foreach ($shownLine in @(Select-ProcessOutputLine -State $echoState -Flush)) {
            Write-Host ('    ' + $shownLine) -ForegroundColor DarkGray
        }
    }

    $stopwatch.Stop()
    $result.DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    $result.Output = $output.ToArray()
    $result.StandardOutput = $standardOutput.ToArray()
    $result.StandardError = $standardError.ToArray()
    if ($timedOut) {
        $result.TimedOut = $true
    }
    else {
        $result.ExitCode = $process.ExitCode
    }
    try {
        $process.Dispose()
    }
    catch {
    }
    return $result
}

<#
.SYNOPSIS
    Returns the folder this run's logs go to, or $null.
.DESCRIPTION
    The folder of the run's transcript ($script:InstallLogPath, set by the generated installer's
    entry script before it calls anything else). $null when the transcript did not start, or
    outside the installer (the imported module, tests), and then no installer log is requested.
.RETURNS
    [string] or $null.
#>
function Get-InstallerLogDirectory {
    if ($script:InstallLogPath) {
        return (Split-Path -Parent $script:InstallLogPath)
    }
    return $null
}

<#
.SYNOPSIS
    Runs winget through Invoke-ExternalProcess, with its installer log in the run's logs folder.
.DESCRIPTION
    Resolves winget with Resolve-WingetExecutable unless the caller already has a path, then runs
    it through Invoke-ExternalProcess with the caller's time
    limit. For the subcommands that run an installer (install, upgrade, uninstall, repair), winget
    is also passed `--log <file>` in the run's logs folder (Get-InstallerLogDirectory), named after
    the subcommand, the package id and the time, so the MSI or Inno log of a failed install is next
    to the transcript instead of in the elevating account's winget state folder. The folder is
    created first: msiexec fails the whole install (1622) when it cannot open its log. Nothing is
    added when the caller already passes --log or -o, or when there is no logs folder.
.PARAMETER ArgumentList
    winget's arguments, subcommand first.
.PARAMETER TimeoutSeconds
    The time limit (see Get-ProcessTimeoutSeconds).
.PARAMETER WingetPath
    The winget executable to run. Default: Resolve-WingetExecutable.
.PARAMETER Echo
    Passed to Invoke-ExternalProcess. Default Live.
.PARAMETER LogDirectory
    Where to put the installer log. Default: Get-InstallerLogDirectory. Empty: no --log.
.RETURNS
    Invoke-ExternalProcess's result, with LogPath set to the installer log path when --log was
    passed (the file exists only if the installer wrote one).
#>
function Invoke-WingetProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [string]$WingetPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Live', 'None')]
        [string]$Echo = 'Live',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($WingetPath)) {
        $WingetPath = Resolve-WingetExecutable
    }

    $arguments = @($ArgumentList)
    $logPath = $null
    $subcommand = ''
    if ($arguments.Count -gt 0) {
        $subcommand = [string]$arguments[0]
    }
    if (@('install', 'upgrade', 'uninstall', 'repair') -contains $subcommand -and -not ($arguments -contains '--log' -or $arguments -contains '-o')) {
        $directory = $LogDirectory
        if (-not $PSBoundParameters.ContainsKey('LogDirectory')) {
            $directory = Get-InstallerLogDirectory
        }
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            $label = 'winget'
            $idIndex = [array]::IndexOf($arguments, '--id')
            if ($idIndex -ge 0 -and $idIndex + 1 -lt $arguments.Count) {
                $label = [string]$arguments[$idIndex + 1] -replace '[^\w.\-]', '_'
            }
            try {
                if (-not (Test-Path -LiteralPath $directory)) {
                    [void](New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop)
                }
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $candidate = Join-Path $directory ('winget-{0}-{1}-{2}.log' -f $subcommand, $label, $stamp)
                $suffix = 2
                while (Test-Path -LiteralPath $candidate) {
                    $candidate = Join-Path $directory ('winget-{0}-{1}-{2}-{3}.log' -f $subcommand, $label, $stamp, $suffix)
                    $suffix++
                }
                $logPath = $candidate
                $arguments += @('--log', $logPath)
            }
            catch {
                # No installer log is better than an install that fails over its log file.
                $logPath = $null
            }
        }
    }

    $result = Invoke-ExternalProcess -FilePath $WingetPath -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -Echo $Echo
    $result.LogPath = $logPath
    return $result
}

# --- SystemInfo ---
function Get-WindowsBuildNumber {
    <#
    .SYNOPSIS
        Returns the current Windows OS build number as an integer (e.g. 19045, 26100).
    .DESCRIPTION
        Wrapped in a function so callers (and tests) can reason about the build gate used to decide
        how to install the latest PowerShell: winget's machine-scope MSIX provisioning only works on
        build 26100 (Windows 11 24H2) and later (issue #166).
    #>
    return [int][System.Environment]::OSVersion.Version.Build
}

function Get-ComputerManufacturer {
    <#
    .SYNOPSIS
        Returns the machine's manufacturer string (e.g. 'Dell Inc.', 'Microsoft Corporation').
    .DESCRIPTION
        Thin, mockable wrapper around the Win32_ComputerSystem CIM class so catalog applicability
        conditions (issue #217) — e.g. gating Dell Command Update on Dell hardware — can be unit
        tested without touching real system state. Private on purpose: it is a seam for the
        catalog's condition scriptblocks, not part of the module's public surface.

        Throws when it has no answer (review finding P3-33): a CIM failure (access denied, RPC
        unavailable, a corrupt WMI repository) and an empty or missing Manufacturer. CIM reports
        those as non-terminating errors, so without -ErrorAction Stop this returned '' and the Dell
        condition read "not Dell": Dell Command Update was skipped as not applicable on a Dell PC
        and the run exited 0. A condition that throws fails open instead (Test-AppApplicability):
        the installer warns and attempts the install.
    .RETURNS
        [string] The manufacturer, never empty.
    #>
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = [string]($computerSystem | Select-Object -First 1).Manufacturer
    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        throw 'Win32_ComputerSystem reported no manufacturer.'
    }
    return $manufacturer.Trim()
}

function Get-OSArchitecture {
    <#
    .SYNOPSIS
        Returns the operating system's processor architecture: 'X64', 'Arm64', 'X86' or 'Arm'.
    .DESCRIPTION
        Mockable seam for catalog applicability conditions (review finding P3-32): for example,
        Adobe.Acrobat.Reader.64-bit ships only an x64 installer, which Adobe does not support on
        ARM64 Windows, so the catalog keeps it off ARM64 PCs.

        Answers for the OS, not for this process. RuntimeInformation.OSArchitecture asks Windows'
        IsWow64Process2 for the native machine (.NET 7 and later, so PowerShell 7.3 and later;
        the bootstrap installs 7.6), which reads Arm64 on an ARM64 PC even from an x64 PowerShell
        running under emulation, and X64 from a 32-bit PowerShell on x64 Windows. The environment
        variables do not: an x64 process under emulation on ARM64 sees PROCESSOR_ARCHITECTURE=AMD64
        and no PROCESSOR_ARCHITEW6432 (Microsoft Learn, "How emulation works on Arm": emulated
        apps are told about the emulated processor). Older .NET reads GetNativeSystemInfo instead,
        which is still right for a 32-bit process but says X64 for an x64 one under emulation.

        Throws when the architecture cannot be read, so a condition built on it fails open
        (Test-AppApplicability): the installer warns and attempts the install.
    .RETURNS
        [string] A System.Runtime.InteropServices.Architecture name, e.g. 'X64' or 'Arm64'.
    #>
    $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'The OS architecture could not be read.'
    }
    return $architecture
}

# --- WauSupport ---
<#
.SYNOPSIS
    Reads the installed Winget-AutoUpdate (WAU) version and MSI ProductCode from the registry.
.DESCRIPTION
    The MSI Uninstall entry (HKLM Uninstall key whose DisplayName matches Winget-AutoUpdate) is
    authoritative for both the installed DisplayVersion and the ProductCode (the key's name); the
    WOW6432Node hive is scanned too in case a WAU build registered 32-bit. WAU's own configuration
    key (HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate) serves as a version fallback when the uninstall
    entry is missing or unparsable. Callers use the version to decide whether the pinned MSI should
    upgrade an older install, and the ProductCode to uninstall whatever WAU version is actually
    present instead of only the pinned one (issue #186).
.RETURNS
    [pscustomobject] with:
      - Version:     [version] of the installed WAU, or $null when it cannot be determined.
      - ProductCode: '{GUID}' of the installed WAU MSI, or $null when no uninstall entry matches.
#>
function Get-InstalledWauInfo {
    $version = $null
    $productCode = $null

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if ($productCode) { break }
        if (-not (Test-Path $root)) { continue }
        foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $entry = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $entry -or $entry.DisplayName -notlike 'Winget-AutoUpdate*') { continue }
            if ($key.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$') {
                $productCode = $key.PSChildName
            }
            $parsedVersion = $null
            if ($entry.DisplayVersion -and [version]::TryParse(([string]$entry.DisplayVersion -replace '^[vV]', ''), [ref]$parsedVersion)) {
                $version = $parsedVersion
            }
            break
        }
    }

    if (-not $version) {
        $wauKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
        if (Test-Path $wauKey) {
            $entry = Get-ItemProperty -Path $wauKey -ErrorAction SilentlyContinue
            foreach ($candidate in @($entry.DisplayVersion, $entry.ProductVersion)) {
                $parsedVersion = $null
                if ($candidate -and [version]::TryParse(([string]$candidate -replace '^[vV]', ''), [ref]$parsedVersion)) {
                    $version = $parsedVersion
                    break
                }
            }
        }
    }

    return [pscustomobject]@{
        Version     = $version
        ProductCode = $productCode
    }
}

<#
.SYNOPSIS
    Reads a directory's owner and access entries as SIDs.
.DESCRIPTION
    Thin seam over Get-Acl (Windows-only, mocked in tests) for Assert-RestrictedDirectoryAcl.
    Every entry is read, explicit and inherited, by SID, so the result does not depend on the
    display language. Name is the account name when the SID resolves, for messages. Throws when
    the access list cannot be read.
.PARAMETER Path
    The directory to read.
.RETURNS
    [pscustomobject] with OwnerSid, OwnerName, InheritanceProtected ([bool], true when the
    directory inherits nothing from its parent) and AccessRules (Sid, Name, AccessControlType
    'Allow'/'Deny', IsInherited).
#>
function Get-DirectoryAccessSummary {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $nameOf = {
        param ($Identity)
        try {
            return [string]$Identity.Translate([System.Security.Principal.NTAccount]).Value
        }
        catch {
            return [string]$Identity.Value
        }
    }

    $owner = $acl.GetOwner($sidType)
    $rules = @(foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
            [pscustomobject]@{
                Sid               = [string]$rule.IdentityReference.Value
                Name              = (& $nameOf $rule.IdentityReference)
                AccessControlType = [string]$rule.AccessControlType
                IsInherited       = [bool]$rule.IsInherited
            }
        })

    $ownerSid = $null
    $ownerName = $null
    if ($owner) {
        $ownerSid = [string]$owner.Value
        $ownerName = & $nameOf $owner
    }
    return [pscustomobject]@{
        OwnerSid             = $ownerSid
        OwnerName            = $ownerName
        InheritanceProtected = [bool]$acl.AreAccessRulesProtected
        AccessRules          = $rules
    }
}

<#
.SYNOPSIS
    Throws unless a directory is owned by Administrators (or SYSTEM) and only SYSTEM and
    Administrators have access entries on it.
.DESCRIPTION
    Review finding P2-21. Checks what Set-RestrictedDirectoryAcl was meant to leave behind, from the
    directory's own access list, so a failed or partial change is caught before anything is
    downloaded into it. Fails on any of:
      - an owner other than Administrators (S-1-5-32-544) or SYSTEM (S-1-5-18): an object's owner
        can always change its access list, whatever the list says;
      - an access entry, allow or deny, explicit or inherited, for any other account;
      - inheritance from the parent folder still turned on.
.PARAMETER Path
    The directory to check.
#>
function Assert-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $security = Get-DirectoryAccessSummary -Path $Path
    $problems = @()
    if ($allowedSids -notcontains $security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid))"
    }
    if (-not $security.InheritanceProtected) {
        $problems += 'it still inherits permissions from its parent folder'
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($allowedSids -notcontains $rule.Sid) {
            $problems += "$($rule.Name) ($($rule.Sid)) has an access entry ($($rule.AccessControlType.ToLowerInvariant()))"
        }
    }
    if ($problems.Count -gt 0) {
        throw ("'{0}' is not limited to SYSTEM and Administrators: {1}." -f $Path, ($problems -join '; '))
    }
}

<#
.SYNOPSIS
    Locks a directory down to SYSTEM and Administrators (owner Administrators, full control,
    inheritance removed) and checks the result.
.DESCRIPTION
    Used to protect the WAU MSI staging directory so a same-user non-elevated process cannot swap
    the file between hash verification and msiexec (TOCTOU, issue #186). Grants use well-known SIDs
    (S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators) instead of account names so the ACL applies
    on non-English Windows.

    Ownership comes first (review finding P2-21): the installer's first, non-elevated launch
    creates %ProgramData%\winget-app-setup for its log, so the signed-in user owns it, and an owner
    can always rewrite the access list, whatever the list says. Removing the inherited entries
    alone left that user able to give themselves full control again and swap the staging folder.
    So icacls first makes Administrators the owner, then removes the inherited entries and replaces
    (/grant:r) any explicit ones for SYSTEM and Administrators, and Assert-RestrictedDirectoryAcl
    then reads the result back: any other owner or entry (an explicit entry another account added
    survives /grant:r) fails the call instead of being used.

    Changes only the directory itself (no /T and no /reset), so the explicit read grant that
    Grant-InstallLogReadAccess puts on the logs folder inside %ProgramData%\winget-app-setup stays
    in place: standard users can still open the logs. /q keeps icacls's per-folder success line
    off the console; its errors still show.

    Throws when icacls fails or the check does: callers must treat the directory as unsafe to use.
    Those two failures carry the error id 'RestrictedDirectoryAclFailed', so a caller can tell them
    from any other (icacls.exe not starting, say) and suggest resetting the folder's owner and
    access list only when that is what went wrong.
.PARAMETER Path
    The directory whose ACL should be replaced.
#>
function Set-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $failure = $null
    $steps = @(
        @{
            Arguments   = "`"$Path`" /setowner *S-1-5-32-544 /q"
            Description = 'make Administrators the owner of'
        },
        @{
            # /inheritance:r strips inherited ACEs; /grant:r replaces any explicit SYSTEM and
            # Administrators entries with these (OI)(CI)F grants, inherited by everything created
            # inside.
            Arguments   = "`"$Path`" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /q"
            Description = 'restrict'
        }
    )
    foreach ($step in $steps) {
        $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList $step.Arguments -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            $failure = "icacls failed to $($step.Description) '$Path' (exit code $($proc.ExitCode))."
            break
        }
    }
    if (-not $failure) {
        try {
            Assert-RestrictedDirectoryAcl -Path $Path
        }
        catch {
            $failure = "$_"
        }
    }
    if ($failure) {
        $exception = [System.InvalidOperationException]::new($failure)
        throw [System.Management.Automation.ErrorRecord]::new($exception, 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $Path)
    }
}

<#
.SYNOPSIS
    Opens a file for reading so that nobody can change, rename or delete it while it is open.
.DESCRIPTION
    Review finding P2-21. FileShare.Read lets other processes (msiexec) open the file for reading
    only: while the returned stream is open, Windows refuses to open the file for writing or
    deleting, so it cannot be overwritten, renamed or deleted, and the folder holding it cannot be
    renamed. Hashing from this stream and keeping it open until msiexec has finished means msiexec
    installs exactly the bytes that were hashed. The caller disposes the stream.
.PARAMETER Path
    The file to open.
.RETURNS
    [System.IO.FileStream]
#>
function Open-ReadLockedFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}

<#
.SYNOPSIS
    Creates a fresh, ACL-restricted staging directory for the WAU MSI download.
.DESCRIPTION
    %TEMP% is user-writable and the previous fixed path (%TEMP%\WAU-<version>.msi) was predictable,
    so a non-elevated process running as the same user could swap the MSI between Get-FileHash and
    msiexec (issue #186). The staging directory lives under %ProgramData%\winget-app-setup, is
    uniquely named per run, and is locked to SYSTEM + Administrators BEFORE anything is downloaded
    into it. The base directory is restricted first, and its owner changed to Administrators (the
    installer's non-elevated first launch creates it, owned by the signed-in user: review finding
    P2-21), so an unprivileged process cannot observe the per-run name or delete-and-recreate the
    staging directory through rights on the parent. Both are checked after the change
    (Set-RestrictedDirectoryAcl). Throws when the directory cannot be created or secured; only a
    failure to secure it carries the error id 'RestrictedDirectoryAclFailed'. Callers own cleanup
    (Remove-Item -Recurse).
.RETURNS
    [string] The full path of the created staging directory.
#>
function New-WauStagingDirectory {
    $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
    $null = New-Item -Path $baseDir -ItemType Directory -Force -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $baseDir

    $stagingDir = Join-Path $baseDir ('wau-msi-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $stagingDir
    return $stagingDir
}

<#
.SYNOPSIS
    Lists the Microsoft.WindowsAppRuntime.1.8 framework packages registered for any user.
.DESCRIPTION
    Thin query seam for Get-WindowsAppRuntimeStatus (mocked in tests). `Get-AppxPackage -AllUsers`
    needs elevation; under PowerShell 7 it runs in Windows PowerShell 5.1, where the Appx module
    always loads - the same delegation Invoke-AppxProvisioning uses. Throws when the query fails.
.RETURNS
    [pscustomobject[]] with Version ([version]) and Architecture ([string], e.g. 'X64', 'Arm64').
#>
function Get-WindowsAppRuntimePackageInfo {
    $query = "Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction Stop | ForEach-Object { '{0}|{1}' -f `$_.Version, `$_.Architecture }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction Stop |
                ForEach-Object { '{0}|{1}' -f $_.Version, $_.Architecture })
    }

    foreach ($line in $lines) {
        $parts = "$line".Trim() -split '\|'
        $parsedVersion = $null
        if ($parts.Count -eq 2 -and [version]::TryParse($parts[0], [ref]$parsedVersion)) {
            [pscustomobject]@{ Version = $parsedVersion; Architecture = $parts[1] }
        }
    }
}

<#
.SYNOPSIS
    Reports whether the WindowsAppRuntime framework that current winget releases need is present.
.DESCRIPTION
    Every winget release from 1.12 through 1.29 (checked against DesktopAppInstaller_Dependencies.json)
    depends on Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0. WAU installs the newest release,
    so re-check this requirement when winget moves to a newer framework (and when Get-WauPin is
    bumped); a newer framework family does NOT satisfy a dependency on 1.8.
    Winget-AutoUpdate's Install-Prerequisites runs on every WAU SYSTEM run and provisions the
    newest winget release from GitHub without that framework. On a machine that lacks it (no
    Microsoft Store updates, Server SKUs) the new App Installer cannot register and the old one is
    then rejected as a downgrade, which leaves winget unusable (the #279/#284 wedge). Callers use
    this to keep WAU off such machines.
.PARAMETER MinimumVersion
    The lowest framework version that satisfies current winget releases.
.RETURNS
    [pscustomobject] with:
      - Present: $true when a package for this OS architecture at or above MinimumVersion is
                 registered for any user; $false when none is; $null when the query failed.
      - Detail:  the versions found (or the query error), for messages.
#>
function Get-WindowsAppRuntimeStatus {
    param (
        [Parameter(Mandatory = $false)]
        [version]$MinimumVersion = [version]'8000.616.304.0'
    )

    try {
        $packages = @(Get-WindowsAppRuntimePackageInfo)
    }
    catch {
        return [pscustomobject]@{ Present = $null; Detail = "could not query installed packages: $_" }
    }

    $osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $suitable = @($packages | Where-Object { $_.Architecture -eq $osArchitecture -and $_.Version -ge $MinimumVersion })
    $found = if ($packages.Count -gt 0) {
        ($packages | ForEach-Object { "$($_.Architecture) $($_.Version)" }) -join ', '
    }
    else {
        'none registered'
    }

    return [pscustomobject]@{
        Present = ($suitable.Count -gt 0)
        Detail  = "Microsoft.WindowsAppRuntime.1.8 >= $MinimumVersion for $osArchitecture required; found: $found"
    }
}

<#
.SYNOPSIS
    Removes the at-logon trigger from an already-deployed Winget-AutoUpdate task.
.DESCRIPTION
    Earlier installer versions did not pass UPDATESATLOGON, so WAU 2.12.0 defaulted it to 1 and its
    SYSTEM task also runs at every user logon. That run re-provisions App Installer and resets
    winget's sources, and it fires exactly when a technician signs in to re-run this installer, so
    the two collide. New installs pass UPDATESATLOGON=0; this brings machines deployed before that
    in line. It also writes WAU_UpdatesAtLogon = 0, which WAU's MSI reads back on later upgrades.
    The weekly trigger is left alone, and a task whose only trigger is the logon one is not
    touched (removing it would stop WAU from ever running). Best-effort: failures only warn.
.RETURNS
    [bool] True when a logon trigger was removed.
#>
function Disable-WauLogonTrigger {
    $removed = $false
    try {
        $task = Get-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction SilentlyContinue
        if ($task) {
            $triggers = @($task.Triggers)
            $logonTriggers = @($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
            $otherTriggers = @($triggers | Where-Object { $_.CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' })
            if ($logonTriggers.Count -gt 0 -and $otherTriggers.Count -gt 0) {
                Set-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -Trigger $otherTriggers -ErrorAction Stop | Out-Null
                Write-Info 'Removed the at-logon trigger from the Winget-AutoUpdate task; it keeps its weekly schedule.'
                $removed = $true
            }
        }
        $wauKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
        if (Test-Path -LiteralPath $wauKey) {
            # An [int] value is written as REG_DWORD, the type WAU's MSI reads back.
            Set-ItemProperty -LiteralPath $wauKey -Name 'WAU_UpdatesAtLogon' -Value ([int]0) -ErrorAction Stop
        }
    }
    catch {
        Write-WarningMessage "Could not remove the Winget-AutoUpdate at-logon trigger: $_"
    }
    return $removed
}

<#
.SYNOPSIS
    Waits, with a time limit, for a running Winget-AutoUpdate task to finish.
.DESCRIPTION
    A WAU run (its weekly schedule catching up after boot, or a logon run on machines deployed
    before Disable-WauLogonTrigger) re-provisions App Installer, resets winget's sources and runs
    MSI upgrades. Starting this installer's own winget work in the middle of that produces launch
    failures and 'another installation is in progress' errors that read like broken apps. Polls
    the \WAU\ tasks and returns as soon as none is running.
.PARAMETER TimeoutSeconds
    Longest time to wait before continuing anyway. Default 900 (15 minutes).
.PARAMETER PollIntervalSeconds
    Seconds between checks. Default 30.
.RETURNS
    [bool] True when no WAU task is running (including when WAU is not installed); false when one
    was still running at the time limit.
#>
function Wait-WauIdle {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 900,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false
    while ($true) {
        $running = @()
        try {
            $running = @(Get-ScheduledTask -TaskPath '\WAU\' -ErrorAction SilentlyContinue | Where-Object { "$($_.State)" -eq 'Running' })
        }
        catch {
            # No task scheduler cmdlets (or no access): nothing to wait for.
            return $true
        }

        if ($running.Count -eq 0) {
            if ($announced) {
                Write-Success 'Winget-AutoUpdate has finished; continuing.'
            }
            return $true
        }

        $names = ($running | ForEach-Object { $_.TaskName }) -join ', '
        if (-not $announced) {
            Write-Info "Winget-AutoUpdate is running ($names); waiting up to $([math]::Ceiling($TimeoutSeconds / 60)) minutes so it does not collide with this run..."
            $announced = $true
        }
        if ((Get-Date) -ge $deadline) {
            Write-WarningMessage "Winget-AutoUpdate is still running ($names) after $([math]::Ceiling($TimeoutSeconds / 60)) minutes; continuing anyway. Installs may fail with 'another installation is in progress'; re-run the installer later if they do."
            return $false
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# --- WindowsInstallerState ---
# Machine state that decides whether an install can run now or needs a restart (review findings
# P2-15 and P3-16): whether Windows Installer is busy with another installation, and whether Windows
# has a restart pending. Read-only: nothing here changes the registry, and the Windows Installer
# mutex is only ever held for the instant it takes to test it (Test-WindowsInstallerBusy). Runs under
# Windows PowerShell 5.1 too: .NET Framework 4.5 APIs only.

<#
.SYNOPSIS
    Returns whether Windows Installer is busy with another installation right now.
.DESCRIPTION
    Windows Installer owns the Global\_MSIExecute mutex while an installation runs its execute
    sequence, and any other MSI install started meanwhile fails at once with 1618
    (ERROR_INSTALL_ALREADY_RUNNING), which winget reports as 0x8A150102. The busy signal is that
    the mutex is owned, not that it exists: the mutex object lives as long as any process holds a
    handle to it, released or not, so a check for existence alone could read busy for as long as
    that handle stays open and run every wait to its time limit.

    So the check opens the mutex (Mutex.TryOpenExisting; none of that name: idle) and tries to take
    it without waiting (WaitOne(0)), the same test PSAppDeployToolkit's Test-ADTMutexAvailability
    makes. Taken: nobody owned it, so Windows Installer is idle, and the mutex is released again at
    once, on the same thread. A mutex whose owner ended without releasing it (abandoned) is taken
    the same way and counts as idle. Not taken: an installation owns it, busy. For that instant an
    MSI starting its execute sequence on another process could get 1618 itself; the window is a few
    microseconds once per poll interval, the trade PSAppDeployToolkit makes before every MSI it
    runs. A mutex that this account may not open (TryOpenExisting asks for the rights to wait on
    and release it) counts as busy, without ever taking it; callers bound how long they wait and
    then try the install anyway. The handle is always closed, so this check never keeps the mutex
    alive.
.PARAMETER Name
    The mutex name. Default 'Global\_MSIExecute'; tests pass a name of their own.
.RETURNS
    [bool]
#>
function Test-WindowsInstallerBusy {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = 'Global\_MSIExecute'
    )

    $mutex = $null
    $taken = $false
    try {
        if (-not [System.Threading.Mutex]::TryOpenExisting($Name, [ref]$mutex)) {
            return $false
        }
        try {
            $taken = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # Its owner ended without releasing it; this thread owns it now.
            $taken = $true
        }
        return (-not $taken)
    }
    catch [System.UnauthorizedAccessException] {
        # The mutex exists, but this account may not open it.
        return $true
    }
    catch {
        # Cannot tell; the install attempt itself is the real test.
        return $false
    }
    finally {
        if ($taken) {
            # Released before anything else, on the thread that took it: a mutex this run kept
            # would make every MSI on the PC fail with 1618 until the run ended.
            try {
                $mutex.ReleaseMutex()
            }
            catch {
                # Only possible if this thread no longer owned it.
            }
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

<#
.SYNOPSIS
    Waits, within a time limit, until Windows Installer is no longer busy with another installation.
.DESCRIPTION
    Used after winget reported 0x8A150102 (another installation in progress, msiexec 1618) and
    before the Winget-AutoUpdate msiexec is retried after 1618. Sleeps one poll interval, then
    checks Test-WindowsInstallerBusy every poll interval until it reports idle or MaximumSeconds is
    reached, printing a progress line every minute so a long wait shows in the transcript. Always
    waits at least one poll interval (or MaximumSeconds, if shorter): 1618 means the installer was
    busy a moment ago, and a chained installation (a bundle installing several MSIs in turn) takes
    the mutex again right after releasing it.
.PARAMETER MaximumSeconds
    The longest this call may wait. 0 or less: return at once without waiting.
.PARAMETER PollSeconds
    Seconds between checks. Default 15.
.PARAMETER Name
    The mutex name, passed to Test-WindowsInstallerBusy.
.RETURNS
    [pscustomobject] @{ WaitedSeconds = <int>; Busy = <bool> }. Busy is the last check: True when
    the time limit ran out with Windows Installer still busy.
#>
function Wait-WindowsInstallerIdle {
    param (
        [Parameter(Mandatory = $true)]
        [int]$MaximumSeconds,

        [Parameter(Mandatory = $false)]
        [int]$PollSeconds = 15,

        [Parameter(Mandatory = $false)]
        [string]$Name = 'Global\_MSIExecute'
    )

    if ($PollSeconds -lt 1) {
        $PollSeconds = 1
    }
    $waited = 0
    $busy = $true
    $nextProgressAt = 60
    while ($waited -lt $MaximumSeconds) {
        $step = [Math]::Min($PollSeconds, $MaximumSeconds - $waited)
        Start-Sleep -Seconds $step
        $waited += $step
        $busy = Test-WindowsInstallerBusy -Name $Name
        if (-not $busy) {
            break
        }
        if ($waited -ge $nextProgressAt -and $waited -lt $MaximumSeconds) {
            Write-Info ('Windows Installer is still busy with another installation ({0} of at most {1} seconds waited)...' -f $waited, $MaximumSeconds)
            $nextProgressAt += 60
        }
    }
    return [pscustomobject]@{ WaitedSeconds = $waited; Busy = $busy }
}

<#
.SYNOPSIS
    Reads whether Windows has a restart pending, and why.
.DESCRIPTION
    Reads the indicators Configuration Manager's pending-restart prerequisite check and Microsoft's
    DSC RebootPending resource use:

      ComponentServicing  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based
                          Servicing\RebootPending exists (Windows servicing, features, updates).
      WindowsUpdate       HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto
                          Update\RebootRequired exists.
      FileRenames         HKLM\SYSTEM\CurrentControlSet\Control\Session Manager
                          PendingFileRenameOperations: the file replacements queued for the next
                          restart (MoveFileEx MOVEFILE_DELAY_UNTIL_REBOOT), which is how an MSI or
                          Inno installer finishes replacing a file that was in use.

    The value holds pairs of entries: a source, then a destination that is empty for a delete. Only
    replacements (a non-empty destination) are kept. Queued deletes are left out: many programs
    queue them to clean up temporary or rollback files (Edge Update, for example), and an install is
    complete without them, so they would report a restart that nothing needs.

    Best-effort and read-only: an indicator that cannot be read counts as absent.
.RETURNS
    [pscustomobject] @{ ComponentServicing = <bool>; WindowsUpdate = <bool>; FileRenames = <string[]>
    ('<source> -> <destination>' per queued replacement) }
#>
function Get-PendingRestartState {
    $componentServicing = $false
    try {
        $componentServicing = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    }
    catch {
        $componentServicing = $false
    }

    $windowsUpdate = $false
    try {
        $windowsUpdate = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
    catch {
        $windowsUpdate = $false
    }

    $fileRenames = @()
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        $entries = @($sessionManager.PendingFileRenameOperations)
        for ($index = 0; $index -lt $entries.Count; $index += 2) {
            $source = [string]$entries[$index]
            $destination = ''
            if ($index + 1 -lt $entries.Count) {
                $destination = [string]$entries[$index + 1]
            }
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destination)) {
                continue
            }
            $fileRenames += ('{0} -> {1}' -f $source.Trim(), $destination.Trim())
        }
    }
    catch {
        # No value (nothing queued) or unreadable.
        $fileRenames = @()
    }

    return [pscustomobject]@{
        ComponentServicing = $componentServicing
        WindowsUpdate      = $windowsUpdate
        FileRenames        = @($fileRenames)
    }
}

<#
.SYNOPSIS
    Lists why a restart is pending, or with -Since, the reasons that appeared since an earlier state.
.DESCRIPTION
    Turns a Get-PendingRestartState result into short reasons for the summary. With -Since (the state
    read at the start of the run), only what appeared during the run counts: an indicator that was
    already present, or a file replacement that was already queued, is left out, so a restart that
    was pending before the run is reported as such and does not make the run's own result 'restart
    required' (exit code 3010).
.PARAMETER State
    A Get-PendingRestartState result.
.PARAMETER Since
    An earlier Get-PendingRestartState result. Optional.
.RETURNS
    [string[]] Nothing when nothing is pending (or nothing new); call it inside @().
#>
function Get-PendingRestartReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Since
    )

    if ($null -eq $State) {
        return
    }

    $reasons = @()
    if ($State.ComponentServicing -and -not ($Since -and $Since.ComponentServicing)) {
        $reasons += 'Windows component servicing has a restart pending'
    }
    if ($State.WindowsUpdate -and -not ($Since -and $Since.WindowsUpdate)) {
        $reasons += 'Windows Update has a restart pending'
    }

    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Since) {
        foreach ($rename in @($Since.FileRenames)) {
            [void]$known.Add([string]$rename)
        }
    }
    $newRenames = @(@($State.FileRenames) | Where-Object { $_ -and -not $known.Contains([string]$_) })
    if ($newRenames.Count -gt 0) {
        $renameWord = if ($newRenames.Count -eq 1) { 'file replacement is' } else { 'file replacements are' }
        $reasons += ('{0} {1} queued for the next restart' -f $newRenames.Count, $renameWord)
    }
    return $reasons
}

# --- WindowsTerminalHostDetection ---
# Windows Terminal self-lock detection (issue #271). A scheduled/dispatched E2E run showed
# winget repeatedly fail to even LAUNCH while installing/verifying Microsoft.WindowsTerminal -
# "Access is denied" / "The file cannot be accessed by the system" - across 5 launch retries plus
# a full final retry pass, all failing identically, while every other catalog app installed fine
# in the same run. That failure shape (persistent, not transient; unique to this one package) does
# not match the DesktopAppInstaller re-registration race WingetLaunchResilience.ps1 already
# retries around (issue #258) - that lock clears once registration finishes, so retries recover.
# It matches a structural self-lock instead: when the CURRENT session's console is itself hosted
# by Windows Terminal (directly, via wt.exe, or delegated via the "default terminal application"
# registry setting), winget cannot safely replace the very console-host files rendering that
# session, and no amount of waiting fixes that - the lock only clears when the session ends. These
# helpers detect that condition so the caller can skip the doomed attempt instead of retrying it.

<#
.SYNOPSIS
    Returns whether the current process's console session is hosted by Windows Terminal.
.DESCRIPTION
    Checked via three independent signals, cheapest and most direct first. Any single positive
    match is sufficient:

      1. $env:WT_SESSION - set directly by Windows Terminal for anything running inside one of
         its panes/tabs. The standard, documented signal for "am I inside Windows Terminal".
      2. HKCU:\Console\%%Startup DelegationConsole/DelegationTerminal - the "default terminal
         application" values Set-WindowsTerminalAsDefaultTerminalApplication also writes. When
         these already point at Windows Terminal, a freshly created console with no inherited
         console (e.g. a new top-level pwsh.exe process - exactly what each step of a CI job
         spawns) is delegated to Windows Terminal's console host even though nothing launched
         wt.exe directly. The GUIDs here must stay in sync with
         Set-WindowsTerminalAsDefaultTerminalApplication. Counted only while Windows Terminal is
         installed (Test-WindowsTerminalInstalled, review finding P3-35): nothing clears these
         values when Windows Terminal is removed, and a delegation to a Windows Terminal that is
         not there cannot host anything (the console falls back to conhost), so on its own it
         made the catalog skip the Windows Terminal install as 'not applicable' on every run.
      3. Process ancestry - walks parent processes (bounded to 10 hops) looking for
         WindowsTerminal.exe or OpenConsole.exe, covering direct wt.exe hosting that neither of
         the above catches.

    Fail-open throughout: any probe that throws (missing registry key, Get-CimInstance
    unavailable, non-Windows Pester run, restricted session) is treated as "not hosted" rather
    than propagating, so a broken probe can never cause an unnecessary skip.
.RETURNS
    [bool]
#>
function Test-WindowsTerminalHostsCurrentSession {
    [CmdletBinding()]
    param ()

    if (-not [string]::IsNullOrEmpty($env:WT_SESSION)) {
        return $true
    }

    try {
        $registryPath = 'HKCU:\Console\%%Startup'
        $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
        $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction Stop
        if ($existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal -and
            (Test-WindowsTerminalInstalled)) {
            return $true
        }
    }
    catch {
        # No delegation key (default console host), or the registry provider is unavailable
        # (e.g. a non-Windows Pester run) - fall through to the ancestry check.
    }

    try {
        $currentProcessId = $PID
        for ($depth = 0; $depth -lt 10 -and $currentProcessId; $depth++) {
            $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $currentProcessId" -ErrorAction Stop
            if (-not $process) {
                break
            }
            if ($process.Name -in @('WindowsTerminal.exe', 'OpenConsole.exe')) {
                return $true
            }
            $currentProcessId = $process.ParentProcessId
        }
    }
    catch {
        # Best-effort only; a probe failure must never read as "hosted" (fail open).
    }

    return $false
}

<#
.SYNOPSIS
    Returns whether Windows Terminal (the stable Microsoft.WindowsTerminal package) is registered
    for the current user.
.DESCRIPTION
    Asks Get-AppxPackage for exactly 'Microsoft.WindowsTerminal', and its answer is final (review
    findings P3-34, P3-35): Windows Terminal Preview is a different package with different
    default-terminal GUIDs, and a settings.json left behind by a removed or unpackaged Windows
    Terminal is not an installed one. Only when Get-AppxPackage itself fails (PowerShell 7 on
    builds where the Appx module cannot load, 0x80131539) does the stable package's own
    settings.json stand in for it.

    Used to gate Set-WindowsTerminalDefaults so it never configures Windows Terminal as the
    default terminal application when Windows Terminal is not actually present (issue #271) -
    doing so unconditionally is what let a single failed install attempt poison every subsequent
    console session on the machine - and by Test-WindowsTerminalHostsCurrentSession, which counts
    those default-terminal values only while Windows Terminal is installed.
.RETURNS
    [bool]
#>
function Test-WindowsTerminalInstalled {
    [CmdletBinding()]
    param ()

    try {
        return [bool](Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction Stop)
    }
    catch {
        # Get-AppxPackage can fail under PowerShell 7 when the Appx module cannot load; the stable
        # package's settings.json (its LocalState folder goes when the package is removed) is the
        # next best sign.
    }

    return @(Get-WindowsTerminalSettingsPaths | Where-Object { $_ -match '\\Packages\\Microsoft\.WindowsTerminal_8wekyb3d8bbwe\\' }).Count -gt 0
}

# --- WingetAgreementArgs ---
<#
.SYNOPSIS
    Returns the shared agreement/interactivity flag set used by every winget install-family call.
.DESCRIPTION
    `--accept-source-agreements --accept-package-agreements --disable-interactivity` was hand-
    duplicated across three call sites (Install-WingetPackage, Install-MsixProvisionedPackage, and
    the PowerShell 7 bootstrap's winget install). That duplication is exactly how issue #230
    shipped: one of the three literal arrays was missing `--disable-interactivity`, and it went
    unnoticed until winget stopped on the one code path every install takes and asked a human that
    was never watching. Routing all three call sites through this single helper makes that class of
    bug structurally impossible - there is only one place left to forget the flag.

    This is deliberately scoped to the install/download flag combination, not a generic wrapper for
    every winget subcommand: none of the `winget source` subcommands except `source add` accepts
    `--accept-source-agreements` (`source update`, issues #174/#175; `source list` and
    `source reset` reject it the same way, with 0x8A150002), and `search` and `list` pass their own
    subset. Callers with those different needs keep building their own argument lists.
.RETURNS
    [string[]] @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
#>
function Get-WingetAgreementArgs {
    [CmdletBinding()]
    param ()

    return @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
}

# --- WingetBootstrap ---
# Helpers for Initialize-Winget (Public/WingetCore.ps1), the one ladder that makes winget usable
# for a run: probe, classify the failure, apply the fix for that class (review findings P3-25 to
# P3-31). Each fix runs at most once per run, and the classification comes from exit codes and
# HRESULTs, never from English text.

<#
.SYNOPSIS
    Returns the App Installer Group Policy value that turns off what this installer needs, or $null.
.DESCRIPTION
    Review finding P3-30. Under these policies the winget alias still runs, but every command it
    is given ends with 0x8A15003A BLOCKED_BY_POLICY (or, for the source, finds no winget source),
    and no repair can change that. The values live under
    HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller (Policy CSP DesktopAppInstaller,
    Computer Configuration > Administrative Templates > Windows Components > Desktop App
    Installer); 0 means Disabled:
      EnableAppInstaller                                'Enable App Installer'
      EnableWindowsPackageManagerCommandLineInterfaces  'Enable Windows Package Manager command line
                                                        interfaces' (Windows 11 24H2 and later)
      EnableDefaultSource                               'Enable App Installer Default Source': the
                                                        winget source every install uses.
    EnableAllowedSources is not checked: it governs only sources added beyond the defaults.
.RETURNS
    [pscustomobject] with Name (the value name) and Policy (its Group Policy name), or $null.
#>
function Get-WingetPolicyBlock {
    try {
        $values = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' -ErrorAction Stop
    }
    catch {
        # No such key: nothing is configured.
        return $null
    }

    $policies = [ordered]@{
        EnableAppInstaller                               = 'Enable App Installer'
        EnableWindowsPackageManagerCommandLineInterfaces = 'Enable Windows Package Manager command line interfaces'
        EnableDefaultSource                              = 'Enable App Installer Default Source'
    }
    foreach ($name in $policies.Keys) {
        $value = $values.$name
        if ($null -ne $value -and "$value" -eq '0') {
            return [pscustomobject]@{ Name = $name; Policy = $policies[$name] }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Returns the AppX deployment HRESULT (0x80073xxx) an Appx or WinGet cmdlet failed with, or $null.
.DESCRIPTION
    Review finding P3-27. Reads the HResult of the exception and of each inner exception first. When
    none is an AppX deployment code, the hex form in the message ('HRESULT: 0x80073CF3', which
    Windows prints the same in every display language) is used. The codes that matter here:
      0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED  a framework App Installer needs is missing
                                                          (issue #279: Microsoft.WindowsAppRuntime.1.8)
      0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE          a newer version of a package is already
                                                          installed (issue #265)
.PARAMETER ErrorRecord
    The ErrorRecord (or exception) the cmdlet failed with.
.RETURNS
    [int] or $null.
#>
function Get-AppxErrorCode {
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ErrorRecord
    )

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    }
    while ($exception -is [System.Exception]) {
        if (('0x{0:X8}' -f $exception.HResult).StartsWith('0x80073')) {
            return [int]$exception.HResult
        }
        $exception = $exception.InnerException
    }

    $match = [regex]::Match("$ErrorRecord", '0x80073[0-9A-F]{3}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [Convert]::ToInt32($match.Value.Substring(2), 16)
    }
    return $null
}

<#
.SYNOPSIS
    Makes Repair-WinGetPackageManager available, installing the Microsoft.WinGet.Client module when
    it is missing.
.DESCRIPTION
    Called only by the repair rung, so a run whose winget works never installs the module (review
    finding P3-26: every fresh PC used to install the NuGet provider and the module from the
    PowerShell Gallery for a repair that rarely runs, and warned about an update feature that no
    longer exists when the Gallery was blocked). The module is installed for all users from the
    PowerShell Gallery only (review finding P3-20): this runs elevated, so no other repository
    registered on the PC may serve it.
.RETURNS
    [bool] True when Repair-WinGetPackageManager can be called.
#>
function Test-AndInstallWingetModule {
    if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
        return $true
    }

    try {
        Write-Info 'Installing the Microsoft.WinGet.Client module for all users from the PowerShell Gallery, for Repair-WinGetPackageManager...'
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "The Microsoft.WinGet.Client module could not be installed, so Repair-WinGetPackageManager cannot run: $_"
        return $false
    }
    return [bool](Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Registers an app package for the current account with Add-AppxPackage, by family name or from
    its AppXManifest.xml; throws when the registration fails.
.DESCRIPTION
    Thin seam for Register-WingetAppInstallerForUser (mocked in tests). Under PowerShell 7 the
    registration runs in Windows PowerShell 5.1 (review finding P3-29). Add-AppxPackage comes from
    the Appx module, which cannot load under PowerShell 7 on Windows builds before 10.0.22453
    (Windows 10, Windows Server 2022): every Appx cmdlet then fails with 0x80131539 'Operation is not
    supported on this platform' (PowerShell issue #13138; Microsoft.WinGet.Client imports Appx with
    -UseWindowsPowerShell for the same reason). In Windows PowerShell it always loads. The same
    delegation Get-DesktopAppInstallerPackageInfo and Invoke-AppxProvisioning use; the child runs
    as the same account, so the package is registered for this account.

    The child prints the HRESULT of the error it caught, which is thrown here as a COMException
    carrying it, with the child's message, so Get-AppxErrorCode reads the code as it would from
    Add-AppxPackage itself (review finding P3-27).
.PARAMETER FamilyName
    Add-AppxPackage -RegisterByFamilyName -MainPackage <FamilyName>.
.PARAMETER ManifestPath
    Add-AppxPackage -Register <ManifestPath> -DisableDevelopmentMode.
#>
function Invoke-AppxRegistration {
    [CmdletBinding(DefaultParameterSetName = 'FamilyName')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'FamilyName')]
        [string]$FamilyName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
        [string]$ManifestPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'FamilyName') {
        $parameters = @{ RegisterByFamilyName = $true; MainPackage = $FamilyName }
        # Each value goes into a single-quoted literal of the child's -Command string, so embedded
        # single quotes are doubled (issue #178).
        $arguments = "-RegisterByFamilyName -MainPackage '{0}'" -f $FamilyName.Replace("'", "''")
    }
    else {
        $parameters = @{ Path = $ManifestPath; Register = $true; DisableDevelopmentMode = $true }
        $arguments = "-Path '{0}' -Register -DisableDevelopmentMode" -f $ManifestPath.Replace("'", "''")
    }

    if ($PSVersionTable.PSEdition -ne 'Core') {
        Add-AppxPackage @parameters -ErrorAction Stop
        return
    }

    $command = "`$ProgressPreference = 'SilentlyContinue'; try { Add-AppxPackage $arguments -ErrorAction Stop } catch { 'ERR|{0}|{1}' -f `$_.Exception.HResult, (`$_.Exception.Message -replace '\s+', ' '); exit 1 }"
    $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command)
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return
    }
    foreach ($line in $lines) {
        $parts = "$line" -split '\|', 3
        if ($parts.Count -eq 3 -and $parts[0] -eq 'ERR') {
            $hresult = 0
            if ([int]::TryParse($parts[1], [ref]$hresult) -and $hresult -ne 0) {
                throw [System.Runtime.InteropServices.COMException]::new($parts[2].Trim(), $hresult)
            }
            throw $parts[2].Trim()
        }
    }
    throw "Add-AppxPackage $arguments failed in Windows PowerShell (exit code $exitCode)."
}

<#
.SYNOPSIS
    Registers the App Installer (winget) package already on this PC for the current account.
.DESCRIPTION
    winget comes with the Microsoft.DesktopAppInstaller package, which is registered per account. An
    admin account elevating on a signed-in user's PC has none, although the PC has the package on
    disk. Registering it needs no download and deploys no framework, so it cannot hit the 0x80073D06
    rejection the repair cmdlet can (issue #265). Two forms are tried: -RegisterByFamilyName, then
    -Register against each package's AppXManifest.xml.

    Both the listing (Get-DesktopAppInstallerPackageInfo, `Get-AppxPackage -AllUsers`) and the
    registrations (Invoke-AppxRegistration, Add-AppxPackage) run in Windows PowerShell under
    PowerShell 7 (review finding P3-29). The Appx module they come from cannot load under PowerShell 7
    on Windows Server 2022 and older Windows 10 builds (0x80131539), so this step used to fail there
    at the listing and, had it got past it, at the registration; in E2E run 35406706712 it only
    worked once Repair-WinGetPackageManager had loaded Appx into the session.

    The AppX codes the registrations fail with (Get-AppxErrorCode) are returned, so the caller can
    tell a missing framework (0x80073CF3) or a downgrade rejection (0x80073D06) from other failures
    (review finding P3-27: these codes appear here, not in Repair-WinGetPackageManager's error).
.RETURNS
    [pscustomobject] Registered ([bool]: a registration call completed; winget is checked by the
    caller) and ErrorCodes ([int[]]).
#>
function Register-WingetAppInstallerForUser {
    $codes = @()
    try {
        $candidates = @(Get-DesktopAppInstallerPackageInfo)
    }
    catch {
        Write-WarningMessage "Could not list the App Installer packages on this PC: $_"
        return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
    }
    if ($candidates.Count -eq 0) {
        Write-Info 'App Installer is not on this PC, so there is nothing to register for this account.'
        return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
    }

    Write-Info 'Registering the App Installer package already on this PC for this account...'
    $registrations = @(@{ Label = 'by family name'; Parameters = @{ FamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } })
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.InstallLocation)) { continue }
        $manifest = Join-Path $candidate.InstallLocation 'AppXManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            $registrations += @{ Label = "from $manifest"; Parameters = @{ ManifestPath = $manifest } }
        }
    }
    foreach ($registration in $registrations) {
        $parameters = $registration.Parameters
        try {
            Invoke-AppxRegistration @parameters -ErrorAction Stop
            Write-Success "App Installer registered for this account ($($registration.Label))."
            return [pscustomobject]@{ Registered = $true; ErrorCodes = $codes }
        }
        catch {
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) { $codes += $code }
            Write-WarningMessage "Registering App Installer $($registration.Label) failed: $_"
        }
    }
    return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
}

<#
.SYNOPSIS
    Runs Repair-WinGetPackageManager: for all users first when the framework App Installer needs is
    missing, then for this account, unforced and then, unless the cause is known, forced.
.DESCRIPTION
    -AllUsers (review finding P3-28) installs App Installer for the whole PC with the frameworks it
    depends on, which is what the cmdlet itself asks for when Microsoft.WindowsAppRuntime.1.8 is
    missing ('Try running with -AllUsers in administrator mode'). It runs only then: on a PC whose
    framework is newer than the one the WinGet release pins, it aborts with 0x80073D06 (issue #265).

    -Force adds only ForceTargetApplicationShutdown (it closes running App Installer processes;
    Microsoft.WinGet.Client AppxModuleHelper.AddAppInstallerBundleAsync), and each attempt downloads
    App Installer again. So it is tried only after a failure nothing has named (review finding
    P3-27). It is skipped when a missing framework (0x80073CF3) or a downgrade rejection (0x80073D06)
    was seen, by this repair or by the App Installer registration before it (KnownErrorCodes: the
    #279 wedge shows them there, while the repair only says 'Failed to repair winget. Try running
    with -AllUsers in administrator mode.'), and when the framework is known to be missing and the
    all-users repair for it failed. The module is installed here, when it is first needed
    (Test-AndInstallWingetModule).
.PARAMETER AllUsersFirst
    Microsoft.WindowsAppRuntime.1.8 is missing for this PC (Get-WindowsAppRuntimeStatus).
.PARAMETER KnownErrorCodes
    The AppX codes this run has already seen, from the App Installer registration.
.RETURNS
    [pscustomobject] Available ([bool]: the cmdlet could be called), Succeeded ([bool]: an attempt
    completed; the caller checks winget itself) and ErrorCodes ([int[]], the AppX codes this repair
    saw).
#>
function Invoke-WingetPackageManagerRepair {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$AllUsersFirst,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [int[]]$KnownErrorCodes = @()
    )

    # 0x80073CF3 and 0x80073D06: retrying, forced or not, fails the same way.
    $finalCodes = @(-2147009293, -2147009274)
    $codes = @()
    if (-not (Test-AndInstallWingetModule)) {
        return [pscustomobject]@{ Available = $false; Succeeded = $false; ErrorCodes = $codes }
    }

    $attempts = @()
    if ($AllUsersFirst) {
        $attempts += @{ Label = '-AllUsers -Latest'; Parameters = @{ AllUsers = $true; Latest = $true } }
    }
    $attempts += @{ Label = '-Latest'; Parameters = @{ Latest = $true } }
    $attempts += @{ Label = '-Latest -Force'; Parameters = @{ Latest = $true; Force = $true } }
    foreach ($attempt in $attempts) {
        $parameters = $attempt.Parameters
        if ($parameters.Force) {
            $named = @(@($KnownErrorCodes) | Where-Object { $finalCodes -contains $_ } | Select-Object -Unique)
            $cause = $null
            if ($named.Count -gt 0) {
                $cause = 'registering App Installer failed with {0}' -f (@($named | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
            }
            elseif ($AllUsersFirst) {
                $cause = 'the Microsoft.WindowsAppRuntime.1.8 framework App Installer needs is missing, and the all-users repair for it failed'
            }
            if ($cause) {
                Write-Info "Not running Repair-WinGetPackageManager $($attempt.Label): $cause, which forcing cannot fix (-Force only closes running App Installer processes)."
                break
            }
        }
        Write-Info "Running Repair-WinGetPackageManager $($attempt.Label)..."
        try {
            Repair-WinGetPackageManager @parameters -ErrorAction Stop
            return [pscustomobject]@{ Available = $true; Succeeded = $true; ErrorCodes = $codes }
        }
        catch {
            Write-WarningMessage "Repair-WinGetPackageManager $($attempt.Label) failed: $_"
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) {
                $codes += $code
                if ($finalCodes -contains $code) {
                    break
                }
            }
        }
    }
    return [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = $codes }
}

<#
.SYNOPSIS
    Runs the next fix that sets winget up for this account, if one is left; each runs once a run.
.DESCRIPTION
    Cheapest first: register the App Installer already on this PC (Register-WingetAppInstallerForUser),
    then Repair-WinGetPackageManager (for all users first when the all-users check finds
    Microsoft.WindowsAppRuntime.1.8 missing). A registration that fails moves straight on to the
    repair, which is told the AppX codes the registration saw, so it does not force a retry those
    codes say cannot help (review finding P3-27). Initialize-Winget calls this in a loop, checking
    winget after each fix that ran.
.PARAMETER State
    The run's ladder state, which this updates: Registered, Repair, Framework and ErrorCodes.
.RETURNS
    [bool] True when a fix ran and winget should be checked again; False when none is left.
#>
function Invoke-NextWingetAccountFix {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    if (-not $State.ContainsKey('Registered')) {
        $register = Register-WingetAppInstallerForUser
        $State.Registered = [bool]$register.Registered
        $State.ErrorCodes += @($register.ErrorCodes)
        if ($State.Registered) {
            return $true
        }
    }
    if (-not $State.ContainsKey('Repair')) {
        $State.Framework = Get-WindowsAppRuntimeStatus
        $State.Repair = Invoke-WingetPackageManagerRepair -AllUsersFirst:($State.Framework.Present -eq $false) -KnownErrorCodes @($State.ErrorCodes)
        $State.ErrorCodes += @($State.Repair.ErrorCodes)
        return [bool]$State.Repair.Available
    }
    return $false
}

<#
.SYNOPSIS
    Returns the one line that says how to fix what the ladder could not, from what it saw.
.PARAMETER State
    The ladder state (Invoke-NextWingetAccountFix).
.PARAMETER Account
    Who the run installs as: the account name, or 'SYSTEM'.
.PARAMETER Source
    The winget source could not be set up. Without it, the advice is for a winget that cannot be
    started.
.PARAMETER SourceExitCode
    The source check's exit code, if it ran to the end.
.RETURNS
    [string]
#>
function Get-WingetSetupAdvice {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$Account,

        [Parameter(Mandatory = $false)]
        [switch]$Source,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$SourceExitCode
    )

    if ($Source) {
        if ($SourceExitCode -eq -2147009255 -and $Account -eq 'SYSTEM') {
            return 'The steps that set winget up for a signed-in account do not apply to SYSTEM; if the installs fail, run the installer once as an administrator signed in to this PC.'
        }
        if ($SourceExitCode -eq -2147009255) {
            return "Fix: sign in to Windows as '$Account' once (that sets winget up for the account), or run 'winget source update' in a session running as '$Account', then re-run the installer."
        }
        return 'Fix: check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer.'
    }
    if ($State.Framework -and $State.Framework.Present -eq $false) {
        return "Fix: install the Microsoft.WindowsAppRuntime.1.8 framework App Installer depends on, which this PC lacks ($($State.Framework.Detail)), or let the Microsoft Store update App Installer, then re-run the installer (issue #279)."
    }
    if (@($State.ErrorCodes) -contains -2147009274) {
        return 'Fix: a framework package on this PC is newer than the one the WinGet release deploys, so App Installer could not be repaired; update App Installer from the Microsoft Store on this PC, then re-run the installer.'
    }
    if ($State.Repair -and -not $State.Repair.Available) {
        return 'Fix: install App Installer from the Microsoft Store or https://aka.ms/getwinget (Repair-WinGetPackageManager could not run: its PowerShell module could not be installed), then re-run the installer.'
    }
    return 'Fix: install or update App Installer from the Microsoft Store or https://aka.ms/getwinget, then re-run the installer.'
}

<#
.SYNOPSIS
    Updates the winget source for the account running winget, which also registers it on first use.
.DESCRIPTION
    `winget source update --name winget --disable-interactivity`, the lightest command that makes
    winget register its source package for an account that has never used it (on a cross-user
    elevation that registration is what fails with 0x80073D19). Only the winget source: the
    installs use no other, and msstore can fail for an account that never signed in while the winget
    source is fine. No --accept-source-agreements: `source update` rejects it with 0x8A150002
    (issues #174/#175); the installs accept the agreements. winget's output is echoed into the
    transcript only when the update fails.
.RETURNS
    [hashtable] @{ Succeeded; ExitCode (or $null); TimedOut; LaunchError (or $null) }
#>
function Invoke-WingetSourceProbe {
    $probe = Invoke-WingetProcess -ArgumentList @('source', 'update', '--name', 'winget', '--disable-interactivity') -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceUpdate) -Echo None
    if ($probe.LaunchFailed) {
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false; LaunchError = $probe.LaunchError }
    }
    if ($probe.TimedOut -or $probe.ExitCode -ne 0) {
        Write-ProcessOutput -Line $probe.Output -Tail 20
    }
    return @{
        Succeeded   = (-not $probe.TimedOut -and $probe.ExitCode -eq 0)
        ExitCode    = $probe.ExitCode
        TimedOut    = [bool]$probe.TimedOut
        LaunchError = $null
    }
}

<#
.SYNOPSIS
    Runs `winget source reset --force` and says whether it worked, with its exit code when not.
.DESCRIPTION
    The fix for a missing or corrupted winget source. It also removes any source added beyond the
    defaults. No --accept-source-agreements: `source reset` rejects it with 0x8A150002, so the reset
    used to never run.
.RETURNS
    [bool]
#>
function Reset-WingetSource {
    Write-Info 'Resetting the winget source (winget source reset --force)...'
    $reset = Invoke-WingetProcess -ArgumentList @('source', 'reset', '--force', '--disable-interactivity') -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceReset)
    if ($reset.LaunchFailed) {
        Write-WarningMessage "Winget source reset failed: $($reset.LaunchError)"
    }
    elseif ($reset.TimedOut) {
        Write-WarningMessage 'Winget source reset failed: it did not finish in time and was stopped.'
    }
    elseif ($reset.ExitCode -ne 0) {
        Write-WarningMessage ('Winget source reset failed with exit code {0}.' -f (Format-WingetExitCode -ExitCode $reset.ExitCode))
    }
    else {
        Write-Info 'Source reset completed.'
        return $true
    }
    return $false
}

# --- WingetLaunchResilience ---
# Winget launch helpers (issues #258, #277, review findings P2-8, P3-7, P3-9, P3-10). winget.exe can
# fail to start at all when the per-user app-execution alias under %LOCALAPPDATA%\Microsoft\WindowsApps
# is broken or locked, most often while the Microsoft.DesktopAppInstaller package is being upgraded
# or re-registered (for example by a Winget-AutoUpdate run, whose Install-Prerequisites re-provisions
# App Installer). These helpers classify a failed launch and check, with one bounded
# `winget --version`, whether winget can be started at all. Invoke-WingetInstall uses that check as a
# circuit breaker: once winget cannot be started, the remaining apps fail at once with one reason
# instead of each spending its own retry budget (about 24 minutes on a wedged machine before).

<#
.SYNOPSIS
    Returns true when a winget launch failed for a transient reason.
.DESCRIPTION
    The transient class is winget.exe's own file being briefly inaccessible (issues #253/#258):
    ERROR_CANT_ACCESS_FILE (1920, "The file cannot be accessed by the system.") and
    ERROR_SHARING_VIOLATION (32, "...being used by another process."). Anything else (e.g. winget
    genuinely missing from PATH) is a real failure the caller should not retry.

    Invoke-ExternalProcess reports the Win32 error code of a failed launch, and -NativeErrorCode
    classifies by that code, which is the same in every display language (review finding P3-6).
    Without a code, -Message is matched instead: against the English texts, against the
    "StandardOutputEncoding is only supported when standard output is redirected." message
    PowerShell's native-command invocation throws for the same broken alias (issue #277), and
    against the two Win32 messages as this machine words them (Get-Win32ErrorMessage), so a German
    "Das System kann auf die Datei nicht zugreifen" matches too. All matching ignores case.
.PARAMETER Message
    The exception message to classify.
.PARAMETER NativeErrorCode
    The Win32 error code of the failed launch, when known.
.RETURNS
    [bool]
#>
function Test-TransientWingetLaunchError {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$NativeErrorCode
    )

    # ERROR_SHARING_VIOLATION and ERROR_CANT_ACCESS_FILE.
    $transientCodes = @(32, 1920)
    if ($null -ne $NativeErrorCode -and $transientCodes -contains $NativeErrorCode) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }
    if ($Message -match 'cannot be accessed by the system|being used by another process|StandardOutputEncoding is only supported when standard output is redirected') {
        return $true
    }
    foreach ($code in $transientCodes) {
        $localized = "$(Get-Win32ErrorMessage -Code $code)".Trim().TrimEnd('.')
        if ($localized.Length -gt 0 -and $Message.IndexOf($localized, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Returns the text Windows gives a Win32 error code, in this machine's display language.
.DESCRIPTION
    The message Start-Process embeds when it cannot launch a program comes from the same Windows
    message table (FormatMessage), so matching against it works in any display language (review
    finding P3-6). Off Windows the .NET runtime words error codes as errno values, which mean
    something else, so nothing is returned there.
.PARAMETER Code
    The Win32 error code.
.RETURNS
    [string] The message, or $null off Windows.
#>
function Get-Win32ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $null
    }
    return (New-Object System.ComponentModel.Win32Exception($Code)).Message
}

<#
.SYNOPSIS
    Returns the winget executable to launch.
.DESCRIPTION
    Every winget call goes through Invoke-WingetProcess, which calls this, so it is the one place
    that decides how winget is found:
      - Normally the bare command name 'winget', which Invoke-ExternalProcess resolves on PATH to
        the account's app-execution alias.
      - In a run as SYSTEM, the full path of the machine-wide winget.exe that
        Test-MachineWingetAvailable found and checked at the start of the run
        ($script:MachineWingetPath; review finding P2-24). SYSTEM has no alias: winget cannot be
        registered for it. When that file is gone, because App Installer was updated during the
        run and its old folder removed, the newest machine-wide winget.exe is looked up again.

    There used to be a -BypassAlias switch that launched winget.exe from the DesktopAppInstaller
    package folder under C:\Program Files\WindowsApps when the alias failed (issue #258). It never
    recovered a launch in any E2E run: every direct launch by an administrator account failed with
    'Access is denied', even against a healthy registered package, so it only added retries and
    misleading 'next attempt uses ...' lines (review finding P3-7). It was removed. SYSTEM, unlike
    an administrator account, may start that winget.exe.
.RETURNS
    [string] 'winget', or a full path to winget.exe in a SYSTEM run.
#>
function Resolve-WingetExecutable {
    $machinePath = $script:MachineWingetPath
    if ([string]::IsNullOrWhiteSpace($machinePath)) {
        return 'winget'
    }
    if (-not (Test-Path -LiteralPath $machinePath -PathType Leaf)) {
        $candidate = @(Get-MachineWingetCandidate) | Select-Object -First 1
        if ($candidate) {
            $script:MachineWingetPath = $candidate.Path
            return $candidate.Path
        }
    }
    return $machinePath
}

<#
.SYNOPSIS
    Checks that winget can be started and answers, with a bounded `winget --version`.
.DESCRIPTION
    Get-Command only proves that the app-execution alias is on PATH, not that winget can run: a
    wedged App Installer, a missing framework or an unlicensed package all leave the alias in
    place (review finding P3-9). This runs `winget --version` through Invoke-WingetProcess under
    the WingetVersion time limit and counts it as launchable only when the process started,
    exited 0 and printed a version (a line matching '^v\d', such as 'v1.12.350').

    With -Attempts above 1, a failed check is repeated after RetryDelaySeconds, for failures that
    can clear on their own: a transient launch failure (Test-TransientWingetLaunchError: winget.exe
    locked by an antivirus scan or an App Installer update in progress), a timeout, a non-zero exit
    or no version in the output. Any other launch failure (winget not on PATH, 'Access is denied')
    is final at once: waiting does not change it. So is exit code 0xC0000135
    (STATUS_DLL_NOT_FOUND): the Windows loader could not find a DLL winget.exe needs, which stays
    so until that DLL is installed. A machine-wide winget.exe started as SYSTEM fails this way on a
    PC without the Visual C++ runtime, and checking it again only made every such run wait 75
    seconds before trying the next one (review of finding P2-24). And so is 0x8A15003A
    (BLOCKED_BY_POLICY): Group Policy turned winget off, which no wait changes (review finding
    P3-30).

    Used by Initialize-Winget (is winget usable before the run), by Invoke-WingetInstall's
    circuit breaker (after an app could not launch winget) and end-of-run check, and by
    e2e/Assert-Install.ps1. It replaced Wait-WingetLaunchable, whose multi-minute polling and
    consecutive-success streaks existed only to survive the Winget-AutoUpdate run the installer
    used to start mid-run (RUN_WAU=YES, removed; review finding P3-10).

    Runs with nothing but read-only winget calls, so a dry run can use it.
.PARAMETER Attempts
    How many times to check before giving up. Default 1.
.PARAMETER RetryDelaySeconds
    Seconds to wait between checks. Default 10.
.RETURNS
    [pscustomobject] with Launchable ([bool]), Version (the version winget printed, or $null),
    Reason (why it is not launchable, for a message; $null when it is), ExitCode (the last check's
    exit code; $null when winget did not start or did not finish) and Attempts (checks made).
#>
function Test-WingetLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$Attempts = 1,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 10
    )

    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetVersion
    # 0xC0000135 STATUS_DLL_NOT_FOUND and 0x8A15003A BLOCKED_BY_POLICY, as the signed Int32 a
    # process exit code is: neither changes by waiting.
    $finalExitCodes = @(-1073741515, -1978335174)
    $reason = $null
    $run = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $run = Invoke-WingetProcess -ArgumentList @('--version') -TimeoutSeconds $timeoutSeconds -Echo None
        $retryable = $true
        if ($run.LaunchFailed) {
            $reason = 'winget could not be started: {0}' -f "$($run.LaunchError)".Trim().TrimEnd('.')
            $retryable = Test-TransientWingetLaunchError -NativeErrorCode $run.LaunchErrorCode -Message $run.LaunchError
        }
        elseif ($run.TimedOut) {
            $reason = "'winget --version' did not answer within $timeoutSeconds seconds and was stopped"
        }
        elseif ($run.ExitCode -ne 0) {
            $reason = "'winget --version' exited with {0}" -f (Format-WingetExitCode -ExitCode $run.ExitCode)
            if ($finalExitCodes -contains $run.ExitCode) {
                $retryable = $false
            }
        }
        else {
            $versionLine = @($run.StandardOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1
            if ($versionLine) {
                return [pscustomobject]@{ Launchable = $true; Version = $versionLine; Reason = $null; ExitCode = 0; Attempts = $attempt }
            }
            $reason = "'winget --version' printed no version"
        }

        if (-not $retryable -or $attempt -ge $Attempts) {
            break
        }
        Write-WarningMessage "winget is not usable yet ($reason). Checking again in ${RetryDelaySeconds}s (check $($attempt + 1) of $Attempts)..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }

    # What winget printed, if anything: the reason it gives is the useful part of the transcript.
    if ($run -and -not $run.LaunchFailed -and @($run.Output).Count -gt 0) {
        Write-ProcessOutput -Line $run.Output -Tail 10
    }
    return [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $reason; ExitCode = $run.ExitCode; Attempts = [Math]::Min($attempt, $Attempts) }
}

# --- WingetResultCodes ---
# winget result codes (review findings P2-15 and P3-16). winget reports its result as a signed Int32
# HRESULT, and every place that printed one showed only the hex value, so a failure such as
# 0x8A150102 (another installation in progress) read as 'package not found after install' plus a
# number. This file is the one table of the codes the installer knows: their winget symbol, what
# they mean in a sentence the summary can show, and how the install should treat them. Every place
# that prints a winget exit code goes through Format-WingetExitCode, and Install-WingetPackage
# decides its retries from the class below, so the name, the message and the behaviour cannot drift
# apart. Values come from winget's own table (doc/windows/package-manager/winget/returnCodes.md,
# "winget error --output"); the classes from how winget maps installer exit codes
# (AppInstallerCLICore Workflows/InstallFlow.cpp ReportInstallerResult and Manifest/ManifestCommon.cpp
# GetDefaultKnownReturnCodes). Runs under Windows PowerShell 5.1 too (the PowerShell 7 bootstrap
# prints the exit code of winget's PowerShell install), so it uses nothing newer than .NET 4.5.

<#
.SYNOPSIS
    Returns what the installer knows about a winget exit code, or $null for an unknown code.
.DESCRIPTION
    Keys are the hex form winget's documentation and issues use (0x8A150102). Classes:

      InstallInProgress     Windows Installer was busy with another installation (msiexec 1618).
                            Wait for it and retry (Install-WingetPackage).
      InUse                 The app or its files were in use. One delayed retry.
      RestartRequiredFirst  The installer cannot run until Windows restarts (Inno exit 8). Never
                            retried: only a restart changes it.
      RestartRequired       The package installed, and a restart finishes it (MSI 3010 on winget
                            1.6 and older, which newer winget reports as exit 0 with a warning), or
                            the installer started a restart itself (MSI 1641).
      SourceBroken          The winget source is missing or its data is corrupted.
                            Initialize-Winget runs `winget source reset --force` for it.
      (empty)               Named for the reader only; no special handling.
.PARAMETER ExitCode
    The exit code as winget reports it (a signed Int32), or $null.
.RETURNS
    [pscustomobject] @{ ExitCode; Hex; Name; Meaning; Class }, or $null when the code is $null, 0 or
    not in the table.
#>
function Get-WingetExitCodeInfo {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    if ($null -eq $ExitCode -or $ExitCode -eq 0) {
        return $null
    }

    # Name: the winget symbol without its APPINSTALLER_CLI_ERROR_ prefix (or the Windows symbol),
    # searchable in winget's returnCodes.md. Meaning: a clause that completes "Failed to install: X
    # (...)" and says what to do where there is something to do.
    $table = @{
        # Installer results (winget's installer-exit-code mapping).
        '0x8A150102' = @('INSTALL_INSTALL_IN_PROGRESS', 'another installation was in progress (Windows Installer was busy) - re-run the installer once it has finished', 'InstallInProgress')
        '0x8A150101' = @('INSTALL_PACKAGE_IN_USE', 'the app is running - close it, then re-run the installer', 'InUse')
        '0x8A150103' = @('INSTALL_FILE_IN_USE', 'files the installer needs are in use - close the app, then re-run the installer', 'InUse')
        '0x8A150111' = @('INSTALL_PACKAGE_IN_USE_BY_APPLICATION', 'the app is in use by another application - close it, then re-run the installer', 'InUse')
        '0x8A150109' = @('INSTALL_REBOOT_REQUIRED_TO_FINISH', 'a restart is required to finish the installation', 'RestartRequired')
        '0x8A15010A' = @('INSTALL_REBOOT_REQUIRED_FOR_INSTALL', 'a restart is required before this installer can run - restart this PC, then re-run the installer', 'RestartRequiredFirst')
        '0x8A15010B' = @('INSTALL_REBOOT_INITIATED', 'the installer started a restart of this PC - re-run the installer after the restart', 'RestartRequired')
        '0x8A15010C' = @('INSTALL_CANCELLED_BY_USER', 'the installation was cancelled', '')
        '0x8A15010D' = @('INSTALL_ALREADY_INSTALLED', 'another version of the app is already installed', '')
        '0x8A15010E' = @('INSTALL_DOWNGRADE', 'a higher version of the app is already installed', '')
        '0x8A15010F' = @('INSTALL_BLOCKED_BY_POLICY', 'organization policy blocks this installation', '')
        '0x8A150104' = @('INSTALL_MISSING_DEPENDENCY', 'a dependency of the package is missing from this system', '')
        '0x8A150105' = @('INSTALL_DISK_FULL', 'the disk is full - free some space, then re-run the installer', '')
        '0x8A150106' = @('INSTALL_INSUFFICIENT_MEMORY', 'there was not enough memory to install', '')
        '0x8A150107' = @('INSTALL_NO_NETWORK', 'the installer needs an internet connection', '')
        '0x8A150108' = @('INSTALL_CONTACT_SUPPORT', 'the installer failed (Windows Installer service error)', '')
        '0x8A150110' = @('INSTALL_DEPENDENCIES', 'a dependency of the package failed to install', '')
        '0x8A150112' = @('INSTALL_INVALID_PARAMETER', 'the installer rejected its parameters', '')
        '0x8A150113' = @('INSTALL_SYSTEM_NOT_SUPPORTED', 'the package does not support this system', '')
        '0x8A150115' = @('INSTALL_CUSTOM_ERROR', 'the installer failed with its own error', '')
        '0x8A150006' = @('SHELLEXEC_INSTALL_FAILED', 'the installer failed (its own exit code is in the log above, and in its installer log)', '')
        '0x8A150049' = @('MSI_INSTALL_FAILED', 'the MSI installer failed (its own exit code is in the log above, and in its installer log)', '')
        '0x8A150052' = @('PORTABLE_INSTALL_FAILED', 'the portable package failed to install', '')
        # Package selection, download and agreements.
        '0x8A150010' = @('NO_APPLICABLE_INSTALLER', 'no installer in the package applies to this system', '')
        '0x8A15002B' = @('UPDATE_NOT_APPLICABLE', 'no applicable update was found for the installed version', '')
        '0x8A150061' = @('PACKAGE_ALREADY_INSTALLED', 'a version of the package is already installed', '')
        '0x8A15008E' = @('UPDATE_INSTALL_TECHNOLOGY_MISMATCH', 'the installed version uses a different install technology', '')
        '0x8A150068' = @('PACKAGE_IS_PINNED', 'the package is pinned in winget', '')
        '0x8A150011' = @('INSTALLER_HASH_MISMATCH', 'the downloaded installer does not match the hash in its manifest', '')
        '0x8A150086' = @('INSTALLER_ZERO_BYTE_FILE', 'the installer download was empty (network or proxy problem)', '')
        '0x8A15006D' = @('SERVICE_UNAVAILABLE', 'a download server was busy or unavailable - re-run the installer later', '')
        '0x8A150041' = @('PACKAGE_AGREEMENTS_NOT_ACCEPTED', 'the package agreements were not accepted', '')
        '0x8A150046' = @('SOURCE_AGREEMENTS_NOT_ACCEPTED', 'the source agreements were not accepted', '')
        # winget itself and its sources.
        '0x8A150001' = @('INTERNAL_ERROR', 'winget hit an internal error', '')
        '0x8A150002' = @('INVALID_CL_ARGUMENTS', 'winget rejected its command line', '')
        '0x8A150003' = @('COMMAND_FAILED', 'the winget command failed', '')
        '0x8A15000B' = @('SOURCES_INVALID', 'the configured winget sources are corrupted', 'SourceBroken')
        '0x8A15000F' = @('SOURCE_DATA_MISSING', 'the winget source data is missing', 'SourceBroken')
        '0x8A150012' = @('SOURCE_NAME_DOES_NOT_EXIST', 'the winget source is not configured', 'SourceBroken')
        '0x8A150014' = @('NO_APPLICATIONS_FOUND', 'winget found no package with that id', '')
        '0x8A150015' = @('NO_SOURCES_DEFINED', 'no winget source is configured', 'SourceBroken')
        '0x8A150019' = @('COMMAND_REQUIRES_ADMIN', 'the winget command needs administrator rights', '')
        '0x8A15003A' = @('BLOCKED_BY_POLICY', 'winget is disabled by Group Policy on this PC', '')
        '0x8A15003F' = @('SOURCE_DATA_INTEGRITY_FAILURE', 'the winget source data is corrupted', 'SourceBroken')
        '0x8A150045' = @('SOURCE_OPEN_FAILED', 'the winget source could not be opened', '')
        '0x8A15004B' = @('FAILED_TO_OPEN_ALL_SOURCES', 'one or more winget sources could not be opened', '')
        '0x8A150056' = @('INSTALLER_PROHIBITS_ELEVATION', 'the installer cannot run as administrator', '')
        '0x8A15007D' = @('ADMIN_CONTEXT_ACTION_PROHIBITED', 'not permitted as administrator on a package installed for one user', '')
        # Windows HRESULTs winget passes through as its exit code.
        '0x80073D19' = @('ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF', 'the installing account has no logon session, so Windows blocked the app package deployment', '')
        # App package deployment errors seen when App Installer is registered or repaired (issues
        # #265, #279).
        '0x80073CF3' = @('ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED', 'a package it depends on, such as a framework, is missing', '')
        '0x80073D06' = @('ERROR_INSTALL_PACKAGE_DOWNGRADE', 'a higher version of the package is already installed', '')
        # winget maps this to 0x8A150101 for MSIX installs, so it is named here but not retried.
        '0x80073D02' = @('ERROR_PACKAGES_IN_USE', 'the app is running - close it, then re-run the installer', '')
        '0x80004004' = @('E_ABORT', 'the operation was cancelled or stopped', '')
        '0x80072EE2' = @('WININET_E_TIMEOUT', 'the download timed out', '')
        '0x80072EE7' = @('WININET_E_NAME_NOT_RESOLVED', 'the download server name could not be resolved', '')
        '0x80072EFD' = @('WININET_E_CANNOT_CONNECT', 'could not connect to the download server', '')
        '0x80190194' = @('HTTP_E_STATUS_NOT_FOUND', 'the download returned HTTP 404 (not found)', '')
        # The Windows loader's code when winget.exe cannot even start (review finding P2-24), reported
        # where winget.exe runs outside its package, as it does for SYSTEM.
        '0xC0000135' = @('STATUS_DLL_NOT_FOUND', 'winget.exe could not start because a DLL it needs was not found', '')
    }

    $hex = '0x{0:X8}' -f [int]$ExitCode
    if (-not $table.ContainsKey($hex)) {
        return $null
    }
    $row = $table[$hex]
    return [pscustomobject]@{
        ExitCode = [int]$ExitCode
        Hex      = $hex
        Name     = $row[0]
        Meaning  = $row[1]
        Class    = $row[2]
    }
}

<#
.SYNOPSIS
    Formats a winget exit code for a message: its hex form, followed by its name when known.
.DESCRIPTION
    The one way a winget exit code is printed (review findings P2-15, P3-16), for example
    '0x8A150102 INSTALL_INSTALL_IN_PROGRESS', or '0x00000001' for a code the table does not name.
    Winget reports HRESULT-style codes as signed Int32 (e.g. -2147009255); the X8 format renders the
    familiar hex form (0x80073D19) winget's documentation and issues use.
.PARAMETER ExitCode
    The exit code as winget reports it.
.RETURNS
    [string]
#>
function Format-WingetExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $info = Get-WingetExitCodeInfo -ExitCode $ExitCode
    if ($info) {
        return ('{0} {1}' -f $info.Hex, $info.Name)
    }
    return ('0x{0:X8}' -f $ExitCode)
}

<#
.SYNOPSIS
    Returns whether an install result says the installer cannot run until Windows restarts.
.DESCRIPTION
    True for 0x8A15010A (INSTALL_REBOOT_REQUIRED_FOR_INSTALL; Inno setup exit 8, for example Git's
    installer while a Windows Update restart is pending). Invoke-WingetInstall's retry pass leaves
    such an app alone, because retrying before a restart fails the same way (review finding P3-16).
.PARAMETER InstallResult
    An Install-AppWithVerification InstallResult (Install-WingetPackage's result, or a package-specific
    installer's), or $null.
.RETURNS
    [bool]
#>
function Test-RestartRequiredFirst {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult
    )

    if ($null -eq $InstallResult -or $null -eq $InstallResult.ExitCode) {
        return $false
    }
    $info = Get-WingetExitCodeInfo -ExitCode ([int]$InstallResult.ExitCode)
    return [bool]($info -and $info.Class -eq 'RestartRequiredFirst')
}

<#
.SYNOPSIS
    Returns whether a winget install says the package installed and a restart finishes it.
.DESCRIPTION
    winget 1.7 and later report an MSI, WiX or Burn installer's 3010 as exit 0 and print 'Restart
    your PC to finish installation.'; winget 1.6 and older exit 0x8A150109, and an installer that
    started a restart itself (MSI 1641) gives 0x8A15010B (review finding P3-16). True for any of the
    three. The printed warning is matched in English only; on other display languages
    Invoke-WingetInstall's pending-restart registry check is what notices it. Used by
    Install-WingetPackage for every app and by the PowerShell 7 bootstrap for its winget install of
    PowerShell, so both read winget's result the same way. Runs under Windows PowerShell 5.1 too.
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.PARAMETER Output
    What winget printed (Invoke-WingetProcess's Output).
.RETURNS
    [bool]
#>
function Test-WingetRestartRequiredResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Output
    )

    if ($null -eq $ExitCode) {
        return $false
    }
    if ($ExitCode -ne 0) {
        $info = Get-WingetExitCodeInfo -ExitCode $ExitCode
        return [bool]($info -and $info.Class -eq 'RestartRequired')
    }
    foreach ($line in @($Output)) {
        if ([string]$line -match 'Restart your PC to finish installation') {
            return $true
        }
    }
    return $false
}

# --- AppCatalog ---
<#
.SYNOPSIS
    Returns the curated default application catalog shared by the installer and uninstaller.
.DESCRIPTION
    Single source of truth for the app list (issue #190). Invoke-WingetInstall consumes it as the
    default value of its -Apps parameter, and winget-app-uninstall.ps1 iterates the same catalog
    for removal. Each entry is a hashtable with at least:
      - name: the winget package id (validated by Test-AppDefinitions before use).
    Optional fields:
      - install: name of a package-specific install function that performs its own verification
        (dispatched by Install-AppWithVerification instead of the generic winget path). This
        string is validated against the module's defined functions by
        build/Build-WingetInstallScript.ps1's Get-UndefinedCatalogInstallReference guard (issue
        #236) - if you add another field carrying a function name the same way (e.g.
        'uninstall', 'verify'), extend that guard to cover it too, or a stale/renamed function
        will pass every build check and only fail at runtime.
      - installerType: forwarded to Install-WingetPackage for machine-scope handling.
      - condition: scriptblock returning a boolean, evaluated once per run by Invoke-WingetInstall
        (Test-AppApplicability) before anything is installed, and the verdict used by both passes
        (review finding P3-34). Falsy means the app does not apply to this machine and is
        reported as Skipped (not applicable) instead of installed (issue #217). Fail open = attempt
        the install: a condition that throws or writes an error is warned about and treated as
        applicable, so a broken probe can never silently drop an app. A probe a condition calls
        must therefore throw when it has no answer, never return an empty or default value that
        reads as "does not apply" (Get-ComputerManufacturer, Get-OSArchitecture; review finding
        P3-33).
      - conditionDescription: short human-readable reason shown in the skip message, e.g.
        "Skipping: <id> (not applicable: <conditionDescription>)".
      - msixName: the app's MSIX package name. In a run for the whole PC (SYSTEM, or cross-user
        elevation), whether that package is provisioned for every user decides whether the app is
        installed, before and after the install, instead of `winget list`, which only sees the
        packages registered for the account running it (review finding P3-24).
    Add or remove apps HERE — never inline a copy of this list at a call site (the previous
    duplicates in Invoke-WingetInstall and winget-app-uninstall.ps1 had already drifted).
.RETURNS
    [array] of app-definition hashtables.
#>
function Get-DefaultAppCatalog {
    return @(
        @{name = '7zip.7zip' },
        @{name = 'GlavSoft.TightVNC' },
        # The manifest's only installer is x64, and Adobe supports only the 32-bit (x86) Reader on
        # Windows on ARM: on an ARM64 PC winget runs the x64 installer under emulation and it
        # fails, in both passes, on every run (review finding P3-32). Architecture-gated so an
        # ARM64 PC reports it Skipped (not applicable) with the reason instead.
        @{name = 'Adobe.Acrobat.Reader.64-bit'; condition = { (Get-OSArchitecture) -ne 'Arm64' }; conditionDescription = 'its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows' },
        @{name = 'Google.Chrome' },
        @{name = 'Google.GoogleDrive' },
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        # Dell Command Update is useless on non-Dell hardware, and its DotNet Desktop Runtime
        # dependency cannot even install on Server-based images (0x8A150104 on GitHub-hosted
        # runners). Manufacturer-gated so non-Dell machines report it Skipped (not applicable)
        # instead of failing a pointless install (issue #217).
        @{name = 'Dell.CommandUpdate.Universal'; condition = { (Get-ComputerManufacturer) -match 'Dell' }; conditionDescription = 'Dell hardware only' },
        # PowerShell needs a version-agnostic install strategy (no pinning — always the latest):
        # winget installs PowerShell 7.6+ as an MSIX by default, which registers per-user and fails
        # to deploy in an elevated cross-user / machine-scope context ("The current system
        # configuration does not support the installation of this package"). Install-PowerShellLatest
        # prefers the MSI while it exists (<= 7.6), and once the MSI is gone (7.7+) installs the latest
        # MSIX machine-wide — natively on Windows 24H2+, or via DISM provisioning on older Windows
        # (issues #163/#166). It self-verifies, so the loop must not re-check it with `winget list`.
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
        # winget cannot reliably install/upgrade Microsoft.WindowsTerminal from a session that
        # Windows Terminal itself is hosting: doing so would require replacing files belonging to
        # the very console host rendering the session, which self-locks winget.exe's own launch
        # ("Access is denied" / "The file cannot be accessed by the system") instead of failing
        # transiently - retries never recover (issue #271: 5 launch attempts plus a full final
        # retry pass all failed identically in the reported E2E run, while every other catalog app
        # installed fine in the same run). Gated with the same condition mechanism as Dell Command
        # Update above (issue #217): evaluated before any winget probe runs, so the
        # structurally-doomed attempt is skipped instead of retried. A run as SYSTEM has no
        # Terminal session, so the check does not apply to it (review finding P3-24); a run for
        # the whole PC decides from msixName whether Terminal is provisioned for every user, as
        # Windows 11 provisions it, and defers it where winget has no machine-wide installer.
        @{name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal'; condition = { (Test-IsSystemAccount) -or -not (Test-WindowsTerminalHostsCurrentSession) }; conditionDescription = 'winget cannot self-update Windows Terminal from a session Windows Terminal itself is hosting (issue #271)' }
    )
}

# --- AppValidation ---
<#
.SYNOPSIS
    Validates the list of application definitions before processing.
.DESCRIPTION
    Ensures each entry in the apps array is a hashtable containing a non-empty string `name` value
    matching the winget package-id shape CLAUDE.md documents (publisher.product), and removes
    duplicates, warning about any issues.
.PARAMETER Apps
    The collection of application definition hash tables to validate.
.RETURNS
    [pscustomobject] containing ValidApps, Errors, and Warnings arrays.
#>
function Test-AppDefinitions {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Apps
    )

    $errors = @()
    $warnings = @()
    $validatedApps = @()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]
        if (-not ($app -is [hashtable])) {
            $errors += "App entry at index $i is not a hashtable."
            continue
        }

        if (-not $app.ContainsKey('name') -or -not ($app['name'] -is [string]) -or [string]::IsNullOrWhiteSpace($app['name'])) {
            $errors += "App entry at index $i is missing a valid 'name' value."
            continue
        }

        $name = $app['name'].Trim()

        # Package-id shape check (CLAUDE.md "Winget Notes"): reject any catalog entry whose name
        # does not look like a winget publisher.product id before it is ever trusted downstream.
        if (-not (Test-WingetPackageIdFormat -PackageId $name)) {
            $errors += "App entry at index $i has an invalid package id '$name': does not match the required publisher.product shape."
            continue
        }

        if (-not $seenNames.Add($name)) {
            $warnings += "Duplicate app definition detected for '$name'. Subsequent entry ignored."
            continue
        }

        $app['name'] = $name
        $validatedApps += $app
    }

    return [pscustomobject]@{
        ValidApps = $validatedApps
        Errors    = $errors
        Warnings  = $warnings
    }
}

# --- Elevation ---
# Public (exported) elevation helpers. The rest of the elevation detection helpers live in
# Private/Elevation.ps1; these are exported (issue #190) so winget-app-uninstall.ps1 can reuse
# them instead of hand-rolling its own admin check / Start-Process relaunch.

<#
.SYNOPSIS
    Detects whether the current process is running with administrator privileges.
.DESCRIPTION
    The single shared implementation of the
    "[Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(...)"
    check, previously copy-pasted (and already behaviorally diverged) across
    WingetAppSetup/Public/Install.ps1, winget-app-uninstall.ps1, and
    WingetAppSetup/Private/PowerShell7Bootstrap.ps1 (full-repo review finding, 2026-07-16).
    Fails safe: if the underlying identity/role check throws for any reason (an exotic restricted
    token, a non-interactive service context, or a mocked failure in tests), this warns and
    returns $true rather than letting the exception propagate and abort the caller - matching the
    PowerShell7Bootstrap.ps1 behavior that is now applied at every call site.

    At the two call sites that gate elevation (Invoke-WingetInstall, winget-app-uninstall.ps1),
    "assume elevated" on failure means a broken check SKIPS Restart-WithElevation and proceeds
    unelevated rather than retrying elevation. This is a deliberate tradeoff, not an oversight
    (full-repo mega-review, 2026-07-17): the trigger is vanishingly rare on a real Windows
    session, the caller still warns loudly before proceeding, any operation that genuinely needed
    elevation then fails just as loudly with an access-denied error, and the alternative
    (fail-closed: assume non-admin, always attempt Restart-WithElevation) risks a relaunch loop if
    the same check throws deterministically in the relaunched process too - a worse failure mode
    than a noisy unelevated run. If a future caller's failure consequence is instead silent/unsafe
    rather than loud, that caller should check the exception itself rather than rely on this
    shared default.
.RETURNS
    [bool] $true when the current process is elevated (or when the check itself failed and could
    not determine elevation), $false when it is confirmed non-elevated.
#>
function Test-IsAdmin {
    try {
        $principal = Get-CurrentWindowsPrincipal
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    }
    catch {
        Write-WarningMessage "Could not determine administrator status; assuming elevated: $_"
        return $true
    }
}

<#
.SYNOPSIS
    Runs the script again in an elevated Windows PowerShell window, waits for it, and returns its
    exit code.
.DESCRIPTION
    Review findings P2-11, P2-12 and P3-11. Asks for administrator rights (the UAC prompt) and starts
    Windows PowerShell (Get-WindowsPowerShellPath) elevated in a new window, waits for it to finish
    and returns its exit code, so the run that asked reports what the elevated run did.

    The elevated program is always System32's powershell.exe, which every account has. A bare
    pwsh.exe or wt.exe resolved through the invoking user's PATH and per-user app aliases, which a
    separate admin account that elevates does not have, so the elevated window could fail to start
    while the run that asked had already exited 0. The installer's Windows PowerShell 5.1 dispatch
    then finds or installs PowerShell 7 as the elevating account and runs under it in the same
    elevated window. There is no Windows Terminal relaunch any more: it could not report an exit
    code either.

    By default the elevated process does not run ScriptPath itself. This function reads the file
    once, checks it against -ExpectedSha256 and stages those bytes in this account's %TEMP%, which
    the elevating account can read even when it cannot see ScriptPath (a mapped drive, a share).
    The elevated process runs a short check given on its command line (New-ElevationVerifierCommand)
    that compares the staged file with the SHA256 computed here, copies it into a folder only
    administrators can change and runs that copy, so a file rewritten in a user-writable folder (the
    bootstrap's copy in %TEMP%, a clone in Downloads, the staged copy) while the UAC prompt is up is
    not run with administrator rights. The staged copy is removed once the elevated run has ended.
    -InPlace runs ScriptPath directly, for a script that needs the files next to it
    (winget-app-uninstall.ps1 imports the module from its own folder). Nothing is checked then: the
    elevated run runs whatever ScriptPath and the files it loads hold when it starts, so a file in a
    folder the signed-in user can write to is exposed while the UAC prompt is up.

    Never asks when nobody is at the console (Test-EffectiveNonInteractive): an unattended run would
    leave a UAC prompt on someone's desktop and report nothing. A declined UAC prompt (Win32 error
    1223, ERROR_CANCELLED) is reported once, with no second prompt.
.PARAMETER ScriptPath
    The full path of the script to run elevated.
.PARAMETER AdditionalArguments
    Switches forwarded to the elevated run (for example '-SkipSystemCheck'), appended after the
    script path so the elevated run inherits the caller's intent. Only switch names are accepted:
    they become part of a command line.
.PARAMETER ExpectedSha256
    The script's SHA256 when this run started (the generated installer computes it at startup). When
    the file no longer has it, nothing is started. Empty: the hash is taken now.
.PARAMETER InPlace
    Run ScriptPath itself, unchecked, instead of a checked copy.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch.
.RETURNS
    [pscustomobject] @{ Started; ExitCode }. Started is $true when an elevated run started, and
    ExitCode is then its exit code. Otherwise ExitCode is 4 (no UAC prompt in a non-interactive run,
    the prompt was declined, or the elevated process could not be started) or 5 (the script could
    not be read, or changed since the run started).
#>
function Restart-WithElevation {
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^-[A-Za-z][A-Za-z0-9]*$')]
        [string[]]$AdditionalArguments = @(),

        [Parameter(Mandatory = $false)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $false)]
        [switch]$InPlace,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) {
        Write-ErrorMessage 'Administrator rights are required, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM.'
        return [pscustomobject]@{ Started = $false; ExitCode = 4 }
    }

    $powerShellPath = Get-WindowsPowerShellPath
    $stagingDirectory = $null
    if ($InPlace) {
        $argumentString = ConvertTo-ProcessArgumentString -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $AdditionalArguments)
    }
    else {
        # Read once: the hash and the staged copy below are both of these bytes.
        try {
            $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
        }
        catch {
            Write-ErrorMessage "Could not read $ScriptPath to run it elevated: $($_.Exception.Message)"
            return [pscustomobject]@{ Started = $false; ExitCode = 5 }
        }
        $sha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
        if ($ExpectedSha256 -and $sha256 -ne $ExpectedSha256) {
            Write-ErrorMessage "$ScriptPath changed after this run started, so it is not run with administrator rights. Start it again."
            return [pscustomobject]@{ Started = $false; ExitCode = 5 }
        }
        # Staged in this account's %TEMP%, which administrators can read (review finding P2-11): the
        # elevated account may not see ScriptPath itself, for example on a mapped drive (drive
        # mappings belong to the signed-in session) or a share it has no access to. The elevated
        # process checks the staged copy against the hash all the same.
        try {
            $stagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-elevate-' + [System.Guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $stagingDirectory -Force -ErrorAction Stop)
            $stagedPath = Join-Path $stagingDirectory (($ScriptPath -split '[\\/]')[-1])
            [System.IO.File]::WriteAllBytes($stagedPath, $bytes)
        }
        catch {
            Write-ErrorMessage "Could not copy $ScriptPath to run it elevated: $($_.Exception.Message)"
            if ($stagingDirectory) {
                Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
            return [pscustomobject]@{ Started = $false; ExitCode = 5 }
        }
        $verifierCommand = New-ElevationVerifierCommand -ScriptPath $stagedPath -Sha256 $sha256 -PowerShellPath $powerShellPath -CopyRoot (Get-ElevatedCopyRoot) -AdditionalArguments $AdditionalArguments
        $argumentString = ConvertTo-ProcessArgumentString -ArgumentList @('-NoProfile', '-Command', $verifierCommand)
    }

    try {
        # ShellExecuteEx, which starts an elevated process, accepts a command line of about 2048
        # characters; a longer one would not start or would arrive cut off.
        if ($argumentString.Length -gt 2000) {
            if ($InPlace) {
                Write-ErrorMessage "The path $ScriptPath is too long to start it elevated. Move it to a shorter path, or start it from an elevated session."
            }
            else {
                # The command line holds the staged copy's path and the file name, not the folder
                # ScriptPath is in, so moving the file would not help.
                Write-ErrorMessage "The command that starts $ScriptPath elevated is too long, because the file name or this account's %TEMP% path ($([System.IO.Path]::GetTempPath())) is long. Give the file a shorter name, or start it from an elevated session."
            }
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }

        # The PowerShell 7 bootstrap's relaunch-loop guard (Invoke-PowerShell7Bootstrap) is set in
        # this process's environment. The elevated Windows PowerShell legitimately enters that
        # bootstrap, so it must not inherit the guard, however Windows builds an elevated process's
        # environment.
        Remove-Item -Path Env:\WINGET_APP_SETUP_PS7_BOOTSTRAP -ErrorAction SilentlyContinue

        Write-Info 'Approve the administrator (UAC) prompt. The run continues in a new, elevated Windows PowerShell window, and this window waits for it to finish.'
        $process = $null
        try {
            $process = Start-ElevatedProcess -FilePath $powerShellPath -ArgumentString $argumentString
        }
        catch {
            if ((Get-NativeErrorCode -Exception $_.Exception) -eq 1223) {
                # ERROR_CANCELLED: the UAC prompt was declined. Reported once; no second prompt.
                Write-ErrorMessage 'The administrator (UAC) prompt was declined, so no elevated run was started. Run it again and approve the prompt, or start it from an elevated session.'
            }
            else {
                Write-ErrorMessage "Could not start an elevated Windows PowerShell ($powerShellPath): $($_.Exception.Message)"
            }
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }
        if (-not $process) {
            Write-ErrorMessage 'An elevated Windows PowerShell was requested, but Windows returned no process to wait for, so its outcome is unknown. Check the elevated window and its log.'
            return [pscustomobject]@{ Started = $true; ExitCode = 5 }
        }

        # Short waits in a loop rather than one WaitForExit(): Ctrl+C in this window is handled
        # between statements, never during a blocking .NET call.
        while (-not $process.WaitForExit(1000)) {
        }
        $exitCode = [int]$process.ExitCode
        Write-Info "The elevated run ended with exit code $exitCode."
        return [pscustomobject]@{ Started = $true; ExitCode = $exitCode }
    }
    finally {
        # The elevated process made its own copy, and it has ended (or never started).
        if ($stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Install ---
<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
.PARAMETER NonInteractive
    Suppresses the interactive extras for unattended runs (RMM, CI, scheduled tasks): the summary
    grid-view window and the final "press any key to exit". Also auto-detected when the session is
    non-interactive or stdin is redirected. No path asks a yes/no question anymore (issue #230), so
    this switch is not needed to keep a run from blocking on a prompt. A non-interactive run that is
    not elevated returns 4 instead of raising a UAC prompt that nobody would answer (review finding
    P2-12).
.PARAMETER SkipSystemCheck
    Pass-through of the entry script's -SkipSystemCheck switch. Used only so an elevated relaunch
    inherits the caller's intent to bypass the pre-flight system checks (issue #185); the checks
    themselves run in the entry script before this function is called.
.PARAMETER Apps
    App-definition hashtables to install. Defaults to the curated catalog returned by
    Get-DefaultAppCatalog — the single source of truth shared with winget-app-uninstall.ps1
    (issue #190). Overridable so tests (and callers) can inject a custom catalog.
.OUTPUTS
    [int] The run's exit code. The function never ends the process itself: the generated entry
    script (build/fragments/tail.ps1) exits with the returned code, so every path here can be
    driven from a test and asserted on its result.
.NOTES
    Exit codes: 0 = success, 1 = one or more apps failed to install (including the apps marked
    failed when winget could no longer be launched mid-run), 2 = winget unavailable (at the start,
    where `winget --version` must run and print a version, or Group Policy turns winget or its
    source off; or no longer launchable at the end of the run), 3 = app-definition validation
    failed or no valid apps remain, 4 = administrator rights
    are required and the run was not elevated: the UAC prompt was declined or could not be shown, a
    non-interactive run (nobody to approve a prompt, so none is shown), irm | iex, or the imported
    module (review finding P2-12), 3010 = success, but a restart is required to finish (an install
    said so, or Windows gained a pending restart during the run; review finding P3-16). At the end
    of a run the precedence is 1 > 2 > 3010 > 0 (Get-InstallerExitCode). Apps reported as Deferred
    (a run as SYSTEM or under cross-user elevation found no machine-wide installer for them) count
    neither as installed nor as failed and do not change the code. A run as SYSTEM returns 2 at the
    start when no machine-wide winget.exe can be started. A run that relaunched
    itself elevated returns the elevated run's exit code (Restart-WithElevation waits for it). The
    generated entry script also exits 1 when a blocking pre-flight check fails (before this
    function runs) and 5 when the run was aborted by an unexpected error or stopped from outside.
#>
function Invoke-WingetInstall {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,

        [Parameter(Mandatory = $false)]
        [array]$Apps = (Get-DefaultAppCatalog)
    )

    # Effective non-interactive mode: explicit switch, a non-interactive session (e.g. service,
    # scheduled task, pwsh -NonInteractive), or redirected stdin (piped/irm|iex wrappers).
    # Shared private helper (issue #214) — Test-SystemRequirements gates its disk-space prompt
    # on the same detection.
    $effectiveNonInteractive = Test-EffectiveNonInteractive -NonInteractive:$NonInteractive

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    # Test-IsAdmin (Public/Elevation.ps1, issue #239) wraps the WindowsPrincipal/IsInRole check
    # behind a mockable command, so tests can drive the non-admin branch below deterministically
    # instead of only when Pester itself happens to run non-elevated. It also fails safe (assumes
    # elevated) if the underlying check throws — see its own docstring for why that direction is
    # the right one for this call site specifically.
    $isAdmin = Test-IsAdmin

    # Check if the script is run as administrator. The $WhatIf gate is checked once here, for
    # both execution contexts below, rather than duplicated per-branch: a dry run makes no system
    # changes, so it never needs elevation or an elevation-required exit — only which preview
    # message to print depends on how this script is being run. Every run that cannot go on without
    # administrator rights returns 4 (review finding P2-12).
    If (-NOT $isAdmin) {
        if ($WhatIf) {
            if (-not (Test-IsRunningLocally)) {
                # IEX/remote execution has no local script path to relaunch from, but that's
                # irrelevant to a preview: same rationale as the local-file case below.
                Write-Info '[DRY-RUN] Would require administrator privileges for a real run (auto-elevation is unavailable when running through IEX/remote execution). Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            elseif ($effectiveNonInteractive) {
                # A real run stops here with 4 (review finding P2-12); the preview says so.
                Write-Info '[DRY-RUN] A real run would stop here with exit code 4: it needs administrator privileges, and a non-interactive run shows no UAC prompt. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                # Relaunching elevated here would (a) be a surprising side effect for a preview
                # and (b) — if the flag were ever dropped across the elevation boundary —
                # silently turn a dry run into a real install. Stay in the current session and
                # continue the preview.
                Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
        }
        elseif (-not (Test-IsRunningLocally)) {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            # No 'Exiting in 5 seconds' sleep any more: the entry script's Exit-Installer prints the
            # log path and build id and, when someone is at the console, waits for a key press
            # before the window closes (review finding P2-14).
            return 4
        }
        elseif (Test-InvokedFromModuleContext -InvocationModule $MyInvocation.MyCommand.Module -CommandPath $PSCommandPath) {
            # Elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the
            # imported (or dot-sourced) module, that path is WingetAppSetup/Public/Install.ps1 —
            # a functions-only file — so the elevated window would define a function and exit
            # without installing anything (issue #185). Fail fast with guidance instead.
            Write-ErrorMessage 'Invoke-WingetInstall was invoked from the imported module without elevation; auto-elevation cannot relaunch a module function. Run winget-app-install.ps1, or start from an already-elevated session.'
            return 4
        }
        elseif ($effectiveNonInteractive) {
            # Nobody is there to approve a UAC prompt (review finding P2-12): an RMM job or a
            # scheduled task running as a standard user used to raise one on the user's desktop and
            # exit 0 within seconds, with nothing installed.
            Write-ErrorMessage 'This script requires administrator privileges, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM (for example from an RMM tool).'
            return 4
        }
        else {
            # No winget call before elevating: the elevated run sets winget up for the account it
            # runs as (Initialize-Winget). A source update here set up the signed-in user's source,
            # which under cross-user elevation is not the account that installs, and was a fourth
            # source probe in the run (review finding P3-25).
            #
            # No "press Enter to elevate" pause (issue #230): the UAC dialog the relaunch raises is
            # the actual consent gate.
            Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
            # Forward the caller's switches so the elevated run inherits the same intent:
            # -SkipSystemCheck so the pre-flight checks the caller explicitly bypassed are not re-run
            # (issue #185); -WhatIf as a safety net so a dry run could never escalate into changes
            # (unreachable today — a dry run never relaunches — but kept so the forwarding stays
            # correct if that ever changes). -NonInteractive is never forwarded: a non-interactive
            # run returned 4 above.
            $elevationArgs = @()
            if ($WhatIf) { $elevationArgs += '-WhatIf' }
            if ($SkipSystemCheck) { $elevationArgs += '-SkipSystemCheck' }
            # Waits for the elevated window and returns its exit code (review finding P2-12), and
            # runs only a checked copy of this file (P3-11): $script:InstallerScriptSha256 is the
            # file's SHA256 taken by the entry script when this run started.
            $elevation = Restart-WithElevation -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs -ExpectedSha256 $script:InstallerScriptSha256
            if (-not $elevation.Started) {
                # Restart-WithElevation has said why and what to do: a declined prompt, a file that
                # changed (5) or a command line too long all differ, and only the first had a prompt.
                Write-ErrorMessage 'No elevated run was started, so nothing was installed.'
                return [int]$elevation.ExitCode
            }
            # The elevated window showed the run's summary, or why it stopped, and waited for a key
            # press itself: recorded so the entry script exits with this code without a second
            # notice and key press here.
            $script:InstallerPendingExitCode = [int]$elevation.ExitCode
            return [int]$elevation.ExitCode
        }
    }
    else {
        Write-Success 'Starting...'
    }

    # Who this run installs as (review findings P2-24, P3-22, P3-23), decided once: SYSTEM, as under
    # an RMM agent such as Endpoint Central, or an admin account elevating on a signed-in user's PC.
    # Either way the run installs for the whole PC only, so an app whose package has no machine-wide
    # installer is deferred instead of being installed for the wrong account. A SYSTEM run uses the
    # machine-wide winget.exe (Initialize-Winget finds it), which Resolve-WingetExecutable
    # returns from then on; a stale path from an earlier run in this session is dropped first.
    $script:MachineWingetPath = $null
    $account = Get-InstallAccountContext
    $machineWide = [bool]($account.IsSystem -or $account.IsCrossUserElevation)
    if ($account.IsSystem) {
        Write-Info 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only, with the winget.exe that App Installer installed for this PC. An app with no machine-wide installer is not installed: it is reported as Deferred, with how it can still be installed for the user. Microsoft does not support the winget command line as SYSTEM, so a SYSTEM run can fail where a run as a user would not.'
    }

    # Pending restart before the run (review finding P3-16), read before this run changes the
    # machine: the end of the run compares against it, so a restart that this run's installs need
    # (exit code 3010) is told apart from one that was already pending, which is reported but does
    # not make the run 3010 by itself. Read-only, so a dry run reports it too.
    $restartStateBefore = $null
    try {
        $restartStateBefore = Get-PendingRestartState
    }
    catch {
        Write-WarningMessage "Could not check whether a restart is pending: $_"
    }
    $restartPendingBefore = @(Get-PendingRestartReason -State $restartStateBefore)
    if ($restartPendingBefore.Count -gt 0) {
        Write-WarningMessage ('A restart is already pending on this PC ({0}). An installer that needs a restart first fails with 0x8A15010A; if one does, restart this PC and re-run the installer.' -f ($restartPendingBefore -join '; '))
    }

    # Let a Winget-AutoUpdate run that is already in progress finish first (bounded): it
    # re-provisions App Installer, resets winget's sources and runs MSI upgrades, and racing it makes
    # healthy apps fail with launch errors or 'another installation is in progress'. Read-only, but
    # skipped in a dry run so a preview never waits.
    if (-not $WhatIf) {
        [void](Wait-WauIdle)
    }

    # Make winget usable for the account this run installs as: one probe, classify, fix ladder
    # (review finding P3-25; as SYSTEM it finds the machine-wide winget.exe, P2-24). It stops the run
    # with exit code 2 when winget cannot be started or Group Policy turns it off. A dry run only
    # probes (P2-16) and carries on whatever it finds: a real run would set winget up first, so
    # stopping here would misreport the very machine a dry run previews (cross-user elevation,
    # issue #265).
    $winget = Initialize-Winget -WhatIf:$WhatIf -AccountContext $account
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable -and -not $WhatIf) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        return 2
    }

    if (-not (Test-AndInstallGraphicalTools -WhatIf:$WhatIf) -and -not $WhatIf) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Migrate away from the old homegrown scheduled-update task if a prior version installed one;
    # ongoing updates are now handled by Winget-AutoUpdate, set up after the app installs (issue #168).
    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

    # Note: earlier versions added the script's own directory (often Downloads/) to the persistent
    # User PATH here for the homegrown updater. The updater is gone (#168) and a user-writable
    # directory on the PATH of an elevating account is a hijack surface, so no PATH changes are
    # made anymore (issue #179).

    # The curated app list lives in Get-DefaultAppCatalog (issue #190) — the single source of
    # truth shared with winget-app-uninstall.ps1. It arrives here through the -Apps parameter,
    # which defaults to that catalog and lets tests inject a custom one.
    $apps = $Apps

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'No valid application definitions found. Resolve the errors and re-run the script.'
        return 3
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        return 3
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    if (-not $wingetAvailable) {
        # Only a dry run gets here without winget: its per-app `winget list` checks cannot run, so
        # each one reports the app as not installed.
        $wingetScope = 'for this account'
        if ($account.IsSystem) {
            $wingetScope = 'machine-wide'
        }
        Write-Info "[DRY-RUN] winget is not available $wingetScope, so this preview cannot tell which apps are already installed: every app that applies to this machine is listed as one a real run would install."
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()
    # Apps with no machine-wide installer in a run for the whole PC (review finding P3-22): neither
    # installed nor failed, and left for the signed-in user's own account (Write-DeferredAppsSummary).
    $deferredApps = @()

    # No separate source-trust pass here: only the winget community source is used (every install
    # forces --source winget), and Initialize-Winget above already updated it, and repaired it if
    # needed (issues #172, #177).

    # Run-level circuit breaker (review findings P2-8, P2-10). Set once an app could not launch
    # winget and a follow-up check (Invoke-WingetLaunchCircuitBreaker) found that winget still
    # cannot be started: every remaining app then fails at once with one reason, and the retry
    # pass is skipped. Without it, each app spent its own launch retries, twice, on a winget that
    # was not coming back (about 24 minutes before the run reported failure).
    $wingetNotLaunchable = $false

    # Run-level budget for waiting on another installation (review finding P2-15): an app whose
    # install finds Windows Installer busy (0x8A150102, msiexec 1618) waits for it and retries, and
    # every wait comes out of these 10 minutes, the Winget-AutoUpdate msiexec's included. Once it
    # is spent, a busy result fails at once with its reason, so a machine that stays busy costs the
    # run 10 minutes at most rather than 10 minutes per app.
    $installerBusyWaitSecondsLeft = 600

    # Apps whose install finished but needs a restart to complete (review finding P3-16). Apps whose
    # installer cannot run until Windows restarts (0x8A15010A) are failed apps marked RestartFirst.
    $restartRequiredApps = @()

    # Each app's catalog condition is evaluated once per run, here, before this run changes the
    # machine, and both passes use that verdict (review finding P3-34). The two passes used to
    # evaluate it separately, and Set-WindowsTerminalDefaults (between them) writes the
    # default-terminal values the Windows Terminal condition reads, so an app the first pass
    # attempted could come back 'not applicable' in the retry pass and be counted as installed.
    # Fail open: a condition with no answer counts as applicable (Test-AppApplicability).
    $applicableByName = @{}
    foreach ($app in $apps) {
        $applicableByName[$app.name] = Test-AppApplicability -App $app
    }

    Foreach ($app in $apps) {
        $outcome = $null
        try {
            # Shared per-app pipeline — pre-check, dispatch, post-verify (issue #188). Messages,
            # summary bucketing, and exit-code policy stay here in the orchestrator.
            # -Silent: an unattended run installs MSI packages with /quiet, not /passive.
            $outcome = Install-AppWithVerification -App $app -Applicable $applicableByName[$app.name] -Silent:$effectiveNonInteractive -WhatIf:$WhatIf -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
            if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
            }

            switch ($outcome.Status) {
                'Skipped' {
                    if ($outcome.SkipReason -eq 'NotApplicable') {
                        # Applicability-gated skip (issue #217): the app's catalog condition
                        # evaluated falsy on this machine (e.g. Dell Command Update on non-Dell
                        # hardware). Same summary bucket as an already-installed skip, but the
                        # message carries the condition's human-readable reason.
                        $conditionText = if ($app.conditionDescription) { $app.conditionDescription } else { 'condition not met' }
                        Write-WarningMessage "Skipping: $($app.name) (not applicable: $conditionText)"
                    }
                    elseif ($outcome.SkipReason -eq 'Provisioned') {
                        # A run for the whole PC read it from the machine (review finding P3-24).
                        Write-WarningMessage "Skipping: $($app.name) (already provisioned for every user on this PC)"
                    }
                    else {
                        Write-WarningMessage "Skipping: $($app.name) (already installed)"
                    }
                    $skippedApps += $app.name
                }
                'Deferred' {
                    # No machine-wide installer, and this run installs for the whole PC only
                    # (review finding P3-22). Write-DeferredAppsSummary says what can install it.
                    Write-WarningMessage "Deferred: $($app.name) (winget found no machine-wide installer for it)"
                    $deferredApps += $app.name
                }
                'Installed' {
                    if ($WhatIf) {
                        Write-Info "[DRY-RUN] Would install: $($app.name)"
                    }
                    else {
                        Write-Success "Successfully installed: $($app.name)"
                        # A restart that finishes the install, or a non-zero winget exit code
                        # behind an app that is installed anyway (review finding P3-16).
                        if (Write-InstalledAppNote -AppName $app.name -InstallResult $outcome.InstallResult) {
                            $restartRequiredApps += $app.name
                        }
                    }
                    $installedApps += $app.name
                }
                default {
                    # Surface the diagnostic detail the install pipeline already returns (winget
                    # exit code, attempts, scope fallback) instead of discarding it (issue #189).
                    $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult -LaunchError $outcome.LaunchError -CheckExitCode $outcome.CheckExitCode
                    switch ($outcome.FailureReason) {
                        'PreCheckTimeout' {
                            # Failed instead of silently dropped: the app then flows through the
                            # retry pass, appears in the summary, and drives the non-zero exit
                            # code (issue #176).
                            Write-WarningMessage "Winget list timed out for $($app.name). Marking as failed; it will be retried."
                        }
                        'VerifyTimeout' {
                            Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
                        }
                        default {
                            Write-ErrorMessage "Failed to install: $($app.name) ($failureReason)."
                        }
                    }
                    # Tracked as objects, not bare names, so the failed-apps summary can render a
                    # Reason column (issue #189). RestartFirst: the installer cannot run until
                    # Windows restarts (0x8A15010A), so the retry pass leaves it alone.
                    $failedApps += @{ Name = $app.name; Reason = $failureReason; RestartFirst = (Test-RestartRequiredFirst -InstallResult $outcome.InstallResult) }
                }
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += @{ Name = $app.name; Reason = "Unexpected error: $_" }
        }

        # A dry run never launches winget beyond its read-only checks, so it never trips this.
        if (-not $WhatIf -and -not $wingetNotLaunchable -and $outcome -and (Invoke-WingetLaunchCircuitBreaker -Outcome $outcome)) {
            $wingetNotLaunchable = $true
        }
    }

    # Ongoing app updates are handled by Winget-AutoUpdate (set up below), which runs as SYSTEM on a
    # schedule — not an install-time pass that upgrades every installed app synchronously as the
    # elevating admin (that was slow, silent, and largely failed under cross-user elevation; issue #170).

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    # Best-effort and isolated: an unexpected error here must not skip the retry pass, the summary
    # or the exit-code decision below.
    try {
        Set-WindowsTerminalDefaults -WhatIf:$WhatIf
    }
    catch {
        Write-WarningMessage "Windows Terminal configuration failed unexpectedly: $_. Continuing; app installs are not affected."
    }

    # Retry any failed installations once before producing the final summary
    if ($failedApps.Count -gt 0) {
        if ($wingetNotLaunchable) {
            Write-WarningMessage 'Skipping the retry pass: winget cannot be launched on this machine (see above); retrying would not help.'
        }
        elseif (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($failedApp in $appsToRetry) {
                $appName = $failedApp.Name
                if ($failedApp.RestartFirst) {
                    # 0x8A15010A (review finding P3-16): only a restart changes it, so another try
                    # now would fail the same way.
                    Write-WarningMessage "Not retrying ${appName}: its installer cannot run until this PC restarts."
                    $failedApps += $failedApp
                    continue
                }
                $outcome = $null
                try {
                    Write-Info "Retrying: $appName"
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1

                    # Same shared pipeline as the first pass (issue #188), so a lingering
                    # 0x80073d19 session error gets its backoff retries here too (issue #150), and
                    # a busy Windows Installer gets what is left of the run's wait budget.
                    # The circuit breaker holds here too: once it trips, the rest fail at once.
                    # -Applicable: the run's verdict from before the first pass, not a new one.
                    $outcome = Install-AppWithVerification -App $appDef -Applicable $applicableByName[$appName] -Silent:$effectiveNonInteractive -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
                    if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                        $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
                    }

                    if ($outcome.Status -eq 'Failed') {
                        $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult -LaunchError $outcome.LaunchError -CheckExitCode $outcome.CheckExitCode
                        switch ($outcome.FailureReason) {
                            'PreCheckTimeout' {
                                Write-WarningMessage "Winget list timed out for retry: $appName. Assuming installation failed."
                            }
                            'VerifyTimeout' {
                                Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                            }
                            default {
                                Write-ErrorMessage "Retry failed: $appName ($failureReason)."
                            }
                        }
                        $failedApps += @{ Name = $appName; Reason = $failureReason; RestartFirst = (Test-RestartRequiredFirst -InstallResult $outcome.InstallResult) }
                    }
                    elseif ($outcome.Status -eq 'Deferred') {
                        # The retry got as far as the install, which found no machine-wide
                        # installer (review finding P3-22): deferred, not failed.
                        Write-WarningMessage "Deferred: $appName (winget found no machine-wide installer for it)"
                        $deferredApps += $appName
                    }
                    elseif ($outcome.SkipReason -eq 'NotApplicable') {
                        # Same bucket and message as the first pass (review finding P3-34): an app
                        # that does not apply was not installed, so it is never 'Retry succeeded'.
                        $conditionText = if ($appDef.conditionDescription) { $appDef.conditionDescription } else { 'condition not met' }
                        Write-WarningMessage "Skipping: $appName (not applicable: $conditionText)"
                        $skippedApps += $appName
                    }
                    else {
                        # 'Installed', or 'Skipped' when the first-pass install actually landed
                        # and only its verification failed — either way the app is present now.
                        Write-Success "Retry succeeded: $appName"
                        if ($outcome.Status -eq 'Installed' -and (Write-InstalledAppNote -AppName $appName -InstallResult $outcome.InstallResult)) {
                            $restartRequiredApps += $appName
                        }
                        $installedApps += $appName
                    }
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += @{ Name = $appName; Reason = "Unexpected error: $_" }
                }

                if (-not $wingetNotLaunchable -and $outcome -and (Invoke-WingetLaunchCircuitBreaker -Outcome $outcome)) {
                    $wingetNotLaunchable = $true
                }
            }
        }
        else {
            Write-Host ''
            Write-Info '[DRY-RUN] Would retry the following failed installations:'
            foreach ($failedApp in $failedApps) {
                Write-Info "[DRY-RUN] Would retry: $($failedApp.Name)"
            }
        }
    }

    # Set up ongoing automatic updates via Winget-AutoUpdate (issue #168). Best-effort: a failure
    # here warns but does not fail the install; the outcome is captured and surfaced next to the
    # final summary instead of being a scrolled-past warning (issue #186).
    #
    # Runs only after every winget call this run makes (the retry pass included), and WAU is no
    # longer told to start an update pass immediately (RUN_WAU=YES was removed). Every WAU SYSTEM
    # run first calls its own Install-Prerequisites, which can re-provision App Installer and reset
    # winget's sources; letting that start mid-run is what wedged winget in the #279/#284 E2E runs
    # and what killed the console in #283. WAU's own schedule takes it from here.
    try {
        $wauResult = Install-WingetAutoUpdate -WhatIf:$WhatIf -InstallInProgressWaitSeconds $installerBusyWaitSecondsLeft
    }
    catch {
        Write-ErrorMessage "Winget-AutoUpdate setup failed unexpectedly: $_"
        $wauResult = [pscustomobject]@{ Status = 'Failed'; Version = $null }
    }

    # A run must never report success while leaving winget unusable (whatever broke it, the next
    # run of this installer and every WAU update would fail). One bounded launch check, after the
    # last thing this run does to the machine; a healthy winget answers on the first try. Up to
    # five tries 15 seconds apart (about a minute) for a failure that may clear on its own, and a
    # single one when the circuit breaker already found winget unusable. Skipped in a dry run,
    # which never touched winget's state.
    $wingetUsableAtEnd = $true
    $endCheckReason = $null
    if (-not $WhatIf) {
        try {
            $endCheckAttempts = 5
            if ($wingetNotLaunchable) {
                $endCheckAttempts = 1
            }
            $endCheck = Test-WingetLaunchable -Attempts $endCheckAttempts -RetryDelaySeconds 15
            $wingetUsableAtEnd = [bool]$endCheck.Launchable
            # Why, for the NOT USABLE line: a failure that is final at once ('Access is denied',
            # winget missing) prints no retry warning and has no winget output to show.
            $endCheckReason = $endCheck.Reason
        }
        catch {
            # A bug in the probe is not evidence that winget is broken; report it and move on.
            Write-WarningMessage "Could not run the end-of-run winget check: $_"
        }
    }

    # Does this run need a restart to finish (review finding P3-16)? An install said so, the
    # Winget-AutoUpdate MSI returned 3010, or Windows gained a pending restart during the run (for
    # example an Inno or MSI installer queued a file replacement for the next restart, which winget
    # does not report). A restart that was already pending before the run is not this run's.
    # Skipped in a dry run, which installed nothing.
    $restartReasons = @()
    if ($restartRequiredApps.Count -gt 0) {
        $restartReasons += ('{0} reported that a restart finishes the installation' -f ($restartRequiredApps -join ', '))
    }
    if ($wauResult -and $wauResult.RestartRequired) {
        $restartReasons += 'the Winget-AutoUpdate installer reported that a restart finishes the installation'
    }
    if (-not $WhatIf -and $null -ne $restartStateBefore) {
        try {
            $restartReasons += @(Get-PendingRestartReason -State (Get-PendingRestartState) -Since $restartStateBefore)
        }
        catch {
            Write-WarningMessage "Could not check whether a restart is pending after the run: $_"
        }
    }
    $restartRequired = $restartReasons.Count -gt 0
    $restartFirstApps = @($failedApps | Where-Object { $_.RestartFirst } | ForEach-Object { $_.Name })

    # Display the summary of the installation
    if ($WhatIf) {
        Write-Host ''
        Write-Info '=== DRY-RUN SUMMARY ==='
        Write-Info 'The following actions would have been performed:'
    }
    else {
        Write-Info 'Summary:'
    }

    $headers = @('Status', 'Apps')
    $rows = @()

    $appList = Format-AppList -AppArray $installedApps
    if ($appList) {
        $rows += , @('Installed', $appList)
    }

    $appList = Format-AppList -AppArray $skippedApps
    if ($appList) {
        $rows += , @('Skipped', $appList)
    }

    $appList = Format-AppList -AppArray $deferredApps
    if ($appList) {
        $rows += , @('Deferred', $appList)
    }

    $failedAppNames = @($failedApps | ForEach-Object { $_.Name })
    $appList = Format-AppList -AppArray $failedAppNames
    if ($appList) {
        $rows += , @('Failed', $appList)
    }

    # -AutoGridView opens the grid view without asking (issue #230), gated on the session actually
    # being interactive so an unattended run never leaves a window open with nobody to close it.
    # The text table prints either way, so the transcript keeps the summary regardless.
    Write-Table -Headers $headers -Rows $rows -AutoGridView (-not $effectiveNonInteractive) -Title 'Installation Summary'

    # Per-app failure reasons (issue #189): winget exit code, attempt count, and scope-fallback
    # detail, so a failure is diagnosable from the summary (and the transcript) instead of a
    # generic message. No-ops when nothing failed.
    Write-FailedAppsSummary -FailedApps $failedApps

    # Why apps were deferred, and who can install them (review findings P3-22, P3-23). They do not
    # change the exit code.
    Write-DeferredAppsSummary -DeferredApps $deferredApps -AccountContext $account

    # Surface the auto-update outcome with the summary so a machine that finished without an update
    # mechanism is visible at the end of the run (issue #186). Deliberately does not affect the exit
    # code: the documented 0/1/2/3 contract stays scoped to app installs and winget availability.
    switch ($wauResult.Status) {
        'Configured' { Write-Success "Auto-updates: Configured (Winget-AutoUpdate v$($wauResult.Version))." }
        'AlreadyPresent' {
            if ($wauResult.FrameworkMissing) {
                Write-ErrorMessage 'Auto-updates: AT RISK - Winget-AutoUpdate is installed but Microsoft.WindowsAppRuntime.1.8 is missing; its next run may leave winget unusable (see above).'
            }
            elseif ($wauResult.Version) {
                Write-Success "Auto-updates: Already present (v$($wauResult.Version))."
            }
            else {
                Write-WarningMessage 'Auto-updates: Already present (installed version could not be determined).'
            }
        }
        'DryRun' { Write-Info "[DRY-RUN] Auto-updates: Would configure Winget-AutoUpdate v$($wauResult.Version)." }
        'FrameworkMissing' { Write-ErrorMessage 'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it. Install the Windows App Runtime 1.8 (or let the Microsoft Store update App Installer), then re-run the installer.' }
        default { Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.' }
    }

    if (-not $wingetUsableAtEnd) {
        $endCheckDetail = ''
        if (-not [string]::IsNullOrWhiteSpace($endCheckReason)) {
            $endCheckDetail = " ($endCheckReason)"
        }
        Write-ErrorMessage "winget: NOT USABLE - winget did not work at the end of this run$endCheckDetail, so automatic updates and the next run of this installer will fail on this machine. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
    }

    # Restart (review finding P3-16): a run whose installs need a restart says so here and exits
    # 3010 when nothing failed; apps whose installer needs a restart first are named; a restart
    # that was pending before the run is reported, nothing more.
    if ($restartFirstApps.Count -gt 0) {
        Write-ErrorMessage ('Restart: REQUIRED before {0} can install - restart this PC, then re-run the installer.' -f ($restartFirstApps -join ', '))
    }
    if ($restartRequired) {
        Write-WarningMessage ('Restart: REQUIRED to finish this run - restart this PC before it is used ({0}).' -f ($restartReasons -join '; '))
    }
    elseif ($restartPendingBefore.Count -gt 0 -and $restartFirstApps.Count -eq 0) {
        Write-WarningMessage ('Restart: already pending before this run ({0}) - restart this PC when you can.' -f ($restartPendingBefore -join '; '))
    }

    # Repeat the persistent transcript path next to the summary (issue #189). The variable is set
    # by the generated installer's entry script before dispatch; it is unset (and this is skipped)
    # when the function runs outside that context (module import, tests) or the transcript could
    # not be started.
    if ($script:InstallLogPath) {
        Write-Info "Full transcript of this run: $script:InstallLogPath"
    }

    $exitCode = Get-InstallerExitCode -FailedAppCount $failedApps.Count -WingetUsable $wingetUsableAtEnd -RestartRequired $restartRequired
    # Recorded before the final prompt: Ctrl+C there stops a run that has already finished, and
    # the entry script's abort guard then reports this code instead of an abort (5).
    $script:InstallerPendingExitCode = $exitCode

    # Keep the console window open until the user presses a key. Skipped in non-interactive mode
    # so unattended runs never block.
    if (-not $effectiveNonInteractive) {
        Write-Prompt 'Press any key to exit...'
        [void][System.Console]::ReadKey($true)
    }

    return $exitCode
}

# --- Logging ---
<#
.SYNOPSIS
    Writes an informational message in blue color.
.DESCRIPTION
    Helper function for consistent informational and action messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Info {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Writes a success message in green color.
.DESCRIPTION
    Helper function for consistent success messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Success {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Green
}

<#
.SYNOPSIS
    Writes a warning message in yellow color.
.DESCRIPTION
    Helper function for consistent warning and skip messages throughout the script.
    Named Write-WarningMessage to avoid conflict with built-in Write-Warning cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-WarningMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Yellow
}

<#
.SYNOPSIS
    Writes an error message in red color.
.DESCRIPTION
    Helper function for consistent error messages throughout the script.
    Named Write-ErrorMessage to avoid conflict with built-in Write-Error cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Red
}

<#
.SYNOPSIS
    Formats an array of app names for display in the summary table.
.DESCRIPTION
    This function checks if an array has content and formats it as a comma-separated string.
.PARAMETER AppArray
    The array of app names to format
.RETURNS
    A formatted string of app names, or $null if the array is empty
#>
function Format-AppList {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$AppArray
    )

    if ($AppArray -and $AppArray.Count -gt 0) {
        return $AppArray -join ', '
    }
    return $null
}

<#
.SYNOPSIS
    Displays a formatted table of results, and optionally also in an interactive GUI view.
.DESCRIPTION
    Always renders the summary as text via PowerShell's built-in Format-Table, then additionally
    opens Out-GridView when a caller asked for it and the session can show one.

    The grid view is never offered as a question (issue #230): it used to be a Read-Host that
    stalled the documented one-liner, so -AutoGridView now just opens it. Text output is
    unconditional for the same reason — the grid view renders in its own window and is never
    captured by Start-Transcript, so returning early once it opened would drop the summary from
    the log of every interactive run.
.PARAMETER Headers
    Array of column header names
.PARAMETER Rows
    Array of row data (each row is an array matching the header count)
.PARAMETER UseGridView
    Caller explicitly wants the grid view. Warns when Out-GridView is unavailable.
.PARAMETER AutoGridView
    Open the grid view whenever the session can show one, silently doing nothing when it cannot.
    Callers pass the session's effective interactivity here, so an unattended run never opens a
    window that nothing is around to close. (Formerly -PromptForGridView, which asked first.)
#>
function Write-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[][]]$Rows,
        [Parameter(Mandatory = $false)]
        [bool]$UseGridView = $false,
        [Parameter(Mandatory = $false)]
        [bool]$AutoGridView = $false,
        [Parameter(Mandatory = $false)]
        [string]$Title = 'Summary'
    )

    # Convert rows to objects for Format-Table
    $tableData = @()
    foreach ($row in $Rows) {
        $obj = New-Object PSObject
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $obj | Add-Member -MemberType NoteProperty -Name $Headers[$i] -Value $row[$i]
        }
        $tableData += $obj
    }

    # Text output first, unconditionally: Out-GridView is a window, not console output, so it is
    # never transcribed (issue #230).
    # An explicit width (review finding P3-13): without one, Out-String uses the console width, so a
    # transcript or captured output (120 columns on a runner or an RMM agent) cut long rows off with
    # an ellipsis - the failed-app list and its reasons, the very text a failure report needs - and a
    # process with no console at all rendered an empty table. Lines are not padded to this width.
    $output = $tableData | Format-Table -AutoSize -Wrap | Out-String -Width 4096
    Write-Host $output.TrimEnd()

    if (-not ($UseGridView -or $AutoGridView)) {
        return
    }

    if (-not (Test-CanUseGridView)) {
        # Only an explicit -UseGridView deserves a warning. -AutoGridView is an offer, not a
        # request: on a session that cannot show a window, having no window is the right outcome
        # and not worth a line of noise.
        if ($UseGridView) {
            Write-WarningMessage 'Out-GridView is not available. The results are in the text summary above.'
        }
        return
    }

    try {
        $tableData | Out-GridView -Title $Title -Wait
    }
    catch {
        Write-WarningMessage "Failed to display grid view: $_. The results are in the text summary above."
    }
}

# --- SystemChecks ---
<#
.SYNOPSIS
    Runs pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044, non-blocking), warns when C: has less than
    50 GB free (measured only — an unreadable drive reports UNKNOWN and stays quiet), and blocks
    when cdn.winget.microsoft.com is unreachable over HTTPS (network is required for winget). The
    network probe uses Invoke-WebRequest, which honors system proxy settings; any HTTP response —
    including 4xx/5xx — counts as reachable, and only a transport-level failure (no response at
    all) blocks.

    Nothing here prompts (issue #230): the only blocking check is the network probe, whose verdict
    is not a matter of opinion, so the sole return-$false path is a genuine failure rather than a
    declined question. Low disk warns and proceeds. That is also why this function has no
    -NonInteractive parameter — with the prompt gone there is no interactive behavior left to
    suppress (it previously gated the low-disk Read-Host, per issues #214/#176).
.PARAMETER WhatIf
    When specified, reports intended checks and skips the low-disk warning (a dry run makes no
    changes that could run the disk out).
.RETURNS
    [bool] True when it is safe to proceed; False when a blocking check fails.
#>
function Test-SystemRequirements {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $results = @()
    $proceed = $true

    # --- OS Version (warn only, Windows 10 21H2 = build 19044) ---
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osName = $cv.ProductName
        # Prefer the registry's CurrentBuildNumber over [Environment]::OSVersion: it is the
        # ground-truth build (never capped by the host's compatibility manifest under Windows
        # PowerShell 5.1) and, unlike the static .NET call, it is mockable in Pester. Fall back
        # to OSVersion only when the value is somehow absent.
        $build = if ($cv.CurrentBuildNumber) { [int]$cv.CurrentBuildNumber } else { [System.Environment]::OSVersion.Version.Build }
        # Windows 11 still reports ProductName "Windows 10 ..." - Microsoft never updated the
        # string, so build >= 22000 is what actually distinguishes it. Relabel so the report
        # isn't misleading (issue #221). The "Windows 10" guard leaves Windows Server (e.g.
        # "Windows Server 2025", build 26100) and an already-correct "Windows 11" untouched.
        if ($build -ge 22000 -and $osName -match 'Windows 10') {
            $osName = $osName -replace 'Windows 10', 'Windows 11'
        }
        if ($build -ge 19044) {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'OK'; Detail = $osName }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "$osName (build $build - Windows 10 21H2 or later recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "Could not determine OS version: $_" }
    }

    # --- Disk Space on C: (warn if under 50 GB) ---
    $freeGB = $null
    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $freeGB = [Math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -ge 50) {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'OK'; Detail = "${freeGB} GB free on C:" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'WARN'; Detail = "${freeGB} GB free on C: (50 GB recommended)" }
        }
    }
    catch {
        # Distinct from the low-space WARN: free space could not be measured, so the low-disk
        # warning below must not fire and claim a number it does not have ($freeGB stays $null).
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'UNKNOWN'; Detail = "Could not read C: drive: $_" }
    }

    # --- Network (blocking — required for winget) ---
    # Proxy-aware HTTPS probe: Invoke-WebRequest honors system proxy settings, unlike a raw
    # TCP test (Test-NetConnection), which false-fails on proxy-only networks (#184). Any HTTP
    # response — even 4xx/5xx — proves the CDN is reachable; only a transport-level failure
    # (no response at all) blocks.
    try {
        # -UseBasicParsing is a no-op on PowerShell 7 but prevents a false FAIL on Windows
        # PowerShell 5.1 (README launch path) when the IE parsing engine is unavailable.
        $null = Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache' -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = 'HTTPS probe of cdn.winget.microsoft.com succeeded' }
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = "cdn.winget.microsoft.com reachable (HTTP $([int]$response.StatusCode))" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = "Cannot reach cdn.winget.microsoft.com over HTTPS - network is required: $($_.Exception.Message)" }
            $proceed = $false
        }
    }

    # --- Display results ---
    Write-Host ''
    Write-Info 'Pre-flight System Checks:'
    foreach ($r in $results) {
        $icon = switch ($r.Status) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'UNKNOWN' { '[UNKNOWN]' } 'FAIL' { '[FAIL]' } }
        $msg = "$icon $($r.Check): $($r.Detail)"
        switch ($r.Status) {
            'OK' { Write-Success $msg }
            'WARN' { Write-WarningMessage $msg }
            'UNKNOWN' { Write-WarningMessage $msg }
            'FAIL' { Write-ErrorMessage $msg }
        }
    }
    Write-Host ''

    if (-not $proceed) {
        return $false
    }

    # Measured-low disk warns and continues; it never asks (issue #230). Low disk is a
    # recommendation, not a blocker, so "continue anyway?" only ever had one useful answer, and
    # asking it stalled the documented one-liner — an interactive `irm | iex` does not redirect
    # stdin, so the interactivity detection this used to branch on reported interactive and the
    # prompt fired. Silent when free space could not be measured ($freeGB stays $null) or under
    # -WhatIf, which makes no changes that could run the disk out.
    if ($null -ne $freeGB -and $freeGB -lt 50 -and -not $WhatIf) {
        Write-WarningMessage 'Disk space is below the 50 GB recommendation. Continuing anyway.'
    }

    return $true
}

# --- WindowsTerminal ---
<#
.SYNOPSIS
    Resolves the most likely Windows Terminal settings file path.
.DESCRIPTION
    Prefers the stable packaged path, then preview, then unpackaged path.
.RETURNS
    [string] Existing settings path when found; otherwise $null.
#>
function Get-WindowsTerminalSettingsPath {
    $settingsPaths = Get-WindowsTerminalSettingsPaths
    if ($settingsPaths.Count -gt 0) {
        return $settingsPaths[0]
    }

    return $null
}

<#
.SYNOPSIS
    Resolves all discovered Windows Terminal settings file paths.
.DESCRIPTION
    Includes packaged channels (stable/preview/dev/canary-style package names)
    and unpackaged path when present.
.RETURNS
    [string[]] Existing settings paths when found; otherwise an empty array.
#>
function Get-WindowsTerminalSettingsPaths {
    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )

    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -Path $packagesRoot) {
        try {
            $dynamicPaths = Get-ChildItem -Path $packagesRoot -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }

            if ($dynamicPaths) {
                $candidatePaths += $dynamicPaths
            }
        }
        catch {
            # Best-effort discovery only; keep static candidates if enumeration fails.
        }
    }

    $existingPaths = @()

    foreach ($path in $candidatePaths) {
        if (Test-Path -Path $path) {
            $existingPaths += $path
        }
    }

    return @($existingPaths | Select-Object -Unique)
}

<#
.SYNOPSIS
    Sets Windows Terminal default profile to a provided GUID.
.DESCRIPTION
    Changes only the value of the top-level "defaultProfile" in settings.json, or inserts that
    key when it is missing (Set-JsoncTopLevelStringProperty). Comments, commented-out profiles,
    formatting and key order are kept: the file used to be parsed and rewritten with
    ConvertTo-Json, which deleted all of them.

    Before anything is written, the edited text is parsed again and must have defaultProfile set
    to the new GUID and every other setting unchanged; otherwise the file is left alone. The
    original file is then copied to settings.json.winget-app-setup.bak next to it, and the new
    content is written to a temporary file in the same folder that replaces settings.json in one
    step ([System.IO.File]::Replace), so the file is never left truncated or half-written and keeps
    its attributes and ACL. A settings.json that is a symbolic or hard link is instead written in
    place, through the link, so the link survives and the linked file gets the change. A UTF-8
    byte-order mark is kept when the file has one; a file that is not valid UTF-8 is left alone.
.PARAMETER SettingsPath
    Full path to the Windows Terminal settings file.
.PARAMETER ProfileGuid
    Profile GUID to set as default. Braces are added when missing.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalDefaultProfile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileGuid
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        Write-WarningMessage "Windows Terminal settings file not found at '$SettingsPath'."
        return $false
    }

    $normalizedGuid = if ($ProfileGuid.StartsWith('{') -and $ProfileGuid.EndsWith('}')) {
        $ProfileGuid
    }
    else {
        "{$ProfileGuid}"
    }

    # The .NET file APIs below resolve a relative path against the process directory, not the
    # PowerShell location, so work with the full path.
    $fullPath = Convert-Path -LiteralPath $SettingsPath

    try {
        $originalBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $hasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF
        # Throw on invalid bytes: decoding them to U+FFFD and writing that back would corrupt the file.
        $encoding = [System.Text.UTF8Encoding]::new($hasBom, $true)
        $bomLength = if ($hasBom) { 3 } else { 0 }
        $settingsContent = $encoding.GetString($originalBytes, $bomLength, $originalBytes.Length - $bomLength)
    }
    catch {
        Write-WarningMessage "Unable to read Windows Terminal settings '$fullPath' as UTF-8: $_"
        return $false
    }

    $settingsObject = ConvertFrom-TerminalSettingsJson -JsonText $settingsContent
    if (-not $settingsObject) {
        Write-WarningMessage 'Unable to parse Windows Terminal settings.json. Skipping default profile update.'
        return $false
    }

    if ($settingsObject.defaultProfile -eq $normalizedGuid) {
        Write-Success 'Windows Terminal default profile is already set to PowerShell 7.'
        return $true
    }

    $updatedContent = Set-JsoncTopLevelStringProperty -JsonText $settingsContent -Name 'defaultProfile' -Value $normalizedGuid
    $updatedObject = if ($null -ne $updatedContent) { ConvertFrom-TerminalSettingsJson -JsonText $updatedContent }
    $isValidEdit = [bool]$updatedObject -and $updatedObject.defaultProfile -eq $normalizedGuid
    if ($isValidEdit) {
        $otherSettingsBefore = $settingsObject | Select-Object -Property * -ExcludeProperty 'defaultProfile' | ConvertTo-Json -Depth 100 -Compress
        $otherSettingsAfter = $updatedObject | Select-Object -Property * -ExcludeProperty 'defaultProfile' | ConvertTo-Json -Depth 100 -Compress
        $isValidEdit = $otherSettingsAfter -ceq $otherSettingsBefore
    }
    if (-not $isValidEdit) {
        Write-WarningMessage "Could not change only defaultProfile in '$fullPath'; the file was left unchanged."
        return $false
    }

    $backupPath = "$fullPath.winget-app-setup.bak"
    $tempPath = "$fullPath.winget-app-setup.tmp"
    try {
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force -ErrorAction Stop
        # A settings.json that is a symbolic or hard link (a dotfiles setup) is written in place,
        # through the link: replacing the name with the temp file would turn it into a separate
        # plain file and leave the linked file unedited (Windows Terminal's own save had this bug,
        # microsoft/terminal#10787). Other reparse points are written in place too.
        $settingsItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        $isLinked = [bool]$settingsItem.LinkType -or
            (($settingsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($isLinked) {
            [System.IO.File]::WriteAllText($fullPath, $updatedContent, $encoding)
        }
        else {
            [System.IO.File]::WriteAllText($tempPath, $updatedContent, $encoding)
            # [NullString]::Value: PowerShell would pass $null to the string parameter as '' (rejected).
            [System.IO.File]::Replace($tempPath, $fullPath, [NullString]::Value)
        }
    }
    catch {
        # Replace can fail after settings.json was moved aside (ERROR_UNABLE_TO_MOVE_REPLACEMENT);
        # put the original back from the backup made just before.
        if (-not (Test-Path -LiteralPath $fullPath) -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $backupPath -Destination $fullPath -ErrorAction SilentlyContinue
        }
        Write-WarningMessage "Failed to update Windows Terminal settings.json: $_"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Success "Configured Windows Terminal default profile to PowerShell 7 (previous file saved as '$backupPath')."
    return $true
}

<#
.SYNOPSIS
    Sets Windows Terminal as the default terminal application via registry.
.DESCRIPTION
    Writes DelegationConsole and DelegationTerminal values under HKCU:\Console\%%Startup.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalAsDefaultTerminalApplication {
    $registryPath = 'HKCU:\Console\%%Startup'
    $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

    try {
        if (-not (Test-Path -Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }

        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        if ($existingValues -and
            $existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal) {
            Write-Success 'Windows Terminal is already configured as the default terminal application.'
            return $true
        }

        New-ItemProperty -Path $registryPath -Name 'DelegationConsole' -PropertyType String -Value $delegationConsole -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name 'DelegationTerminal' -PropertyType String -Value $delegationTerminal -Force | Out-Null
        Write-Success 'Configured Windows Terminal as the default terminal application.'
        return $true
    }
    catch {
        Write-WarningMessage "Failed to set default terminal application in registry: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Configures Windows Terminal defaults for shell profile and terminal delegation.
.DESCRIPTION
    Applies both issue #74 requirements: PowerShell 7 default profile and Windows Terminal
    default terminal application setting.

    Both writes are strictly per-user: settings.json lives under the process account's
    %LOCALAPPDATA% and the delegation values under its HKCU hive. They are only made when that
    account is the logged-on user. The whole step is skipped, with one line, when:
      - the process runs as SYSTEM (Test-IsSystemAccount), as under an RMM agent: SYSTEM is not
        a person and has no Terminal of its own; or
      - the process account differs from the interactive session's user (the #159 detection,
        Get-ProcessUserName vs Get-InteractiveSessionUserName): a tech elevating as an admin-*
        account on a user's machine. Applying the settings there would configure the ADMIN
        account, never the user, and the delegation values in the admin's HKCU would make later
        admin sessions look Terminal-hosted to Test-WindowsTerminalHostsCurrentSession.
    When the session user is unknown (no console user reported), the step runs as before. It
    deliberately does NOT write to another user's profile or registry hive - impersonation/HKU
    writes are out of scope.

    The "default terminal application" registry write is gated on Windows Terminal actually
    being installed (Test-WindowsTerminalInstalled, issue #271). This function used to run
    unconditionally after the app-install loop regardless of whether the Microsoft.WindowsTerminal
    install had just failed, which could point HKCU:\Console\%%Startup at Windows Terminal even
    though it was never actually deployed. Once set, that delegation makes every subsequently
    created console (including a fresh top-level process such as the next CI job step) hosted by
    Windows Terminal's console component - self-locking every later attempt to install/verify
    Microsoft.WindowsTerminal via winget, since doing so would require replacing files belonging
    to the very console host rendering the session. Skipping the write when Windows Terminal is
    not installed keeps a failed install from poisoning the rest of the run (and later runs) this
    way.
.PARAMETER WhatIf
    When provided, only reports intended actions.
#>
function Set-WindowsTerminalDefaults {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # Per-user settings: only write them for the logged-on user (see the description above).
    if (Test-IsSystemAccount) {
        Write-Info 'Skipping Windows Terminal defaults: they are per-user settings, and this run is SYSTEM, not a logged-on user.'
        return
    }
    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    if ($processUser -and $sessionUser -and ($processUser -ne $sessionUser)) {
        Write-Info "Skipping Windows Terminal defaults: they are per-user settings, and this run is elevated as '$processUser' while '$sessionUser' is logged on."
        return
    }

    $powerShell7ProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $settingsPaths = @(Get-WindowsTerminalSettingsPaths)

    if ($WhatIf) {
        if ($settingsPaths.Count -gt 0) {
            Write-Info "[DRY-RUN] Would set defaultProfile to $powerShell7ProfileGuid in $($settingsPaths.Count) Windows Terminal settings file(s)"
        }
        else {
            Write-Info '[DRY-RUN] Would set Windows Terminal defaultProfile to PowerShell 7 when settings.json is available'
        }
        if (Test-WindowsTerminalInstalled) {
            Write-Info '[DRY-RUN] Would set HKCU:\Console\%%Startup DelegationConsole and DelegationTerminal to Windows Terminal values'
        }
        else {
            Write-Info '[DRY-RUN] Windows Terminal is not installed; would skip default terminal application configuration'
        }
        return
    }

    if ($settingsPaths.Count -gt 0) {
        foreach ($settingsPath in $settingsPaths) {
            [void](Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid $powerShell7ProfileGuid)
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal settings.json was not found. Skipping default profile configuration.'
    }

    # Only claim Windows Terminal as the default terminal application when it is actually
    # installed (issue #271) - see the function-level remark above for why this gate exists.
    if (Test-WindowsTerminalInstalled) {
        [void](Set-WindowsTerminalAsDefaultTerminalApplication)
    }
    else {
        Write-WarningMessage 'Windows Terminal is not installed. Skipping default terminal application configuration.'
    }
}

# --- WingetAutoUpdate ---
<#
.SYNOPSIS
    Returns the pinned Winget-AutoUpdate (WAU) release metadata.
.DESCRIPTION
    We deploy a specific, SHA256-verified WAU release rather than tracking latest, and disable WAU's
    own self-update, so an upstream change can never roll out to managed machines unreviewed. Bump
    all fields together to move to a newer WAU (verify the new SHA256 against the winget-pkgs manifest
    for that version). See issue #168. Also re-check the WindowsAppRuntime requirement in
    Get-WindowsAppRuntimeStatus (WauSupport.ps1): WAU installs the newest winget release, so the
    framework that release needs is what decides whether WAU is safe to deploy.
#>
function Get-WauPin {
    return @{
        Version     = '2.12.0'
        MsiUrl      = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi'
        Sha256      = 'F5AB2303FDF82FBFCB2248CCA4F96479FE17D74584A528B0F86B3DBE9F9E9718'
        ProductCode = '{FB0EB14E-95AC-45D7-A951-432316FFCBD4}'
    }
}

<#
.SYNOPSIS
    Returns true when Winget-AutoUpdate appears to be installed on this machine.
.DESCRIPTION
    WAU records its configuration under HKLM and registers a scheduled task 'Winget-AutoUpdate' under
    the '\WAU\' task path. Either is a reliable indicator that WAU is already set up, so the installer
    can leave an existing (possibly customized) WAU configuration untouched.
#>
function Test-WauInstalled {
    if (Test-Path 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate') {
        return $true
    }
    try {
        if (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction Stop) {
            return $true
        }
    }
    catch { }
    return $false
}

<#
.SYNOPSIS
    Installs (or upgrades) and configures Winget-AutoUpdate (WAU) to keep installed apps current.
.DESCRIPTION
    Downloads the pinned WAU MSI into an ACL-restricted staging directory (owned by Administrators,
    SYSTEM + Administrators only, checked before the download, so a non-elevated process cannot
    swap the file between hash verification and msiexec: issue #186, review finding P2-21),
    verifies its SHA256 from a handle it keeps open until msiexec has finished, and installs it
    silently with the configuration this project standardizes on (issue #168):
      - Weekly updates on Tuesdays at 02:00 (WAU's "Weekly" schedule), and not at user logon
        (UPDATESATLOGON=0): a logon run collides with a technician signing in to re-run this
        installer. WAU runs as SYSTEM for machine-scope packages and spawns a user-context task in
        the logged-on session for user-scope packages, which avoids the cross-user 0x80073d19 class
        the homegrown updater fought.
      - Only when Microsoft.WindowsAppRuntime.1.8 is present (Get-WindowsAppRuntimeStatus): every
        WAU run provisions the newest winget, which needs that framework, and would otherwise leave
        winget unusable.
      - USERCONTEXT=1 so user-scope apps update in the real interactive session.
      - DISABLEWAUAUTOUPDATE=1 so WAU stays on this pinned version until we bump it deliberately.
      - Full notifications; skip on metered connections.
    Version-aware (issue #186): because DISABLEWAUAUTOUPDATE=1 pins deployed machines, a bumped
    Get-WauPin would otherwise only ever reach brand-new installs. When WAU is present but older
    than the pin, the pinned MSI is run anyway — msiexec upgrades in place and re-applies this
    project's standard configuration — making installer re-runs the WAU upgrade vehicle. An
    equal/newer installed version, or one whose version cannot be read, is left untouched
    (configuration included).
    On a machine that already has WAU, its at-logon trigger is removed (Disable-WauLogonTrigger)
    and a missing framework is reported, but the installation is otherwise left alone.
    Best-effort: any failure warns and returns a Failed result rather than aborting the install.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, when msiexec exits 1618 because Windows Installer is busy with another
    installation (review finding P2-15): it waits for that installation (Wait-WindowsInstallerIdle)
    and retries, up to 3 times. Invoke-WingetInstall passes what is left of the run's budget.
    Default 600. 0: 1618 fails at once.
.RETURNS
    [pscustomobject] with:
      - Status:  'Configured' (installed or upgraded this run), 'AlreadyPresent' (left as-is),
                 'FrameworkMissing' (not installed: WindowsAppRuntime 1.8 is missing), 'Failed',
                 or 'DryRun' (under -WhatIf).
      - Version: the pinned version for Configured/Failed/DryRun/FrameworkMissing; the installed
                 version (or $null when unreadable) for AlreadyPresent.
      - FrameworkMissing: $true when the framework check found no suitable framework (on
                 AlreadyPresent this means the existing WAU may break winget on its next run).
      - RestartRequired: $true when msiexec returned 3010 (ERROR_SUCCESS_REBOOT_REQUIRED): WAU is
                 installed, and a restart finishes it (review finding P3-16).
#>
function Install-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600
    )

    $pin = Get-WauPin

    if ($WhatIf) {
        # Read-only probe, so the preview matches what a real run would do on this machine.
        if (Test-WauInstalled) {
            Write-Info '[DRY-RUN] Winget-AutoUpdate is already installed: would leave it in place and remove its at-logon trigger if it has one (WAU_UpdatesAtLogon = 0).'
        }
        else {
            Write-Info "[DRY-RUN] Would install Winget-AutoUpdate $($pin.Version) (weekly updates on Tuesdays at 02:00, not at logon, Full notifications, self-update disabled), if Microsoft.WindowsAppRuntime.1.8 is present."
        }
        return [pscustomobject]@{ Status = 'DryRun'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }

    $framework = Get-WindowsAppRuntimeStatus
    if ($null -eq $framework.Present) {
        # A failed query is not evidence the framework is missing; keep the previous behavior.
        Write-WarningMessage "Could not check for Microsoft.WindowsAppRuntime.1.8 ($($framework.Detail)); continuing with Winget-AutoUpdate."
    }
    $frameworkMissing = $framework.Present -eq $false

    if (Test-WauInstalled) {
        $installed = Get-InstalledWauInfo
        if ($installed.Version -and $installed.Version -lt [version]$pin.Version -and -not $frameworkMissing) {
            Write-Info "Winget-AutoUpdate v$($installed.Version) is older than the pinned v$($pin.Version); upgrading in place..."
        }
        else {
            $versionLabel = if ($installed.Version) { "v$($installed.Version)" } else { 'version unknown' }
            Write-Success "Winget-AutoUpdate is already installed ($versionLabel); leaving its configuration unchanged apart from the at-logon trigger."
            [void](Disable-WauLogonTrigger)
            if ($frameworkMissing) {
                Write-ErrorMessage "Winget-AutoUpdate is installed, but Microsoft.WindowsAppRuntime.1.8 is missing ($($framework.Detail)). Its next update run may install a winget that cannot start and leave winget unusable. Install the Windows App Runtime 1.8 (update App Installer from the Microsoft Store, or install Microsoft's Windows App SDK 1.8 runtime), or uninstall Winget-AutoUpdate on this machine."
            }
            return [pscustomobject]@{ Status = 'AlreadyPresent'; Version = $installed.Version; FrameworkMissing = $frameworkMissing; RestartRequired = $false }
        }
    }
    elseif (-not $frameworkMissing) {
        Write-Info "Setting up automatic app updates via Winget-AutoUpdate $($pin.Version)..."
    }

    if ($frameworkMissing) {
        Write-ErrorMessage "Winget-AutoUpdate was NOT installed: Microsoft.WindowsAppRuntime.1.8 is missing ($($framework.Detail)). Every WAU update run installs the newest winget, which needs that framework, so WAU would leave winget unusable here. Install the Windows App Runtime 1.8 (update App Installer from the Microsoft Store, or install Microsoft's Windows App SDK 1.8 runtime), then re-run this installer. On a newly set-up PC this usually clears once the Store has updated App Installer."
        return [pscustomobject]@{ Status = 'FrameworkMissing'; Version = $pin.Version; FrameworkMissing = $true; RestartRequired = $false }
    }

    $stagingDir = $null
    $msiStream = $null
    try {
        # Download, verify, and install from a locked-down per-run directory instead of the
        # predictable %TEMP% path a same-user non-elevated process could tamper with (issue #186).
        # Nothing is downloaded unless the folder is verifiably limited to SYSTEM and
        # Administrators (review finding P2-21).
        try {
            $stagingDir = New-WauStagingDirectory
        }
        catch {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
                Write-ErrorMessage "Winget-AutoUpdate was NOT installed: its download folder could not be limited to SYSTEM and Administrators, so its installer could have been swapped before it ran. $_ To reset the folder, run in an elevated prompt: takeown /f `"$baseDir`" /a, then icacls `"$baseDir`" /reset, and re-run this installer."
            }
            else {
                # Not an access-list problem (a file already named winget-app-setup, a full disk,
                # icacls.exe not starting): resetting the folder's owner would not help.
                Write-ErrorMessage "Winget-AutoUpdate was NOT installed: its download folder in '$baseDir' could not be set up: $_"
            }
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }
        $msiPath = Join-Path $stagingDir "WAU-$($pin.Version).msi"
        # Time-limited (review finding P2-5): without a limit, a download that connects and then
        # stalls waits for ever.
        $downloadTimeouts = Get-WebDownloadTimeoutParameters
        Invoke-WebRequest @downloadTimeouts -Uri $pin.MsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

        # Held open, with read-only sharing, from the hash until msiexec has finished (review
        # finding P2-21): while it is open the file cannot be overwritten, renamed or deleted, so
        # msiexec installs exactly the bytes hashed here. Disposed in finally, before the cleanup.
        $msiStream = Open-ReadLockedFile -Path $msiPath
        $actualHash = (Get-FileHash -InputStream $msiStream -Algorithm SHA256).Hash
        if ($actualHash -ne $pin.Sha256) {
            Write-ErrorMessage "Winget-AutoUpdate MSI hash mismatch (expected $($pin.Sha256), got $actualHash). Skipping installation."
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        # Bake the configuration in via MSI properties (the winget-package install path allows no
        # install-time customization). Single quoted-path argument string for reliable msiexec parsing.
        # No RUN_WAU=YES: an immediate WAU run starts WAU's Install-Prerequisites (App Installer
        # re-provisioning plus `winget source reset --force`) and app upgrades while this installer
        # is still running - the cause of the #279/#284 winget wedge and the #283 console stop.
        # WAU's own schedule runs the first pass instead.
        # UPDATESATLOGON=0: no at-logon run (see the function help); WAU stores it as
        # WAU_UpdatesAtLogon, which later MSI upgrades read back.
        $msiArgs = "/i `"$msiPath`" /qn /norestart UPDATESATLOGON=0 USERCONTEXT=1 DISABLEWAUAUTOUPDATE=1 UPDATESINTERVAL=Weekly UPDATESATTIME=02:00:00 NOTIFICATIONLEVEL=Full DONOTRUNONMETERED=1"
        # Time-limited (review finding P2-5): Start-Process -Wait used to wait for ever.
        $msiTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation MsiExec
        $busyRetries = 0
        $busyWaited = 0
        while ($true) {
            $msiexec = Invoke-ExternalProcess -FilePath 'msiexec.exe' -ArgumentString $msiArgs -TimeoutSeconds $msiTimeoutSeconds -Echo None
            if ($msiexec.LaunchFailed) {
                Write-ErrorMessage "Failed to install Winget-AutoUpdate: msiexec could not be started ($($msiexec.LaunchError))."
                return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
            }
            if ($msiexec.TimedOut) {
                Write-ErrorMessage ('Winget-AutoUpdate install failed: msiexec did not finish within {0} minutes and was stopped.' -f [Math]::Round($msiTimeoutSeconds / 60))
                return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
            }
            # 1618 = ERROR_INSTALL_ALREADY_RUNNING: Windows Installer is busy with another
            # installation and says so at once (review finding P2-15). Wait for it, within the
            # run's budget, and try again.
            $busyWaitLeft = $InstallInProgressWaitSeconds - $busyWaited
            if ($msiexec.ExitCode -eq 1618 -and $busyRetries -lt 3 -and $busyWaitLeft -gt 0) {
                $busyRetries++
                Write-WarningMessage ('Windows Installer is busy with another installation (msiexec exit code 1618). Waiting for it to finish (at most {0} seconds) before retry {1} of 3 of the Winget-AutoUpdate install...' -f $busyWaitLeft, $busyRetries)
                $wait = Wait-WindowsInstallerIdle -MaximumSeconds $busyWaitLeft
                $busyWaited += [int]$wait.WaitedSeconds
                continue
            }
            break
        }

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED: installed, and a restart finishes it (P3-16).
        if ($msiexec.ExitCode -eq 0 -or $msiexec.ExitCode -eq 3010) {
            $restartRequired = $msiexec.ExitCode -eq 3010
            Write-Success "Winget-AutoUpdate $($pin.Version) installed. Apps will update weekly, on Tuesdays at 02:00 (or soon after the next start if the machine was off)."
            if ($restartRequired) {
                Write-WarningMessage 'The Winget-AutoUpdate installer reported that a restart finishes the installation (msiexec exit code 3010).'
            }
            return [pscustomobject]@{ Status = 'Configured'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $restartRequired }
        }

        if ($msiexec.ExitCode -eq 1618) {
            Write-ErrorMessage ('Winget-AutoUpdate install failed: Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting (msiexec exit code 1618). Re-run the installer once that installation has finished.' -f $busyRetries, $busyWaited)
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        Write-ErrorMessage "Winget-AutoUpdate install failed (msiexec exit code $($msiexec.ExitCode))."
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }
    catch {
        Write-ErrorMessage "Failed to install Winget-AutoUpdate: $_"
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }
    finally {
        # Close the MSI first: the open handle refuses deletion, so the cleanup would fail.
        if ($msiStream) {
            $msiStream.Dispose()
        }
        if ($stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Uninstalls Winget-AutoUpdate (WAU) via the MSI product code of the installed version.
.DESCRIPTION
    Resolves the ProductCode of the WAU actually installed from its uninstall registry entry
    (issue #186): every MSI version of WAU has its own ProductCode, so uninstalling with only the
    pinned code makes msiexec exit 1605 ('unknown product') against any other installed version and
    leaves WAU in place. Falls back to the pinned ProductCode when the registry lookup finds none.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when WAU was removed (or was not installed), otherwise False.
#>
function Uninstall-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if (-not (Test-WauInstalled)) {
        Write-WarningMessage 'Winget-AutoUpdate is not installed; nothing to remove.'
        return $true
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would uninstall Winget-AutoUpdate.'
        return $true
    }

    $productCode = (Get-InstalledWauInfo).ProductCode
    if (-not $productCode) {
        $productCode = (Get-WauPin).ProductCode
    }
    Write-Info 'Uninstalling Winget-AutoUpdate...'
    $msiexec = Invoke-ExternalProcess -FilePath 'msiexec.exe' -ArgumentString "/x $productCode /qn /norestart" -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation MsiExec) -Echo None
    if ($msiexec.LaunchFailed) {
        Write-ErrorMessage "Winget-AutoUpdate uninstall failed: msiexec could not be started ($($msiexec.LaunchError))."
        return $false
    }
    if ($msiexec.TimedOut) {
        Write-ErrorMessage 'Winget-AutoUpdate uninstall failed: msiexec did not finish in time and was stopped.'
        return $false
    }

    if ($msiexec.ExitCode -eq 0 -or $msiexec.ExitCode -eq 3010) {
        Write-Success 'Winget-AutoUpdate uninstalled.'
        return $true
    }

    Write-ErrorMessage "Winget-AutoUpdate uninstall failed (msiexec exit code $($msiexec.ExitCode))."
    return $false
}

<#
.SYNOPSIS
    Removes the legacy homegrown scheduled-update task and its %APPDATA% data.
.DESCRIPTION
    Auto-updates are now handled by Winget-AutoUpdate (issue #168). Earlier versions registered a
    Windows scheduled task 'WingetAppSetup-ScheduledUpdates' (under '\winget-app-setup\') that ran a
    helper deployed to %APPDATA%\winget-app-setup — a helper that self-downloads from the repo and
    would break once removed. This migration unregisters that task and deletes the data directory so
    already-deployed machines transition cleanly. Safe to call when nothing is present (no-op).
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when something was removed, otherwise False.
#>
function Remove-LegacyScheduledUpdates {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'
    $appDataDir = Join-Path $env:APPDATA 'winget-app-setup'
    $removed = $false

    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    }
    catch {
        $task = $null
    }
    if ($task) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy scheduled task '$taskPath$taskName'."
        }
        else {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            Write-Info 'Removed the legacy scheduled-update task (updates are now handled by Winget-AutoUpdate).'
        }
        $removed = $true
    }

    if (Test-Path $appDataDir) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy update data directory '$appDataDir'."
        }
        else {
            Remove-Item -Path $appDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $removed = $true
    }

    return $removed
}

# --- WingetCore ---
<#
.SYNOPSIS
    Makes winget usable for this run: checks it, works out what is wrong, applies the fix for that,
    and says in one line what could not be fixed.
.DESCRIPTION
    One ladder (review finding P3-25) in place of three that ran back to back and gave one cause
    three diagnoses (Test-AndInstallWinget, Initialize-WingetSourcesForUser, Test-WingetSources),
    plus a source update before elevation that only ever set up the signed-in user's source. Each
    fix runs at most once per run.

      1. Group Policy (Get-WingetPolicyBlock, review finding P3-30). When App Installer's policy
         turns winget or its source off, no fix can help: the run stops with exit code 2 and names
         the policy. So does a winget that answers 0x8A15003A BLOCKED_BY_POLICY.
      2. Can winget start? `winget --version` must run and print a version (Test-WingetLaunchable).
         A failure that can clear on its own (winget.exe locked during an App Installer update,
         issues #253/#258) is checked for up to 75 seconds first, so an update in progress is not
         repaired underneath. Then the account fixes run (Invoke-NextWingetAccountFix), each
         followed by two checks 5 seconds apart: register the App Installer already on this PC for
         this account (the cross-user elevation fix), then Repair-WinGetPackageManager. When winget
         still cannot start, one line says why and what to do, and the run stops with exit code 2.
      3. The winget source: `winget source update --name winget` (Invoke-WingetSourceProbe). Its
         exit code picks the fix: 0x80073D19 (the account has no logon session, so Windows blocked
         registering the source for it, issue #159) gets the account fixes that have not run; a
         missing or corrupted source (class SourceBroken in Get-WingetExitCodeInfo) gets
         `winget source reset --force`. A timeout, a network error or any other code gets none: no
         repair fixes a network, and a slow proxy used to get App Installer replaced (review finding
         P3-28). A source that still fails is reported in one line, and the run carries on: each
         install then says why it failed.

    As SYSTEM (review finding P2-24) step 2 is Test-MachineWingetAvailable, which finds and checks
    the winget.exe App Installer installed for the PC, and no account fix runs: each sets winget up
    for one account, which SYSTEM cannot have.

    Two rungs were dropped. The aka.ms/getwinget download (review findings P3-25, P3-31: it also
    used a fixed file name in %TEMP%) installed the bundle Repair-WinGetPackageManager -Latest
    installs, but without the frameworks the bundle needs, and through the per-account deployment
    that 0x80073D19 blocks under cross-user elevation; the run it once rescued (issue #265) is now
    rescued by the registration rung. Registering cdn.winget.microsoft.com/cache/source.msix with
    Add-AppxPackage was that same per-account deployment, which `winget source update` and
    `winget source reset` make themselves.
.PARAMETER WhatIf
    Dry run (P2-16): only the policy and `winget --version` checks run. Nothing is registered,
    repaired, updated or reset; [DRY-RUN] lines say what a real run would do.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, which Invoke-WingetInstall passes; read here when not given.
.RETURNS
    [pscustomobject] Ready ([bool]: winget starts and no policy blocks it; a real run stops with exit
    code 2 when it is $false) and Diagnosis: 'Ok', 'SourceFailed' (ready, but the winget source
    could not be set up), 'PolicyBlocked' or 'NotLaunchable'.
#>
function Initialize-Winget {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    if ($null -eq $AccountContext) {
        $AccountContext = Get-InstallAccountContext
    }
    $isSystem = [bool]$AccountContext.IsSystem
    $account = 'SYSTEM'
    $who = 'SYSTEM'
    if (-not $isSystem) {
        $account = "$($AccountContext.ProcessUser)"
        $who = "'$account'"
    }
    # 0x8A15003A BLOCKED_BY_POLICY, 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF and
    # 0x8A150046 SOURCE_AGREEMENTS_NOT_ACCEPTED, as the signed Int32 winget exits with.
    $policyExitCode = -1978335174
    $sessionBlockedExitCode = -2147009255
    $agreementsExitCode = -1978335162
    $state = @{ ErrorCodes = @() }

    $policyBlocked = {
        param ([string]$Detail)
        $message = "Group Policy on this PC blocks winget: $Detail. This installer cannot install apps until the policy allows it; ask whoever manages this PC's policies (Computer Configuration > Administrative Templates > Windows Components > Desktop App Installer) to allow it, then re-run the installer."
        if ($WhatIf) {
            Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
        }
        else {
            Write-ErrorMessage $message
        }
        [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }

    $policy = Get-WingetPolicyBlock
    if ($policy) {
        return (& $policyBlocked ("'{0}' is Disabled ({1} = 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller)" -f $policy.Policy, $policy.Name))
    }

    if ($AccountContext.IsCrossUserElevation) {
        Write-WarningMessage "Cross-user elevation detected: running as '$account' while '$($AccountContext.SessionUser)' owns the interactive session."
        Write-WarningMessage "winget is set up per account; setting it up for '$account'."
    }

    if ($isSystem) {
        if (-not (Test-MachineWingetAvailable -WhatIf:$WhatIf)) {
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
    }
    else {
        $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
        if (-not $probe.Launchable -and -not $WhatIf) {
            Write-WarningMessage "Winget is not available: $($probe.Reason)."
            while (-not $probe.Launchable -and $probe.ExitCode -ne $policyExitCode -and (Invoke-NextWingetAccountFix -State $state)) {
                $probe = Test-WingetLaunchable -Attempts 2 -RetryDelaySeconds 5
            }
        }
        if ($probe.ExitCode -eq $policyExitCode) {
            return (& $policyBlocked ("'winget --version' answered {0}" -f (Format-WingetExitCode -ExitCode $probe.ExitCode)))
        }
        if (-not $probe.Launchable) {
            if ($WhatIf) {
                Write-Info "[DRY-RUN] Winget is not available for this account ($($probe.Reason)). A real run would set it up: register the App Installer package already on this PC for this account, then run Repair-WinGetPackageManager (installing its Microsoft.WinGet.Client module from the PowerShell Gallery first if it is missing), and stop with exit code 2 if winget still cannot be started."
                return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
            }
            $seen = ''
            $codes = @($state.ErrorCodes | Select-Object -Unique)
            if ($codes.Count -gt 0) {
                $seen = ' App Installer could not be registered or repaired ({0}).' -f (@($codes | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
            }
            Write-ErrorMessage ("Winget cannot be started for {0}: {1}.{2} {3}" -f $who, $probe.Reason, $seen, (Get-WingetSetupAdvice -State $state -Account $account))
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        Write-Success "Winget is available ($($probe.Version))."
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would update the winget source for $who (winget source update --name winget), and fix it if that fails: winget source reset --force for a missing or corrupted source, which also removes any source added beyond the defaults."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    Write-Info "Updating the winget source for $who (this may take a moment)..."
    $source = Invoke-WingetSourceProbe
    while (-not $source.Succeeded) {
        $fixed = $false
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $source.ExitCode
        if ($source.ExitCode -eq $sessionBlockedExitCode -and -not $isSystem) {
            $fixed = Invoke-NextWingetAccountFix -State $state
        }
        elseif ($codeInfo -and $codeInfo.Class -eq 'SourceBroken' -and -not $state.ContainsKey('SourceReset')) {
            $state.SourceReset = Reset-WingetSource
            $fixed = $true
        }
        if (-not $fixed) {
            break
        }
        $source = Invoke-WingetSourceProbe
    }

    if ($source.Succeeded) {
        Write-Success "The winget source is up to date for $who."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }
    if ($source.ExitCode -eq $policyExitCode) {
        return (& $policyBlocked ("'winget source update' answered {0}" -f (Format-WingetExitCode -ExitCode $source.ExitCode)))
    }
    if ($source.ExitCode -eq $agreementsExitCode) {
        Write-Info 'The winget source agreements are not accepted for this account yet (0x8A150046); each install accepts them.'
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    $detail = 'it did not finish in time and was stopped'
    if ($source.LaunchError) {
        $detail = "winget could not be started: $($source.LaunchError)"
    }
    elseif (-not $source.TimedOut) {
        $detail = 'exit code {0}' -f (Format-WingetExitCode -ExitCode $source.ExitCode)
    }
    Write-WarningMessage ('The winget source could not be set up for {0} ({1}). {2} Installations may fail.' -f $who, $detail, (Get-WingetSetupAdvice -State $state -Account $account -Source -SourceExitCode $source.ExitCode))
    return [pscustomobject]@{ Ready = $true; Diagnosis = 'SourceFailed' }
}

<#
.SYNOPSIS
    Installs a single winget package, retrying the results that clear on their own: the 0x80073d19
    session error, another installation in progress, and an app or file in use.
.DESCRIPTION
    Runs `winget install` for one package id through Invoke-WingetProcess and reads winget's real
    process exit code from the result. Exit code 0x80073d19 (ERROR_INSTALL_USER_LOGOFF — "an error
    occurred because a user was logged off") is a transient MSIX/session-deployment race: an
    immediate retry simply hits the same race, which is why issues #81/#100/#102 left it unresolved.
    When that specific code is seen, this function waits with an increasing backoff and retries, up
    to MaxAttempts.

    Two more results are retried (review finding P2-15), decided by their class in
    Get-WingetExitCodeInfo:
      - 0x8A150102 (INSTALL_INSTALL_IN_PROGRESS): Windows Installer was busy with another
        installation (msiexec 1618), which it reports at once instead of waiting. Common on a fresh
        PC whose management agent, OEM tools or Teams are still installing. This function waits
        until Windows Installer is idle (Wait-WindowsInstallerIdle, checking every 15 seconds) and
        retries, up to InstallInProgressRetries times, waiting at most InstallInProgressWaitSeconds
        in all. Invoke-WingetInstall passes what is left of the run's 10-minute budget, so a machine
        that stays busy costs the run 10 minutes at most, not 10 minutes per app.
      - 0x8A150101, 0x8A150103 and 0x8A150111 (the app or its files are in use): one retry after
        InUseRetryDelaySeconds.
    0x8A15010A (a restart is required before the installer can run) is never retried: only a restart
    changes it. Any other exit code (success or a real failure) is returned at once so the caller
    can verify the result with `winget list` as before.

    Restart required to finish (review finding P3-16): winget 1.7 and later report an MSI, WiX or
    Burn installer's 3010 as exit 0 and print 'Restart your PC to finish installation.'; winget 1.6
    and older exit 0x8A150109, and an installer that started a restart itself (MSI 1641) gives
    0x8A15010B. RestartRequired says so for any of the three. The printed warning is matched in
    English only; on other display languages the caller's pending-restart registry check is what
    notices it.

    Each install has a time limit (Get-ProcessTimeoutSeconds WingetInstall, review finding P2-5):
    when it runs out, winget and the installer it started are stopped, and the result says TimedOut
    with no exit code; a timed-out install is not retried here. winget's output is echoed into the
    console and the transcript as it arrives (P2-6), so the installer's own error text ("Installer
    failed with exit code: 1603") is in the log the teammate attaches, and winget writes the
    installer's log (--log) to the run's logs folder; InstallerLogPath points at it when the
    installer wrote one. When the run is unattended (-Silent), winget gets --silent, so MSI and
    WiX packages install with /quiet instead of /passive.

    winget can also fail to launch at all, with Win32 ERROR_CANT_ACCESS_FILE (1920, "The file cannot
    be accessed by the system.") or the sibling ERROR_SHARING_VIOLATION (32, "being used by another
    process"), instead of producing an exit code. This happens when winget.exe's own file is
    transiently locked — e.g. Windows Defender real-time scanning it, or an AppX
    package-registration race right after Repair-WinGetPackageManager runs. A failed launch used to
    bypass the exit-code-based retry loop below entirely: on a GitHub-hosted E2E runner this was
    observed to fail every install in a run, surviving even the caller's separate one-shot retry
    pass, because neither layer paused before retrying (issue #253). This class of launch failure is
    now retried, recognized by its Win32 error code rather than by its translated message (P3-6).
    Any other launch failure (e.g. winget genuinely missing, or 'Access is denied') is not retried:
    it ends the install at once with LaunchErrorExhausted and the launch error in the result, so
    the caller reports that winget could not be launched (and Invoke-WingetInstall's circuit
    breaker can stop the run) instead of an unexpected error.

    Launch failures have their own retry budget, longer than the session-error one (issue #258):
    the dominant real-world cause is a Microsoft.DesktopAppInstaller (App Installer) upgrade or
    re-registration in flight - e.g. a background Winget-AutoUpdate run - which breaks the per-user
    winget.exe app-execution alias for the whole registration window, far longer than the 15s the
    #253 backoff covered. The launch backoff doubles across MaxLaunchAttempts (default 5:
    5s+10s+20s+40s = 75s of coverage) so the retry window outlasts a typical App Installer
    registration. A failed launch never ran winget, so it does not consume one of the MaxAttempts
    install attempts. (Each retry used to launch the package's own winget.exe past the alias,
    Resolve-WingetExecutable -BypassAlias; that never worked and was removed, review finding P3-7.)

    Installs prefer `--scope machine` (issue #159): user-scope installs land in the elevated
    account's profile rather than the logged-on user's, and packages that ship both MSIX and MSI
    installers (e.g. Microsoft.PowerShell) resolve at user scope to the MSIX — whose per-user AppX
    deployment is exactly what 0x80073D19 blocks under cross-user elevation. When a package has no
    machine-scope installer (e.g. the MSIX-only Microsoft.WindowsTerminal), winget returns
    0x8A150010 (NO_APPLICABLE_INSTALLER) and the install is retried once at winget's default scope,
    unless -MachineScopeOnly says the run must not install for one account (review finding P3-22).
.PARAMETER PackageId
    The winget package id to install (e.g. 'Microsoft.PowerShell').
.PARAMETER InstallerType
    Optional winget installer-type override (e.g. 'wix' to force the MSI), passed as
    `--installer-type <value>`. Needed for PowerShell: even with --scope machine, winget's
    installer-type precedence still selects the default MSIX, whose machine-scope provisioning fails
    as a packaged app on Windows < build 26100 with 0x8A150113 ("system configuration does not
    support"). Forcing 'wix' installs the machine-wide MSI instead (issue #163).
.PARAMETER MaxAttempts
    Maximum number of install attempts while the session error keeps recurring. Default 3.
.PARAMETER InitialDelaySeconds
    Seconds to wait before the first retry; the wait doubles on each subsequent retry. Default 5.
.PARAMETER MaxLaunchAttempts
    Maximum number of times to attempt launching winget.exe while the launch keeps failing with the
    transient file-lock error (issue #258). Separate from MaxAttempts because a failed launch never
    ran an install; the wait starts at InitialDelaySeconds and doubles on each launch retry.
    Default 5 (75s of total backoff at the default InitialDelaySeconds).
.PARAMETER Silent
    Pass --silent to winget. Invoke-WingetInstall passes its effective non-interactive state. When
    the parameter is not given, Test-EffectiveNonInteractive decides (e.g. for a script that calls
    the function on its own).
.PARAMETER InstallInProgressRetries
    How many times to retry after 0x8A150102 (another installation in progress). Default 3.
.PARAMETER InstallInProgressWaitSeconds
    The most this call may wait, in all, for Windows Installer to finish another installation.
    Default 600 (10 minutes). 0: no wait, so 0x8A150102 is final at once.
.PARAMETER InUseRetryDelaySeconds
    Seconds to wait before the one retry after an in-use result. Default 60.
.PARAMETER MachineScopeOnly
    Never fall back to winget's default scope (review finding P3-22). Invoke-WingetInstall passes it
    for a run as SYSTEM or under cross-user elevation, where the default scope installs into the
    wrong profile: SYSTEM's own, or the elevating admin's instead of the signed-in user's, and the
    verification, run as that same account, then reported it installed. A package with no
    machine-scope installer then ends at once with NoMachineScopeInstaller, and the caller defers
    it (leaves it for the signed-in user's own account).
.RETURNS
    [hashtable] @{ ExitCode = <int|$null>; Attempts = <int>; SessionErrorExhausted = <bool>; MachineScopeFellBack = <bool>; NoMachineScopeInstaller = <bool>; LaunchErrorExhausted = <bool>; LaunchAttempts = <int>; LaunchError = <string|$null>; TimedOut = <bool>; TimeoutSeconds = <int>; InstallerLogPath = <string|$null>; InstallInProgressWaitedSeconds = <int>; RestartRequired = <bool> }
    SessionErrorExhausted is True only when every attempt failed with the session error.
    InstallInProgressWaitedSeconds is how long this call waited for another installation to finish.
    RestartRequired is True when the last attempt's result says a restart finishes the installation
    (see the description); the caller decides from `winget list` whether the package installed.
    MachineScopeFellBack is True when the package had no machine-scope installer and the install
    was retried at winget's default scope. NoMachineScopeInstaller is True when it had none and
    -MachineScopeOnly kept it from being installed at all (ExitCode is then 0x8A150010). Attempts
    counts install attempts at the finally selected scope, the retries after another installation
    in progress or an in-use result included; the one-time scope fallback does not consume a
    session-error attempt, and neither does a failed launch (no process ran). LaunchAttempts counts failed winget launches.
    LaunchErrorExhausted is True when winget.exe could not be launched: a transient launch failure
    through every launch attempt (issues #253/#258), or any other launch failure at once; ExitCode
    is $null in that case, since no process ran to report an exit code, and LaunchError is the last
    launch error. TimedOut is True when the last attempt ran out of time
    and was stopped (ExitCode is then $null); TimeoutSeconds is the limit it had. InstallerLogPath
    is the installer log winget wrote for the last attempt, or $null when there is none.
#>
function Install-WingetPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5,

        [Parameter(Mandatory = $false)]
        [int]$MaxLaunchAttempts = 5,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressRetries = 3,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600,

        [Parameter(Mandatory = $false)]
        [int]$InUseRetryDelaySeconds = 60,

        [Parameter(Mandatory = $false)]
        [switch]$MachineScopeOnly
    )

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32, which is how winget
    # reports it through Process.ExitCode.
    $sessionLogoffExitCode = -2147009255
    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32: returned when
    # the --scope machine requirement filters out every installer in the package's manifest.
    $noApplicableInstallerExitCode = -1978335216

    $useSilent = [bool]$Silent
    if (-not $PSBoundParameters.ContainsKey('Silent')) {
        $useSilent = [bool](Test-EffectiveNonInteractive)
    }
    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetInstall

    $attempt = 0
    $sessionErrors = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $installInProgressRetried = 0
    $installInProgressWaited = 0
    $inUseRetried = $false
    $restartRequired = $false
    $useMachineScope = $true
    $machineScopeFellBack = $false
    $noMachineScopeInstaller = $false
    $launchErrorExhausted = $false
    $launchAttempt = 0
    $launchDelay = $InitialDelaySeconds
    $launchError = $null
    $timedOut = $false
    $installerLogPath = $null

    while ($true) {
        $attempt++
        $restartRequired = $false

        # The shared agreement/interactivity flags come from Get-WingetAgreementArgs (issue #230
        # follow-up): every other winget call in the module already passed them, but this one -
        # the path every app install takes - did not, because each call site hand-duplicated the
        # literal array. Routing through the shared helper makes that omission structurally
        # impossible instead of relying on manual re-auditing.
        $installArgs = @(
            'install', '-e'
        ) + (Get-WingetAgreementArgs) + @(
            '--source', 'winget',
            '--id', $PackageId
        )
        if ($useMachineScope) {
            $installArgs += @('--scope', 'machine')
        }
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $installArgs += @('--installer-type', $InstallerType)
        }
        if ($useSilent) {
            # Without --silent winget runs MSI and WiX installers with /passive (a progress window)
            # rather than /quiet.
            $installArgs += '--silent'
        }

        $run = Invoke-WingetProcess -ArgumentList $installArgs -TimeoutSeconds $timeoutSeconds
        $installerLogPath = $null
        if ($run.LogPath -and (Test-Path -LiteralPath $run.LogPath)) {
            $installerLogPath = $run.LogPath
        }
        if ($run.LaunchFailed) {
            # A failed launch never ran winget, so it must not consume an install attempt; launch
            # failures have their own budget (issue #258).
            $attempt--
            $launchAttempt++
            $launchError = $run.LaunchError
            $transient = Test-TransientWingetLaunchError -NativeErrorCode $run.LaunchErrorCode -Message $run.LaunchError
            if ($transient -and $launchAttempt -lt $MaxLaunchAttempts) {
                # The usual cause is the winget.exe app-execution alias breaking while the
                # DesktopAppInstaller package is upgraded or re-registered underneath us (e.g. by
                # a background Winget-AutoUpdate run), or an antivirus scan of winget.exe.
                Write-WarningMessage "Could not launch winget for $PackageId - its executable appears transiently locked ($($run.LaunchError)). Waiting ${launchDelay}s before launch retry $($launchAttempt + 1) of ${MaxLaunchAttempts}..."
                Start-Sleep -Seconds $launchDelay
                $launchDelay = $launchDelay * 2
                continue
            }

            if ($transient) {
                Write-WarningMessage "Still unable to launch winget for $PackageId after ${MaxLaunchAttempts} launch attempts ($($run.LaunchError))."
            }
            else {
                # Not a lock that clears on its own (e.g. winget missing, or 'Access is denied'):
                # retrying would only wait.
                Write-WarningMessage "Could not launch winget for ${PackageId}: $($run.LaunchError)"
            }
            $launchErrorExhausted = $true
            $exitCode = $null
            break
        }

        if ($run.TimedOut) {
            # Invoke-ExternalProcess stopped winget and the installer it was running. A hung
            # installer would most likely hang again, so this is final; the caller's verification
            # and the run's retry pass decide what happens next.
            Write-ErrorMessage ("Install of {0} did not finish within {1} minutes and was stopped." -f $PackageId, [Math]::Round($timeoutSeconds / 60))
            $timedOut = $true
            $exitCode = $null
            break
        }

        $exitCode = $run.ExitCode
        if ($exitCode -ne 0 -and $installerLogPath) {
            Write-Info "Installer log for ${PackageId}: $installerLogPath"
        }

        # No installer matched the machine-scope requirement (e.g. MSIX-only packages such as
        # Microsoft.WindowsTerminal, which only install per-user). Fall back to winget's default
        # scope once; this is a manifest property, not a transient error, so it does not consume
        # one of the session-error attempts.
        if ($useMachineScope -and $exitCode -eq $noApplicableInstallerExitCode) {
            if ($MachineScopeOnly) {
                # A run as SYSTEM or under cross-user elevation (review finding P3-22): the default
                # scope would install the app for the account running this, not for the user.
                Write-Info "winget found no machine-scope installer for $PackageId that applies to this PC, and this run installs for the whole PC only, so it is not installed at winget's default (per-user) scope."
                $noMachineScopeInstaller = $true
                break
            }
            Write-Info "$PackageId has no machine-scope installer. Retrying with winget's default scope..."
            $useMachineScope = $false
            $machineScopeFellBack = $true
            $attempt--
            continue
        }

        if ($exitCode -eq $sessionLogoffExitCode) {
            $sessionErrors++
            if ($sessionErrors -lt $MaxAttempts) {
                Write-WarningMessage "Install of $PackageId hit transient session error 0x80073D19 (a user was logged off). Waiting ${delay}s before retry $($sessionErrors + 1) of ${MaxAttempts}..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
                continue
            }
            Write-WarningMessage "Install of $PackageId still failing with session error 0x80073D19 after ${MaxAttempts} attempts."
            break
        }

        $codeClass = ''
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $exitCode
        if ($codeInfo) {
            $codeClass = $codeInfo.Class
        }

        if ($codeClass -eq 'InstallInProgress') {
            # Windows Installer returns 1618 at once while another installation holds it (review
            # finding P2-15): wait for that installation, within this call's share of the budget.
            $waitLeft = $InstallInProgressWaitSeconds - $installInProgressWaited
            if ($installInProgressRetried -lt $InstallInProgressRetries -and $waitLeft -gt 0) {
                $installInProgressRetried++
                Write-WarningMessage ("Windows Installer is busy with another installation ({0}). Waiting for it to finish (at most {1} seconds) before retry {2} of {3} for {4}..." -f (Format-WingetExitCode -ExitCode $exitCode), $waitLeft, $installInProgressRetried, $InstallInProgressRetries, $PackageId)
                $wait = Wait-WindowsInstallerIdle -MaximumSeconds $waitLeft
                $installInProgressWaited += [int]$wait.WaitedSeconds
                continue
            }
            Write-WarningMessage ("Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting; {2} was not installed." -f $installInProgressRetried, $installInProgressWaited, $PackageId)
            break
        }

        if ($codeClass -eq 'InUse' -and -not $inUseRetried) {
            $inUseRetried = $true
            Write-WarningMessage ("{0} could not be installed because it or its files are in use ({1}). Waiting {2}s before one more try..." -f $PackageId, (Format-WingetExitCode -ExitCode $exitCode), $InUseRetryDelaySeconds)
            Start-Sleep -Seconds $InUseRetryDelaySeconds
            continue
        }

        # Success, a restart-required result (0x8A15010A is never retried: only a restart changes
        # it) or another failure: final here. The caller verifies the actual install state with
        # `winget list`.
        # winget 1.7+ turns an installer's 3010 into exit 0 and says so only in its output
        # ('Restart your PC to finish installation.', English display language only).
        $restartRequired = Test-WingetRestartRequiredResult -ExitCode $exitCode -Output $run.Output
        break
    }

    return @{
        ExitCode                       = $exitCode
        Attempts                       = $attempt
        SessionErrorExhausted          = ($exitCode -eq $sessionLogoffExitCode)
        MachineScopeFellBack           = $machineScopeFellBack
        NoMachineScopeInstaller        = $noMachineScopeInstaller
        LaunchErrorExhausted           = $launchErrorExhausted
        LaunchAttempts                 = $launchAttempt
        LaunchError                    = $(if ($launchErrorExhausted) { $launchError } else { $null })
        TimedOut                       = $timedOut
        TimeoutSeconds                 = $timeoutSeconds
        InstallerLogPath               = $installerLogPath
        InstallInProgressWaitedSeconds = $installInProgressWaited
        RestartRequired                = $restartRequired
    }
}

<#
.SYNOPSIS
    Returns whether winget reports the given package id as installed for the current account.
.DESCRIPTION
    Runs `winget list --exact --id <id>` through Invoke-WingetProcess, quietly (the per-app checks
    would otherwise print a table twice for every app), and always under a time limit, killing a
    hung winget instead of blocking the install loop (issues #176, #188).

    Without -TimeoutSeconds the check uses the general `winget list` limit (Get-ProcessTimeoutSeconds
    WingetList) and returns a plain [bool], keeping the original contract for existing callers; any
    failure to get an answer reads as not installed. With -TimeoutSeconds a hashtable is returned so
    the caller can tell the three outcomes apart: installed, not installed, and no answer. A
    timeout must count as a failure rather than being silently dropped (issue #176), and so must a
    winget that could not be started (LaunchFailed, review finding P2-9): reading that as "not
    installed" made Install-AppWithVerification install apps that were already there and then
    report them as 'package not found after install'. A failed launch is not retried here; the
    caller decides (Invoke-WingetInstall's circuit breaker checks whether winget can still start).
    The same goes for a `winget list` that ran but failed (CheckFailed): it exits 0 when it lists
    the package and 0x8A150014 (APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND) when nothing matches,
    and it only warns about a source it could not search. Any other exit code with no match (for
    example 0x8A15004B, every source failed to open) means the check itself failed.

    Both modes determine "installed" via Test-WingetListOutputContainsPackageId rather than a plain
    substring .Contains check, so an unrelated listed id that merely contains $PackageId as a
    substring (e.g. target 'Foo.Bar' inside listed id 'Foo.BarBaz') cannot false-positive.
.PARAMETER PackageId
    The winget package id to check.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for `winget list` before killing it. When omitted (or 0), the general
    `winget list` limit applies and a [bool] is returned.
.RETURNS
    [bool] when -TimeoutSeconds is not supplied.
    [hashtable] @{ Installed = <bool>; TimedOut = <bool>; LaunchFailed = <bool>;
    LaunchError = <string or $null>; CheckFailed = <bool>; ExitCode = <int or $null> } when it is.
    Installed is True only when winget answered and listed the id. TimedOut, LaunchFailed and
    CheckFailed mean there was no answer: winget ran out of time, could not be started (LaunchError
    says why), or ran and failed without listing the id (ExitCode says how). ExitCode is the winget
    process exit code, or $null when winget did not run to the end.
#>
function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0
    )

    $listArgs = @('list', '--exact', '--id', $PackageId, '--accept-source-agreements', '--disable-interactivity')

    if ($TimeoutSeconds -gt 0) {
        $run = Invoke-WingetProcess -ArgumentList $listArgs -TimeoutSeconds $TimeoutSeconds -Echo None
        if ($run.LaunchFailed) {
            return @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = $run.LaunchError; CheckFailed = $false; ExitCode = $null }
        }

        if ($run.TimedOut) {
            return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
        }

        # Standard output only, as before: an error message on standard error can name the id too.
        # Join with a newline, not '': Test-WingetListOutputContainsPackageId's boundary regex
        # treats anything outside [\w.\-] as a token edge, so an empty separator would let the
        # end of one line abut the start of the next and could hide a real match at that seam.
        $installed = Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", @($run.StandardOutput))) -PackageId $PackageId

        # 0 (listed) and 0x8A150014 (APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND, as a signed
        # Int32) are the answers; any other exit code without a match is a failed check, not "not
        # installed" (review finding P2-9).
        $noApplicationsFoundExitCode = -1978335212
        $checkFailed = (-not $installed) -and ($null -ne $run.ExitCode) -and (@(0, $noApplicationsFoundExitCode) -notcontains [int]$run.ExitCode)

        return @{
            Installed    = $installed
            TimedOut     = $false
            LaunchFailed = $false
            LaunchError  = $null
            CheckFailed  = $checkFailed
            ExitCode     = $run.ExitCode
        }
    }

    $run = Invoke-WingetProcess -ArgumentList $listArgs -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetList) -Echo None
    if ($run.LaunchFailed -or $run.TimedOut) {
        return $false
    }
    return Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", @($run.Output))) -PackageId $PackageId
}

<#
.SYNOPSIS
    Returns true when an MSIX/Appx package matching the given DisplayName/PackageName pattern is
    provisioned for all users on this machine.
.PARAMETER NameLike
    A wildcard pattern matched against provisioned packages' DisplayName and PackageName.
#>
function Test-AppxPackageProvisioned {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NameLike
    )

    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction Stop
        return [bool]($provisioned | Where-Object { $_.DisplayName -like $NameLike -or $_.PackageName -like $NameLike })
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Provisions a downloaded MSIX package (and its dependencies) for all users via DISM.
.DESCRIPTION
    Thin, mockable wrapper around Add-AppxProvisionedPackage. The Appx/DISM provider is unreliable
    under PowerShell 7 (it throws 0x80131539 "Operation is not supported on this platform"), so when
    running under pwsh the provisioning is delegated to Windows PowerShell 5.1. Returns True on
    success. A winget-source MSIX has no Store license, so -SkipLicense is used when no license file
    was downloaded alongside it.
.PARAMETER PackagePath
    Full path to the .msixbundle/.msix to provision.
.PARAMETER DependencyPackagePath
    Full paths to dependency packages (e.g. Microsoft.WindowsAppRuntime, VCLibs).
.PARAMETER LicensePath
    Optional path to a downloaded license .xml.
#>
function Invoke-AppxProvisioning {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [string[]]$DependencyPackagePath = @(),

        [Parameter(Mandatory = $false)]
        [string]$LicensePath
    )

    $hasLicense = $LicensePath -and (Test-Path $LicensePath)

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Delegate to Windows PowerShell 5.1, where the Appx/DISM provider works.
            # Every path is interpolated into a single-quoted literal inside the delegated
            # -Command string, so escape embedded single quotes by doubling them (issue #178).
            # Otherwise an apostrophe in a path (e.g. C:\Users\O'Brien\...) unbalances the
            # quoting — breaking provisioning at best, and at worst letting a crafted filename
            # break out of the literal inside an elevated powershell.exe -Command.
            $escapedPackagePath = $PackagePath.Replace("'", "''")
            $depClause = if ($DependencyPackagePath.Count -gt 0) {
                $escapedDependencyPaths = @($DependencyPackagePath | ForEach-Object { $_.Replace("'", "''") })
                "-DependencyPackagePath @('" + ($escapedDependencyPaths -join "','") + "')"
            }
            else { '' }
            $licClause = if ($hasLicense) { "-LicensePath '$($LicensePath.Replace("'", "''"))'" } else { '-SkipLicense' }
            $command = "Add-AppxProvisionedPackage -Online -PackagePath '$escapedPackagePath' $depClause $licClause -ErrorAction Stop | Out-Null"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
            return ($LASTEXITCODE -eq 0)
        }

        $params = @{ Online = $true; PackagePath = $PackagePath; ErrorAction = 'Stop' }
        if ($DependencyPackagePath.Count -gt 0) { $params.DependencyPackagePath = $DependencyPackagePath }
        if ($hasLicense) { $params.LicensePath = $LicensePath } else { $params.SkipLicense = $true }
        Add-AppxProvisionedPackage @params | Out-Null
        return $true
    }
    catch {
        Write-ErrorMessage "Add-AppxProvisionedPackage failed for '$PackagePath': $_"
        return $false
    }
}

<#
.SYNOPSIS
    Installs the latest MSIX build of a winget package machine-wide by provisioning it via DISM.
.DESCRIPTION
    Used for the holdout case where a package is MSIX-only (e.g. PowerShell 7.7+) AND the machine is
    Windows older than build 26100, where winget cannot machine-scope-provision an MSIX because it
    calls the provisioning API from a packaged process. This function instead downloads the latest
    MSIX (plus dependencies and license) with `winget download`, then provisions it for all users
    with Add-AppxProvisionedPackage from a NON-packaged process, which is not subject to that bug
    (issue #166).

    VALIDATION NOTE: the DISM path is dormant until a package's winget default becomes MSIX-only
    (PowerShell 7.7 GA). It is covered by unit tests with mocked external calls, but the end-to-end
    behavior (winget download layout, license handling, all-users provisioning under cross-user
    elevation) should be validated on a real Windows 10 machine before it is relied upon.
.PARAMETER PackageId
    The winget package id to provision (e.g. 'Microsoft.PowerShell').
.PARAMETER VerifyNameLike
    Wildcard matched against provisioned package names to confirm success. Defaults to *<last id
    segment>* (e.g. '*PowerShell*').
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool> }
#>
function Install-MsixProvisionedPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$VerifyNameLike
    )

    if (-not $VerifyNameLike) {
        $VerifyNameLike = '*' + ($PackageId -split '\.')[-1] + '*'
    }

    $downloadDir = Join-Path $env:TEMP ('winget-msix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    try {
        Write-Info "Downloading the latest MSIX for $PackageId to provision it machine-wide..."
        $downloadArgs = @(
            'download', '-e', '--id', $PackageId, '--source', 'winget', '--installer-type', 'msix'
        ) + (Get-WingetAgreementArgs) + @(
            '--download-directory', $downloadDir
        )
        $download = Invoke-WingetProcess -ArgumentList $downloadArgs -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetDownload)
        if ($download.LaunchFailed) {
            # As before, a winget that cannot start at all propagates to the caller.
            throw $download.LaunchException
        }
        if ($download.TimedOut) {
            Write-ErrorMessage "winget download for $PackageId did not finish in time and was stopped."
            return @{ ExitCode = $null; Installed = $false }
        }
        if ($download.ExitCode -ne 0) {
            Write-ErrorMessage ('winget download failed for {0} (exit code {1}).' -f $PackageId, (Format-WingetExitCode -ExitCode $download.ExitCode))
            return @{ ExitCode = $download.ExitCode; Installed = $false }
        }

        $downloaded = Get-ChildItem -Path $downloadDir -Recurse -File -ErrorAction SilentlyContinue
        $bundle = $downloaded |
            Where-Object { $_.Extension -in '.msixbundle', '.appxbundle', '.msix', '.appx' -and $_.FullName -notmatch '[\\/]Dependencies[\\/]' } |
            Select-Object -First 1
        if (-not $bundle) {
            Write-ErrorMessage "No MSIX package was found in the winget download for $PackageId."
            return @{ ExitCode = -1; Installed = $false }
        }
        $dependencies = @($downloaded |
                Where-Object { $_.Extension -in '.msix', '.appx' -and $_.FullName -match '[\\/]Dependencies[\\/]' } |
                ForEach-Object { $_.FullName })
        $license = $downloaded | Where-Object { $_.Extension -eq '.xml' -and $_.Name -match 'License' } | Select-Object -First 1

        Write-Info "Provisioning $($bundle.Name) for all users..."
        $provisioned = Invoke-AppxProvisioning -PackagePath $bundle.FullName -DependencyPackagePath $dependencies -LicensePath $license.FullName

        $installed = $provisioned -and (Test-AppxPackageProvisioned -NameLike $VerifyNameLike)
        if ($installed) {
            Write-Success "$PackageId provisioned machine-wide via DISM."
        }
        else {
            Write-ErrorMessage "Failed to provision $PackageId machine-wide."
        }
        return @{ ExitCode = if ($installed) { 0 } else { -1 }; Installed = $installed }
    }
    finally {
        Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Installs the newest available PowerShell, choosing a delivery that works in an elevated
    cross-user / machine-scope context (no version pinning).
.DESCRIPTION
    winget's default already tracks the latest PowerShell, so this never pins a version. It only
    chooses HOW to deliver the latest so the install works machine-wide when the script is elevated
    as a different account than the logged-on user (issues #163/#166):

      1. Prefer the MSI while the current line still ships one (<= 7.6). The MSI installs machine-wide,
         works on any Windows build, and is runnable under Task Scheduler.
      2. Once the MSI is gone (7.7+), winget offers only the MSIX:
         - Windows 24H2+ (build >= 26100): winget can machine-scope-provision the MSIX, so install the
           default package directly.
         - Older Windows: winget's machine-scope MSIX provisioning is broken (it calls the provisioning
           API from a packaged process), so provision the MSIX for all users via DISM instead.

    The result's Installed flag is authoritative — the DISM-provisioned path does not appear under
    `winget list` for the elevating account, so the caller must not re-verify PowerShell with winget.
.PARAMETER PackageId
    The winget package id. Default 'Microsoft.PowerShell'.
.PARAMETER Silent
    Forwarded to Install-WingetPackage (winget --silent, so the MSI installs with /quiet rather than
    /passive). Install-AppWithVerification passes the run's effective non-interactive state, so an
    explicit -NonInteractive reaches PowerShell's install too. Not given: Install-WingetPackage
    decides.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, for another installation to finish (Install-WingetPackage's parameter
    of the same name), shared by the MSI and MSIX attempts. Install-AppWithVerification passes what
    is left of the run's budget. Not given: Install-WingetPackage's default.
.PARAMETER MachineScopeOnly
    Forwarded to Install-WingetPackage (review finding P3-22): a run as SYSTEM or under cross-user
    elevation never installs PowerShell at winget's default (per-user) scope. When the MSIX has no
    machine-scope installer either, the result says NoMachineScopeInstaller, with no `winget list`
    check, and Install-AppWithVerification defers PowerShell.
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool>; Method = 'msi' | 'msix-native' | 'msix-provisioned' }
    The winget paths (msi, msix-native) return Install-WingetPackage's whole result with Installed
    and Method added (review finding P3-8: only ExitCode survived, so PowerShell's failure reason
    read just 'installer reported failure' while every other app's said why), plus the outcome of
    the `winget list` check: VerifyTimedOut, VerifyLaunchFailed, VerifyLaunchError, VerifyCheckFailed
    (`winget list` ran and failed) and VerifyExitCode (its exit code). When winget could not be
    launched for the install (LaunchErrorExhausted), the check is skipped: it would only fail to
    launch again.
#>
function Install-PowerShellLatest {
    param (
        [Parameter(Mandatory = $false)]
        [string]$PackageId = 'Microsoft.PowerShell',

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds,

        [Parameter(Mandatory = $false)]
        [switch]$MachineScopeOnly
    )

    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32 — what winget
    # returns for `--installer-type wix` once the manifest no longer ships an MSI.
    $noApplicableInstallerExitCode = -1978335216

    # The same limit as Install-AppWithVerification's checks (Private/InstallVerification.ps1), so a
    # hung `winget list` during PowerShell's own self-verification fails into the retry pass like
    # every other catalog app's verification does, instead of blocking the run forever.
    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck

    $installParameters = @{ PackageId = $PackageId }
    if ($PSBoundParameters.ContainsKey('Silent')) {
        $installParameters['Silent'] = $Silent
    }
    if ($MachineScopeOnly) {
        $installParameters['MachineScopeOnly'] = $true
    }

    # The wait for another installation to finish (review finding P2-15) is one budget for both
    # attempts below.
    if ($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds')) {
        $installParameters['InstallInProgressWaitSeconds'] = $InstallInProgressWaitSeconds
    }

    # 1. Prefer the MSI while the latest version still ships one.
    $method = 'msi'
    $result = Install-WingetPackage @installParameters -InstallerType 'wix'
    $installInProgressWaited = [int]$result.InstallInProgressWaitedSeconds
    if ($result.ExitCode -eq $noApplicableInstallerExitCode) {
        # 2. No MSI for the latest version (7.7+): install the latest MSIX machine-wide.
        Write-Info "No MSI is available for the latest $PackageId; installing the MSIX package instead."
        if ((Get-WindowsBuildNumber) -lt 26100) {
            $provision = Install-MsixProvisionedPackage -PackageId $PackageId
            return @{ ExitCode = $provision.ExitCode; Installed = $provision.Installed; Method = 'msix-provisioned'; InstallInProgressWaitedSeconds = $installInProgressWaited }
        }
        $method = 'msix-native'
        if ($installParameters.ContainsKey('InstallInProgressWaitSeconds')) {
            $installParameters['InstallInProgressWaitSeconds'] = [Math]::Max(0, $InstallInProgressWaitSeconds - $installInProgressWaited)
        }
        $result = Install-WingetPackage @installParameters
        $installInProgressWaited += [int]$result.InstallInProgressWaitedSeconds
    }

    # Install-WingetPackage's whole result (exit code, attempts, scope fallback, session and launch
    # errors, time limit, installer log), so Format-InstallFailureReason renders the same detail for
    # PowerShell as for every other app (review finding P3-8).
    $outcome = @{}
    if ($result -is [hashtable]) {
        foreach ($key in $result.Keys) {
            $outcome[$key] = $result[$key]
        }
    }
    else {
        $outcome['ExitCode'] = $result.ExitCode
    }
    $outcome['Method'] = $method
    $outcome['InstallInProgressWaitedSeconds'] = $installInProgressWaited
    $outcome['VerifyTimedOut'] = $false
    $outcome['VerifyLaunchFailed'] = $false
    $outcome['VerifyLaunchError'] = $null
    $outcome['VerifyCheckFailed'] = $false
    $outcome['VerifyExitCode'] = $null

    if ($outcome['LaunchErrorExhausted'] -or $outcome['NoMachineScopeInstaller']) {
        # winget never started, or found no installer this run may use, so nothing was installed,
        # and the check would only fail to launch again or say so.
        $outcome['Installed'] = $false
        return $outcome
    }

    $verify = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
    $outcome['Installed'] = [bool]$verify.Installed
    $outcome['VerifyTimedOut'] = [bool]$verify.TimedOut
    $outcome['VerifyLaunchFailed'] = [bool]$verify.LaunchFailed
    $outcome['VerifyLaunchError'] = $verify.LaunchError
    $outcome['VerifyCheckFailed'] = [bool]$verify.CheckFailed
    $outcome['VerifyExitCode'] = $verify.ExitCode
    return $outcome
}

# ------------------------------------------------Main Script------------------------------------------------

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
