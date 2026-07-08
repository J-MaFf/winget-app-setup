<#
.SYNOPSIS
    Converts JSONC (JSON with comments) text to strict JSON.
.DESCRIPTION
    Character-scanner sanitizer for Windows Terminal settings files, which commonly carry
    // line comments (including trailing inline ones), /* */ block comments (possibly
    spanning lines), and trailing commas. The previous regex approach (issue #187) missed
    trailing inline comments and could corrupt string values containing comment-like
    sequences such as "/*" or "//" — and because Set-WindowsTerminalDefaultProfile writes
    the parsed object back to settings.json, a corrupted parse would persist the damage.

    The scanner tracks JSON string state (honoring backslash escapes like \" and \\), so
    comment markers and commas inside string values are never touched. Outside strings it:
      - drops // comments up to (not including) the end-of-line, and
      - drops /* */ comments, spanning lines, replaced with a single space so adjacent
        tokens cannot fuse, and
      - drops a trailing comma whose next non-whitespace character is '}' or ']'
        (whitespace between comma and closer is preserved).

    Comment stripping and trailing-comma removal run as two passes so a comma separated
    from its closing brace only by a comment ("1, /* c */ }") is still removed.
.PARAMETER JsonText
    JSONC text to sanitize.
.RETURNS
    [string] Strict-JSON text suitable for ConvertFrom-Json on Windows PowerShell 5.1.
#>
function Convert-JsoncToJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    # Pass 1: strip // and /* */ comments, string-aware.
    $length = $JsonText.Length
    $withoutComments = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ($inString) {
            [void]$withoutComments.Append($currentChar)
            if ($currentChar -eq '\') {
                # Copy the escaped character verbatim so \" does not end the string.
                if ($i + 1 -lt $length) {
                    [void]$withoutComments.Append($JsonText[$i + 1])
                    $i += 2
                    continue
                }
            }
            elseif ($currentChar -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($currentChar -eq '"') {
            $inString = $true
            [void]$withoutComments.Append($currentChar)
            $i++
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length) {
            $nextChar = $JsonText[$i + 1]
            if ($nextChar -eq '/') {
                # Line comment: skip to end of line, keeping the line break itself.
                $i += 2
                while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                    $i++
                }
                continue
            }
            if ($nextChar -eq '*') {
                # Block comment: skip past the closing */ (an unterminated comment
                # swallows the rest of the text, matching JSONC tokenizer behavior).
                $i += 2
                while ($i + 1 -lt $length -and -not ($JsonText[$i] -eq '*' -and $JsonText[$i + 1] -eq '/')) {
                    $i++
                }
                $i = [System.Math]::Min($i + 2, $length)
                [void]$withoutComments.Append(' ')
                continue
            }
        }

        [void]$withoutComments.Append($currentChar)
        $i++
    }

    # Pass 2: drop trailing commas (a ',' whose next non-whitespace char is '}' or ']'),
    # string-aware for values like "a, ]" that must survive untouched.
    $commentFreeText = $withoutComments.ToString()
    $length = $commentFreeText.Length
    $sanitized = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $commentFreeText[$i]

        if ($inString) {
            [void]$sanitized.Append($currentChar)
            if ($currentChar -eq '\') {
                if ($i + 1 -lt $length) {
                    [void]$sanitized.Append($commentFreeText[$i + 1])
                    $i += 2
                    continue
                }
            }
            elseif ($currentChar -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($currentChar -eq '"') {
            $inString = $true
            [void]$sanitized.Append($currentChar)
            $i++
            continue
        }

        if ($currentChar -eq ',') {
            $lookahead = $i + 1
            while ($lookahead -lt $length -and [char]::IsWhiteSpace($commentFreeText[$lookahead])) {
                $lookahead++
            }
            if ($lookahead -lt $length -and ($commentFreeText[$lookahead] -eq '}' -or $commentFreeText[$lookahead] -eq ']')) {
                # Trailing comma: drop it; the whitespace and closer are appended normally.
                $i++
                continue
            }
        }

        [void]$sanitized.Append($currentChar)
        $i++
    }

    return $sanitized.ToString()
}
