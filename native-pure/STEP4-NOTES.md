# Step 4 — packaging: self-contained + Universal

Written 2026-11-07 (porting VM; the Mac build remains the
compile check, as with every step). Step 4 changes ONLY
`build-app.sh`, plus two new folders (`tools/`, `licenses/`)
and this note. No Swift source, no vendored atracdenc source,
no Info.plist, no icon wiring was touched.

## The problem Step 4 solves

Through Step 3, the bundled `atracdenc` dynamically linked
the build machine's Homebrew libsndfile by absolute path
(e.g. `/usr/local/lib/libsndfile.1.dylib` on Intel). Two
consequences:

1. On any Mac without that exact Homebrew install, the
   encoder would not even launch — the app was portable in
   name only.
2. Both binaries were host-architecture only (the Step 3
   build pinned `CMAKE_OSX_ARCHITECTURES` to `uname -m` for
   the encoder, and plain `swiftc` produces a host-arch app).

Step 4's output: a `DiscWright.app` whose two binaries are
both Universal (x86_64 + arm64), with libsndfile compiled
INTO the encoder, linking nothing outside the macOS system
libraries — plus the license texts riding inside the bundle.

## Design

### Why a vendored, static libsndfile

`build-app.sh` now builds libsndfile itself, from a pinned
source tarball, as a static archive, and atracdenc links
that archive. Options considered and rejected:

- **Bundle Homebrew's dylib + `install_name_tool` rewiring.**
  The classic approach, and the fiddliest: dylib install
  names, `@rpath` plumbing inside a *subprocess* binary that
  lives in Resources, per-arch Homebrew installs for the
  arm64 slice (an Intel Mac's Homebrew is x86_64-only), and
  the transitive question of what Homebrew's libsndfile was
  itself built against (FLAC / Ogg / Vorbis / Opus…). Every
  one of those is a way for the bundle to be subtly wrong.
- **Static vendored build (chosen).** One archive, both
  architectures, linked into the encoder at build time.
  There is no dylib left to rewire, no runtime search path
  to get wrong, and nothing to look for on the user's disk.
  The app either contains its encoder whole or the build
  failed loudly.

**The WAV-only switch-off does double duty.** The build sets
`ENABLE_EXTERNAL_LIBS=OFF` and `ENABLE_MPEG=OFF`, so the
static libsndfile contains only libsndfile's own code — no
FLAC, Ogg, Vorbis, Opus or MPEG code at all. atracdenc only
ever hands it WAV files (the app decodes everything to a
canonical WAV via AVFoundation first), so no capability is
lost — and the license-notice question the pre-publish
research had left open ("does the shipped libsndfile
internally bundle Xiph codec code? — UNVERIFIED") simply
ceases to exist for the Mac form: there is no codec code in
the binary to carry extra notices for.

### Why dual-arch compiles rather than one "fat" invocation

- *App:* `swiftc` compiles per target. The script compiles
  the unchanged source list twice — `-target
  x86_64-apple-macos13.0` and `-target
  arm64-apple-macos13.0` (both matching the bundle's
  LSMinimumSystemVersion 13.0) — and `lipo -create` joins
  the two into `Contents/MacOS/DiscWright`. One command
  shape, looped over the arch list.
- *Encoder + libsndfile:* CMake's
  `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` is the
  established mechanism and produces fat objects natively;
  the vendored atracdenc CMakeLists patch from Step 3
  already permits the override (upstream's own default was
  universal all along — Step 3 pinned host-arch only because
  of the single-arch Homebrew libsndfile, a constraint that
  no longer exists).

## The libsndfile pin

- **What:** `tools/libsndfile-1.2.2.tar.xz` (730,760 bytes),
  the official source tarball from
  https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz
- **Pinned SHA-256:**
  `3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e`
- **How the hash was obtained (honestly):** the tarball was
  downloaded from the official release URL during the Step 4
  session in the porting VM and hashed locally with
  `sha256sum`. It was then cross-checked against an
  independent third party that pins the same artifact:
  OpenEmbedded's recipe `meta/recipes-multimedia/libsndfile/libsndfile1_1.2.2.bb`
  records `SRC_URI[sha256sum] = "3799ca99…db80e"` — an exact
  match (openSUSE's package pages also list the same file at
  the same 730,760 bytes). The GitHub release page itself
  publishes no checksum file, so the cross-check rests on
  the distro pins, not on GitHub. The MD5 of the download,
  for the record: `04e2e6f726da7c5dc87f8cf72f250d04`.
- **Enforced at build time:** the script verifies the
  tarball's hash on every fresh libsndfile build and STOPS
  with both hashes printed if it mismatches.
- **Kept or not:** the tarball is KEPT in `tools/` (~714 KB)
  so rebuilds work offline and the exact bytes that were
  hashed are the bytes that get built. It is a source
  tarball, not a binary build product; if the tree is ever
  mirrored to a repo that prefers not to carry it, excluding
  `tools/*.tar.xz` is safe — the script re-downloads and
  re-verifies it against the same pin.

## What changed in build-app.sh, section by section

1. **Header** — now describes the Step 4 shape (universal,
   vendored static libsndfile).
2. **Prerequisites** — was "cmake + Homebrew libsndfile,
   stop with `brew install cmake libsndfile`". Now: **cmake**
   only (plus `curl`, which ships with macOS, checked so its
   absence is named). All Homebrew-libsndfile detection
   (`brew --prefix libsndfile`, `/opt/homebrew` /
   `/usr/local` probing, pkg-config) is GONE; the encoder
   path has no Homebrew dependence left. The friendly
   stop-early-with-the-fix shape is unchanged.
3. **NEW: libsndfile section** — download (if the tarball is
   absent) → checksum verify → extract into `tools/` →
   CMake configure as a static, position-independent,
   universal library with programs/examples/tests off and
   external codecs + MPEG off → build → install into
   `tools/libsndfile-prefix`. Stamp-cached like the encoder:
   the stamp input folds the version, the pinned hash, the
   arch list and the feature switches (`SND_CONFIG_ID`), so
   changing any of them forces a rebuild. After install it
   asserts `lib/libsndfile.a` exists before anything relies
   on it.
4. **atracdenc section** — architecture flips from
   `$(uname -m)` to `"arm64;x86_64"`. The vendored static
   libsndfile is handed to atracdenc's
   `FindLibSndFile.cmake` three ways at once:
   `-DCMAKE_PREFIX_PATH=<abs prefix>`,
   `-DLIBSNDFILE_INCLUDE_DIR=<abs prefix>/include`,
   `-DSNDFILE_LIBRARY=<abs prefix>/lib/libsndfile.a`
   (the module's own two cache variables, pointed straight
   at the archive — its find logic cannot wander to a system
   or Homebrew copy). The old brew-prefix
   `CMAKE_PREFIX_ARGS` block is deleted. The build still
   compiles ONLY the `atracdenc` target (the unquoted-path
   man-page target stays avoided) and still disables the
   GTest find. The encoder stamp now also covers
   `SND_CONFIG_ID` and the arch list, so a libsndfile or
   arch change rebuilds the encoder too.
5. **Bundle assembly** — unchanged copies (Info.plist,
   encoder, icon), plus NEW: `licenses/GPL-3.0.txt`,
   `licenses/LGPL-2.1.txt` and
   `licenses/THIRD-PARTY-NOTICES.txt` copied into
   `Contents/Resources/Licenses/`.
6. **App compile** — the single host-arch `swiftc` call
   becomes a loop over `x86_64 arm64`, one `-target
   <arch>-apple-macos13.0` compile each into a temp dir,
   then `lipo -create` → `Contents/MacOS/DiscWright`. Flags
   otherwise identical (`-O -parse-as-library`, same four
   frameworks, same source globs).
7. **Codesign** — unchanged (`--force --deep -s -`), still
   after every copy, last mutation of the bundle.
8. **NEW: verification gates** — after signing, before the
   success message:
   - `lipo -info` on BOTH binaries must list `x86_64` and
     `arm64`.
   - `otool -L` on BOTH binaries must contain no
     `/opt/homebrew`, no `/usr/local`, and no `libsndfile`
     reference at all.
   Any failure prints what was found and exits non-zero —
   the build does not call itself done.
9. **Summary block** — prints bundle size, encoder size and
   the architecture list before the usual launch lines.

## Licenses in the bundle

`licenses/` in the tree (builds copy from here; nothing is
downloaded at build time):

- `GPL-3.0.txt` — DiscWright's own license; canonical text
  fetched from https://www.gnu.org/licenses/gpl-3.0.txt
  (35,149 bytes, verified "Version 3, 29 June 2007").
- `LGPL-2.1.txt` — covers BOTH atracdenc and libsndfile with
  this one copy; canonical text from
  https://www.gnu.org/licenses/lgpl-2.1.txt (26,419 bytes).
- `THIRD-PARTY-NOTICES.txt` — written from the Mac column of
  `~/workspace/discwright-public-prep/LICENSE-NOTICES.md`:
  - atracdenc — LGPL-2.1-or-later; source:
    github.com/dcherednik/atracdenc at commit
    cb170709f836cb43dc0312455188c791159d81dc.
  - libsndfile 1.2.2 — LGPL-2.1-or-later, © Erik de Castro
    Lopo; source: the official release tarball URL, with
    its pinned SHA-256 printed in the notice.
  - KissFFT — BSD 3-Clause, © Mark Borgerding, with the
    full text taken VERBATIM from the vendored copy inside
    atracdenc (`src/lib/fft/kissfft_impl/kiss_fft.c` header
    — note the vendored wording: "Neither the author nor
    the names of any contributors…"; the generic template's
    "Neither the name of the copyright holder…" differs, and
    the vendored text is what governs).
  - **libgha — resolved while writing this.** The research
    file listed libgha's license as not separately checked;
    the vendored copy carries its own LICENSE: BSD 2-Clause,
    © 2018 Daniil Cherednik. Its full text is included in
    the notices. (libgha's CMake falls back to its own
    bundled KissFFT copy only when no FFT library is handed
    to it; atracdenc hands it `fft_impl`, so that copy is
    not compiled — either way the same author's BSD terms
    are already in the notices via the KissFFT entry.)

## Known-UNVERIFIED (mine to flag, Lola's to confirm)

1. **Intel swiftc cross-compiling the arm64 slice.**
   `-target arm64-apple-macos13.0` on an Intel Mac with the
   Command Line Tools should work (the CLT install the SDK
   for both archs), but no Intel Mac in the porting VM
   exists — her build log is the proof. If the arm64 compile
   is what fails, this is the item.
2. **The arm64 slices cannot be executed on any machine she
   owns** (all her Macs are Intel; the Neo is future). They
   are verified structurally only — `lipo -info` in the
   gates. First true run of an arm64 slice happens on Apple
   Silicon.
3. **atracdenc's FindLibSndFile accepting the vendored
   static archive without a fight.** By the module's own
   text it should: the two cache variables are its inputs,
   and CMake's prefix search is its fallback. But CMake
   find-module behavior across versions is exactly the kind
   of thing that surprises. If her build fails at the
   encoder configure with "libsndfile PCM I/O backend
   requires libsndfile", THIS is the first suspect — and
   the fix would be in how the script passes the paths, not
   in the app.
4. **libsndfile 1.2.2's CMake on her macOS/CMake combo**
   (deployment-target and universal-archive details) is
   likewise first-run territory: established options, but
   her log is the first real execution of this exact build.
5. Version number in Info.plist intentionally left at 0.3 —
   a "1.0" bump is a release decision, not a packaging one.

## Lola's test checklist

Terminal (macOS), in the folder with build-app.sh — remember
folders with spaces are fine, the script quotes everything:

1. `cd ` + drag the folder in + Enter, then `./build-app.sh`
2. First run takes longer: it verifies + builds libsndfile,
   rebuilds the encoder (stamp changed), and compiles the
   app twice. Later runs skip straight through the caches.
3. Watch for the new end-of-build lines:
   - "Checking the finished bundle..."
   - "OK: both binaries are universal (x86_64 + arm64)."
   - "OK: no Homebrew, /usr/local, or external libsndfile
     references."
   - "Done: DiscWright.app (… total; encoder …;
     architectures: x86_64 + arm64)"
   If a check FAILs, the script stops and names the binary
   and the offending library line — send me that output.
4. `open DiscWright.app` and do the proven Step 3 pass:
   add tracks, encode, author, burn offer — a disc the
   D-NE1 plays is the verdict, same as always.
5. Peek inside: right-click DiscWright.app → Show Package
   Contents → Contents/Resources — `atracdenc`, `AppIcon.icns`
   and a `Licenses` folder holding GPL-3.0.txt, LGPL-2.1.txt
   and THIRD-PARTY-NOTICES.txt.
6. The real portability test, whenever it's handy: copy the
   built app to the OTHER Intel Mac (the one that did NOT
   build it) and encode something there. That machine is
   the stand-in for "a Mac that never built DiscWright" —
   if the encoder runs there, Step 4 did its job.

## First-run fix (2026-11-07, GlitchedDot's build)

Her first Step 4 build stopped at the libsndfile configure with
CMake's "Compatibility with CMake < 3.5 has been removed" error:
her CMake is 4.x, and libsndfile 1.2.2's project files declare an
older cmake_minimum_required. Fix: the libsndfile configure in
build-app.sh now passes -DCMAKE_POLICY_VERSION_MINIMUM=3.5 —
CMake's own documented bridge for this case; it changes no build
output. Note the script already wiped the libsndfile build dir on
every rebuild, so the failed configure left no stale cache to
poison the retry. If atracdenc ever hits the same wall on a future
CMake, the same flag is the first thing to try there too.
