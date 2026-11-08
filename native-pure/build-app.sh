#!/bin/bash
# Build the fully native DiscWright.app (Step 4: SwiftUI face +
# byte-proven Swift core + the vendored atracdenc encoder +
# vendored static libsndfile, everything Universal).
# Run in Terminal (macOS):
#     cd <this folder>
#     ./build-app.sh
#     open DiscWright.app
# The bundle lands next to this script. No Xcode project, no
# SwiftPM — plain swiftc, like build-selftest.sh.
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler was not found."
  echo "Install Apple's free Command Line Tools first, in Terminal:"
  echo "    xcode-select --install"
  echo "When that finishes, run ./build-app.sh again."
  exit 1
fi

# ---- Step 4 dependencies: cmake only ------------------------
# atracdenc (the vendored encoder) builds with CMake. Its sound
# library, libsndfile, is NO LONGER taken from Homebrew: it is
# built from a pinned, checksum-verified source tarball kept in
# tools/ and statically linked into the encoder (see the
# libsndfile section below), so the finished app runs on a Mac
# that has never seen Homebrew. cmake is the only build tool
# left that must already be installed.
if ! command -v cmake >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "DiscWright needs two free build tools:"
  command -v cmake >/dev/null 2>&1 || echo "  - cmake: MISSING (used to build the encoder)"
  command -v curl >/dev/null 2>&1 || echo "  - curl: MISSING (used once to fetch the libsndfile source)"
  echo ""
  echo "cmake with Homebrew, in Terminal:"
  echo "    brew install cmake"
  echo "(curl ships with macOS; if it is somehow missing, any"
  echo "standard macOS install will have it.)"
  echo "Then run ./build-app.sh again. (Nothing else to do — the"
  echo "encoder and its sound library build once and are reused"
  echo "until their sources change.)"
  exit 1
fi

# ---- libsndfile: pinned vendored source -> static, universal -
# libsndfile 1.2.2, built from the official source tarball as a
# STATIC library for both Mac architectures, with every optional
# external codec library disabled (FLAC / Ogg / Vorbis / Opus /
# MPEG all OFF). atracdenc only ever hands it WAV files, so the
# WAV-only build loses nothing — and because the library is
# compiled INTO the encoder, no libsndfile.dylib needs to exist
# on the machine that runs the app. That is the whole point of
# Step 4: the old build linked Homebrew's libsndfile.dylib by
# absolute path and would not even launch anywhere else.
SND_VERSION="1.2.2"
SND_TARBALL="libsndfile-${SND_VERSION}.tar.xz"
SND_URL="https://github.com/libsndfile/libsndfile/releases/download/${SND_VERSION}/${SND_TARBALL}"
SND_SHA256="3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e"
SND_DIR="tools"
SND_SRC="$SND_DIR/libsndfile-$SND_VERSION"
SND_BUILD="$SND_DIR/libsndfile-build"
SND_PREFIX="$SND_DIR/libsndfile-prefix"
SND_LIB="$SND_PREFIX/lib/libsndfile.a"
SND_STAMP="$SND_BUILD/.source-stamp"
# The stamp folds in everything that should force a rebuild:
# the pinned version, the tarball hash, the architecture list
# and the feature switches (kept in one string so editing any
# of them above also invalidates the cache).
SND_CONFIG_ID="libsndfile-$SND_VERSION sha256=$SND_SHA256 archs=arm64;x86_64 shared=OFF external=OFF mpeg=OFF pic=ON"
SND_NEW_STAMP="$(printf '%s|%s' "$SND_CONFIG_ID" "$SND_SHA256" | shasum -a 256 | cut -d' ' -f1)"
SND_OLD_STAMP=""
[ -f "$SND_STAMP" ] && SND_OLD_STAMP="$(cat "$SND_STAMP")"
if [ -f "$SND_LIB" ] && [ "$SND_NEW_STAMP" = "$SND_OLD_STAMP" ]; then
  echo "libsndfile: up to date (skipping rebuild)."
else
  mkdir -p "$SND_DIR"
  if [ ! -f "$SND_DIR/$SND_TARBALL" ]; then
    echo "Downloading libsndfile $SND_VERSION source (one-time)..."
    curl -fL -o "$SND_DIR/$SND_TARBALL.tmp" "$SND_URL"
    mv "$SND_DIR/$SND_TARBALL.tmp" "$SND_DIR/$SND_TARBALL"
  fi
  SND_ACTUAL_SHA="$(shasum -a 256 "$SND_DIR/$SND_TARBALL" | cut -d' ' -f1)"
  if [ "$SND_ACTUAL_SHA" != "$SND_SHA256" ]; then
    echo "STOP: the libsndfile tarball in tools/ does not match"
    echo "the pinned checksum."
    echo "  expected: $SND_SHA256"
    echo "  actual:   $SND_ACTUAL_SHA"
    echo "Delete tools/$SND_TARBALL and run ./build-app.sh again"
    echo "so a fresh copy is downloaded. If a fresh download also"
    echo "mismatches, do not proceed — the download is not the"
    echo "official 1.2.2 source."
    exit 1
  fi
  echo "Extracting libsndfile $SND_VERSION..."
  rm -rf "$SND_SRC" "$SND_BUILD" "$SND_PREFIX"
  mkdir -p "$SND_SRC" "$SND_BUILD"
  tar -xJf "$SND_DIR/$SND_TARBALL" -C "$SND_SRC" --strip-components 1
  echo "Building libsndfile $SND_VERSION (static, universal, WAV-only; one-time)..."
  # BUILD_SHARED_LIBS stays OFF (upstream's own cmake default):
  # only libsndfile.a is produced and installed. Programs,
  # examples and tests are off — nothing but the library.
  # CMAKE_POLICY_VERSION_MINIMUM=3.5: libsndfile 1.2.2 declares
  # an old cmake_minimum_required, and CMake 4.x removed
  # compatibility with minimums below 3.5 outright ("Compatibility
  # with CMake < 3.5 has been removed"). This flag is CMake's own
  # documented bridge for exactly that case; it changes no build
  # output, only which policies the old project files may use.
  # (First hit on GlitchedDot's CMake 4.x, 2026-11-07.)
  cmake -S "$SND_SRC" -B "$SND_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_INSTALL_PREFIX="$PWD/$SND_PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_PROGRAMS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_EXTERNAL_LIBS=OFF \
    -DENABLE_MPEG=OFF
  cmake --build "$SND_BUILD" -j
  cmake --install "$SND_BUILD"
  if [ ! -f "$SND_LIB" ]; then
    echo "STOP: libsndfile built but $SND_LIB is missing."
    echo "The vendored build did not install where the encoder"
    echo "expects it — see STEP4-NOTES.md."
    exit 1
  fi
  echo "$SND_NEW_STAMP" > "$SND_STAMP"
fi

# ---- atracdenc: build once, reuse until sources change ------
ENC_SRC="encoder/atracdenc-src"
ENC_BUILD="encoder/build"
ENC_BIN="$ENC_BUILD/src/atracdenc"
ENC_STAMP="$ENC_BUILD/.source-stamp"
# The encoder's stamp covers its own sources AND the inputs
# that decide how it links: the libsndfile build identity and
# the architecture list. Change any of those and the encoder
# rebuilds too.
ENC_NEW_STAMP="$( { find "$ENC_SRC" -type f -print0 | sort -z | xargs -0 shasum -a 256; printf '%s' "$SND_CONFIG_ID"; printf '%s' "archs=arm64;x86_64"; } | shasum -a 256 | cut -d' ' -f1)"
OLD_STAMP=""
[ -f "$ENC_STAMP" ] && OLD_STAMP="$(cat "$ENC_STAMP")"
if [ -x "$ENC_BIN" ] && [ "$ENC_NEW_STAMP" = "$OLD_STAMP" ]; then
  echo "atracdenc: up to date (skipping rebuild)."
else
  echo "Building atracdenc (one-time; universal arm64 + x86_64)..."
  # Architecture: UNIVERSAL (arm64;x86_64) — the vendored
  # CMakeLists patch respects this override (it is also
  # upstream's own default). Step 3 built host-arch only
  # because the encoder linked the machine's single-arch
  # Homebrew libsndfile; now that libsndfile is a vendored,
  # universal, STATIC library, both slices link.
  # libsndfile itself is handed to atracdenc's
  # FindLibSndFile.cmake three ways at once (prefix path plus
  # the module's two cache variables, pointed straight at the
  # static archive), so the find cannot wander off to a system
  # or Homebrew copy. GTest is disabled explicitly: the
  # upstream test/ tree is not vendored, and the top-level
  # CMake only adds it when GTest is found.
  SND_ABS="$PWD/$SND_PREFIX"
  cmake -S "$ENC_SRC" -B "$ENC_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE \
    -DCMAKE_PREFIX_PATH="$SND_ABS" \
    -DLIBSNDFILE_INCLUDE_DIR="$SND_ABS/include" \
    -DSNDFILE_LIBRARY="$SND_ABS/lib/libsndfile.a"
  # Build ONLY the atracdenc target, never "all": upstream's
  # man-atracdenc custom target (part of ALL) runs a hand-written
  # shell line with an UNQUOTED output path — it dies with
  # "No such file or directory" whenever the build folder's path
  # contains a space (GlitchedDot's first Step 3 build,
  # 2026-11-05: "DiscWrightPure 6" on /Volumes/NAS). We never
  # install, so the man page is dead weight anyway.
  cmake --build "$ENC_BUILD" --target atracdenc -j
  echo "$ENC_NEW_STAMP" > "$ENC_STAMP"
fi

APP="DiscWright.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
cp "$ENC_BIN" "$APP/Contents/Resources/atracdenc"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/atracdenc"

# Licenses ride inside the bundle (Step 4): DiscWright's own
# GPL-3.0, the LGPL-2.1 that covers both atracdenc and
# libsndfile, and the notices file naming every third-party
# piece (incl. the BSD-licensed KissFFT and libgha compiled
# into the encoder). The texts live in licenses/ in this tree
# so builds never re-download them.
mkdir -p "$APP/Contents/Resources/Licenses"
cp licenses/GPL-3.0.txt licenses/LGPL-2.1.txt licenses/THIRD-PARTY-NOTICES.txt \
  "$APP/Contents/Resources/Licenses/"

echo "Compiling DiscWright (native core + SwiftUI face; universal)..."
# One compile per architecture, then lipo joins them into the
# single Contents/MacOS/DiscWright. Targets match the bundle's
# LSMinimumSystemVersion (13.0). -parse-as-library: the entry
# point is the @main attribute in app/DiscWrightApp.swift, not
# top-level code.
APP_BUILD_TMP=".app-build"
rm -rf "$APP_BUILD_TMP"
mkdir -p "$APP_BUILD_TMP"
APP_ARCH_BINS=()
for DW_ARCH in x86_64 arm64; do
  echo "  - $DW_ARCH slice..."
  swiftc -O -parse-as-library \
    -target "$DW_ARCH-apple-macos13.0" \
    -framework SwiftUI -framework AppKit -framework AVFoundation \
    -framework UniformTypeIdentifiers \
    -o "$APP_BUILD_TMP/DiscWright-$DW_ARCH" \
    core/*.swift app/*.swift
  APP_ARCH_BINS+=("$APP_BUILD_TMP/DiscWright-$DW_ARCH")
done
lipo -create "${APP_ARCH_BINS[@]}" -output "$APP/Contents/MacOS/DiscWright"
rm -rf "$APP_BUILD_TMP"

# Ad-hoc signature so the bundle is well-formed for local use.
# Signing stays LAST: everything copied or rewired above must
# already be in its final place, or the seal breaks.
codesign --force --deep -s - "$APP" 2>/dev/null || true

# ---- Step 4 verification gates ------------------------------
# The finished bundle must PROVE it is self-contained and
# universal before we call the build done. Any failure stops
# the script with what is wrong; nothing here is advisory.
echo ""
echo "Checking the finished bundle..."
GATE_FAIL=0
for GATE_BIN in "$APP/Contents/MacOS/DiscWright" "$APP/Contents/Resources/atracdenc"; do
  GATE_ARCHS="$(lipo -info "$GATE_BIN" 2>/dev/null || true)"
  case "$GATE_ARCHS" in
    *x86_64*arm64*|*arm64*x86_64*) : ;;
    *)
      echo "  FAIL: $GATE_BIN is not universal (lipo: ${GATE_ARCHS:-unreadable})"
      GATE_FAIL=1
      ;;
  esac
  GATE_LIBS="$(otool -L "$GATE_BIN" 2>/dev/null || true)"
  if printf '%s' "$GATE_LIBS" | grep -E "/opt/homebrew|/usr/local|libsndfile" >/dev/null; then
    echo "  FAIL: $GATE_BIN still references an outside library:"
    printf '%s\n' "$GATE_LIBS" | grep -E "/opt/homebrew|/usr/local|libsndfile" | sed 's/^/        /'
    GATE_FAIL=1
  fi
done
if [ "$GATE_FAIL" -ne 0 ]; then
  echo ""
  echo "STOP: the bundle above failed a Step 4 check. It would"
  echo "not run on a Mac without this machine's Homebrew. See"
  echo "STEP4-NOTES.md for what each check means."
  exit 1
fi
echo "  OK: both binaries are universal (x86_64 + arm64)."
echo "  OK: no Homebrew, /usr/local, or external libsndfile references."

APP_SIZE="$(du -sh "$APP" | cut -f1)"
ENC_SIZE="$(du -h "$APP/Contents/Resources/atracdenc" | cut -f1)"
echo ""
echo "Done: $APP  ($APP_SIZE total; encoder $ENC_SIZE; architectures: x86_64 + arm64)"
echo "Launch it with:  open DiscWright.app"
echo "(First launch: if macOS objects, right-click the app and choose Open.)"
