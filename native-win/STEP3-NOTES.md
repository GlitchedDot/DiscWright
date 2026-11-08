# DiscWright Stage 3, Step 3 — the encode bridge (v26) — work notes

What this step is: the Windows counterpart of the Mac's Step 3.
A new disc can now be encoded end to end — ffmpeg decodes each
track to a canonical WAV, the vendored atracdenc encodes it to
raw ATRAC3+ frames, DiscAuthor.BuildDisc (the byte-proven core,
untouched) authors the disc, and the ISO lands in
%USERPROFILE%\Downloads\atrac-disc.iso.

Lola's framing for v26 (2026-11-06, her words): a TEMPORARY
"Make ISO" button so she can test the ENCODER without spending
physical discs — encode → ISO file → she imports that ISO back
and burns it through the proven Import+Burn path. So v26 is the
full encode bridge surfaced through Make ISO. Burn-after-encode
(the Mac's offerBurn right after authoring) is deliberately NOT
in this build: Burn Disc for a new disc stays disabled, and the
launch line + footnote say so.

## Files

app/EncodeService.cs    NEW — the port of EncodeService.swift
                        (jobs / handle / failures / encodeAll,
                        with ffmpeg standing in for AVAssetReader)
app/Store.cs            encode state: IsEncoding,
                        EncodeProgress, EncodeWorkers +
                        settings file, CanMakeIso, and the
                        Begin/Apply/Cancel lifecycle callbacks
app/MainWindow.xaml     the Make ISO row (Make ISO + Cancel +
                        workers NumberBox) under the burn row;
                        footnote updated to the v26 truth
app/MainWindow.xaml.cs  MakeIso_Click (pre-flight + snapshot +
                        background encode/author/write,
                        DispatcherQueue callbacks), workers wiring
app/DiscPainter.cs      the laser's fraction now reads the
                        store's EncodeProgress when present;
                        cosmetic pacing kept as the fallback.
                        NO drawing numbers changed.
build-app.cmd           tools-prep stage (below) before
                        MSBuild + tools copy into DiscWright\
encoder/atracdenc-src/  the vendored encoder sources, copied
                        verbatim from native-pure (2.3 MB)

Untouched, per the brief's hard rules: core/, app/App.xaml,
app/BurnService.cs, app/Imapi2Interop.cs, and every drawing
number in DiscPainter.

## The encode flow (mirror of the Mac's startEncodeAndBuild)

1. Click → pre-flight guards on the UI thread (the Mac's):
   a track that failed to read, a track with no source file,
   over-capacity, or a missing tool each refuse with a named
   log line + the standard error status. Nothing starts.
2. Snapshot: jobs in playlist order (index / title / source),
   tag triples, and groups as 1-based inclusive ranges over
   the playlist, empty groups skipped.
3. BeginEncode: IsEncoding + IsBurning set (the stage spins
   and draws the laser throughout, as on the Mac), progress 0,
   status "Writing — 0 of N tracks encoded".
4. Background (Task.Run): EncodeService.EncodeAll with the
   workers cap; each finished track reports (done, total,
   title) → status + log, progress = 0.85 × done/total.
5. Authoring: status "Writing — authoring the disc…",
   progress 1.0; fresh random DiscID + one 8-byte IV per
   track (RandomNumberGenerator — the web's
   crypto.getRandomValues counterpart); BuildDisc against the
   selected blank's capacity.
6. ISO written to Downloads\atrac-disc.iso; the log line is
   the Mac's: `Built <path> — N tracks, X MB, S sectors.`;
   status lands on "Your disc is ready. 💿".
7. Any track failure aborts BEFORE authoring (first failure
   wins; pending jobs drop out) → "Build failed: <reason>"
   where the reason names the track and carries the failing
   child's log tail. Cancel → children killed, pending jobs
   dropped, status back to the idle line, log "Encoding
   cancelled — no disc was built."

Per track (EncodeService): temp dir track-<i> under a fresh
%TEMP%\DiscWrightEncode-<guid>; ffmpeg -> in.wav; atracdenc
-> out.raw; frames validated: length > 0 and % 376 == 0
(376 = Atrac.FrameSize from the core). Temp root deleted at
the end, success or failure.

Recipes (standing, hardware-proven on the Mac side):
  ffmpeg:    -y -v error -i <in> -ar 44100 -ac 2 -sample_fmt s16 <out.wav>
  atracdenc: -e atrac3plus --bitrate 64 --container raw -i in.wav -o out.raw

## Tools (build-app.cmd tools stage, before MSBuild)

Tools resolve at run time from a `tools` folder beside the
exe (AppContext.BaseDirectory + "tools"). The shipped
DiscWright\tools\ carries ONLY the app-facing payload —
ffmpeg.exe, atracdenc.exe, *.dll — and the script refuses to
ship if either exe is missing (same guard shape as the .pri
guard). The build cache (stamps, the vcpkg installed tree)
stays in native-win\tools\ and is never shipped: the app
would never read its headers/libs, and it would add well
over 100 MB to every zip.

### ffmpeg — pinned download

- URL: https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip
  (verified from the VM 2026-11-06: redirects to
  https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip,
  HTTP 200; downloaded once to ~/workspace/ffmpeg-pin/)
- SHA-256 of that download:
  60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba
  (114,768,076 bytes; zip layout ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe)
- Script behavior when tools\ffmpeg.exe is absent: download
  to a temp name (PowerShell Invoke-WebRequest), verify the
  hash with certutil -hashfile, Expand-Archive to a temp
  folder, copy ONLY bin\ffmpeg.exe into tools\, clean up.
  Any failure stops the build with a message.
- ⚠ The release-essentials URL is a MOVING pointer to
  gyan.dev's latest build. When they publish a newer ffmpeg,
  the hash check will stop the build ON PURPOSE (nothing
  unpinned ever ships). Updating the pin = re-download,
  re-hash, edit FFMPEG_URL/FFMPEG_SHA256 in build-app.cmd.

### libsndfile — vcpkg, install root redirected (ADAPTATION)

The brief assumed `vcpkg install libsndfile:x64-windows`
into <vcpkgRoot>\installed. The vcpkg bundled with
Visual Studio lives under Program Files
(...\2022\<Edition>\VC\vcpkg), where a NON-ELEVATED build
script cannot write the installed tree. So the script runs:

  vcpkg install libsndfile:x64-windows --x-install-root="<tree>\tools\vcpkg-installed"

and the atracdenc configure gets the matching
-DVCPKG_INSTALLED_DIR. Same packages, writable location,
no elevation. Gated by tools\.vcpkg-stamp (+ a live check
that sndfile.dll actually exists).

### atracdenc — cmake against the vcpkg toolchain

  cmake -S encoder\atracdenc-src -B encoder\build-win
        -G "Visual Studio 17 2022" -A x64
        -DCMAKE_TOOLCHAIN_FILE="<VS>\VC\vcpkg\scripts\buildsystems\vcpkg.cmake"
        -DVCPKG_TARGET_TRIPLET=x64-windows
        -DVCPKG_INSTALLED_DIR="<tree>\tools\vcpkg-installed"
        -DVCPKG_MANIFEST_INSTALL=OFF
        -DATRACDENC_PCM_IO_BACKEND=libsndfile
        -DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE
  cmake --build encoder\build-win --config Release --target atracdenc

- ONLY the `atracdenc` target, never "all" — the Mac's scar:
  upstream's man target runs an unquoted-path shell line and
  dies in folders with spaces (her first Mac Step 3 build).
- -DATRACDENC_PCM_IO_BACKEND=libsndfile is PINNED on purpose:
  the vendored src/CMakeLists.txt picks "auto" → Media
  Foundation under WIN32+MSVC. libsndfile is the Mac's proven
  WAV path AND makes the vcpkg step load-bearing; the
  vendored FindLibSndFile.cmake uses plain find_path/
  find_library, which the vcpkg toolchain's prefix path
  satisfies (sndfile.h under include\, sndfile.lib under lib\).
- -DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE for the Mac's
  reason: upstream's test/ tree is not vendored and the top
  CMake only adds it when GTest is found.
- The CMAKE_OSX_ARCHITECTURES patch in the vendored
  CMakeLists is macOS-only (guarded) and inert here.
- Output: encoder\build-win\src\Release\atracdenc.exe (VS
  generators are multi-config, hence the Release subfolder)
  copied to tools\, PLUS every *.dll from
  tools\vcpkg-installed\x64-windows\bin (sndfile.dll and its
  dependency DLLs — FLAC/Ogg/Vorbis/Opus as built).
- Rebuild gate: a source stamp (SHA-256 over every source
  file's SHA-256, path-sorted — the Mac's scheme) in
  tools\atracdenc.stamp; missing exe or a moved stamp
  rebuilds, otherwise the stage is skipped with a message.
- cmake is probed at the VS-bundled path first
  (Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin),
  then `where cmake`. vcpkg is probed under the same four
  VS roots build-app.cmd already probes for MSBuild. If
  either can't be found, the script stops with an exact
  message before anything builds.

## Deviations from the Mac (each forced, each contained)

1. **Decode**: AVAssetReader (in-process) → bundled
   ffmpeg.exe (a child process). The canonical-output
   contract is identical (44.1k/16-bit/stereo WAV).
2. **Child output plumbing**: Swift hands the child a log
   FileHandle directly — zero pipes. .NET's Process cannot
   accept a raw handle for a child's stdout, so each child
   is drained CONTINUOUSLY via OutputDataReceived /
   ErrorDataReceived into the same per-track log file. The
   deadlock the no-pipe rule guards against (a child
   blocking on a full, undrained pipe buffer) cannot form:
   the drain runs for the child's whole life. Log files:
   ffmpeg.log / atracdenc.log in the track's temp dir.
3. **EncodeHandle tracks BOTH children** (ffmpeg and
   atracdenc) — on the Mac only atracdenc was a process, so
   only it needed registering for Cancel. Same semantics:
   Cancel kills whatever child a track is currently in.
4. **Failure log tail**: the Mac embeds the atracdenc log's
   whole trimmed tail in the failure reason. Kept, capped at
   the last 600 characters so a chatty ffmpeg failure
   cannot flood the app log. Both children's failures carry
   their tails (the Mac had no ffmpeg tail to carry).
5. **Workers persistence**: UserDefaults → a plain file,
   %LOCALAPPDATA%\DiscWright\settings.txt, one
   `encodeWorkers=N` line. ApplicationData.Current is NOT
   usable: it requires package identity and throws in an
   unpackaged app. A broken settings file never blocks launch.
6. **Orchestration home**: the Mac's flow lives in its
   store; here the click handler in MainWindow builds the
   snapshot and runs the work (BurnService's established
   split — MainWindow owns invocation, the store owns
   state), with every store touch marshaled through the
   window's DispatcherQueue.
7. **Stage during authoring**: progress is set to 1.0 for
   the authoring beat (the Mac holds 0.85-scale until the
   burn finishes, then nils the feed on decline/finish —
   v26 has no burn-after, so success clears the feed as the
   ready status lands).

## Flagged uncertainties (could not be compile-verified in the VM)

The VM has no WinUI SDK; her machine is the compile check, as
with every Windows step. EncodeService.cs + the core + Models
WERE compiled in-VM (net8.0, 0 warnings / 0 errors), so the
risk concentrates in the WinUI-facing files:

1. **NumberBox surface** (MainWindow.xaml + code-behind):
   `Header`, `Minimum`, `SpinButtonPlacementMode="Inline"`,
   `ValueChanged` with `NumberBoxValueChangedEventArgs.NewValue`,
   and the `Maximum`/`Value` property sets from code-behind.
   All are standard WinUI 3 (Microsoft.UI.Xaml.Controls),
   no new package — but none could be compiled here. If
   SpinButtonPlacementMode's enum spelling differs, XAML
   pass 1 will say so (loudly, unlike the silent landmines).
2. **NumberBox.Value type**: it is a double DependencyProperty;
   the ctor assigns the store's int (implicit conversion) and
   ValueChanged reads NewValue as double → cast to int. No
   {Binding} on Value, deliberately (classic two-way binding
   to a double from an int property is a blind-write risk).
3. **Task.Run + DispatcherQueue**: BurnService precedent
   (Thread + queue.TryEnqueue) — Task.Run is used here
   because no STA apartment is needed (children are
   processes, not COM). Callbacks capture the window's
   DispatcherQueue before the task starts.
4. **EncodeException filter**: `catch (EncodeException ex)
   when (ex.Kind == ...)` — standard C#; the store also
   re-checks handle identity on every callback, so a stale
   report from a superseded run is ignored (the Mac's
   `encodeHandle === handle` guard).
5. **vcpkg --x-install-root**: a long-standing vcpkg option
   (used since ~2020); if the VS-bundled vcpkg on her machine
   spells it differently, the install step fails loudly with
   vcpkg's own usage text and the fix is that one line.
6. **FindLibSndFile under the toolchain**: find_path/
   find_library should resolve through VCPKG_INSTALLED_DIR
   (it is on CMAKE_PREFIX_PATH under the toolchain). If the
   configure reports "libsndfile PCM I/O backend requires
   libsndfile", the fallback knob is pre-seeding
   -DLIBSNDFILE_INCLUDE_DIR / -DSNDFILE_LIBRARY in the
   configure line — noted here so the fix is one edit.
7. **atracdenc.exe runtime deps**: every DLL from the vcpkg
   bin folder ships in tools\, so sndfile.dll's own
   dependencies resolve from the exe's folder. The exe also
   links the MSVC runtime — her machine built it, so the
   runtime is present; on a FUTURE clean machine the static
   CRT would be the answer (-DCMAKE_MSVC_RUNTIME_LIBRARY),
   deliberately not changed blind.
8. **Downloads path**: %USERPROFILE%\Downloads is the brief's
   definition (Environment.SpecialFolder has no Downloads
   member); the folder is created if absent.

## Verification done in this VM

- EncodeService.cs + core + Models.cs compiled with the
  local .NET 8 SDK: 0 warnings, 0 errors.
- All touched .cs files: brace/paren/bracket balance 0.
- MainWindow.xaml: XML well-formed after the edit.
- The shipped zip: extracted to /tmp and grep-verified
  (EncodeService.cs present, Make ISO wiring present,
  CreateImapi untouched in BurnService.cs, tools stage
  present in build-app.cmd) — see the delivery report.
- NOT verifiable here: WinUI compile, the cmake/vcpkg run,
  ffmpeg behavior, and of course the encode itself. Lola's
  machine + a test list + her D-NE1 remain the verdict, in
  that order.

---

## v27 addendum (2026-11-06 evening) — vcpkg removed

v26's first real build stopped at its vcpkg lookup: the vcpkg bundled
with Visual Studio is a separate component, and Lola's VS install (the
WinUI workload + UWP tools + C++ WinUI tools) does not carry it. Rather
than prescribe another VS component install, v27 removes vcpkg from
the design entirely — a build that someday ships to other people
cannot hinge on an optional VS component either.

- libsndfile now arrives like ffmpeg: a pinned download, verified
  before use. The artifact is the project's OFFICIAL prebuilt win64
  zip (this one is versioned, so the pin is stable — no "latest"
  pointer): https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2-win64.zip
  SHA-256 2173935c0c1ed13cf627951d34483f9d405ead2eb473190461c42ba220643a3f
  (2,036,867 bytes; contents verified from the real archive:
  include/sndfile.h, lib/sndfile.lib, bin/sndfile.dll with its
  FLAC/ogg/vorbis deps linked in, cmake/SndFileConfig.cmake).
  Extracted under tools\libsndfile\libsndfile-1.2.2-win64.
- The atracdenc configure drops the vcpkg toolchain flags and passes
  -DCMAKE_PREFIX_PATH="<prefix>;<prefix>\cmake" so both a module-mode
  find (include/ + lib/) and a config-mode find_package(SndFile)
  (cmake/SndFileConfig.cmake) can land. The forced
  ATRACDENC_PCM_IO_BACKEND=libsndfile and the atracdenc-only target
  are unchanged from v26.
- The runtime DLL copied beside atracdenc.exe is now exactly
  bin\sndfile.dll from that archive (v26 copied every DLL from the
  vcpkg bin dir).
- VSROOT is now derived from the MSBuild probe (guarded first-match
  lines); it exists only to locate VS's bundled CMake.
- Nothing else changed in v27: app code, core, and the rest of the
  script are v26 verbatim. If the atracdenc CONFIGURE still cannot
  find libsndfile on Lola's machine, the next knob (from the v26
  notes) is pre-seeding the find module's include/lib cache vars —
  the configure output will say which it wants.

## v28 addendum (2026-11-06 evening) — CMake is a pinned download too

v27's first build stopped one gate later: "CMake was not found."
Visual Studio's bundled CMake is also an optional component, and
Lola's install doesn't carry it (nor is CMake on her PATH). Same
lesson as vcpkg, applied the same way: v28 leans on VS only for
MSBuild + the MSVC compiler, which the app build genuinely needs.

- The script now stages CMake like everything else: prefer the
  pinned copy under tools\cmake\, then any CMake on PATH, else
  download the pinned official Kitware build — cmake 3.31.6
  windows-x86_64 zip, https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.zip
  SHA-256 d163cd3ab4959b0a53fa8988f2ddbd2e6c501658201e6a154386bad9dbe4f836
  (46,473,549 bytes; bin\cmake.exe verified in the real archive).
  3.31.6 chosen deliberately: the vendored atracdenc declares a
  3.1...3.26 policy range, which 3.31 honors cleanly; a 4.x CMake
  would risk old-policy friction for no benefit.
- The VSROOT derivation added in v27 is removed again (it existed
  only to locate VS's CMake).
- Known next risk, stated openly: the atracdenc configure drives
  the "Visual Studio 17 2022" generator, which needs the MSVC
  v143 toolset in her install (expected via the C++ WinUI tools
  optional she ticked + the Windows 11 SDK). If the configure
  reports no compiler, THAT output is the testimony to act on.

## v31 (2026-11-06 late) — NumberBox convicted and replaced

v28 built clean but the app died at startup: Application Error 1000,
faulting module Microsoft.UI.Xaml.dll, exception 0xc000027b, three
launches identical. Bisected the v26 window delta (the encoder, the
Store changes and the build script were exonerated by the v29 control,
which reverted ONLY the window pair and launched): v30a (window minus
the NumberBox) LAUNCHED; v30b (window minus the buttons, NumberBox
kept) DIED. The NumberBox element is the killer in this unpackaged
WinUI setup — mechanism inside the framework unknown, verdict certain.

v31 replaces it with a ComboBox of 1..ProcessorCount (index =
workers − 1), matching the blank picker's proven pattern; the
persisted setting and Store code are unchanged. A warning comment in
MainWindow.xaml records the conviction — do not reintroduce NumberBox.
