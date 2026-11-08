# DiscWright Windows v34 — the standalone learns to testify

Built 2026-11-07. Scope: `launcher/launcher.cpp` and the
standalone stage of `build-app.cmd` ONLY. **app/ and core/
are untouched** — v31, v32 and v33 folder builds all launch
on Lola's machine; only the standalone wrapper
(DiscWright-standalone.exe) fails, and it fails SILENTLY:
no extraction folder ever appears under
%LOCALAPPDATA%\DiscWright, and no error box was seen.

## The two hypotheses v34 discriminates

1. **Mis-assembled bytes** — the copy /b assembly or the
   PowerShell-written footer produced a file whose payload
   is not where its footer claims (wrong size, wrong
   offset, not a zip at that offset). v32's launcher would
   then die somewhere between "open self" and "start tar"
   with at most a generic "damaged" box — or, if the bytes
   are bad in a way its checks didn't cover, with nothing
   recognisable at all.
2. **Killed before wWinMain** — the process never runs its
   own code (Defender/SmartScreen reputation on a fresh
   unsigned self-extracting exe, or similar). Then NO code
   change inside the launcher can produce testimony from
   the launcher itself — the witness would be the build
   log's verdict line plus the still-total absence of any
   unpack folder, box, console or log.

How v34 answers: the launcher now self-checks the payload
against the footer (stage S4) before copying a byte, so
hypothesis 1 gets a named, coded message box on first run.
The build prints a `STANDALONE RESULT:` verdict (see
build-app.cmd below), so a skipped/failed assembly is
visible in the build output instead of hiding behind a
warning scroll. If v34's standalone STILL leaves zero
trace — no S-box, no console, no unpack.log, no folder —
hypothesis 2 is convicted by elimination and the fight
moves to the machine's security state, not the code.

## launcher/launcher.cpp — what changed

### Named-stage errors (S1–S11)
Every Fail() now takes a stage number and, where the
failing Win32 call set one, the GetLastError() code; the
message box shows both: `<plain message> [stage S#]
(error N)`. Stages:

- S1 — finding our own file path (GetModuleFileNameW)
- S2 — opening ourselves / reading the 48-byte footer
- S3 — footer magic mismatch ("DWPAYLD1" not found)
- S4 — payload self-check (new, below)
- S5 — local-app-data path / unpack path construction
- S6 — creating the unpack folder
- S7 — creating payload.zip in the unpack folder
- S8 — copying the payload bytes into payload.zip
- S9 — starting tar.exe
- S10 — tar's exit code / extraction result
- S11 — starting the unpacked DiscWright.exe

### Payload self-check (S4, new)
Right after the magic check, before anything is copied:
payloadSize must be nonzero and fit inside the file
(payloadOffset = fileSize − 48 − payloadSize must be a
real position strictly inside the payload region), and
the four bytes AT payloadOffset must be the zip local
file header signature `PK\x03\x04`. A mis-assembled file
now fails HERE, by name, instead of downstream weirdness.

### The watch window (Lola's ask, 2026-11-07)

Lola: "while its logging things, can you also have it
open a read only cmd window or something so I can watch?"
Watching processes work is a standing delight of hers, so
the unpack — and ONLY the unpack; the fast path stays
invisible, no console, exactly like v32 — narrates itself:

- At the start of the unpack branch the launcher attaches
  a console: `AttachConsole(ATTACH_PARENT_PROCESS)` first,
  so a launch from PowerShell shows the stages inline in
  her terminal; if that fails, `AllocConsole()` opens a
  fresh window titled "DiscWright - unpacking". If both
  fail, the unpack carries on silently — the console is a
  courtesy, never a gate.
- A `Say()` helper writes each stage line to the console
  AND mirrors it into `unpack.log`, opened in the unpack
  folder right after the folder is created. Lines, in
  plain words: "DiscWright standalone - first run:
  unpacking", the unpack folder's path, "Copying
  payload... N MB", "Extracting...", "Unpack complete -
  starting DiscWright". Failure stages Say their tagged
  line before the message box, so the log holds them too.
- tar runs as `tar.exe -xvf "<zip>" -C "<dir>"` — verbose,
  INHERITING the watch console (no CREATE_NO_WINDOW), so
  the parade of unpacked files scrolls by live in the
  window and her terminal alike. This REPLACED the
  earlier v34 plan to redirect tar's output into
  unpack.log via cmd.exe: live and inherited beats
  captured and static, and Say() still gives unpack.log
  the stage-level record.
- Endings. SUCCESS: the completion line is Said, the app
  launches, the launcher sleeps ~1.2 s so "done" can be
  seen, then frees the console — but only one it allocated
  itself; an attached parent console (her terminal) is
  never freed. The app itself is started DETACHED_PROCESS
  when a console is up, so the watch window is the
  launcher's alone to close and doesn't linger for the
  app's lifetime. FAILURE with a console: after the
  message box is dismissed, "Press Enter to close this
  window..." and one line-read on CONIN$ before exiting,
  so the testimony stays on screen for a screenshot.
  payload.zip is deleted only on success; on failure it
  stays in the unpack folder for inspection.

### Child command line (S11)
The app now gets a command line built for it:
`"<extracted DiscWright.exe>"` plus whatever followed the
launcher's own first token on the original command line,
verbatim (quoted and unquoted first tokens both skipped).
v32 passed GetCommandLineW() through unchanged, so the
child's argv[0] named the launcher.

## build-app.cmd — what changed (standalone stage only)

- `STAMP=2026-11-07.v34` (new stamp ⇒ the v34 standalone
  unpacks into its own fresh `standalone-2026-11-07.v34`
  folder; the v32 stamp's folder, if any, is untouched).
- The stage now ends in a VERDICT, not a hint: on success,
  `STANDALONE RESULT: OK` above the existing component
  sizes line (launcher + payload + 48-byte footer = final
  bytes); every existing WARNING exit also sets
  `STANDALONE_FAIL` (toolset / cl / compile / pack /
  footer / assemble) and the final summary prints
  `STANDALONE RESULT: SKIPPED - <stage>` for the one that
  fired. A build whose standalone quietly didn't happen
  is now impossible to miss in the output Lola pastes.
- The stage's header comment records v34 (hardened
  launcher: staged errors + payload self-check +
  unpack.log + watch console).

Nothing before the standalone stage changed behaviour;
app/, core/, build-singlefile.cmd and the v33 machinery
are all untouched.

## NOT verified here (Lola's build is the check)

- No MSVC in this VM: launcher.cpp's compile check is
  Lola's build, as with v32. It was re-read end to end
  after writing (buffer sizes audited — the tar command
  buffer grew to 4096 for the verbose form; every API used
  is declared by windows.h/shlobj.h; the hand-rolled
  number/text appenders keep the file CRT-formatting-free,
  matching its raw-Win32 style).
- The console behaviour (attach vs alloc, tar's inherited
  parade, the Enter wait) can only be witnessed on her
  machine — which is, of course, the point of shipping it.

## Test outcome (Lola, 2026-11-07 ~16:40)

- The v34 FOLDER build launches (app exonerated again).
- The standalone stage printed "STANDALONE RESULT: SKIPPED -
  compile": on Lola's machine the launcher's cl compile failed,
  so no DiscWright-standalone.exe was produced at all. This also
  retro-explains the v32 silent failure IF the same compile step
  failed then (v32's script let the warning scroll by): no
  launcher ever existed, hence no unpack folder and no error box.
- Candy cross-checked launcher.cpp on 2026-11-07 with a mingw-w64
  Win32 toolchain: compiles AND links clean; strict ISO C++14
  (-pedantic-errors) reports nothing but the two MSVC-only
  #pragma comment lines. The source is not the suspect; the
  cl invocation/environment on her machine is. Her cl error
  lines are the remaining evidence.
- v35 change (build-app.cmd only): the cl step now captures its
  output to standalone-build.log beside the script and prints it
  inline on failure, so the compiler's testimony survives the
  terminal scrollback. STAMP bumped to 2026-11-07.v35.
