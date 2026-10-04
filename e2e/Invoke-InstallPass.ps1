<#
.SYNOPSIS
    Runs one install pass of the end-to-end workflow and applies its exit-code policy.
.DESCRIPTION
    Used by every install step in .github/workflows/e2e-install.yml, in both legs: the
    PowerShell 7 leg (e2e-install) and the Windows PowerShell 5.1 leg
    (e2e-install-windows-powershell, review finding P3-40). Each pass starts the installer in a
    fresh process of the chosen PowerShell, the way a technician opens a new console:

      - Source 'raw-main' (the weekly run): the documented one-liner, fetched from raw main, in
        both passes: Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "<url>" | iex
      - Source 'checkout', -Entry OneLiner (pull requests and dispatched runs, first pass): the
        checkout's winget-app-install.ps1 piped to iex the same way, with no file path.
      - Source 'checkout', -Entry File (second pass): <shell> -NoProfile -ExecutionPolicy Bypass
        -File <checkout>, the entry for clone, RMM and CI runs.

    Under Windows PowerShell an iex run has no file to relaunch, so the bootstrap downloads the
    installer again, from raw main, for its PowerShell 7 relaunch. A checkout one-liner run in
    that shell therefore defines an Invoke-RestMethod function first that answers that one URL
    with the checkout's file and passes every other call to the real cmdlet; it lives only in the
    Windows PowerShell process, not in the PowerShell 7 run it starts. Without it the PowerShell 7
    half of the pass would test main instead of the change. Assert-Install.ps1 -InstallerPath
    checks the result: every transcript, the bootstrap ones included, must log the checkout's
    build id.

    Exit-code policy (the step fails with the code this script exits with):
      - 0: the pass succeeded.
      - 1 with KNOWN_PLATFORM_INCOMPATIBLE set: tolerated (exit 0) pending the assertion step's
        containment check that nothing outside that list failed. An empty variable means strict.
      - anything else: the pass failed, with the installer's code.

    Runs under Windows PowerShell 5.1 and PowerShell 7: ASCII only, no 7-only syntax.
.PARAMETER Pass
    'first' or 'second'; used in the messages.
.PARAMETER Shell
    The PowerShell that starts the installer: 'pwsh' or 'powershell' (Windows PowerShell 5.1).
.PARAMETER Entry
    'OneLiner' (piped to iex) or 'File' (-File). A raw-main pass always runs the one-liner.
.PARAMETER Source
    'raw-main' or 'checkout'. Default: $env:INSTALLER_SOURCE; anything but 'raw-main' runs the
    checkout.
.PARAMETER KnownPlatformIncompatible
    Default: $env:KNOWN_PLATFORM_INCOMPATIBLE.
.PARAMETER InstallerPath
    The checkout's installer. Default: winget-app-install.ps1 at the repository root.
.NOTES
    Exit codes: the policy above. 64 = bad arguments.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Pass,

    [Parameter(Mandatory = $false)]
    [string]$Shell,

    [Parameter(Mandatory = $false)]
    [string]$Entry,

    [Parameter(Mandatory = $false)]
    [string]$Source = $env:INSTALLER_SOURCE,

    [Parameter(Mandatory = $false)]
    [string]$KnownPlatformIncompatible = $env:KNOWN_PLATFORM_INCOMPATIBLE,

    [Parameter(Mandatory = $false)]
    [string]$InstallerPath
)

<#
.SYNOPSIS
    Returns the script text that makes Invoke-RestMethod answer the installer's raw URL with a
    local file.
.DESCRIPTION
    Any raw.githubusercontent.com URL of this repository's winget-app-install.ps1 (whatever ref)
    gets the file's text, read as UTF-8 like the real download; the call is logged, so the
    bootstrap transcript says the checkout was served. Every other call goes to the real cmdlet
    with its arguments unchanged (@args keeps the parameter names).
.PARAMETER InstallerPath
    The file to serve.
#>
function Get-CheckoutRelaunchShim {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    $quotedPath = "'" + $InstallerPath.Replace("'", "''") + "'"
    return @"
`$global:WingetAppSetupE2ECheckoutInstaller = $quotedPath
function global:Invoke-RestMethod {
    foreach (`$argument in `$args) {
        if ("`$argument" -match '^https://raw\.githubusercontent\.com/J-MaFf/winget-app-setup/.+/winget-app-install\.ps1`$') {
            Write-Host "[e2e] Serving the checkout's installer (`$global:WingetAppSetupE2ECheckoutInstaller) for `$argument"
            return (Get-Content -Raw -Encoding UTF8 -LiteralPath `$global:WingetAppSetupE2ECheckoutInstaller)
        }
    }
    Microsoft.PowerShell.Utility\Invoke-RestMethod @args
}
"@
}

<#
.SYNOPSIS
    Works out the command line of one install pass.
.PARAMETER Shell
    'pwsh' or 'powershell'.
.PARAMETER Entry
    'OneLiner' or 'File'.
.PARAMETER Source
    'raw-main' or anything else (the checkout).
.PARAMETER InstallerPath
    The checkout's installer.
.RETURNS
    [pscustomobject] with FilePath, Arguments (string[]), Description and Script (the text a
    one-liner pass runs, $null for -File).
#>
function Get-InstallPassCommand {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('pwsh', 'powershell')]
        [string]$Shell,
        [Parameter(Mandatory = $true)]
        [ValidateSet('OneLiner', 'File')]
        [string]$Entry,
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    $shellName = 'PowerShell 7'
    if ($Shell -eq 'powershell') {
        $shellName = 'Windows PowerShell'
    }

    if ($Source -ne 'raw-main' -and $Entry -eq 'File') {
        return [pscustomobject]@{
            FilePath    = $Shell
            Arguments   = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $InstallerPath)
            Description = "the checkout ($InstallerPath), run with -File in $shellName"
            Script      = $null
        }
    }

    if ($Source -eq 'raw-main') {
        # The readme's one-liner, verbatim. The bootstrap's relaunch download uses the same URL.
        $script = 'Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex'
        $description = "raw main (the production one-liner) in $shellName"
    }
    else {
        $quotedPath = "'" + $InstallerPath.Replace("'", "''") + "'"
        $lines = @('Set-ExecutionPolicy Unrestricted -Scope Process -Force')
        if ($Shell -eq 'powershell') {
            $lines += (Get-CheckoutRelaunchShim -InstallerPath $InstallerPath)
        }
        $lines += "Get-Content -Raw -Encoding UTF8 -LiteralPath $quotedPath | iex"
        $script = $lines -join "`n"
        $description = "the checkout ($InstallerPath), piped to iex in $shellName"
    }

    # -EncodedCommand: no quoting rules to get wrong in either shell, and like -Command it runs
    # the text with no script file, so $PSCommandPath stays empty as under the real one-liner.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    return [pscustomobject]@{
        FilePath    = $Shell
        Arguments   = @('-NoProfile', '-EncodedCommand', $encoded)
        Description = $description
        Script      = $script
    }
}

<#
.SYNOPSIS
    Applies the e2e exit-code policy to one install pass.
.PARAMETER ExitCode
    The installer's exit code.
.PARAMETER KnownPlatformIncompatible
    The KNOWN_PLATFORM_INCOMPATIBLE value; empty means strict.
.PARAMETER Pass
    'first' or 'second'.
.RETURNS
    [pscustomobject] with StepExitCode, Outcome ('passed', 'tolerated' or 'failed') and Message.
#>
function Get-InstallPassVerdict {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$KnownPlatformIncompatible,
        [Parameter(Mandatory = $true)]
        [string]$Pass
    )

    $passName = $Pass.Substring(0, 1).ToUpperInvariant() + $Pass.Substring(1)
    if ($ExitCode -eq 0) {
        return [pscustomobject]@{ StepExitCode = 0; Outcome = 'passed'; Message = "$passName install pass exited 0." }
    }
    if ($ExitCode -eq 1 -and $KnownPlatformIncompatible.Trim()) {
        return [pscustomobject]@{
            StepExitCode = 0
            Outcome      = 'tolerated'
            Message      = "$passName install pass exited 1 (some apps failed) - tolerated pending the containment check against known platform-incompatible apps: $KnownPlatformIncompatible"
        }
    }
    return [pscustomobject]@{ StepExitCode = $ExitCode; Outcome = 'failed'; Message = "$passName install pass FAILED with exit code $ExitCode" }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (@('first', 'second') -notcontains $Pass -or @('pwsh', 'powershell') -notcontains $Shell -or @('OneLiner', 'File') -notcontains $Entry) {
        Write-Host "Invoke-InstallPass.ps1: give -Pass first|second, -Shell pwsh|powershell and -Entry OneLiner|File (got '$Pass', '$Shell', '$Entry')." -ForegroundColor Red
        exit 64
    }
    if (-not $InstallerPath) {
        $InstallerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winget-app-install.ps1'
    }
    $InstallerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallerPath)
    if ($null -eq $KnownPlatformIncompatible) {
        $KnownPlatformIncompatible = ''
    }

    $command = Get-InstallPassCommand -Shell $Shell -Entry $Entry -Source $Source -InstallerPath $InstallerPath
    Write-Host "Installer under test: $($command.Description) ($env:GITHUB_REF at $env:GITHUB_SHA)."
    if ($command.Script) {
        Write-Host 'The pass runs:'
        Write-Host $command.Script
    }

    # Native stderr must not stop this script: the step shells run with
    # $ErrorActionPreference = 'Stop', and Windows PowerShell turns redirected stderr into errors.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    & $command.FilePath @($command.Arguments)
    $installerExitCode = $global:LASTEXITCODE
    if ($null -eq $installerExitCode) {
        Write-Host "$($command.FilePath) could not be started." -ForegroundColor Red
        exit 127
    }

    $verdict = Get-InstallPassVerdict -ExitCode $installerExitCode -KnownPlatformIncompatible $KnownPlatformIncompatible -Pass $Pass
    $color = 'Green'
    if ($verdict.Outcome -eq 'tolerated') {
        $color = 'Yellow'
    }
    elseif ($verdict.Outcome -eq 'failed') {
        $color = 'Red'
    }
    Write-Host $verdict.Message -ForegroundColor $color
    # Explicit in every case: the step shell ends with 'exit $LASTEXITCODE', which would otherwise
    # fail a tolerated pass with the installer's code (observed on run 3).
    exit $verdict.StepExitCode
}
