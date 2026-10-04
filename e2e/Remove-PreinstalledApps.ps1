<#
.SYNOPSIS
    Uninstalls the catalog apps a GitHub-hosted runner image ships with, so the e2e install
    passes really install them.
.DESCRIPTION
    Review finding P3-40: windows-latest already has Google Chrome, 7-Zip and Git, so every first
    pass logged 'Skipping: <id> (already installed)' for them and their install paths never ran.
    .github/workflows/e2e-install.yml runs this before the first pass in both legs. With
    -IncludePowerShell7 (the Windows PowerShell 5.1 leg) it also removes PowerShell 7, so the
    first pass starts from what a fresh box has and the bootstrap has to install it.

    Tolerant: an app that is not installed is fine, and an app that cannot be removed is reported
    as a GitHub warning annotation and left in place (the pass then skips it, as before), so
    runner preparation never fails the run on its own. Every winget and msiexec call is bounded.

    The catalog apps are checked the way the installer checks them, with
    'winget list --id <id> --exact': absent there means the first pass installs it. PowerShell 7 is
    checked by its pwsh.exe, which is what the bootstrap looks for; the image installs it from the
    MSI, so its Windows Installer entry is removed first and winget is the fallback.

    Runs under Windows PowerShell 5.1 (the steps use 'shell: powershell', which does not depend on
    PowerShell 7): ASCII only, no 7-only syntax.
.PARAMETER PackageId
    winget ids to remove. Default: Google.Chrome, 7zip.7zip, Git.Git.
.PARAMETER IncludePowerShell7
    Also remove PowerShell 7.
.PARAMETER ListTimeoutSeconds
    Limit for each 'winget list'. Default 90.
.PARAMETER UninstallTimeoutSeconds
    Limit for each uninstall. Default 240.
.NOTES
    Exit codes: 0 = done (warnings for anything left installed), 1 = unexpected error.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string[]]$PackageId = @('Google.Chrome', '7zip.7zip', 'Git.Git'),

    [Parameter(Mandatory = $false)]
    [switch]$IncludePowerShell7,

    [Parameter(Mandatory = $false)]
    [int]$ListTimeoutSeconds = 90,

    [Parameter(Mandatory = $false)]
    [int]$UninstallTimeoutSeconds = 240
)

<#
.SYNOPSIS
    Runs a process with its output captured and a time limit.
.RETURNS
    [pscustomobject] with ExitCode ([int], or $null when it did not start or timed out),
    TimedOut, Output (stdout and stderr text) and Error (why it did not start).
#>
function Invoke-BoundedProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $result = [pscustomobject]@{ ExitCode = $null; TimedOut = $false; Output = ''; Error = $null }
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        # Windows PowerShell only fills ExitCode for a -PassThru process whose handle was read.
        $null = $process.Handle
        if ($process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
        }
        else {
            $result.TimedOut = $true
            try {
                $process.Kill()
            }
            catch {
                # Already gone.
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        $text = @()
        foreach ($path in @($stdoutPath, $stderrPath)) {
            try {
                $text += [System.IO.File]::ReadAllText($path)
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
            catch {
                # Still held by a killed process; the text is only for the log.
            }
        }
        $result.Output = ($text -join "`n").Trim()
    }
    return $result
}

# How a failed or timed-out process call reads in the log.
function Format-ProcessOutcome {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Outcome,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($Outcome.Error) {
        return "could not start: $($Outcome.Error)"
    }
    if ($Outcome.TimedOut) {
        return "timed out after $TimeoutSeconds s"
    }
    return ('exit 0x{0:X8}' -f [int]$Outcome.ExitCode)
}

<#
.SYNOPSIS
    Asks winget whether a package is installed, the way the installer does.
.RETURNS
    [pscustomobject] with State ('present', 'absent' or 'unknown') and Detail.
#>
function Get-WingetPackagePresence {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $outcome = Invoke-BoundedProcess -FilePath 'winget' -ArgumentList @('list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $TimeoutSeconds
    if ($outcome.ExitCode -eq 0) {
        return [pscustomobject]@{ State = 'present'; Detail = 'winget list found it' }
    }
    # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND (0x8A150014): no such package installed.
    if ($outcome.ExitCode -eq -1978335212) {
        return [pscustomobject]@{ State = 'absent'; Detail = 'winget list does not find it' }
    }
    return [pscustomobject]@{ State = 'unknown'; Detail = "winget list $(Format-ProcessOutcome -Outcome $outcome -TimeoutSeconds $TimeoutSeconds)" }
}

<#
.SYNOPSIS
    Uninstalls one catalog app with winget, if it is installed.
.RETURNS
    [pscustomobject] with App, Result ('absent', 'removed', 'still present' or 'unknown') and
    Detail.
#>
function Remove-PreinstalledPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [int]$ListTimeoutSeconds,
        [Parameter(Mandatory = $true)]
        [int]$UninstallTimeoutSeconds
    )

    $before = Get-WingetPackagePresence -Id $Id -TimeoutSeconds $ListTimeoutSeconds
    if ($before.State -eq 'absent') {
        return [pscustomobject]@{ App = $Id; Result = 'absent'; Detail = 'not installed on this runner' }
    }

    $uninstall = Invoke-BoundedProcess -FilePath 'winget' -ArgumentList @('uninstall', '--id', $Id, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $UninstallTimeoutSeconds
    $uninstallText = 'winget uninstall ' + (Format-ProcessOutcome -Outcome $uninstall -TimeoutSeconds $UninstallTimeoutSeconds)
    $after = Get-WingetPackagePresence -Id $Id -TimeoutSeconds $ListTimeoutSeconds
    switch ($after.State) {
        'absent' { return [pscustomobject]@{ App = $Id; Result = 'removed'; Detail = $uninstallText } }
        'present' { return [pscustomobject]@{ App = $Id; Result = 'still present'; Detail = "$uninstallText; $($after.Detail)" } }
        default { return [pscustomobject]@{ App = $Id; Result = 'unknown'; Detail = "$uninstallText; then $($after.Detail)" } }
    }
}

# The PowerShell 7 executables the bootstrap's Find-PowerShell7 would find in Program Files.
function Get-PowerShell7ExecutablePath {
    $paths = @()
    foreach ($root in @($env:ProgramFiles, $env:ProgramW6432)) {
        if ($root) {
            $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
            if ($paths -notcontains $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $paths += $candidate
            }
        }
    }
    return $paths
}

# Windows Installer entries of PowerShell 7 (the image installs the MSI): their product codes.
function Get-PowerShell7MsiProductCode {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $codes = @()
    foreach ($entry in (Get-ChildItem -Path $keys -ErrorAction SilentlyContinue)) {
        $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
        if ($properties -and $properties.DisplayName -like 'PowerShell 7*' -and $properties.WindowsInstaller -eq 1 -and $entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            $codes += $entry.PSChildName
        }
    }
    return @($codes | Sort-Object -Unique)
}

<#
.SYNOPSIS
    Removes PowerShell 7 from Program Files: its MSI first, winget as the fallback.
.RETURNS
    [pscustomobject] with App ('Microsoft.PowerShell'), Result and Detail, as
    Remove-PreinstalledPackage.
#>
function Remove-PowerShell7 {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ListTimeoutSeconds,
        [Parameter(Mandatory = $true)]
        [int]$UninstallTimeoutSeconds
    )

    if (@(Get-PowerShell7ExecutablePath).Count -eq 0) {
        return [pscustomobject]@{ App = 'Microsoft.PowerShell'; Result = 'absent'; Detail = 'no pwsh.exe under Program Files' }
    }

    $steps = @()
    foreach ($productCode in (Get-PowerShell7MsiProductCode)) {
        $msi = Invoke-BoundedProcess -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart') -TimeoutSeconds $UninstallTimeoutSeconds
        $steps += "msiexec /x $productCode $(Format-ProcessOutcome -Outcome $msi -TimeoutSeconds $UninstallTimeoutSeconds)"
    }
    if (@(Get-PowerShell7ExecutablePath).Count -gt 0) {
        $winget = Remove-PreinstalledPackage -Id 'Microsoft.PowerShell' -ListTimeoutSeconds $ListTimeoutSeconds -UninstallTimeoutSeconds $UninstallTimeoutSeconds
        $steps += "winget: $($winget.Result) ($($winget.Detail))"
    }
    if ($steps.Count -eq 0) {
        $steps += 'nothing to run'
    }

    $left = @(Get-PowerShell7ExecutablePath)
    if ($left.Count -eq 0) {
        return [pscustomobject]@{ App = 'Microsoft.PowerShell'; Result = 'removed'; Detail = ($steps -join '; ') }
    }
    return [pscustomobject]@{ App = 'Microsoft.PowerShell'; Result = 'still present'; Detail = (($steps + "still there: $($left -join ', ')") -join '; ') }
}

<#
.SYNOPSIS
    Removes the preinstalled apps and prints what happened, one line per app.
.DESCRIPTION
    An app left installed (or whose state winget could not tell) gets a GitHub warning
    annotation: the run carries on, and the first pass will skip that app.
.RETURNS
    The per-app results (see Remove-PreinstalledPackage).
#>
function Invoke-RunnerPreparation {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PackageId,
        [Parameter(Mandatory = $false)]
        [switch]$IncludePowerShell7,
        [Parameter(Mandatory = $true)]
        [int]$ListTimeoutSeconds,
        [Parameter(Mandatory = $true)]
        [int]$UninstallTimeoutSeconds
    )

    $results = @()
    foreach ($id in $PackageId) {
        Write-Host "Removing $id..."
        $results += Remove-PreinstalledPackage -Id $id -ListTimeoutSeconds $ListTimeoutSeconds -UninstallTimeoutSeconds $UninstallTimeoutSeconds
    }
    if ($IncludePowerShell7) {
        Write-Host 'Removing PowerShell 7...'
        $results += Remove-PowerShell7 -ListTimeoutSeconds $ListTimeoutSeconds -UninstallTimeoutSeconds $UninstallTimeoutSeconds
    }

    Write-Host ''
    Write-Host '=== Runner preparation: preinstalled apps ==='
    foreach ($result in $results) {
        Write-Host ('{0,-22} {1,-14} {2}' -f $result.App, $result.Result, $result.Detail)
        if ($result.Result -eq 'still present' -or $result.Result -eq 'unknown') {
            # One line, no '%': an annotation ends at the newline, and '%' is its escape character.
            $message = ('{0} could not be removed ({1}): {2}. The first install pass will skip it as already installed.' -f $result.App, $result.Result, $result.Detail) -replace '[\r\n%]', ' '
            Write-Host "::warning title=E2E runner preparation::$message"
        }
    }
    return $results
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Continue'
    try {
        $null = Invoke-RunnerPreparation -PackageId $PackageId -IncludePowerShell7:$IncludePowerShell7 -ListTimeoutSeconds $ListTimeoutSeconds -UninstallTimeoutSeconds $UninstallTimeoutSeconds
        exit 0
    }
    catch {
        Write-Host "::warning title=E2E runner preparation::Unexpected error: $(($_.Exception.Message) -replace '[\r\n%]', ' ')"
        exit 1
    }
}
