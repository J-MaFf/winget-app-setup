<#
.SYNOPSIS
    Resolves all discovered Windows Terminal settings file paths.
.DESCRIPTION
    Includes packaged channels (stable/preview/dev/canary-style package names)
    and unpackaged path when present.
.RETURNS
    [string[]] Existing settings paths when found; otherwise an empty array.
#>
function Get-WindowsTerminalSettingsPaths {
    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )

    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -Path $packagesRoot) {
        try {
            $dynamicPaths = Get-ChildItem -Path $packagesRoot -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }

            if ($dynamicPaths) {
                $candidatePaths += $dynamicPaths
            }
        }
        catch {
            # Best-effort discovery only; keep static candidates if enumeration fails.
        }
    }

    $existingPaths = @()

    foreach ($path in $candidatePaths) {
        if (Test-Path -Path $path) {
            $existingPaths += $path
        }
    }

    return @($existingPaths | Select-Object -Unique)
}

<#
.SYNOPSIS
    Sets Windows Terminal default profile to a provided GUID.
.DESCRIPTION
    Changes only the value of the top-level "defaultProfile" in settings.json, or inserts that
    key when it is missing (Set-JsoncTopLevelStringProperty). Comments, commented-out profiles,
    formatting and key order are kept: the file used to be parsed and rewritten with
    ConvertTo-Json, which deleted all of them.

    Before anything is written, the edited text is parsed again and must have defaultProfile set
    to the new GUID and every other setting unchanged; otherwise the file is left alone. The
    original file is then copied to settings.json.winget-app-setup.bak next to it, and the new
    content is written to a temporary file in the same folder that replaces settings.json in one
    step ([System.IO.File]::Replace), so the file is never left truncated or half-written and keeps
    its attributes and ACL. A settings.json that is a symbolic or hard link is instead written in
    place, through the link, so the link survives and the linked file gets the change. A UTF-8
    byte-order mark is kept when the file has one; a file that is not valid UTF-8 is left alone.
.PARAMETER SettingsPath
    Full path to the Windows Terminal settings file.
.PARAMETER ProfileGuid
    Profile GUID to set as default. Braces are added when missing.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalDefaultProfile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileGuid
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        Write-WarningMessage "Windows Terminal settings file not found at '$SettingsPath'."
        return $false
    }

    $normalizedGuid = if ($ProfileGuid.StartsWith('{') -and $ProfileGuid.EndsWith('}')) {
        $ProfileGuid
    }
    else {
        "{$ProfileGuid}"
    }

    # The .NET file APIs below resolve a relative path against the process directory, not the
    # PowerShell location, so work with the full path.
    $fullPath = Convert-Path -LiteralPath $SettingsPath

    try {
        $originalBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $hasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF
        # Throw on invalid bytes: decoding them to U+FFFD and writing that back would corrupt the file.
        $encoding = [System.Text.UTF8Encoding]::new($hasBom, $true)
        $bomLength = if ($hasBom) { 3 } else { 0 }
        $settingsContent = $encoding.GetString($originalBytes, $bomLength, $originalBytes.Length - $bomLength)
    }
    catch {
        Write-WarningMessage "Unable to read Windows Terminal settings '$fullPath' as UTF-8: $_"
        return $false
    }

    $settingsObject = ConvertFrom-TerminalSettingsJson -JsonText $settingsContent
    if (-not $settingsObject) {
        Write-WarningMessage 'Unable to parse Windows Terminal settings.json. Skipping default profile update.'
        return $false
    }

    if ($settingsObject.defaultProfile -eq $normalizedGuid) {
        Write-Success 'Windows Terminal default profile is already set to PowerShell 7.'
        return $true
    }

    $updatedContent = Set-JsoncTopLevelStringProperty -JsonText $settingsContent -Name 'defaultProfile' -Value $normalizedGuid
    $updatedObject = if ($null -ne $updatedContent) { ConvertFrom-TerminalSettingsJson -JsonText $updatedContent }
    $isValidEdit = [bool]$updatedObject -and $updatedObject.defaultProfile -eq $normalizedGuid
    if ($isValidEdit) {
        $otherSettingsBefore = $settingsObject | Select-Object -Property * -ExcludeProperty 'defaultProfile' | ConvertTo-Json -Depth 100 -Compress
        $otherSettingsAfter = $updatedObject | Select-Object -Property * -ExcludeProperty 'defaultProfile' | ConvertTo-Json -Depth 100 -Compress
        $isValidEdit = $otherSettingsAfter -ceq $otherSettingsBefore
    }
    if (-not $isValidEdit) {
        Write-WarningMessage "Could not change only defaultProfile in '$fullPath'; the file was left unchanged."
        return $false
    }

    $backupPath = "$fullPath.winget-app-setup.bak"
    $tempPath = "$fullPath.winget-app-setup.tmp"
    try {
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force -ErrorAction Stop
        # A settings.json that is a symbolic or hard link (a dotfiles setup) is written in place,
        # through the link: replacing the name with the temp file would turn it into a separate
        # plain file and leave the linked file unedited (Windows Terminal's own save had this bug,
        # microsoft/terminal#10787). Other reparse points are written in place too.
        $settingsItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        $isLinked = [bool]$settingsItem.LinkType -or
            (($settingsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($isLinked) {
            [System.IO.File]::WriteAllText($fullPath, $updatedContent, $encoding)
        }
        else {
            [System.IO.File]::WriteAllText($tempPath, $updatedContent, $encoding)
            # [NullString]::Value: PowerShell would pass $null to the string parameter as '' (rejected).
            [System.IO.File]::Replace($tempPath, $fullPath, [NullString]::Value)
        }
    }
    catch {
        # Replace can fail after settings.json was moved aside (ERROR_UNABLE_TO_MOVE_REPLACEMENT);
        # put the original back from the backup made just before.
        if (-not (Test-Path -LiteralPath $fullPath) -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $backupPath -Destination $fullPath -ErrorAction SilentlyContinue
        }
        Write-WarningMessage "Failed to update Windows Terminal settings.json: $_"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Success "Configured Windows Terminal default profile to PowerShell 7 (previous file saved as '$backupPath')."
    return $true
}

<#
.SYNOPSIS
    Sets Windows Terminal as the default terminal application via registry.
.DESCRIPTION
    Writes DelegationConsole and DelegationTerminal values under HKCU:\Console\%%Startup.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalAsDefaultTerminalApplication {
    $registryPath = 'HKCU:\Console\%%Startup'
    $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

    try {
        if (-not (Test-Path -Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }

        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        if ($existingValues -and
            $existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal) {
            Write-Success 'Windows Terminal is already configured as the default terminal application.'
            return $true
        }

        New-ItemProperty -Path $registryPath -Name 'DelegationConsole' -PropertyType String -Value $delegationConsole -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name 'DelegationTerminal' -PropertyType String -Value $delegationTerminal -Force | Out-Null
        Write-Success 'Configured Windows Terminal as the default terminal application.'
        return $true
    }
    catch {
        Write-WarningMessage "Failed to set default terminal application in registry: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Configures Windows Terminal defaults for shell profile and terminal delegation.
.DESCRIPTION
    Applies both issue #74 requirements: PowerShell 7 default profile and Windows Terminal
    default terminal application setting.

    Both writes are strictly per-user: settings.json lives under the process account's
    %LOCALAPPDATA% and the delegation values under its HKCU hive. They are only made when that
    account is the logged-on user. The whole step is skipped, with one line, when:
      - the process runs as SYSTEM (Test-IsSystemAccount), as under an RMM agent: SYSTEM is not
        a person and has no Terminal of its own; or
      - the process account differs from the interactive session's user (the #159 detection,
        Get-ProcessUserName vs Get-InteractiveSessionUserName): a tech elevating as an admin-*
        account on a user's machine. Applying the settings there would configure the ADMIN
        account, never the user, and the delegation values in the admin's HKCU would make later
        admin sessions look Terminal-hosted to Test-WindowsTerminalHostsCurrentSession.
    When the session user is unknown (no console user reported), the step runs as before. It
    deliberately does NOT write to another user's profile or registry hive - impersonation/HKU
    writes are out of scope.

    The "default terminal application" registry write is gated on Windows Terminal actually
    being installed (Test-WindowsTerminalInstalled, issue #271). This function used to run
    unconditionally after the app-install loop regardless of whether the Microsoft.WindowsTerminal
    install had just failed, which could point HKCU:\Console\%%Startup at Windows Terminal even
    though it was never actually deployed. Once set, that delegation makes every subsequently
    created console (including a fresh top-level process such as the next CI job step) hosted by
    Windows Terminal's console component - self-locking every later attempt to install/verify
    Microsoft.WindowsTerminal via winget, since doing so would require replacing files belonging
    to the very console host rendering the session. Skipping the write when Windows Terminal is
    not installed keeps a failed install from poisoning the rest of the run (and later runs) this
    way.
.PARAMETER WhatIf
    When provided, only reports intended actions.
.PARAMETER PassThru
    Return what happened (the user phase records it, and tries again at a later sign-in unless it is
    Applied). Without it, nothing is returned.
.OUTPUTS
    With -PassThru, [string]: 'Applied' (defaultProfile is set in every settings.json found and, when
    Windows Terminal is installed, the default terminal application too), 'SettingsNotFound' (no
    settings.json yet: Terminal was never opened), 'Failed' (a settings.json or the default terminal
    application could not be set), 'Skipped' (SYSTEM, or another account than the logged-on user)
    or 'WhatIf'.
#>
function Set-WindowsTerminalDefaults {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Per-user settings: only write them for the logged-on user (see the description above).
    if (Test-IsSystemAccount) {
        Write-Info 'Skipping Windows Terminal defaults: they are per-user settings, and this run is SYSTEM, not a logged-on user.'
        if ($PassThru) {
            return 'Skipped'
        }
        return
    }
    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    if ($processUser -and $sessionUser -and ($processUser -ne $sessionUser)) {
        Write-Info "Skipping Windows Terminal defaults: they are per-user settings, and this run is elevated as '$processUser' while '$sessionUser' is logged on."
        if ($PassThru) {
            return 'Skipped'
        }
        return
    }

    $powerShell7ProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $settingsPaths = @(Get-WindowsTerminalSettingsPaths)

    if ($WhatIf) {
        if ($settingsPaths.Count -gt 0) {
            Write-Info "[DRY-RUN] Would set defaultProfile to $powerShell7ProfileGuid in $($settingsPaths.Count) Windows Terminal settings file(s)"
        }
        else {
            Write-Info '[DRY-RUN] Would set Windows Terminal defaultProfile to PowerShell 7 when settings.json is available'
        }
        if (Test-WindowsTerminalInstalled) {
            Write-Info '[DRY-RUN] Would set HKCU:\Console\%%Startup DelegationConsole and DelegationTerminal to Windows Terminal values'
        }
        else {
            Write-Info '[DRY-RUN] Windows Terminal is not installed; would skip default terminal application configuration'
        }
        if ($PassThru) {
            return 'WhatIf'
        }
        return
    }

    $status = 'Applied'
    if ($settingsPaths.Count -gt 0) {
        foreach ($settingsPath in $settingsPaths) {
            if (-not (Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid $powerShell7ProfileGuid)) {
                $status = 'Failed'
            }
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal settings.json was not found. Skipping default profile configuration.'
        $status = 'SettingsNotFound'
    }

    # Only claim Windows Terminal as the default terminal application when it is actually
    # installed (issue #271) - see the function-level remark above for why this gate exists.
    if (Test-WindowsTerminalInstalled) {
        if (-not (Set-WindowsTerminalAsDefaultTerminalApplication)) {
            $status = 'Failed'
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal is not installed. Skipping default terminal application configuration.'
    }
    if ($PassThru) {
        return $status
    }
}

