# v39 — the whole disc artwork fits the stage (2026-11-07)

Lola, on v38: "You didn't give the spinning CD space on the
bottom, the text is still clipping into it."

She's right, and it's older than v38. The painted artwork is
not the disc's diameter — it's a span of about 2.5 x R:

- rim top: cy − 0.94R − bob (bob up to 0.0528R)
- shadow bottom: cy + 1.348R + 0.1055R = cy + 1.4535R

At the radius the pane's width gives (R = 182), that span is
~455 tall. NO stage height this app has ever shipped fits it:
440 (v36 and earlier) clipped ~20 off the shadow, 336 (v37)
clipped the disc's own rim, 384 (v38) still clipped — and
v38 made it worse in one way, by moving the disc's center
DOWN 42, pushing its rim past the stage's bottom edge and
into the status text under the stage. The v38 note's claim
that the rim region "carries only transparent falloff" was
wrong where it mattered: she could see it, on her screen,
which is the only verdict that counts.

## The v39 fix

DiscPainter.Draw:
- Radius capped: r = min(w/2 − 8, 160). The disc is a bit
  smaller (320 across instead of 364) — the price of the
  whole artwork fitting at this pane width.
- Center placed to center the SPAN, not the disc:
  cy = stageHeight/2 − 0.2304R. At R = 160 in the 416 stage:
  rim top clears by ~12, shadow completes ~12 above the
  bottom edge. Nothing the painter draws crosses the stage's
  bounds, at any spin angle, bob included.

MainWindow.xaml:
- DiscCanvas Height 384 → 416 (the +32 comes out of the
  headroom the 980 window has; Cancel and Encode workers
  stay visible — same row arithmetic as v37/v38).
- The status line under the stage gets a 6 DIP top margin,
  so there's a visible breath of air between the disc's
  area and the text.

Still in force from v38: the disc holds still while encoding
or writing, so the laser spot's outward travel is watchable.

## Her test

Idle: the disc floats with its FULL shadow visible below it
and clear space between the shadow and "Please select a
type of disc." — no part of the disc or shadow touching the
text, at any point in the spin/bob cycle.
