# DiscWright — third-party notices

DiscWright itself is Copyright (C) 2026 GlitchedDot and is licensed
under the GNU General Public License, version 3 (see `LICENSE` in
this repository).

DiscWright is built with the third-party components below. Their
licenses govern those components; DiscWright's GPL-3.0 governs
DiscWright's own code. The full text of the GNU Lesser General
Public License, version 2.1, is in `LGPL-2.1.txt` in this
repository; the GPL-3.0 text is `LICENSE`.

Components are listed per release form, because each form bundles
them differently:

- **Web app** (this repository's root — the GitHub Pages app)
- **Mac app** (`native-pure/`)
- **Windows app** (`native-win/`)

---

## Web app

### atracdenc (as WebAssembly)

Copyright (C) Dan Cherednik and contributors.
License: GNU Lesser General Public License, version 2.1 or
(at your option) any later version — LGPL-2.1-or-later.
Full text: `LGPL-2.1.txt` in this repository.

The web app's encoder, `encoder/atrac3p.wasm`, is compiled from
atracdenc source. Relinking a WebAssembly module is not practical
for a visitor, so the corresponding source of the encoder module
is the meaningful offer:

Source code for the exact version bundled here:
  https://github.com/dcherednik/atracdenc
  commit cb170709f836cb43dc0312455188c791159d81dc

atracdenc contains KissFFT and libgha code (see the shared
sections below), which are also present inside the wasm.

The web app does not use libsndfile or ffmpeg: the browser decodes
audio itself, and the Wasm build is atracdenc-only.

### KissFFT and libgha

See the shared sections below — both are compiled into the wasm
as part of atracdenc.

---

## Mac app

The Mac app's bundle also carries its own copy of these notices
and license texts (`Contents/Resources/Licenses/` in the built
app).

### atracdenc

Copyright (C) Dan Cherednik and contributors.
License: GNU Lesser General Public License, version 2.1 or
(at your option) any later version — LGPL-2.1-or-later.
Full text: LGPL-2.1.txt (in the app bundle's Licenses folder, and
`LGPL-2.1.txt` in this repository).

atracdenc ships inside DiscWright as a separate executable
(Contents/Resources/atracdenc) which DiscWright runs as a
subprocess. It is statically linked with libsndfile (below)
and contains KissFFT and libgha code (below).

Source code for the exact version bundled here:
  https://github.com/dcherednik/atracdenc
  commit cb170709f836cb43dc0312455188c791159d81dc

### libsndfile 1.2.2

Copyright (C) 1999-2018 Erik de Castro Lopo
<erikd@mega-nerd.com> and contributors.
License: GNU Lesser General Public License, version 2.1 or
(at your option) any later version — LGPL-2.1-or-later.
Full text: LGPL-2.1.txt.

In this build, libsndfile is compiled from its official source
release and statically linked into the bundled atracdenc, with
all optional external codec libraries disabled (WAV-family
formats only). No separate libsndfile library ships in the app.
(The pinned source tarball is included in this repository at
`native-pure/tools/libsndfile-1.2.2.tar.xz`; the build script
verifies its hash before use.)

Source code for the exact version bundled here:
  https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz
  SHA-256: 3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e

### KissFFT and libgha

See the shared sections below — both are compiled into the
bundled atracdenc.

---

## Windows app

### atracdenc

Copyright (C) Dan Cherednik and contributors.
License: GNU Lesser General Public License, version 2.1 or
(at your option) any later version — LGPL-2.1-or-later.
Full text: `LGPL-2.1.txt` in this repository.

atracdenc ships as its own executable (`atracdenc.exe`) which
DiscWright runs as a separate program; nothing of DiscWright's is
linked into it. The build is Universal-independent x64, compiled
by `native-win/build-app.cmd` from the atracdenc source included
in this repository (`native-win/encoder/atracdenc-src/`).

Source code for the exact version bundled here:
  https://github.com/dcherednik/atracdenc
  commit cb170709f836cb43dc0312455188c791159d81dc
  (the same source is vendored in this repository, above)

### libsndfile 1.2.2

Copyright (C) 1999-2018 Erik de Castro Lopo
<erikd@mega-nerd.com> and contributors.
License: GNU Lesser General Public License, version 2.1 or
(at your option) any later version — LGPL-2.1-or-later.
Full text: `LGPL-2.1.txt` in this repository.

The Windows app ships the official `sndfile.dll` beside
`atracdenc.exe`, dynamically linked — the LGPL's shared-library
mechanism (§6(b)): the library can be replaced by the user. The
build script downloads the official win64 distribution and
verifies it before use:

  https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2-win64.zip
  SHA-256: 2173935c0c1ed13cf627951d34483f9d405ead2eb473190461c42ba220643a3f

Note: whether the official win64 `sndfile.dll` internally bundles
further codec libraries (FLAC/Ogg/Vorbis/Opus are libsndfile's
usual dependencies, carrying their own BSD-style/Xiph notices) was
not verified at the time of writing.

### ffmpeg (gyan.dev essentials build)

Used only for decoding audio. `ffmpeg.exe` is bundled unmodified,
as a separate program, downloaded by the build script from
gyan.dev and verified before use:

  https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip
  SHA-256 (of the pinned download): 60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba

The builder's own statement: "All builds are 64-bit, static and
licensed as GPLv3" (https://www.gyan.dev/ffmpeg/builds/ — the
essentials build includes the GPL encoders libx264/libx265, which
is why the build is GPL rather than LGPL). The GPL-3.0 text is
`LICENSE` in this repository.

**Corresponding Source:** The bundled ffmpeg is the gyan.dev
essentials build of FFmpeg 9.0.2 (package
`ffmpeg-9.0.2-essentials_build.zip`, SHA-256 of the download
pinned in `native-win/build-app.cmd`). The Corresponding Source
for this build is the official FFmpeg 9.0.2 release source,
available from the FFmpeg project's releases directory at
ffmpeg.org/releases/ (file `ffmpeg-9.0.2.tar.xz`). In addition,
as a written offer under GPL-3.0 §6(b): the DiscWright
maintainer (GlitchedDot) offers to provide the complete
Corresponding Source for the exact ffmpeg build bundled with
DiscWright V1.0 to any third party who requests it, for a charge
of no more than the reasonable cost of distribution; this offer
is valid for at least three years from the V1.0 release date
(2026-11-07) and for as long as spare parts / support are
offered for V1.0. Contact via the GitHub repository
(github.com/GlitchedDot/DiscWright).

### KissFFT and libgha

See the shared sections below — both are compiled into
`atracdenc.exe`.

---

## Shared: inside atracdenc in all three forms

### KissFFT (vendored inside atracdenc)

Copyright (c) 2003-2010, Mark Borgerding

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
    * Neither the author nor the names of any contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

### libgha (vendored inside atracdenc)

BSD 2-Clause License

Copyright (c) 2018, Daniil Cherednik
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
