<#
.SYNOPSIS
    Returns the filesystem paths used by scheduled update functionality.
#>
function Get-UpdateSettingsPaths {
    $basePath = Join-Path $env:APPDATA 'winget-app-setup'
    return @{
        BasePath        = $basePath
        ConfigFile      = Join-Path $basePath 'update-config.json'
        UpdateChecks    = Join-Path $basePath 'update-checks'
        RollbackScripts = Join-Path $basePath 'rollback-scripts'
        HelperScript    = Join-Path $basePath 'Update-InstalledApps.ps1'
        ModuleDir       = Join-Path $basePath 'WingetAppSetup'
    }
}

<#
.SYNOPSIS
    Returns the default update configuration object.
#>
function New-DefaultUpdateConfiguration {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Weekly', 'Daily')]
        [string]$UpdateFrequency = 'Weekly',
        [Parameter(Mandatory = $false)]
        [bool]$AutoInstall = $true,
        [Parameter(Mandatory = $false)]
        [bool]$EnabledScheduledUpdates = $false,
        [Parameter(Mandatory = $false)]
        [bool]$InitialPromptCompleted = $false
    )

    return @{
        EnabledScheduledUpdates = $EnabledScheduledUpdates
        UpdateFrequency         = $UpdateFrequency
        AutoInstall             = $AutoInstall
        LastCheckDate           = $null
        Enabled                 = $EnabledScheduledUpdates
        InitialPromptCompleted  = $InitialPromptCompleted
    }
}

<#
.SYNOPSIS
    Reads persisted update configuration from AppData.
#>
function Get-UpdateConfiguration {
    $paths = Get-UpdateSettingsPaths
    if (-not (Test-Path $paths.ConfigFile)) {
        return (New-DefaultUpdateConfiguration)
    }

    try {
        $raw = Get-Content -Path $paths.ConfigFile -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
        return @{
            EnabledScheduledUpdates = [bool]$config.EnabledScheduledUpdates
            UpdateFrequency         = if ($config.UpdateFrequency -in @('Weekly', 'Daily')) { [string]$config.UpdateFrequency } else { 'Weekly' }
            AutoInstall             = [bool]$config.AutoInstall
            LastCheckDate           = $config.LastCheckDate
            Enabled                 = [bool]$config.Enabled
            InitialPromptCompleted  = [bool]$config.InitialPromptCompleted
        }
    }
    catch {
        Write-WarningMessage "Failed to parse update configuration, using defaults: $_"
        return (New-DefaultUpdateConfiguration)
    }
}

<#
.SYNOPSIS
    Saves update configuration to AppData.
#>
function Save-UpdateConfiguration {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration
    )

    $paths = Get-UpdateSettingsPaths
    if (-not (Test-Path $paths.BasePath)) {
        New-Item -Path $paths.BasePath -ItemType Directory -Force | Out-Null
    }

    $Configuration | ConvertTo-Json | Set-Content -Path $paths.ConfigFile -Encoding UTF8
}

<#
.SYNOPSIS
    Returns true when the scheduled updates task currently exists.
.RETURNS
    [bool]
#>
function Test-ScheduledUpdatesTaskExists {
    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'

    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        return $null -ne $task
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Deploys the scheduled update helper script (and the code it needs) into AppData and returns the helper path.
.DESCRIPTION
    The helper runs as a standalone scheduled task with the repository absent, so the functions it
    needs (Get-UpdateReport, Get-UpdateConfiguration, ...) must be deployed next to it under %APPDATA%.

    Local installs have the repository on disk ($PSScriptRoot is populated): the helper and a fresh
    copy of the WingetAppSetup module are copied so the installed copies never drift from the repo.

    Remote installs run via `irm | iex`, so $PSScriptRoot is empty and there are no source files to
    copy (issue #164 — this previously threw "Cannot bind argument to parameter 'Path'" on every
    Join-Path/Copy-Item and left the scheduled task pointing at a helper that never got deployed). In
    that case the standalone helper and the self-contained winget-app-install.ps1 are downloaded from
    the repository instead; Update-InstalledApps.ps1 dot-sources the self-contained script for its
    functions when the module folder is absent.
.PARAMETER SourceRoot
    Directory holding the repository source files (Update-InstalledApps.ps1 and the WingetAppSetup
    folder). Defaults to $PSScriptRoot; empty when running remotely via `irm | iex`.
#>
function Install-UpdateHelperScript {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SourceRoot = $PSScriptRoot
    )

    $paths = Get-UpdateSettingsPaths

    $sourceScript = if ($SourceRoot) { Join-Path $SourceRoot 'Update-InstalledApps.ps1' } else { $null }
    $sourceModule = if ($SourceRoot) { Join-Path $SourceRoot 'WingetAppSetup' } else { $null }

    # When the repository is on disk, the expected source files must be present; a missing file means
    # a genuinely broken local install, so surface it rather than silently downloading.
    if ($SourceRoot) {
        if (-not (Test-Path $sourceScript)) {
            throw "Required helper script is missing: $sourceScript"
        }
        if (-not (Test-Path $sourceModule)) {
            throw "Required WingetAppSetup module is missing: $sourceModule"
        }
    }

    foreach ($dir in @($paths.BasePath, $paths.UpdateChecks, $paths.RollbackScripts)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    if ($SourceRoot) {
        # Local install: refresh the module copy the helper imports at runtime, then the helper.
        if (Test-Path $paths.ModuleDir) {
            Remove-Item -Path $paths.ModuleDir -Recurse -Force
        }
        Copy-Item -Path $sourceModule -Destination $paths.ModuleDir -Recurse -Force
        Copy-Item -Path $sourceScript -Destination $paths.HelperScript -Force
        return $paths.HelperScript
    }

    # Remote (irm | iex) install: nothing on disk to copy. Download the standalone helper plus the
    # self-contained script it dot-sources for the WingetAppSetup functions. Drop any stale module
    # copy from a prior local install so it can't shadow the self-contained fallback.
    if (Test-Path $paths.ModuleDir) {
        Remove-Item -Path $paths.ModuleDir -Recurse -Force
    }

    $rawBase = 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main'
    $selfContained = Join-Path $paths.BasePath 'winget-app-install.ps1'
    Invoke-WebRequest -Uri "$rawBase/Update-InstalledApps.ps1" -OutFile $paths.HelperScript -UseBasicParsing -ErrorAction Stop
    Invoke-WebRequest -Uri "$rawBase/winget-app-install.ps1" -OutFile $selfContained -UseBasicParsing -ErrorAction Stop

    return $paths.HelperScript
}

<#
.SYNOPSIS
    Enables automatic app update checks via Windows Scheduled Task.
.DESCRIPTION
    Creates a Windows scheduled task that runs as the current user (S4U, no elevated privileges).
.PARAMETER SkipPrompt
    When true, skips the user prompt and uses supplied parameter values.
.PARAMETER WhatIf
    When provided, only reports intended actions.
#>
function Enable-ScheduledUpdatesCheck {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Weekly', 'Daily')]
        [string]$UpdateFrequency = 'Weekly',
        [Parameter(Mandatory = $false)]
        [bool]$AutoInstall = $true,
        [Parameter(Mandatory = $false)]
        [bool]$SkipPrompt = $false,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $paths = Get-UpdateSettingsPaths
    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'

    if (-not $SkipPrompt -and -not $WhatIf) {
        $scheduleDescription = if ($UpdateFrequency -eq 'Daily') { 'every day at 2:00 AM' } else { 'every Sunday at 2:00 AM' }
        $userChoice = Read-Host "Enable $($UpdateFrequency.ToLower()) automatic update checks? Updates will be checked $scheduleDescription. (Y/N)"
        $enableScheduledUpdates = $userChoice -in @('Y', 'y')

        $config = New-DefaultUpdateConfiguration -UpdateFrequency $UpdateFrequency -AutoInstall $AutoInstall -EnabledScheduledUpdates $enableScheduledUpdates -InitialPromptCompleted $true
        Save-UpdateConfiguration -Configuration $config

        if (-not $enableScheduledUpdates) {
            Write-WarningMessage 'Scheduled updates were not enabled.'
            return $false
        }

        $autoInstallChoice = Read-Host 'Automatically install found updates? (Y/N):'
        $AutoInstall = $autoInstallChoice -in @('Y', 'y')
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would create/update scheduled task: $taskName"
        Write-Info "[DRY-RUN] Frequency: $UpdateFrequency at 2:00 AM"
        return $true
    }

    # Deploying the helper is best-effort: if it fails (e.g. the remote download is blocked), warn
    # and skip rather than aborting the whole install or registering a task that points at a helper
    # that was never deployed.
    try {
        $null = Install-UpdateHelperScript
    }
    catch {
        Write-WarningMessage "Could not deploy the scheduled-update helper: $_"
        Write-WarningMessage 'Scheduled updates were not enabled.'
        return $false
    }

    if (Test-ScheduledUpdatesTaskExists) {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    }

    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    try {
        $taskAction = New-ScheduledTaskAction -Execute $psExecutable -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($paths.HelperScript)`""
        if ($UpdateFrequency -eq 'Daily') {
            $taskTrigger = New-ScheduledTaskTrigger -Daily -At '2:00 AM'
        }
        else {
            $taskTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '2:00 AM'
        }
        $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited

        Register-ScheduledTask -Action $taskAction `
            -Trigger $taskTrigger `
            -TaskName $taskName `
            -TaskPath $taskPath `
            -Settings $taskSettings `
            -Principal $taskPrincipal `
            -Description 'Automatically checks and installs available updates for installed applications via winget.' `
            -Force | Out-Null
    }
    catch {
        Write-ErrorMessage "Failed to create scheduled task: $_"
        return $false
    }

    $config = New-DefaultUpdateConfiguration -UpdateFrequency $UpdateFrequency -AutoInstall $AutoInstall -EnabledScheduledUpdates $true -InitialPromptCompleted $true
    Save-UpdateConfiguration -Configuration $config
    Write-Success 'Scheduled updates enabled successfully.'
    return $true
}

<#
.SYNOPSIS
    Disables and removes the scheduled updates task.
#>
function Disable-ScheduledUpdatesCheck {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would disable scheduled task: $taskPath$taskName"
        return $true
    }

    try {
        if (Test-ScheduledUpdatesTaskExists) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
        }

        $config = Get-UpdateConfiguration
        $config.EnabledScheduledUpdates = $false
        $config.Enabled = $false
        $config.InitialPromptCompleted = $true
        Save-UpdateConfiguration -Configuration $config
        Write-Success 'Scheduled updates disabled successfully.'
        return $true
    }
    catch {
        Write-ErrorMessage "Failed to disable scheduled updates: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Runs update check immediately, optionally auto-installing updates.
#>
function Invoke-OnDemandUpdateCheck {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$AutoInstallUpdates,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $report = @(Get-UpdateReport)
    if ($report.Count -eq 0) {
        Write-Info 'No updates available.'
    }
    else {
        Write-Info 'Available updates:'
        $report | Format-Table PackageName, CurrentVersion, AvailableVersion
    }

    if (-not $AutoInstallUpdates) {
        return
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would auto-install all available updates.'
        return
    }

    $helperPath = Install-UpdateHelperScript
    & $helperPath -AutoInstallOverride:$true -RunReason OnDemand
}

