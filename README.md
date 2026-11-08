# DiscWright — ATRAC3+ CD ISO maker

by **GlitchedDot**

DiscWright makes ATRAC3+ CDs that play in Sony ATRAC CD Walkmans —
discs like the ones Sony's SonicStage used to make, for players
like the D-NE1. Sony discontinued that whole world years ago;
DiscWright replaces the one SonicStage job that mattered: take
your music, get a working ATRAC3+ CD.

It works the way the real discs work. The authoring recipe was
reverse-engineered from the genuine article and proven on real
hardware — discs authored by DiscWright play in an actual D-NE1.
Your tracks are encoded to 64 kbps ATRAC3+, organized into groups
(the playlists of the ATRAC CD world — the player navigates by
them, and every track belongs to exactly one), and written with
the same layout the original software produced.

DiscWright comes in three forms that share one proven authoring
core. Pick whichever fits:

## The three forms

### Web app (this repository's root)

Runs entirely in your browser — on GitHub Pages, or from a local
server if you prefer. Nothing is uploaded anywhere; all decoding,
encoding and authoring happens in the browser tab. The web app
makes the ISO; you burn it yourself (see step 5 below).

### Mac app (`native-pure/`)

A native macOS app (SwiftUI) that encodes, authors **and burns**
the disc itself — no separate burn step. Universal binary
(Intel + Apple Silicon), macOS 13 or later. Audio is decoded by
AVFoundation, so every format your Mac understands is welcome.

### Windows app (`native-win/`)

A native Windows app (WinUI 3) that likewise encodes, authors
and burns. Decoding is handled by ffmpeg, so its format appetite
is wide. The build also produces a **standalone single .exe** —
one file that unpacks itself on first run and opens the app, for
people who don't want to keep a folder of files around.

## Use it (web app)

Run it locally (Mac Terminal):

    cd <this folder>
    python3 -m http.server 8000

Then open http://localhost:8000 in Safari. (On the GitHub Pages
site, just open the page.)

1. Drag audio files onto the page (MP3 and anything else the
   browser can decode) — or drag a whole folder, or pick one
   with the folder picker: folders are searched recursively up
   to 2 levels deep and every audio file inside is added in
   path order. Tags are read from ID3v2 or ID3v1;
   anything missing falls back to the file name and can be
   edited right in the list.
2. Arrange tracks into groups — each group is a playlist on the
   disc. Every track sits in exactly one group.
3. Pick the blank size. The meter shows the estimated fill;
   the build refuses if the disc would overflow.
4. Build ISO. The page encodes every track to 64 kbps ATRAC3+
   (atracdenc in WebAssembly), encrypts and authors the disc
   with the hardware-proven recipe, and downloads `atrac-disc.iso`.

   (While it works, the stage performs: at idle the disc hovers
   and globe-spins over its shadow. On Build, the spin settles,
   a top-loading drive slides in from the left, the disc tilts
   into the well and the semi-transparent lid closes. Each
   track's title flies in from the right and is sucked into the
   drive as the track is buffered, then the disc spins under the
   lid while the red laser tracks outward with true CD geometry
   — fast across the inner tracks, slower toward the rim — as
   the data is written. When the build finishes, the lid opens,
   the disc is placed into a jewel case, the case closes, the
   drive fades away and the case glides to center. The laser's
   position — 8 stops, 45 degrees apart — can be chosen in the
   Laser position menu; the choice is remembered between visits.)
5. Burn the ISO as a plain single-session disc image.

### Known limits of this first version (web app)

- Decoding and encoding run in parallel across the machine's
  cores: a pool of encoder workers sized from the browser's
  reported thread count (up to 8), with a few decodes running
  ahead of them. The final authoring pass is still
  single-threaded: the payload encryption runs in plain
  JavaScript at roughly 0.3 MB/s, so a full disc's authoring
  step can take a while even when the encoding flew. (A faster
  cipher is a drop-in upgrade for later.)
- One encode per track is held in memory; CD-length audio is fine.

## Building the native apps

**Mac** — in Terminal (macOS), from the `native-pure/` folder:

    ./build-app.sh

You need Apple's Command Line Tools and CMake; the script stops
early with the exact fix if either is missing, and builds
everything else itself — including the encoder and its
statically-linked libraries — from the pinned sources in the
tree. Nothing is taken from Homebrew at runtime. See
`native-pure/NOTES.md` and `native-pure/STEP4-NOTES.md` for the
details and design notes.

**Windows** — from the `native-win/` folder, build with Visual
Studio's MSBuild via the included script (see the notes at the
top of `native-win/build-app.cmd`); `native-win/build-singlefile.cmd`
additionally produces the standalone single-exe. The build
downloads its pinned tools (CMake, ffmpeg, libsndfile) and
verifies each by SHA-256 before use. See `native-win/NOTES.md`
for the design and the self-test.

## License

DiscWright is Copyright (C) 2026 GlitchedDot, licensed under the
**GNU General Public License, version 3** — see `LICENSE`.

Third-party components (the atracdenc encoder, libsndfile,
ffmpeg, KissFFT, libgha) keep their own licenses; the full
notices are in `THIRD-PARTY-NOTICES.md`, and the LGPL-2.1 text is
in `LGPL-2.1.txt`.

---

## Easter eggs

### The collection

Little human moments found inside Sony's OpenMG code while reverse-engineering it. Collected during the project, at the author's request — and still growing: more of these turn up as the reverse engineering continues.

## #1 — "OpenMG oh my god!!"

- **What:** The message text of an OMGException thrown by pfcom's ProcessFile constructor path — exception code `(0x2)`, tag `<8858>`, core string: **"OpenMG oh my god!!"**
- **Found:** 2026-10-29, harness run 153 (Unicorn SAL emulation of Sony's own binaries). The ctor had just read maclist1.dat in full (21,420 bytes) at its real repository path when it threw; the harness's log caught the message being assembled (`swprintf … ' - OpenMG oh my god!!'`).
- **Why it stayed hidden so long:** Reaching this throw requires the maclist database invoke to do its *full* processing, which only happened once the harness's fake CoCreateGuid answer (constant bytes 00 01 02…0f) was replaced with the genuine TypeLib GUID {317B92BE-B04A-4EF6-BC04-02346DEFDB20} from Lola's Toshiba registry. Under every earlier configuration the flow died earlier (at the (0x303) "bad ProcessFile MAC" wall), so this string never executed.
- **Lola's note:** "Doubt anyone else found that" — plausibly true: it only fires deep inside a failing ProcessFile construction, in code paths essentially nobody outside Sony ever ran under a microscope.
- **Postscript (Session 18, same day):** the throw turned out to be a null-guard assertion — FUN_65103e50 throws it when a DB-state object's core pointer is NULL, i.e. "you used this before initializing it," with a joke for a message. Programmer-error, not a data verdict.

## #2 — "hayappon !"

- **What:** A standalone string in salwrap.dll's .rdata at VA 0x65139844, sitting between "EKB/" and "Debugger is present" in the ICV/restore string group.
- **Found:** 2026-10-29, Session 18, during a string census of the (0x2) throw's neighborhood. No context recovered yet — just the word, an exclamation mark, and twenty years of silence. (Possibly a dev's handle or an in-joke; unclaimed.)

## #3 — "poi poi poi poi"

- **What:** A four-"poi" variant string, salwrap.dll .rdata VA 0x651398ac. The three-poi "poi poi poi" (the salexec engine's deliberate-throw message from the harness's early days) was already known; this is its bigger sibling.
- **Found:** 2026-10-29, Session 18, same census.

## #4 — "OpenMG oh my god!" (one exclamation mark)

- **What:** The (0x302) exception message in FUN_65109380's failure tail — the one-`!` sibling of entry #1's two-`!` (0x2) message. A whole family of escalating oh-my-gods, each with its own error code.
- **Found:** 2026-10-29, Session 18, while dissecting FUN_65109380 (the maclist/ICV load-verify method). This branch was not taken in our runs — the string was read from the binary, not caught in flight.

## #5 — "at3 decoder: oh my god"

- **What:** A debug/log string inside omgconv2.dll at FUN_6193ec54: **"at3 decoder: oh my god"** — no exclamation marks this time; the family is growing dialects.
- **Found:** 2026-11-02, Session 46, during the Ghidra decompilation sweep of omgconv2.dll (the conversion engine whose PCMTOATP path drives nc.ocm — the session that superseded the Session 45 wall). Read from the decomp, not caught in flight.
- **Filed:** 2026-11-02 at Lola's word ("File it and continue"), after being surfaced unfiled in the Session 46 report.

## #6 — "OpenMG oh my god!!!" (three exclamation marks)

- **What:** A third sibling in the oh-my-god family: the string "OpenMG oh my god!!!" in salwrap.dll's .rdata at VA 0x6513968c, in the EKB string group — it sits between "bad newest ekb version" and "bad ProcessFile MAC". Read from the binary, not caught in flight.
- **Found:** 2026-11-06, in a second-pass string census Lola asked for while the DiscWright Windows app work was in flight — 857 unique binaries across all four corpora on hand (both Toshiba trees, the ULTIMATE OpenMG set, the batch2 Sony Shared tree), ASCII and UTF-16 strings from each. The Session 18 census had walked this exact neighborhood (entry #1's string is two entries away at 0x65139630) and missed it.
- **The family, complete:** "oh my god!" (one mark, ICV restore — entry #4), "oh my god!!" (two, the maclist/ProcessFile constructor — entry #1), "oh my god!!!" (three, the EKB path). The worse the failure, the more punctuation.

## #7 — "Botamoti": a core module named after a sweet

- **What:** Botamoti.dll and botamoti.ocm are real, shipped OpenMG components — version resource "Botamoti Module", Copyright 1999-2007 Sony Corporation. *Botamochi* (ぼたもち) is a Japanese sweet made of glutinous rice and sweet azuki paste. The module sits in salwrap.dll's ICV module list (alongside l3.ocm, init2.ocm, region.ocm, kdrm.ocm) and is referenced by pfcom.dll and OMGUtils.dll — in a directory where every other module is named for its function (ekbman, kdrm, icv), this one is named for a dessert.
- **Found:** 2026-11-06, same second-pass census. No joke strings inside the module itself; the codename that shipped is the trace.
- **Filed:** 2026-11-06 at Lola's word, together with entry #6.
