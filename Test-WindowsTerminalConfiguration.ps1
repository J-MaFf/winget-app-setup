<#
.SYNOPSIS
    Smoke-test validation for Windows Terminal default shell configuration.

.DESCRIPTION
    Verifies that:
    1) Windows Terminal settings.json exists.
    2) defaultProfile is set to PowerShell 7 GUID.
    3) HKCU:\Console\%%Startup delegation values point to Windows Terminal.

.PARAMETER AsJson
    Output a JSON payload in addition to console summary.

.EXAMPLE
    .\Test-WindowsTerminalConfiguration.ps1

.EXAMPLE
    .\Test-WindowsTerminalConfiguration.ps1 -AsJson
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [switch]$AsJson
)

$expectedDefaultProfile = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
$expectedDelegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
$expectedDelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

$settingsPathCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
)

$resolvedSettingsPath = $settingsPathCandidates | Where-Object { Test-Path -Path $_ } | Select-Object -First 1

$results = @()

# Check settings file existence
$results += [pscustomobject]@{
    Check    = 'Settings file exists'
    Passed   = [bool]$resolvedSettingsPath
    Expected = 'An existing Windows Terminal settings.json path'
    Actual   = if ($resolvedSettingsPath) { $resolvedSettingsPath } else { 'Not found' }
}

# Check default profile when settings file exists
$settingsDefaultProfile = $null
if ($resolvedSettingsPath) {
    try {
        $settingsObject = Get-Content -Path $resolvedSettingsPath -Raw | ConvertFrom-Json
        $settingsDefaultProfile = $settingsObject.defaultProfile
    }
    catch {
        $settingsDefaultProfile = "Read/parse error: $($_.Exception.Message)"
    }
}

$results += [pscustomobject]@{
    Check    = 'defaultProfile is PowerShell 7'
    Passed   = ($settingsDefaultProfile -eq $expectedDefaultProfile)
    Expected = $expectedDefaultProfile
    Actual   = if ($settingsDefaultProfile) { $settingsDefaultProfile } else { 'Unavailable' }
}

# Check registry delegation values
$registryPath = 'HKCU:\Console\%%Startup'
$delegationConsole = $null
$delegationTerminal = $null

try {
    $reg = Get-ItemProperty -Path $registryPath -ErrorAction Stop
    $delegationConsole = $reg.DelegationConsole
    $delegationTerminal = $reg.DelegationTerminal
}
catch {
    $delegationConsole = 'Unavailable'
    $delegationTerminal = 'Unavailable'
}

$results += [pscustomobject]@{
    Check    = 'DelegationConsole is Windows Terminal'
    Passed   = ($delegationConsole -eq $expectedDelegationConsole)
    Expected = $expectedDelegationConsole
    Actual   = $delegationConsole
}

$results += [pscustomobject]@{
    Check    = 'DelegationTerminal is Windows Terminal'
    Passed   = ($delegationTerminal -eq $expectedDelegationTerminal)
    Expected = $expectedDelegationTerminal
    Actual   = $delegationTerminal
}

$passedCount = ($results | Where-Object Passed).Count
$totalCount = $results.Count
$allPassed = ($passedCount -eq $totalCount)

Write-Host ''
Write-Host 'Windows Terminal Configuration Smoke Test' -ForegroundColor Cyan
Write-Host '----------------------------------------' -ForegroundColor Cyan
# Route the table to the host (like the Write-Host lines around it) so the success stream
# stays clean: with -AsJson, stdout must carry ONLY the JSON payload so callers can pipe
# it straight into ConvertFrom-Json (issue #187).
$results | Format-Table -AutoSize | Out-Host
Write-Host "Result: $passedCount/$totalCount checks passed." -ForegroundColor $(if ($allPassed) { 'Green' } else { 'Yellow' })

if ($AsJson) {
    [pscustomobject]@{
        allPassed = $allPassed
        passed    = $passedCount
        total     = $totalCount
        checks    = $results
    } | ConvertTo-Json -Depth 6
}

if (-not $allPassed) {
    exit 1
}

exit 0
