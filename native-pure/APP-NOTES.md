# DiscWright — native app, Step 2 notes

Step 2 puts the SwiftUI face on the byte-proven Swift core
(`core/`, untouched this step). Build with `./build-app.sh`
(Terminal, macOS) → `DiscWright.app` next to the script.

## Structure (all under `app/`)

| File | What it is |
|---|---|
| `DiscWrightApp.swift` | `@main` App; one WindowGroup titled "DiscWright — ATRAC3+ CD ISO maker", default size 1180×820. |
| `Models.swift` | `TrackItem` / `GroupItem` (UI working models — NOT the core's `DiscTrack`/`DiscGroup`), `fmtDuration` and `mbString` (the web app's formatters). |
| `Store.swift` | `DiscStore` (`ObservableObject`, `@MainActor`): groups/tracks, imported state, blank selection, log lines; every list operation, intake, capacity, import, burn wiring. |
| `TagReader.swift` | Port of the web app's `tagsFor` path: ID3v2 (TIT2/TPE1/TALB; v2.3/v2.4 frame sizes; encodings Latin-1 / UTF-16+BOM / UTF-16BE / UTF-8) → ID3v1 trailer → filename fallback (extension dropped, `_`→space). |
| `BurnService.swift` | The burn, adapted from the superseded shell's proven code: confirm alert ("Burn this disc now?"), `Process` → `/usr/bin/drutil burn <path>`, result alert with drutil's output. |
| `TrackRow.swift` | One row: Title/Artist/Album fields, duration or ⚠ error, ↑ / ↓ / Move menu / ✕. Imported: fields disabled, no buttons. |
| `ContentView.swift` | Controls bar, capacity bar, the sectioned List, the action row, the log. |
| `Info.plist` | Adapted from `native-mac/Info.plist` (same bundle id `com.glitcheddot.discwright`); version 0.2; `LSMinimumSystemVersion` raised 11.0 → **13.0** (see risks). |

## Behavior mapping (web app → here)

- **Groups**: header = "Group:" + editable name field + "Remove
  group" (only when >1 group). Removal moves its tracks to the
  previous group — or the next one when removing the first —
  exactly the web rule.
- **Tracks**: ↑/↓ swap with the neighbor; ✕ removes; the Move
  menu appends to the chosen group's end (the web's select does
  the same); drag reorder within a group via List `onMove`
  (hand-rolled IndexSet semantics in the store).
- **Add Files**: `UTType.audio` panel, multi-select; files join
  the LAST group. Tags load via `TagReader`; duration via
  AVFoundation (`AVURLAsset.load(.duration)`), samples =
  round(seconds × 44100) — the web app's capacity basis. A file
  whose tags/duration can't be read still joins, flagged
  "could not decode this file" in the duration cell (the web's
  error string).
- **Add Folder**: single-directory panel. Audio extensions
  mp3/m4a/wav/flac/ogg/aif/aiff, regular files only, hidden files
  skipped, in path order; depth = folders between the picked
  root and the file, ≤ 2 collected, deeper counted as skipped.
  All files join a group named after the folder — created, or
  reused if a group already has that name. Both of the web app's
  log lines are mirrored ("Folder scan: added…", "Folder "X"
  became a group (N tracks).").
- **Capacity**: identical math — per-track frames
  (samples/2048 + 1) × 376 + 1120, NDB sizes from the core's own
  `writeNdb`, fixed STI/STK sizes, through the core's
  `isoSectorCount`, + 11,709 overhead sectors, against the blank.
  Text format matches the web ("N tracks · X MB of Y MB — over
  capacity!"); the bar tints red when over. Blank picker: the
  core `BLANKS` six, in the web's order, plus a Custom… entry
  with a sector field (the web picker has no Custom — it exists
  only as a fallback word in capacity error text — but the Step 2
  brief asked for it; it changes nothing unless selected).
- **Import ISO**: panel (`.iso`) → `Data` → the core's
  `parseAtracDisc` → the list is REPLACED by imported groups/
  tracks (samples = seconds × 44100, `.ATP` sizes kept). Intake
  controls are disabled, fields disabled, no row buttons, no
  remove-group, `onMove` off. Capacity line switches to the
  web's imported wording ("Imported disc "name" — N tracks ·
  X MB (the ISO itself)"); the bar shows the ISO's share of the
  selected blank (the web pins it at 100% — the one deliberate
  divergence, noted here). "✕ Clear imported disc" appears only
  in this mode and restores one empty editable "Group 1".
- **Burn Disc**: sits BESIDE Import ISO (the user's explicit
  layout requirement), large/prominent. Enabled only with an
  imported ISO loaded (and not while a burn runs): confirm →
  drutil → result, via `BurnService`. The launch log carries
  the required line verbatim: "Encoding arrives in the next
  build; Import ISO + burn works now." A caption beside the
  buttons says the same while no disc is imported.

## Intentionally NOT in this step

- **Encoding / authoring a new disc** (Step 3): no atracdenc
  bridge, no `buildDisc` call from the UI. Burn Disc for a
  non-imported list is disabled rather than faking a build.
- **The web app's cleaned-tag MP3 export** — not in the brief.
- **Drag-and-drop from Finder** onto the window (the web app
  has it; the brief's intake is panels only). List drag
  REORDERING is in.
- **The web app's "now playing / library" info readouts** and
  its disc-theatre stage — web-GUI furniture, not native app.
- **Multi-folder pick** in one panel pass (the web's folder
  picker can carry several roots; pick folders one at a time —
  groups are reused by name, so the result converges).
- **Security-scoped bookmarks**: the app is not sandboxed (no
  entitlements, ad-hoc signed), so panel URLs are directly
  readable, including at burn time. If the app is ever
  sandboxed for distribution, bookmarks become necessary.

## Compile risks (no Swift compiler in the build VM — the Mac
build is the first real check, as with Step 1)

1. **`@main` + bare swiftc**: `build-app.sh` passes
   `-parse-as-library` so `DiscWrightApp.swift`'s `@main` is the
   entry point. If the link instead complains about a missing
   main, that flag is the knob (its opposite failure — "top-level
   code" complaints — would point the other way).
2. **List binding iteration**: `ForEach($store.groups)` /
   `ForEach($group.tracks)` with `$group.wrappedValue` reads is
   the documented macOS 12+ pattern; isolated oddities (e.g. a
   header field losing focus per keystroke) would be the thing
   to report, not a redesign.
3. **`onMove` on macOS**: a macOS List may only engage drag
   reorder in edit mode. Up/down buttons and the Move menu are
   the guaranteed reorder paths either way (the brief requires
   both, deliberately).
4. **AVFoundation `load(.duration)`** is macOS 13+ — hence
   `LSMinimumSystemVersion` 13.0. On the user's Tahoe system
   this is a non-issue; the app simply won't launch on 11/12.
   (Fallback if ever needed: the deprecated synchronous
   `asset.duration`.)
5. **`UTType(filenameExtension: "iso")`** may be nil on some
   systems; the import panel then just shows all files (the
   assignment is guarded).
6. **`String(bytes:encoding: .isoLatin1)`** is failable in
   signature only — Latin-1 decoding cannot actually fail; the
   `?? ""` covers the type.
7. **SwiftUI minors**: `ProgressView.tint`, `.listStyle(.inset
   (alternatesRowBackgrounds:))`, `WindowGroup.defaultSize`,
   single-argument `onChange(of:)` — all macOS 12–13 APIs,
   consistent with the 13.0 floor.
8. **NSAlert from a SwiftUI app** (BurnService): `runModal`
   works without a nib because SwiftUI installs the app object;
   the standard Edit menu also comes free with SwiftUI (unlike
   the nib-less shell, which had to build one by hand).

## Step 2.5 — the look, natively (restyle)

The plain stock-SwiftUI face worked but had none of the look
GlitchedDot art-directed for the web app, so Step 2.5 brings
that look back as a native skin: palette + disc stage +
typography, inside a real Mac window (the fake Windows 7
chrome stays dead). No functionality changed: same controls,
bindings, list behavior, import behavior, capacity math. Two
files added (`Theme.swift`, `DiscStageView.swift` — both
picked up by build-app.sh's `app/*.swift` glob), three
restyled (`ContentView.swift`, `TrackRow.swift`), and two got
minimal wiring (`Store.swift`, `BurnService.swift`).

### What was themed

- **Backdrop**: the window sits on the web client's indigo
  gradient (ss-blue-2 → ss-blue), with two lavender panes
  (#eceefc, 1px #0d0f45 border, radius 3) laid out like the
  web's Create a CD: "My Library" (intake + list) on the left,
  "ATRAC CD" (stage, blank, capacity, actions) on the right,
  the log across the bottom. Pane headers mirror the web's
  .panehead, including the right pane's "Drive: ISO image".
- **Header band**: the SonicStage modetab purple
  (#4b34b8 → #2a1a7e) carrying a mini silver disc glyph (the
  web titlebar's .app-icon: conic silver ring, #123a82 hub),
  the "DiscWright" wordmark in white with the
  "ATRAC3+ CD ISO maker" subtitle in #b9bef5, and the web's
  one visible mode tab as a pill ("Create a CD", #191970 on
  #e3e6ff → #b9c0f2, #0d0f45 ring).
- **Group sections**: header strips in the .group h3 gradient
  (#f7fafc → #dde8f1) with #17324e "Group:" text and a
  #b9cbd9 bottom rule; rows white with #e6edf3 separators
  (the web's td border).
- **Capacity meter**: a custom bar replacing the stock
  ProgressView — white track, #6d6d6d border, and her exact
  indigo fill #7d84e8 → #3a2a9e, switching to the red
  #f08a8a → #c81e1e gradient only when over capacity.
- **Log**: white pane with the web's #9aa1d6 border,
  monospaced 12pt, #14141c text.
- **Buttons/rows**: Burn Disc is `.borderedProminent` tinted
  ss-blue-2; duration text is the web's #333, the ⚠ error the
  palette's --bad #c81e1e (was system orange/secondary).
- **The disc stage** (`DiscStageView.swift`): see below.

### Palette (Theme.swift — every value from the web CSS)

From `:root`: ss-blue #1a1e6e, ss-blue-2 #232a86,
ss-lav #c2c9f4, ss-lav-light #d6dbf8, ss-pane #eceefc,
ss-gray #8d8d8d, ss-gray-dark #5f5f5f, text #14141c,
bad #c81e1e. From component rules: deep border #0d0f45
(.pane/.modetabs), subtitle-on-blue #b9bef5, stage-status
#3c4170, log border #9aa1d6, meter border #6d6d6d, group
card border #9db2c4, group header text #17324e / rule
#b9cbd9, row separator #e6edf3, duration #333333, small
text #43435a, hub label #eef1ff / sub-line #aab3d6, glyph
hub #123a82, mode-tab-on text #191970. Gradients: client
ss-blue-2 → ss-blue; header #4b34b8 → #2a1a7e; mode pill
#e3e6ff → #b9c0f2; meter #7d84e8 → #3a2a9e; meter-full
#f08a8a → #c81e1e; group header #f7fafc → #dde8f1.

### How the disc painting mirrors drawDisc()

One SwiftUI `Canvas` inside a `TimelineView(.animation)` —
the whole disc (shadow, base, sheen, laser, hub, label) is
painted into that single bitmap under one squash transform;
no layered or transformed views (the web's black-bar lesson,
honored in spirit). Ported number-for-number from app.js:

- **Spin**: vertical-axis globe spin, scaleX = max(|cos|, 0.02),
  tilt scaleY = 0.94; back face (plain-silver gradient) when
  cos < 0. Idle 80°/s (the web's SPIN_DEG_PER_SEC); while
  burning 200°/s, per the brief's "idle spin is slower".
  Angles integrate piecewise via @State phase bases re-based
  in `onChange(of: isBurning)`, so speed changes never jump.
- **Bob**: idle only, sin(t / 2.6 s) × 0.0528 R, drawn inside
  the painting (the web draws it in-canvas too).
- **Shadow**: ellipse 0.791 R × 0.1055 R centered 1.348 R
  below disc center (the web's 27cqw × 3.6cqw at +23cqw),
  black 0.55 → 0 at 70%, scaleX = 0.35 + 0.65|cos|; hidden
  while burning, as the web shows it only in its idle state.
- **Base gradients**: both stop tables verbatim (front:
  hub-dark #20242b to 0.21, translucent silver
  rgba(215,222,240,0.20) band, #3a4150 rim; back: the silver
  data side #c8cedb / #dfe4ef / #b9c0cf).
- **Sheen**: the web's 11-stop rainbow (front) / 6-stop
  (back, fixed 200° start) as an angular gradient; rotates
  at 150°/s only while burning, like the web's burnStep.
  Edge-on shade rgba(0,0,0,(1−|cos|)·0.30) when |cos| < 0.999.
- **Hub**: radius 0.387 R, radial gradient from offset
  (−0.3 hr, −0.4 hr), #2c313b → #191d23, rim stroke
  rgba(255,255,255,0.14). Label "ATRAC CD" wrapped to
  1.78 hr (max 3 lines, the web's algorithm, widths via
  ResolvedText.sizeThatFits) over "ATRAC3+ · 64 kbps"
  (#aab3d6), both in **Comic Sans MS** bold/regular — the
  web label's face, which ships with macOS.
- **Laser** (burning only, front face): Bottom stop (90°,
  the user's saved default), radius by the area law
  r = sqrt(rIn² + f·(rOut² − rIn²)), rIn/rOut = 31/111 and
  105/111 of R; spot radius 0.055 R with the web's 5-stop
  red falloff (255,0,0,0.95 → 255,150,110,0); flicker level
  0.88–1.0 re-rolled in ~160 ms buckets (a deterministic
  sin-hash stands in for the web's Math.random re-rolls).
  **One honest fudge**: drutil reports no progress to the
  store in this step, so f is paced cosmetically — a full
  outward pass over 6 minutes from burn start. When a real
  encode/burn progress feed lands (Step 3), f should be
  driven from the store instead.
- **Status line** under the stage: `store.stageStatus`,
  bold, #3c4170, idle text exactly the web's
  "Please select a type of disc."
- **Reduced motion**: the TimelineView pauses and the disc
  paints static and front-facing, echoing the web's
  prefers-reduced-motion handling.

### Wiring (Store / BurnService)

- `DiscStore.burning` renamed to the brief's `isBurning`
  (same semantics; `burnEnabled` unchanged in effect), plus
  `@Published stageStatus` (idle default above; set to
  "Writing — burning the disc…" on burn start, "Your disc is
  ready. 💿" / "Something went wrong — see the log below."
  on finish — the web's status phrases; reset to idle by
  Clear Import).
- `BurnService`'s Bool callback became `BurnState`
  (.started / .finished(success:)); the alerts, the drutil
  invocation, and the result handling are byte-for-byte the
  Step 2 behavior.

### Compile risks (Step 2.5 additions; still no Swift
compiler in the build VM)

1. **`GraphicsContext.Shading.angularGradient`** — used for
   the sheen. It is a documented macOS 12+ shading; if the
   installed SDK disagrees, the fallback is painting the
   sheen as ~72 wedge slices interpolated from the same stop
   table. Related cosmetic risk: if SwiftUI's angular 0°
   sits at 12 o'clock where canvas2D's conic 0 rad sits at
   3 o'clock, the sheen (only the sheen — the laser uses my
   own trig) will read rotated 90°; the fix is a constant
   −90° on the sheen start angles in DiscStageView.
2. **Shading under a context transform**: the port relies on
   gradients being evaluated in the context's current user
   space (true of CG-backed GraphicsContext fills, and the
   whole squash design depends on it). If a gradient ever
   rendered un-squashed, that assumption is the suspect.
3. **`ResolvedText.sizeThatFits(ProposedViewSize)`** —
   macOS 13 API used for the label wrap. The label is the
   constant "ATRAC CD" and fits on one line at any plausible
   width, so even a surprise here is cosmetic.
4. **List section-header backgrounds**: the group strip's
   gradient/overlay renders inside the List header area; on
   macOS the header's own insets may leave the strip narrower
   than the rows. Cosmetic only.
5. **`.listRowSeparatorTint` / `.scrollContentBackground`** —
   macOS 13 APIs, consistent with the 13.0 floor.
6. **TimelineView + Canvas at 60 fps** with the full disc
   painting is a modest per-frame cost (a handful of gradient
   fills); if the 2014 MacBook Pro's GPU/CPU minds, dropping
   the minimumInterval to 1/30 is a one-line change.
7. **Header `AngularGradient`** (the glyph) is the classic
   ShapeStyle API, unrelated to risk 1's Canvas shading.

## Step 3 — encode bridge, system appearance, selectable workers

### Part A — appearance: follow the system, both designed

The v5 `.preferredColorScheme(.light)` pin is GONE. GlitchedDot
likes dark mode, so the app now follows the system appearance
with BOTH appearances designed, via `Palette` in Theme.swift:

- `Palette.light` IS the approved Step 2.5 look — every field is
  the corresponding Step 2.5 Theme constant, so light mode is
  unchanged pixel-for-pixel.
- `Palette.dark` is the same identity at night:

| Surface | Light (approved) | Dark (Step 3) |
|---|---|---|
| Pane | #eceefc | #23265e |
| Pane text | #14141c | #e6e9ff |
| Secondary text | #5f5f5f | #aab0e8 |
| Group header strip | #f7fafc→#dde8f1 | #2a2e63→#1e214e |
| Group header text | #17324e | #dfe4ff |
| Group header rule | #b9cbd9 | #3a3f7d |
| Row background | white | #262a66 |
| Row separator | #e6edf3 | #343a75 |
| Log pane | white bg, #14141c text | #14163a bg, #d6dbf8 text |
| Meter track | white | #14163a |
| Stage status | #3c4170 | #c9cdf5 |
| Duration text | #333333 | #c9cdf5 |

Appearance-neutral pieces stay shared in Theme: the client
gradient + ribbons, the header band and mode pill, the meter
FILLS (indigo / over-red), the log border #9aa1d6, and the
entire disc painting (it reads on both appearances). Wiring:
ContentView, TrackRow and DiscStageView read
`@Environment(\.colorScheme)` and take `Palette.of(scheme)`;
DiscStore holds no appearance state.

### Part B — encoding new discs, end to end

Pipeline per track (app/EncodeService.swift):
AVAssetReader (output settings force 44.1 kHz / stereo /
16-bit integer PCM — the reader resamples and down/up-mixes)
→ streamed to a canonical WAV in a per-track temp dir
(NSTemporaryDirectory/DiscWrightEncode-<uuid>/track-<i>/)
→ `atracdenc -e atrac3plus --bitrate 64 --container raw
-i in.wav -o out.raw` (CLI verified against the vendored
src/help.cpp + src/main.cpp — see STEP3-NOTES.md)
→ frames read back, validated (non-empty, whole 376-byte
frames) → core `buildDisc` (fresh random 16-byte DiscID, one
random 8-byte IV per track, blank's sector count as capacity)
→ ISO written to ~/Downloads/atrac-disc.iso (path logged)
→ the established BurnService "Burn this disc now?" offer →
drutil. Declining the offer keeps the ISO and says so in the
log. ANY track failure aborts before authoring: no ISO, the
log names the track and the reason.

- **Workers (the user's explicit requirement)**: "Encode
  workers" Stepper in the right pane under the capacity bar,
  1…ProcessInfo.activeProcessorCount, labeled "N of M threads".
  Default min(max(cores−1,1),8) (the web app's rule); persisted
  in UserDefaults key `encodeWorkers`. The count is the
  OperationQueue's maxConcurrentOperationCount — a real cap;
  each job (decode+encode) is one operation in its own temp
  subdir, and results are slotted by playlist index, so the
  authored order is exact regardless of finish order.
- **Progress**: the store publishes encodeProgress — 0.85 ×
  (done/total) while encoding, 1.0 through authoring and burn.
  stageStatus follows the web's wording family:
  "Writing — N of M tracks encoded". DiscStageView's laser is
  driven by this REAL fraction now; the Step 2.5 cosmetic
  6-minute pacing survives only as the fallback for burns with
  no encode behind them (imported ISOs via drutil, which
  reports no progress).
- **Cancel**: a Cancel button appears in the action row while
  encoding; it cancels the queue and terminates running
  atracdenc processes. Temp dirs are removed on every exit path.
- **Removed**: the launch line "Encoding arrives in the next
  build…" and the matching action-row footnote are gone; the
  footnote now describes the real flow. If the bundled encoder
  is missing, launch logs a plain warning and Burn Disc (new
  list) refuses with a clear log line — Import ISO + burn is
  unaffected.

### The encoder: vendored + built by build-app.sh

- Source: `encoder/atracdenc-src/` — a pruned copy of
  atracdenc-test @ cb17070: top CMakeLists.txt, LICENSE, man/,
  and src/ intact. NOT vendored: build/, test/, e0_profile/,
  tools/, debian/, .git. src/CMakeLists.txt references no
  *_ut.cpp (those belong to test/), so src/ compiles as-is.
- build-app.sh checks FIRST (before any compiling): cmake and
  libsndfile (brew prefix, /opt/homebrew, /usr/local, or
  pkg-config). Missing either → it stops with the exact fix,
  `brew install cmake libsndfile`, and exits non-zero. It never
  installs anything itself.
- Build: `cmake -S encoder/atracdenc-src -B encoder/build
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE`
  (GTest off explicitly — the un-vendored test/ tree is only
  added upstream when GTest is found), then
  `cmake --build encoder/build -j`. Upstream sets
  CMAKE_OSX_ARCHITECTURES "arm64;x86_64" on APPLE, so the
  binary is universal (first build is the slow one). A SHA-256
  stamp of the vendored sources (encoder/build/.source-stamp)
  skips the rebuild when nothing changed. The binary is copied
  to DiscWright.app/Contents/Resources/atracdenc and found at
  runtime via Bundle.main.
- Runtime note: the bundled atracdenc links Homebrew's
  libsndfile dynamically, so the Mac needs libsndfile present
  at run time too (it is, on any machine that built the app).
  Bundling the dylib is a packaging-step (Step 4) concern.
- Info.plist version bumped 0.2 → 0.3. macOS floor stays 13.0;
  everything used (AVAssetReader track output, OperationQueue,
  FileHandle.write(contentsOf:)) is macOS 13-compatible.
