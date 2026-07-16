# Spec: Consolidate the triplicated admin-check into one shared helper

## Goal
The `IsInRole('Administrator')` check — currently copy-pasted in three files with already-diverged
failure behavior — becomes one shared function that every call site uses, so a future change to
how admin-detection failure is handled only has to be made once.

## Context
The identical expression
`([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')`
appears in three places:

- `WingetAppSetup/Public/Install.ps1:66` — `$isAdmin = (...)`, no try/catch.
- `winget-app-uninstall.ps1:15` — inline inside an `If (-NOT (...))`, no try/catch, recomputed
  rather than stored in a variable.
- `WingetAppSetup/Private/PowerShell7Bootstrap.ps1:182-187` — wrapped: `$isAdmin = $true` set first,
  then `try { $isAdmin = (...) } catch { }`, with a comment explaining the try/catch exists "so the
  unit tests stay runnable on non-Windows hosts."

Verified via an independent verifier agent (CONFIRMED, full-repo review, 2026-07-16): these three
copies have already behaviorally diverged — `PowerShell7Bootstrap.ps1`'s copy fails safe (defaults
to admin, warns) if `GetCurrent()`/`IsInRole` ever throws; the other two would let an unhandled
exception propagate. The verifier notes this divergence's real-world trigger (an exotic restricted
token or non-interactive service context) is edge-case rather than commonly observed on end-user
Windows machines — so practical risk today is low, but the inconsistency is real and the module
already has a purpose-built place for this: `WingetAppSetup/Public/Elevation.ps1`'s own
file-header comment says it exists specifically "so `winget-app-uninstall.ps1` doesn't hand-roll
its own" elevation logic — yet it currently holds only `Restart-WithElevation`, not the admin check
itself.

## Deliverable
A new shared function (e.g. `Test-IsAdmin`) added to `WingetAppSetup/Public/Elevation.ps1` (or
`WingetAppSetup/Private/Elevation.ps1`, whichever better matches the module's public/private
boundary for this — `winget-app-uninstall.ps1` only imports exported/Public functions via the
`.psd1`, so if `winget-app-uninstall.ps1` needs to call it directly, it must be Public), with all
three existing call sites updated to use it, plus new/updated Pester coverage, a regenerated
`winget-app-install.ps1`, and a `CHANGELOG.md` entry.

## Requirements
- R1. A single function encapsulates the admin-check, including the defensive try/catch behavior
  (fail-safe-as-admin-with-warning on unexpected exception) that `PowerShell7Bootstrap.ps1`
  currently has and the other two call sites lack. [verify: unit test mocks
  `[Security.Principal.WindowsIdentity]::GetCurrent()` (or the function's internal call to it) to
  throw, and asserts the shared function returns `$true` rather than propagating the exception —
  matching today's `PowerShell7Bootstrap.ps1` behavior, now applied everywhere]
- R2. `WingetAppSetup/Public/Install.ps1`, `WingetAppSetup/Private/PowerShell7Bootstrap.ps1`, and
  `winget-app-uninstall.ps1` all call the new shared function instead of the inline expression.
  [verify: `Grep` the repo for the literal `IsInRole` expression outside the new shared function's
  own definition — zero hits]
- R3. Existing observable behavior at each of the three call sites is unchanged on the non-exception
  path (an actual admin session is still detected as admin; a non-admin session is still detected
  as non-admin). [verify: existing tests exercising elevation/admin-detection at all three call
  sites pass unmodified or with only mechanical updates (e.g. mocking the new function name instead
  of the raw expression)]
- R4. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R5. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not change what "admin" means or add new elevation logic — this is purely consolidating
  existing, identical detection logic.
- Do not change `Restart-WithElevation` or any other function already in `Elevation.ps1`.
- Do not add the defensive try/catch behavior change (R1) selectively to only some call sites —
  if consolidating, all three get the same (safer) behavior.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- The new function must be usable both from the module (`Install.ps1`, private
  `PowerShell7Bootstrap.ps1`) and from `winget-app-uninstall.ps1`, which imports only via the
  `.psd1` — this determines whether the function must be Public or can stay Private with
  `winget-app-uninstall.ps1` gaining its own thin wrapper.
- Tests must mock the underlying `.NET` calls per repo CLAUDE.md — never rely on the actual
  admin/non-admin state of the machine running the test.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff a test proves the shared function fails safe (returns `$true`, no
  exception) when the underlying `.NET` call throws.
- C2 (from R2): PASS iff a repo-wide search for the raw `IsInRole` expression finds it only inside
  the new shared function's definition.
- C3 (from R3): PASS iff existing admin-detection tests at all three call sites still pass (updated
  mechanically if needed).
- C4 (from R4): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C5 (from R5): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
