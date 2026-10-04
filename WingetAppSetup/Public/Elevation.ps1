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

    Never asks either when Group Policy's Windows PowerShell execution policy for the PC is AllSigned
    or Restricted (Get-ScriptExecutionPolicyBlock, wgt-gq8.39): -ExecutionPolicy Bypass cannot
    override it, so the elevated window could not run the script. One line says so instead. Such a
    policy for this account only is a warning: it applies only if this account approves the prompt.
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
    Group Policy's execution policy would refuse the script in the elevated window, the prompt was
    declined, or the elevated process could not be started) or 5 (the script could not be read, or
    changed since the run started).
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

    # The elevated Windows PowerShell runs the script with -File, and Group Policy's execution policy
    # overrides -ExecutionPolicy Bypass (wgt-gq8.39). Under a machine policy of AllSigned or
    # Restricted the elevated window refused the file, printed PowerShell's own error and closed at
    # once, and this run passed on its non-zero exit code as the run's result; nothing is started
    # then. A user policy is this account's, and holds only if this same account approves the
    # prompt: a warning.
    $policyBlock = Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell
    if ($policyBlock) {
        $policyMessage = Format-ElevationPolicyBlockMessage -Block $policyBlock
        if ($policyBlock.Scope -eq 'MachinePolicy') {
            Write-ErrorMessage "$policyMessage No UAC prompt was shown."
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }
        Write-WarningMessage $policyMessage
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
