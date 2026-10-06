# The opt-in install engine of runs as SYSTEM (wgt-gq8.42): the Microsoft.WinGet.Client module,
# which Microsoft supports as SYSTEM where the winget command line is not. Each module call runs in
# a child pwsh under Invoke-ExternalProcess, so the per-call time limits and the tree kill still
# apply, and its result comes back as one JSON line that maps onto winget's own result codes.

<#
.SYNOPSIS
    Reads which install engine a run as SYSTEM should use, from WINGET_APP_SETUP_SYSTEM_ENGINE.
.DESCRIPTION
    'WinGetClient' opts in to Microsoft.WinGet.Client; 'Cli', unset or empty keeps winget.exe. The
    value is trimmed and compared ignoring case. Any other value is warned about and means Cli.
    rmm/Invoke-WingetAppSetup.ps1 -SystemInstallEngine sets the variable for the installer.
.OUTPUTS
    [pscustomobject] with Engine ('Cli' or 'WinGetClient'), Source ('Default' when the variable is
    unset or empty, else 'Environment') and RawValue (the variable as set, or $null).
#>
function Get-SystemInstallEngineRequest {
    $raw = [System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_SYSTEM_ENGINE')
    $value = "$raw".Trim()
    if ($value.Length -eq 0) {
        return [pscustomobject]@{ Engine = 'Cli'; Source = 'Default'; RawValue = $raw }
    }
    if ($value -eq 'WinGetClient') {
        return [pscustomobject]@{ Engine = 'WinGetClient'; Source = 'Environment'; RawValue = $raw }
    }
    if ($value -ne 'Cli') {
        Write-WarningMessage "WINGET_APP_SETUP_SYSTEM_ENGINE='$raw' is not Cli or WinGetClient; using winget.exe."
    }
    return [pscustomobject]@{ Engine = 'Cli'; Source = 'Environment'; RawValue = $raw }
}

<#
.SYNOPSIS
    Builds the run record's installEngine entry: which engine was asked for and which installed.
.PARAMETER Requested
    'Cli' or 'WinGetClient'. Default 'Cli'.
.PARAMETER Used
    'Cli' or 'WinGetClient'. Default 'Cli'.
.PARAMETER Module
    Initialize-WingetClientModule's result, when the module installed the apps.
.PARAMETER EngineVersion
    What Get-WinGetVersion answered, when the module installed the apps.
.PARAMETER FallbackReason
    Why the requested module was not used.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] requested, used, module ($null, or name,
    version, sha256 and engineVersion) and fallbackReason ($null when there was no fallback).
#>
function New-InstallEngineRecord {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$Requested = 'Cli',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$Used = 'Cli',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Module,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$EngineVersion,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FallbackReason
    )

    $moduleRecord = $null
    if ($Used -eq 'WinGetClient' -and $null -ne $Module) {
        $engineVersionText = $null
        if (-not [string]::IsNullOrWhiteSpace($EngineVersion)) {
            $engineVersionText = $EngineVersion
        }
        $moduleRecord = [ordered]@{
            name          = 'Microsoft.WinGet.Client'
            version       = [string]$Module.Version
            sha256        = [string]$Module.Sha256
            engineVersion = $engineVersionText
        }
    }
    $reasonText = $null
    if (-not [string]::IsNullOrWhiteSpace($FallbackReason)) {
        $reasonText = $FallbackReason
    }
    return [ordered]@{
        requested      = $Requested
        used           = $Used
        module         = $moduleRecord
        fallbackReason = $reasonText
    }
}

<#
.SYNOPSIS
    Returns this run's installEngine entry ($script:InstallEngineRecord), or the winget.exe one
    when the run has not set it.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] (New-InstallEngineRecord).
#>
function Get-InstallEngineRecord {
    if ($script:InstallEngineRecord -is [System.Collections.IDictionary]) {
        return $script:InstallEngineRecord
    }
    return (New-InstallEngineRecord)
}

<#
.SYNOPSIS
    Returns whether this run installs with Microsoft.WinGet.Client.
.OUTPUTS
    [bool] True once Initialize-WingetClientEngine found it ready, until Remove-WingetClientEngine.
#>
function Test-WingetClientEngineActive {
    return ($null -ne $script:WingetClientEngine)
}

<#
.SYNOPSIS
    Returns the folders the module's engine writes its own logs (WinGetCOM-*.log) to.
.DESCRIPTION
    The engine logs to its temp folder's WinGet\defaultState. As SYSTEM that can be
    %SystemRoot%\SystemTemp (GetTempPath2) or the TMP/TEMP folder, so both are named; built from the
    environment, never from GetTempPath(), which answers for this process only.
.OUTPUTS
    [string[]] One or two folders, the SystemTemp one first when it exists.
#>
function Get-WingetEngineLogDirectory {
    $folders = @()
    $windowsDirectory = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $windowsDirectory = $env:windir
    }
    if (-not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $systemTemp = $windowsDirectory.TrimEnd('\', '/') + '\SystemTemp'
        if (Test-Path -LiteralPath $systemTemp -PathType Container) {
            $folders += $systemTemp + '\WinGet\defaultState'
        }
    }
    $temp = $null
    foreach ($candidate in @($env:TMP, $env:TEMP)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $temp = $candidate
            break
        }
    }
    if (-not $temp -and -not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $temp = $windowsDirectory.TrimEnd('\', '/') + '\Temp'
    }
    if ($temp) {
        $folder = $temp.TrimEnd('\', '/') + '\WinGet\defaultState'
        if (@($folders | Where-Object { [string]::Equals($_, $folder, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            $folders += $folder
        }
    }
    return [string[]]$folders
}

<#
.SYNOPSIS
    Prints the run's 'Install engine: ' line, once, in a run as SYSTEM.
.DESCRIPTION
    'Install engine: Microsoft.WinGet.Client <version> (WinGet engine <version>, PowerShell <version>
    <arch>; engine log folder <folder>).', 'Install engine: winget.exe (<path>).', or, when the
    module was asked for and is not used, 'Install engine: winget.exe (<path>), not the requested
    Microsoft.WinGet.Client: <reason>.' e2e/TranscriptAssertions.ps1 reads it.
#>
function Write-InstallEngineLine {
    $engine = $script:WingetClientEngine
    if ($null -ne $engine) {
        Write-Info ('Install engine: Microsoft.WinGet.Client {0} (WinGet engine {1}, PowerShell {2} {3}; engine log folder {4}).' -f $engine.Module.Version, $engine.EngineVersion, $engine.PowerShellVersion, $engine.Module.Architecture, (@(Get-WingetEngineLogDirectory) -join ' or '))
        return
    }
    $path = $script:MachineWingetPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = 'none found'
    }
    $record = Get-InstallEngineRecord
    if ($record.requested -eq 'WinGetClient') {
        Write-Info ('Install engine: winget.exe ({0}), not the requested Microsoft.WinGet.Client: {1}.' -f $path, "$($record.fallbackReason)".TrimEnd('.'))
        return
    }
    Write-Info ('Install engine: winget.exe ({0}).' -f $path)
}

<#
.SYNOPSIS
    Reads the result line a Microsoft.WinGet.Client request printed.
.DESCRIPTION
    The last standard output line 'WINGET-CLIENT-RESULT {json}' (Get-WingetClientChildScript),
    which must be protocol 1. No such line, JSON that does not parse, or another protocol is a
    protocol error.
.PARAMETER StandardOutput
    The child's standard output lines.
.PARAMETER StandardError
    The child's standard error lines, for the protocol error.
.PARAMETER ExitCode
    The child's exit code, for the protocol error.
.OUTPUTS
    [pscustomobject] with Response (the parsed result, or $null) and ProtocolError ($null, or why
    there is no result).
#>
function ConvertFrom-WingetClientResponse {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$StandardOutput,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$StandardError,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    $json = $null
    foreach ($line in @($StandardOutput)) {
        if ("$line" -match '^WINGET-CLIENT-RESULT (\{.*\})$') {
            $json = $Matches[1]
        }
    }
    if ($null -eq $json) {
        $codeText = 'none'
        if ($null -ne $ExitCode) {
            $codeText = [string]$ExitCode
        }
        $detail = ''
        $lastError = @($StandardError | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
        if ($lastError) {
            $detail = ': ' + "$lastError".Trim()
        }
        return [pscustomobject]@{ Response = $null; ProtocolError = "the WinGet client request ended without a result (exit code $codeText)$detail" }
    }
    try {
        $response = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Response = $null; ProtocolError = "the WinGet client request's result is not valid JSON: $($_.Exception.Message)" }
    }
    if ($null -eq $response -or "$($response.protocol)" -ne '1') {
        return [pscustomobject]@{ Response = $null; ProtocolError = "the WinGet client request answered in protocol '$($response.protocol)', not 1" }
    }
    return [pscustomobject]@{ Response = $response; ProtocolError = $null }
}

<#
.SYNOPSIS
    Runs one Microsoft.WinGet.Client request in a child pwsh and reads its result.
.DESCRIPTION
    The child script (Get-WingetClientChildScript) runs under Invoke-ExternalProcess with
    -NoProfile -NonInteractive, quietly and under the given time limit; on a timeout the child and
    the installer it started are stopped.
.PARAMETER Module
    Initialize-WingetClientModule's ready result. Default: the active engine's.
.PARAMETER Operation
    'Probe', 'Version', 'Installed' or 'Install'.
.PARAMETER PackageId
    The package id, for Installed and Install.
.PARAMETER InstallerType
    Install-WinGetPackage -InstallerType, for Install.
.PARAMETER Mode
    Install-WinGetPackage -Mode: 'Silent' (default) or 'Default'.
.PARAMETER Log
    Install-WinGetPackage -Log: the installer log's full path.
.PARAMETER TimeoutSeconds
    The time limit (Get-ProcessTimeoutSeconds).
.OUTPUTS
    [pscustomobject] with Run (Invoke-ExternalProcess's result), Response
    (ConvertFrom-WingetClientResponse's, or $null) and ProtocolError ($null when there is a
    response, or the child did not run to the end).
#>
function Invoke-WingetClientRequest {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Module,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Probe', 'Version', 'Installed', 'Install')]
        [string]$Operation,

        [Parameter(Mandatory = $false)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Silent', 'Default')]
        [string]$Mode = 'Silent',

        [Parameter(Mandatory = $false)]
        [string]$Log,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($null -eq $Module -and $null -ne $script:WingetClientEngine) {
        $Module = $script:WingetClientEngine.Module
    }
    if ($null -eq $Module -or -not $Module.Ready) {
        throw [System.InvalidOperationException]::new('Invoke-WingetClientRequest: the Microsoft.WinGet.Client module is not ready.')
    }

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', [string]$Module.ChildScriptPath, '-ModuleManifest', [string]$Module.ManifestPath, '-ExpectedVersion', [string]$Module.Version, '-Operation', $Operation)
    if (-not [string]::IsNullOrWhiteSpace($PackageId)) {
        $arguments += @('-PackageId', $PackageId)
    }
    if ($Operation -eq 'Install') {
        $arguments += @('-Mode', $Mode)
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $arguments += @('-InstallerType', $InstallerType)
        }
        if (-not [string]::IsNullOrWhiteSpace($Log)) {
            $arguments += @('-Log', $Log)
        }
    }

    $run = Invoke-ExternalProcess -FilePath ([string]$Module.PowerShellPath) -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -Echo None
    $response = $null
    $protocolError = $null
    if (-not $run.LaunchFailed -and -not $run.TimedOut) {
        $parsed = ConvertFrom-WingetClientResponse -StandardOutput $run.StandardOutput -StandardError $run.StandardError -ExitCode $run.ExitCode
        $response = $parsed.Response
        $protocolError = $parsed.ProtocolError
    }
    return [pscustomobject]@{ Run = $run; Response = $response; ProtocolError = $protocolError }
}

<#
.SYNOPSIS
    Maps a Microsoft.WinGet.Client exception chain onto the winget result code winget.exe would
    have exited with.
.DESCRIPTION
    By exception name, outermost first: NoPackageFoundException 0x8A150014, VagueCriteriaException
    0x8A150016, InvalidSourceException 0x8A150012, GroupPolicyException 0x8A15003A,
    CatalogConnectException its inner HRESULT (else 0x8A150045), FindPackagesException its own
    HRESULT when it is winget's (0x8A15....), else 0x8A150003. Anything else: the first winget
    HRESULT in the chain, else the outermost HRESULT when negative, else 0x8A150001.
.PARAMETER Exceptions
    The child's exception records (type, name, hresult, message), outermost first.
.OUTPUTS
    [int]
#>
function Get-WingetClientExceptionCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Exceptions
    )

    # Signed Int32: 0x8A150014 NO_APPLICATIONS_FOUND, 0x8A150016 MULTIPLE_APPLICATIONS_FOUND,
    # 0x8A150012 SOURCE_NAME_DOES_NOT_EXIST, 0x8A15003A BLOCKED_BY_POLICY.
    $byName = @{
        NoPackageFoundException = -1978335212
        VagueCriteriaException  = -1978335210
        InvalidSourceException  = -1978335214
        GroupPolicyException    = -1978335174
    }
    $sourceOpenFailed = -1978335163
    $commandFailed = -1978335229
    $internalError = -1978335231
    $chain = @($Exceptions | Where-Object { $null -ne $_ })
    for ($index = 0; $index -lt $chain.Count; $index++) {
        $name = [string]$chain[$index].name
        if ($byName.ContainsKey($name)) {
            return $byName[$name]
        }
        if ($name -eq 'CatalogConnectException') {
            if ($index + 1 -lt $chain.Count -and [long]$chain[$index + 1].hresult -lt 0) {
                return [int]$chain[$index + 1].hresult
            }
            return $sourceOpenFailed
        }
        if ($name -eq 'FindPackagesException') {
            $own = [int]$chain[$index].hresult
            if (('0x{0:X8}' -f $own).StartsWith('0x8A15')) {
                return $own
            }
            return $commandFailed
        }
    }
    foreach ($record in $chain) {
        if (('0x{0:X8}' -f [int]$record.hresult).StartsWith('0x8A15')) {
            return [int]$record.hresult
        }
    }
    if ($chain.Count -gt 0 -and [long]$chain[0].hresult -lt 0) {
        return [int]$chain[0].hresult
    }
    return $internalError
}

<#
.SYNOPSIS
    Turns a Microsoft.WinGet.Client request into the result Install-WingetPackage and the checks
    read: an exit code as winget.exe would have returned it, or why there is none.
.DESCRIPTION
    Failure says which kind of outcome it was:
      Launch    pwsh could not be started: LaunchFailed, LaunchErrorCode and LaunchError as
                Invoke-ExternalProcess reported them.
      Timeout   the request ran out of time and was stopped: TimedOut, ExitCode $null.
      Protocol  no valid result line; Load  the module did not load, or the call failed with an
                exception that means it cannot work here (WindowsPowerShellNotSupported,
                WinGetIntegrityException, SingleThreadedApartmentException,
                TypeInitializationException, DllNotFoundException, BadImageFormatException,
                FileNotFoundException, FileLoadException). Both: LaunchFailed, LaunchErrorCode
                $null, LaunchError 'the WinGet client engine could not start: ...'.
      Call      the call threw: ExitCode from Get-WingetClientExceptionCode.
      $null     an answer. Install: Status Ok is 0; a failed Status is its HRESULT, or by Status
                when it has none (NoApplicableInstallers 0x8A150010, BlockedByPolicy 0x8A15003A,
                PackageAgreementsNotAccepted 0x8A150041, NoApplicableUpgrade 0x8A15002B,
                CatalogError 0x8A150045, InvalidOptions 0x8A150002, ManifestError and
                InternalError 0x8A150001, any other 0x8A150003). Other operations: 0.
    InstallerErrorCode is the installer's own exit code; RebootRequired is never set by the module.
.PARAMETER Request
    Invoke-WingetClientRequest's result.
.OUTPUTS
    [pscustomobject] with Failure, ExitCode, TimedOut, LaunchFailed, LaunchErrorCode, LaunchError,
    Status (the install Status, or the exception's name), InstallerErrorCode and Detail (a short
    'name: message' of the exception, or $null).
#>
function Get-WingetClientResultCode {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Request
    )

    $result = [pscustomobject]@{
        Failure            = $null
        ExitCode           = $null
        TimedOut           = $false
        LaunchFailed       = $false
        LaunchErrorCode    = $null
        LaunchError        = $null
        Status             = $null
        InstallerErrorCode = $null
        Detail             = $null
    }
    $run = $Request.Run
    if ($run -and $run.LaunchFailed) {
        $result.Failure = 'Launch'
        $result.LaunchFailed = $true
        $result.LaunchErrorCode = $run.LaunchErrorCode
        $result.LaunchError = $run.LaunchError
        return $result
    }
    if ($run -and $run.TimedOut) {
        $result.Failure = 'Timeout'
        $result.TimedOut = $true
        return $result
    }
    $response = $Request.Response
    if ($null -eq $response) {
        $protocolError = [string]$Request.ProtocolError
        if ([string]::IsNullOrWhiteSpace($protocolError)) {
            $protocolError = 'the WinGet client request returned no result'
        }
        $result.Failure = 'Protocol'
        $result.LaunchFailed = $true
        $result.LaunchError = "the WinGet client engine could not start: $protocolError"
        return $result
    }

    $exceptions = @($response.exceptions | Where-Object { $null -ne $_ })
    $formatException = {
        param ($Record)
        if ($null -eq $Record) {
            return 'no exception was reported'
        }
        return ('{0}: {1}' -f $Record.name, "$($Record.message)".Trim().TrimEnd('.'))
    }
    $loadClass = @('WindowsPowerShellNotSupported', 'WinGetIntegrityException', 'SingleThreadedApartmentException', 'TypeInitializationException', 'DllNotFoundException', 'BadImageFormatException', 'FileNotFoundException', 'FileLoadException')
    $loadRecord = $null
    if ([string]$response.stage -eq 'load') {
        if ($exceptions.Count -gt 0) {
            $loadRecord = $exceptions[0]
        }
        else {
            $loadRecord = [pscustomobject]@{ name = 'LoadFailed'; message = 'the module did not load' }
        }
    }
    elseif ($response.ok -ne $true) {
        $loadRecord = @($exceptions | Where-Object { $loadClass -contains [string]$_.name }) | Select-Object -First 1
    }
    if ($null -ne $loadRecord) {
        $result.Failure = 'Load'
        $result.LaunchFailed = $true
        $result.Detail = & $formatException $loadRecord
        $result.LaunchError = 'the WinGet client engine could not start: ' + $result.Detail
        return $result
    }
    if ($response.ok -ne $true) {
        $result.Failure = 'Call'
        $result.ExitCode = Get-WingetClientExceptionCode -Exceptions $exceptions
        if ($exceptions.Count -gt 0) {
            $result.Status = [string]$exceptions[0].name
            $result.Detail = & $formatException $exceptions[0]
        }
        else {
            $result.Status = 'Exception'
            $result.Detail = 'the call failed without an exception'
        }
        return $result
    }

    if ([string]$response.operation -ne 'Install') {
        $result.ExitCode = 0
        return $result
    }
    $status = [string]$response.status
    $result.Status = $status
    if ($null -ne $response.installerErrorCode) {
        $result.InstallerErrorCode = [long]$response.installerErrorCode
    }
    if ($status -eq 'Ok') {
        $result.ExitCode = 0
    }
    elseif ($null -ne $response.hresult -and [long]$response.hresult -lt 0) {
        $result.ExitCode = [int]$response.hresult
    }
    else {
        # Signed Int32 forms of the winget codes winget.exe ends with for the same outcome.
        $result.ExitCode = switch ($status) {
            'NoApplicableInstallers' { -1978335216 }
            'BlockedByPolicy' { -1978335174 }
            'PackageAgreementsNotAccepted' { -1978335167 }
            'NoApplicableUpgrade' { -1978335189 }
            'CatalogError' { -1978335163 }
            'InvalidOptions' { -1978335230 }
            'ManifestError' { -1978335231 }
            'InternalError' { -1978335231 }
            default { -1978335229 }
        }
    }
    return $result
}

<#
.SYNOPSIS
    Installs one package for the whole PC with Microsoft.WinGet.Client: the engine's form of one
    `winget install --scope machine` attempt.
.DESCRIPTION
    Install-WinGetPackage -Id <id> -Source winget -MatchOption Equals -Scope System -Mode
    Silent|Default [-InstallerType <type>] [-Log <installer log>], in a child pwsh
    (Invoke-WingetClientRequest). -Scope System is --scope machine: installers that declare no
    scope do not count, so a package without a machine-scope installer ends with 0x8A150010, which
    Install-WingetPackage defers. The installer log has the name Invoke-WingetProcess gives it
    (New-WingetInstallerLogPath). Prints the call, the child's output and one result line.
.PARAMETER PackageId
    The package id.
.PARAMETER Scope
    'machine' only: the engine runs as SYSTEM, where any other scope would install into SYSTEM's
    own profile. Anything else throws an ArgumentException.
.PARAMETER InstallerType
    Passed as -InstallerType (e.g. 'wix').
.PARAMETER Silent
    -Mode Silent (MSI and WiX with /quiet); otherwise -Mode Default.
.PARAMETER TimeoutSeconds
    The time limit (WingetInstall).
.PARAMETER LogDirectory
    Where the installer log goes. Default: Get-InstallerLogDirectory. Empty: no -Log.
.OUTPUTS
    [pscustomobject] Invoke-ExternalProcess's members with ExitCode, TimedOut, LaunchFailed,
    LaunchErrorCode and LaunchError as Get-WingetClientResultCode mapped them, LogPath the
    installer log path, Output the child's lines without the result line, plus InstallerErrorCode,
    WingetClientStatus and Engine 'WinGetClient'.
#>
function Invoke-WingetClientInstall {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory
    )

    if ($Scope -ne 'machine') {
        throw [System.ArgumentException]::new("Invoke-WingetClientInstall: the WinGet client engine installs for the whole PC only (-Scope System), so it cannot install $PackageId at scope '$Scope'.")
    }
    $mode = 'Default'
    if ($Silent) {
        $mode = 'Silent'
    }
    $logParameters = @{ Subcommand = 'install'; PackageId = $PackageId }
    if ($PSBoundParameters.ContainsKey('LogDirectory')) {
        $logParameters['LogDirectory'] = $LogDirectory
    }
    $logPath = New-WingetInstallerLogPath @logParameters

    $call = '  > Install-WinGetPackage -Id {0} -Source winget -MatchOption Equals -Scope System -Mode {1}' -f $PackageId, $mode
    if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
        $call += " -InstallerType $InstallerType"
    }
    if ($logPath) {
        $call += " -Log $logPath"
    }
    Write-Host $call -ForegroundColor DarkGray

    $requestParameters = @{ Operation = 'Install'; PackageId = $PackageId; Mode = $mode; TimeoutSeconds = $TimeoutSeconds }
    if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
        $requestParameters['InstallerType'] = $InstallerType
    }
    if ($logPath) {
        $requestParameters['Log'] = $logPath
    }
    $request = Invoke-WingetClientRequest @requestParameters
    $run = $request.Run
    $mapped = Get-WingetClientResultCode -Request $request

    $output = @($run.Output | Where-Object { "$_" -notmatch '^WINGET-CLIENT-RESULT ' })
    if ($output.Count -gt 0) {
        Write-ProcessOutput -Line $output -Tail 20
    }
    $seconds = [Math]::Round([double]$run.DurationSeconds)
    if ($mapped.TimedOut) {
        Write-Host ('    WinGet client result: no answer within {0} s; the request and its installer were stopped' -f $TimeoutSeconds) -ForegroundColor DarkGray
    }
    elseif ($mapped.LaunchFailed) {
        Write-Host ('    WinGet client result: {0} ({1} s)' -f "$($mapped.LaunchError)".TrimEnd('.'), $seconds) -ForegroundColor DarkGray
    }
    else {
        $installerCode = 0
        if ($null -ne $mapped.InstallerErrorCode) {
            $installerCode = $mapped.InstallerErrorCode
        }
        Write-Host ('    WinGet client result: {0}, {1}, installer exit code {2} ({3} s)' -f $mapped.Status, (Format-WingetExitCode -ExitCode $mapped.ExitCode), $installerCode, $seconds) -ForegroundColor DarkGray
    }

    $result = [ordered]@{}
    foreach ($property in $run.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    $result['ExitCode'] = $mapped.ExitCode
    $result['TimedOut'] = [bool]$mapped.TimedOut
    $result['LaunchFailed'] = [bool]$mapped.LaunchFailed
    $result['LaunchErrorCode'] = $mapped.LaunchErrorCode
    $result['LaunchError'] = $mapped.LaunchError
    $result['Output'] = $output
    $result['LogPath'] = $logPath
    $result['InstallerErrorCode'] = $mapped.InstallerErrorCode
    $result['WingetClientStatus'] = $mapped.Status
    $result['Engine'] = 'WinGetClient'
    return [pscustomobject]$result
}

<#
.SYNOPSIS
    Test-WingetPackageInstalled's form for the engine: Get-WinGetPackage -Id <id> -MatchOption
    Equals -Source winget in a child pwsh.
.DESCRIPTION
    The same installed-package catalog `winget list` reads. Installed when a listed package's Id is
    the id (ignoring case); nothing listed is not installed. A thrown call is CheckFailed with the
    mapped code; a timeout, or an engine that cannot start, is no answer either.
.PARAMETER PackageId
    The package id.
.PARAMETER TimeoutSeconds
    The caller's limit; at least WingetClientListCheck (45 seconds), since each check starts pwsh
    and loads the module.
.OUTPUTS
    [hashtable] Test-WingetPackageInstalled's keys: Installed, TimedOut, LaunchFailed, LaunchError,
    CheckFailed and ExitCode (0 when listed, 0x8A150014 when not, the mapped code when the check
    failed, $null without an answer).
#>
function Invoke-WingetClientInstalledCheck {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $timeout = [Math]::Max($TimeoutSeconds, (Get-ProcessTimeoutSeconds -Operation WingetClientListCheck))
    $request = Invoke-WingetClientRequest -Operation Installed -PackageId $PackageId -TimeoutSeconds $timeout
    $mapped = Get-WingetClientResultCode -Request $request
    if ($mapped.LaunchFailed) {
        return @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = $mapped.LaunchError; CheckFailed = $false; ExitCode = $null }
    }
    if ($mapped.TimedOut) {
        return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    }
    if ($mapped.Failure -eq 'Call') {
        return @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $true; ExitCode = $mapped.ExitCode }
    }
    $installed = @($request.Response.packages | Where-Object { $null -ne $_ -and [string]$_.id -eq $PackageId }).Count -gt 0
    # 0x8A150014 NO_APPLICATIONS_FOUND, what `winget list` exits with when nothing matches.
    $exitCode = -1978335212
    if ($installed) {
        $exitCode = 0
    }
    return @{ Installed = $installed; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $exitCode }
}

<#
.SYNOPSIS
    Checks that the engine still starts and answers: Get-WinGetVersion in a child pwsh.
.DESCRIPTION
    The engine's form of Test-WingetLaunchable, for the circuit breaker. A timeout, a pwsh launch
    failure that can clear on its own, a missing result line or another failed call is checked
    again after RetryDelaySeconds; a module that cannot load here, a pwsh that cannot start for good
    and 0x8A15003A (Group Policy) are final at once.
.PARAMETER Attempts
    How many times to check. Default 1.
.PARAMETER RetryDelaySeconds
    Seconds between checks. Default 10.
.OUTPUTS
    [pscustomobject] Test-WingetLaunchable's shape: Launchable, Version, Reason, ExitCode and
    Attempts.
#>
function Test-WingetClientEngineLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$Attempts = 1,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 10
    )

    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetClientVersion
    $policyExitCode = -1978335174
    $reason = $null
    $mapped = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $request = Invoke-WingetClientRequest -Operation Version -TimeoutSeconds $timeoutSeconds
        $mapped = Get-WingetClientResultCode -Request $request
        $retryable = $true
        switch ($mapped.Failure) {
            'Launch' {
                $reason = 'pwsh could not be started: {0}' -f "$($mapped.LaunchError)".Trim().TrimEnd('.')
                $retryable = Test-TransientWingetLaunchError -NativeErrorCode $mapped.LaunchErrorCode -Message $mapped.LaunchError
            }
            'Timeout' {
                $reason = "Get-WinGetVersion did not answer within $timeoutSeconds seconds and was stopped"
            }
            'Protocol' {
                $reason = "$($mapped.LaunchError)".TrimEnd('.')
            }
            'Load' {
                $reason = "$($mapped.LaunchError)".TrimEnd('.')
                $retryable = $false
            }
            'Call' {
                $reason = 'Get-WinGetVersion failed with {0} ({1})' -f (Format-WingetExitCode -ExitCode $mapped.ExitCode), $mapped.Detail
                if ($mapped.ExitCode -eq $policyExitCode) {
                    $retryable = $false
                }
            }
            default {
                $version = "$($request.Response.version)".Trim()
                if ($version) {
                    return [pscustomobject]@{ Launchable = $true; Version = $version; Reason = $null; ExitCode = 0; Attempts = $attempt }
                }
                $reason = 'Get-WinGetVersion returned no version'
            }
        }
        if (-not $retryable -or $attempt -ge $Attempts) {
            break
        }
        Write-WarningMessage "The WinGet client engine is not usable yet ($reason). Checking again in ${RetryDelaySeconds}s (check $($attempt + 1) of $Attempts)..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
    return [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $reason; ExitCode = $mapped.ExitCode; Attempts = [Math]::Min($attempt, $Attempts) }
}

<#
.SYNOPSIS
    Makes the Microsoft.WinGet.Client engine ready for this run as SYSTEM, or says why it is not.
.DESCRIPTION
    Initialize-WingetClientModule, then one probe in a child pwsh (Get-WinGetVersion and a
    Get-WinGetPackage for Microsoft.PowerShell, WingetClientProbe limit): ready only when both
    answered (an empty package list is an answer). Ready sets $script:WingetClientEngine, which
    every install and check of the run then uses; not ready removes the module's folder. Either way
    $script:InstallEngineRecord says what happened, for last-run.json.
.OUTPUTS
    [pscustomobject] with Ready, Reason (why not, or $null), Module (Initialize-WingetClientModule's
    result) and EngineVersion.
#>
function Initialize-WingetClientEngine {
    $script:WingetClientEngine = $null
    $module = Initialize-WingetClientModule
    if (-not $module.Ready) {
        $reason = "the module is not ready: $($module.Reason)"
        $script:InstallEngineRecord = New-InstallEngineRecord -Requested 'WinGetClient' -Used 'Cli' -FallbackReason $reason
        return [pscustomobject]@{ Ready = $false; Reason = $reason; Module = $module; EngineVersion = $null }
    }

    $request = Invoke-WingetClientRequest -Module $module -Operation Probe -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetClientProbe)
    $mapped = Get-WingetClientResultCode -Request $request
    $response = $request.Response
    $version = $null
    $detail = $null
    switch ($mapped.Failure) {
        'Launch' { $detail = "pwsh could not be started: $($mapped.LaunchError)" }
        'Timeout' { $detail = 'it did not answer within {0} seconds and was stopped' -f (Get-ProcessTimeoutSeconds -Operation WingetClientProbe) }
        'Protocol' { $detail = $mapped.LaunchError }
        'Load' { $detail = $mapped.LaunchError }
        'Call' { $detail = '{0} ({1})' -f $mapped.Detail, (Format-WingetExitCode -ExitCode $mapped.ExitCode) }
        default {
            $version = "$($response.version)".Trim()
            if (-not $version) {
                $detail = 'Get-WinGetVersion returned no version'
            }
            elseif ($response.installedChecked -ne $true) {
                $detail = 'Get-WinGetPackage did not run'
            }
        }
    }
    if ($detail) {
        $reason = "the module's probe failed: " + "$detail".Trim().TrimEnd('.')
        Write-WarningMessage "WinGet client module: NOT READY - $reason."
        if ($module.Directory) {
            Remove-Item -LiteralPath $module.Directory -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:InstallEngineRecord = New-InstallEngineRecord -Requested 'WinGetClient' -Used 'Cli' -FallbackReason $reason
        return [pscustomobject]@{ Ready = $false; Reason = $reason; Module = $module; EngineVersion = $null }
    }

    $script:WingetClientEngine = [pscustomobject]@{
        Module            = $module
        EngineVersion     = $version
        PowerShellVersion = [string]$response.psVersion
        Architecture      = [string]$response.architecture
    }
    $script:InstallEngineRecord = New-InstallEngineRecord -Requested 'WinGetClient' -Used 'WinGetClient' -Module $module -EngineVersion $version
    return [pscustomobject]@{ Ready = $true; Reason = $null; Module = $module; EngineVersion = $version }
}

<#
.SYNOPSIS
    Ends the engine's use in this run: removes the module's folder and stops further module calls.
.DESCRIPTION
    Invoke-WingetInstall calls it after its last install, and the entry script's finally block
    again; a second call does nothing. $script:InstallEngineRecord is kept for the run record. A
    folder that cannot be removed now is removed by a later run's housekeeping
    (Remove-StaleWingetClientFolder). Never throws.
#>
function Remove-WingetClientEngine {
    $engine = $script:WingetClientEngine
    $script:WingetClientEngine = $null
    if ($null -eq $engine -or $null -eq $engine.Module) {
        return
    }
    $directory = [string]$engine.Module.Directory
    if ([string]::IsNullOrEmpty($directory)) {
        return
    }
    try {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        Write-WarningMessage "Could not remove the Microsoft.WinGet.Client folder ${directory}: $($_.Exception.Message). A later run removes it."
    }
}
