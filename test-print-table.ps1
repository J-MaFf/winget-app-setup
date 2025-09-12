# Define the Show-Table function for testing
function Show-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [string[][]]$Rows
    )

    $maxLengths = @{}
    foreach ($header in $Headers) {
        $maxLengths[$header] = $header.Length
    }

    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $row.Length; $i++) {
            if ($row[$i].Length -gt $maxLengths[$Headers[$i]]) {
                $maxLengths[$Headers[$i]] = $row[$i].Length
            }
        }
    }

    # Build table divider with proper column separators
    $divider = '+'
    foreach ($header in $Headers) {
        $columnWidth = $maxLengths[$header] + 2  # Add padding for spaces
        $divider += ('-' * $columnWidth) + '+'
    }

    # Build header line
    $headerLine = ''
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $padSize = $maxLengths[$Headers[$i]] - $Headers[$i].Length
        $headerLine += '|' + ' ' + $Headers[$i] + (' ' * $padSize) + ' '
    }
    $headerLine += '|'

    Write-Host $divider
    Write-Host $headerLine
    Write-Host $divider

    # Build each row
    foreach ($row in $Rows) {
        $rowLine = ''
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $cellValue = $row[$i]
            $padSize = $maxLengths[$Headers[$i]] - $cellValue.Length
            $rowLine += '|' + ' ' + $cellValue + (' ' * $padSize) + ' '
        }
        $rowLine += '|'

        Write-Host $rowLine
        Write-Host $divider
    }
}

# Define headers and rows for testing
$headers = @('Column1', 'Column2', 'Column3')
$rows = @(
    @('Row1Col1', 'Row1Col2', 'Row1Col3'),
    @('Row2Col1', 'Row2Col2', 'Row2Col3'),
    @('Row3Col1', 'Row3Col2', 'Row3Col3')
)

# Call the Show-Table function with the test data
Show-Table -Headers $headers -Rows $rows
