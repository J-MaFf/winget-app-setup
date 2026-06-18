# WingetAppSetup.psm1
# Root module loader. Dot-sources every function file under Private/ and Public/,
# then exports only the Public functions. Private functions remain available to
# other module functions but are not surfaced to importers.

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

# Export the names of every function defined in a Public/*.ps1 file.
$publicFunctionNames = foreach ($file in $public) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $false
    ) | ForEach-Object { $_.Name }
}

Export-ModuleMember -Function $publicFunctionNames
