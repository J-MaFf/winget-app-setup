<#
.SYNOPSIS
    Writes an informational message in blue color.
.DESCRIPTION
    Helper function for consistent informational and action messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Info {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Writes a success message in green color.
.DESCRIPTION
    Helper function for consistent success messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Success {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Green
}

<#
.SYNOPSIS
    Writes a warning message in yellow color.
.DESCRIPTION
    Helper function for consistent warning and skip messages throughout the script.
    Named Write-WarningMessage to avoid conflict with built-in Write-Warning cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-WarningMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Yellow
}

<#
.SYNOPSIS
    Writes an error message in red color.
.DESCRIPTION
    Helper function for consistent error messages throughout the script.
    Named Write-ErrorMessage to avoid conflict with built-in Write-Error cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Red
}

<#
.SYNOPSIS
    Formats an array of app names for display in the summary table.
.DESCRIPTION
    This function checks if an array has content and formats it as a comma-separated string.
.PARAMETER AppArray
    The array of app names to format
.RETURNS
    A formatted string of app names, or $null if the array is empty
#>
function Format-AppList {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$AppArray
    )

    if ($AppArray -and $AppArray.Count -gt 0) {
        return $AppArray -join ', '
    }
    return $null
}

<#
.SYNOPSIS
    Displays a formatted table of results, and optionally also in an interactive GUI view.
.DESCRIPTION
    Always renders the summary as text via PowerShell's built-in Format-Table, then additionally
    opens Out-GridView when a caller asked for it and the session can show one.

    The grid view is never offered as a question (issue #230): it used to be a Read-Host that
    stalled the documented one-liner, so -AutoGridView now just opens it. Text output is
    unconditional for the same reason — the grid view renders in its own window and is never
    captured by Start-Transcript, so returning early once it opened would drop the summary from
    the log of every interactive run.
.PARAMETER Headers
    Array of column header names
.PARAMETER Rows
    Array of row data (each row is an array matching the header count)
.PARAMETER UseGridView
    Caller explicitly wants the grid view. Warns when Out-GridView is unavailable.
.PARAMETER AutoGridView
    Open the grid view whenever the session can show one, silently doing nothing when it cannot.
    Callers pass the session's effective interactivity here, so an unattended run never opens a
    window that nothing is around to close. (Formerly -PromptForGridView, which asked first.)
#>
function Write-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[][]]$Rows,
        [Parameter(Mandatory = $false)]
        [bool]$UseGridView = $false,
        [Parameter(Mandatory = $false)]
        [bool]$AutoGridView = $false,
        [Parameter(Mandatory = $false)]
        [string]$Title = 'Summary'
    )

    # Convert rows to objects for Format-Table
    $tableData = @()
    foreach ($row in $Rows) {
        $obj = New-Object PSObject
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $obj | Add-Member -MemberType NoteProperty -Name $Headers[$i] -Value $row[$i]
        }
        $tableData += $obj
    }

    # Text output first, unconditionally: Out-GridView is a window, not console output, so it is
    # never transcribed (issue #230).
    $output = $tableData | Format-Table -AutoSize | Out-String
    Write-Host $output.TrimEnd()

    if (-not ($UseGridView -or $AutoGridView)) {
        return
    }

    if (-not (Test-CanUseGridView)) {
        # Only an explicit -UseGridView deserves a warning. -AutoGridView is an offer, not a
        # request: on a session that cannot show a window, having no window is the right outcome
        # and not worth a line of noise.
        if ($UseGridView) {
            Write-WarningMessage 'Out-GridView is not available. The results are in the text summary above.'
        }
        return
    }

    try {
        $tableData | Out-GridView -Title $Title -Wait
    }
    catch {
        Write-WarningMessage "Failed to display grid view: $_. The results are in the text summary above."
    }
}

