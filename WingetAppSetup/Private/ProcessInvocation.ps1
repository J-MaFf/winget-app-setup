# One way to run winget and msiexec: a time limit, the output in the transcript, and a failed launch
# classified by its Win32 code (P2-5, P2-6, P3-6). Invoke-WingetProcess adds what is specific to
# winget. Both run under Windows PowerShell 5.1 too (the PowerShell 7 bootstrap installs pwsh with
# winget), so .NET Framework 4.5 APIs only: ProcessStartInfo.Arguments, not ArgumentList, and
# taskkill, not Kill($true).

<#
.SYNOPSIS
    Returns the time limit, in seconds, for one kind of external process call: the one place the
    limits live.
.DESCRIPTION
    When a limit runs out, the process tree is stopped and the call reports TimedOut. The limits are
    generous: they keep a hung installer or a stalled download from stopping an unattended run
    forever, not a slow machine from finishing.
.PARAMETER Operation
    WingetInstall     one `winget install`, its download, installer and wait for another winget
                      install included (30 minutes).
    WingetDownload    one `winget download` (30 minutes).
    WingetUninstall   one `winget uninstall`, the app's own uninstaller included; or, for a catalog
                      entry with quietUninstall, its own uninstaller run directly and the wait
                      for its uninstall entry to go (15 minutes).
    WingetListCheck   the per-app `winget list` check before and after an install (15 seconds).
    WingetVersion     the `winget --version` launch check (30 seconds; no network or source I/O).
    WingetSourceUpdate `winget source update`, before the installs (2 minutes).
    WingetSourceOpen  the `winget search --source winget` that checks winget can open its source
                      after that update, which downloads the source first when it is missing (2
                      minutes).
    WingetSourceReset `winget source reset`, which downloads the source again (5 minutes).
    WingetClientProbe the Microsoft.WinGet.Client engine's start-of-run probe in a child pwsh: the
                      module load, Get-WinGetVersion and one Get-WinGetPackage (3 minutes).
    WingetClientVersion Get-WinGetVersion in a child pwsh, the engine's launch check (60 seconds).
    WingetClientListCheck the engine's per-app Get-WinGetPackage check in a child pwsh, which
                      starts pwsh and loads the module each time (45 seconds).
    MsiExec           one msiexec install or uninstall (15 minutes).
    AppxProvisioning  one Add-AppxProvisionedPackage, run in Windows PowerShell (10 minutes).
    AppxRegistration  one Add-AppxPackage for this account (a registration, or an .msix such as the
                      winget source package), run in Windows PowerShell (5 minutes).
    AppxQuery         one Get-AppxPackage -AllUsers, run in Windows PowerShell (2 minutes).
    WebDownload       a file download's connection and wait for the response headers (5 minutes);
                      Invoke-WebRequest's -TimeoutSec does not cover the body.
    WebDownloadStall  how long a download may receive nothing once the file is arriving, on
                      PowerShell 7.4 and newer (2 minutes).
    WebLookup         a small file the run can do without, such as the latest winget release's
                      DesktopAppInstaller_Dependencies.json (30 seconds, for both of the above).
.OUTPUTS
    [int] Seconds.
#>
function Get-ProcessTimeoutSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('WingetInstall', 'WingetDownload', 'WingetUninstall', 'WingetListCheck', 'WingetVersion', 'WingetSourceUpdate', 'WingetSourceOpen', 'WingetSourceReset', 'WingetClientProbe', 'WingetClientVersion', 'WingetClientListCheck', 'MsiExec', 'AppxProvisioning', 'AppxRegistration', 'AppxQuery', 'WebDownload', 'WebDownloadStall', 'WebLookup')]
        [string]$Operation
    )

    switch ($Operation) {
        'WingetInstall' { return 1800 }
        'WingetDownload' { return 1800 }
        'WingetUninstall' { return 900 }
        'WingetListCheck' { return 15 }
        'WingetVersion' { return 30 }
        'WingetSourceUpdate' { return 120 }
        'WingetSourceOpen' { return 120 }
        'WingetSourceReset' { return 300 }
        'WingetClientProbe' { return 180 }
        'WingetClientVersion' { return 60 }
        'WingetClientListCheck' { return 45 }
        'MsiExec' { return 900 }
        'AppxProvisioning' { return 600 }
        'AppxRegistration' { return 300 }
        'AppxQuery' { return 120 }
        'WebDownload' { return 300 }
        'WebDownloadStall' { return 120 }
        'WebLookup' { return 30 }
    }
}

<#
.SYNOPSIS
    Returns the time-limit parameters for an Invoke-WebRequest download, for splatting.
.DESCRIPTION
    -TimeoutSec bounds only the connection and the response headers; PowerShell 7.4+ adds
    -OperationTimeoutSeconds, which bounds a stall while the body arrives. Both are passed where they
    exist; on 7.3 and older a download that stops mid-file still waits for ever.
.PARAMETER Lookup
    For a small file the run can do without (WebLookup): both limits are 30 seconds instead of the
    download limits.
.OUTPUTS
    [hashtable] TimeoutSec, plus OperationTimeoutSeconds when Invoke-WebRequest has it.
#>
function Get-WebDownloadTimeoutParameters {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Lookup
    )

    $timeoutOperation = 'WebDownload'
    $stallOperation = 'WebDownloadStall'
    if ($Lookup) {
        $timeoutOperation = 'WebLookup'
        $stallOperation = 'WebLookup'
    }
    $parameters = @{ TimeoutSec = (Get-ProcessTimeoutSeconds -Operation $timeoutOperation) }
    $command = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ($command -and $command.Parameters -and $command.Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $parameters['OperationTimeoutSeconds'] = (Get-ProcessTimeoutSeconds -Operation $stallOperation)
    }
    return $parameters
}

<#
.SYNOPSIS
    Joins arguments into one command line, quoted the way Windows programs split it again.
.DESCRIPTION
    For ProcessStartInfo.Arguments, since ArgumentList does not exist on .NET Framework (5.1). An
    argument that is empty or holds white space or a double quote is wrapped in double quotes, with
    backslashes before a quote doubled, as CommandLineToArgvW reads it back. Others pass unchanged.
.PARAMETER ArgumentList
    The arguments, one per element.
.OUTPUTS
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
    Walks the InnerException chain to the Win32Exception Process.Start threw, so a launch failure is
    classified by its code, the same in every display language, not by its translated message.
.PARAMETER Exception
    The caught exception.
.OUTPUTS
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
.OUTPUTS
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
    Redirected, winget still draws its spinner (- \ | /) and progress bar, each update a line of
    its own. 'Status' is the spinner with a message, redrawn every 250 ms while winget waits, such
    as '   - Waiting for another install/uninstall to complete...'.
.PARAMETER Line
    A line already passed through ConvertTo-PlainProcessLine.
.OUTPUTS
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
    The filter Write-ProcessOutput and Invoke-ExternalProcess's live echo share:
      - 'Blank' and 'Spinner' lines are dropped;
      - of a run of 'Progress' updates only the last is shown, before the next shown line or at
        -Flush;
      - a 'Status' line is shown once per run of the same message (the spinner character is not
        compared), or a wait for another install would print four lines a second for 30 minutes;
      - 'Text' lines are always shown.
.PARAMETER State
    A hashtable the caller keeps for one run of output, empty to begin with.
.PARAMETER Line
    The next line, already passed through ConvertTo-PlainProcessLine.
.PARAMETER Flush
    End of the output: return the progress update still held back, if any.
.OUTPUTS
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
    A transcript records only what PowerShell writes to the host, never a child process's own
    console output (P2-6), so the lines go out through Write-Host, indented and filtered by
    Select-ProcessOutputLine. For callers that capture quietly, for example to show the output only
    when a command failed.
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
    A timed-out winget usually waits on its installer, which would otherwise keep running and hold
    the Windows Installer mutex and the output pipes. On Windows `taskkill /PID <id> /T /F` (works
    under 5.1); elsewhere, or when taskkill fails, Process.Kill(true), then Process.Kill().
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
    The process primitive behind every winget and msiexec call:
      - A bare program name is resolved on PATH with Get-Command, so the current directory is never
        searched.
      - Standard output and error are read line by line as they arrive and, with -Echo Live, written
        to the host (Write-ProcessOutput's filter), so they reach the transcript. Standard input is
        closed: nothing may wait for a key press.
      - When TimeoutSeconds runs out, the process tree is stopped (Stop-ProcessTree) and the result
        says TimedOut. Output a leftover child keeps open is read for a few seconds more, then left.
      - A launch failure never throws: the result says LaunchFailed, with LaunchErrorCode (2 not
        found, 5 access denied, 32 sharing violation, 1920 the file cannot be accessed).
    The exit code comes from the process object, so it cannot go stale as $LASTEXITCODE does.
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
.PARAMETER Encoding
    The encoding the program writes its output in. Default UTF-8, which winget always writes.
    Windows PowerShell writes redirected output in the console's code page, so
    Invoke-AppxProvisioning passes [Console]::OutputEncoding.
.PARAMETER RemoveEnvironmentVariable
    Environment variables the program starts without; the rest of this process's environment is
    passed on, and this process's own environment does not change (PSModulePath, for Windows
    PowerShell started from PowerShell 7).
.OUTPUTS
    [pscustomobject] with FilePath, Arguments, ExitCode ($null when the process timed out or did
    not start), TimedOut, LaunchFailed, LaunchErrorCode, LaunchError (message), LaunchException,
    Output (standard output and standard error lines in arrival order, control sequences removed),
    StandardOutput, StandardError, DurationSeconds, LogPath ($null; Invoke-WingetProcess sets it),
    ProcessId, StartedAtUtc (just before the start) and ExitedAtUtc (when it exited by itself), the
    last three $null when they do not apply: a caller can find what the process left running.
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
        [string]$Echo = 'Live',

        [Parameter(Mandatory = $false)]
        [System.Text.Encoding]$Encoding,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$RemoveEnvironmentVariable = @()
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
        ProcessId       = $null
        StartedAtUtc    = $null
        ExitedAtUtc     = $null
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
    if (-not $Encoding) {
        $Encoding = New-Object System.Text.UTF8Encoding($false)
    }
    $startInfo.StandardOutputEncoding = $Encoding
    $startInfo.StandardErrorEncoding = $Encoding
    # EnvironmentVariables starts as a copy of this process's environment (.NET Framework and .NET
    # alike); removing a name there leaves this process's own environment as it is.
    foreach ($name in @($RemoveEnvironmentVariable)) {
        if (-not [string]::IsNullOrEmpty($name)) {
            [void]$startInfo.EnvironmentVariables.Remove($name)
        }
    }

    if ($Echo -eq 'Live') {
        Write-Host ('  > {0} {1}' -f $displayName, $arguments).TrimEnd() -ForegroundColor DarkGray
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $startedAtUtc = [DateTime]::UtcNow
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
    $result.ProcessId = $process.Id
    $result.StartedAtUtc = $startedAtUtc

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
        try {
            $result.ExitedAtUtc = $process.ExitTime.ToUniversalTime()
        }
        catch {
            $result.ExitedAtUtc = [DateTime]::UtcNow
        }
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
    Runs a script in Windows PowerShell 5.1, with a time limit, and returns the process result.
.DESCRIPTION
    For the Appx cmdlets, which cannot load under PowerShell 7 before Windows build 10.0.22453
    (0x80131539) and always load in 5.1. As -EncodedCommand, so no quoting changes the script, with
    UTF-8 output, so localized error text arrives intact, and without PSModulePath: inherited
    through Process.Start, PowerShell 7's module folders come first and their Utility and Security
    modules cannot load in 5.1 (about_PSModulePath). Nothing is echoed.
.PARAMETER Script
    The script.
.PARAMETER TimeoutSeconds
    The time limit (see Get-ProcessTimeoutSeconds).
.PARAMETER FilePath
    The powershell.exe to run. Default: Get-WindowsPowerShellPath.
.OUTPUTS
    Invoke-ExternalProcess's result.
#>
function Invoke-WindowsPowerShellScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [string]$FilePath
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $FilePath = Get-WindowsPowerShellPath
    }
    $prologue = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $ProgressPreference = ''SilentlyContinue''; '
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($prologue + $Script))
    return (Invoke-ExternalProcess -FilePath $FilePath -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -TimeoutSeconds $TimeoutSeconds -Echo None -RemoveEnvironmentVariable @('PSModulePath'))
}

<#
.SYNOPSIS
    Returns the folder this run's logs go to: that of $script:InstallLogPath, which the entry script
    sets first. $null without a transcript or outside the installer, and then no installer log is
    requested.
.OUTPUTS
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
    Returns a new path for one installer log in the run's logs folder, or $null.
.DESCRIPTION
    winget-<subcommand>-<package id>-<yyyyMMdd-HHmmss>[-<n>].log, the name diagnostics and
    housekeeping look for, with -<n> added when that file exists. The folder is created first:
    msiexec fails the install (1622) when it cannot open its log. $null when there is no logs folder
    or it cannot be created: no installer log is better than an install that fails over it. Used by
    Invoke-WingetProcess (--log) and Invoke-WingetClientInstall (-Log).
.PARAMETER Subcommand
    install, upgrade, uninstall or repair.
.PARAMETER PackageId
    The package id; characters other than letters, digits, '.', '-' and '_' become '_'. Empty:
    'winget'.
.PARAMETER LogDirectory
    The folder. Default: Get-InstallerLogDirectory. Empty: no log.
.OUTPUTS
    [string] or $null.
#>
function New-WingetInstallerLogPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Subcommand,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory
    )

    $directory = $LogDirectory
    if (-not $PSBoundParameters.ContainsKey('LogDirectory')) {
        $directory = Get-InstallerLogDirectory
    }
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return $null
    }
    $label = 'winget'
    if (-not [string]::IsNullOrWhiteSpace($PackageId)) {
        $label = $PackageId -replace '[^\w.\-]', '_'
    }
    try {
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop)
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $candidate = Join-Path $directory ('winget-{0}-{1}-{2}.log' -f $Subcommand, $label, $stamp)
        $suffix = 2
        while (Test-Path -LiteralPath $candidate) {
            $candidate = Join-Path $directory ('winget-{0}-{1}-{2}-{3}.log' -f $Subcommand, $label, $stamp, $suffix)
            $suffix++
        }
        return $candidate
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Runs winget through Invoke-ExternalProcess, with its installer log in the run's logs folder.
.DESCRIPTION
    Resolves winget with Resolve-WingetExecutable unless a path is given. For install, upgrade,
    uninstall and repair it adds `--log <file>` (New-WingetInstallerLogPath: named after the
    subcommand, the package id and the time, in the logs folder), so a failed installer's log sits
    next to the transcript. Nothing is added when the caller passes --log or -o, or there is no
    logs folder.
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
.OUTPUTS
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
        $logParameters = @{ Subcommand = $subcommand }
        $idIndex = [array]::IndexOf($arguments, '--id')
        if ($idIndex -ge 0 -and $idIndex + 1 -lt $arguments.Count) {
            $logParameters['PackageId'] = [string]$arguments[$idIndex + 1]
        }
        if ($PSBoundParameters.ContainsKey('LogDirectory')) {
            $logParameters['LogDirectory'] = $LogDirectory
        }
        $logPath = New-WingetInstallerLogPath @logParameters
        if ($logPath) {
            $arguments += @('--log', $logPath)
        }
    }

    $result = Invoke-ExternalProcess -FilePath $WingetPath -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -Echo $Echo
    $result.LogPath = $logPath
    return $result
}
