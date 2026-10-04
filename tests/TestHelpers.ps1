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
# mocks Get-Command first (e.g. the grid-view tests) breaks autoload for later mock
# targets like Install-Module. The old single-file suite got this resolution for free
# from Describe ordering; the split files must not depend on run order.
$null = Get-Command Install-Module, Install-PackageProvider, Get-PackageProvider -ErrorAction SilentlyContinue

# Off Windows: stand-ins for the Windows-only commands the tests mock (wgt-gq8.5). Pester can
# only mock a command that exists, so without these every test that mocks one fails on
# Linux/macOS with "Could not find Command". A stand-in is defined only when the command is
# missing, so on Windows the real cmdlet is what gets mocked. Each declares the real cmdlet's
# parameter names (and switch types): -ParameterFilter blocks read them ($Name, $AllUsers,
# $TaskName, $Force, ...) and the code under test passes them, so a parameterless stand-in would
# leave every filter seeing $null. An unmocked call throws CommandNotFoundException, as calling
# the missing command did, so a test that forgets its Mock still fails instead of passing against
# a no-op. winget and powershell.exe are native executables: their stand-ins take $args, which is
# how Pester hands a mocked executable its arguments on Windows too. When a test starts mocking
# another command Linux lacks, add it here; tests/TestHarness.Tests.ps1 names any that are missing.
$windowsOnlyCommandParameters = [ordered]@{
    'Get-AppxPackage'             = { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, [Parameter(Position = 1)][string]$Publisher, [switch]$AllUsers, [string]$User, [string]$PackageTypeFilter, [string]$Volume) }
    'Add-AppxPackage'             = { [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string[]]$DependencyPath, [switch]$Register, [switch]$DisableDevelopmentMode, [switch]$RegisterByFamilyName, [string]$MainPackage, [string[]]$DependencyPackages, [switch]$ForceApplicationShutdown, [switch]$ForceTargetApplicationShutdown, [switch]$ForceUpdateFromAnyVersion, [switch]$Stage, [switch]$Update, [string]$Volume) }
    'Get-CimInstance'             = { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter, [string]$Query, [string[]]$Property, [string[]]$ComputerName, [switch]$KeyOnly, [uint32]$OperationTimeoutSec) }
    'Get-ScheduledTask'           = { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$TaskName, [Parameter(Position = 1)][string[]]$TaskPath) }
    'Set-ScheduledTask'           = { [CmdletBinding()] param([Parameter(Position = 0)][string]$TaskName, [string]$TaskPath, [object[]]$Action, [object[]]$Trigger, [object]$Settings, [object]$Principal, [string]$User, [string]$Password, [object]$InputObject) }
    'Unregister-ScheduledTask'    = { [CmdletBinding(SupportsShouldProcess = $true)] param([Parameter(Position = 0)][string[]]$TaskName, [Parameter(Position = 1)][string[]]$TaskPath, [object[]]$InputObject) }
    'Repair-WinGetPackageManager' = { [CmdletBinding()] param([string]$Version, [switch]$Latest, [switch]$IncludePrerelease, [switch]$AllUsers, [switch]$Force) }
    'winget'                      = $null
    'powershell.exe'              = $null
}
$script:WindowsOnlyCommandNames = @($windowsOnlyCommandParameters.Keys)
$script:WindowsOnlyNativeCommandNames = @($script:WindowsOnlyCommandNames | Where-Object { $null -eq $windowsOnlyCommandParameters[$_] })
$script:WindowsOnlyCommandStandIns = @()
foreach ($commandName in $script:WindowsOnlyCommandNames) {
    # A file that loads this helper twice (see Install.Tests.ps1) finds its own stand-in the
    # second time; only a real command counts as present.
    $existingCommand = Get-Command -Name $commandName -ErrorAction SilentlyContinue
    if ($existingCommand -and "$($existingCommand.Definition)" -notmatch 'defines this stand-in') {
        continue
    }
    $signature = "$($windowsOnlyCommandParameters[$commandName])"
    $body = "throw [System.Management.Automation.CommandNotFoundException]::new('$commandName is a Windows-only command. tests/TestHelpers.ps1 defines this stand-in only so tests can mock it; this test called it without a Mock.')"
    Set-Item -Path "function:$commandName" -Value ([scriptblock]::Create("$signature`n$body"))
    $script:WindowsOnlyCommandStandIns += $commandName
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
