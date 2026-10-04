<#
.SYNOPSIS
    Pins the RMM wrappers to the winget-app-install.ps1 of one commit.
.DESCRIPTION
    rmm/Invoke-WingetAppSetup.ps1 and rmm/Invoke-WingetAppSetupUserPhase.ps1 download
    https://raw.githubusercontent.com/J-MaFf/winget-app-setup/<PinnedInstallerCommit>/winget-app-install.ps1
    and run it only when its SHA256 is PinnedInstallerSha256. This sets both pins, in both scripts,
    from a commit:

      1. resolves the commit to its full 40-character id (git rev-parse);
      2. reads winget-app-install.ps1 from that commit as raw bytes (git cat-file), which are the
         bytes raw.githubusercontent.com serves (the repository keeps .ps1 files LF, see
         .gitattributes), and hashes them. A file read back through a shell redirect would not do:
         Windows PowerShell 5.1 writes a redirect as UTF-16;
      3. rewrites the two pin lines in both scripts, and nothing else; when either script does not
         have exactly one of each, it stops before writing anything.

    The commit has to be one GitHub serves: pushed, normally a commit on main that has passed the
    E2E run. A commit that is not on origin/main gets a warning. Commit the two scripts afterwards,
    and upload them to Endpoint Central's Script Repository again.
.PARAMETER Commit
    The commit (a hash, or a name git resolves, such as origin/main).
.PARAMETER RepositoryRoot
    The repository. Default: the folder above this script.
.EXAMPLE
    pwsh -File build/Set-RmmInstallerPin.ps1 -Commit origin/main
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Commit,

    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Runs git and returns its standard output as bytes, exactly as git wrote them.
#>
function Invoke-GitBytes {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($Repository)
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $buffer = [System.IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($buffer)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw ('git {0} failed (exit code {1}): {2}' -f ($ArgumentList -join ' '), $process.ExitCode, $stderrTask.Result.Trim())
    }
    return , $buffer.ToArray()
}

<#
.SYNOPSIS
    Replaces the value of one "$Name = '...'" line at the start of a line, and fails unless there is
    exactly one.
#>
function Set-PinLine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $pattern = '(?m)^\$' + [regex]::Escape($Name) + " = '[^'\r\n]*'"
    $count = [regex]::Matches($Text, $pattern).Count
    if ($count -ne 1) {
        throw "$FileName has $count lines that set `$$Name; expected exactly one."
    }
    # An evaluator, not a replacement string, in which '$' would be special.
    $line = '${0} = ''{1}''' -f $Name, $Value
    return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param ($match) $line })
}

$fullCommit = [System.Text.Encoding]::ASCII.GetString((Invoke-GitBytes -Repository $RepositoryRoot -ArgumentList @('rev-parse', '--verify', "$Commit^{commit}"))).Trim()
if ($fullCommit -notmatch '^[0-9a-f]{40}$') {
    throw "git rev-parse returned '$fullCommit' for '$Commit', not a full commit id."
}
$installerBytes = Invoke-GitBytes -Repository $RepositoryRoot -ArgumentList @('cat-file', 'blob', "${fullCommit}:winget-app-install.ps1")
$algorithm = [System.Security.Cryptography.SHA256]::Create()
try {
    $sha256 = [System.Convert]::ToHexString($algorithm.ComputeHash($installerBytes))
}
finally {
    $algorithm.Dispose()
}

& git -C $RepositoryRoot merge-base --is-ancestor $fullCommit origin/main 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "$fullCommit is not on origin/main here (or origin/main is not fetched). Pin a commit GitHub serves: one that is pushed, normally on main and through the E2E run."
}

# Both scripts are edited in memory first, so a script without its pin lines stops this before
# either is written: the two must never pin different installers.
$updates = [ordered]@{}
foreach ($relativePath in @('rmm/Invoke-WingetAppSetup.ps1', 'rmm/Invoke-WingetAppSetupUserPhase.ps1')) {
    $path = Join-Path $RepositoryRoot $relativePath
    $text = [System.IO.File]::ReadAllText($path)
    $updated = Set-PinLine -Text $text -Name 'PinnedInstallerCommit' -Value $fullCommit -FileName $relativePath
    $updates[$path] = Set-PinLine -Text $updated -Name 'PinnedInstallerSha256' -Value $sha256 -FileName $relativePath
}
foreach ($path in $updates.Keys) {
    [System.IO.File]::WriteAllText($path, $updates[$path], [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Pinned the RMM wrappers to winget-app-install.ps1 at $fullCommit (SHA256 $sha256)."
Write-Host 'Commit rmm/Invoke-WingetAppSetup.ps1 and rmm/Invoke-WingetAppSetupUserPhase.ps1, then upload both to the Script Repository again.'
