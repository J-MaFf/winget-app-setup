<#
.SYNOPSIS
    Returns the Windows Terminal settings.json paths that exist: every packaged channel's and the
    unpackaged one.
.OUTPUTS
    [string[]] The existing settings paths, or an empty array.
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
    Sets Windows Terminal's default profile to a GUID.
.DESCRIPTION
    Changes only the top-level "defaultProfile" value, or inserts the key
    (Set-JsoncTopLevelStringProperty), so comments, formatting and key order are kept. The edited
    text must parse with the new GUID and every other setting unchanged, or nothing is written.
    Then the original is copied to settings.json.winget-app-setup.bak and the new text replaces
    settings.json in one step ([System.IO.File]::Replace), so the file is never half-written and
    keeps its attributes and ACL. A settings.json that is a link is written through the link
    instead. A UTF-8 BOM is kept; a file that is not valid UTF-8 is left alone.
.PARAMETER SettingsPath
    Full path to the Windows Terminal settings file.
.PARAMETER ProfileGuid
    Profile GUID to set as default. Braces are added when missing.
.OUTPUTS
    [bool] True when the profile is set (or already was); otherwise False.
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
        # A link (a dotfiles setup) is written in place, through the link: replacing the name would
        # leave a plain file and the linked one unedited (microsoft/terminal#10787). Other reparse
        # points are written in place too.
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
.OUTPUTS
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
    Makes PowerShell 7 Windows Terminal's default profile and Windows Terminal the default terminal
    application (issue #74).
.DESCRIPTION
    Both settings are per-user (settings.json under %LOCALAPPDATA%, the delegation values in HKCU),
    so the step is skipped, with one line, when the process runs as SYSTEM or as another account
    than the interactive session's user (cross-user elevation, issue #159): it would configure the
    wrong account. When the session user is unknown, it runs. It never writes to another user's
    profile or hive. The installer passes the account context it read at the start of the run, so
    this step decides as the rest of the run did; without one (the user phase), it reads it here.

    The default terminal application is set only when Windows Terminal is installed
    (Test-WindowsTerminalInstalled, issue #271): pointing it at a Terminal that failed to install
    made every later console Terminal-hosted, which locks winget out of installing Terminal.
.PARAMETER WhatIf
    When provided, only reports intended actions.
.PARAMETER PassThru
    Return what happened (the user phase records it, and tries again at a later sign-in unless it is
    Applied). Without it, nothing is returned.
.PARAMETER AccountContext
    The run's Get-InstallAccountContext result (IsSystem, ProcessUser, SessionUser). Optional: when
    omitted, the step reads the account itself.
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
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    # Per-user settings: only write them for the logged-on user (see the description above).
    if ($null -ne $AccountContext) {
        $isSystem = [bool]$AccountContext.IsSystem
    }
    else {
        $isSystem = [bool](Test-IsSystemAccount)
    }
    if ($isSystem) {
        Write-Info 'Skipping Windows Terminal defaults: they are per-user settings, and this run is SYSTEM, not a logged-on user.'
        if ($PassThru) {
            return 'Skipped'
        }
        return
    }
    if ($null -ne $AccountContext) {
        $processUser = $AccountContext.ProcessUser
        $sessionUser = $AccountContext.SessionUser
    }
    else {
        $processUser = Get-ProcessUserName
        $sessionUser = Get-InteractiveSessionUserName
    }
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

