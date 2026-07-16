# Spec: `Install-PowerShellLatest`'s verification calls need the timeout every other app already gets

## Goal
Verifying whether PowerShell itself installed successfully must be bounded by the same timeout
every other catalog app's verification already uses, so a hung `winget list` during this one app's
check fails into the retry pass instead of blocking the entire run forever.

## Context
`WingetAppSetup/Public/WingetCore.ps1`'s `Test-WingetPackageInstalled` (lines 425-479) takes an
optional `-TimeoutSeconds` (default `0`, line 431). When greater than 0 (lines 434-470), it runs
`winget list` via a timeout-guarded `Start-Process`/`WaitForExit`/`Kill()` pattern. When omitted
(the default), it falls through to lines 472-479: a bare, untimed `winget list ... 2>&1` call with
no way to bound or kill it.

`Install-PowerShellLatest` (same file, lines 669-694) calls `Test-WingetPackageInstalled` twice —
line 682 (MSI path) and line 689 (native-MSIX path) — and **neither call passes
`-TimeoutSeconds`**, so both hit the untimed fallback.

By contrast, `WingetAppSetup/Private/InstallVerification.ps1`'s `Install-AppWithVerification` sets
`$checkTimeoutSeconds = 15` (line 84) and passes it explicitly on both its pre-check (line 86) and
post-verify (line 118) calls — the pipeline every other catalog app's verification goes through.

Verified via direct read and an independent verifier agent (CONFIRMED, full-repo review,
2026-07-16): this is a genuine, real asymmetry — every other verification call in the pipeline is
timeout-guarded; PowerShell's own self-verification is not. A hang here blocks the whole run
instead of failing into the retry pass like any other app would.

This repo's convention: the module is the source of truth; tests use Pester 6.x and mock all
external calls.

## Deliverable
A code change to `WingetAppSetup/Public/WingetCore.ps1`'s `Install-PowerShellLatest` function
(lines 682 and 689), passing an explicit `-TimeoutSeconds` to both `Test-WingetPackageInstalled`
calls, plus new/updated Pester coverage in `tests/WingetCore.Tests.ps1`, a regenerated
`winget-app-install.ps1`, and a `CHANGELOG.md` entry.

## Requirements
- R1. Both calls to `Test-WingetPackageInstalled` inside `Install-PowerShellLatest` (the MSI-path
  call and the native-MSIX-path call) must pass an explicit `-TimeoutSeconds` value greater than 0.
  [verify: unit test mocks `Test-WingetPackageInstalled` and asserts it is invoked with
  `-TimeoutSeconds` bound to a value `-gt 0` on both call paths]
- R2. The timeout value used must match the value already used elsewhere in the pipeline (15
  seconds, per `Install-AppWithVerification`'s `$checkTimeoutSeconds`), or the reviewer must be able
  to see a documented reason for a different value. [verify: code review of the literal/constant
  used; if it differs from 15, a comment explains why]
- R3. Existing behavior when the check completes normally (no hang) must be unchanged — the
  function still returns the same `@{ ExitCode; Installed; Method }` shape it does today. [verify:
  existing tests for `Install-PowerShellLatest`'s return shape continue to pass unmodified]
- R4. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R5. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not change `Test-WingetPackageInstalled` itself — its existing timeout mechanism already works
  correctly; this fix is purely about `Install-PowerShellLatest` passing the parameter.
- Do not change `Install-AppWithVerification` or any other caller of `Test-WingetPackageInstalled`.
- Do not add retry logic beyond what already exists in the surrounding pipeline.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- Tests must mock `Test-WingetPackageInstalled` (or the underlying `Start-Process`) per repo
  CLAUDE.md — never rely on real winget/system state.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff both calls in `Install-PowerShellLatest` pass a `-TimeoutSeconds` value
  greater than 0, provable by a test.
- C2 (from R2): PASS iff the value used is 15 or a documented deviation from 15.
- C3 (from R3): PASS iff existing return-shape tests for `Install-PowerShellLatest` pass unmodified.
- C4 (from R4): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C5 (from R5): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
