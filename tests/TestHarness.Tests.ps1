# TestHarness.Tests.ps1
# Tests for the suite itself (wgt-gq8.5): every test file loads the module source through
# tests/TestHelpers.ps1, and TestHelpers.ps1 gives Linux/macOS a stand-in for every Windows-only
# command the suite mocks, with the parameters the module passes and the tests filter on. These
# are what let the whole suite run, and mean something, off Windows.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Get-ParsedScript {
        param ([Parameter(Mandatory = $true)][System.IO.FileInfo[]]$File)

        foreach ($item in $File) {
            $tokens = $null
            $parseErrors = $null
            [pscustomobject]@{
                Name = $item.Name
                Ast  = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$tokens, [ref]$parseErrors)
            }
        }
    }

    function Get-CommandAst {
        param ([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast)

        $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    }

    # The command a `Mock <name>`, `Mock -CommandName <name>` or `Should -Invoke <name>` call
    # targets, plus that call's -ParameterFilter block (or $null).
    function Get-MockTarget {
        param ([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$Command)

        $elements = $Command.CommandElements
        $nameIndex = $null
        switch ($Command.GetCommandName()) {
            'Mock' {
                $nameIndex = 1
                if ($elements.Count -gt 2 -and $elements[1] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[1].ParameterName -eq 'CommandName') {
                    $nameIndex = 2
                }
            }
            'Should' {
                for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                    if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Invoke') {
                        $nameIndex = $i + 1
                        break
                    }
                }
            }
        }
        if ($null -eq $nameIndex -or $nameIndex -ge $elements.Count -or $elements[$nameIndex] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return
        }

        $filter = $null
        for ($i = 1; $i -lt $elements.Count - 1; $i++) {
            if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'ParameterFilter' -and
                $elements[$i + 1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $filter = $elements[$i + 1]
                break
            }
        }

        [pscustomobject]@{
            Name   = $elements[$nameIndex].Value
            Filter = $filter
            Line   = $Command.Extent.StartLineNumber
        }
    }

    # A native executable (winget, powershell.exe), real or stand-in, takes its arguments as $args.
    function Test-TakesArgsOnly {
        param ([Parameter(Mandatory = $true)][System.Management.Automation.CommandInfo]$Command)

        $Command.CommandType -eq [System.Management.Automation.CommandTypes]::Application -or
        $Command.Name -in $script:WindowsOnlyNativeCommandNames
    }

    $script:TestFiles = @(Get-ParsedScript -File (Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1'))
    $script:ModuleFiles = @(Get-ParsedScript -File (Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Private'), (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1'))
}

Describe 'Test harness (tests/TestHelpers.ps1, wgt-gq8.5)' {
    It 'never dot-sources the generated installer into a test file' {
        # Dot-sourcing winget-app-install.ps1 re-declares every function from the GENERATED copy
        # over the module source TestHelpers.ps1 loaded, so the tests exercise whatever was last
        # built instead of the code being edited (CLAUDE.md, Testing).
        $offenders = foreach ($file in $script:TestFiles) {
            foreach ($command in Get-CommandAst -Ast $file.Ast) {
                if ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
                    $command.CommandElements[0].Extent.Text -match 'InstallerScriptPath|winget-app-install') {
                    '{0}:{1}' -f $file.Name, $command.Extent.StartLineNumber
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because 'test files load the module through TestHelpers.ps1, never the generated installer'
    }

    It 'can resolve every command the suite mocks, on this platform' {
        # Pester refuses to mock a command that does not exist. A Windows-only command mocked
        # without a stand-in in TestHelpers.ps1 fails every test that mocks it on Linux/macOS.
        $definedInTests = @(foreach ($file in $script:TestFiles) {
                $file.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                    ForEach-Object { $_.Name -replace '^(global|script|local|private):', '' }
            })
        $targets = foreach ($file in $script:TestFiles) {
            foreach ($command in Get-CommandAst -Ast $file.Ast) {
                Get-MockTarget -Command $command
            }
        }
        $targetNames = @($targets | ForEach-Object { $_.Name } | Sort-Object -Unique)

        $unresolved = $targetNames | Where-Object {
            $_ -notin $definedInTests -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }

        $targetNames | Should -Contain 'Get-AppxPackage' -Because 'the scan must find the mocks it guards'
        $unresolved | Should -BeNullOrEmpty -Because 'tests/TestHelpers.ps1 must give every mocked Windows-only command a stand-in'
    }

    It 'accepts every parameter the module passes to a Windows-only command' {
        # A mock copies the parameters of the command it replaces; a parameter the stand-in lacks
        # would make the module's call fail to bind before the mock body runs.
        $script:WindowsOnlyCommandNames | Should -Contain 'Get-AppxPackage' -Because 'TestHelpers.ps1 lists the Windows-only commands it stands in for'

        $missing = foreach ($file in $script:ModuleFiles) {
            foreach ($command in Get-CommandAst -Ast $file.Ast) {
                $name = $command.GetCommandName()
                if ($name -notin $script:WindowsOnlyCommandNames) {
                    continue
                }
                $resolved = Get-Command -Name $name | Select-Object -First 1
                if (Test-TakesArgsOnly -Command $resolved) {
                    continue
                }
                $accepted = @($resolved.Parameters.Keys) + @($resolved.Parameters.Values | ForEach-Object { $_.Aliases })
                foreach ($parameter in $command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
                    if ($parameter.ParameterName -notin $accepted) {
                        '{0}:{1} {2} -{3}' -f $file.Name, $command.Extent.StartLineNumber, $name, $parameter.ParameterName
                    }
                }
            }
        }

        $missing | Should -BeNullOrEmpty
    }

    It 'declares every parameter a -ParameterFilter on a Windows-only command reads' {
        # A filter reads the mocked call's parameters as variables ($Name, $AllUsers, ...). If the
        # command does not declare one, the variable is $null and the filter silently never matches.
        # Variables a test file assigns itself are its own locals, not parameters, so they are skipped.
        $script:WindowsOnlyCommandNames | Should -Contain 'Get-AppxPackage' -Because 'TestHelpers.ps1 lists the Windows-only commands it stands in for'

        $automatic = @('args', 'input', 'true', 'false', 'null', '_', 'PSItem', 'TestDrive')
        $undeclared = foreach ($file in $script:TestFiles) {
            $assigned = @($file.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                    ForEach-Object { $_.Left.Find({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) } |
                    Where-Object { $_ } |
                    ForEach-Object { $_.VariablePath.UserPath })
            foreach ($command in Get-CommandAst -Ast $file.Ast) {
                $target = Get-MockTarget -Command $command
                if (-not $target -or -not $target.Filter -or $target.Name -notin $script:WindowsOnlyCommandNames) {
                    continue
                }
                $resolved = Get-Command -Name $target.Name | Select-Object -First 1
                if (Test-TakesArgsOnly -Command $resolved) {
                    continue
                }
                $accepted = @($resolved.Parameters.Keys) + @($resolved.Parameters.Values | ForEach-Object { $_.Aliases })
                $variables = $target.Filter.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                    Where-Object { $_.VariablePath.IsUnscopedVariable } |
                    ForEach-Object { $_.VariablePath.UserPath } |
                    Sort-Object -Unique
                foreach ($variable in $variables) {
                    if ($variable -in $automatic -or $variable -in $assigned) {
                        continue
                    }
                    if ($variable -notin $accepted) {
                        '{0}:{1} {2} has no -{3}' -f $file.Name, $target.Line, $target.Name, $variable
                    }
                }
            }
        }

        $undeclared | Should -BeNullOrEmpty
    }

    It 'stands in only for missing commands, and an unmocked stand-in fails like the missing command' {
        $script:WindowsOnlyCommandNames | Should -Contain 'Get-AppxPackage' -Because 'TestHelpers.ps1 lists the Windows-only commands it stands in for'

        foreach ($name in $script:WindowsOnlyCommandNames) {
            if ($name -in $script:WindowsOnlyCommandStandIns) {
                Get-Command -Name $name -CommandType Cmdlet, Application, ExternalScript -ErrorAction SilentlyContinue |
                    Should -BeNullOrEmpty -Because "a stand-in must never shadow a real $name"
                { & $name } | Should -Throw -ExceptionType ([System.Management.Automation.CommandNotFoundException])
            }
            else {
                "$((Get-Command -Name $name | Select-Object -First 1).Definition)" |
                    Should -Not -Match 'defines this stand-in' -Because "$name exists here, so tests must mock the real command"
            }
        }
    }
}
