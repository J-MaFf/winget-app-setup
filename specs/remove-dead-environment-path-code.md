# Spec: Remove the orphaned PATH-mutation helpers left behind by issue #179

## Goal
`WingetAppSetup/Private/Environment.ps1`'s PATH-mutation functions — dead since the feature that
used them was removed — are deleted, leaving the module with no unused private helpers pretending
to be live code.

## Context
`WingetAppSetup/Public/Install.ps1` (lines 171-174) carries this comment:

> Note: earlier versions added the script's own directory (often Downloads/) to the persistent User
> PATH here for the homegrown updater. The updater is gone (#168) and a user-writable directory on
> the PATH of an elevating account is a hijack surface, so no PATH changes are made anymore (issue
> #179).

`tests/Install.Tests.ps1` (line 66) has a regression assertion,
`$installBody | Should -Not -Match 'Add-ToEnvironmentPath'`, proving the removal from the install
path was deliberate and guarded.

But `WingetAppSetup/Private/Environment.ps1` itself was never cleaned up. It still defines:
`Add-ToEnvironmentPath` (line 116), `Test-PathInEnvironment` (line 158),
`Test-PathListContainsEntry` (line 39), `Get-PersistedEnvironmentPath` (line 67), and
`Set-PersistedEnvironmentPath` (line 89).

Verified via an independent verifier agent (CONFIRMED, full-repo review, 2026-07-16): a repo-wide
grep (excluding `.claude/worktrees/` and `tests/`) for all five function names found zero real
callers anywhere in `WingetAppSetup/Public/`, `build/`, `e2e/`, `winget-app-install.ps1`, or
`winget-app-uninstall.ps1` — only their own internal cross-calls (`Add-ToEnvironmentPath` calling
`Test-PathInEnvironment`, `Test-PathInEnvironment` calling `Get-PersistedEnvironmentPath` and
`Test-PathListContainsEntry`) and their dedicated test file, `tests/Environment.Tests.ps1`. The file
is in `Private/`, so none of these functions are exported via `WingetAppSetup.psd1`'s
`FunctionsToExport` either — there is no external consumer to preserve compatibility for.

## Deliverable
Deletion of the five orphaned functions from `WingetAppSetup/Private/Environment.ps1` (or deletion
of the whole file if nothing else in it is still used — `Get-WindowsBuildNumber` and
`Get-ComputerManufacturer`, lines 1-24, ARE still live and must be preserved, likely by moving them
to a different/renamed file), deletion of their now-pointless dedicated tests, a regenerated
`winget-app-install.ps1`, and a `CHANGELOG.md` entry.

## Requirements
- R1. `Add-ToEnvironmentPath`, `Test-PathInEnvironment`, `Test-PathListContainsEntry`,
  `Get-PersistedEnvironmentPath`, and `Set-PersistedEnvironmentPath` no longer exist anywhere in
  `WingetAppSetup/`. [verify: `Get-Command -Name Add-ToEnvironmentPath -ErrorAction
  SilentlyContinue` (and the other four) returns `$null` after dot-sourcing the module in a test
  session]
- R2. `Get-WindowsBuildNumber` and `Get-ComputerManufacturer` — the two functions in the same file
  that ARE still used (by `Install-PowerShellLatest`'s build-number gate and the catalog's Dell
  Command Update applicability condition, respectively) — continue to work exactly as before,
  regardless of which file they end up living in. [verify: existing tests exercising
  `Get-WindowsBuildNumber` and `Get-ComputerManufacturer` (or their consumers) pass unmodified]
- R3. `tests/Environment.Tests.ps1`'s tests for the five removed functions are deleted; any tests
  in that file for `Get-WindowsBuildNumber`/`Get-ComputerManufacturer` are preserved (moved if the
  file itself is renamed/reorganized). [verify: `Invoke-Pester ./tests` shows no test names
  referencing the five removed functions, and the two retained functions still have test coverage]
- R4. `winget-app-install.ps1` is regenerated (the five functions and their tests disappear from the
  generated artifact and its build-time undefined-reference checks) and `pwsh -File
  ./build/Build-WingetInstallScript.ps1 -Check` passes. [verify: run the command, exit code 0; grep
  the regenerated file for the five removed names — zero hits outside comments/CHANGELOG]
- R5. The full Pester suite passes on Pester 6.x with zero new failures, and the total test count
  decreases by exactly the number of deleted tests (no accidental deletion of unrelated tests).
  [verify: compare `Invoke-Pester ./tests` total test count before and after]

## Out of scope
- Do not remove or alter `Get-WindowsBuildNumber` or `Get-ComputerManufacturer` — only the five
  PATH-mutation functions are dead.
- Do not re-investigate whether the PATH-mutation feature should be restored — issue #179's decision
  to remove it stands; this spec only finishes that cleanup.
- Do not touch `WingetAppSetup/Public/Install.ps1`'s explanatory comment about why no PATH changes
  are made — it remains accurate and useful context.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- If splitting `Get-WindowsBuildNumber`/`Get-ComputerManufacturer` into a new or differently-named
  file, update `WingetAppSetup/WingetAppSetup.psm1`'s loader (if it lists files explicitly) and any
  path references in tests accordingly.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff `Get-Command` for all five removed function names returns `$null` after
  the change.
- C2 (from R2): PASS iff `Get-WindowsBuildNumber`/`Get-ComputerManufacturer` and their consumer
  tests still pass unmodified.
- C3 (from R3): PASS iff no test names reference the five removed functions, and the two retained
  functions keep coverage.
- C4 (from R4): PASS iff the regenerated installer contains zero non-comment references to the five
  removed functions and `-Check` exits 0.
- C5 (from R5): PASS iff the Pester suite shows 0 new failures and a test-count decrease matching
  exactly what was deleted.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
