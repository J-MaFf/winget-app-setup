# TestHelpers.ps1
# Shared bootstrap for the per-area Pester files in this directory (issue #192).
#
# Dot-source this from each test file's top-level BeforeAll:
#
#     BeforeAll {
#         . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
#     }
#
# It resolves the repo paths and dot-sources the WingetAppSetup module's function files
# (WingetAppSetup/Private + WingetAppSetup/Public — the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by
# build/Build-WingetInstallScript.ps1). Each Pester test file is its own session scope,
# so loading here preserves the old suite's load-once semantics per file: every Describe
# in a file shares one set of definitions, with no bleed between files.
#
# It also gives Linux/macOS what the suite needs from Windows (see "Off Windows" below), so
# the whole suite runs there too and a new failure stands out instead of hiding in ~100
# environment failures (wgt-gq8.5).
#
# This file deliberately has no .Tests.ps1 suffix so `Invoke-Pester ./tests` never
# discovers it as a test container.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WingetAppSetupRoot = Join-Path $script:RepoRoot 'WingetAppSetup'
$script:ModuleManifestPath = Join-Path $script:WingetAppSetupRoot 'WingetAppSetup.psd1'
$script:InstallerScriptPath = Join-Path $script:RepoRoot 'winget-app-install.ps1'
$script:UninstallerScriptPath = Join-Path $script:RepoRoot 'winget-app-uninstall.ps1'

Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Private'), (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

# Force PowerShellGet/PackageManagement autoload while the real Get-Command is still in
# effect. Pester resolves every Mock target through command discovery, and a test that
# mocks Get-Command first (e.g. the dry-run test in Install.Tests.ps1) breaks autoload for later
# mock targets like Install-Module. The old single-file suite got this resolution for free
# from Describe ordering; the split files must not depend on run order.
$null = Get-Command Install-Module, Install-PackageProvider, Get-PackageProvider -ErrorAction SilentlyContinue

# Off Windows: stand-ins for the Windows-only commands the tests mock (wgt-gq8.5). Pester can
# only mock a command that exists, so without these every test that mocks one fails on
# Linux/macOS with "Could not find Command". A stand-in is defined only when the command is
# missing, so on Windows the real cmdlet is what gets mocked. Each declares the real cmdlet's
# parameter names (and switch types): -ParameterFilter blocks read them ($Name, $AllUsers,
# $TaskName, $Force, ...) and the code under test passes them, so a parameterless stand-in would
# leave every filter seeing $null. The scheduled-task objects keep their real CimInstance types, so
# a fake trigger fails to bind here exactly as on Windows unless the Mock uses -RemoveParameterType.
# An unmocked call throws CommandNotFoundException, as calling the missing command did. That fails
# the test only if the code under test lets it through: production code that catches it (for
# example around Get-AppxPackage) hides it here, while on Windows the same call reads the real
# machine. So Mock every Windows-only command the code under test reaches, even one whose failure
# it tolerates. winget and powershell.exe are native executables: their stand-ins take $args,
# which is how Pester hands a mocked executable its arguments on Windows too. When a test starts
# mocking another command Linux lacks, add it here; tests/TestHarness.Tests.ps1 names any that
# are missing.
$windowsOnlyCommandParameters = [ordered]@{
    'Get-AppxPackage'             = { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, [Parameter(Position = 1)][string]$Publisher, [switch]$AllUsers, [string]$User, [string]$PackageTypeFilter, [string]$Volume) }
    'Add-AppxPackage'             = { [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string[]]$DependencyPath, [switch]$Register, [switch]$DisableDevelopmentMode, [switch]$RegisterByFamilyName, [string]$MainPackage, [string[]]$DependencyPackages, [switch]$ForceApplicationShutdown, [switch]$ForceTargetApplicationShutdown, [switch]$ForceUpdateFromAnyVersion, [switch]$Stage, [switch]$Update, [string]$Volume) }
    'Get-CimInstance'             = { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter, [string]$Query, [string[]]$Property, [string[]]$ComputerName, [switch]$KeyOnly, [uint32]$OperationTimeoutSec) }
    'Get-ScheduledTask'           = { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$TaskName, [Parameter(Position = 1)][string[]]$TaskPath) }
    'Get-ScheduledTaskInfo'       = { [CmdletBinding()] param([Parameter(Position = 0)][string]$TaskName, [Parameter(Position = 1)][string]$TaskPath, [Microsoft.Management.Infrastructure.CimInstance]$InputObject) }
    'Set-ScheduledTask'           = { [CmdletBinding()] param([Parameter(Position = 0)][string]$TaskName, [string]$TaskPath, [Microsoft.Management.Infrastructure.CimInstance[]]$Action, [Microsoft.Management.Infrastructure.CimInstance[]]$Trigger, [Microsoft.Management.Infrastructure.CimInstance]$Settings, [Microsoft.Management.Infrastructure.CimInstance]$Principal, [string]$User, [string]$Password, [Microsoft.Management.Infrastructure.CimInstance]$InputObject) }
    'Unregister-ScheduledTask'    = { [CmdletBinding(SupportsShouldProcess = $true)] param([Parameter(Position = 0)][string[]]$TaskName, [Parameter(Position = 1)][string[]]$TaskPath, [Microsoft.Management.Infrastructure.CimInstance[]]$InputObject) }
    'Repair-WinGetPackageManager' = { [CmdletBinding()] param([string]$Version, [switch]$Latest, [switch]$IncludePrerelease, [switch]$AllUsers, [switch]$Force) }
    'Get-AuthenticodeSignature'   = { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$FilePath, [string[]]$LiteralPath, [string[]]$SourcePathOrExtension, [byte[]]$Content) }
    'Get-Acl'                     = { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [psobject]$InputObject, [switch]$Audit, [string]$Filter, [string[]]$Include, [string[]]$Exclude) }
    'Get-Service'                 = { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [string[]]$DisplayName, [string[]]$Include, [string[]]$Exclude, [switch]$DependentServices, [switch]$RequiredServices, [object[]]$InputObject) }
    'Restart-Service'             = { [CmdletBinding(SupportsShouldProcess = $true)] param([Parameter(Position = 0)][string[]]$Name, [string[]]$DisplayName, [string[]]$Include, [string[]]$Exclude, [switch]$Force, [switch]$PassThru, [object[]]$InputObject) }
    'Start-Service'               = { [CmdletBinding(SupportsShouldProcess = $true)] param([Parameter(Position = 0)][string[]]$Name, [string[]]$DisplayName, [string[]]$Include, [string[]]$Exclude, [switch]$PassThru, [object[]]$InputObject) }
    'Register-ScheduledTask'      = { [CmdletBinding()] param([Parameter(Position = 0)][string]$TaskName, [Parameter(Position = 1)][string]$TaskPath, [Microsoft.Management.Infrastructure.CimInstance[]]$Action, [Microsoft.Management.Infrastructure.CimInstance[]]$Trigger, [Microsoft.Management.Infrastructure.CimInstance]$Settings, [Microsoft.Management.Infrastructure.CimInstance]$Principal, [string]$User, [string]$Password, [string]$RunLevel, [string]$Description, [string]$Xml, [Microsoft.Management.Infrastructure.CimInstance]$InputObject, [switch]$Force) }
    'Start-ScheduledTask'         = { [CmdletBinding()] param([Parameter(Position = 0)][string]$TaskName, [Parameter(Position = 1)][string]$TaskPath, [Microsoft.Management.Infrastructure.CimInstance]$InputObject) }
    'Stop-ScheduledTask'          = { [CmdletBinding()] param([Parameter(Position = 0)][string]$TaskName, [Parameter(Position = 1)][string]$TaskPath, [Microsoft.Management.Infrastructure.CimInstance]$InputObject) }
    'New-LocalUser'               = { [CmdletBinding(SupportsShouldProcess = $true)] param([Parameter(Position = 0)][string]$Name, [securestring]$Password, [datetime]$AccountExpires, [switch]$AccountNeverExpires, [string]$Description, [switch]$Disabled, [string]$FullName, [switch]$NoPassword, [switch]$PasswordNeverExpires, [switch]$UserMayNotChangePassword) }
    'winget'                      = $null
    'powershell.exe'              = $null
}
$script:WindowsOnlyCommandNames = @($windowsOnlyCommandParameters.Keys)
$script:WindowsOnlyNativeCommandNames = @($script:WindowsOnlyCommandNames | Where-Object { $null -eq $windowsOnlyCommandParameters[$_] })
$script:WindowsOnlyCommandStandIns = @()
foreach ($commandName in $script:WindowsOnlyCommandNames) {
    # A file that loads this helper twice (once more at its top level, for a BeforeDiscovery block
    # that needs a module function) finds its own stand-in the second time; only a real command
    # counts as present.
    $existingCommand = Get-Command -Name $commandName -ErrorAction SilentlyContinue
    if ($existingCommand -and "$($existingCommand.Definition)" -notmatch 'defines this stand-in') {
        continue
    }
    $signature = "$($windowsOnlyCommandParameters[$commandName])"
    $body = "throw [System.Management.Automation.CommandNotFoundException]::new('$commandName is a Windows-only command. tests/TestHelpers.ps1 defines this stand-in only so tests can mock it; this test called it without a Mock.')"
    Set-Item -Path "function:$commandName" -Value ([scriptblock]::Create("$signature`n$body"))
    $script:WindowsOnlyCommandStandIns += $commandName
}

# The functions a manifest import of the module exports, which is how e2e/Assert-Install.ps1 loads
# it (review finding P3-44). Imported in a runspace of its own, so the test file's own definitions
# and mocks are left alone.
function Get-ManifestExportedFunctionName {
    $powerShell = [powershell]::Create()
    try {
        [void]$powerShell.AddScript('param ($Path) @((Import-Module -Name $Path -PassThru -Force -ErrorAction Stop).ExportedFunctions.Keys)').AddArgument($script:ModuleManifestPath)
        $names = @($powerShell.Invoke())
        if ($powerShell.HadErrors) {
            throw "Importing $($script:ModuleManifestPath) failed: $(@($powerShell.Streams.Error) -join '; ')"
        }
        return $names
    }
    finally {
        $powerShell.Dispose()
    }
}

# A copy of the generated winget-app-uninstall.ps1 at -Path, with -Overrides inserted just before its
# entry block: defined after the module's functions, they replace those of the same name, while the
# real entry block runs unchanged (EntryPoint.Tests.ps1 does the same for the installer). Never
# dot-source the result (tests/TestHarness.Tests.ps1): run it in a child process.
function New-TestUninstallerScript {
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Overrides = ''
    )

    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UninstallerScriptPath
    $entry = [regex]::Match($text, '(?m)^# -+Main Script-+\r?$')
    if (-not $entry.Success) {
        throw "$($script:UninstallerScriptPath) has no Main Script marker; regenerate it with build/Build-WingetInstallScript.ps1."
    }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    Set-Content -LiteralPath $Path -Value $text.Insert($entry.Index, "$Overrides`n") -Encoding UTF8
    return $Path
}

# Runs New-TestUninstallerScript's copy (under -Root, as winget-app-uninstall.ps1) in a child
# PowerShell, so its exit ends the child, not the test run: with -File, or with -ViaInvokeExpression
# the way irm | iex runs it (no script file), followed by -AfterInvokeExpression.
function Invoke-TestUninstallerScript {
    param (
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Overrides = '',
        [string[]]$ScriptArguments = @(),
        [hashtable]$Environment = @{},
        [switch]$ViaInvokeExpression,
        [string]$AfterInvokeExpression = ''
    )

    $scriptPath = New-TestUninstallerScript -Path (Join-Path $Root 'winget-app-uninstall.ps1') -Overrides $Overrides
    $arguments = @('-File', $scriptPath) + $ScriptArguments
    if ($ViaInvokeExpression) {
        $arguments = @('-Command', ("Get-Content -Raw -LiteralPath '{0}' | Invoke-Expression; {1}" -f $scriptPath.Replace("'", "''"), $AfterInvokeExpression))
    }

    $saved = @{}
    foreach ($name in $Environment.Keys) {
        $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
        [System.Environment]::SetEnvironmentVariable($name, $Environment[$name])
    }
    try {
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($name in $saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Path = $scriptPath }
}

# Test doubles for the process helpers (WingetAppSetup/Private/ProcessInvocation.ps1, review
# findings P2-5, P2-6 and P3-6). Call-site tests mock Invoke-WingetProcess or
# Invoke-ExternalProcess and return New-TestProcessResult, which has the same shape as the real
# result. New-FakeExecutable writes a small program the real helper can run on either platform.
function New-TestProcessResult {
    param (
        [AllowNull()]$ExitCode = 0,
        [string[]]$Output = @(),
        [string[]]$StandardError = @(),
        [switch]$TimedOut,
        [switch]$LaunchFailed,
        [AllowNull()]$LaunchErrorCode = $null,
        [string]$LaunchError = 'The file cannot be accessed by the system.',
        [string]$LogPath = $null,
        [AllowNull()]$ProcessId = $null,
        [AllowNull()]$StartedAtUtc = $null,
        [AllowNull()]$ExitedAtUtc = $null
    )

    $exception = $null
    if ($LaunchFailed) {
        $code = 0
        if ($null -ne $LaunchErrorCode) { $code = [int]$LaunchErrorCode }
        $exception = [System.ComponentModel.Win32Exception]::new($code, $LaunchError)
    }
    [pscustomobject]@{
        FilePath        = 'winget'
        Arguments       = ''
        ExitCode        = $(if ($TimedOut -or $LaunchFailed) { $null } else { $ExitCode })
        TimedOut        = [bool]$TimedOut
        LaunchFailed    = [bool]$LaunchFailed
        LaunchErrorCode = $(if ($LaunchFailed) { $LaunchErrorCode } else { $null })
        LaunchError     = $(if ($LaunchFailed) { $LaunchError } else { $null })
        LaunchException = $exception
        Output          = @($Output) + @($StandardError)
        StandardOutput  = @($Output)
        StandardError   = @($StandardError)
        DurationSeconds = 0
        LogPath         = $(if ($LogPath) { $LogPath } else { $null })
        ProcessId       = $ProcessId
        StartedAtUtc    = $StartedAtUtc
        ExitedAtUtc     = $ExitedAtUtc
    }
}

# A Get-PendingRestartState result (review finding P3-16), for `Mock Get-PendingRestartState`. Every
# test that drives Invoke-WingetInstall mocks that read: on Windows it reads the real registry, where
# another installation on the machine could queue a file replacement mid-test and turn the run's
# exit code into 3010.
function New-TestRestartState {
    param (
        [switch]$ComponentServicing,
        [switch]$WindowsUpdate,
        [string[]]$FileRenames = @()
    )

    [pscustomobject]@{
        ComponentServicing = [bool]$ComponentServicing
        WindowsUpdate      = [bool]$WindowsUpdate
        FileRenames        = @($FileRenames)
    }
}

# A Get-InstallAccountContext result (review findings P2-24, P3-22, P3-23), for
# `Mock Get-InstallAccountContext`. Every test that drives Invoke-WingetInstall past its admin check
# mocks that read: on Windows it reads the real process token and the console session (CIM), and a
# runner that runs as SYSTEM, or one with another account signed in at the console, would turn the
# run into one for the whole PC. The default is a same-user run.
function New-TestAccountContext {
    param (
        [switch]$System,
        [switch]$CrossUser,
        [string]$ProcessUser = 'CONTOSO\admin-tech',
        [string]$SessionUser = 'CONTOSO\admin-tech'
    )

    if ($System) {
        $ProcessUser = 'NT AUTHORITY\SYSTEM'
    }
    [pscustomobject]@{
        IsSystem             = [bool]$System
        ProcessUser          = $ProcessUser
        SessionUser          = $SessionUser
        IsCrossUserElevation = [bool]$CrossUser
    }
}

# What Get-Acl returns for a file, for `Mock Get-Acl { New-TestFileAcl }`: the owner and the access
# entries by SID (GetOwner, GetAccessRules), with each entry's FileSystemRights and PropagationFlags.
# The default is what an installer run as SYSTEM leaves on last-run.json: owned by SYSTEM, full
# control for SYSTEM and Administrators, read and execute for Users. Each rule is a hashtable with
# Sid and Rights, and optionally Type ('Allow' or 'Deny') and InheritOnly. Every test that reads a
# run record mocks Get-Acl, or Get-DirectoryAccessSummary above it: on Windows the real call reads
# the test file's own access list, which the runner's account owns (work-order item 34's review).
function New-TestFileAcl {
    param (
        [string]$OwnerSid = 'S-1-5-18',
        [object[]]$Rules = @(
            @{ Sid = 'S-1-5-18'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-544'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-545'; Rights = 1179817 }
        )
    )

    $testRules = @(foreach ($rule in $Rules) {
            $type = 'Allow'
            if ($rule.Type) { $type = $rule.Type }
            $propagation = 0
            if ($rule.InheritOnly) { $propagation = 2 }
            [pscustomobject]@{
                IdentityReference = [pscustomobject]@{ Value = $rule.Sid }
                FileSystemRights  = [long]$rule.Rights
                AccessControlType = $type
                IsInherited       = $true
                PropagationFlags  = $propagation
            }
        })
    $acl = [pscustomobject]@{
        AreAccessRulesProtected = $false
        TestOwner               = [pscustomobject]@{ Value = $OwnerSid }
        TestRules               = $testRules
    }
    $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param ($Type) $this.TestOwner }
    $acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { param ($Explicit, $Inherited, $Type) $this.TestRules }
    return $acl
}

# For tests that script winget's behaviour with `Mock winget { ... }` (reading $args, setting
# $global:LASTEXITCODE, throwing when winget cannot run): code that now runs winget through
# Invoke-WingetProcess reaches that mock through
#     Mock Invoke-WingetProcess { Invoke-TestWingetMock -ArgumentList $ArgumentList }
# which turns the mock's output, exit code or exception into a process result.
function Invoke-TestWingetMock {
    param ([string[]]$ArgumentList = @())

    $global:LASTEXITCODE = 0
    try {
        $lines = @(winget @ArgumentList 2>&1 | ForEach-Object { "$_" })
    }
    catch {
        return New-TestProcessResult -LaunchFailed -LaunchErrorCode 0 -LaunchError "$($_.Exception.Message)"
    }
    New-TestProcessResult -ExitCode $global:LASTEXITCODE -Output $lines
}

# A program that prints the given lines, optionally waits, and exits with the given code: a .cmd
# file on Windows, a /bin/sh script elsewhere. Keep the lines to letters, digits, spaces and
# ':.[]-' so cmd's echo prints them unchanged.
function New-FakeExecutable {
    param (
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$StandardOutput = @(),
        [string[]]$StandardError = @(),
        [int]$ExitCode = 0,
        [int]$SleepSeconds = 0
    )

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $path = Join-Path $Directory "$Name.cmd"
        $lines = @('@echo off')
        $lines += @($StandardOutput | ForEach-Object { "echo $_" })
        $lines += @($StandardError | ForEach-Object { "echo $_ 1>&2" })
        if ($SleepSeconds -gt 0) { $lines += "ping -n $($SleepSeconds + 1) 127.0.0.1 >nul" }
        $lines += "exit /b $ExitCode"
        Set-Content -LiteralPath $path -Value $lines -Encoding ascii
        return $path
    }

    $path = Join-Path $Directory $Name
    $lines = @('#!/bin/sh')
    $lines += @($StandardOutput | ForEach-Object { "printf '%s\n' '$($_ -replace "'", "'\''")'" })
    $lines += @($StandardError | ForEach-Object { "printf '%s\n' '$($_ -replace "'", "'\''")' >&2" })
    if ($SleepSeconds -gt 0) { $lines += "sleep $SleepSeconds" }
    $lines += "exit $ExitCode"
    Set-Content -LiteralPath $path -Value ($lines -join "`n") -NoNewline -Encoding ascii
    [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
    return $path
}

# Off Windows: the Windows folders the code under test joins paths onto. Unset, Join-Path fails
# on a null path before the code reaches what a test checks. Each is set only when missing
# (Windows always has them) and is not created here; tests mock the file system or use TestDrive.
$windowsFolderVariables = [ordered]@{
    TEMP         = [System.IO.Path]::GetTempPath()
    APPDATA      = Join-Path ([System.IO.Path]::GetTempPath()) 'winget-app-setup-tests/AppData/Roaming'
    LOCALAPPDATA = Join-Path ([System.IO.Path]::GetTempPath()) 'winget-app-setup-tests/AppData/Local'
    ProgramData  = Join-Path ([System.IO.Path]::GetTempPath()) 'winget-app-setup-tests/ProgramData'
}
foreach ($variableName in $windowsFolderVariables.Keys) {
    if (-not [System.Environment]::GetEnvironmentVariable($variableName)) {
        Set-Item -Path "env:$variableName" -Value $windowsFolderVariables[$variableName]
    }
}
Remove-Variable -Name windowsOnlyCommandParameters, commandName, existingCommand, signature, body, windowsFolderVariables, variableName -ErrorAction SilentlyContinue
