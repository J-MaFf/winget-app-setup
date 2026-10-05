<#
.SYNOPSIS
    The user phase of an Endpoint Central deployment: at each sign-in, as the signed-in user,
    installs the apps the machine phase deferred to the user's own account and sets the user's
    Windows Terminal defaults. Ends at once, silently, when there is nothing to do.
.DESCRIPTION
    Upload this script to ManageEngine Endpoint Central's Script Repository and deploy it as a User
    Configuration custom script that runs as the target (signed-in) user, frequency Every Logon,
    success exit codes 0,3010. It never prompts and never elevates.

    The machine phase (rmm/Invoke-WingetAppSetup.ps1, as SYSTEM) installs what installs for the whole
    PC, and records the apps it could not install that way as Deferred in
    %ProgramData%\winget-app-setup\logs\last-run.json, which every user can read. It cannot set the
    per-user Windows Terminal defaults either. This script does both, once per machine run, in each
    user's own account:

      1. As SYSTEM it does nothing (it says so and exits 0).
      2. It decides, before it downloads anything, whether this account has work for the latest
         machine run: none when there is no last-run.json, when that run has not finished, or when
         this account's %LOCALAPPDATA%\winget-app-setup\user-phase.json says it already finished
         that run, or tried it MaxAttempts times. Then it exits 0 and prints nothing: this is what
         almost every sign-in does, in well under a second. A last-run.json that someone other
         than SYSTEM or Administrators owns, or can change, is not used either (it says so and
         exits 0): the apps it defers are installed in every account that signs in, so only one
         the machine phase wrote counts.
      3. Otherwise it finds PowerShell 7 (the machine phase installs it), downloads
         winget-app-install.ps1 from the pinned commit below into the user's %TEMP%, checks its
         SHA256 against the pinned one, and runs itself under PowerShell 7 with that copy, which it
         dot-sources (its functions only: the installer's own run starts only when it is run, not
         dot-sourced) to call Invoke-WingetUserPhase. That installs each deferred app with
         `--scope user` only (a per-user installer, which needs no administrator rights; never a
         machine-wide one, which would ask for them), sets the Windows Terminal defaults (the
         targeted defaultProfile edit), records what it did in user-phase.json and logs to
         %LOCALAPPDATA%\winget-app-setup\logs.
      4. The PowerShell 7 run gets MaxMinutes for its installs, and is stopped when it has not ended
         MaxMinutes + 5 minutes after it started.

    A later sign-in tries again when an app failed, the time budget ran out, winget could not be
    started yet, or Windows Terminal had not been opened yet (it has no settings.json before), up to
    MaxAttempts sign-ins per machine run.
.PARAMETER InstallerPath
    Use this local copy of winget-app-install.ps1 instead of downloading the pinned one (testing).
    Its SHA256 is still checked: against -InstallerSha256, or the pinned one.
.PARAMETER InstallerSha256
    The SHA256 the installer must have. Default: the pinned one.
.PARAMETER MaxMinutes
    The time budget for the installs. Default 15.
.PARAMETER MaxAttempts
    How many sign-ins may try for one machine run. Default 3.
.PARAMETER RunUserPhaseWith
    Internal: the checked copy of the installer the PowerShell 7 run dot-sources. Set by this script
    when it runs itself under PowerShell 7.
.NOTES
    Exit codes: 0 = done, or nothing to do; 1 = a deferred app failed, or was not attempted within
    the time budget; 2 = winget cannot be started for this account yet; 3010 = done, an install
    needs a restart; 5 = the installer could not be run (pins not set, download failed, SHA256
    mismatch), the run did not end in time, or an unexpected error; 7 = PowerShell 7 is not
    installed (the machine phase installs it).

    The pins below must be the same as in rmm/Invoke-WingetAppSetup.ps1
    (build/Set-RmmInstallerPin.ps1 sets both; tests/RmmWrapper.Tests.ps1 checks it).

    The first part runs under Windows PowerShell 5.1: ASCII only, no PowerShell-7-only syntax.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $false)]
    [string]$InstallerSha256,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 240)]
    [int]$MaxMinutes = 15,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxAttempts = 3,

    [Parameter(Mandatory = $false)]
    [string]$RunUserPhaseWith
)

# ---- The pinned installer ------------------------------------------------------------------------
# Which winget-app-install.ps1 this script runs: the file in commit PinnedInstallerCommit (its full
# 40-character id, a commit on main), whose SHA256 must be PinnedInstallerSha256. Set both together,
# here and in rmm/Invoke-WingetAppSetup.ps1, with:
#     pwsh -File build/Set-RmmInstallerPin.ps1 -Commit <commit on main>
# It reads the file from that commit with git and writes both pins into both scripts. Then upload
# the changed scripts to the Script Repository again. Both empty: not set yet, and the script
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
    Returns whether this process runs as SYSTEM.
#>
function Test-RmmIsSystem {
    try {
        return [bool][System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Says why the run record may have been written by someone other than SYSTEM or an administrator,
    or returns $null when it cannot have been.
.DESCRIPTION
    The same check as the module's Get-RunRecordTrustProblem (WingetAppSetup/Private/
    UserPhaseSupport.ps1): the file's owner must be SYSTEM or Administrators, and no access entry
    that applies to it may let another account write or append to it, delete it, change its access
    list or take ownership of it. tests/RmmWrapper.Tests.ps1 checks that the two agree.
.RETURNS
    [string] What is wrong, or $null.
#>
function Get-RmmRunRecordTrustProblem {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    # WriteData, AppendData, Delete, ChangePermissions, TakeOwnership, GENERIC_ALL, GENERIC_WRITE.
    $changeRights = 0x2 -bor 0x4 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $sidType = [System.Security.Principal.SecurityIdentifier]
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $acl.GetOwner($sidType)
        $rules = @($acl.GetAccessRules($true, $true, $sidType))
    }
    catch {
        return "its owner and access list could not be read ($($_.Exception.Message))"
    }

    $problems = @()
    $ownerSid = ''
    if ($owner) {
        $ownerSid = [string]$owner.Value
    }
    if ($trustedSids -notcontains $ownerSid) {
        $problems += "it is owned by $ownerSid, not by SYSTEM or Administrators"
    }
    foreach ($rule in $rules) {
        $sid = [string]$rule.IdentityReference.Value
        $inheritOnly = (([int]$rule.PropagationFlags) -band 2) -ne 0
        if ([string]$rule.AccessControlType -ne 'Allow' -or $inheritOnly -or $trustedSids -contains $sid) {
            continue
        }
        if (([long]$rule.FileSystemRights -band $changeRights) -ne 0) {
            $problems += "$sid can change it"
        }
    }
    if ($problems.Count -eq 0) {
        return $null
    }
    return ($problems -join '; ')
}

<#
.SYNOPSIS
    Decides, before anything is downloaded, whether this account has user-phase work.
.DESCRIPTION
    The same rule as the module's Get-UserPhaseDecision (WingetAppSetup/Private/UserPhaseSupport.ps1),
    read the same way: no work without a readable run record with an apps list that only SYSTEM or
    an administrator can have written (Get-RmmRunRecordTrustProblem), while that run has not
    reported (exitCode null), or when this account's state is for the same record (same SHA256) and
    is complete or has used MaxAttempts attempts. tests/RmmWrapper.Tests.ps1 checks that the two
    agree.
.RETURNS
    [pscustomobject] with Pending ([bool]), Reason ('NoRecord', 'RunNotFinished', 'Done',
    'GaveUp', 'Pending' or 'New') and Detail (a line to print, for a record that is not used
    because someone else could have written it; otherwise $null).
#>
function Test-RmmUserPhasePending {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RunRecordPath,

        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [int]$MaxAttempts
    )

    if (-not (Test-Path -LiteralPath $RunRecordPath -PathType Leaf)) {
        return [pscustomobject]@{ Pending = $false; Reason = 'NoRecord'; Detail = $null }
    }
    $trustProblem = Get-RmmRunRecordTrustProblem -Path $RunRecordPath
    if ($trustProblem) {
        return [pscustomobject]@{ Pending = $false; Reason = 'NoRecord'; Detail = "winget-app-setup user phase: ignoring $RunRecordPath, which SYSTEM or an administrator must have written: $trustProblem. The next run of the machine phase replaces it." }
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($RunRecordPath)
        $record = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)) -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Pending = $false; Reason = 'NoRecord'; Detail = $null }
    }
    if ($null -eq $record -or $null -eq $record.PSObject.Properties['apps']) {
        return [pscustomobject]@{ Pending = $false; Reason = 'NoRecord'; Detail = $null }
    }
    if ($null -eq $record.exitCode) {
        return [pscustomobject]@{ Pending = $false; Reason = 'RunNotFinished'; Detail = $null }
    }

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $recordSha256 = ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }

    $state = $null
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $state = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($StatePath)) -ErrorAction Stop
        }
        catch {
            $state = $null
        }
    }
    if ($null -ne $state -and [string]::Equals([string]$state.recordSha256, $recordSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($state.complete -eq $true) {
            return [pscustomobject]@{ Pending = $false; Reason = 'Done'; Detail = $null }
        }
        $attempts = 0
        if ($null -ne $state.attempts) {
            $attempts = [int]$state.attempts
        }
        if ($attempts -ge $MaxAttempts) {
            return [pscustomobject]@{ Pending = $false; Reason = 'GaveUp'; Detail = $null }
        }
        return [pscustomobject]@{ Pending = $true; Reason = 'Pending'; Detail = $null }
    }
    return [pscustomobject]@{ Pending = $true; Reason = 'New'; Detail = $null }
}

<#
.SYNOPSIS
    Finds PowerShell 7: machine-wide first (the machine phase installs it there), then on PATH, then
    this user's own MSIX install.
.RETURNS
    [string] pwsh.exe's path, or $null.
#>
function Find-RmmPowerShell7 {
    $candidates = @()
    foreach ($programFiles in @($env:ProgramW6432, $env:ProgramFiles)) {
        if ($programFiles) {
            $candidates += (Join-Path $programFiles 'PowerShell\7\pwsh.exe')
        }
    }
    $onPath = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) {
        $candidates += $onPath.Source
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

<#
.SYNOPSIS
    Joins arguments into one command line, quoted the way Windows programs split it again.
#>
function ConvertTo-RmmArgumentString {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    $quoted = foreach ($argument in $ArgumentList) {
        if ($null -ne $argument -and $argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            $argument
            continue
        }
        $backslash = [char]92
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append([char]34)
        $backslashes = 0
        foreach ($character in "$argument".ToCharArray()) {
            if ($character -eq $backslash) {
                $backslashes++
                continue
            }
            if ($character -eq [char]34) {
                [void]$builder.Append($backslash, 2 * $backslashes + 1)
            }
            elseif ($backslashes -gt 0) {
                [void]$builder.Append($backslash, $backslashes)
            }
            $backslashes = 0
            [void]$builder.Append($character)
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append($backslash, 2 * $backslashes)
        }
        [void]$builder.Append([char]34)
        $builder.ToString()
    }
    return (@($quoted) -join ' ')
}

<#
.SYNOPSIS
    Runs a program in this console and returns its exit code, or $null when it could not be started
    or was stopped at the time limit (with every process it started).
#>
function Invoke-RmmProcessWithTimeout {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList (ConvertTo-RmmArgumentString -ArgumentList $ArgumentList) -NoNewWindow -PassThru -ErrorAction Stop
    }
    catch {
        Write-RmmLine "Could not start ${FilePath}: $($_.Exception.Message)" 'Red'
        return $null
    }
    # Read the handle now: without it, Windows PowerShell's Process object may not report the exit
    # code of a process started this way.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-RmmLine ('{0} did not end within {1} minutes; stopping it.' -f $FilePath, [Math]::Round($TimeoutSeconds / 60)) 'Red'
        try {
            if ($env:OS -eq 'Windows_NT') {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
            }
            else {
                $process.Kill()
            }
        }
        catch {
        }
        return $null
    }
    $process.WaitForExit()
    return $process.ExitCode
}

<#
.SYNOPSIS
    The first part, in any PowerShell: decides whether there is work, gets and checks the
    installer, and runs the user phase under PowerShell 7.
.RETURNS
    [int] The exit code (see the script's notes).
#>
function Invoke-RmmUserPhaseLauncher {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InstallerPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InstallerSha256,

        [Parameter(Mandatory = $false)]
        [int]$MaxMinutes = 15,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PinnedCommit,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PinnedSha256,

        [Parameter(Mandatory = $false)]
        [string]$RunRecordPath = (Join-Path $env:ProgramData 'winget-app-setup\logs\last-run.json'),

        [Parameter(Mandatory = $false)]
        [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'winget-app-setup\user-phase.json'),

        [Parameter(Mandatory = $false)]
        [string]$TempRoot = $env:TEMP
    )

    if (Test-RmmIsSystem) {
        Write-RmmLine 'The user phase installs for the signed-in user, so it has nothing to do as SYSTEM: deploy it as a User Configuration script that runs as the user. The machine phase is rmm/Invoke-WingetAppSetup.ps1.'
        return 0
    }

    $pending = Test-RmmUserPhasePending -RunRecordPath $RunRecordPath -StatePath $StatePath -MaxAttempts $MaxAttempts
    if (-not $pending.Pending) {
        if ($pending.Detail) {
            Write-RmmLine $pending.Detail 'Yellow'
        }
        return 0
    }

    Write-RmmLine ('winget-app-setup user phase: there is work for this account ({0}).' -f $pending.Reason)
    $pwsh = Find-RmmPowerShell7
    if (-not $pwsh) {
        Write-RmmLine 'PowerShell 7 is not installed, and the user phase needs it. The machine phase (rmm/Invoke-WingetAppSetup.ps1) installs it; the next sign-in tries again. Nothing was installed.' 'Red'
        return 7
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        Write-RmmLine 'The user phase must be run as a script file (-File): it runs itself again under PowerShell 7. Nothing was installed.' 'Red'
        return 5
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
    }
    else {
        if (-not (Test-RmmPinnedCommit -Commit $PinnedCommit) -or -not (Test-RmmSha256 -Hash $PinnedSha256)) {
            Write-RmmLine 'This script has no pinned installer yet: set PinnedInstallerCommit and PinnedInstallerSha256 at the top of the script (pwsh -File build/Set-RmmInstallerPin.ps1 -Commit <commit on main>), then upload it again. Nothing was installed.' 'Red'
            return 5
        }
        $url = Get-RmmInstallerUrl -Commit $PinnedCommit
    }

    if ([string]::IsNullOrWhiteSpace($TempRoot)) {
        $TempRoot = [System.IO.Path]::GetTempPath()
    }
    $copyDirectory = Join-Path $TempRoot ('winget-app-setup-userphase-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -Path $copyDirectory -ItemType Directory -Force -ErrorAction Stop)
        $copyPath = Join-Path $copyDirectory 'winget-app-install.ps1'
        if ($url) {
            if (-not (Save-RmmInstallerDownload -Url $url -Destination $copyPath)) {
                Write-RmmLine "Could not download $url; the next sign-in tries again. Nothing was installed." 'Red'
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

        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-RunUserPhaseWith', $copyPath, '-InstallerSha256', $actualSha256, '-MaxMinutes', "$MaxMinutes", '-MaxAttempts', "$MaxAttempts")
        $exitCode = Invoke-RmmProcessWithTimeout -FilePath $pwsh -ArgumentList $arguments -TimeoutSeconds (($MaxMinutes + 5) * 60)
        if ($null -eq $exitCode) {
            Write-RmmLine 'The user phase did not finish; the next sign-in tries again while attempts are left.' 'Red'
            return 5
        }
        return [int]$exitCode
    }
    catch {
        Write-RmmLine "The user phase stopped on an unexpected error: $($_.Exception.Message)" 'Red'
        return 5
    }
    finally {
        Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    The second part, under PowerShell 7: checks the installer copy again, dot-sources it and runs
    Invoke-WingetUserPhase.
.RETURNS
    [int] Invoke-WingetUserPhase's exit code, or 5.
#>
function Invoke-RmmUserPhaseRunner {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InstallerCopyPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstallerSha256,

        [Parameter(Mandatory = $false)]
        [int]$MaxMinutes = 15,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-RmmLine 'The user phase runs under PowerShell 7; this is an older PowerShell. Nothing was installed.' 'Red'
        return 5
    }
    $actualSha256 = Get-RmmFileSha256 -Path $InstallerCopyPath
    if (-not (Test-RmmSha256 -Hash $InstallerSha256) -or $actualSha256 -ne $InstallerSha256.ToUpperInvariant()) {
        Write-RmmLine "The installer copy $InstallerCopyPath changed after it was checked, so it was not run." 'Red'
        return 5
    }
    try {
        # Dot-sourced, the installer only defines its functions: its own run starts only when it is
        # run (if ($MyInvocation.InvocationName -ne '.') in build/fragments/tail.ps1).
        . $InstallerCopyPath
        if (-not (Get-Command -Name 'Invoke-WingetUserPhase' -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-RmmLine 'The pinned winget-app-install.ps1 has no user phase (Invoke-WingetUserPhase): it is from a commit older than the user phase. Pin a newer commit (build/Set-RmmInstallerPin.ps1 refuses one without it). Nothing was installed.' 'Red'
            return 5
        }
        return [int](@(Invoke-WingetUserPhase -MaxMinutes $MaxMinutes -MaxAttempts $MaxAttempts)[-1])
    }
    catch {
        Write-RmmLine "The user phase stopped on an unexpected error: $($_.Exception.Message)" 'Red'
        return 5
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($RunUserPhaseWith) {
        $userPhaseExitCode = Invoke-RmmUserPhaseRunner -InstallerCopyPath $RunUserPhaseWith -InstallerSha256 $InstallerSha256 -MaxMinutes $MaxMinutes -MaxAttempts $MaxAttempts
    }
    else {
        $userPhaseExitCode = Invoke-RmmUserPhaseLauncher -ScriptPath $PSCommandPath -InstallerPath $InstallerPath -InstallerSha256 $InstallerSha256 -MaxMinutes $MaxMinutes -MaxAttempts $MaxAttempts -PinnedCommit $PinnedInstallerCommit -PinnedSha256 $PinnedInstallerSha256
    }
    exit ([int](@($userPhaseExitCode)[-1]))
}
