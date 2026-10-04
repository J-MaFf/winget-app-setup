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
    WingetSourceList  `winget source list` (2 minutes).
    WingetSearch      the `winget search` source health check (2 minutes).
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
        [ValidateSet('WingetInstall', 'WingetDownload', 'WingetListCheck', 'WingetVersion', 'WingetList', 'WingetSourceList', 'WingetSearch', 'WingetSourceReset', 'MsiExec', 'WebDownload', 'WebDownloadStall')]
        [string]$Operation
    )

    switch ($Operation) {
        'WingetInstall' { return 1800 }
        'WingetDownload' { return 1800 }
        'WingetListCheck' { return 15 }
        'WingetVersion' { return 30 }
        'WingetList' { return 120 }
        'WingetSourceList' { return 120 }
        'WingetSearch' { return 120 }
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
