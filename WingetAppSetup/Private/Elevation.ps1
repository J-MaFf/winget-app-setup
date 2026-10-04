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

