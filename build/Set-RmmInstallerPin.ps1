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
      3. refuses a file that does not define Invoke-WingetUserPhase: the user phase wrapper
         dot-sources the pinned file and calls it, so a file from a commit older than the user phase
         would fail at every sign-in of every user, without ever counting as an attempt;
      4. rewrites the two pin lines in both scripts, and nothing else; when either script does not
         have exactly one of each, it stops before writing anything.

    The commit has to be one GitHub serves: pushed, normally a commit on main that has passed the
    E2E run. A commit that is not on origin/main gets a warning. Commit the two scripts afterwards,
    and upload them to Endpoint Central's Script Repository again.

    With -Release instead of -Commit, the commit is the one a published release was built from, and
    three more checks run before anything is written. The GitHub CLI (gh), signed in, does the
    downloading and the attestation check:

      a. downloads the release's release-manifest.json (gh release download), which
         .github/workflows/release.yml publishes through J-MaFf/release-kit, and refuses one whose
         schema, repository or tag is not this release's;
      b. refuses the release when the tag here does not point at the commit the manifest names (a
         tag moved after the release, or not fetched: git fetch --tags);
      c. refuses the release when the installer's bytes at that commit do not have the manifest's
         SHA256 and size, or when gh attestation verify cannot prove that release-kit's workflow
         built those bytes in this repository.

    The pins are the same either way: the wrappers still download from the commit and check the
    SHA256, so a release changes how the pin is chosen, not how the wrappers trust it.
.PARAMETER Commit
    The commit (a hash, or a name git resolves, such as origin/main).
.PARAMETER Release
    A published release's tag, such as v1.1.0.
.PARAMETER Repository
    With -Release: the GitHub repository (owner/name) the release is in. Default J-MaFf/winget-app-setup.
.PARAMETER RepositoryRoot
    The repository. Default: the folder above this script.
.EXAMPLE
    pwsh -File build/Set-RmmInstallerPin.ps1 -Release v1.1.0
.EXAMPLE
    pwsh -File build/Set-RmmInstallerPin.ps1 -Commit origin/main
#>
[CmdletBinding(DefaultParameterSetName = 'Commit')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'Commit')]
    [string]$Commit,

    [Parameter(Mandatory = $true, ParameterSetName = 'Release')]
    [string]$Release,

    [Parameter(Mandatory = $false, ParameterSetName = 'Release')]
    [string]$Repository = 'J-MaFf/winget-app-setup',

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

<#
.SYNOPSIS
    Downloads a release's release-manifest.json with gh, checks that it is this release's, and
    returns it with the commit the release's tag points at here.
#>
function Get-ReleasePin {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$WorkDirectory
    )

    if ($Tag -notmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?\z') {
        throw "'$Tag' is not a release tag (vMAJOR.MINOR.PATCH)."
    }
    $download = & gh release download $Tag --repo $Repository --pattern 'release-manifest.json' --dir $WorkDirectory --clobber 2>&1
    $downloadExitCode = $LASTEXITCODE
    $manifestPath = Join-Path $WorkDirectory 'release-manifest.json'
    if ($downloadExitCode -ne 0 -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Could not download release-manifest.json from release $Tag of $Repository (gh exit code $downloadExitCode): $(($download | Out-String).Trim()) Is the release published by .github/workflows/release.yml, and is gh signed in (gh auth status)?"
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    # Schema 1 is the format release-kit's release.yml writes; a newer one may mean something else.
    if ($manifest.schema -ne 1) {
        throw "release-manifest.json of $Tag has schema '$($manifest.schema)'; this script reads schema 1. Update it."
    }
    if ($manifest.repository -ne $Repository -or $manifest.tag -cne $Tag) {
        throw "release-manifest.json of $Tag names repository '$($manifest.repository)' and tag '$($manifest.tag)', not $Repository and $Tag."
    }
    if ($manifest.commit -notmatch '^[0-9a-f]{40}\z') {
        throw "release-manifest.json of $Tag names commit '$($manifest.commit)', not a full commit id."
    }
    $installer = if ($manifest.files) { $manifest.files['winget-app-install.ps1'] }
    if (-not $installer -or $installer.path -ne 'winget-app-install.ps1' -or $installer.sha256 -notmatch '^[0-9a-f]{64}\z' -or $installer.size -isnot [long]) {
        throw "release-manifest.json of $Tag has no valid entry for winget-app-install.ps1."
    }

    try {
        $tagCommit = [System.Text.Encoding]::ASCII.GetString((Invoke-GitBytes -Repository $RepositoryRoot -ArgumentList @('rev-parse', '--verify', "refs/tags/$Tag^{commit}"))).Trim()
    }
    catch {
        throw "There is no tag $Tag here. Fetch it (git fetch --tags) and run this again."
    }
    if ($tagCommit -ne $manifest.commit) {
        throw "Tag $Tag points at $tagCommit here, but release $Tag was built from $($manifest.commit). Was the tag moved? Fetch the tags again (git fetch --tags --force) and check which one is right before pinning."
    }

    return [pscustomobject]@{
        Commit = $manifest.commit
        Sha256 = $installer.sha256
        Size   = [long]$installer.size
    }
}

$releasePin = $null
$workDirectory = $null
if ($PSCmdlet.ParameterSetName -eq 'Release') {
    if (-not (Get-Command -Name gh -ErrorAction SilentlyContinue)) {
        throw '-Release needs the GitHub CLI (gh), signed in: https://cli.github.com'
    }
    $workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('rmm-pin-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $workDirectory
    try {
        $releasePin = Get-ReleasePin -Tag $Release -Repository $Repository -RepositoryRoot $RepositoryRoot -WorkDirectory $workDirectory
    }
    catch {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    $Commit = $releasePin.Commit
}

$fullCommit = [System.Text.Encoding]::ASCII.GetString((Invoke-GitBytes -Repository $RepositoryRoot -ArgumentList @('rev-parse', '--verify', "$Commit^{commit}"))).Trim()
if ($fullCommit -notmatch '^[0-9a-f]{40}$') {
    throw "git rev-parse returned '$fullCommit' for '$Commit', not a full commit id."
}
$installerBytes = Invoke-GitBytes -Repository $RepositoryRoot -ArgumentList @('cat-file', 'blob', "${fullCommit}:winget-app-install.ps1")
# The user phase wrapper calls this function after it dot-sources the pinned file. Every build that
# has it also has the machine phase's SYSTEM mode, which came first.
if ([System.Text.Encoding]::UTF8.GetString($installerBytes) -notmatch '(?im)^\s*function\s+Invoke-WingetUserPhase\b') {
    throw "winget-app-install.ps1 at $fullCommit has no user phase (function Invoke-WingetUserPhase): it is from a commit older than the user phase, which rmm/Invoke-WingetAppSetupUserPhase.ps1 needs. Pin a newer commit."
}
$algorithm = [System.Security.Cryptography.SHA256]::Create()
try {
    $sha256 = [System.Convert]::ToHexString($algorithm.ComputeHash($installerBytes))
}
finally {
    $algorithm.Dispose()
}

if ($releasePin) {
    try {
        if ($sha256 -ne $releasePin.Sha256 -or $installerBytes.Length -ne $releasePin.Size) {
            throw "winget-app-install.ps1 at $fullCommit has SHA256 $sha256 and $($installerBytes.Length) bytes, but release $Release lists $($releasePin.Sha256.ToUpperInvariant()) and $($releasePin.Size) bytes. Do not pin it."
        }
        # The bytes git holds are the bytes attested: verify them, not a download of the asset.
        $attested = Join-Path $workDirectory 'winget-app-install.ps1'
        [System.IO.File]::WriteAllBytes($attested, $installerBytes)
        $verify = & gh attestation verify $attested --repo $Repository --signer-workflow 'J-MaFf/release-kit/.github/workflows/release.yml' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "gh attestation verify could not prove that J-MaFf/release-kit's release workflow built winget-app-install.ps1 at $fullCommit in $Repository (exit code $LASTEXITCODE): $(($verify | Out-String).Trim())"
        }
    }
    finally {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
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

$source = if ($releasePin) { "release $Release, commit $fullCommit, attested" } else { $fullCommit }
Write-Host "Pinned the RMM wrappers to winget-app-install.ps1 at $source (SHA256 $sha256)."
Write-Host 'Commit rmm/Invoke-WingetAppSetup.ps1 and rmm/Invoke-WingetAppSetupUserPhase.ps1, then upload both to the Script Repository again.'
