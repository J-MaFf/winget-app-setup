# Spec: Retry-pass failure messages must name the actual failed phase, not always "verification"

## Goal
When a retried app fails because its pre-check (`winget list`) timed out, the printed message must
say so — not claim "verification timed out," which misattributes which pipeline phase actually
failed and misleads whoever is reading the output to diagnose it.

## Context
`WingetAppSetup/Public/Install.ps1`'s `Invoke-WingetInstall` has two loops that both convert a
failed `Install-AppWithVerification` outcome into a human-readable message via
`Format-InstallFailureReason`.

**First pass** (lines 245-262):
```powershell
switch ($outcome.FailureReason) {
    'PreCheckTimeout' {
        Write-WarningMessage "Winget list timed out for $($app.name). Marking as failed; it will be retried."
    }
    'VerifyTimeout' {
        Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
    }
    default {
        Write-ErrorMessage "Failed to install: $($app.name) ($failureReason)."
    }
}
```

**Retry pass** (lines 306-313):
```powershell
if ($outcome.FailureReason -in 'PreCheckTimeout', 'VerifyTimeout') {
    Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
}
else {
    Write-ErrorMessage "Retry failed: $appName ($failureReason)."
}
```

Verified via an independent verifier agent (CONFIRMED, full-repo review, 2026-07-16): the first
pass gives `PreCheckTimeout` its own distinct wording; the retry pass collapses `PreCheckTimeout`
and `VerifyTimeout` into one branch, both printing "Verification timed out for retry" — mislabeling
a pre-check timeout as a verification timeout. A user diagnosing a retry failure reads "Verification
timed out" and reasonably concludes the install itself likely succeeded but post-install
verification couldn't confirm it, when the real story (for `PreCheckTimeout`) is that the pre-check
(`winget list`, checking whether the app is already installed) never even completed. This is a
materially misleading attribution, not a cosmetic wording difference.

## Deliverable
A code change to the retry-pass loop in `Invoke-WingetInstall` (`WingetAppSetup/Public/Install.ps1`,
currently lines 306-315) so it distinguishes `PreCheckTimeout` from `VerifyTimeout` the same way the
first pass already does, plus new/updated Pester coverage, a regenerated
`winget-app-install.ps1`, and a `CHANGELOG.md` entry.

## Requirements
- R1. When a retry's `$outcome.FailureReason` is `'PreCheckTimeout'`, the retry pass must print a
  message that names the pre-check/`winget list` phase specifically (not "verification"), analogous
  to the first pass's wording, adapted for "retry" context (e.g. mentioning "retry" the way the
  current retry messages already do). [verify: unit test drives the retry loop with a mocked
  outcome of `FailureReason = 'PreCheckTimeout'` and asserts the printed message text does not say
  "Verification timed out" and does reference the pre-check/list phase]
- R2. When a retry's `$outcome.FailureReason` is `'VerifyTimeout'`, the retry pass must continue to
  print a verification-timeout-specific message — this case is not being changed, only decoupled
  from `PreCheckTimeout`. [verify: unit test drives the retry loop with `FailureReason =
  'VerifyTimeout'` and asserts the existing "Verification timed out for retry" wording (or
  equivalent) is preserved]
- R3. All other `FailureReason` values on retry must continue to fall through to the existing
  generic "Retry failed: ... (reason)" message. [verify: existing tests for the generic retry-failure
  path continue to pass unmodified]
- R4. The `$failedApps` tracking (`@{ Name; Reason }`) must be unaffected — this fix is purely about
  the printed warning/error text, not the data recorded for the summary table. [verify: existing
  summary-table tests pass unmodified]
- R5. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R6. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not change the first-pass loop's messages — they are already correct and are the reference
  behavior this fix aligns the retry pass to.
- Do not change `Format-InstallFailureReason` or the `FailureReason` values themselves.
- Do not change retry counts, backoff, or any other retry-pass logic besides message selection.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- Keep the retry-specific phrasing convention already in use (messages mention "retry" explicitly,
  e.g. "for retry", "Retry failed") rather than copying the first-pass wording verbatim.
- Tests must mock `Install-AppWithVerification`'s outcome per repo CLAUDE.md conventions.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff a test proves a `PreCheckTimeout` retry no longer says "Verification timed
  out" and instead names the pre-check phase.
- C2 (from R2): PASS iff a test proves `VerifyTimeout` retry messaging is unchanged.
- C3 (from R3): PASS iff the generic retry-failure message path is unaffected.
- C4 (from R4): PASS iff the `$failedApps` data shape and summary-table tests are unaffected.
- C5 (from R5): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C6 (from R6): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
