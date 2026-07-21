# Spec: Pre-elevation `winget source update` needs the same timeout guard as its sibling probe

## Goal
The pre-elevation `winget source update` call in `Invoke-WingetInstall` can no longer hang the
entire run indefinitely on a corrupted/unreachable winget source — it must time out and continue,
the same way the module's own `Invoke-WingetSourceProbe` already does for the identical command.

## Context
`WingetAppSetup/Public/Install.ps1` (currently line 73, inside `Invoke-WingetInstall`, before
elevation) runs:

```powershell
Start-Process -FilePath 'winget' -ArgumentList 'source', 'update', '--name', 'winget', '--disable-interactivity' -Wait -NoNewWindow
```

with no `-PassThru`, no exit-code check, and — the actual bug — no timeout. `-Wait` blocks the
calling thread until the child process exits on its own, however long that takes.

`WingetAppSetup/Private/WingetBootstrap.ps1`'s `Invoke-WingetSourceProbe` (lines 27-67) runs the
**exact same command** (`winget source update --name winget --disable-interactivity`) but wraps it
with `-PassThru`, redirected output, and a `$TimeoutSeconds` (default 120) `WaitForExit`/`Kill()`
guard, specifically because — per this repo's own history (issue #177, and the general
timeout-guard pattern documented across `CHANGELOG.md` for issue #120 and elsewhere) — this class
of winget call is known to hang.

Verified via direct read and an independent verifier agent (CONFIRMED, full-repo review,
2026-07-16): no `$ErrorActionPreference = 'Stop'` is set anywhere in this scope (confirmed by
grepping the whole repo), so a "winget not found" failure at this call site is a non-terminating
error that lets execution continue into `Test-AndInstallWinget` (which installs winget when
missing) — that part is low severity and out of scope here. The **timeout gap** is the real,
higher-severity issue: on a healthy winget source this call returns quickly, but on a broken one it
can block the whole script forever, before elevation, before any of the timeout-guarded checks
later in the pipeline ever run.

This repo's convention: the module is the source of truth; `winget-app-install.ps1` is generated
and must never be hand-edited. Tests use Pester 6.x, mock every external call (including
`Start-Process`), and use unconditional `Mock` in `BeforeEach`.

## Deliverable
A code change to `WingetAppSetup/Public/Install.ps1`'s `Invoke-WingetInstall` (the call currently at
line 73), reusing or mirroring `Invoke-WingetSourceProbe`'s timeout-guard pattern from
`WingetAppSetup/Private/WingetBootstrap.ps1`, plus new/updated Pester coverage, a regenerated
`winget-app-install.ps1`, and a `CHANGELOG.md` entry.

## Requirements
- R1. The pre-elevation `winget source update` call must have a bounded wait: if the process has
  not exited within a fixed timeout (recommend reusing `Invoke-WingetSourceProbe`'s existing
  120-second default rather than inventing a new number), the process is killed and execution
  continues rather than blocking forever. [verify: unit test mocks the underlying process object
  such that `WaitForExit` returns `$false` (simulating a hang), and asserts the function returns /
  continues within the test's synchronous execution rather than blocking, and that a `Kill()`-style
  call was invoked]
- R2. On a normal (non-hanging) run, behavior must be observably unchanged: the call still runs
  before elevation, still updates the winget source in the user's context, still uses
  `--disable-interactivity`. [verify: existing/updated test asserts the winget command is invoked
  with the same arguments as before the change]
- R3. Prefer reusing `Invoke-WingetSourceProbe` directly (it already does exactly this, in the same
  module) over duplicating the timeout-guard logic a third time; if reuse isn't feasible, the
  reviewer must be able to see why in code comments. [verify: code review — either the call site
  now calls `Invoke-WingetSourceProbe`, or a comment explains why a separate implementation was
  necessary]
- R4. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R5. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not change `Invoke-WingetSourceProbe` itself unless R3 requires extracting a shared helper —
  if you do extract one, keep its behavior identical to the current `Invoke-WingetSourceProbe`.
- Do not add retry/backoff logic here — a timeout-and-continue is sufficient; this call was already
  best-effort (its exit code was never checked before this fix either).
- Do not change any other winget call site in the module.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- Match the existing timeout-guard idiom already used in this module (`Start-Process -PassThru`,
  `WaitForExit(ms)`, `Kill()` in a try/catch) rather than inventing a new pattern.
- Tests must mock all external process calls per repo CLAUDE.md.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff a test proves a simulated hang on this call site is bounded (killed after
  timeout) rather than blocking indefinitely.
- C2 (from R2): PASS iff a normal-path test proves the same winget arguments are still passed.
- C3 (from R3): PASS iff the change reuses `Invoke-WingetSourceProbe` or documents why not.
- C4 (from R4): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C5 (from R5): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
