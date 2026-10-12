# WingetAppSetup.psm1
# Root module loader. Dot-sources every function file under Private/ and Public/ and exports every
# function they define; the manifest's FunctionsToExport is '*' too (review finding P3-44). Public/
# holds the run's entry points and main steps, Private/ their helpers: a split for readers, not an
# access boundary, just as in the generated single-file installer, which dot-sources them all.

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

Export-ModuleMember -Function '*'
