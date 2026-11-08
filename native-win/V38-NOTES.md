# v38 — room below the disc + still disc while working (2026-11-07)

Two asks from Lola, both from watching her own v37 video:

1. "Add space to the area below the disc, you can see its cut
   off, I don't want that."
2. "When encoding and writing, please have the CD stop
   spinning so ppl can see the laser move."

## The cut-off, measured

The painter sizes the disc from the canvas WIDTH (r = w/2 − 8)
and drops the ground shadow 1.348 R below the disc's center.
At the pane's width (canvas ≈ 380, R ≈ 182): center at
R + 14 = 196, shadow center at 196 + 245 = 441, shadow bottom
edge ≈ 460 — but the v37 canvas is only 336 tall. The shadow
was never near fitting; the v37 shrink (440 → 336, done to
rescue the clipped buttons) pushed the disc's own lower rim
(196 + 0.94·182 ≈ 367) past the edge too.

Fix, two halves:
- MainWindow.xaml: DiscCanvas Height 336 → 384.
- DiscPainter.cs Draw: disc center cy = r + 14 → r + 56. The
  disc's painted bottom lands ≈ 409 (its rim dips into the
  canvas's non-layout overshoot the way it always did — the
  rim region carries only the transparent sheen falloff), and
  the shadow — the part that visibly ended mid-fade — now
  completes at ≈ 385, inside the taller stage.
- The window stays 1200x980 (v37): the +48 of stage is well
  inside the ~130 of headroom v37 left, so Cancel and the
  Encode workers picker stay visible. Verified by the same
  row-sum arithmetic as the v37 notes.

## The still disc

DiscPainter.Update advanced the spin at 200 deg/s in the
burning state, so during a job the disc flipped front/back
2.5×/second and the laser spot strobed around the flip —
unreadable. The store raises IsBurning for BOTH phases of a
job (Store.cs: "the stage spins + draws the laser
throughout": encode start sets IsEncoding AND IsBurning; the
imported-ISO burn sets IsBurning alone), so "burning" in the
painter already means "encoding or writing".

v38: Update no longer advances _spinDeg while burning. The
disc holds still at whatever angle it froze at, the sheen
keeps rotating (light, not the disc), and the laser spot
travels outward across a still disc by the real progress
fraction — exactly what she asked to be able to watch. Idle
spin (80 deg/s) resumes when the job ends. BurnSpinSpeed is
gone; the header comment records the rule so nobody
"restores" it.

## Her test

Build as usual (STAMP 2026-11-07.v38). Idle: disc floats with
its full shadow visible below it, nothing cut at the stage's
bottom edge. Start an encode or a burn: the disc stops
turning, and the red laser spot creeps outward from the hub
as the job progresses. Cancel and Encode workers still
visible at the default window size.
