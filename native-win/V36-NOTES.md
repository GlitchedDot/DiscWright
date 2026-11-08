# v36 — the S6 drive-root fix (2026-11-07)

## Verdict that produced this build

Lola ran v35. The standalone was PRODUCED for the first time
(103,734 KB beside build-app.cmd), launched, opened its watch
console, and testified exactly as designed:

    DiscWright could not create its unpack folder under your
    local app data. [stage S6] (error 5)

(error 5 = ERROR_ACCESS_DENIED.)

## Root cause

launcher.cpp's EnsureDirectory walks the target path one level
at a time, creating each prefix. For
"C:\Users\pspmo\AppData\Local\DiscWright\standalone-<stamp>"
the first prefix it tries to create is "C:" — and
CreateDirectoryW("C:") fails with ERROR_ACCESS_DENIED even
though the drive root obviously exists. The walk died on its
first step, before creating anything.

Every later prefix (Users, pspmo, AppData, Local, DiscWright)
already exists on her machine, and the final component is the
only genuinely new folder — none of them were ever the problem.

## The fix (this build)

EnsureDirectory now:

- never attempts to create the drive root (a truncated prefix
  of "C:" / "C:\" is skipped outright), and
- treats a level that already exists AS A DIRECTORY as success
  regardless of the error CreateDirectoryW reported (the
  attribute check is the ground truth), restoring the real
  error before returning failure so Fail() reports it honestly.

STAMP bumped to 2026-11-07.v36 (fresh unpack folder; the failed
v35 run created nothing under AppData, but the stamp discipline
stands). The edited launcher was syntax-checked with the mingw
Win32 cross-compiler before shipping; her MSVC build remains
the real compile check.

## Her test

Fresh extract → PowerShell or cmd → `.\build-app.cmd` →
"STANDALONE RESULT: OK" → run DiscWright-standalone.exe. The
watch console should now narrate past S6: "Unpack folder: ...",
"Copying payload... ~99 MB", "Extracting..." with tar's file
parade, "Unpack complete - starting DiscWright" — then the app
opens. Later launches take the silent fast path.

## Verdict (Lola, 2026-11-07 ~17:42)

**THE STANDALONE WORKS.** Her words, untangled from a first
confusing four-way report: the standalone runs, the watch
window narrates the unpack, DiscWright opens; the unpacked app
inside %LOCALAPPDATA%\DiscWright\standalone-2026-11-07.v36
also launches fine when double-clicked directly; and the
folder build runs as always. The only non-runner in the whole
story is the v33 native single-file experiment, which was
already convicted (XAML activation) and is buried for good.

The standalone saga (v32 silent absence → v34 testimony →
v35 link fix → v36 S6 fix) is CLOSED. DiscWright for Windows
ships in both forms: the folder build, and the single
DiscWright-standalone.exe — no install, per-user unpack, watch
window on first run, silent fast path after.
