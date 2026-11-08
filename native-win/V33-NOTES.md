# DiscWright Windows v33 — the native single-file variant — completion note

Built 2026-11-07 per the v33 brief, BESIDE v32: the wrapper
route in build-app.cmd is untouched and remains the
fallback if the native ladder fails on the gaming PC. Three
changes: (1) app/DiscWright.csproj gains the conditioned
single-file configuration (the ONLY edit to an existing
build file); (2) NEW build-singlefile.cmd drives a native
PublishSingleFile publish through Visual Studio's MSBuild;
(3) STEP3-NOTES.md gains the "v33 — the native single-file
variant" section. Nothing was zipped.

## Changes per file

### app/DiscWright.csproj (only existing file edited)
- In the main PropertyGroup, right after the SelfContained
  line, the brief's conditioned block verbatim:
  EnableMsixTooling, IncludeAllContentForSelfExtract and
  PublishSingleFile, each Condition=
  "'$(DiscWrightSingleFile)' == 'true'", with the brief's
  comment (switched on ONLY by build-singlefile.cmd passing
  /p:DiscWrightSingleFile=true — v32's folder build never
  sees them). Lines 37–39 of the file.
- After the existing DiscWright.ico ItemGroup, a new
  ItemGroup with the same condition (line 88): the three
  encoder tools (..\tools\ffmpeg.exe, ..\tools\atracdenc.exe,
  ..\tools\sndfile.dll) as Content, each Linked into tools\
  in the output, CopyToOutputDirectory and
  CopyToPublishDirectory = PreserveNewest,
  ExcludeFromSingleFile=true — they ride as loose content
  the self-extract carries instead of being embedded in the
  main assembly. The brief's comment block rides above the
  group, explaining the bundling trap: the tools are not
  project content today (build scripts copy them beside the
  exe after the build), so an un-fixed bundle would omit
  them and every encode would fail "ffmpeg was not found";
  EncodeService looks for <base>\tools\ffmpeg.exe /
  atracdenc.exe at runtime.
- Nothing else changed: no App.xaml edits, no package
  changes, the AppxMSBuildToolsPath probes stay, PRI
  generation untouched (ON, unconditional — no .pri =
  0xc000027b, established).

### build-singlefile.cmd (NEW)
- Header in build-app.cmd's voice: what it produces (ONE
  file, DiscWright-singlefile.exe), what PublishSingleFile
  is (Microsoft's own, WASDK >= 1.5, validated by the
  WindowsAppSDKSingleFileVerifyConfiguration target), the
  not-zero-extraction truth (dependencies extract to a temp
  dir at first launch), and that it is an ALTERNATIVE to
  build-app.cmd — both produce one double-clickable file,
  build-app.cmd is untouched and remains the fallback.
- The SAME four-path VS MSBuild probe block as
  build-app.cmd (Community / Professional / Enterprise /
  BuildTools), same not-found shape; the comment states the
  rule plainly: publish runs under VS MSBuild, never
  dotnet build (the PRI/AppX tasks ship only with VS —
  MSB4062 otherwise).
- Tools pre-flight BEFORE MSBuild: tools\ffmpeg.exe,
  tools\atracdenc.exe and tools\sndfile.dll must all exist
  (this script does NOT prepare them); missing → each
  absent file is named and the script says "Run
  build-app.cmd once first, then run this again." and
  exits 1, before anything is built.
- Publish invocation, verbatim per brief:
  "%MSBUILD%" "%ROOT%app\DiscWright.csproj" /restore
  /t:Publish /p:Configuration=Release /p:Platform=x64
  /p:DiscWrightSingleFile=true
  /p:PublishDir="%ROOT%SingleFile\\" /nologo /v:m
  errorlevel 1 → "PUBLISH FAILED - see the errors above.",
  exit 1.
- Deliverable guards (the v20 lesson): SingleFile\
  DiscWright.exe must exist or the script stops loudly;
  its size is measured and echoed; the publish folder's
  file count is computed (dir /b | find /c) and echoed for
  the record — NOT hard-failed, since the exact loose-file
  behavior of the verify target is part of what her run
  proves.
- The exe is copied to DiscWright-singlefile.exe beside
  the script (copy failure and missing-result both stop
  loudly). Final echoes: PUBLISH SUCCEEDED, the single
  file's path, first-launch extraction note, and the
  fallback line pointing at build-app.cmd's
  DiscWright-standalone.exe.
- Batch discipline: every path quoted, no '&' mid-line
  separators, parenthesized IF blocks for multi-command
  conditions. Re-read top to bottom after writing (see
  Verification).

### STEP3-NOTES.md
- Appended "## v33 — the native single-file variant
  (2026-11-07)" after the v32 section: the CORRECTION
  (v32's "WinUI 3 does not support .NET single-file
  publishing" premise is outdated — supported since WASDK
  1.5; v32's text stays as the record of what was believed,
  Route A exists, Route B stands as fallback); the
  three conditioned properties + the tools-as-content fix
  for the bundling trap (EncodeService's <base>\tools
  lookups; ExcludeFromSingleFile so self-extract carries
  them loose); publish via VS MSBuild only; the extraction
  difference (native = TEMP at first launch, wrapper =
  persistent %LOCALAPPDATA% folder — user-visible nil,
  maintenance = standard publish output vs custom
  bootstrapper); and the gaming-PC verification ladder:
  1) exe launches (PRI survived extraction — 0xc000027b
  would say otherwise), 2) Burn Disc on a small list does
  NOT stop at "…was not found in the app's tools folder"
  (titlebar DW icon as soft signal), 3) encode completes
  and the burn offer appears, 4) burn finishes, 5) the
  D-NE1 plays it — any rung failing = the v32 wrapper
  stands, nothing lost. Plus the cheap %TEMP%\.net
  extraction peek between rungs 1 and 2.

## Verification (run in this VM, 2026-11-07)

```
--- csproj XML parse ---
python3 xml.etree.ElementTree.parse(app/DiscWright.csproj)
csproj: well-formed XML OK

--- grep -c "DiscWrightSingleFile" app/DiscWright.csproj ---
6
(3 property conditions, lines 37-39; 1 ItemGroup
condition, line 88; 2 comment mentions, lines 33 and 87.
The brief estimated 5; the actual count is 6.)

--- grep -c "DiscWrightSingleFile" build-singlefile.cmd ---
1   (the /p:DiscWrightSingleFile=true on the publish line)

--- grep -n "dotnet" build-singlefile.cmd ---
35:rem Build with Visual Studio's MSBuild, NOT the "dotnet"
(the ONLY occurrence - a comment explaining the dotnet
command is NOT used; the publish itself is VS MSBuild)

--- build-app.cmd UNMODIFIED (before/after identical) ---
mtime: 2026-11-07 19:24:16.312804128 +0000 (unchanged)
size:  22237 bytes (unchanged)
grep -c "DiscWright-standalone" build-app.cmd: 7 (before 7)
line 343: set "STAMP=2026-11-07.v32" (intact)

--- core build (untouched core, tree-coherence check) ---
dotnet build core/DiscWright.Core.csproj -v q --nologo
Build succeeded. 0 Warning(s) 0 Error(s)

--- build-singlefile.cmd discipline ---
Re-read top to bottom once after writing: quoted paths
throughout; parenthesized IF blocks where multiple
commands depend on one condition; no '&' separators;
the tools pre-flight names each missing file individually
before exiting.
```

## NOT verified here (her gaming PC is the check)

- No VS MSBuild / Windows App SDK in this VM: the publish
  itself runs only on her gaming PC. The csproj conditions
  are inert unless /p:DiscWrightSingleFile=true is passed,
  so the v32 folder build cannot be affected by them — but
  the single-file publish's own verdict (and each rung of
  the ladder in STEP3-NOTES) is hers to run.
- The publish folder's exact loose-file set under
  IncludeAllContentForSelfExtract is deliberately reported,
  not asserted, by build-singlefile.cmd — what the verify
  target leaves beside the exe is part of what her run
  establishes.
