<#
.SYNOPSIS
    Saves a release's winget-app-install.ps1, for the assertions of an end-to-end run that tests
    that release.
.DESCRIPTION
    A run dispatched with installer_source release (#289) starts every pass with the release
    one-liner, so its transcripts must carry the release's build id, not the checkout's. This saves
    the installer of that release (the latest, or -Tag) where Assert-Install.ps1 -InstallerPath
    reads the build id from. It runs before the first pass, so a release without the installer
    (v1.0.0 has no assets) stops the job before anything is installed.

    The URL is the passes' own (Get-ReleaseInstallerUrl in e2e/TranscriptAssertions.ps1). GitHub
    serves the asset as application/octet-stream, so Invoke-WebRequest's Content is the file's
    bytes, saved as they are.

    Runs under Windows PowerShell 5.1 (the 5.1 leg) and PowerShell 7: ASCII only, no 7-only syntax.
.PARAMETER Tag
    The release tag (vX.Y.Z), or empty for the latest release. Default: $env:INSTALLER_RELEASE_TAG.
.PARAMETER OutputPath
    Where to save the file.
.NOTES
    Exit codes: 0 = saved; 1 = not downloaded, or not the installer; 64 = bad arguments.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Tag = $env:INSTALLER_RELEASE_TAG,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Test-ReleaseTag, Get-ReleaseInstallerUrl and Get-InstallerBuildIdFromScript.
. (Join-Path $PSScriptRoot 'TranscriptAssertions.ps1')

<#
.SYNOPSIS
    Downloads a release's installer and checks that it is the installer.
.PARAMETER Url
    The asset's URL.
.RETURNS
    [pscustomobject] with Bytes, BuildId and Error (why it is not usable, or $null).
#>
function Get-ReleaseInstallerDownload {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Bytes = $null; BuildId = $null; Error = "the download failed: $($_.Exception.Message)" }
    }
    if ($response.Content -is [string]) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($response.Content)
    }
    else {
        $bytes = [byte[]]$response.Content
    }
    $buildId = Get-InstallerBuildIdFromScript -Content ([System.Text.Encoding]::UTF8.GetString($bytes))
    if (-not $buildId) {
        return [pscustomobject]@{ Bytes = $null; BuildId = $null; Error = 'it is not the installer: it carries no installer build id' }
    }
    return [pscustomobject]@{ Bytes = $bytes; BuildId = $buildId; Error = $null }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $OutputPath -or ($Tag -and -not (Test-ReleaseTag -Tag $Tag))) {
        Write-Host "Save-ReleaseInstaller.ps1: give -OutputPath, and -Tag vMAJOR.MINOR.PATCH (optionally -prerelease) or no tag for the latest release (got tag '$Tag')." -ForegroundColor Red
        exit 64
    }
    # Windows PowerShell's progress bar slows Invoke-WebRequest down many times over.
    $ProgressPreference = 'SilentlyContinue'
    $releaseName = 'the latest release'
    if ($Tag) {
        $releaseName = "release $Tag"
    }
    $url = Get-ReleaseInstallerUrl -Tag $Tag
    $download = Get-ReleaseInstallerDownload -Url $url
    if ($download.Error) {
        Write-Host "Could not take winget-app-install.ps1 of $releaseName from ${url}: $($download.Error). Releases before v2.0.0 have no installer asset; dispatch with release_tag set to one that has." -ForegroundColor Red
        exit 1
    }
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $directory = Split-Path -Parent $OutputPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [System.IO.File]::WriteAllBytes($OutputPath, $download.Bytes)
    Write-Host "Saved winget-app-install.ps1 of $releaseName ($url), installer build $($download.BuildId), to $OutputPath."
    exit 0
}
