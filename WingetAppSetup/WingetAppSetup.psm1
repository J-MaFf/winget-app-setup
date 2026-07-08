# WingetAppSetup.psm1
# Root module loader. Dot-sources every function file under Private/ and Public/, then exports
# exactly the manifest's FunctionsToExport list. The psd1 is the SINGLE export authority
# (issue #191): this file used to AST-derive its own export list from Public/*.ps1, which made a
# second authority — a new Public function passed the psm1's export but was silently filtered on
# manifest imports (how winget-app-uninstall.ps1 loads the module) until the psd1 was updated.
# Reading the manifest here keeps direct-psm1 imports and manifest imports identical, and
# build/Build-WingetInstallScript.ps1 asserts (in both build and -Check modes) that the psd1 list
# exactly matches the functions defined under Public/, so drift fails the build instead.

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in ($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load function file '$($file.FullName)': $_"
    }
}

$manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'WingetAppSetup.psd1')
Export-ModuleMember -Function $manifest.FunctionsToExport
