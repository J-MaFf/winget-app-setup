# Spec: `-WhatIf` must preview instead of demanding elevation on the IEX/remote path

## Goal
A non-admin user running the documented one-liner (`irm <url> | iex`) with `-WhatIf` gets a dry-run
preview, the same way a non-admin local-file run already does — instead of an unconditional
"requires administrator privileges" failure that never looks at `-WhatIf` at all.

## Context
`Invoke-WingetInstall` (`WingetAppSetup/Public/Install.ps1`) has two branches for a non-admin
session, gated on `Test-IsRunningLocally` (`WingetAppSetup/Private/Elevation.ps1:10`, which returns
`$false` whenever `$PSScriptRoot` is empty or invalid — the case for every `irm | iex` run, since
there is no on-disk script file).

- **Local-file branch** (`Install.ps1:79-114`): explicitly checks `$WhatIf` first (line 84). When
  true, it prints `'[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview
  in the current (non-elevated) session; no system changes will be made.'` and falls through
  without elevating or exiting.
- **IEX/remote branch** (`Install.ps1:116-124`, the `else` of the `if (Test-IsRunningLocally)` at
  line 79): never references `$WhatIf` at all. It unconditionally prints "This script requires
  administrator privileges" / "Auto-elevation is unavailable when running through IEX/remote
  execution", sleeps 5 seconds, and calls `Exit 1`.

Verified via direct read and an independent verifier agent (both CONFIRMED, full-repo review,
2026-07-16): no earlier guard in `Invoke-WingetInstall` or in `build/fragments/tail.ps1` (which
just forwards `-WhatIf:$WhatIf` into the function) intercepts this combination before it reaches
the `else` branch. No existing test drives non-admin + `Test-IsRunningLocally` false + `-WhatIf`
true: `tests/EntryPoint.Tests.ps1`'s only real (non-mocked) IEX/non-admin test omits `-WhatIf`, and
every `Invoke-WingetInstall` `-WhatIf` test in `tests/Install.Tests.ps1` mocks `Test-IsRunningLocally`
to always return `$true`.

This repo's convention: the module (`WingetAppSetup/Public/*.ps1`) is the single source of truth;
`winget-app-install.ps1` is generated from it via `build/Build-WingetInstallScript.ps1` and must
never be hand-edited. Tests use Pester 6.x (`Import-Module Pester -MinimumVersion 6.0.0
-MaximumVersion 6.999.999`), mock every external call, and use unconditional `Mock` in `BeforeEach`
rather than conditional stubs.

## Deliverable
A code change to `WingetAppSetup/Public/Install.ps1`'s `Invoke-WingetInstall` function (the `else`
branch at what is currently lines 116-124), plus new/updated Pester coverage in
`tests/Install.Tests.ps1`, plus a regenerated `winget-app-install.ps1` (via
`build/Build-WingetInstallScript.ps1`) and a `CHANGELOG.md` entry under `[Unreleased]`.

## Requirements
- R1. When `$isAdmin` is false, `Test-IsRunningLocally` is false, and `$WhatIf` is `$true`, the
  function must NOT call `Exit` and must NOT print the "requires administrator privileges" /
  "Auto-elevation is unavailable" messages. [verify: unit test mocks `Test-IsRunningLocally` to
  return `$false`, calls `Invoke-WingetInstall -WhatIf`, and asserts the function returns normally
  (no `Exit` invoked) and `Write-ErrorMessage`/`Write-Info` are never called with those exact
  strings]
- R2. In that same scenario, the function must print a dry-run message analogous to the
  local-file branch's, explicitly stating that elevation would be required for a real run and that
  no system changes are being made. [verify: unit test asserts `Write-Info` (or equivalent) is
  invoked with a message matching `-WhatIf` / `[DRY-RUN]` conventions already used elsewhere in
  this function, e.g. `-match '\[DRY-RUN\]'`]
- R3. The pre-existing behavior for `$WhatIf` false in this same non-admin/IEX combination must be
  unchanged: still prints the two error/info messages, still sleeps, still exits 1. [verify:
  existing test `tests/EntryPoint.Tests.ps1`'s "Should exit with code 1 and show remote elevation
  guidance" test (or its Install.Tests.ps1 equivalent) continues to pass unmodified]
- R4. The pre-existing local-file `-WhatIf` behavior (lines 79-114) must be unchanged. [verify:
  existing Pester tests covering that branch continue to pass unmodified]
- R5. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0, output "up to date"]
- R6. The full Pester suite passes on Pester 6.x with zero new failures and no reduction in the
  pre-existing skip count (currently 3). [verify: `Invoke-Pester ./tests`, compare pass/fail/skip
  counts before and after]

## Out of scope
- Do not change the local-file (`Test-IsRunningLocally` true) branch's behavior or messages.
- Do not change what happens when `$WhatIf` is false on the IEX/remote path (R3 pins this).
- Do not add a mechanism to actually preview installs differently on the IEX path than the
  local-file path already does — reuse the exact same dry-run messaging convention.
- Do not touch elevation, UAC, or any other prompt-related behavior — this is scoped purely to the
  `$WhatIf` gate on this one branch.

## Constraints
- PowerShell 7+ syntax; edit the module source only, never hand-edit `winget-app-install.ps1`.
- Follow this repo's existing message-formatting conventions (`Write-Info`, `[DRY-RUN]` prefix)
  rather than inventing new ones.
- Tests must mock all external calls (no real `Exit`, no real elevation) per repo CLAUDE.md.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change (repo convention: they always change together).

## Acceptance rubric
- C1 (from R1): PASS iff a test proves `Invoke-WingetInstall -WhatIf` with `Test-IsRunningLocally`
  mocked false does not exit and does not print the admin-required messages.
- C2 (from R2): PASS iff that same scenario prints a `[DRY-RUN]`-style preview message.
- C3 (from R3): PASS iff the non-`WhatIf` IEX/remote exit-1 behavior is provably unchanged (test
  still passes without modification to its assertions).
- C4 (from R4): PASS iff the local-file `-WhatIf` branch's tests still pass unmodified.
- C5 (from R5): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C6 (from R6): PASS iff the full Pester suite shows 0 new failures and the same skip count as
  before the change.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
