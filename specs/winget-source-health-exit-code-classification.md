# Spec: Reduce locale-fragile prose matching in winget source-corruption detection

## Goal
`Test-WingetSourceHealth`'s corruption detection relies less on matching English prose from winget
output and more on the numeric exit code / HRESULT signal this module already uses everywhere else,
so a winget CLI locale or wording change is less likely to silently break corruption detection.

## Context
`WingetAppSetup/Private/WingetBootstrap.ps1`'s `Test-WingetSourceHealth` (function starts line 91)
classifies a `winget search` result as functional or corrupted at line 117:

```powershell
if ($searchOutput -match '0x8a150|failed when opening|data required' -or $searchExitCode -ne 0) {
```

Verified via an independent verifier agent (PLAUSIBLE — real fragility, but the initial framing was
corrected, full-repo review, 2026-07-16): this is NOT prose-matching *instead of* exit-code
checking — the same line already ORs in `$searchExitCode -ne 0`, so any nonzero exit already fails
the check regardless of text. The prose match supplements the exit-code check specifically because
(per the codebase's own hard-won history with flaky winget exit codes, documented across issues
#150/#172/#174/#175/#177) winget can reportedly emit a corruption signature like `0x8a15000f`
("Failed when opening source(s)... Data required by the source is missing") while still returning
exit code 0 in some observed cases.

The verifier found a viable numeric alternative for at least part of the pattern:
`0x8a15000f` as a signed Int32 HRESULT is `-1978335217` — directly adjacent to the other HRESULT
constants this module already checks numerically elsewhere (`-1978335216`, `-1978335162` in
`WingetCore.ps1`). The two literal English phrases (`'failed when opening'`, `'data required'`)
are the genuinely locale-fragile part, and — unlike a similar function in
`winget-app-uninstall.ps1:48` which has an explicit "winget output is locale-dependent (issue
#180)" comment — this function has no such acknowledgment. `tests/WingetBootstrap.Tests.ps1:58-76`
only exercises the corrupted-text case paired with a nonzero exit code, never isolating the prose
match's independent effect (i.e. corrupted text + exit code 0, which is the scenario the prose
match exists to catch).

## Deliverable
A code change to `Test-WingetSourceHealth`'s corruption check (`WingetAppSetup/Private/
WingetBootstrap.ps1`, line 117) that checks the `0x8a15000f` case via its numeric exit code
(`-1978335217`) where winget actually returns it, while keeping — and clearly commenting as
locale-fragile-but-necessary — a reduced prose-matching fallback only for the specific
scenario this exists to catch (exit code 0 despite corrupted output), plus new/updated Pester
coverage isolating that scenario, a regenerated `winget-app-install.ps1`, and a `CHANGELOG.md`
entry.

## Requirements
- R1. When `winget search` returns a nonzero exit code that corresponds to the known
  `0x8a15000f`/`-1978335217` corruption signature, the function must classify the source as
  not-functional via the numeric exit code check, without needing the prose match to fire.
  [verify: unit test mocks `$LASTEXITCODE` to `-1978335217` with output text NOT matching the
  existing prose regex, and asserts `Test-WingetSourceHealth` still reports `Functional = $false`]
- R2. The existing scenario the prose match specifically exists for — corrupted-looking output text
  with exit code 0 — must continue to be caught. [verify: unit test mocks exit code 0 with output
  matching the corruption phrases, asserts `Functional = $false`, isolating this from the
  already-covered "nonzero exit + corrupted text" combination]
- R3. A code comment must explain why prose matching is retained for this one case (winget
  reportedly returns success despite corruption in some versions) and flag it as locale-sensitive,
  mirroring the existing locale-dependency acknowledgment pattern in
  `winget-app-uninstall.ps1:48`. [verify: code review of the comment]
- R4. Existing test coverage in `tests/WingetBootstrap.Tests.ps1` continues to pass; add the new
  isolated test cases from R1/R2 rather than replacing existing ones. [verify: `Invoke-Pester
  ./tests/WingetBootstrap.Tests.ps1`, existing test names all still present and passing]
- R5. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R6. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not remove prose matching entirely — the verifier confirmed at least one real scenario (exit 0
  despite corruption) where text is the only available signal; this spec reduces reliance on prose,
  it does not eliminate it.
- Do not change `Test-WingetSourceHealth`'s two-step (Listed/Functional) structure or its `-Quiet`
  parameter behavior.
- Do not touch the `winget source list` "Listed" check (lines 98-105) — this spec is scoped to the
  "Functional" check only.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- Use the exact numeric constant already verified: `-1978335217` for `0x8a15000f`; do not
  reintroduce it as a magic number without a comment tying it to the hex HRESULT.
- Tests must mock all external winget calls per repo CLAUDE.md.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff a test proves the `-1978335217` exit code alone (no prose match needed)
  correctly reports not-functional.
- C2 (from R2): PASS iff a test proves the exit-0-with-corrupted-text case is still caught.
- C3 (from R3): PASS iff a comment documents the retained prose match's purpose and locale
  sensitivity.
- C4 (from R4): PASS iff all pre-existing `tests/WingetBootstrap.Tests.ps1` tests still pass.
- C5 (from R5): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C6 (from R6): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
