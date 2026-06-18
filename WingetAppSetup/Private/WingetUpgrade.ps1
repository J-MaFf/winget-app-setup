<#
.SYNOPSIS
    Upgrades a single winget package with a hard timeout so a stalled upgrade cannot hang the run.
.DESCRIPTION
    Runs `winget upgrade` for one package id as a child process and waits up to TimeoutSeconds for it
    to exit. If the process does not finish in time it is killed and reported as timed out, so the
    caller can move on to the next package instead of blocking indefinitely (issue #120). This mirrors
    the Start-Process/WaitForExit/Kill timeout pattern already used by Set-Sources.
.PARAMETER PackageId
    The exact winget package identifier to upgrade (for example, 'Warp.Warp').
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the upgrade before terminating it. Defaults to 300 (5 minutes).
.RETURNS
    [PSCustomObject] with Id, Status ('Ok' | 'NoUpgrade' | 'Failed' | 'TimedOut'), and ExitCode.
#>
function Invoke-WingetPackageUpgrade {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300
    )

    $token = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "winget_upgrade_out_$token.txt"
    $errFile = Join-Path $env:TEMP "winget_upgrade_err_$token.txt"

    try {
        $upgradeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'upgrade', '--id', $PackageId, '--exact', '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        if (-not $upgradeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Write-WarningMessage "Update for $PackageId timed out after $TimeoutSeconds seconds. Terminating..."
            try { $upgradeProcess.Kill() } catch { }
            return [PSCustomObject]@{ Id = $PackageId; Status = 'TimedOut'; ExitCode = $null }
        }

        $exitCode = $upgradeProcess.ExitCode
        $output = (Get-Content -Path $outFile -ErrorAction SilentlyContinue) -join "`n"

        if ($output -match 'No available upgrade found' -or $output -match 'No newer package versions are available') {
            return [PSCustomObject]@{ Id = $PackageId; Status = 'NoUpgrade'; ExitCode = $exitCode }
        }

        if ($exitCode -eq 0 -or $output -match 'Successfully installed') {
            return [PSCustomObject]@{ Id = $PackageId; Status = 'Ok'; ExitCode = $exitCode }
        }

        return [PSCustomObject]@{ Id = $PackageId; Status = 'Failed'; ExitCode = $exitCode }
    }
    catch {
        Write-ErrorMessage "Error updating ${PackageId}: $_"
        return [PSCustomObject]@{ Id = $PackageId; Status = 'Failed'; ExitCode = $null }
    }
    finally {
        Remove-Item -Path $outFile, $errFile -ErrorAction SilentlyContinue
    }
}
