<#
.SYNOPSIS
    Validates the app catalog entries before a run.
.DESCRIPTION
    Each entry must be a hashtable whose `name` has the package-id shape (publisher.product) and
    whose optional fields pass Get-AppDefinitionSchemaIssue. An entry with an error is left out and
    listed in Errors, which stops the run with exit code 3; duplicates are removed, and they and
    unknown fields are reported as warnings.
.PARAMETER Apps
    The app definitions to validate.
.OUTPUTS
    [pscustomobject] with ValidApps, Errors and Warnings.
#>
function Test-AppDefinitions {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Apps
    )

    $errors = @()
    $warnings = @()
    $validatedApps = @()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]
        if (-not ($app -is [hashtable])) {
            $errors += "App entry at index $i is not a hashtable."
            continue
        }

        if (-not $app.ContainsKey('name') -or -not ($app['name'] -is [string]) -or [string]::IsNullOrWhiteSpace($app['name'])) {
            $errors += "App entry at index $i is missing a valid 'name' value."
            continue
        }

        $name = $app['name'].Trim()

        # Package-id shape check (CLAUDE.md "Winget Notes"): reject any catalog entry whose name
        # does not look like a winget publisher.product id before it is ever trusted downstream.
        if (-not (Test-WingetPackageIdFormat -PackageId $name)) {
            $errors += "App entry at index $i has an invalid package id '$name': does not match the required publisher.product shape."
            continue
        }

        # The optional schema fields: a wrong value stops the run here, before
        # anything is installed, instead of misbehaving for this app halfway through it.
        $schemaIssues = Get-AppDefinitionSchemaIssue -App $app -Label "App entry at index $i ('$name')"
        $warnings += @($schemaIssues.Warnings)
        if (@($schemaIssues.Errors).Count -gt 0) {
            $errors += @($schemaIssues.Errors)
            continue
        }

        if (-not $seenNames.Add($name)) {
            $warnings += "Duplicate app definition detected for '$name'. Subsequent entry ignored."
            continue
        }

        $app['name'] = $name
        $validatedApps += $app
    }

    return [pscustomobject]@{
        ValidApps = $validatedApps
        Errors    = $errors
        Warnings  = $warnings
    }
}

