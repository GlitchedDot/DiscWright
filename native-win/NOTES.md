# DiscWright native-win — C# port of the JS authoring core

Step 1 of the native Windows rebuild (Stage 3): the proven JS
core (`~/workspace/atrac-web-app/core/`), already ported once to
Swift (`~/workspace/atrac-web-app/native-pure/core/`, byte-parity
proven on the user's Mac), ported mechanically to C# / .NET 8,
plus a command-line self-test that rebuilds the reference
fixture and compares it against `expected.iso`. The Swift port
is the structural mirror; the JS remains the semantic reference.
The core is a UI-free class library (`DiscWright.Core`) so the
Step 2 face (WPF or WinUI) consumes it unchanged.

Build & check (**cmd** or **PowerShell**, Windows):

```
cd native-win
build-selftest.cmd ..\reference
```

(build-selftest.cmd checks for the .NET 8 SDK and prints the
exact fix — `winget install Microsoft.DotNet.SDK.8` — if it is
missing; then builds Release and runs the self-test against the
reference folder given as its argument.)

Expect: md5 `4528977b9bb7e8e1cf9a2e18dce41303`, 131 sectors,
268,288 bytes, `BYTE-IDENTICAL`, reader smoke-parse
3 tracks / 2 groups, exit 0.

VERIFIED IN THE PORTING VM (2026-11-06): the .NET 8 SDK
(8.0.427, Linux) was installed locally and the self-test was
actually run — see the bottom of this file for the result.
Unlike the Swift port, this one does not ship blind.

## Swift/JS → C# API mapping

All byte strings are `byte[]` (JS `Uint8Array`, Swift `[UInt8]`);
all file maps are `Dictionary<string, byte[]>` /
`Dictionary<string, int>`. JS `throw` / Swift `throws` →
exceptions: `DiscCoreException` (defined in Des.cs, mirroring
Swift's arrangement) and `CapacityException` for capacity.cs's
error. Module boundaries match the Swift files one for one;
methods are PascalCase, constants keep their JS/Swift names.

| Swift (native-pure/core/) | C# (native-win/core/) |
|---|---|
| Des.swift `desEncryptBlock(key8:block8:)` | Des.cs `Des.DesEncryptBlock(key8, block8)` |
| Des.swift `desDecryptBlock` | Des.cs `Des.DesDecryptBlock` |
| Des.swift `edeEncryptBlock(key16:block8:)` | Des.cs `Des.EdeEncryptBlock` — E_K1∘D_K2∘E_K1 composed from single-DES transforms, same order as JS/Swift |
| Des.swift `edeDecryptBlock` | Des.cs `Des.EdeDecryptBlock` — D_K1∘E_K2∘D_K1 |
| Des.swift `desCbcEncrypt(key8:iv8:data:)` | Des.cs `Des.DesCbcEncrypt` — one CBC transform, PaddingMode.None |
| Des.swift `desCbcDecrypt` | Des.cs `Des.DesCbcDecrypt` |
| Text.swift `clampString(_:) -> [UInt32]` | Text.cs `Text.ClampString(s) -> int[]` (code points) |
| Text.swift `utf16be(_)`, `utf16beClamped(_:)` | Text.cs `Text.Utf16Be`, `Text.Utf16BeClamped` |
| Atrac.swift `D2`, `V_KEY`, `CONNUM`, `TRACK_SLOT`, `MGD`, `FRAME_SIZE` | Atrac.cs same names (`V_KEY` spelled `VKey`, C# style) |
| Atrac.swift `blockSeed(discId:bindIndex:)` | Atrac.cs `Atrac.BlockSeed(discId, bindIndex)` |
| Atrac.swift `icv(discId:sizes:)` | Atrac.cs `Atrac.Icv` — `unchecked` UInt64 wrap fold |
| Atrac.swift `encryptPayload(frames:iv:)` | Atrac.cs `Atrac.EncryptPayload` |
| Ndb.swift `writeNdb`, `NDB_HEADER_LEN`, `NDB_RECORD_LEN` | Ndb.cs `Ndb.WriteNdb`, same constants |
| Header.swift `headerToBytes(_:)`, `HEADER_LEN` | Header.cs `Header.HeaderToBytes(SecureHeaderFields)`, `Header.HeaderLen` |
| Sti.swift `writeToc`, `writePlf`, `framesToSeconds` | Sti.cs `Sti.WriteToc`, `Sti.WritePlf`, `Sti.FramesToSeconds` |
| Stk.swift `STK_BYTES`, `STK_FILENAME` | Stk.cs `Stk.StkBytes`, `Stk.StkFilename` |
| Id3.swift `writeTag(title:artist:album:)`, `TAG_LEN` | Id3.cs `Id3.WriteTag`, `Id3.TagLen` |
| Iso.swift `writeIso(files:volIdent:timestamp:)`, `isoSectorCount(_:)`, `ISO_SECTOR` | Iso.cs `Iso.WriteIso(files, volIdent, timestamp)`, `Iso.IsoSectorCount`, `Iso.IsoSector` |
| Capacity.swift `checkCapacity`, `SESSION_OVERHEAD_SECTORS`, `BLANKS`, `SECTOR` | Capacity.cs `Capacity.CheckCapacity`, same constant names |
| Author.swift `buildDisc(...) -> BuildDiscResult` | Author.cs `DiscAuthor.BuildDisc(...) -> BuildDiscResult`; `DiscTrack`, `DiscGroup`, `DiscTimestamp`, `DiscStats` classes |
| Author.swift `trackFilename`, `ATP_OVERHEAD` | Author.cs `DiscAuthor.TrackFilename`, `DiscAuthor.AtpOverhead` |
| IsoRead.swift `readIsoFiles(_:)`, `parseAtracDisc(_:)` | IsoRead.cs `IsoRead.ReadIsoFiles`, `IsoRead.ParseAtracDisc` → `ParsedDisc` / `ParsedGroup` / `ParsedTrack` |

## Semantic traps — carried over from the Swift port, re-checked for C#

(Numbering follows native-pure/NOTES.md; only the C#-specific
handling is described. Anything not mentioned behaves exactly
as the Swift port documents.)

1. **DES.** .NET's `DES.Create()` with `CipherMode.ECB` /
   `CipherMode.CBC` and `PaddingMode.None`, one
   `TransformFinalBlock` per CCCrypt one-shot. The EDE
   composition is three separate single-DES transforms in
   des.js's exact order — NOT `TripleDES`, whose keying
   semantics are not the JS's. Two .NET-specific notes:
   (a) .NET DES rejects *known weak keys* on key assignment;
   every key in this system is a held constant (d2, V) and none
   is weak or semi-weak, so the check can never trip here —
   but it means Des.cs is not a general-purpose DES utility.
   (b) .NET ignores DES parity bits, as do CommonCrypto and
   the JS key schedule.
2. **ICV fold.** C# `ulong` arithmetic in an explicit
   `unchecked` block: `x = x * (ulong)s + b` wraps mod 2^64,
   the same operation as JS BigInt-with-mask and Swift `&*`/`&+`.
3. **String clamping by UTF-16 code unit, over code points.**
   C# strings are UTF-16. Iteration uses
   `string.EnumerateRunes()`, which yields one `Rune` per
   Unicode scalar and yields U+FFFD for any invalid sequence —
   the same observable behavior as Swift's `unicodeScalars`
   iteration (a C# string built by System.Text.Json, like a
   Swift String, cannot carry a live lone surrogate into this
   code). The clamped result is carried as `int[]` code points,
   and `Utf16Be` computes surrogate pairs arithmetically,
   exactly like text.js.
4. **ISO timestamps without a calendar.** Same Hinnant
   `civil_from_days` arithmetic as the Swift port, `long`
   throughout, explicit `FloorDiv` where JS floors (tz byte,
   PVD hundredths). C#'s `%` is a truncating remainder like
   Swift's and JS's, so only the divisions need flooring.
   Digit strings are formatted with the invariant culture so a
   host locale with non-ASCII digits can never shift bytes.
   The no-timestamp fallback uses
   `DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()` and
   `TimeZoneInfo.Local` UTC offset (the analogue of the Swift
   port's `TimeZone.current` approximation; the pipeline and
   the self-test always pass an explicit timestamp).
5. **Byte truncation.** Wherever JS/Swift rely on Uint8Array
   assignment truncating, C# uses `(byte)` casts on the masked
   or unmasked value to reproduce `UInt8(truncatingIfNeeded:)`;
   where the JS masks with `& 0xff` first, the mask is kept.
6. **Sort orders.** `[...sizes.keys()].sort()` (JS default =
   UTF-16 code-unit order) is `StringComparer.Ordinal` in C# —
   ordinal compares UTF-16 code units, the same order.
   Byte-order sorts (directory records, path table) use the
   ported `CmpBytes`, never string comparison.
7. **ISO walk name handling.** JS builds names with
   `String.fromCharCode(byte)` (one Latin-1 unit per byte);
   C# decodes the name bytes with `Encoding.Latin1`, which is
   exactly that mapping. Keys are uppercased with
   `ToUpperInvariant()` (JS `toUpperCase()` / Swift
   `uppercased()` are full Unicode mappings; the invariant
   mapping differs only for non-ASCII names, which ISO 9660
   paths here never carry).
8. **NDB reading re-forms surrogate pairs.** The stored UTF-16
   units are collected as `char[]` — a C# char IS a UTF-16 code
   unit, so a stored astral pair simply *is* the two chars of
   the astral character in the resulting string, exactly the
   JS `String.fromCharCode` result. A lone surrogate stays a
   lone surrogate in the C# string (as in JS; the Swift port
   decoded it to U+FFFD — unobservable unless a disc carries a
   corrupt name table).
9. **`FramesToSeconds`.** `(int)((frames * 2048L) / 44100)` —
   64-bit product, truncating division of a non-negative value;
   identical to the JS double computation for every frame count
   a disc can hold.
10. **writeToc group coverage, PLLIST, hex constants** — as in
    the Swift port, unchanged: the coverage throw is
    reproduced, PLLIST.NDB is `WriteNdb` over zero strings
    (never `WritePlf`), and all held constants are parsed from
    the same hex strings as the JS/Swift (`Text.BytesFromHex`),
    never hand-transcribed byte arrays.

## Where C# could silently diverge (watch list)

- `int` is 32-bit in C# where Swift's `Int` is 64-bit. Every
  quantity in the core is bounded by disc geometry (largest:
  total sectors × 2048 ≈ 9.2×10^8 for a 99-min blank — inside
  int32, with headroom). The two places a product could grow —
  `FramesToSeconds` and the timestamp math — use `long`
  explicitly, as noted above.
- `Dictionary` iteration order is never relied on: the ISO
  planner sorts path keys itself, exactly as in JS/Swift.
- `DES.Create()` in .NET 8 is provided by the OS crypto stack
  (CNG on Windows, OpenSSL on Linux); single DES with
  PaddingMode.None is supported on both. Verified locally on
  Linux (see below); the Windows run is the user's build.

## Verification (2026-11-06, porting VM — .NET SDK 8.0.427, Linux)

The SDK was installed into the VM specifically so this port
would not ship blind. First build: **0 warnings, 0 errors.**
First self-test run against `~/workspace/atrac-web-app/reference`:

```
C# ISO md5:   4528977b9bb7e8e1cf9a2e18dce41303
expected md5:    4528977b9bb7e8e1cf9a2e18dce41303
sectors: 131 expected: 131
bytes: 268288 expected: 268288
reader: 3 tracks, 2 groups, 23s total
BYTE-IDENTICAL ✓
exit 0
```

The gate PASSES: the C# core reproduces the fixture disc byte
for byte — MD5 `4528977b9bb7e8e1cf9a2e18dce41303`, 131 sectors,
268,288 bytes — and IsoRead smoke-parses it (3 tracks /
2 groups). This also proves .NET's DES (OpenSSL provider,
Linux) bit-matches CommonCrypto and the JS for every operation
the recipe uses, including the EDE composition and the CBC
payload chain. The remaining check is the same self-test on
Windows via build-selftest.cmd, which exercises the CNG DES
provider — expected to match, and it is the run that counts
for the user's machine.

## Step 2 — the WinUI 3 face (2026-11-06, written blind; the gaming PC is the compile check)

`app/` holds the whole window. It mirrors the Mac app file for
file: `App.xaml(.cs)` (theme dictionaries), `MainWindow.xaml(.cs)`
(layout + glue), `Store.cs` (the DiscStore view-model),
`Models.cs`, `TagReader.cs`, `DiscPainter.cs` (the Win2D disc),
`BurnService.cs` + `Imapi2Interop.cs` (IMAPI2), `Converters.cs`,
`DiscWright.csproj`, `app.manifest`. `build-app.cmd` at this
folder's root builds it.

### Decisions

- **Framework**: WinUI 3 / Windows App SDK 1.6 (floating
  `1.6.*`), `net8.0-windows10.0.19041.0`, min 17763.
  **Unpackaged + self-contained** (`WindowsPackageType None`,
  `WindowsAppSDKSelfContained true`, RID win-x64,
  `SelfContained true`): `build-app.cmd` copies the build
  output to `DiscWright\` next to it; double-click
  `DiscWright.exe`, no runtime installs — the user's rhythm.
- **MVVM**: classic `{Binding}` + code-behind, hand-rolled
  `INotifyPropertyChanged`. No toolkit dependency: the Mac's
  `@Observable` semantics are small (computed capacity
  properties re-raised from one `Refresh()`), and one less
  NuGet surface is one less blind-write risk. x:Bind was
  avoided for the same reason (its compile-time path checks
  are unforgiving across DataTemplate boundaries written
  blind).
- **The look, from line one** (Mac Step 2.5 lesson): every
  color is a named brush. Theme-varying brushes live in
  `App.xaml`'s Light/Dark `ThemeDictionaries` (the exact
  `Theme.swift` / Step-3 dark tables); shared gradients
  (client, header, mode pill, meter fill/over) live in the
  merged dictionary and are theme-invariant, as on the Mac.
  Nothing pins a theme — the app follows the system, and the
  dark palette is designed, not inverted. The backdrop
  ribbon bands are two rotated translucent borders over the
  client gradient (a quiet echo of the web wallpapers).
- **Disc stage**: Win2D `CanvasAnimatedControl` +
  `DiscPainter`, a number-for-number port of
  `DiscStageView.swift`'s Canvas painter (spin/squash/bob,
  both radial stop tables, laser with the same area law and
  flicker buckets, hub label + the v5 sub-line gap). ONE
  deviation, flagged: the sheen is painted as **72 rotated
  wedge slices** interpolating the web's 12 conic stops —
  the technique the approved Mac build itself ships —
  instead of `CanvasConicGradientBrush`, whose center/offset
  space could not be verified blind. `PaintSheen()` in
  `DiscPainter.cs` is the single swap point if the conic
  brush is wanted later. Brushes are created per draw (no
  cached device resources), removing the
  device-lost/recreate class of bugs at a trivial per-frame
  cost.
- **Burn (imports only)**: hand-rolled IMAPI2 interop,
  isolated in two files. Typed `[ComImport]` interfaces only
  where the vtable layout is certain (IDiscMaster2;
  IDiscRecorder2's head — Initialize + the two
  exclusive-access calls); **IDiscFormat2Data is driven
  through `dynamic` IDispatch**, because its vtable is long
  and property order is the classic blind-write trap —
  names resolve against the type library at runtime. The
  ISO is handed over as an `IStream` from
  `SHCreateStreamOnFileEx` (the standard IMAPI recipe).
  `ForceMediaToBeClosed = false` (leave the session open,
  SonicStage-style). The confirmation + result dialogs live
  in `BurnService` but take the `Window` (ContentDialog needs
  a XamlRoot); `DiscStore.ApplyBurnState` keeps the Mac's
  `idle → burning → idle` state machine so a failed burn
  can't strand the stage. Failures log the real HRESULT —
  nothing fakes success. **Burn for NEW discs stays disabled**
  with the honest launch log line, Mac Step 2 precedent:
  encoding is Step 3.
- **Tags**: `TagReader.cs` is a line-for-line port of the
  Swift reader (v2.3/v2.4 frames, all four text encodings,
  ID3v1, filename fallback). Duration comes from WinRT
  `MusicProperties` (samples = round(sec × 44100)), standing
  in for AVAsset until Step 3's ffmpeg decode replaces it.
- **Verified in this VM** (the Linux SDK cannot build
  Windows targets): `Models.cs` + `TagReader.cs` compiled as
  plain net8.0 — 0 warnings, 0 errors — and `TagReader` was
  functionally smoke-tested against synthetic ID3v2.4/2.3,
  ID3v1 and filename-fallback files. All XAML/manifest/csproj
  parse as XML; all C# files brace-balance.

### Blind-write risks to watch on the first build/run

1. **Grouped ListView header DataContext** — the header
   template binds the group's own `Name`/`Editable`/
   `CanRemove`, which requires WinUI to hand the template
   the group object itself (the standard pattern when the
   source items are the groups). If group strips render
   empty, this is the place to look.
2. **ListView drag-reorder** — `CanReorderItems` raises
   `ItemsVectorChanged` rather than moving items in an
   `ObservableCollection` source, and multi-list (grouped)
   reorder is the shakiest corner. `DiscStore.
   OnGroupsVectorChanged` reconciles the CSV order back
   into the groups and rejects cross-group drops by
   refreshing; if drops misbehave, this reconciliation is
   the suspect. The ↑/↓ buttons always work regardless.
3. **IMAPI2 interop** — first real burn is the test. Watch
   for: coclass activation (registry ProgIDs), the
   `dynamic` property names (`Recorder`, `ClientName`,
   `ForceMediaToBeClosed`), and media-support checks
   returning false on a drive IMAPI doesn't like.
4. **FolderPicker** requires a non-empty `FileTypeFilter`
   even though it picks folders; `"*"` is set.
5. **CanvasTextLayout natural size** — created with
   requested height 0 (natural); if the hub text measures
   0-height on some driver, pass the measured block height.
6. **NuGet/SDK versions** — floating `1.6.*` / Win2D
   `1.3.*`; if restore picks something unexpected, pin
   exact versions in `app/DiscWright.csproj`.

### Build & run (for Lola)

PowerShell:
```powershell
cd "<path to>\native-win"
.\build-app.cmd
.\DiscWright\DiscWright.exe
```
Or double-click `build-app.cmd`, then `DiscWright\
DiscWright.exe`. The first build downloads the Windows App
SDK + Win2D NuGet packages (network needed once). If `dotnet`
is missing the script prints the exact winget line and stops,
exactly like `build-selftest.cmd`.
