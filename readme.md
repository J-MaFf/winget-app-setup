# Winget App Setup

A one-line guide for running the installer.

## Run the installer

> **Requires PowerShell 7+ (`pwsh`).** Run the commands below from a `pwsh` prompt — not the
> built-in Windows PowerShell 5.1 (`powershell.exe`). Under 5.1 the installer prints a short
> message and exits without changing anything. If you only have Windows PowerShell, install
> PowerShell 7 first (`winget install Microsoft.PowerShell`) or prefix the one-liner with
> `pwsh -Command "..."`.

From the repository root, execute (after cloning):

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1
```

No download/clone needed (one-line-run, from a `pwsh` prompt):

```powershell
Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex
```

Or, from a Windows PowerShell 5.1 prompt, hand the one-liner to `pwsh`:

```powershell
pwsh -Command "irm 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1' | iex"
```

The script will trust the required Winget sources, elevate if necessary, and install or update the curated app list. Repeat step 1 anytime you open a new PowerShell window before running it.

## App catalog

The curated app list is `Get-DefaultAppCatalog` (`WingetAppSetup/Public/AppCatalog.ps1`) — the
single source of truth shared by the installer and `winget-app-uninstall.ps1`. Entries may
declare an optional applicability **condition** (a scriptblock, with a human-readable
`conditionDescription`), evaluated before any winget call: an app whose condition is falsy on
the current machine is reported as `Skipping: <id> (not applicable: <reason>)` and counted as
Skipped in the summary instead of being pointlessly installed. A condition that throws fails
open — a warning, then a normal install — so a broken probe can never silently drop an app.
`Dell.CommandUpdate.Universal` is gated this way (`Dell hardware only`): it installs only when
`Win32_ComputerSystem` reports a Dell manufacturer ([#217](https://github.com/J-MaFf/winget-app-setup/issues/217)).

## Unattended runs

Pass `-NonInteractive` to suppress all interactive prompts (the elevation pause, the grid-view
prompt, and the final "press any key") for RMM, CI, or scheduled-task use:

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -NonInteractive
```

Non-interactive mode is also auto-detected when the session is non-interactive (e.g.
`pwsh -NonInteractive`, services, scheduled tasks) or stdin is redirected.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success — all apps installed or already present |
| 1 | One or more apps failed to install (also: run under PowerShell older than 7, pre-flight system checks failed, or elevation unavailable under remote execution) |
| 2 | Winget is unavailable and could not be installed |
| 3 | App-definition validation failed, or no valid app definitions remain |

## Logs

Every run writes a full transcript to
`%ProgramData%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>.log` (dry runs get a `-whatif`
suffix, e.g. `install-20260708-143000-whatif.log`). The path is printed at startup and repeated
with the final summary. ProgramData is used — rather than the elevating account's `%TEMP%` — so
the log survives cross-user elevation and can be collected after a failed install on a remote
machine. If the transcript cannot be started, the installer warns and continues: logging never
blocks an install.

Each transcript begins with an `Installer build:` line carrying the content-derived build id
(`<module version>+<8-char SHA256 fragment of the assembled functions>`) stamped by
`build/Build-WingetInstallScript.ps1`, so you can tell exactly which installer build produced a
given log.

## Automatic updates

Ongoing updates are handled by [Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate),
which the installer sets up automatically (a pinned, SHA256-verified version). WAU runs as SYSTEM on a
weekly schedule (2 AM) and updates installed apps machine-wide, plus a user-context pass for the
logged-on user — which avoids the cross-user `0x80073d19` problems a per-user scheduled task hits.
WAU's own self-update is disabled so the version stays pinned; bump it via `Get-WauPin` in
`WingetAppSetup/Public/WingetAutoUpdate.ps1`. `winget-app-uninstall.ps1` removes WAU (and any legacy
scheduled-update task from older versions).

## End-to-end monitoring (e2e tier 1)

The unit suite mocks every external call, so a real install is exercised by a scheduled
end-to-end run (`.github/workflows/e2e-install.yml`, issue #214) on a GitHub-hosted
`windows-latest` runner — a throwaway VM by construction:

- **When it runs:** weekly (Mondays 06:00 UTC), on manual dispatch, and on pull requests that
  touch the e2e machinery itself (`.github/workflows/e2e-install.yml`, `e2e/**`) so those
  changes validate themselves pre-merge.
- **What it does:** installs the curated catalog twice — scheduled/dispatch runs use the true
  production path (`irm <raw main URL> | iex`), PR runs use the checkout's
  `winget-app-install.ps1` — asserting exit 0 both times (the second pass proves idempotence),
  then runs the shared assertion script `e2e/Assert-Install.ps1 -ExpectAllSkippedOnSecondRun`:
  every **applicable** `Get-DefaultAppCatalog` app resolves via `winget list` (exit-code
  classified) — the script evaluates each app's catalog condition on the runner, and
  not-applicable apps must instead show their `not applicable` skip line in the latest
  transcript — the WAU scheduled task exists, the installed WAU version matches `Get-WauPin`,
  and a transcript with the `Installer build` stamp exists — with every applicable app Skipped
  on the second pass. The script's `-SkipApps` parameter is an escape hatch for runner-platform
  incompatibilities only; each use must reference a GitHub issue at the call site. Dell Command
  Update is **no longer skip-listed** there: the catalog's manufacturer condition
  ([#217](https://github.com/J-MaFf/winget-app-setup/issues/217)) gates it in the product
  itself, so the non-Dell runners exercise the gating for real on every run.
- **Where the transcripts land:** on the runner under `%ProgramData%\winget-app-setup\logs`
  (the same place as production runs), always uploaded as the `e2e-install-transcripts`
  artifact on the workflow run.
- **On failure:** scheduled/dispatched runs (never PR runs) create — or comment on an existing
  open — GitHub issue titled `E2E install run failed` with the run URL and the last 50
  transcript lines.
- **Trigger manually:** `gh workflow run e2e-install.yml`, then watch with
  `gh run list --workflow e2e-install.yml` / `gh run watch <run-id>`.

Tier 2 ([#215](https://github.com/J-MaFf/winget-app-setup/issues/215)) will reuse
`e2e/Assert-Install.ps1` for a cross-user elevation run on a snapshot-rollback VM.

## Project layout (for contributors)

The installer's logic lives in the **`WingetAppSetup` PowerShell module** under `WingetAppSetup/`
(`Public/` for exported functions, `Private/` for internal helpers). The single-file
`winget-app-install.ps1` is **generated** from that module so the `irm | iex` one-liner keeps
working — do not edit it by hand.

After changing anything under `WingetAppSetup/`, regenerate the installer:

```powershell
pwsh -File .\build\Build-WingetInstallScript.ps1
```

Verify the committed script is in sync with the module (useful in CI / pre-commit):

```powershell
pwsh -File .\build\Build-WingetInstallScript.ps1 -Check
```

Run the test suite (one `<Area>.Tests.ps1` per module file under `tests/`; each loads the
module directly via `tests/TestHelpers.ps1`):

```powershell
Invoke-Pester .\tests
```

### One-time setup: local pre-commit drift check

The repo tracks a pre-commit hook (`.githooks/pre-commit`) that runs the same `-Check`
before a commit lands. Enable it once per clone:

```powershell
git config core.hooksPath .githooks
```

The hook is fast and forgiving by design: it only runs when the staged files touch
`WingetAppSetup/`, `build/`, a `.psd1` manifest, or `winget-app-install.ps1` itself, and if
`pwsh` is not on `PATH` it prints a warning and lets the commit through — CI enforces the same
check on every push and pull request, so nothing ships unverified either way. On failure it
prints how to fix it: re-run the build and stage the regenerated installer together with your
module change.

> **If you also use the beads hooks:** `bd hooks install` (opt-in — the shims under
> `.beads/hooks/` are inert by default) writes its hooks into `.git/hooks/`, and setting
> `core.hooksPath` makes git ignore `.git/hooks/` entirely, silently disabling them. If you
> want both, leave `core.hooksPath` unset and instead add a line to your
> `.git/hooks/pre-commit` that invokes `.githooks/pre-commit` — the drift check runs the same
> way from either location.

### Why `winget-app-install.ps1` cannot drift from the module

The generated installer is guaranteed to match the `WingetAppSetup` module by a stack of
guards, most of which run in both build and `-Check` modes of
`build/Build-WingetInstallScript.ps1`:

1. **Byte-compare with BOM rejection** — `-Check` regenerates the installer in memory and
   compares it (LF-normalized) against the committed file byte for byte; it also inspects the
   raw bytes and rejects a leading UTF-8 BOM that a text comparison would silently strip
   ([#183](https://github.com/J-MaFf/winget-app-setup/issues/183)).
2. **Assembled-script parse guard** — the assembled script is parsed and any syntax error
   fails the build with line/column details, so an unbalanced brace in a module file can no
   longer ship a broken installer ([#183](https://github.com/J-MaFf/winget-app-setup/issues/183)).
3. **AST undefined-reference guard** — every hyphenated command the assembled script invokes
   must resolve to a module-defined function (matched case-sensitively, so a stale call site
   cannot silently resolve to an external cmdlet that differs only by case) or an external
   command; catches functions dropped from the module while still being called — the drift
   class that broke the one-liner in
   [#154](https://github.com/J-MaFf/winget-app-setup/issues/154). Runs on Windows, where the
   installer's Windows-only cmdlets are resolvable.
4. **psd1 export assertion** — `WingetAppSetup.psd1`'s `FunctionsToExport` must exactly
   (case-sensitively) match the functions defined under `WingetAppSetup/Public/*.ps1`, so a
   new public function cannot be silently filtered on manifest imports
   ([#191](https://github.com/J-MaFf/winget-app-setup/issues/191)).
5. **Non-ASCII token guard (Windows PowerShell 5.1 parse safety)** — every non-comment token
   of the assembled script must be pure ASCII. The installer ships as BOM-less UTF-8, which
   5.1 decodes as ANSI: a multi-byte character inside a string literal misdecodes (an em
   dash's 0x94 byte becomes a string-terminating curly quote) and cascades into parser
   errors before the version fail-fast can run. Keeping code tokens ASCII keeps the file
   5.1-parseable so 5.1 reaches the version check and prints a real message; comments are
   exempt because misdecoded bytes there cannot change tokenization
   ([#210](https://github.com/J-MaFf/winget-app-setup/issues/210)).
6. **Content-derived build id** — the banner and `$script:InstallerBuildId` are stamped with
   `<module version>+<8-hex SHA256 fragment of the assembled functions>`, derived from content
   only (never git metadata or timestamps) so rebuilding the same tree is byte-identical and
   the `-Check` byte-compare stays deterministic; transcripts log the id at startup so a log
   identifies the exact installer build ([#189](https://github.com/J-MaFf/winget-app-setup/issues/189)).
7. **CI enforcement** — `.github/workflows/windows-tests.yml` runs `-Check` on every push to
   `main` and on every pull request, so drift fails CI instead of shipping
   ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156)).
8. **Local pre-commit hook** — `.githooks/pre-commit` (above) runs the same `-Check` before a
   commit that touches the module, the build, a manifest, or the installer, catching drift
   before it is even committed ([#211](https://github.com/J-MaFf/winget-app-setup/issues/211)).
