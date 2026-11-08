# v37 — window height: Cancel + Encode workers visible (2026-11-07)

Lola's ask, verbatim in spirit: "make it tall enough so ppl can
see the cancel button and select how many workers. It's hidden
and I don't want that."

## Why it was hidden

The window opened at 1200x880 (MainWindow constructor). The
right column is a fixed stack of Auto rows — header, disc stage
(440), status line, separator, blank picker, capacity meter,
then the action rows (Burn Disc / Import ISO, then Cancel +
Encode workers, then the hint line). Measured against the
XAML, the stack runs roughly 100 DIP taller than the client
area an 880 window offers, so the layout clipped from the
bottom — and the bottom rows are exactly Cancel and the
workers picker. (This also retro-explains the v31 evening's
"Where is the make iso button?" — same clipping, same rows.)

## The change (two halves, ~200 DIP of headroom)

- MainWindow.xaml.cs: AppWindow.Resize 1200x880 → 1200x980,
  with the reasoning left in the comment.
- MainWindow.xaml: DiscCanvas Height 440 → 336, with a comment
  saying why. DiscPainter sizes the disc from the canvas
  layout bounds (no hardcoded 440 anywhere in the painter —
  grepped), so the disc stays round, just less greedy.

Nothing else moved: same rows, same order, same bindings. The
NumberBox warning comment and the v32 action-row comments are
untouched.

## Her test

Build as usual; at the default window size — no maximizing —
the right column should now show everything down through
Cancel, the Encode workers picker, and the hint line, for both
the folder build and the standalone (STAMP 2026-11-07.v37
forces the standalone's fresh unpack).
