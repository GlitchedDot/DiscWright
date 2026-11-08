# DiscWright native-pure — Swift port of the JS authoring core

Step 1 of the fully-native Mac rebuild: the proven JS core
(`~/workspace/atrac-web-app/core/`) ported mechanically to Swift,
byte-exact, plus a command-line self-test that rebuilds the
reference fixture and compares it against `expected.iso`.

Build & check (Terminal, macOS):

```
cd native-pure
./build-selftest.sh        # needs swiftc; xcode-select --install if missing
./selftest ../reference    # expect: md5 4528977b9bb7e8e1cf9a2e18dce41303, BYTE-IDENTICAL, exit 0
```

Target: ISO md5 `4528977b9bb7e8e1cf9a2e18dce41303`, 131 sectors
(confirmed as the JS core's current output in the porting VM).

## JS → Swift API mapping

All byte strings are `[UInt8]` (JS `Uint8Array`); all file maps
are `[String: [UInt8]]` / `[String: Int]` (JS `Map` — iteration
order never matters downstream because the ISO planner sorts
path keys itself, exactly as in the JS). JS `throw` → Swift
`throws` with `DiscCoreError.message(...)` (defined in Des.swift);
capacity.js's `CapacityError` subclass → `CapacityError` class.

| JS (core/) | Swift (core/) |
|---|---|
| des.js `desEncryptBlock(key8, block8)` | Des.swift `desEncryptBlock(key8:block8:)` |
| des.js `desDecryptBlock` | Des.swift `desDecryptBlock(key8:block8:)` |
| des.js `edeEncryptBlock(key16, block8)` | Des.swift `edeEncryptBlock(key16:block8:)` — E_K1∘D_K2∘E_K1 composed from single-DES CCCrypt calls, same order as JS |
| des.js `edeDecryptBlock` | Des.swift `edeDecryptBlock(key16:block8:)` — D_K1∘E_K2∘D_K1 |
| des.js `desCbcEncrypt(key8, iv8, data)` | Des.swift `desCbcEncrypt(key8:iv8:data:)` — one CCCrypt CBC call, no padding |
| des.js `desCbcDecrypt` | Des.swift `desCbcDecrypt(key8:iv8:data:)` |
| text.js `clampString(s)` | Text.swift `clampString(_:) -> [UInt32]` (code points, see traps) |
| text.js `utf16be(s)` | Text.swift `utf16be(_ codePoints:)`; pipeline `utf16beClamped(_:)` = JS `utf16be(clampString(s))` |
| atrac.js `D2`, `V`, `CONNUM`, `TRACK_SLOT`, `MGD`, `FRAME_SIZE` | Atrac.swift same names, except `V` → `V_KEY` (see risks) |
| atrac.js `blockSeed(discId, i)` | Atrac.swift `blockSeed(discId:bindIndex:)` |
| atrac.js `icv(discId, sizes)` | Atrac.swift `icv(discId:sizes:)` |
| atrac.js `encryptPayload(frames, iv)` | Atrac.swift `encryptPayload(frames:iv:)` |
| ndb.js `writeNdb(strings)`, `NDB_HEADER_LEN`, `NDB_RECORD_LEN` | Ndb.swift same |
| header.js `headerToBytes(h)`, `HEADER_LEN` | Header.swift `headerToBytes(_ SecureHeaderFields)`, `HEADER_LEN` |
| sti.js `writeToc(spec)`, `writePlf()`, `framesToSeconds(f)` | Sti.swift `writeToc(frameCounts:groups:icv:discId:)`, `writePlf()`, `framesToSeconds(_:)` |
| stk.js `STK_BYTES`, `STK_FILENAME` | Stk.swift same |
| id3.js `writeTag(track, artist, album)`, `TAG_LEN` | Id3.swift `writeTag(title:artist:album:)`, `TAG_LEN` (JS's first param is named `track` but carries the title) |
| iso.js `writeIso(files, {volIdent, timestamp})` | Iso.swift `writeIso(files:volIdent:timestamp:)`; timestamp = `IsoTimestampInput{ms: Int64, tzOffsetMinutes: Int}` |
| iso.js `isoSectorCount(sizes)`, `SECTOR` | Iso.swift `isoSectorCount(_:)`, `ISO_SECTOR` |
| capacity.js `checkCapacity(map, sectors)`, `SESSION_OVERHEAD_SECTORS`, `BLANKS`, `SECTOR` | Capacity.swift same names (`SECTOR` = `ISO_SECTOR`) |
| author.js `buildDisc(opts)` → `{iso, files, stats}` | Author.swift `buildDisc(tracks:groups:discId:ivs:capacitySectors:timestamp:) -> BuildDiscResult{iso, files, stats: DiscStats}`; opts.tracks → `[DiscTrack{frames, title, artist, album, frameSize?}]`; opts.groups → `[DiscGroup{name, first, last}]?`; opts.timestamp → `DiscTimestamp{ms, tzOffsetMinutes}?` |
| author.js `trackFilename(n)`, `ATP_OVERHEAD` | Author.swift same |
| isoread.js `readIsoFiles(bytes)` | IsoRead.swift `readIsoFiles(_:) -> [String: IsoFileRec]` |
| isoread.js `parseAtracDisc(bytes)` | IsoRead.swift `parseAtracDisc(_:) -> ParsedDisc{trackCount, totalSeconds, groups: [ParsedGroup{name, tracks: [ParsedTrack{title, artist, album, seconds, size}]}]}` |

## Semantic traps found, and how each was handled

1. **DES via CommonCrypto.** CCCrypt defaults to CBC with
   PKCS#7 padding OFF only if you don't pass the flag — the JS
   never pads (payloads are multiples of 8). All calls pass
   options with *no* `kCCOptionPKCS7Padding`. Single-block ops
   pass `kCCOptionECBMode` explicitly so no IV semantics can leak
   in; the CBC functions pass the IV and no ECB flag (CBC is
   CCCrypt's default mode). The EDE composition is three separate
   single-DES CCCrypt calls in exactly des.js's order — not the
   `kCCAlgorithm3DES` algorithm, whose keying/parity behaviour is
   not the JS's.

2. **ICV BigInt fold.** atrac.js uses BigInt with an explicit
   `(1n << 64n) - 1n` mask after every multiply-add. Swift:
   `x = x &* UInt64(s) &+ b` — wrapping multiply then wrapping
   add is the same value mod 2^64, and `be64`/BE-decode are
   written out byte by byte like the JS.

3. **String clamping is by UTF-16 code unit, over code points.**
   text.js iterates code points; an astral character costs 2
   units and is kept whole or dropped whole (it can straddle the
   30-unit cap only by being dropped); a lone surrogate becomes
   U+FFFD and costs 1. Swift: iterate `unicodeScalars`, apply the
   same replacement and accounting, and carry the clamped result
   as `[UInt32]` code points so no re-encoding can differ.
   Divergence that cannot occur in practice: a Swift `String`
   can never *contain* an unpaired surrogate (it is repaired to
   U+FFFD when the string is built, e.g. by JSONSerialization),
   so that JS branch is dead on any real input — including the
   fixture, whose long title with 😀 exercises the astral path
   (😀 = 2 units; the title clamps mid-string at 30 units).

4. **ISO timestamps without a calendar.** The JS uses `Date` UTC
   getters of `ms` and of `ms + tzOffsetMinutes*60000`, and
   `Math.floor`. JavaScript `Date` is a pure proleptic-Gregorian
   UTC calendar, so Iso.swift computes civil fields
   arithmetically (Howard Hinnant's `civil_from_days`) instead of
   using Foundation's Calendar/DateFormatter, which follow the
   host's calendar/locale and could shift bytes. Floor division
   is implemented explicitly (`floorDiv`) where JS floors:
   the tz byte (`Math.floor(tzMin/15)` — differs from Swift's
   truncating `/` for negative non-multiples of 15) and the PVD
   hundredths (`Math.floor((ms % 1000)/10)`; JS `%` is a
   truncating remainder like Swift's, so only the division
   needed flooring). The date7 year byte is `year - 1900`
   truncated to a byte, as the JS's Uint8Array assignment does.

5. **Uint8Array assignment truncates; Swift `UInt8(int)` traps.**
   Wherever the JS stores a possibly-out-of-range number into a
   byte (TOC group count, group index, record lengths, year),
   the port uses `UInt8(truncatingIfNeeded:)`; wherever the JS
   masks with `& 0xff` first, the port keeps the same mask.

6. **JS sort order.** `[...sizes.keys()].sort()` is JS's default
   string sort (by UTF-16 code unit); Swift's `String.sorted()`
   sorts by Unicode scalar via `Character` comparison — identical
   for the ASCII paths this app produces. Directory-record and
   path-table ordering is by *bytes* in the JS (`cmpBytes`) and
   is ported as bytes, not strings.

7. **The ISO walk (`readIsoFiles`) name handling.** JS builds
   names with `String.fromCharCode(byte)` (one Latin-1 unit per
   byte); the port appends `Character(UnicodeScalar(byte))`,
   which is the same for byte values. `";1"` stripping is a
   name-suffix operation in the JS; the port strips the suffix
   from the just-appended name component (same end of string).
   Keys are uppercased in both.

8. **NDB reading re-forms surrogate pairs.** isoread.js collects
   UTF-16 units with `String.fromCharCode`, so a stored astral
   character re-forms in the JS string. The port collects the
   units and `String(decoding:as: UTF16.self)` — same result for
   valid pairs; a lone surrogate decodes to U+FFFD where the JS
   would keep the lone unit in its string (unobservable unless a
   disc carries a corrupt name table).

9. **`framesToSeconds` in floating point.** JS:
   `Math.trunc(frames * 2048 / 44100)` in double. The port uses
   integer division. For any frame count a real disc can hold,
   `frames * 2048` is far below 2^53 and the double quotient's
   truncation equals the integer quotient.

10. **`writeToc` group coverage check.** The JS throws when a
    track falls outside every group (`findIndex` → -1 → group 0);
    the port reproduces that, including for the fixture's groups.

11. **PLLIST.NDB is `writeNdb([])`.** author.js writes the PLLIST
    with the generic NDB writer over zero strings (256-byte
    header, count 0) — *not* sti.js's `writePlf`, which is only
    used for TOC00001.STI. The port keeps them separate exactly
    as the JS does.

12. **Hex constants.** D2/V/MGD/STK bytes are parsed from the
    same hex strings as the JS (no hand-transcribed byte arrays),
    so a transcription slip in the port cannot hide.

## Compile risks (no Swift compiler in the porting VM)

The port was written blind; the compile on the user's Mac is the
first real check. Conservative style throughout (plain structs,
free functions, `[UInt8]` everywhere), but flagging honestly:

- **CCCrypt bridging (Des.swift)** is the most intricate part:
  nested `withUnsafeBytes` closures feeding `CCCrypt`. The
  signature used is the standard one for the macOS SDK
  (`CCCryptorStatus` return, `&outMoved` as
  `UnsafeMutablePointer<Int>`). If the compiler quibbles, it will
  be here — types around `kCCSuccess` / `CCOperation(kCCEncrypt)`
  casts are belt-and-braces and can be dropped if they error.
- **`import CommonCrypto`** works with plain `swiftc` on macOS
  (CommonCrypto ships a Swift module map with the SDK) — no
  `-framework` flag needed; same for CryptoKit in selftest.swift.
  If an older toolchain disagrees, that's the first fix to try.
- **`V` was renamed `V_KEY`**: a one-letter global could collide
  with generic parameter names in future files; behaviour is
  unchanged (same bytes, parsed from the same hex).
- **selftest.swift staging**: swiftc permits top-level code only
  in `main.swift`, so `build-selftest.sh` copies `selftest.swift`
  to `.selftest-build/main.swift` for the compile and cleans up.
  The deliverable stays named `selftest.swift`.
- **JSONSerialization numbers** in the self-test: `timestampMs`
  (1793733350170) arrives as an `NSNumber`; `int64Value` is exact
  (well under 2^53). Emoji strings in fixture.json decode through
  JSONSerialization's surrogate handling into proper Swift
  strings, which is what trap 3 relies on.
- `String(num, radix: 16, uppercase: true)` is used for the
  TRK filename hex (JS: `toString(16).toUpperCase().padStart(5)`);
  output is plain ASCII hex, matching for all track numbers in
  range (the writer also enforces the JS's 1...0xFFFFF check).
- One deliberate non-port: the JS ISO writer's no-timestamp
  fallback uses the *machine-local* offset via
  `-getTimezoneOffset()`; the port approximates it with
  `TimeZone.current.secondsFromGMT / 60`. The build pipeline and
  the self-test always pass an explicit timestamp, so this path
  affects nothing byte-verified.
