# DiscWright Windows v32 — the final version — completion note

Built 2026-11-07 per the v32 brief. Three changes: (1) the
temporary Make ISO button is REMOVED (Lola's explicit word —
it existed only to test the encoder, v26–v31); (2) Burn Disc
is now the real flow for a new disc: encode → author → the
window auto-imports the fresh ISO and offers its burn through
the proven Import ISO + OfferBurn path; (3) the build gains a
standalone single-exe packaging stage (a native bootstrapper
that unpacks the app folder per-user — no install).

Forbidden files were NOT touched, verified by mtime (all
pre-date this session): core/, app/App.xaml,
app/DiscPainter.cs, app/EncodeService.cs,
app/Imapi2Interop.cs, app/DiscWright.csproj. The proven
ProgID/dynamic IMAPI2 code in BurnService.cs is untouched
apart from the dialog wording.

## Changes per file

### app/BurnService.cs
- OfferBurnAsync's confirmation Content now depends on the
  disc's origin: `disc.FromEncode` → "“<name>” — Your disc is
  encoded and ready. Put a blank CD in the drive, then burn
  it."; otherwise → "“<name>” — You imported this ISO. Put a
  blank CD in the drive, then burn it." (exact strings per
  brief). Title / PrimaryButtonText / CloseButtonText
  unchanged.
- The method's summary comment now records the two origins
  instead of claiming the one wording is "the Mac wording,
  verbatim".
- Nothing else in the file changed.

### app/Store.cs
- ImportedDisc gains `public bool FromEncode;` with the
  brief's comment (set when the "imported" disc is one the
  app itself just encoded).
- Constructor: the v26 launch log line is replaced with
  "Add tracks, then Burn Disc — a new disc encodes, authors,
  and offers its burn in one go. Import ISO + burn works
  too." ("Ready." unchanged, still first.)
- BurnEnabled replaced with the final rule (brief verbatim,
  comment included):
  `!IsEncoding && !IsBurning && (Imported != null || AllTracks.Count > 0)`.
- CanMakeIso DELETED (property + comment), and its
  OnPropertyChanged call removed from Refresh().
- ImportIso(string path, bool fromEncode = false); the
  ImportedDisc initializer sets FromEncode = fromEncode.
- Encode section header comment: "Make ISO click" → "Burn
  Disc click".
- ApplyEncodeSuccess summary: now says the window
  auto-imports the ISO it just built (marked FromEncode)
  and offers its burn — the proven Import ISO path, no
  Downloads detour by hand. Body unchanged.
- IsEncoding summary: "locks Burn Disc" (was "locks Make
  ISO").
- One extra, flagged for honesty: the file-header comment
  said "the Make ISO lifecycle callbacks" — reworded to "the
  encode lifecycle callbacks" so no LIVE comment names the
  removed feature. The only remaining "Make ISO" mentions in
  Store.cs are none; in the .cs/XAML the two survivors are
  past-tense history in MainWindow.xaml and
  MainWindow.xaml.cs comments.

### app/MainWindow.xaml
- MakeIsoButton element DELETED.
- The row keeps: Cancel (Click="CancelEncode_Click",
  IsEnabled="{Binding IsEncoding}", now restyled like the
  other action buttons: FontSize="14" Padding="14,7",
  VerticalAlignment="Center" kept) and the workers TextBlock
  + WorkersCombo EXACTLY as they were — including the entire
  NumberBox warning comment block, verbatim.
- The comment above the row is the final-version comment:
  Burn Disc runs the whole job now; the Make ISO button was
  Lola's temporary encoder test path (v26–v31), removed in
  the final version at her word; the "every IsEnabled sits
  on the Control itself, NEVER on a panel" sentence kept.
- Hint TextBlock under the row now reads: "Burn Disc encodes
  a new disc, authors its ISO to Downloads, then offers the
  burn." (visibility binding unchanged).
- Nothing above the actions StackPanel was touched.

### app/MainWindow.xaml.cs
- MakeIso_Click DELETED; BurnNewDiscAsync (private async
  Task) holds its ENTIRE pre-flight + snapshot + Task.Run
  body, logic unchanged, except the tail: `string isoPath`
  is declared before Task.Run and assigned inside it; the
  success hop is now async and does, in order:
  Store.ApplyEncodeSuccess(handle, line);
  Store.ImportIso(isoPath, fromEncode: true);
  if (Store.Imported is { } imp2) await
  BurnService.OfferBurnAsync(this, imp2, …ApplyBurnState…,
  Store.Log).
  Mechanical note: the existing Enqueue helper takes an
  Action, so the async hop rides a small sibling helper,
  EnqueueAsync(Func<Task>), added beside it — same
  DispatcherQueue, same pattern.
- BurnDisc_Click is now: imported disc → OfferBurnAsync and
  return; otherwise → await BurnNewDiscAsync().
- The encode section header comment describes the final
  flow (and records the v26–v31 button's history).
- WorkersCombo_SelectionChanged, CancelEncode_Click, the
  pickers, and the canvas handlers are unchanged.

### launcher/launcher.cpp (NEW)
- Native bootstrapper per the brief's spec. Layout:
  [launcher PE][payload.zip][48-byte footer]; footer is
  little-endian — magic "DWPAYLD1" (bytes 0..7), uint64
  payloadSize (8..15), 32-byte NUL-padded ASCII stamp
  (16..47).
- wWinMain: own path via GetModuleFileNameW; size <
  48 + 4 or bad magic → MessageBoxW "This DiscWright
  standalone file is damaged (missing payload)." and exit.
- Extract dir: SHGetKnownFolderPath(FOLDERID_LocalAppData)
  + "\DiscWright\standalone-" + sanitized stamp
  ([A-Za-z0-9._-] kept, else '_').
- Fast path: DiscWright.exe present AND .dwstamp content
  == stamp → launch immediately.
- Else: directory chain created level by level; payload
  stream-copied in 1 MiB chunks (seek to
  fileSize − 48 − payloadSize) to <dir>\payload.zip;
  extracted with `tar.exe -xf "<dir>\payload.zip" -C
  "<dir>"` via CreateProcessW + CREATE_NO_WINDOW, waited
  on, nonzero exit → fail dialog; payload.zip deleted;
  .dwstamp written (stamp text, no newline).
- Launch: CreateProcessW(applicationName = extracted
  DiscWright.exe, commandLine = GetCommandLineW() passed
  through unchanged — the choice is documented in a
  comment: argv[0] is re-parsed from applicationName and
  DiscWright takes no arguments — working directory =
  extract dir), then the launcher exits 0. CreateProcess
  failure → MessageBoxW.
- Only windows.h + shlobj.h; shell32.lib/ole32.lib via
  #pragma comment(lib, …). Header comment documents the
  what/layout/why (WinUI 3 has no .NET single-file
  publishing; the folder must exist on disk; per-user, no
  install, no admin; delete %LOCALAPPDATA%\DiscWright to
  remove).

### build-app.cmd
- Header: "Step 3 build (v28)" → "Final build (v32)"; the
  usage comment now also documents DiscWright-standalone.exe
  (one file, double-click, unpacks under
  %LOCALAPPDATA%\DiscWright on first run; folder build stays
  for debugging).
- Tools-missing errors de-named: "Make ISO would have no
  decoder." → "the encoder would have no decoder.";
  "Make ISO would have no encoder." → "the encoder would
  have no encoder tool."
- NEW standalone stage after the tools-copy guards, before
  the final BUILD SUCCEEDED block:
  - STAMP=2026-11-07.v32; STANDALONE_OK flag (0 unless the
    exe is produced and size-verified).
  - vcvars64.bat probed under the same four VS 2022 roots
    the MSBuild probe uses (Community / Professional /
    Enterprise under Program Files, BuildTools under
    Program Files (x86)); none found → clear warning that
    the standalone was SKIPPED (points at the "C++ WinUI app
    development tools" Lola's install carries) and the
    folder build still succeeds.
  - call vcvars64; cl resolved from PATH (where cl) as a
    sanity check; compile:
    cl /nologo /O2 /W3 /DUNICODE /D_UNICODE
    launcher\launcher.cpp /Fe:…\discwright-launcher.exe
    /Fo:…\discwright-launcher.obj /link /SUBSYSTEM:WINDOWS
    (the /link switch rides the same cl invocation, so the
    subsystem flag lands). Failure → warn + skip.
  - Payload: PowerShell Compress-Archive of DiscWright\*
    (the folder's CONTENTS — DiscWright.exe at zip root)
    to %TEMP%\discwright-payload.zip. Failure → warn + skip.
  - Footer written by PowerShell: 48-byte array, ASCII
    "DWPAYLD1", payload length via
    [BitConverter]::GetBytes([uint64]) at offset 8, stamp
    ASCII at offset 16 (array is zero-initialised, so the
    stamp is NUL-padded to 32).
  - Assembled with copy /b launcher + payload + footer →
    %ROOT%DiscWright-standalone.exe; verified present AND
    its size reported alongside the launcher/payload sizes
    (must exceed launcher + payload by the 48-byte footer);
    temp files deleted.
  - Final echo block: on success, `Standalone:
    "%ROOT%DiscWright-standalone.exe" (single file -
    double-click to run; first run unpacks itself, no
    install).`; on skip, a SKIPPED line pointing at the
    warning. Batch discipline kept: all paths quoted, no
    mid-line `&` separators, parenthesized IF blocks for
    multi-command conditions.

### STEP3-NOTES.md
- Appended "## v32 — the final shape (2026-11-07)": the
  button's removal at Lola's word, Burn Disc = encode →
  author (ISO still in Downloads) → auto-import FromEncode
  → proven OfferBurn path, workers ComboBox untouched, the
  standalone design and WHY, and the known costs (first-run
  unpack takes seconds; unsigned binary → SmartScreen may
  ask on first download-run; folder build remains for
  debugging).

## Verification (run in this VM, 2026-11-07)

```
--- grep -c "MakeIso" ---
app/MainWindow.xaml:0
app/MainWindow.xaml.cs:0
app/Store.cs:0

--- grep -c "CanMakeIso" ---
app/MainWindow.xaml:0
app/MainWindow.xaml.cs:0
app/Store.cs:0

--- grep -c "NumberBox" app/MainWindow.xaml ---
1        (the warning comment, as required)

--- grep -c "FromEncode" ---
app/Store.cs:3
app/BurnService.cs:1
app/MainWindow.xaml.cs:1
total 5  (>= 4 required)

--- grep -c "DWPAYLD1" ---
launcher/launcher.cpp:1   (plus the magic as a char array
                           in code and in the header layout)
build-app.cmd:2

--- remaining "Make ISO" (with a space) ---
app/MainWindow.xaml:299      past-tense history in the
                             v32 row comment
app/MainWindow.xaml.cs:190   past-tense history in the
                             encode section comment
(none in Store.cs / BurnService.cs; no live references)

--- grep -rn "MakeIso" app --include=*.cs --include=*.xaml ---
(none)

--- XAML well-formedness ---
MainWindow.xaml parses as XML OK (ElementTree)

--- core build (untouched core, tree-coherence check) ---
dotnet build core/DiscWright.Core.csproj -v q --nologo
Build succeeded. 0 Warning(s) 0 Error(s)

--- brace/paren/bracket balance on edited .cs files ---
BurnService.cs 0/0/0, Store.cs 0/0/0, MainWindow.xaml.cs 0/0/0
```

## NOT verified here (Lola's build is the check)

- No MSVC in this VM: launcher.cpp's compile check is
  Lola's build, as with all the WinUI code. It was given a
  careful re-read for undeclared identifiers/typos after
  writing (buffers sized generously; every API used is
  declared by windows.h/shlobj.h; the one static 1 MiB
  chunk buffer is deliberate, to keep it off the stack).
- The WinUI app itself still compiles only on her gaming
  PC (VS MSBuild via build-app.cmd) — the v32 edits are
  small and brace-balanced, but the XAML/C# compile verdict
  is hers, same as every step.
- The standalone stage's skip paths (no vcvars / cl /
  payload failures) were written to warn-and-continue; her
  machine HAS the C++ toolset, so the expected path is the
  full one.
