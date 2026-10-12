<#
.SYNOPSIS
    Runs the installer as SYSTEM the way Endpoint Central does, through the RMM wrapper started by a
    32-bit Windows PowerShell, and checks the run.
.DESCRIPTION
    The e2e-install-system job of .github/workflows/e2e-install.yml (work-order item 34). It
    registers a one-shot scheduled task that runs as SYSTEM:

        %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive
            -ExecutionPolicy Bypass -File <checkout>\rmm\Invoke-WingetAppSetup.ps1
            -InstallerPath <checkout>\winget-app-install.ps1 -InstallerSha256 <its SHA256>

    SysWOW64's powershell.exe is the 32-bit one, as Endpoint Central's 32-bit agent starts scripts,
    so the wrapper has to relaunch itself in 64-bit Windows PowerShell through Sysnative. The wrapper
    gets the checkout's installer, not its pinned commit, so the run tests the code under review; it
    still copies it into its protected folder and checks its SHA256. The script starts the task,
    waits for it (printing the newest transcript line every minute), reads its LastTaskResult and
    removes it, then checks:

      - the exit code, with the policy of every install pass (Get-InstallPassVerdict in
        e2e/Invoke-InstallPass.ps1): 0 and 3010 pass, and 8 passes only when the run's transcript
        says auto-updates were not configured because Microsoft.WindowsAppRuntime.1.8 is missing
        and the installer could not try to install it (work-order item 31: on windows-latest it
        can, so this run is expected to exit 0). 1 passes only while KNOWN_PLATFORM_INCOMPATIBLE
        lists apps, and only when every app the run left failed is on that list
        (Test-InstallFailureContainment on the run's transcript, the check e2e/Assert-Install.ps1
        makes for the other legs);
      - auto-updates: the transcript says 'Auto-updates: Configured' (or 'Already present'), as
        e2e/Assert-Install.ps1 expects WAU at its pin on the other legs, or NOT CONFIGURED for the
        missing framework when the installer could not try to install it (the case exit code 8 is
        accepted for);
      - the Windows App Runtime: the run installed it once ('Windows App Runtime: installed'), or
        needed not to (no 'Windows App Runtime:' line); a 'NOT INSTALLED' line passes only in that
        same case;
      - the deferred apps (work-order items 34 and 38): every Deferred entry of last-run.json has a
        winget package id and a reason, which the user phase installs from, and the summary's
        Deferred row lists the same apps;
      - the wrapper's log (install-<time>-rmm.log): it was started by a 32-bit PowerShell and
        relaunched through Sysnative, it checked the installer, and it passed the installer's exit
        code back unchanged;
      - the run's transcript says it ran as SYSTEM, and last-run.json records the same exit code
        and a run that reached its summary;
      - nothing was installed per-user into SYSTEM's own profile: no new entry under
        HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Uninstall (or its
        WOW6432Node twin), and no new folder under SYSTEM's AppData\Local\Programs (System32's and
        SysWOW64's systemprofile). A run as SYSTEM installs for the whole PC only and defers the
        rest; winget's default scope would have put a per-user app there;
      - every catalog app, from last-run.json (the per-app checks the other legs make with
        winget list): the catalog and its applicability come from the checkout's module
        (Get-DefaultAppCatalog, Test-AppApplicability), decided before the run as the run as SYSTEM
        decides them. An app that applies is Installed or Skipped as already there, and Installed
        only for the apps the job uninstalled first (e2e/Remove-PreinstalledApps.ps1's defaults:
        Chrome, 7-Zip, Git); one that does not apply is Skipped with its not-applicable reason;
        per-user work is Deferred with its reason. Failed, Deferred otherwise, or no entry fails.
        Apps on KNOWN_PLATFORM_INCOMPATIBLE are not checked.

    With -SystemInstallEngine WinGetClient (the e2e-install-system-winget-client job, wgt-gq8.42)
    the wrapper also gets -SystemInstallEngine WinGetClient, and these rows are added
    (Get-SystemPassEngineResult): the wrapper passed the request on; the transcript says 'WinGet
    client module: ready - ' with the pin's version and SHA256; the 'Install engine:' line names
    Microsoft.WinGet.Client at the pin, no 'NOT READY' line and no '> winget install' line appear,
    every app the job removed shows a '> Install-WinGetPackage -Id <id>' line, and last-run.json says
    installEngine.used WinGetClient at the pin. After the first pass, the apps the job removed are
    looked up with `winget list` as the runner account (Get-SystemPassIndependentInstallResult), a
    check that does not trust the engine's own detection.

    -PassCount 2 runs the task a second time, with every row prefixed 'Pass 1: ' or 'Pass 2: '. The
    second pass is checked the same way, except that every app that applies must be Skipped as
    already there ('App already present on the second run: <id>'), the framework must not be
    installed again, and with the engine its module must come 'from the cache'.

    Prints an '=== E2E assertion results ===' table and exits 0 when every check passed; otherwise
    with the run's exit code when that is what failed, or 1.

    The checks are functions (Get-SystemInstallPassResult and the helpers it uses) that read only
    what they are given, so tests/E2ESystemInstallPass.Tests.ps1 runs them on any OS (the per-app
    ones against tests/fixtures/e2e/system-last-run.json); the task handling needs Windows.

    Runs under Windows PowerShell 5.1 and PowerShell 7: ASCII only, no 7-only syntax.
.PARAMETER RmmWrapperPath
    Default: rmm\Invoke-WingetAppSetup.ps1 in the checkout.
.PARAMETER CheckoutInstallerPath
    Default: winget-app-install.ps1 in the checkout.
.PARAMETER InstallerLogDirectory
    Default: %ProgramData%\winget-app-setup\logs.
.PARAMETER TimeoutMinutes
    How long the task may run, per pass. Default 40.
.PARAMETER SystemInstallEngine
    Passed to the wrapper as -SystemInstallEngine; WinGetClient also adds the engine's checks. Not
    given: nothing is passed, as before.
.PARAMETER PassCount
    1 (default) or 2: run the task again, for the checks of a second run.
.NOTES
    Exit codes: 0 = every check passed; the run's exit code or 1 = a check failed; 64 = bad
    arguments; 127 = the task could not be registered or started.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$RmmWrapperPath,

    [Parameter(Mandatory = $false)]
    [string]$CheckoutInstallerPath,

    [Parameter(Mandatory = $false)]
    [string]$InstallerLogDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 120)]
    [int]$TimeoutMinutes = 40,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Cli', 'WinGetClient')]
    [string]$SystemInstallEngine,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 2)]
    [int]$PassCount = 1
)

# Get-InstallPassVerdict and Get-InstallPassTranscript (and, through it, TranscriptAssertions.ps1).
# Dot-sourcing it also sets its parameters as variables here ($InstallerPath, $LogDirectory, ...),
# which is why this script's own parameters have other names.
. (Join-Path $PSScriptRoot 'Invoke-InstallPass.ps1')

$script:SystemTaskName = 'winget-app-setup-e2e-system'

<#
.SYNOPSIS
    Returns the scheduled task's command line arguments for the wrapper.
.PARAMETER SystemInstallEngine
    Appended as -SystemInstallEngine <value> when given.
#>
function Get-SystemPassTaskArgument {
    param (
        [Parameter(Mandatory = $true)]
        [string]$WrapperPath,
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,
        [Parameter(Mandatory = $true)]
        [string]$InstallerSha256,
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$SystemInstallEngine
    )

    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -InstallerPath "{1}" -InstallerSha256 {2}' -f $WrapperPath, $InstallerPath, $InstallerSha256
    if (-not [string]::IsNullOrWhiteSpace($SystemInstallEngine)) {
        $argument += " -SystemInstallEngine $SystemInstallEngine"
    }
    return $argument
}

<#
.SYNOPSIS
    Turns a scheduled task's LastTaskResult (an unsigned 32-bit number) into the exit code as a
    signed 32-bit number, the way the process returned it.
#>
function ConvertTo-TaskExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [long]$LastTaskResult
    )

    if ($LastTaskResult -gt [int]::MaxValue) {
        return [int]($LastTaskResult - 4294967296)
    }
    return [int]$LastTaskResult
}

<#
.SYNOPSIS
    Lists what is installed per-user in SYSTEM's own profile: uninstall entries in its registry
    hive and folders under its AppData\Local\Programs.
.PARAMETER RegistryPath
    The uninstall keys to read. Default: SYSTEM's (HKEY_USERS\S-1-5-18), and their WOW6432Node twin.
.PARAMETER FolderPath
    The folders to list. Default: AppData\Local\Programs of System32's and SysWOW64's systemprofile
    (a 32-bit installer running as SYSTEM writes to the second).
.RETURNS
    [string[]] One entry per key or folder: the key or folder path, with the DisplayName of a key
    in brackets.
#>
function Get-SystemProfileInstallEntry {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$RegistryPath = @(
            'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'Registry::HKEY_USERS\S-1-5-18\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        ),
        [Parameter(Mandatory = $false)]
        [string[]]$FolderPath = @(
            "$env:SystemRoot\System32\config\systemprofile\AppData\Local\Programs",
            "$env:SystemRoot\SysWOW64\config\systemprofile\AppData\Local\Programs"
        )
    )

    $entries = @()
    foreach ($path in $RegistryPath) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $displayName = $null
            try {
                $displayName = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop).DisplayName
            }
            catch {
            }
            $entry = '{0}\{1}' -f ($path -replace '^Registry::', ''), $key.PSChildName
            if ($displayName) {
                $entry = '{0} [{1}]' -f $entry, $displayName
            }
            $entries += $entry
        }
    }
    foreach ($path in $FolderPath) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            continue
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
            $entries += $item.FullName
        }
    }
    return [string[]]$entries
}

<#
.SYNOPSIS
    Returns the entries in After that were not in Before.
#>
function Compare-SystemProfileInstallEntry {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Before = @(),
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$After = @()
    )

    return [string[]]@($After | Where-Object { $Before -notcontains $_ })
}

<#
.SYNOPSIS
    Returns the package ids e2e/Remove-PreinstalledApps.ps1 uninstalls when it is run without
    -PackageId, as the e2e-install-system job runs it.
.DESCRIPTION
    Read from the default of that script's -PackageId parameter without running it, so the list
    is kept in one place.
.PARAMETER ScriptPath
    Default: Remove-PreinstalledApps.ps1 next to this script.
.RETURNS
    [string[]] The package ids. Throws when the script does not parse or has no such default.
#>
function Get-PreinstalledAppRemovalList {
    param (
        [Parameter(Mandatory = $false)]
        [string]$ScriptPath = (Join-Path $PSScriptRoot 'Remove-PreinstalledApps.ps1')
    )

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "$ScriptPath does not parse: $($parseErrors[0].Message)"
    }
    $parameter = $null
    if ($ast.ParamBlock) {
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PackageId' }) | Select-Object -First 1
    }
    if (-not $parameter -or -not $parameter.DefaultValue) {
        throw "$ScriptPath has no default value for -PackageId"
    }
    return [string[]]@($parameter.DefaultValue.SafeGetValue())
}

<#
.SYNOPSIS
    Decides which catalog apps apply to this PC as the run as SYSTEM decides it.
.DESCRIPTION
    The module's Test-AppApplicability (arch list and condition, failing open), with
    Test-IsSystemAccount answering $true: this script runs as the runner's account, the run it
    checks as SYSTEM, and a condition may ask which (Windows Terminal's does). What else a
    condition reads, such as the manufacturer or the OS architecture, is the same PC's.
.PARAMETER Catalog
    The catalog (Get-DefaultAppCatalog).
.PARAMETER Module
    The imported WingetAppSetup module. Its catalog's conditions are bound to its session state,
    so they are evaluated there. Without it, in this script's session state (the unit tests).
.RETURNS
    [hashtable] package id -> [bool], true when the app applies.
#>
function Get-SystemRunApplicability {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Catalog,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Management.Automation.PSModuleInfo]$Module
    )

    $evaluate = {
        param ($Catalog)
        # Commands resolve through the calling scopes first, so the conditions find this one.
        function Test-IsSystemAccount {
            return $true
        }
        $verdicts = @{}
        foreach ($app in $Catalog) {
            $verdicts[$app.name] = [bool](Test-AppApplicability -App $app)
        }
        return $verdicts
    }
    if ($Module) {
        return (& $Module $evaluate $Catalog)
    }
    return (& $evaluate $Catalog)
}

<#
.SYNOPSIS
    Says what last-run.json must record for each catalog app after the run as SYSTEM.
.DESCRIPTION
    In the order Install-AppWithVerification decides it with -MachineWide:
      - an app that does not apply: Skipped, 'not applicable: <Get-AppNotApplicableReason>';
      - per-user work (scope 'user' or userPhase): Deferred, with Get-AppDeferReasonText's reason;
      - any other app: Installed, or Skipped as already there: 'already installed', or for an app
        with msixName, which a run as SYSTEM checks by its provisioning, 'already provisioned for
        every user on this PC'. Only Installed for an app the job uninstalled before the run. With
        -AlreadyPresent (a second run): only Skipped as already there ('AlreadyPresent').
    Calls the module's catalog helpers, so the module must be loaded.
.PARAMETER Catalog
    The catalog (Get-DefaultAppCatalog).
.PARAMETER Applicability
    Get-SystemRunApplicability's verdicts. An app without one counts as applicable (fail open).
.PARAMETER RemovedApps
    The package ids the job uninstalled before the run (Get-PreinstalledAppRemovalList).
.PARAMETER AlreadyPresent
    The run is a second one: every app the first one installed must be there already.
.RETURNS
    [pscustomobject[]] One per catalog app, in catalog order, with Id, Expected ('Installed',
    'AlreadyPresent', 'NotApplicable' or 'Deferred'), Reason (the record's reason for
    NotApplicable and Deferred, otherwise $null), AlreadyPresentReasons (the skip reasons Installed
    and AlreadyPresent accept) and MustInstall.
#>
function Get-SystemPassAppExpectation {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Catalog,
        [Parameter(Mandatory = $false)]
        [hashtable]$Applicability = @{},
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$RemovedApps = @(),
        [Parameter(Mandatory = $false)]
        [switch]$AlreadyPresent
    )

    $expectations = @()
    foreach ($app in $Catalog) {
        $id = [string]$app.name
        $applies = $true
        if ($Applicability.ContainsKey($id)) {
            $applies = [bool]$Applicability[$id]
        }
        $expected = 'Installed'
        $reason = $null
        $presentReasons = @('already installed')
        if (-not [string]::IsNullOrWhiteSpace([string]$app['msixName'])) {
            $presentReasons = @('already provisioned for every user on this PC')
        }
        if (-not $applies) {
            $expected = 'NotApplicable'
            $reason = 'not applicable: ' + (Get-AppNotApplicableReason -App $app)
            $presentReasons = @()
        }
        else {
            $perUserReason = Get-AppPerUserDeferReason -App $app
            if ($perUserReason) {
                $expected = 'Deferred'
                $reason = Get-AppDeferReasonText -DeferReason $perUserReason
                $presentReasons = @()
            }
        }
        $mustInstall = ($expected -eq 'Installed' -and $RemovedApps -contains $id)
        if ($AlreadyPresent -and $expected -eq 'Installed') {
            $expected = 'AlreadyPresent'
            $mustInstall = $false
        }
        $expectations += [pscustomobject]@{
            Id                    = $id
            Expected              = $expected
            Reason                = $reason
            AlreadyPresentReasons = [string[]]$presentReasons
            MustInstall           = $mustInstall
        }
    }
    return $expectations
}

<#
.SYNOPSIS
    Reads last-run.json.
.PARAMETER Path
    The file.
.RETURNS
    [pscustomobject] with Record (the parsed file, or $null) and Problem (why there is no record,
    or $null).
#>
function Read-SystemPassRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Record = $null; Problem = "no last-run.json at $Path" }
    }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ Record = $null; Problem = "$Path is empty" }
        }
        $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Record = $null; Problem = "could not read ${Path}: $($_.Exception.Message)" }
    }
    if ($null -eq $record) {
        return [pscustomobject]@{ Record = $null; Problem = "$Path holds no record" }
    }
    return [pscustomobject]@{ Record = $record; Problem = $null }
}

# A run-record entry as the per-app details show it: 'Skipped (already installed)'.
function Format-SystemPassAppEntry {
    param (
        [Parameter(Mandatory = $true)]
        $Entry
    )

    $text = [string]$Entry.status
    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.reason)) {
        $text += " ($($Entry.reason))"
    }
    return $text
}

<#
.SYNOPSIS
    Checks each catalog app's entry in last-run.json against what the run as SYSTEM had to do.
.DESCRIPTION
    One row for the record itself ('last-run.json lists the catalog''s apps': a schema 1 record
    with an apps list and no app the catalog lacks). When the record can be read, one row per
    catalog app that is not skip-listed (Get-SystemPassAppExpectation):
      - 'App installed: <id>': Installed, or Skipped as already there unless the job removed the
        app first; Failed, Deferred, another skip reason, or no entry or several fail;
      - 'App already present on the second run: <id>': Skipped as already there, nothing else;
      - 'Not-applicable skip recorded: <id>': Skipped with the catalog's not-applicable reason;
      - 'Deferred to the user phase: <id>': Deferred with the per-user reason.
.PARAMETER RunRecord
    last-run.json, parsed, or $null.
.PARAMETER RunRecordProblem
    Why there is no RunRecord (Read-SystemPassRunRecord), or $null.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result.
.PARAMETER AppExpectationProblem
    Why there is no AppExpectation (the catalog could not be read), or $null.
.PARAMETER SkipApps
    The KNOWN_PLATFORM_INCOMPATIBLE package ids, which are not checked.
.RETURNS
    Assertion rows ([pscustomobject] with Assertion, Result and Detail).
#>
function Get-SystemPassAppResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunRecordProblem,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AppExpectationProblem,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$SkipApps = @()
    )

    $recordAssertion = 'last-run.json lists the catalog''s apps'
    $problem = $null
    if ($AppExpectationProblem) {
        $problem = $AppExpectationProblem
    }
    elseif ($null -eq $AppExpectation) {
        $problem = 'no catalog expectations to check last-run.json against'
    }
    elseif ($null -eq $RunRecord) {
        $problem = 'no last-run.json'
        if ($RunRecordProblem) {
            $problem = $RunRecordProblem
        }
    }
    elseif ("$($RunRecord.schemaVersion)" -ne '1') {
        $problem = "schemaVersion '$($RunRecord.schemaVersion)', not 1, the record New-InstallerRunRecord writes and this check reads"
    }
    elseif ($null -eq $RunRecord.PSObject.Properties['apps']) {
        $problem = 'the record has no apps list'
    }
    if ($problem) {
        return @([pscustomobject]@{ Assertion = $recordAssertion; Result = 'FAIL'; Detail = $problem })
    }

    $entries = @($RunRecord.apps | Where-Object { $null -ne $_ })
    $catalogIds = @($AppExpectation | ForEach-Object { $_.Id })
    $extraIds = @($entries | ForEach-Object { [string]$_.id } | Where-Object { $catalogIds -notcontains $_ } | Select-Object -Unique)
    $skipped = @($catalogIds | Where-Object { $SkipApps -contains $_ })
    $recordDetail = 'schemaVersion 1, {0} entries for the catalog''s {1} apps' -f $entries.Count, $catalogIds.Count
    if ($extraIds.Count -gt 0) {
        $recordDetail = 'entries for apps the catalog does not have: ' + ($extraIds -join ', ')
    }
    if ($skipped.Count -gt 0) {
        $recordDetail += '; not checked (KNOWN_PLATFORM_INCOMPATIBLE): ' + ($skipped -join ', ')
    }
    $rows = @([pscustomobject]@{ Assertion = $recordAssertion; Result = $(if ($extraIds.Count -eq 0) { 'PASS' } else { 'FAIL' }); Detail = $recordDetail })

    foreach ($expectation in $AppExpectation) {
        if ($SkipApps -contains $expectation.Id) {
            continue
        }
        $assertion = "App installed: $($expectation.Id)"
        if ($expectation.Expected -eq 'AlreadyPresent') {
            $assertion = "App already present on the second run: $($expectation.Id)"
        }
        elseif ($expectation.Expected -eq 'NotApplicable') {
            $assertion = "Not-applicable skip recorded: $($expectation.Id)"
        }
        elseif ($expectation.Expected -eq 'Deferred') {
            $assertion = "Deferred to the user phase: $($expectation.Id)"
        }

        $matching = @($entries | Where-Object { [string]$_.id -eq $expectation.Id })
        $passed = $false
        if ($matching.Count -eq 0) {
            $detail = 'no entry in last-run.json'
        }
        elseif ($matching.Count -gt 1) {
            $detail = "$($matching.Count) entries in last-run.json: " + (@($matching | ForEach-Object { Format-SystemPassAppEntry -Entry $_ }) -join '; ')
        }
        else {
            $entry = $matching[0]
            $status = [string]$entry.status
            $reason = [string]$entry.reason
            $detail = 'last-run.json: ' + (Format-SystemPassAppEntry -Entry $entry)
            if ($expectation.Expected -eq 'AlreadyPresent') {
                if ($status -eq 'Skipped' -and @($expectation.AlreadyPresentReasons) -contains $reason) {
                    $passed = $true
                }
                else {
                    $detail += '; the first run installed or found it, so the second run had to find it: expected Skipped (' + (@($expectation.AlreadyPresentReasons) -join ' or ') + ')'
                }
            }
            elseif ($expectation.Expected -eq 'Installed') {
                if ($status -eq 'Installed') {
                    $passed = $true
                    if ($null -ne $entry.code -and [long]$entry.code -ne 0) {
                        $detail += ", code $($entry.codeHex)"
                    }
                    if ($entry.restartRequired -eq $true) {
                        $detail += ', restart required'
                    }
                    if ($entry.postInstall) {
                        $detail += ", post-install $($entry.postInstall)"
                    }
                }
                elseif ($status -eq 'Skipped' -and @($expectation.AlreadyPresentReasons) -contains $reason) {
                    if ($expectation.MustInstall) {
                        $detail += '; the job uninstalled it before the run (e2e/Remove-PreinstalledApps.ps1), so the run had to install it: see that step''s warnings'
                    }
                    else {
                        $passed = $true
                    }
                }
                elseif ($status -eq 'Deferred') {
                    $detail += '; its catalog entry is not per-user, so the run as SYSTEM had to install it for the whole PC'
                }
                elseif ($status -eq 'Skipped') {
                    $accepted = 'Installed'
                    if (-not $expectation.MustInstall) {
                        $accepted = 'Installed, or Skipped (' + (@($expectation.AlreadyPresentReasons) -join ' or ') + ')'
                    }
                    $detail += "; it applies to this PC as SYSTEM, so expected $accepted"
                }
            }
            else {
                $expectedStatus = 'Skipped'
                if ($expectation.Expected -eq 'Deferred') {
                    $expectedStatus = 'Deferred'
                }
                if ($status -eq $expectedStatus -and $reason -eq $expectation.Reason) {
                    $passed = $true
                }
                else {
                    $detail += "; expected $expectedStatus ($($expectation.Reason))"
                }
            }
        }
        $rows += [pscustomobject]@{ Assertion = $assertion; Result = $(if ($passed) { 'PASS' } else { 'FAIL' }); Detail = $detail }
    }
    return $rows
}

<#
.SYNOPSIS
    Checks a SYSTEM run from what it left behind.
.PARAMETER TaskExitCode
    The task's exit code (ConvertTo-TaskExitCode), or $null when the task never finished.
.PARAMETER Transcript
    The run's transcript (Get-InstallPassTranscript), or $null.
.PARAMETER WrapperLog
    The text of the wrapper's log (install-<time>-rmm.log), or $null when there is none.
.PARAMETER RunRecord
    last-run.json, parsed, or $null.
.PARAMETER RunRecordProblem
    Why there is no RunRecord (Read-SystemPassRunRecord), or $null.
.PARAMETER NewSystemProfileEntries
    What appeared in SYSTEM's profile during the run (Compare-SystemProfileInstallEntry).
.PARAMETER KnownPlatformIncompatible
    The KNOWN_PLATFORM_INCOMPATIBLE value (package ids, comma-separated); empty means strict.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result: adds the per-app rows (Get-SystemPassAppResult). Not
    given and no AppExpectationProblem: no per-app rows (the tests of the other checks).
.PARAMETER AppExpectationProblem
    Why there is no AppExpectation (the catalog could not be read): one failed per-app row.
.PARAMETER SecondPass
    The run is a second one: the framework must not be installed again ('Windows App Runtime not
    installed again' instead of 'installed once, or already there').
.RETURNS
    [pscustomobject] with Results (Assertion, Result 'PASS' or 'FAIL', Detail) and StepExitCode.
#>
function Get-SystemInstallPassResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$TaskExitCode,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WrapperLog,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunRecordProblem,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$NewSystemProfileEntries = @(),
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$KnownPlatformIncompatible = '',
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AppExpectationProblem,
        [Parameter(Mandatory = $false)]
        [switch]$SecondPass
    )

    $results = @()
    $stepExitCode = 0
    if ($null -eq $KnownPlatformIncompatible) {
        $KnownPlatformIncompatible = ''
    }
    $skipApps = @($KnownPlatformIncompatible -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $noRecordDetail = 'no last-run.json'
    if ($RunRecordProblem) {
        $noRecordDetail = $RunRecordProblem
    }

    if ($null -eq $TaskExitCode) {
        $results += [pscustomobject]@{ Assertion = 'SYSTEM run exit code'; Result = 'FAIL'; Detail = 'the scheduled task did not finish' }
        $stepExitCode = 1
    }
    else {
        $verdict = Get-InstallPassVerdict -ExitCode $TaskExitCode -KnownPlatformIncompatible $KnownPlatformIncompatible -Pass 'system' -Transcript $Transcript
        $result = 'PASS'
        if ($verdict.Outcome -eq 'failed') {
            $result = 'FAIL'
            $stepExitCode = $verdict.StepExitCode
        }
        $results += [pscustomobject]@{ Assertion = 'SYSTEM run exit code'; Result = $result; Detail = $verdict.Message }
        # Exit 1 is tolerated only on the promise that every failure is a known platform
        # incompatibility; the other legs check it in e2e/Assert-Install.ps1.
        if ($verdict.Outcome -eq 'tolerated') {
            $contained = $false
            $containedDetail = 'no transcript of the run, so its failures cannot be checked'
            if ($Transcript) {
                $containment = Test-InstallFailureContainment -Transcript $Transcript.Parsed -SkipApps $skipApps
                $contained = [bool]$containment.Passed
                $containedDetail = "$($Transcript.Name): $($containment.Detail)"
            }
            $results += [pscustomobject]@{ Assertion = 'Failures are all known platform-incompatible apps'; Result = $(if ($contained) { 'PASS' } else { 'FAIL' }); Detail = $containedDetail }
        }
    }

    $wrapperText = ''
    if ($WrapperLog) {
        $wrapperText = $WrapperLog
    }
    $relaunched = $wrapperText.Contains('Started by a 32-bit PowerShell on 64-bit Windows, and relaunched in 64-bit Windows PowerShell through Sysnative.')
    $relaunchDetail = 'the wrapper log does not say it was relaunched from a 32-bit PowerShell'
    if (-not $WrapperLog) {
        $relaunchDetail = 'no wrapper log (install-<time>-rmm.log) from this run'
    }
    elseif ($relaunched) {
        $relaunchDetail = 'started by SysWOW64 powershell.exe, relaunched through Sysnative'
    }
    $results += [pscustomobject]@{ Assertion = 'Wrapper relaunched in 64-bit Windows PowerShell'; Result = $(if ($relaunched) { 'PASS' } else { 'FAIL' }); Detail = $relaunchDetail }

    $checked = $wrapperText -match 'Installer checked \(SHA256 [0-9A-F]{64}\)\.'
    $results += [pscustomobject]@{ Assertion = 'Wrapper checked the installer''s SHA256'; Result = $(if ($checked) { 'PASS' } else { 'FAIL' }); Detail = $(if ($checked) { $Matches[0] } else { 'no ''Installer checked'' line in the wrapper log' }) }

    $passedBack = $false
    $passedBackDetail = 'no ''The installer exited with'' line in the wrapper log'
    if ($wrapperText -match 'The installer exited with (-?\d+)\.') {
        $installerExitCode = [int]$Matches[1]
        $passedBack = ($null -ne $TaskExitCode -and $installerExitCode -eq $TaskExitCode)
        $passedBackDetail = 'the installer exited with {0}, the task with {1}' -f $installerExitCode, $TaskExitCode
    }
    $results += [pscustomobject]@{ Assertion = 'Wrapper passed the exit code back unchanged'; Result = $(if ($passedBack) { 'PASS' } else { 'FAIL' }); Detail = $passedBackDetail }

    $ranAsSystem = $false
    $ranAsSystemDetail = 'no transcript of the run'
    if ($Transcript) {
        $ranAsSystemDetail = "$($Transcript.Name) has no 'Running as SYSTEM' line"
        if ($Transcript.Parsed.RanAsSystem) {
            $ranAsSystem = $true
            $ranAsSystemDetail = "$($Transcript.Name): Running as SYSTEM"
        }
    }
    $results += [pscustomobject]@{ Assertion = 'Installer ran as SYSTEM'; Result = $(if ($ranAsSystem) { 'PASS' } else { 'FAIL' }); Detail = $ranAsSystemDetail }

    $recordOk = $false
    $recordDetail = $noRecordDetail
    if ($null -ne $RunRecord) {
        $recordDetail = 'exitCode {0}, summaryReached {1}, deferred: {2}' -f $RunRecord.exitCode, $RunRecord.summaryReached, ((@($RunRecord.apps | Where-Object { $_.status -eq 'Deferred' } | ForEach-Object { $_.id }) -join ', '))
        $recordOk = ($null -ne $TaskExitCode -and $null -ne $RunRecord.exitCode -and [int]$RunRecord.exitCode -eq $TaskExitCode -and $RunRecord.summaryReached -eq $true)
    }
    $results += [pscustomobject]@{ Assertion = 'last-run.json records the run'; Result = $(if ($recordOk) { 'PASS' } else { 'FAIL' }); Detail = $recordDetail }

    # Work-order item 31: the SYSTEM run installs the missing framework and then Winget-AutoUpdate,
    # as the other legs' first pass does.
    $autoUpdatesOk = $false
    $autoUpdatesDetail = 'no transcript of the run'
    $runtimeOk = $false
    $runtimeDetail = 'no transcript of the run'
    if ($Transcript) {
        $parsed = $Transcript.Parsed
        $autoUpdatesDetail = "$($Transcript.Name) has no 'Auto-updates:' line"
        if ($parsed.AutoUpdatesLine) {
            $autoUpdatesDetail = "$($Transcript.Name): Auto-updates: $($parsed.AutoUpdatesLine)"
        }
        # The one reason the pass policy accepts for auto-updates not being set up (exit code 8, or
        # masked by a tolerated 1): the framework is missing and the installer could not try to
        # install it. A framework install that started and failed, or a stale pin, is not it.
        $frameworkMissingAccepted = [bool]$parsed.AutoUpdatesFrameworkMissing -and -not $parsed.WindowsAppRuntimePinStale -and -not ($parsed.WindowsAppRuntimeAttempted -and -not $parsed.WindowsAppRuntimeInstalled)
        if (@('Configured', 'Already present') -contains $parsed.AutoUpdatesStatus) {
            $autoUpdatesOk = $true
        }
        elseif ($frameworkMissingAccepted) {
            $autoUpdatesOk = $true
            $autoUpdatesDetail += ' (accepted: the framework is missing and the installer could not try to install it)'
        }

        $installCount = [int]$parsed.WindowsAppRuntimeInstallCount
        if ($SecondPass) {
            $runtimeOk = ($installCount -eq 0)
            $runtimeDetail = "$($Transcript.Name) has no 'Windows App Runtime: installed' line"
            if ($installCount -gt 0) {
                $runtimeDetail = "$($Transcript.Name) installed it again: Windows App Runtime: $($parsed.WindowsAppRuntimeLine)"
            }
        }
        elseif ($installCount -gt 1) {
            $runtimeDetail = "$($Transcript.Name) installed it $installCount times in one run"
        }
        elseif ($installCount -eq 1) {
            $runtimeOk = $true
            $runtimeDetail = "$($Transcript.Name): Windows App Runtime: $($parsed.WindowsAppRuntimeLine)"
        }
        elseif (-not $parsed.WindowsAppRuntimeLine) {
            $runtimeOk = $true
            $runtimeDetail = "$($Transcript.Name) has no 'Windows App Runtime:' line: the run did not need to install it"
        }
        else {
            $runtimeOk = $frameworkMissingAccepted
            $runtimeDetail = "$($Transcript.Name): Windows App Runtime: $($parsed.WindowsAppRuntimeLine)"
            if ($frameworkMissingAccepted) {
                $runtimeDetail += ' (accepted: the installer could not try to install it)'
            }
        }
    }
    $results += [pscustomobject]@{ Assertion = 'Auto-updates configured by the SYSTEM run'; Result = $(if ($autoUpdatesOk) { 'PASS' } else { 'FAIL' }); Detail = $autoUpdatesDetail }
    $runtimeAssertion = 'Windows App Runtime installed once, or already there'
    if ($SecondPass) {
        $runtimeAssertion = 'Windows App Runtime not installed again'
    }
    $results += [pscustomobject]@{ Assertion = $runtimeAssertion; Result = $(if ($runtimeOk) { 'PASS' } else { 'FAIL' }); Detail = $runtimeDetail }

    # Work-order items 34 and 38: the user phase installs what last-run.json defers, by id, so each
    # Deferred entry must carry a package id and why it was deferred, and the summary must agree.
    $deferredOk = $false
    $deferredDetail = $noRecordDetail
    if ($null -ne $RunRecord) {
        $deferredEntries = @($RunRecord.apps | Where-Object { $null -ne $_ -and [string]$_.status -eq 'Deferred' })
        $deferredIds = @($deferredEntries | ForEach-Object { [string]$_.id })
        $problems = @()
        foreach ($entry in $deferredEntries) {
            if ([string]$entry.id -notmatch '^[\w][\w.\-]+\.[\w][\w.\-]+\z') {
                $problems += "'$($entry.id)' is not a winget package id"
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.reason)) {
                $problems += "$($entry.id) has no reason"
            }
        }
        if ($Transcript -and $Transcript.Parsed.HasSummary -and -not $Transcript.Parsed.SummaryTruncated) {
            $summaryDeferred = @($Transcript.Parsed.SummaryDeferred | Where-Object { $_ })
            $onlyInRecord = @($deferredIds | Where-Object { $summaryDeferred -notcontains $_ })
            $onlyInSummary = @($summaryDeferred | Where-Object { $deferredIds -notcontains $_ })
            if ($onlyInRecord.Count -gt 0 -or $onlyInSummary.Count -gt 0) {
                $problems += ('the summary''s Deferred row ({0}) differs from last-run.json ({1})' -f ($summaryDeferred -join ', '), ($deferredIds -join ', '))
            }
        }
        $deferredOk = ($problems.Count -eq 0)
        if ($problems.Count -gt 0) {
            $deferredDetail = $problems -join '; '
        }
        elseif ($deferredIds.Count -eq 0) {
            $deferredDetail = 'nothing deferred'
        }
        else {
            $deferredDetail = 'deferred, each with its reason: ' + (@($deferredEntries | ForEach-Object { '{0} ({1})' -f $_.id, $_.reason }) -join '; ')
        }
    }
    $results += [pscustomobject]@{ Assertion = 'Deferred apps recorded for the user phase'; Result = $(if ($deferredOk) { 'PASS' } else { 'FAIL' }); Detail = $deferredDetail }

    $newEntries = @($NewSystemProfileEntries | Where-Object { $_ })
    $profileDetail = 'nothing new under SYSTEM''s uninstall keys or AppData\Local\Programs'
    if ($newEntries.Count -gt 0) {
        $profileDetail = 'installed per-user for SYSTEM: ' + ($newEntries -join '; ')
    }
    $results += [pscustomobject]@{ Assertion = 'Nothing installed per-user into SYSTEM''s profile'; Result = $(if ($newEntries.Count -eq 0) { 'PASS' } else { 'FAIL' }); Detail = $profileDetail }

    # wgt-gq8.45: each catalog app's outcome, which the other legs check with winget list.
    if ($PSBoundParameters.ContainsKey('AppExpectation') -or $AppExpectationProblem) {
        $results += @(Get-SystemPassAppResult -RunRecord $RunRecord -RunRecordProblem $noRecordDetail -AppExpectation $AppExpectation -AppExpectationProblem $AppExpectationProblem -SkipApps $skipApps)
    }

    if ($stepExitCode -eq 0 -and @($results | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) {
        $stepExitCode = 1
    }
    return [pscustomobject]@{ Results = $results; StepExitCode = $stepExitCode }
}

<#
.SYNOPSIS
    Checks that a run that asked for Microsoft.WinGet.Client installed with it (wgt-gq8.42).
.DESCRIPTION
    Three rows:
      - 'Wrapper passed the engine request': the wrapper log says 'Install engine requested:
        WinGetClient';
      - 'WinGet client module verified as SYSTEM': the transcript's last 'WinGet client module:'
        line is 'ready - ' with the pin's version and SHA256, and on a second pass 'from the cache';
      - 'Installs ran through Microsoft.WinGet.Client': the 'Install engine:' line names
        Microsoft.WinGet.Client at the pin, no 'NOT READY' line, no '> winget install' line, a
        '> Install-WinGetPackage -Id <id>' line for every app the job removed (MustInstall), and
        last-run.json's installEngine says used WinGetClient with the module at the pin.
    A silent fall back to winget.exe fails the last two.
.PARAMETER WrapperLog
    The wrapper log's text, or $null.
.PARAMETER Transcript
    The run's transcript (Get-InstallPassTranscript), or $null.
.PARAMETER RunRecord
    last-run.json, parsed, or $null.
.PARAMETER Pin
    The checkout's Get-WingetClientModulePin.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result, for the apps the job removed.
.PARAMETER PassNumber
    1 or 2.
.RETURNS
    Assertion rows ([pscustomobject] with Assertion, Result and Detail).
#>
function Get-SystemPassEngineResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WrapperLog,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,
        [Parameter(Mandatory = $true)]
        [hashtable]$Pin,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 2)]
        [int]$PassNumber = 1
    )

    $rows = @()
    $pinSha256 = ([string]$Pin.Sha256).ToUpperInvariant()

    $requested = ([string]$WrapperLog).Contains('Install engine requested: WinGetClient')
    $requestDetail = 'the wrapper log has no ''Install engine requested: WinGetClient'' line'
    if (-not $WrapperLog) {
        $requestDetail = 'no wrapper log (install-<time>-rmm.log) from this run'
    }
    elseif ($requested) {
        $requestDetail = 'Install engine requested: WinGetClient'
    }
    $rows += [pscustomobject]@{ Assertion = 'Wrapper passed the engine request'; Result = $(if ($requested) { 'PASS' } else { 'FAIL' }); Detail = $requestDetail }

    $moduleOk = $false
    $moduleDetail = 'no transcript of the run'
    $engineProblems = @()
    if ($Transcript) {
        $parsed = $Transcript.Parsed
        if (-not $parsed.WingetClientModuleLine) {
            $moduleDetail = "$($Transcript.Name) has no 'WinGet client module:' line"
        }
        else {
            $moduleDetail = "$($Transcript.Name): WinGet client module: $($parsed.WingetClientModuleLine)"
            $moduleOk = [bool]$parsed.WingetClientModuleReady -and $parsed.WingetClientModuleVersion -eq $Pin.Version -and $parsed.WingetClientModuleSha256 -eq $pinSha256
            if ($moduleOk -and $PassNumber -ge 2 -and -not $parsed.WingetClientModuleFromCache) {
                $moduleOk = $false
                $moduleDetail += ' (the second run must take it from the cache)'
            }
            elseif (-not $moduleOk -and $parsed.WingetClientModuleReady) {
                $moduleDetail += " (expected Microsoft.WinGet.Client $($Pin.Version), SHA256 $pinSha256)"
            }
        }

        if ($parsed.InstallEngine -ne 'WinGetClient') {
            if ($parsed.InstallEngineLine) {
                $engineProblems += "the run's 'Install engine:' line is '$($parsed.InstallEngineLine)'"
            }
            else {
                $engineProblems += "the run has no 'Install engine:' line"
            }
        }
        elseif ($parsed.InstallEngineVersion -ne $Pin.Version) {
            $engineProblems += "the run used Microsoft.WinGet.Client $($parsed.InstallEngineVersion), not the pinned $($Pin.Version)"
        }
        if ($parsed.WingetClientModuleNotReadyReason) {
            $engineProblems += "WinGet client module: NOT READY - $($parsed.WingetClientModuleNotReadyReason)"
        }
        if ([int]$parsed.WingetExeInstallCount -gt 0) {
            $engineProblems += "$($parsed.WingetExeInstallCount) '> winget install' line(s): winget.exe installed apps"
        }
        $mustInstall = @($AppExpectation | Where-Object { $null -ne $_ -and $_.MustInstall } | ForEach-Object { [string]$_.Id })
        $missing = @($mustInstall | Where-Object { @($parsed.WingetClientInstallIds) -notcontains $_ })
        if ($missing.Count -gt 0) {
            $engineProblems += 'no ''> Install-WinGetPackage -Id <id>'' line for ' + ($missing -join ', ')
        }
    }
    else {
        $engineProblems += 'no transcript of the run'
    }
    $rows += [pscustomobject]@{ Assertion = 'WinGet client module verified as SYSTEM'; Result = $(if ($moduleOk) { 'PASS' } else { 'FAIL' }); Detail = $moduleDetail }

    if ($null -eq $RunRecord) {
        $engineProblems += 'no last-run.json'
    }
    else {
        $recordEngine = $null
        if ($RunRecord.PSObject.Properties['installEngine']) {
            $recordEngine = $RunRecord.installEngine
        }
        if ($null -eq $recordEngine) {
            $engineProblems += 'last-run.json has no installEngine'
        }
        elseif ([string]$recordEngine.used -ne 'WinGetClient') {
            $why = ''
            if ($recordEngine.fallbackReason) {
                $why = " ($($recordEngine.fallbackReason))"
            }
            $engineProblems += "last-run.json says installEngine.used '$($recordEngine.used)'$why"
        }
        elseif ($null -eq $recordEngine.module -or [string]$recordEngine.module.version -ne $Pin.Version) {
            $engineProblems += "last-run.json's installEngine.module is not Microsoft.WinGet.Client $($Pin.Version)"
        }
    }
    $engineDetail = $engineProblems -join '; '
    if ($engineProblems.Count -eq 0) {
        $installedIds = @($Transcript.Parsed.WingetClientInstallIds)
        $engineDetail = 'Install engine: {0}; Install-WinGetPackage for: {1}; last-run.json installEngine.used WinGetClient' -f $Transcript.Parsed.InstallEngineLine, $(if ($installedIds.Count -gt 0) { $installedIds -join ', ' } else { 'none (nothing to install)' })
    }
    $rows += [pscustomobject]@{ Assertion = 'Installs ran through Microsoft.WinGet.Client'; Result = $(if ($engineProblems.Count -eq 0) { 'PASS' } else { 'FAIL' }); Detail = $engineDetail }
    return $rows
}

<#
.SYNOPSIS
    Looks up, without the run's own engine, the apps the job removed: `winget list` as the runner
    account, after the run as SYSTEM installed them.
.DESCRIPTION
    One row per MustInstall app, 'Installed per winget list as the runner account: <id>', from
    -TestInstalled (the checkout module's Test-WingetPackageInstalled in the main script), tried
    -Attempts times -RetryDelaySeconds apart. A machine-wide install is listed for every account.
.PARAMETER AppExpectation
    Get-SystemPassAppExpectation's result.
.PARAMETER TestInstalled
    A script block that takes a package id and returns Test-WingetPackageInstalled's result.
.PARAMETER Attempts
    Default 3.
.PARAMETER RetryDelaySeconds
    Default 20.
.PARAMETER SkipApps
    The KNOWN_PLATFORM_INCOMPATIBLE package ids, which are not checked.
.RETURNS
    Assertion rows ([pscustomobject] with Assertion, Result and Detail).
#>
function Get-SystemPassIndependentInstallResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppExpectation,
        [Parameter(Mandatory = $true)]
        [scriptblock]$TestInstalled,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10)]
        [int]$Attempts = 3,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 600)]
        [int]$RetryDelaySeconds = 20,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$SkipApps = @()
    )

    $rows = @()
    foreach ($expectation in @($AppExpectation | Where-Object { $null -ne $_ -and $_.MustInstall })) {
        $id = [string]$expectation.Id
        if ($SkipApps -contains $id) {
            continue
        }
        $passed = $false
        $detail = 'not checked'
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $answer = & $TestInstalled $id
                if ($answer.Installed) {
                    $passed = $true
                    $detail = "winget list --exact --id $id lists it"
                    break
                }
                if ($answer.TimedOut) {
                    $detail = 'winget list did not answer in time'
                }
                elseif ($answer.LaunchFailed) {
                    $detail = "winget could not be started: $($answer.LaunchError)"
                }
                elseif ($answer.CheckFailed) {
                    $detail = 'winget list failed with 0x{0:X8}' -f [int]$answer.ExitCode
                }
                else {
                    $detail = 'winget list does not list it'
                }
            }
            catch {
                $detail = "the check failed: $($_.Exception.Message)"
            }
            if ($attempt -lt $Attempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
        if (-not $passed) {
            $detail += " ($Attempts checks)"
        }
        $rows += [pscustomobject]@{ Assertion = "Installed per winget list as the runner account: $id"; Result = $(if ($passed) { 'PASS' } else { 'FAIL' }); Detail = $detail }
    }
    return $rows
}

<#
.SYNOPSIS
    Prefixes each row's assertion with 'Pass <n>: ', for a job that runs the task twice.
#>
function Add-SystemPassPrefix {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,
        [Parameter(Mandatory = $true)]
        [int]$PassNumber
    )

    return @($Rows | Where-Object { $null -ne $_ } | ForEach-Object {
            [pscustomobject]@{ Assertion = ('Pass {0}: {1}' -f $PassNumber, $_.Assertion); Result = $_.Result; Detail = $_.Detail }
        })
}

<#
.SYNOPSIS
    Runs the wrapper once as SYSTEM from a one-shot scheduled task, and reads what the run left.
.DESCRIPTION
    Registers the task (SYSTEM, highest run level, -TimeoutMinutes), starts it, waits for it
    (printing the newest transcript line every minute) and stops it 2 minutes past its limit, then
    removes it. Windows only.
.PARAMETER PowerShellPath
    The 32-bit powershell.exe the task runs.
.PARAMETER TaskArgument
    Get-SystemPassTaskArgument's result.
.PARAMETER TimeoutMinutes
    The task's time limit.
.PARAMETER LogFolder
    The installer's logs folder.
.RETURNS
    [pscustomobject] with StartError (why the task could not be registered or started, or $null),
    TaskExitCode ($null when it did not finish), StartedAt, Transcript, WrapperLog, RunRecordRead
    (Read-SystemPassRunRecord) and NewSystemProfileEntries.
#>
function Invoke-SystemPassTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,
        [Parameter(Mandatory = $true)]
        [string]$TaskArgument,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutMinutes,
        [Parameter(Mandatory = $true)]
        [string]$LogFolder
    )

    $profileBefore = Get-SystemProfileInstallEntry
    try {
        $action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $TaskArgument
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $script:SystemTaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop
        $startedAt = Get-Date
        Start-ScheduledTask -TaskName $script:SystemTaskName -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ StartError = $_.Exception.Message; TaskExitCode = $null; StartedAt = $null; Transcript = $null; WrapperLog = $null; RunRecordRead = $null; NewSystemProfileEntries = @() }
    }

    # 267009 (0x41301) is 'the task is running', 267011 (0x41303) 'the task has not yet run'.
    $deadline = $startedAt.AddMinutes($TimeoutMinutes + 2)
    $taskExitCode = $null
    $lastReport = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $task = Get-ScheduledTask -TaskName $script:SystemTaskName -ErrorAction SilentlyContinue
        $info = Get-ScheduledTaskInfo -TaskName $script:SystemTaskName -ErrorAction SilentlyContinue
        if ($task -and $info -and "$($task.State)" -ne 'Running' -and $info.LastRunTime -ge $startedAt.AddMinutes(-1) -and @(267009, 267011) -notcontains $info.LastTaskResult) {
            $taskExitCode = ConvertTo-TaskExitCode -LastTaskResult $info.LastTaskResult
            break
        }
        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            $lastReport = Get-Date
            $newest = Get-ChildItem -LiteralPath $LogFolder -Filter 'install-*.log' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime | Select-Object -Last 1
            $line = ''
            if ($newest) {
                $line = "$($newest.Name): " + (Get-Content -LiteralPath $newest.FullName -Tail 1 -ErrorAction SilentlyContinue)
            }
            Write-Host ('[{0:N0} min] the SYSTEM run is still going. {1}' -f ((Get-Date) - $startedAt).TotalMinutes, $line)
        }
    }
    if ($null -eq $taskExitCode) {
        Write-Host "The SYSTEM task did not finish within $($TimeoutMinutes + 2) minutes; stopping it." -ForegroundColor Red
        Stop-ScheduledTask -TaskName $script:SystemTaskName -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "The SYSTEM task ended with exit code $taskExitCode."
    }
    Unregister-ScheduledTask -TaskName $script:SystemTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $newProfileEntries = Compare-SystemProfileInstallEntry -Before $profileBefore -After (Get-SystemProfileInstallEntry)
    $transcript = Get-InstallPassTranscript -LogDirectory $LogFolder -Since $startedAt
    $wrapperLog = $null
    $wrapperFile = @((Get-InstallTranscriptFile -LogDirectory $LogFolder).Rmm | Where-Object { $_.LastWriteTime -ge $startedAt }) | Select-Object -Last 1
    if ($wrapperFile) {
        $wrapperLog = [string](Get-Content -LiteralPath $wrapperFile.FullName -Raw)
    }
    $runRecordRead = Read-SystemPassRunRecord -Path (Join-Path $LogFolder 'last-run.json')
    if ($runRecordRead.Problem) {
        Write-Host $runRecordRead.Problem -ForegroundColor Yellow
    }
    return [pscustomobject]@{
        StartError              = $null
        TaskExitCode            = $taskExitCode
        StartedAt               = $startedAt
        Transcript              = $transcript
        WrapperLog              = $wrapperLog
        RunRecordRead           = $runRecordRead
        NewSystemProfileEntries = @($newProfileEntries)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $wrapperFilePath = $RmmWrapperPath
    if (-not $wrapperFilePath) {
        $wrapperFilePath = Join-Path $repositoryRoot 'rmm\Invoke-WingetAppSetup.ps1'
    }
    $installerFilePath = $CheckoutInstallerPath
    if (-not $installerFilePath) {
        $installerFilePath = Join-Path $repositoryRoot 'winget-app-install.ps1'
    }
    $logFolder = $InstallerLogDirectory
    if (-not $logFolder) {
        $logFolder = Join-Path $env:ProgramData 'winget-app-setup\logs'
    }
    $wrapperFilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($wrapperFilePath)
    $installerFilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($installerFilePath)
    if (-not (Test-Path -LiteralPath $wrapperFilePath -PathType Leaf) -or -not (Test-Path -LiteralPath $installerFilePath -PathType Leaf)) {
        Write-Host "Invoke-SystemInstallPass.ps1: no wrapper at $wrapperFilePath or no installer at $installerFilePath." -ForegroundColor Red
        exit 64
    }
    $ErrorActionPreference = 'Continue'

    $installerSha256 = (Get-FileHash -LiteralPath $installerFilePath -Algorithm SHA256).Hash
    $powerShell32 = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgument = Get-SystemPassTaskArgument -WrapperPath $wrapperFilePath -InstallerPath $installerFilePath -InstallerSha256 $installerSha256 -SystemInstallEngine $SystemInstallEngine
    Write-Host "Installer under test: $installerFilePath (SHA256 $installerSha256), through $wrapperFilePath ($env:GITHUB_REF at $env:GITHUB_SHA)."
    Write-Host "The task runs as SYSTEM: $powerShell32 $taskArgument"

    # What last-run.json must say per app, from the checkout's catalog (the installer under test is
    # built from it), decided before the run as the installer decides it.
    $catalogExpectation = $null
    $appExpectationProblem = $null
    $wingetClientPin = $null
    try {
        $wingetAppSetupModule = Import-Module (Join-Path $repositoryRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force -PassThru -ErrorAction Stop
        $catalog = @(Get-DefaultAppCatalog)
        $applicability = Get-SystemRunApplicability -Catalog $catalog -Module $wingetAppSetupModule
        $removedApps = Get-PreinstalledAppRemovalList -ScriptPath (Join-Path $PSScriptRoot 'Remove-PreinstalledApps.ps1')
        $catalogExpectation = @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability $applicability -RemovedApps $removedApps)
        foreach ($expected in @('Installed', 'NotApplicable', 'Deferred')) {
            $ids = @($catalogExpectation | Where-Object { $_.Expected -eq $expected } | ForEach-Object { $_.Id })
            if ($ids.Count -gt 0) {
                Write-Host ('Expected in last-run.json, {0}: {1}' -f $expected, ($ids -join ', '))
            }
        }
        Write-Host ('Removed before the run, so expected Installed: {0}' -f ((@($catalogExpectation | Where-Object { $_.MustInstall } | ForEach-Object { $_.Id })) -join ', '))
        if ($SystemInstallEngine -eq 'WinGetClient') {
            $wingetClientPin = & $wingetAppSetupModule { Get-WingetClientModulePin }
            Write-Host ('Expected install engine: Microsoft.WinGet.Client {0}, SHA256 {1}.' -f $wingetClientPin.Version, $wingetClientPin.Sha256)
        }
    }
    catch {
        $appExpectationProblem = "could not work out what the catalog expects: $($_.Exception.Message)"
        Write-Host $appExpectationProblem -ForegroundColor Red
    }
    $skipApps = @("$env:KNOWN_PLATFORM_INCOMPATIBLE" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $allResults = @()
    $stepExitCode = 0
    for ($passNumber = 1; $passNumber -le $PassCount; $passNumber++) {
        if ($PassCount -gt 1) {
            Write-Host "=== SYSTEM pass $passNumber of $PassCount ==="
        }
        $taskRun = Invoke-SystemPassTask -PowerShellPath $powerShell32 -TaskArgument $taskArgument -TimeoutMinutes $TimeoutMinutes -LogFolder $logFolder
        if ($taskRun.StartError) {
            Write-Host "Could not register or start the SYSTEM task: $($taskRun.StartError)" -ForegroundColor Red
            exit 127
        }
        $runRecordRead = $taskRun.RunRecordRead
        # The second run must find every app the first one installed or found.
        $appExpectation = $catalogExpectation
        if ($passNumber -ge 2 -and $null -ne $catalogExpectation) {
            $appExpectation = @(Get-SystemPassAppExpectation -Catalog $catalog -Applicability $applicability -RemovedApps $removedApps -AlreadyPresent)
        }

        $check = Get-SystemInstallPassResult -TaskExitCode $taskRun.TaskExitCode -Transcript $taskRun.Transcript -WrapperLog $taskRun.WrapperLog -RunRecord $runRecordRead.Record -RunRecordProblem $runRecordRead.Problem -NewSystemProfileEntries $taskRun.NewSystemProfileEntries -KnownPlatformIncompatible "$env:KNOWN_PLATFORM_INCOMPATIBLE" -AppExpectation $appExpectation -AppExpectationProblem $appExpectationProblem -SecondPass:($passNumber -ge 2)
        $passResults = @($check.Results)
        if ($check.StepExitCode -ne 0 -and $stepExitCode -eq 0) {
            $stepExitCode = $check.StepExitCode
        }
        if ($SystemInstallEngine -eq 'WinGetClient') {
            if ($null -eq $wingetClientPin) {
                $passResults += [pscustomobject]@{ Assertion = 'Installs ran through Microsoft.WinGet.Client'; Result = 'FAIL'; Detail = 'the checkout''s Microsoft.WinGet.Client pin could not be read' }
            }
            else {
                $passResults += @(Get-SystemPassEngineResult -WrapperLog $taskRun.WrapperLog -Transcript $taskRun.Transcript -RunRecord $runRecordRead.Record -Pin $wingetClientPin -AppExpectation $appExpectation -PassNumber $passNumber)
            }
            if ($passNumber -eq 1) {
                # Not the engine's own detection: winget.exe as the runner account, through the
                # checkout's module, where the engine is never active.
                $testInstalled = {
                    param ($Id)
                    & $wingetAppSetupModule { param ($PackageId) Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds 60 } $Id
                }
                $passResults += @(Get-SystemPassIndependentInstallResult -AppExpectation $appExpectation -TestInstalled $testInstalled -SkipApps $skipApps)
            }
        }
        if ($PassCount -gt 1) {
            $passResults = Add-SystemPassPrefix -Rows $passResults -PassNumber $passNumber
        }
        $allResults += $passResults
    }
    if ($stepExitCode -eq 0 -and @($allResults | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) {
        $stepExitCode = 1
    }

    Write-Host ''
    Write-Host '=== E2E assertion results ==='
    Write-Host ($allResults | Format-Table -AutoSize -Wrap | Out-String -Width 4096).TrimEnd()
    $failures = @($allResults | Where-Object { $_.Result -eq 'FAIL' })
    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host "FAILED: $($failures.Count) assertion(s) failed:" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "  - $($failure.Assertion): $($failure.Detail)" -ForegroundColor Red
        }
    }
    else {
        Write-Host ''
        Write-Host "PASSED: all $(@($allResults).Count) assertions passed." -ForegroundColor Green
    }
    exit $stepExitCode
}
