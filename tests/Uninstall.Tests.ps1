# Uninstall.Tests.ps1
# Tests for WingetAppSetup/Public/Uninstall.ps1 (Invoke-WingetUninstall) and its private per-app
# step (Private/AppUninstall.ps1: Uninstall-CatalogApp, Get-HostingShellSkipReason), plus the
# winget-app-uninstall.ps1 entry script that runs them (review findings P2-19 and P3-18).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A copy of winget-app-uninstall.ps1 next to a module folder, run in a child PowerShell so its
    # `exit` ends the child, not the test run. -ModuleSource copies the real module and adds
    # -Overrides as one more Public file, loaded last, so it replaces the functions that would touch
    # the machine; without it the module is just -Overrides (a stand-in).
    function Invoke-TestUninstallerScript {
        param (
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][string]$Overrides,
            [string]$ModuleSource,
            [string[]]$ScriptArguments = @(),
            [hashtable]$Environment = @{},
            [switch]$NoModule
        )

        $moduleRoot = Join-Path $Root 'WingetAppSetup'
        if ($NoModule) {
            # The script copied on its own, without the module folder next to it.
            [void](New-Item -ItemType Directory -Path $Root -Force)
        }
        elseif ($ModuleSource) {
            Copy-Item -LiteralPath $ModuleSource -Destination $moduleRoot -Recurse
            Set-Content -LiteralPath (Join-Path $moduleRoot 'Public/zz-TestOverrides.ps1') -Value $Overrides
        }
        else {
            [void](New-Item -ItemType Directory -Path $moduleRoot -Force)
            Set-Content -LiteralPath (Join-Path $moduleRoot 'WingetAppSetup.psd1') -Value "@{ RootModule = 'WingetAppSetup.psm1'; ModuleVersion = '1.0.0'; FunctionsToExport = '*' }"
            Set-Content -LiteralPath (Join-Path $moduleRoot 'WingetAppSetup.psm1') -Value $Overrides
        }
        Copy-Item -LiteralPath $script:UninstallerScriptPath -Destination $Root
        $scriptCopy = Join-Path $Root 'winget-app-uninstall.ps1'

        $saved = @{}
        foreach ($name in $Environment.Keys) {
            $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
            [System.Environment]::SetEnvironmentVariable($name, $Environment[$name])
        }
        try {
            $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $scriptCopy @ScriptArguments 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally {
            foreach ($name in $saved.Keys) {
                [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }
}

Describe 'Invoke-WingetUninstall' {
    BeforeEach {
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $false }
        Mock Uninstall-WingetAutoUpdate { @{ Succeeded = $true; RestartRequired = $false } }
        Mock Test-WauInstalled { $true }
        Mock Reset-WindowsTerminalDelegation { $false }
        Mock Test-WindowsTerminalHostsCurrentSession { $false }
        Mock Get-PowerShellEdition { 'Desktop' }
        # Never read the runner's real account or console session: a same-user run unless a test
        # says otherwise (review findings P2-24, P3-23).
        Mock Get-InstallAccountContext { New-TestAccountContext }

        $script:capturedTables = @{}
        $script:gridView = @{}
        Mock Write-Table {
            $script:capturedTables[$Title] = $Rows
            $script:gridView[$Title] = $AutoGridView
        }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        $script:successMessages = @()
        Mock Write-Success { $script:successMessages += $Message }

        # The machine: which apps winget lists, and what `winget uninstall` exits with per app.
        $script:installed = @{ 'Contoso.AppOne' = $true; 'Contoso.AppTwo' = $true }
        $script:uninstallResults = @{}
        $script:sequence = @()
        Mock Invoke-WingetProcess {
            $arguments = @($ArgumentList)
            $id = $arguments[[array]::IndexOf($arguments, '--id') + 1]
            $script:sequence += ('{0} {1}' -f $arguments[0], $id)
            switch ($arguments[0]) {
                'list' {
                    if ($script:installed[$id]) {
                        return New-TestProcessResult -ExitCode 0 -Output @("$id  1.0  winget")
                    }
                    return New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
                }
                'uninstall' {
                    if ($script:uninstallResults.ContainsKey($id)) {
                        return & $script:uninstallResults[$id]
                    }
                    $script:installed[$id] = $false
                    return New-TestProcessResult -ExitCode 0
                }
            }
            throw "unexpected winget call: $($arguments -join ' ')"
        }

        $script:apps = @(@{ name = 'Contoso.AppOne' }, @{ name = 'Contoso.AppTwo' })
    }

    Context 'Exit codes' {
        It 'Returns 0, and nothing else, when every app and Winget-AutoUpdate are removed' {
            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            @($result).Count | Should -Be 1
            $result | Should -BeOfType [int]
            $result | Should -Be 0
            $script:sequence | Should -Be @('list Contoso.AppOne', 'uninstall Contoso.AppOne', 'list Contoso.AppTwo', 'uninstall Contoso.AppTwo')
            Should -Invoke Remove-LegacyScheduledUpdates -Times 1 -Exactly
            Should -Invoke Uninstall-WingetAutoUpdate -Times 1 -Exactly -ParameterFilter { -not $WhatIf }
            $script:capturedTables['Uninstallation Summary'][0] | Should -Be @('Uninstalled', 'Contoso.AppOne, Contoso.AppTwo')
            $script:successMessages | Should -Contain 'Successfully uninstalled: Contoso.AppOne'
        }

        It 'Returns 2 and removes nothing, Winget-AutoUpdate included, when winget cannot be started (P2-19)' {
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 2
            Should -Invoke Initialize-Winget -Times 1 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Remove-LegacyScheduledUpdates -Times 0 -Exactly
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
            Should -Invoke Write-Table -Times 0 -Exactly
            ($script:errorMessages -join "`n") | Should -Match 'winget cannot be started for this account, so nothing was uninstalled'
            ($script:errorMessages -join "`n") | Should -Match 'Winget-AutoUpdate was left in place'
        }

        It 'Returns 2, removes nothing and keeps Winget-AutoUpdate, naming Group Policy, when the policy turns winget off (review finding P3-30)' {
            # Initialize-Winget names the policy; another account or a fresh App Installer cannot
            # help, so the uninstaller must not send the user there.
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' } }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 2
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Remove-LegacyScheduledUpdates -Times 0 -Exactly
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
            $script:errorMessages | Should -Be @('Group Policy on this PC blocks winget (see above), so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed. Winget-AutoUpdate was left in place, so the apps keep getting updates. Run the uninstaller again once the policy allows winget.')
        }

        It 'Does not claim Winget-AutoUpdate was left in place when it is not installed (winget unusable)' {
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }
            Mock Test-WauInstalled { $false }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 2
            ($script:errorMessages -join "`n") | Should -Match 'winget cannot be started for this account, so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed\. Run the uninstaller from an account where winget works'
            ($script:errorMessages -join "`n") | Should -Not -Match 'Winget-AutoUpdate'
        }

        It 'Sets winget up the way the installer does before the first app' {
            Mock Initialize-Winget { $script:sequence += 'winget setup'; [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }

            $null = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $script:sequence[0..1] | Should -Be @('winget setup', 'list Contoso.AppOne')
            Should -Invoke Get-InstallAccountContext -Times 1 -Exactly
            Should -Invoke Initialize-Winget -Times 1 -Exactly -ParameterFilter { -not $WhatIf -and $null -ne $AccountContext -and -not $AccountContext.IsSystem }
        }

        It 'Drops a machine-wide winget path left by an earlier run in this session before it sets winget up (review finding P2-24)' {
            # Resolve-WingetExecutable returns $script:MachineWingetPath once a SYSTEM run has found
            # it; a path from an earlier run in the same session may no longer exist.
            $script:MachineWingetPath = 'C:\stale\from\an\earlier\run\winget.exe'
            $script:pathAtSetup = 'not called'
            Mock Initialize-Winget { $script:pathAtSetup = $script:MachineWingetPath; [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }

            try {
                $null = Invoke-WingetUninstall -Apps $script:apps -NonInteractive
            }
            finally {
                $script:MachineWingetPath = $null
            }

            $script:pathAtSetup | Should -BeNullOrEmpty
        }

        It 'Sets winget up as a SYSTEM run of the installer does: the account it decided, so the machine-wide winget and no account fix (review findings P2-24, P3-23)' {
            # An RMM agent runs the uninstaller as SYSTEM too. Initialize-Winget then uses the
            # machine-wide winget.exe and never installs Microsoft.WinGet.Client.
            Mock Get-InstallAccountContext { New-TestAccountContext -System }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 0
            Should -Invoke Get-InstallAccountContext -Times 1 -Exactly
            Should -Invoke Initialize-Winget -Times 1 -Exactly -ParameterFilter { $AccountContext.IsSystem }
            $script:successMessages | Should -Contain 'Successfully uninstalled: Contoso.AppTwo'
        }

        It 'Returns 1 and keeps Winget-AutoUpdate when an app could not be removed' {
            $script:uninstallResults['Contoso.AppTwo'] = { New-TestProcessResult -ExitCode -1978335226 }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
            Should -Invoke Remove-LegacyScheduledUpdates -Times 0 -Exactly
            $script:errorMessages | Should -Contain "Failed to uninstall: Contoso.AppTwo ('winget uninstall' exited with 0x8A150006 SHELLEXEC_INSTALL_FAILED)."
            $script:warningMessages | Should -Contain 'Winget-AutoUpdate is kept: 1 app(s) could not be uninstalled, and it keeps them updated. Fix the failures above and run the uninstaller again to remove it.'
            $script:warningMessages | Should -Contain 'Auto-updates: KEPT - Winget-AutoUpdate stays until every app is removed (see above).'
            $script:capturedTables['Uninstallation Summary'] | Should -HaveCount 2
            $script:capturedTables['Uninstallation Summary'][1] | Should -Be @('Failed', 'Contoso.AppTwo')
            $script:capturedTables['Failed Uninstalls'][0] | Should -Be @('Contoso.AppTwo', "'winget uninstall' exited with 0x8A150006 SHELLEXEC_INSTALL_FAILED")
        }

        It 'Says nothing about keeping Winget-AutoUpdate when an app fails and it is not installed' {
            Mock Test-WauInstalled { $false }
            $script:uninstallResults['Contoso.AppTwo'] = { New-TestProcessResult -ExitCode -1978335226 }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
            @(@($script:warningMessages) + @($script:errorMessages) + @($script:infoMessages) | Where-Object { $_ -match 'Winget-AutoUpdate|Auto-updates' }) | Should -BeNullOrEmpty
            $script:errorMessages | Should -Contain "Failed to uninstall: Contoso.AppTwo ('winget uninstall' exited with 0x8A150006 SHELLEXEC_INSTALL_FAILED)."
        }

        It 'Returns 1 when Winget-AutoUpdate could not be removed (<Case>)' -ForEach @(
            @{ Case = 'it reported a failure'; Behaviour = { @{ Succeeded = $false; RestartRequired = $false } } }
            @{ Case = 'it threw'; Behaviour = { throw 'msiexec exploded' } }
        ) {
            Mock Uninstall-WingetAutoUpdate $Behaviour

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            $script:errorMessages | Should -Contain 'Auto-updates: FAILED - Winget-AutoUpdate could not be removed (see above). Run the uninstaller again.'
        }

        It 'Returns 1 when an app''s step throws, and keeps going with the next app' {
            Mock Uninstall-CatalogApp { throw 'boom' } -ParameterFilter { $App.name -eq 'Contoso.AppOne' }
            Mock Uninstall-CatalogApp { @{ Status = 'Uninstalled'; Reason = $null; RestartRequired = $false } }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            $script:capturedTables['Failed Uninstalls'][0] | Should -Be @('Contoso.AppOne', 'Unexpected error: boom')
            $script:successMessages | Should -Contain 'Successfully uninstalled: Contoso.AppTwo'
        }

        It 'Returns 3 without touching winget when the app list is <Case>' -ForEach @(
            @{ Case = 'invalid'; Apps = @(@{ name = 'not-a-package-id' }) }
            @{ Case = 'empty'; Apps = @() }
        ) {
            $result = Invoke-WingetUninstall -Apps $Apps -NonInteractive

            $result | Should -Be 3
            Should -Invoke Initialize-Winget -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
        }
    }

    Context 'A check winget could not answer is a failure, never "not installed" (P2-19)' {
        It 'Fails every app and keeps Winget-AutoUpdate when <Case>' -ForEach @(
            @{ Case = 'winget cannot be started'; Result = { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'The system cannot find the file specified.' }; Reason = 'could not check whether it is installed: winget could not be started (The system cannot find the file specified)' }
            @{ Case = 'winget list runs out of time'; Result = { New-TestProcessResult -TimedOut }; Reason = "could not check whether it is installed: 'winget list' did not answer within 15 seconds" }
            @{ Case = 'winget list fails'; Result = { New-TestProcessResult -ExitCode -1978335157 }; Reason = "could not check whether it is installed: 'winget list' failed with 0x8A15004B FAILED_TO_OPEN_ALL_SOURCES" }
        ) {
            $script:listResult = $Result
            Mock Invoke-WingetProcess { & $script:listResult } -ParameterFilter { $ArgumentList[0] -eq 'list' }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
            @($script:warningMessages | Where-Object { $_ -like 'Skipping:*' }) | Should -BeNullOrEmpty
            $script:capturedTables['Uninstallation Summary'] | Should -HaveCount 1
            $script:capturedTables['Uninstallation Summary'][0] | Should -Be @('Failed', 'Contoso.AppOne, Contoso.AppTwo')
            $script:capturedTables['Failed Uninstalls'][0] | Should -Be @('Contoso.AppOne', $Reason)
        }

        It 'Reports an app winget does not list as not installed, and still removes Winget-AutoUpdate' {
            $script:installed['Contoso.AppTwo'] = $false

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 0
            $script:warningMessages | Should -Contain 'Skipping: Contoso.AppTwo (not installed)'
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' -and $ArgumentList -contains 'Contoso.AppTwo' }
            Should -Invoke Uninstall-WingetAutoUpdate -Times 1 -Exactly
            $script:capturedTables['Uninstallation Summary'][1] | Should -Be @('Skipped', 'Contoso.AppTwo')
        }
    }

    Context 'Catalog conditions and the shells this run depends on (P3-18)' {
        It 'Leaves an installed app alone when its catalog condition does not hold' {
            $apps = @(@{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' })
            $script:installed['Dell.CommandUpdate.Universal'] = $true

            $result = Invoke-WingetUninstall -Apps $apps -NonInteractive

            $result | Should -Be 0
            $script:warningMessages | Should -Contain 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
        }

        It 'Removes the app when its condition throws (fail-open, as in the installer)' {
            $apps = @(@{ name = 'Contoso.AppOne'; condition = { throw 'probe broke' } })

            $result = Invoke-WingetUninstall -Apps $apps -NonInteractive

            $result | Should -Be 0
            $script:warningMessages | Should -Contain 'Condition for Contoso.AppOne failed to evaluate (probe broke); treating as applicable and attempting the uninstall.'
            $script:successMessages | Should -Contain 'Successfully uninstalled: Contoso.AppOne'
        }

        It 'Removes the app when its condition writes an error and gives no answer (fail-open, the installer''s rule, review finding P3-33)' {
            # A probe that writes an error and returns nothing (a CIM query without -ErrorAction
            # Stop) has no answer; it used to read as "does not apply", so the app was kept.
            $apps = @(@{ name = 'Contoso.AppOne'; condition = { Write-Error 'RPC server is unavailable' } })

            $result = Invoke-WingetUninstall -Apps $apps -NonInteractive

            $result | Should -Be 0
            ($script:warningMessages -join "`n") | Should -Match 'Condition for Contoso\.AppOne failed to evaluate \(RPC server is unavailable\); treating as applicable and attempting the uninstall\.'
            $script:successMessages | Should -Contain 'Successfully uninstalled: Contoso.AppOne'
        }

        It 'Decides applicability with the installer''s Test-AppApplicability, after the installed check' {
            Mock Test-AppApplicability { $false } -ParameterFilter { $App.name -eq 'Contoso.AppTwo' -and $Purpose -eq 'Uninstall' }
            Mock Test-AppApplicability { $true }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 0
            $script:warningMessages | Should -Contain 'Skipping: Contoso.AppTwo (not applicable: condition not met)'
            $script:sequence | Should -Be @('list Contoso.AppOne', 'uninstall Contoso.AppOne', 'list Contoso.AppTwo')
            Should -Invoke Test-AppApplicability -Times 2 -Exactly -ParameterFilter { $Purpose -eq 'Uninstall' }
        }

        It 'Keeps PowerShell 7 when it runs this uninstaller, and removes it from Windows PowerShell (<Edition>)' -ForEach @(
            @{ Edition = 'Core'; Removed = $false }
            @{ Edition = 'Desktop'; Removed = $true }
        ) {
            $script:edition = $Edition
            Mock Get-PowerShellEdition { $script:edition }
            $script:installed['Microsoft.PowerShell'] = $true

            $result = Invoke-WingetUninstall -Apps @(@{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' }) -NonInteractive

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times ([int]$Removed) -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
            if (-not $Removed) {
                $script:warningMessages | Should -Contain 'Skipping: Microsoft.PowerShell (this uninstaller is running in PowerShell 7; to remove it, run winget-app-uninstall.ps1 from Windows PowerShell)'
                # Kept on purpose, not a failure: Winget-AutoUpdate is still removed.
                Should -Invoke Uninstall-WingetAutoUpdate -Times 1 -Exactly
            }
        }

        It 'Keeps Windows Terminal when it hosts this session, and removes it otherwise (hosted: <Hosted>)' -ForEach @(
            @{ Hosted = $true }
            @{ Hosted = $false }
        ) {
            $script:hosted = $Hosted
            Mock Test-WindowsTerminalHostsCurrentSession { $script:hosted }
            $script:installed['Microsoft.WindowsTerminal'] = $true
            # The catalog's own entry: its condition is the same host check.
            $terminal = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            $result = Invoke-WingetUninstall -Apps @($terminal) -NonInteractive

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times ([int](-not $Hosted)) -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
            if ($Hosted) {
                ($script:warningMessages -join "`n") | Should -Match 'Skipping: Microsoft\.WindowsTerminal \(Windows Terminal hosts this window, or is set as the default terminal application, so removing it would close this window; to remove it, set the default terminal application to Windows Console Host'
            }
        }

        It 'Checks whether Windows Terminal is installed before the host check, so an absent one reads "not installed"' {
            Mock Test-WindowsTerminalHostsCurrentSession { $true }
            $terminal = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            $null = Invoke-WingetUninstall -Apps @($terminal) -NonInteractive

            $script:warningMessages | Should -Contain 'Skipping: Microsoft.WindowsTerminal (not installed)'
            Should -Invoke Test-WindowsTerminalHostsCurrentSession -Times 0 -Exactly
        }

        It 'Resets the default-terminal setting after the app loop once winget no longer lists Windows Terminal (<Case>)' -ForEach @(
            @{ Case = 'removed now'; Installed = $true }
            @{ Case = 'not installed'; Installed = $false }
        ) {
            $script:installed['Microsoft.WindowsTerminal'] = $Installed
            Mock Reset-WindowsTerminalDelegation { $script:sequence += 'reset delegation'; $true }
            $apps = @(@(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }) + @($script:apps)

            $result = Invoke-WingetUninstall -Apps $apps -NonInteractive

            $result | Should -Be 0
            Should -Invoke Reset-WindowsTerminalDelegation -Times 1 -Exactly -ParameterFilter { -not $WhatIf }
            # After the whole app loop, not right after Windows Terminal.
            $script:sequence[-1] | Should -Be 'reset delegation'
        }

        It 'Leaves the default-terminal setting alone while Windows Terminal is still installed (<Case>)' -ForEach @(
            @{ Case = 'it hosts this session'; Hosted = $true; UninstallResult = $null }
            @{ Case = 'its uninstall failed'; Hosted = $false; UninstallResult = { New-TestProcessResult -ExitCode -1978335226 } }
            @{ Case = 'the check failed'; Hosted = $false; UninstallResult = $null; CheckFails = $true }
        ) {
            $script:installed['Microsoft.WindowsTerminal'] = $true
            $script:hosted = $Hosted
            Mock Test-WindowsTerminalHostsCurrentSession { $script:hosted }
            if ($UninstallResult) {
                $script:uninstallResults['Microsoft.WindowsTerminal'] = $UninstallResult
            }
            if ($CheckFails) {
                Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut } -ParameterFilter { $ArgumentList[0] -eq 'list' }
            }
            $terminal = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            $null = Invoke-WingetUninstall -Apps @($terminal) -NonInteractive

            Should -Invoke Reset-WindowsTerminalDelegation -Times 0 -Exactly
        }

        It 'Leaves the default-terminal setting alone when the list has no Windows Terminal' {
            $null = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            Should -Invoke Reset-WindowsTerminalDelegation -Times 0 -Exactly
        }
    }

    Context 'The winget uninstall call (P3-18)' {
        It 'Runs through Invoke-WingetProcess with --silent and the uninstall time limit, even when someone is at the console' {
            Mock Test-EffectiveNonInteractive { $false }
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 } -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }

            $null = Invoke-WingetUninstall -Apps @(@{ name = 'Contoso.AppOne' })

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -eq 'uninstall --exact --id Contoso.AppOne --silent --accept-source-agreements --disable-interactivity' -and
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetUninstall)
            }
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[0] -eq 'list' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetListCheck)
            }
        }

        It 'Fails the app when <Case>' -ForEach @(
            @{ Case = 'the uninstall runs out of time'; Result = { New-TestProcessResult -TimedOut }; Reason = "'winget uninstall' did not finish within 15 minutes and was stopped" }
            @{ Case = 'winget cannot be started for the uninstall'; Result = { New-TestProcessResult -LaunchFailed -LaunchErrorCode 5 -LaunchError 'Access is denied.' }; Reason = 'winget could not be started (Access is denied)' }
        ) {
            $script:uninstallResults['Contoso.AppOne'] = $Result

            $result = Invoke-WingetUninstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 1
            $script:capturedTables['Failed Uninstalls'][0] | Should -Be @('Contoso.AppOne', $Reason)
        }

        It 'Names the uninstaller''s log in the reason when winget wrote one' {
            $logPath = Join-Path $TestDrive 'winget-uninstall-Contoso.AppOne.log'
            Set-Content -LiteralPath $logPath -Value 'MSI log'
            $script:logPath = $logPath
            $script:uninstallResults['Contoso.AppOne'] = { New-TestProcessResult -ExitCode -1978335159 -LogPath $script:logPath }

            $null = Invoke-WingetUninstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $script:capturedTables['Failed Uninstalls'][0][1] | Should -Be "'winget uninstall' exited with 0x8A150049 MSI_INSTALL_FAILED; uninstaller log: $logPath"
        }

        # What winget prints and exits with when the app's uninstaller returns a restart code: its
        # uninstall flow reports any non-zero return as 0x8A150030 EXEC_UNINSTALL_COMMAND_FAILED
        # (Workflows/UninstallFlow.cpp ReportUninstallerResult), after the uninstaller's own code.
        It 'Counts an uninstall a restart finishes (uninstaller returned <Code>) as removed, says so and returns 3010' -ForEach @(
            @{ Code = 3010 }
            @{ Code = 1641 }
        ) {
            $script:code = $Code
            $script:uninstallResults['Contoso.AppOne'] = { New-TestProcessResult -ExitCode -1978335184 -Output @('Found Contoso App One [Contoso.AppOne]', 'Starting package uninstall...', "Uninstall failed with exit code: $script:code") }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 3010
            $script:successMessages | Should -Contain 'Successfully uninstalled: Contoso.AppOne (a restart finishes removing it)'
            $script:warningMessages | Should -Contain 'Restart: REQUIRED to finish removing Contoso.AppOne.'
            $script:capturedTables['Uninstallation Summary'][0] | Should -Be @('Uninstalled', 'Contoso.AppOne, Contoso.AppTwo')
            Should -Invoke Uninstall-WingetAutoUpdate -Times 1 -Exactly
        }

        It 'Fails the app when its uninstaller returned another code (<Case>)' -ForEach @(
            @{ Case = 'MSI 1603'; Output = @('Uninstall failed with exit code: 1603') }
            @{ Case = '3010 only inside the installer log path'; Output = @('Uninstall failed with exit code: 1603', 'Installer log is available at: C:\logs\3010\winget-uninstall-Contoso.AppOne-20261004-183010.log') }
            @{ Case = '3010 inside a longer number'; Output = @('Uninstall failed with exit code: 13010') }
        ) {
            $script:output = $Output
            $script:uninstallResults['Contoso.AppOne'] = { New-TestProcessResult -ExitCode -1978335184 -Output $script:output }

            $result = Invoke-WingetUninstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 1
            $script:capturedTables['Failed Uninstalls'][0] | Should -Be @('Contoso.AppOne', "'winget uninstall' exited with 0x8A150030")
            $script:warningMessages | Should -Not -Contain 'Restart: REQUIRED to finish removing Contoso.AppOne.'
        }

        It 'Returns 1, not 3010, when one app needs a restart and another failed' {
            $script:uninstallResults['Contoso.AppOne'] = { New-TestProcessResult -ExitCode -1978335184 -Output @('Uninstall failed with exit code: 3010') }
            $script:uninstallResults['Contoso.AppTwo'] = { New-TestProcessResult -ExitCode -1978335226 }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            $script:warningMessages | Should -Contain 'Restart: REQUIRED to finish removing Contoso.AppOne.'
        }

        It 'Returns 3010 when removing Winget-AutoUpdate needs a restart to finish' {
            Mock Uninstall-WingetAutoUpdate { @{ Succeeded = $true; RestartRequired = $true } }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive

            $result | Should -Be 3010
            $script:warningMessages | Should -Contain 'Restart: REQUIRED to finish removing Winget-AutoUpdate.'
        }
    }

    Context 'Dry run' {
        It 'Runs only the read-only checks, removes nothing and returns 0' {
            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive -WhatIf

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -ne 'list' }
            Should -Invoke Initialize-Winget -Times 1 -Exactly -ParameterFilter { $WhatIf }
            Should -Invoke Remove-LegacyScheduledUpdates -Times 1 -Exactly -ParameterFilter { $WhatIf }
            Should -Invoke Uninstall-WingetAutoUpdate -Times 1 -Exactly -ParameterFilter { $WhatIf }
            $script:infoMessages | Should -Contain '[DRY-RUN] Would uninstall: Contoso.AppOne'
            $script:infoMessages | Should -Contain '=== DRY-RUN SUMMARY ==='
        }

        It 'Forwards the dry run to the default-terminal reset when Windows Terminal is not installed' {
            $terminal = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            $null = Invoke-WingetUninstall -Apps @($terminal) -NonInteractive -WhatIf

            Should -Invoke Reset-WindowsTerminalDelegation -Times 1 -Exactly -ParameterFilter { $WhatIf }
        }

        It 'Does not preview the default-terminal reset for a Windows Terminal it would only remove' {
            $script:installed['Microsoft.WindowsTerminal'] = $true
            $terminal = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            $null = Invoke-WingetUninstall -Apps @($terminal) -NonInteractive -WhatIf

            Should -Invoke Reset-WindowsTerminalDelegation -Times 0 -Exactly
        }

        It 'Stops the preview with 0 when winget cannot be started yet' {
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive -WhatIf

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
            ($script:infoMessages -join "`n") | Should -Match 'A real run would try to set it up \(see above\) and, if winget still could not start, stop with exit code 2 before removing anything'
        }

        It 'Stops the preview with 0, naming Group Policy, when the policy turns winget off' {
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' } }

            $result = Invoke-WingetUninstall -Apps $script:apps -NonInteractive -WhatIf

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            $script:infoMessages | Should -Contain '[DRY-RUN] Group Policy on this PC blocks winget (see above). A real run would stop with exit code 2 before removing anything. Without winget this preview cannot tell which apps are installed, so it stops here.'
        }
    }

    Context 'Summary' {
        It 'Opens the grid view only when someone is at the console (non-interactive: <NonInteractive>)' -ForEach @(
            @{ NonInteractive = $true }
            @{ NonInteractive = $false }
        ) {
            $script:nonInteractive = $NonInteractive
            Mock Test-EffectiveNonInteractive { $script:nonInteractive }

            $null = Invoke-WingetUninstall -Apps $script:apps

            $script:gridView['Uninstallation Summary'] | Should -Be (-not $NonInteractive)
        }
    }
}

Describe 'winget-app-uninstall.ps1' {
    BeforeAll {
        # A stand-in module: the entry script's own logic is what is under test here.
        $script:standInModule = @'
function Test-IsAdmin { $env:UNINSTALL_TEST_ADMIN -eq '1' }
function Write-ErrorMessage { param ([string]$Message) Write-Host "ERROR: $Message" }
function Write-Success { param ([string]$Message) Write-Host "SUCCESS: $Message" }
function Write-Info { param ([string]$Message) Write-Host "INFO: $Message" }
function Restart-WithElevation {
    param ([string]$ScriptPath, [string[]]$AdditionalArguments, [string]$ExpectedSha256, [switch]$InPlace, [switch]$NonInteractive)
    Write-Host "RELAUNCH InPlace=$([bool]$InPlace) NonInteractive=$([bool]$NonInteractive)"
    [pscustomobject]@{ Started = $false; ExitCode = 4 }
}
function Invoke-WingetUninstall {
    param ([switch]$WhatIf, [switch]$NonInteractive)
    Write-Host "UNINSTALL WhatIf=$([bool]$WhatIf) NonInteractive=$([bool]$NonInteractive)"
    if ($env:UNINSTALL_TEST_THROW -eq '1') { throw 'unexpected (test)' }
    [int]$env:UNINSTALL_TEST_CODE
}
'@
    }

    It 'Exits with Invoke-WingetUninstall''s code (<Code>) and passes its switches on' -ForEach @(
        @{ Code = 0 }
        @{ Code = 1 }
        @{ Code = 2 }
        @{ Code = 3010 }
    ) {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive "code-$Code") -Overrides $script:standInModule -ScriptArguments @('-NonInteractive') -Environment @{ UNINSTALL_TEST_ADMIN = '1'; UNINSTALL_TEST_CODE = "$Code"; UNINSTALL_TEST_THROW = $null }

        # Off Windows a process exit code keeps only its low 8 bits (3010 arrives as 194).
        $expected = $Code
        if (-not $IsWindows) {
            $expected = $Code -band 0xFF
        }
        $run.ExitCode | Should -Be $expected
        $run.Output | Should -Match 'UNINSTALL WhatIf=False NonInteractive=True'
        $run.Output | Should -Not -Match 'RELAUNCH'
    }

    It 'Exits 5 when the uninstall stops on an unexpected error' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'throws') -Overrides $script:standInModule -Environment @{ UNINSTALL_TEST_ADMIN = '1'; UNINSTALL_TEST_CODE = '0'; UNINSTALL_TEST_THROW = '1' }

        $run.ExitCode | Should -Be 5
        $run.Output | Should -Match 'ERROR: The uninstaller stopped on an unexpected error before it finished: unexpected \(test\)'
    }

    It 'Exits 5, not 0, when the module next to it cannot be loaded (<Case>)' -ForEach @(
        @{ Case = 'no module folder'; NoModule = $true; Module = '# not written' }
        @{ Case = 'a module file that fails to load'; NoModule = $false; Module = "throw 'module file broken (test)'" }
    ) {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive "no-module-$NoModule") -Overrides $Module -NoModule:$NoModule -ScriptArguments @('-NonInteractive') -Environment @{ UNINSTALL_TEST_ADMIN = '1'; UNINSTALL_TEST_CODE = '0'; UNINSTALL_TEST_THROW = $null }

        $run.ExitCode | Should -Be 5
        $run.Output | Should -Match 'The uninstaller cannot run: the WingetAppSetup module folder next to it could not be loaded'
        $run.Output | Should -Not -Match 'UNINSTALL '
    }

    It 'Exits 5 when the unexpected-error report itself fails' {
        # A module without Write-ErrorMessage: the catch block's report fails, which used to leave
        # the exit code unset, and `exit $null` is 0.
        $module = $script:standInModule -replace '(?m)^function Write-ErrorMessage .*$', ''
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'report-fails') -Overrides $module -Environment @{ UNINSTALL_TEST_ADMIN = '1'; UNINSTALL_TEST_CODE = '0'; UNINSTALL_TEST_THROW = '1' }

        $run.Output | Should -Match 'UNINSTALL WhatIf=False'
        $run.ExitCode | Should -Be 5
    }

    It 'Asks for elevation with the caller''s -NonInteractive and exits with its code when not elevated' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'not-admin') -Overrides $script:standInModule -ScriptArguments @('-NonInteractive') -Environment @{ UNINSTALL_TEST_ADMIN = '0'; UNINSTALL_TEST_CODE = '0'; UNINSTALL_TEST_THROW = $null }

        $run.ExitCode | Should -Be 4
        $run.Output | Should -Match 'RELAUNCH InPlace=True NonInteractive=True'
        $run.Output | Should -Not -Match 'UNINSTALL '
    }

    It 'Previews in place, without elevating, when not elevated and -WhatIf is given' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'preview') -Overrides $script:standInModule -ScriptArguments @('-WhatIf') -Environment @{ UNINSTALL_TEST_ADMIN = '0'; UNINSTALL_TEST_CODE = '0'; UNINSTALL_TEST_THROW = $null }

        $run.ExitCode | Should -Be 0
        $run.Output | Should -Not -Match 'RELAUNCH'
        $run.Output | Should -Match 'UNINSTALL WhatIf=True NonInteractive=False'
        $run.Output | Should -Match 'INFO: \[DRY-RUN\] A real run needs administrator rights'
    }
}

# The P2-19 scenario end to end: the real winget-app-uninstall.ps1 and the real module, with only
# what would touch the machine replaced. Before this change the script printed 'Skipping: <id>
# (not installed; winget list exit code unavailable)' for every app, removed Winget-AutoUpdate and
# exited 0 when winget could not be started.
Describe 'winget-app-uninstall.ps1 with the real module (P2-19)' {
    BeforeAll {
        $script:moduleOverrides = @'
# Loaded after every module file, so these replace the module's own functions in the child run.
function Test-IsAdmin { $true }
function Get-DefaultAppCatalog { @(@{ name = 'Contoso.AppOne' }, @{ name = 'Contoso.AppTwo' }) }
function Get-WingetPolicyBlock {
    if ($env:UNINSTALL_TEST_SCENARIO -eq 'PolicyBlocked') {
        return [pscustomobject]@{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' }
    }
    $null
}
function Test-AndInstallWingetModule { $false }
function Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $false; ErrorCodes = @() } }
function Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'present (test)' } }
function Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $false; Succeeded = $false; ErrorCodes = @() } }
function Invoke-WebRequest { throw 'no network in this test' }
function Add-AppxPackage { throw 'no App Installer in this test' }
function Get-ProcessUserName { 'CONTOSO\admin-tech' }
function Get-InteractiveSessionUserName { $null }
function Start-Sleep { param ([int]$Seconds) }
function Test-CanUseGridView { $false }
function Remove-LegacyScheduledUpdates { param ([switch]$WhatIf) $false }
function Test-WauInstalled { $true }
function Uninstall-WingetAutoUpdate { param ([switch]$WhatIf) Write-Host 'FAKE: Winget-AutoUpdate removed'; @{ Succeeded = $true; RestartRequired = $false } }
function Invoke-WingetProcess {
    param ([string[]]$ArgumentList, [int]$TimeoutSeconds, [string]$WingetPath, [string]$Echo = 'Live', [AllowNull()][AllowEmptyString()][string]$LogDirectory)
    $arguments = @($ArgumentList)
    Write-Host ('FAKE: winget {0}' -f ($arguments -join ' '))
    $result = [pscustomobject]@{ FilePath = 'winget'; Arguments = ''; ExitCode = $null; TimedOut = $false; LaunchFailed = $false; LaunchErrorCode = $null; LaunchError = $null; LaunchException = $null; Output = @(); StandardOutput = @(); StandardError = @(); DurationSeconds = 0; LogPath = $null }
    $scenario = $env:UNINSTALL_TEST_SCENARIO
    if ($scenario -eq 'NoWinget' -or ($scenario -eq 'ListCannotLaunch' -and $arguments[0] -ne '--version')) {
        $result.LaunchFailed = $true
        $result.LaunchErrorCode = 2
        $result.LaunchError = 'The system cannot find the file specified.'
        return $result
    }
    $result.ExitCode = 0
    if ($arguments[0] -eq '--version') {
        $result.StandardOutput = @('v1.12.350')
    }
    elseif ($arguments[0] -eq 'list') {
        $result.StandardOutput = @(('{0}  1.0  winget' -f $arguments[[array]::IndexOf($arguments, '--id') + 1]))
    }
    elseif ($arguments[0] -eq 'uninstall' -and $scenario -eq 'RestartToFinish') {
        # winget's real result for an MSI whose `msiexec /x` returned 3010.
        $result.ExitCode = -1978335184
        $result.StandardOutput = @('Starting package uninstall...', 'Uninstall failed with exit code: 3010')
    }
    $result.Output = $result.StandardOutput
    return $result
}
'@
        $script:moduleSource = Join-Path $script:RepoRoot 'WingetAppSetup'
    }

    It 'Exits 2 and removes nothing when winget cannot be started for the account' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'no-winget') -ModuleSource $script:moduleSource -Overrides $script:moduleOverrides -Environment @{ UNINSTALL_TEST_SCENARIO = 'NoWinget'; WINGET_APP_SETUP_NONINTERACTIVE = '1' }

        $run.ExitCode | Should -Be 2
        $run.Output | Should -Not -Match 'FAKE: Winget-AutoUpdate removed'
        $run.Output | Should -Not -Match 'Skipping:'
        $run.Output | Should -Not -Match 'FAKE: winget (list|uninstall)'
        $run.Output | Should -Match 'winget cannot be started for this account, so nothing was uninstalled'
    }

    It 'Exits 2, runs no winget and keeps Winget-AutoUpdate when Group Policy turns winget off (review finding P3-30)' {
        # The real Initialize-Winget reads the policy before it starts winget at all.
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'policy-blocked') -ModuleSource $script:moduleSource -Overrides $script:moduleOverrides -Environment @{ UNINSTALL_TEST_SCENARIO = 'PolicyBlocked'; WINGET_APP_SETUP_NONINTERACTIVE = '1' }

        $run.ExitCode | Should -Be 2
        $run.Output | Should -Not -Match 'FAKE: winget'
        $run.Output | Should -Not -Match 'FAKE: Winget-AutoUpdate removed'
        $run.Output | Should -Not -Match 'Skipping:'
        $run.Output | Should -Match "Group Policy on this PC blocks winget: 'Enable App Installer' is Disabled"
        $run.Output | Should -Match ([regex]::Escape('Group Policy on this PC blocks winget (see above), so nothing was uninstalled'))
    }

    It 'Exits 1 and keeps Winget-AutoUpdate when winget starts but cannot check the apps' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'list-cannot-launch') -ModuleSource $script:moduleSource -Overrides $script:moduleOverrides -Environment @{ UNINSTALL_TEST_SCENARIO = 'ListCannotLaunch'; WINGET_APP_SETUP_NONINTERACTIVE = '1' }

        $run.ExitCode | Should -Be 1
        $run.Output | Should -Not -Match 'FAKE: Winget-AutoUpdate removed'
        $run.Output | Should -Not -Match 'Skipping:'
        $run.Output | Should -Match ([regex]::Escape('Failed to uninstall: Contoso.AppOne (could not check whether it is installed: winget could not be started (The system cannot find the file specified)).'))
    }

    It 'Exits 0 after removing every app and then Winget-AutoUpdate when winget works' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'healthy') -ModuleSource $script:moduleSource -Overrides $script:moduleOverrides -Environment @{ UNINSTALL_TEST_SCENARIO = 'Healthy'; WINGET_APP_SETUP_NONINTERACTIVE = '1' }

        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'FAKE: winget uninstall --exact --id Contoso\.AppOne --silent --accept-source-agreements --disable-interactivity'
        $run.Output | Should -Match 'FAKE: winget uninstall --exact --id Contoso\.AppTwo'
        $run.Output.IndexOf('FAKE: winget uninstall --exact --id Contoso.AppTwo') | Should -BeLessThan $run.Output.IndexOf('FAKE: Winget-AutoUpdate removed')
    }

    It 'Exits 3010 when the apps are removed and a restart finishes removing them' {
        $run = Invoke-TestUninstallerScript -Root (Join-Path $TestDrive 'restart') -ModuleSource $script:moduleSource -Overrides $script:moduleOverrides -Environment @{ UNINSTALL_TEST_SCENARIO = 'RestartToFinish'; WINGET_APP_SETUP_NONINTERACTIVE = '1' }

        # Off Windows a process exit code keeps only its low 8 bits (3010 arrives as 194).
        $expected = 3010
        if (-not $IsWindows) {
            $expected = 3010 -band 0xFF
        }
        $run.ExitCode | Should -Be $expected
        $run.Output | Should -Match 'FAKE: Winget-AutoUpdate removed'
        $run.Output | Should -Match ([regex]::Escape('Restart: REQUIRED to finish removing Contoso.AppOne, Contoso.AppTwo.'))
        $run.Output | Should -Not -Match 'Failed to uninstall'
    }
}
