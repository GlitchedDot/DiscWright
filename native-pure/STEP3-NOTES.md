# Step 3 — progress notes (written incrementally)

## Plan
- Part A: remove `.preferredColorScheme(.light)` pin; appearance-aware
  `Palette` in Theme.swift (light = approved v5 values verbatim; dark =
  designed in-family); wire `@Environment(\.colorScheme)` in
  ContentView / TrackRow / DiscStageView status line.
- Part B: vendor atracdenc, build in build-app.sh, EncodeService
  (AVAssetReader decode → WAV → atracdenc → frames), Store encode flow,
  workers control (UserDefaults "encodeWorkers"), real laser progress,
  cancel button.

## atracdenc CLI — verified from vendored source (src/help.cpp)
```
atracdenc {-e <codec> | --encode=<codec> | -d | --decode} -i <in> -o <out>
--container		explicitly select output container: aea, oma, riff, rm, raw
--bitrate		allow to specify bitrate (for ATRAC3 + RealMedia container only)
```
src/main.cpp: getopt_long string "e:dhi:o:m"; longopts include
encode (optional_argument), bitrate (required), container (required).
`atrac3plus` accepted for -e. NO positional args allowed ("Unhandled arg").
=> Recipe used: `atracdenc -e atrac3plus --bitrate 64 --container raw -i <in.wav> -o <out.raw>`
(the standing hardware-proven recipe; --bitrate is the ladder selector).

## CMake structure (from atracdenc-test, HEAD cb17070)
- Top CMakeLists: add_subdirectory(src); UNIX man target needs
  man/atracdenc.1; APPLE sets CMAKE_OSX_ARCHITECTURES "arm64;x86_64";
  add_subdirectory(test) ONLY if GTest found -> our build passes
  -DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE so the un-vendored test/
  dir is never required. Integration add_test() entries reference
  test/*.py only at ctest time (never run).
- src/CMakeLists.txt: does NOT reference any *_ut.cpp (those belong to
  test/) -> vendoring src/ intact (incl. _ut files) is safe; they are
  simply never compiled. PCM backend on macOS = libsndfile
  (FindLibSndFile.cmake in src/cmake/modules).

## Core API used (Author.swift, untouched)
buildDisc(tracks:groups:discId:ivs:capacitySectors:timestamp:) throws
- DiscTrack{frames,title,artist,album}; DiscGroup{name,first,last} 1-based.
- discId = 16 random bytes, ivs = one random 8-byte IV per track
  (web app.js: crypto.getRandomValues for both).

## Log
- [start] sources read: APP-NOTES (at native-pure/APP-NOTES.md),
  Theme, Store, ContentView, BurnService, DiscStageView, TrackRow,
  Models, DiscWrightApp, Info.plist, build-app.sh, core/Author+Atrac.
- [done] atracdenc vendored -> encoder/atracdenc-src/ (2.3 MB:
  CMakeLists.txt, LICENSE, man/, src/ intact; test/build/tools/
  debian/e0_profile/.git excluded).
- [done] Part A: Palette in Theme.swift (light = Theme constants;
  dark designed); ContentView/TrackRow/DiscStageView wired to
  @Environment(\.colorScheme); .preferredColorScheme pin removed.
- [done] app/EncodeService.swift: AVAssetReader decode->WAV
  (streamed, header patched at end), atracdenc Process (stdout/
  stderr to a per-track log file, never a pipe), OperationQueue
  cap = workers, index-slotted results, EncodeHandle cancel
  (queue cancel + process terminate).
- [done] Store: encodeWorkers (UserDefaults "encodeWorkers",
  default min(max(cores-1,1),8), clamped to activeProcessorCount),
  encodeProgress/isEncoding published, burnDiscClicked new-disc
  flow (snapshot jobs/groups -> encode -> buildDisc(random
  discId/IVs, blank capacity) -> ~/Downloads/atrac-disc.iso ->
  offerBurn with onDeclined), cancelEncode().
- [done] BurnService.offerBurn gained optional onDeclined.
- [done] ContentView: workersRow (Stepper 1...maxWorkers,
  "N of M threads") under capacityBar; Cancel button while
  encoding; footnote replaced; CapacityMeter takes palette track.
- [done] DiscStageView: laser fraction = store.encodeProgress
  when present, 6-minute pacing only as fallback (imported-ISO
  burns); header comment updated — the fudge note is gone.
- [done] build-app.sh: cmake+libsndfile pre-check (stops with
  `brew install cmake libsndfile`, exit 1, before compiling),
  stamped atracdenc build (GTest find disabled), binary copied
  to Contents/Resources/atracdenc. Info.plist 0.2 -> 0.3.
- [todo: user] Mac build = compile check; watch for: Swift
  concurrency warnings (default mode is lenient), the
  asset.tracks(withMediaType:) deprecation warning on the
  newest SDK (harmless), Stepper label form.
