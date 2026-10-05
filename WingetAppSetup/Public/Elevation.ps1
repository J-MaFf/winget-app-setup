# The elevation helpers the entry blocks call: the installer and the uninstaller share them
# instead of each hand-rolling its own admin check and relaunch (issue #190). The rest live in
# Private/Elevation.ps1.

<#
.SYNOPSIS
    Returns whether the current process runs with administrator rights.
.DESCRIPTION
    The one implementation for the installer, the uninstaller and the PowerShell 7 bootstrap. When
    the check itself throws, it warns and returns $true: a broken check then skips the elevated
    relaunch and the run goes on unelevated, where anything that needed elevation fails loudly.
    Assuming non-admin instead could relaunch forever if the check fails the same way in the
    relaunched process. A caller for which proceeding unelevated would be silent or unsafe should
    check the identity itself.
.OUTPUTS
    [bool] $true when elevated, or when the check failed; $false when confirmed not elevated.
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
    Starts System32's powershell.exe (Get-WindowsPowerShellPath), which every account has, after the
    UAC prompt (review finding P2-11): the installer's 5.1 dispatch then finds or installs
    PowerShell 7 as the elevating account in the same window, and the uninstaller runs there as it
    is. Waiting for it lets the run that asked report what the elevated run did.

    The elevated process never runs ScriptPath itself (review finding P3-11), so ScriptPath must be
    a self-contained script: the generated installer or uninstaller. This function reads the file
    once, checks it against -ExpectedSha256 and stages the bytes in this account's %TEMP%, which the
    elevating account can read even when it cannot see ScriptPath (a mapped drive, a share). The
    elevated process checks the staged file against the hash, copies it into a folder only
    administrators can change and runs the copy (New-ElevationVerifierCommand), so a file rewritten
    while the UAC prompt is up is not run. Each run stages and copies into folders of its own, under
    the file's own name. The staged copy is removed once the elevated run ends.

    Never shows a UAC prompt when nobody is at the console (Test-EffectiveNonInteractive), and asks
    once: a declined prompt (1223, ERROR_CANCELLED) is reported, not asked again. Never asks either
    when Group Policy sets the PC's execution policy to AllSigned or Restricted
    (Get-ScriptExecutionPolicyBlock), which -ExecutionPolicy Bypass cannot override; such a policy
    for this account only is a warning, and the checked copy's window checks the approving
    account's.
.PARAMETER ScriptPath
    The full path of the script to run elevated.
.PARAMETER AdditionalArguments
    Switch names forwarded to the elevated run (for example '-SkipSystemCheck'). Only switch names
    are accepted: they become part of a command line.
.PARAMETER ExpectedSha256
    The script's SHA256 when this run started; nothing is started when the file no longer has it.
    Empty: the hash is taken now.
.PARAMETER NonInteractive
    The caller's -NonInteractive switch.
.OUTPUTS
    [pscustomobject] @{ Started; ExitCode }. Started is $true when an elevated run started, and
    ExitCode is then its exit code (4 when its window found the execution policy would refuse the
    script, 5 when the file changed). Otherwise ExitCode is 4 (no prompt in a non-interactive run,
    an execution policy that would refuse the script, a declined prompt, or a process that could
    not start) or 5 (the script could not be read, or changed since the run started).
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
        [switch]$NonInteractive
    )

    if (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) {
        Write-ErrorMessage 'Administrator rights are required, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM.'
        return [pscustomobject]@{ Started = $false; ExitCode = 4 }
    }

    # Group Policy's execution policy overrides the elevated window's -ExecutionPolicy Bypass, so
    # the PC's AllSigned or Restricted stops here. This account's own policy holds only if this
    # account approves the prompt: a warning, and the checked copy's window checks the approver's.
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
    # Staged in this account's %TEMP%, which administrators can read: the elevated account may not
    # see ScriptPath (a mapped drive belongs to the signed-in session). The elevated process checks
    # the staged copy against the hash all the same.
    $stagingDirectory = $null
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
    # -ExecutionPolicy Bypass as for the copy it runs, so the check's Get-ExecutionPolicy sees only a
    # policy Group Policy sets.
    $argumentString = ConvertTo-ProcessArgumentString -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $verifierCommand)

    try {
        # ShellExecuteEx, which starts an elevated process, accepts a command line of about 2048
        # characters; a longer one would not start or would arrive cut off. It holds the staged
        # copy's path and the file name, not the folder ScriptPath is in, so moving the file would
        # not help.
        if ($argumentString.Length -gt 2000) {
            Write-ErrorMessage "The command that starts $ScriptPath elevated is too long, because the file name or this account's %TEMP% path ($([System.IO.Path]::GetTempPath())) is long. Give the file a shorter name, or start it from an elevated session."
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }

        # The elevated Windows PowerShell legitimately enters the PowerShell 7 bootstrap, so it must
        # not inherit this process's relaunch-loop guard.
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
