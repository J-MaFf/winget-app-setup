# RunBudget.Tests.ps1
# Tests for WingetAppSetup/Private/RunBudget.ps1 (wgt-gq8.41): the whole run's time budget, from
# -MaxRuntimeMinutes or WINGET_APP_SETUP_MAX_RUNTIME_MINUTES, its deadline across the relaunches,
# and the arguments that carry it to them.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function New-UtcTime {
        param ([string]$Text)
        [DateTime]::SpecifyKind([DateTime]::ParseExact($Text, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture), [System.DateTimeKind]::Utc)
    }
}

Describe 'Resolve-InstallerRunBudget' {
    BeforeEach {
        $script:savedBudgetVariable = $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES
        Remove-Item -Path Env:\WINGET_APP_SETUP_MAX_RUNTIME_MINUTES -ErrorAction SilentlyContinue
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        $script:started = New-UtcTime '2026-10-05T12:00:00Z'
    }

    AfterEach {
        if ($null -eq $script:savedBudgetVariable) {
            Remove-Item -Path Env:\WINGET_APP_SETUP_MAX_RUNTIME_MINUTES -ErrorAction SilentlyContinue
        }
        else {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $script:savedBudgetVariable
        }
    }

    It 'Has no budget when neither the parameter nor the variable sets one (today''s behaviour)' {
        $budget = Resolve-InstallerRunBudget -StartedUtc $script:started

        $budget.Minutes | Should -Be 0
        $budget.DeadlineUtc | Should -BeNullOrEmpty
        $script:warnings | Should -HaveCount 0
    }

    It 'Sets the deadline to the start plus the parameter''s minutes' {
        $budget = Resolve-InstallerRunBudget -MaxRuntimeMinutes 90 -StartedUtc $script:started

        $budget.Minutes | Should -Be 90
        $budget.DeadlineUtc | Should -Be (New-UtcTime '2026-10-05T13:30:00Z')
        $budget.DeadlineUtc.Kind | Should -Be 'Utc'
    }

    It 'Reads the variable when the parameter is not given: ''<Value>''' -ForEach @(
        @{ Value = '45'; Minutes = 45 }
        @{ Value = ' 45 '; Minutes = 45 }
        @{ Value = '1440'; Minutes = 1440 }
        @{ Value = '0'; Minutes = 0 }
        @{ Value = ''; Minutes = 0 }
    ) {
        $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $Value

        $budget = Resolve-InstallerRunBudget -StartedUtc $script:started

        $budget.Minutes | Should -Be $Minutes
        $script:warnings | Should -HaveCount 0
    }

    It 'Lets the parameter win over the variable' {
        $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = '45'

        (Resolve-InstallerRunBudget -MaxRuntimeMinutes 20 -StartedUtc $script:started).Minutes | Should -Be 20
    }

    It 'Warns about a variable that is not a whole number from 0 to 1440, and runs without a budget: ''<_>''' -ForEach @('-5', 'abc', '1441', '12.5', '30m', '99999') {
        $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $_

        $budget = Resolve-InstallerRunBudget -StartedUtc $script:started

        $budget.Minutes | Should -Be 0
        $budget.DeadlineUtc | Should -BeNullOrEmpty
        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Be "Ignoring WINGET_APP_SETUP_MAX_RUNTIME_MINUTES='$_': it must be a whole number of minutes from 0 to 1440. This run has no time budget."
    }

    It 'Keeps an earlier deadline a relaunch passed on, so the clock runs from the first start of the run' {
        # The PowerShell 7 run starts 3 minutes after the 5.1 phase that set the deadline.
        $budget = Resolve-InstallerRunBudget -MaxRuntimeMinutes 60 -RunDeadlineUtc '2026-10-05T12:57:00Z' -StartedUtc $script:started

        $budget.DeadlineUtc | Should -Be (New-UtcTime '2026-10-05T12:57:00Z')
        $budget.DeadlineUtc.Kind | Should -Be 'Utc'
        $budget.Minutes | Should -Be 60
    }

    It 'Never lets a passed-on deadline extend the budget' {
        $budget = Resolve-InstallerRunBudget -MaxRuntimeMinutes 60 -RunDeadlineUtc '2026-10-06T00:00:00Z' -StartedUtc $script:started

        $budget.DeadlineUtc | Should -Be (New-UtcTime '2026-10-05T13:00:00Z')
    }

    It 'Ignores a passed-on deadline without a budget' {
        (Resolve-InstallerRunBudget -RunDeadlineUtc '2026-10-05T12:30:00Z' -StartedUtc $script:started).DeadlineUtc | Should -BeNullOrEmpty
    }

    It 'Warns about a passed-on deadline in another form and counts from this start: ''<_>''' -ForEach @('2026-10-05 12:30', 'tomorrow', '2026-10-05T12:30:00+02:00') {
        $budget = Resolve-InstallerRunBudget -MaxRuntimeMinutes 60 -RunDeadlineUtc $_ -StartedUtc $script:started

        $budget.DeadlineUtc | Should -Be (New-UtcTime '2026-10-05T13:00:00Z')
        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -BeLike "Ignoring -RunDeadlineUtc '$_': it is not a time in the form yyyy-MM-ddTHH:mm:ssZ.*"
    }

    It 'Ignores more than 1440 minutes from a caller that skipped the parameter check' {
        $budget = Resolve-InstallerRunBudget -MaxRuntimeMinutes 5000 -StartedUtc $script:started

        $budget.Minutes | Should -Be 0
        $script:warnings | Should -HaveCount 1
    }
}

Describe 'Get-InstallerRunBudgetArgument' {
    It 'Passes nothing on without a budget, so a relaunch keeps today''s command line' {
        @(Get-InstallerRunBudgetArgument -Budget $null) | Should -HaveCount 0
        @(Get-InstallerRunBudgetArgument -Budget ([pscustomobject]@{ Minutes = 0; DeadlineUtc = $null })) | Should -HaveCount 0
    }

    It 'Passes the minutes and the deadline on, in a form the relaunched run reads back' {
        Mock Write-WarningMessage { throw "unexpected warning: $Message" }
        $budget = [pscustomobject]@{ Minutes = 60; DeadlineUtc = (New-UtcTime '2026-10-05T12:57:00Z') }

        $arguments = @(Get-InstallerRunBudgetArgument -Budget $budget)

        $arguments | Should -Be @('-MaxRuntimeMinutes', '60', '-RunDeadlineUtc', '2026-10-05T12:57:00Z')
        # What Restart-WithElevation and Invoke-PowerShell7Bootstrap accept on a command line.
        foreach ($argument in $arguments) {
            $argument | Should -Match '^(?:-[A-Za-z][A-Za-z0-9]*|[0-9][0-9A-Za-z:.-]*)\z'
        }
        $relaunched = Resolve-InstallerRunBudget -MaxRuntimeMinutes ([int]$arguments[1]) -RunDeadlineUtc $arguments[3] -StartedUtc (New-UtcTime '2026-10-05T12:01:00Z')
        $relaunched.DeadlineUtc | Should -Be $budget.DeadlineUtc
    }
}

Describe 'Test-InstallerRunBudgetSpent and Get-InstallerRunBudgetSecondsLeft' {
    BeforeAll {
        $script:budget = [pscustomobject]@{ Minutes = 60; DeadlineUtc = (New-UtcTime '2026-10-05T13:00:00Z') }
    }

    It 'Is never spent without a budget, and has no seconds left to count' {
        Test-InstallerRunBudgetSpent -Budget $null | Should -BeFalse
        Test-InstallerRunBudgetSpent -Budget ([pscustomobject]@{ Minutes = 0; DeadlineUtc = $null }) | Should -BeFalse
        Get-InstallerRunBudgetSecondsLeft -Budget $null | Should -BeNullOrEmpty
    }

    It 'Is spent from the deadline on' {
        Test-InstallerRunBudgetSpent -Budget $script:budget -NowUtc (New-UtcTime '2026-10-05T12:59:59Z') | Should -BeFalse
        Test-InstallerRunBudgetSpent -Budget $script:budget -NowUtc (New-UtcTime '2026-10-05T13:00:00Z') | Should -BeTrue
        Test-InstallerRunBudgetSpent -Budget $script:budget -NowUtc (New-UtcTime '2026-10-05T14:00:00Z') | Should -BeTrue
    }

    It 'Counts the whole seconds left, never fewer than 0' {
        Get-InstallerRunBudgetSecondsLeft -Budget $script:budget -NowUtc (New-UtcTime '2026-10-05T12:50:00Z') | Should -Be 600
        Get-InstallerRunBudgetSecondsLeft -Budget $script:budget -NowUtc (New-UtcTime '2026-10-05T13:10:00Z') | Should -Be 0
    }
}
