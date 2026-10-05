<#
.SYNOPSIS
    Returns whether the script runs from a file on disk ($PSScriptRoot is an existing folder)
    rather than from a pipe such as irm | iex.
.OUTPUTS
    [bool] True for a file on disk.
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
    RMM agents run scripts as SYSTEM, which has no interactive session, no per-user app
    registrations and an HKCU that is no user's. The catch is untyped on purpose: off Windows,
    GetCurrent() throws a MethodInvocationException that a typed catch would miss. A function so
    tests can mock it.
.OUTPUTS
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
    Returns the account that owns the interactive console session (DOMAIN\user), or $null.
.DESCRIPTION
    Compared with Get-ProcessUserName to detect cross-user elevation, where winget's per-user MSIX
    setup fails with 0x80073D19 because the process account has no interactive logon (issue #159).
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
    Read once by Invoke-WingetInstall and passed to the steps that depend on it:
      - IsSystem: the process runs as SYSTEM (an RMM agent), which has no per-user winget and whose
        per-user installs would land in its own profile.
      - IsCrossUserElevation: the process runs as another account than the user signed in at the
        console (issue #159), such as a technician's admin account. Always False for SYSTEM.
    In both cases the run installs machine-wide only, and defers an app with no machine-wide
    installer instead of installing it for the wrong account.
.OUTPUTS
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
    Returns whether Invoke-WingetInstall runs from the WingetAppSetup module rather than from the
    generated installer.
.DESCRIPTION
    Elevation relaunches $PSCommandPath, which from the module is the functions-only
    Public/Install.ps1, so the elevated window would install nothing (issue #185).
.PARAMETER InvocationModule
    The caller's $MyInvocation.MyCommand.Module; set when called from an imported module.
.PARAMETER CommandPath
    The caller's $PSCommandPath, which also catches a dot-sourced Public/Install.ps1.
.OUTPUTS
    [bool] True when relaunching $PSCommandPath would do nothing.
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
    Returns a WindowsPrincipal for the current process: a seam so tests of Test-IsAdmin can make
    the static WindowsIdentity call throw.
.OUTPUTS
    [Security.Principal.WindowsPrincipal] for the current process.
#>
function Get-CurrentWindowsPrincipal {
    [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
}

# The parts of Restart-WithElevation (Public/Elevation.ps1), which the installer and the uninstaller
# call. It runs under Windows PowerShell 5.1 too, so they stay 5.1-compatible.

<#
.SYNOPSIS
    Returns the Windows directory (%SystemRoot%), without a trailing backslash, falling back to
    %windir% and then C:\Windows so it is never empty.
.OUTPUTS
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
    The elevated relaunch must start a program every account has: an admin account that elevates
    has no per-user pwsh.exe or wt.exe alias of the end user (review finding P2-11). The installer
    re-enters its 5.1 dispatch there and finds or installs PowerShell 7 itself. Built by string
    concatenation, because off Windows Join-Path rejects a C: path.
.OUTPUTS
    [string] The full path of powershell.exe.
#>
function Get-WindowsPowerShellPath {
    return (Get-WindowsDirectoryPath) + '\System32\WindowsPowerShell\v1.0\powershell.exe'
}

<#
.SYNOPSIS
    Returns the folder the elevated relaunch copies the installer or the uninstaller under:
    %SystemRoot%\Temp.
.DESCRIPTION
    Standard users can create entries there but cannot list, rename or delete another account's,
    unlike the end user's %TEMP% (review finding P3-11). A function so tests can point it elsewhere.
.OUTPUTS
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
    The script the non-elevated run relaunches can sit in the end user's %TEMP%, where that user
    could rewrite it while the UAC prompt is up (review finding P3-11). The check must run before
    any of the file does, so it is this command, on the elevated process's command line. It:
      1. stops with exit code 4 when Group Policy sets AllSigned or Restricted for the approving
         account (2 and 3 in the ExecutionPolicy enum, compared as numbers because Restricted and
         Default share 3): -ExecutionPolicy Bypass makes Get-ExecutionPolicy name any other policy
         only when Group Policy sets it, and step 4's -File would be refused. Only this window knows
         which account approved;
      2. reads the file once and stops with exit code 5 unless its SHA256 is the expected one;
      3. creates a new folder under -CopyRoot that only SYSTEM and Administrators can change and
         writes those bytes into it;
      4. runs that copy with -File in the same window, forwarding the arguments, and exits with its
         exit code, also when Ctrl+C at the copy's closing key prompt stops this command too (the
         console sends it to both): the finally block sets it with $host.SetShouldExit;
      5. deletes the folder.
    The elevated process makes the copy because a non-elevated one would own the folder and could
    change its access list. The list does not name the elevating account, whose non-elevated
    processes could otherwise rewrite the copy in Admin Approval Mode. On failure it prints why and
    waits for Enter, since the window closes when it exits.

    One line, single quotes only: it is passed in double quotes, and ShellExecuteEx limits the
    command line to about 2048 characters. Always runs under Windows PowerShell 5.1
    (Directory.CreateDirectory with a DirectorySecurity is .NET Framework only).
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
.OUTPUTS
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
    # $LASTEXITCODE holds the exit code throughout (-Command runs at the top level, so it is the
    # global the copy's run sets): nothing has to run after the copy, which Ctrl+C would skip.
    $template = @'
$ErrorActionPreference = 'Stop';
$LASTEXITCODE = 5;
$copyDirectory = $null;
try {
    $p = Get-ExecutionPolicy;
    if ($p -in 2, 3) { $LASTEXITCODE = 4; throw ('Group Policy sets the execution policy to ' + $p + ', which -ExecutionPolicy Bypass cannot override'); }
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
} catch {
    Write-Host ('Did not run ' + @NAME@ + ': ' + $_) -ForegroundColor Red;
    try { [void](Read-Host 'Press Enter to close this window'); } catch { }
} finally {
    $host.SetShouldExit($LASTEXITCODE);
    if ($copyDirectory) { Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue; }
}
'@

    # Single-quoted literals. EscapeSingleQuotedStringContent also doubles the typographic quotes
    # U+2018 to U+201B, which a profile folder name can hold and which would end the literal.
    # Windows paths cannot contain the double quote that would end the command-line argument.
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
    Process.Start, not Start-Process -Verb RunAs, because it throws the Win32Exception itself, so a
    declined UAC prompt is recognized by its code (1223, ERROR_CANCELLED) in every display language
    (review finding P2-12). A function so tests can mock it.
.PARAMETER FilePath
    The program.
.PARAMETER ArgumentString
    Its command line, without the program name.
.OUTPUTS
    [System.Diagnostics.Process]. Throws when it could not be started or the prompt was declined.
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

