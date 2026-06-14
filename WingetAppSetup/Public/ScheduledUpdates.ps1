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
    Copies the scheduled update helper script and the WingetAppSetup module into AppData and returns the helper path.
.DESCRIPTION
    The helper runs as a standalone scheduled task with the repository absent, so it imports the
    WingetAppSetup module from a copy deployed next to it under %APPDATA%. Both the helper and the
    module are refreshed on every call so the installed copies never drift from the repository.
#>
function Install-UpdateHelperScript {
    $paths = Get-UpdateSettingsPaths
    $sourceScript = Join-Path $PSScriptRoot 'Update-InstalledApps.ps1'
    $sourceModule = Join-Path $PSScriptRoot 'WingetAppSetup'

    if (-not (Test-Path $sourceScript)) {
        throw "Required helper script is missing: $sourceScript"
    }
    if (-not (Test-Path $sourceModule)) {
        throw "Required WingetAppSetup module is missing: $sourceModule"
    }

    if (-not (Test-Path $paths.BasePath)) {
        New-Item -ItemType Directory -Path $paths.BasePath -Force | Out-Null
    }
    if (-not (Test-Path $paths.UpdateChecks)) {
        New-Item -ItemType Directory -Path $paths.UpdateChecks -Force | Out-Null
    }
    if (-not (Test-Path $paths.RollbackScripts)) {
        New-Item -ItemType Directory -Path $paths.RollbackScripts -Force | Out-Null
    }

    # Refresh the module copy the helper imports at runtime.
    if (Test-Path $paths.ModuleDir) {
        Remove-Item -Path $paths.ModuleDir -Recurse -Force
    }
    Copy-Item -Path $sourceModule -Destination $paths.ModuleDir -Recurse -Force

    Copy-Item -Path $sourceScript -Destination $paths.HelperScript -Force
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

    $null = Install-UpdateHelperScript

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

