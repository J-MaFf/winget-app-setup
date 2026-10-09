<#
.SYNOPSIS
    Converts JSONC (JSON with comments) text to strict JSON, for Windows Terminal's settings.json.
.DESCRIPTION
    A character scanner that tracks JSON strings (with their backslash escapes), so comment
    markers and commas inside a string are never touched (a regex could not, issue #187). Outside
    strings it drops // comments up to the end of the line, drops /* */ comments (replaced by one
    space so tokens cannot fuse), and then, in a second pass, drops a comma whose next
    non-whitespace character is '}' or ']', so "1, /* c */ }" loses its comma too.
.PARAMETER JsonText
    JSONC text to sanitize.
.OUTPUTS
    [string] Strict JSON that ConvertFrom-Json on Windows PowerShell 5.1 accepts.
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

<#
.SYNOPSIS
    Parses Windows Terminal settings content, JSONC included.
.DESCRIPTION
    ConvertFrom-Json first (PowerShell 7 accepts JSONC); when that fails, as on Windows PowerShell
    5.1, the text is sanitized with Convert-JsoncToJson and parsed again.
.PARAMETER JsonText
    Raw settings content.
.OUTPUTS
    The parsed settings object, or $null.
#>
function ConvertFrom-TerminalSettingsJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return [pscustomobject]@{}
    }

    try {
        # ConvertFrom-Json -Depth is unavailable in Windows PowerShell 5.1.
        return $JsonText | ConvertFrom-Json
    }
    catch {
        # Windows Terminal settings are often JSONC; strip comments and trailing commas.
        $sanitizedJson = Convert-JsoncToJson -JsonText $JsonText

        try {
            # Keep parsing compatible with both Windows PowerShell and PowerShell 7+.
            return $sanitizedJson | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
}

<#
.SYNOPSIS
    Splits JSONC text into its JSON tokens, skipping whitespace and comments.
.DESCRIPTION
    Each token has its kind ('{', '}', '[', ']', ':', ',', 'String', or 'Literal' for
    true/false/null/numbers), its start and (exclusive) end in the original text, and its depth:
    the root object's braces are at 0 and its keys and values at 1. Strings keep their quotes and
    escapes; comments follow Convert-JsoncToJson's rules (an unterminated /* runs to the end).
    Positions let Set-JsoncTopLevelStringProperty edit one value and leave every other byte alone.
    Nothing is validated: invalid JSON still yields tokens.
.PARAMETER JsonText
    JSONC text to scan.
.OUTPUTS
    [pscustomobject[]] Tokens with Kind, Start, End and Depth, in text order.
#>
function Get-JsoncToken {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    $tokens = New-Object System.Collections.Generic.List[object]
    $length = $JsonText.Length
    $depth = 0
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ([char]::IsWhiteSpace($currentChar)) {
            $i++
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length -and $JsonText[$i + 1] -eq '/') {
            $i += 2
            while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                $i++
            }
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length -and $JsonText[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $length -and -not ($JsonText[$i] -eq '*' -and $JsonText[$i + 1] -eq '/')) {
                $i++
            }
            $i = [System.Math]::Min($i + 2, $length)
            continue
        }

        $start = $i
        $tokenDepth = $depth
        if ($currentChar -eq '"') {
            $kind = 'String'
            $i++
            while ($i -lt $length -and $JsonText[$i] -ne '"') {
                if ($JsonText[$i] -eq '\') {
                    $i++
                }
                $i++
            }
            $i = [System.Math]::Min($i + 1, $length)
        }
        elseif ('{['.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $depth++
            $i++
        }
        elseif ('}]'.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $depth--
            $tokenDepth = $depth
            $i++
        }
        elseif (':,'.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $i++
        }
        else {
            $kind = 'Literal'
            while ($i -lt $length -and -not [char]::IsWhiteSpace($JsonText[$i]) -and '{}[]:,"/'.IndexOf($JsonText[$i]) -lt 0) {
                $i++
            }
            if ($i -eq $start) {
                # A lone '/' that does not start a comment: take it as a one-character token.
                $i++
            }
        }

        $tokens.Add([pscustomobject]@{ Kind = $kind; Start = $start; End = $i; Depth = $tokenDepth })
    }

    return , $tokens.ToArray()
}

<#
.SYNOPSIS
    Sets one top-level string property in JSONC text by editing only that value.
.DESCRIPTION
    settings.json is hand-maintained JSONC, and writing it back with ConvertTo-Json would drop its
    comments, indentation and key order. Instead:
      - an existing top-level property gets its value replaced (every top-level occurrence, so a
        duplicated key cannot keep an old value);
      - otherwise "Name": "Value", goes before the root object's first key, on its own line with
        that key's indentation (inline when that key shares its line), or inside an empty root;
      - text with no tokens (empty, whitespace or comments only) gets a new root object with just
        the property, appended.
    Everything else stays as it was. Keys match case-sensitively, as Windows Terminal reads them,
    and only at the top level. The caller validates the result by parsing it.
.PARAMETER JsonText
    JSONC text whose root is an object.
.PARAMETER Name
    Top-level property name, matched case-sensitively.
.PARAMETER Value
    New string value. Backslashes and double quotes are escaped.
.OUTPUTS
    [string] The edited text, or $null when the root is not an object or the property's current
    value is an object or an array (nothing is edited then).
#>
function Set-JsoncTopLevelStringProperty {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $quotedValue = '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
    $member = '"' + $Name + '": ' + $quotedValue
    $newLine = if ($JsonText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $tokens = Get-JsoncToken -JsonText $JsonText

    if ($tokens.Count -eq 0) {
        $separator = if ($JsonText.Length -gt 0 -and $JsonText[$JsonText.Length - 1] -ne "`n") { $newLine } else { '' }
        return $JsonText + $separator + '{' + $newLine + '    ' + $member + $newLine + '}' + $newLine
    }

    if ($tokens[0].Kind -ne '{') {
        return $null
    }

    $firstKey = $null
    $valueTokens = @()
    for ($t = 1; $t -lt $tokens.Count; $t++) {
        $token = $tokens[$t]
        if ($token.Depth -eq 0) {
            # The root object's closing brace.
            break
        }
        $isTopLevelKey = $token.Depth -eq 1 -and $token.Kind -eq 'String' -and
            $t + 1 -lt $tokens.Count -and $tokens[$t + 1].Kind -eq ':'
        if (-not $isTopLevelKey) {
            continue
        }
        if ($null -eq $firstKey) {
            $firstKey = $token
        }
        if ($JsonText.Substring($token.Start + 1, $token.End - $token.Start - 2) -cne $Name) {
            continue
        }
        if ($t + 2 -ge $tokens.Count -or ($tokens[$t + 2].Kind -ne 'String' -and $tokens[$t + 2].Kind -ne 'Literal')) {
            return $null
        }
        $valueTokens += $tokens[$t + 2]
    }

    if ($valueTokens.Count -gt 0) {
        $builder = [System.Text.StringBuilder]::new($JsonText)
        # Back to front, so the earlier positions stay valid.
        for ($v = $valueTokens.Count - 1; $v -ge 0; $v--) {
            [void]$builder.Remove($valueTokens[$v].Start, $valueTokens[$v].End - $valueTokens[$v].Start)
            [void]$builder.Insert($valueTokens[$v].Start, $quotedValue)
        }
        return $builder.ToString()
    }

    if ($null -eq $firstKey) {
        return $JsonText.Insert($tokens[0].End, ' ' + $member + ' ')
    }

    # [char] overload: the string overload of LastIndexOf is culture-sensitive, and on .NET's ICU
    # globalization it does not find "`n" right after "`r".
    $lineStart = $JsonText.LastIndexOf([char]10, $firstKey.Start - 1) + 1
    $indent = $JsonText.Substring($lineStart, $firstKey.Start - $lineStart)
    $insertion = if ([string]::IsNullOrWhiteSpace($indent)) {
        $member + ',' + $newLine + $indent
    }
    else {
        $member + ', '
    }
    return $JsonText.Insert($firstKey.Start, $insertion)
}
