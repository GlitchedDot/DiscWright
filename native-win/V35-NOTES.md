# v35 — the standalone link fix (2026-11-07)

## Verdict that produced this build

Lola ran the v34 build. The folder build launched (again), and
the standalone stage printed:

    STANDALONE RESULT: SKIPPED - compile

and, when she pasted the compiler block, the failure was at the
LINK step, not the compile step:

    discwright-launcher.obj : error LNK2019: unresolved external
    symbol __imp_MessageBoxW referenced in function Fail(...)
    fatal error LNK1120: 1 unresolved externals

So v32's standalone most likely died the same death: launcher.cpp
compiled, the link failed on exactly ONE missing symbol, the
warning scrolled by, and no DiscWright-standalone.exe was ever
produced — which is why no unpack folder and no error box ever
appeared on any "run" of it.

## Why

launcher.cpp asked MSVC to link shell32.lib and ole32.lib via
`#pragma comment(lib, ...)` for SHGetKnownFolderPath /
CoTaskMemFree, but never named user32.lib — and MessageBoxW
lives in user32. (The declaration itself isn't the issue; the
import library simply wasn't in the link.) GNU's linker
auto-resolves it from default libs, which is why Candy's
mingw cross-compile linked clean and the code looked innocent.

## The fix (this build)

- launcher.cpp: added `#pragma comment(lib, "user32.lib")` and
  corrected the build comment to name all three libraries.
- build-app.cmd: the cl line now names the libraries explicitly
  on the link line — `/link /SUBSYSTEM:WINDOWS user32.lib
  shell32.lib ole32.lib` — belt and braces, so the dependency no
  longer rests on pragmas alone. (Also already in this tree from
  the v35 prep: cl output is captured to standalone-build.log
  beside the script and printed inline on failure; STAMP is
  2026-11-07.v35, forcing a fresh unpack folder.)

## Her test

Fresh extract → PowerShell → `.\build-app.cmd` → expect
"STANDALONE RESULT: OK" → run `& ".\DiscWright-standalone.exe"`
from the same PowerShell: the watch console should narrate the
first unpack (stage lines + tar's file parade), then the app
opens. Later runs take the silent fast path.
