// DiscPainter.cs — the ATRAC CD stage painting for Win2D, a
// port of DiscStageView.swift (itself app.js drawDisc(),
// number for number):
//   - globe spin on the VERTICAL axis: scaleX = |cos(angle)|,
//     the back face (plain silver) showing when cos < 0,
//   - tilt squashY = 0.94, hover bob (idle only) with a 2.6 s
//     period and 0.0528 R amplitude,
//   - ground shadow ellipse tracking the squash
//     (scaleX 0.35 + 0.65|cos|), hidden while burning,
//   - rainbow sheen (rotates at 150 deg/s ONLY while burning),
//   - the laser while burning: pure-red core with glow, at the
//     Bottom stop (90 deg), radius by the area law
//     r = sqrt(rIn^2 + f*(rOut^2 - rIn^2)), rIn/rOut = 31/111
//     and 105/111 of R, with the web's flicker (0.88–1.0,
//     re-rolled in ~160 ms buckets),
//   - hub disc + "ATRAC CD" label in Comic Sans MS.
// Spin speeds: idle 80 deg/s only. While the stage is in its
// burning state (which covers BOTH the encode and the burn —
// the store raises IsBurning for the whole job, Step 3) the
// disc does NOT spin at all: Lola's rule (2026-11-07, v38) —
// a still disc is what lets people watch the laser spot travel
// outward as the work progresses. Before v38 the burning state
// spun at 200 deg/s and the laser strobed around the flip.
// The sheen keeps rotating while burning (it is light, not
// the disc turning). The laser's fraction f: since
// Step 3 (v26) the encode feeds it for real through the
// store's EncodeProgress; an imported ISO's burn (IMAPI2
// reports no progress) still paces it cosmetically — a full
// outward pass over 6 minutes from burn start — exactly the
// Mac's imported-ISO path.
//
// HOST CONTROL (changed 2026-11-06, v22): painted on Win2D's
// CanvasControl, driven by CompositionTarget.Rendering +
// Invalidate — NOT CanvasAnimatedControl. Win2D's own docs mark
// the animated control "currently unsupported for WinUI3", and
// in practice its swap chain presents alpha as opaque black:
// the stage rendered solid black despite ClearColor=
// "Transparent" (Lola's catch on the first launch). CanvasControl
// composites alpha properly, so the disc floats on the pane like
// the Mac/web stage. Update/Draw take plain values now (elapsed
// time; drawing session + size) so the host stays swappable.
//
// SHEEN TECHNIQUE (a deliberate, documented deviation — see
// STEP2-NOTES.md): the conic is painted as 72 triangle-fan
// slices interpolated from the same stop tables, the exact
// technique the APPROVED Mac build shipped after its SDK
// turned out to lack an angular-gradient API. Zero API risk,
// pixel-equivalent result. If Win2D's conic brush is ever
// confirmed on the target, PaintSheen is the one swap point.

using System;
using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Windows.UI;
using Windows.UI.Text;

namespace DiscWright;

public sealed class DiscPainter
{
    private const double IdleSpinSpeed = 80.0;  // web SPIN_DEG_PER_SEC
    // No burn spin speed since v38: the disc holds still while
    // encoding/writing so the laser's travel stays readable
    // (Lola, 2026-11-07).
    private const double SheenSpeed = 150.0;    // web burnStep sheen rate
    private const double SquashY = 0.94;        // web tilt squash target
    private const double LaserAngleDeg = 90.0;  // Bottom (saved default)
    private const string DiscLabel = "ATRAC CD";

    /// <summary>The store the stage reads (IsBurning for the
    /// spin/laser state, EncodeProgress for the laser's real
    /// fraction when an encode feeds it). Set by MainWindow
    /// once.</summary>
    public DiscStore? Store { get; set; }

    /// <summary>Set from the system's animation setting by
    /// MainWindow: when true the disc paints static and
    /// front-facing, echoing the web's prefers-reduced-motion.</summary>
    public bool ReduceMotion { get; set; }

    // Animation phase state, integrated in Update (the game
    // loop's own thread) so speed changes never jump — the
    // integral form of the Swift view's re-based phases.
    private double _clock;        // seconds since start (bob)
    private double _spinDeg;
    private double _sheenDeg;
    private double _burnElapsed;  // seconds since burn start
    private bool _wasBurning;

    public void Update(TimeSpan elapsed)
    {
        double dt = elapsed.TotalSeconds;
        _clock += dt;
        bool burning = Store?.IsBurning ?? false;
        if (burning && !_wasBurning) _burnElapsed = 0;
        if (burning) _burnElapsed += dt;
        _wasBurning = burning;
        if (!ReduceMotion)
        {
            // v38: while the stage is working (encode or burn —
            // IsBurning covers both), _spinDeg is NOT advanced:
            // the disc freezes at whatever angle it had, front
            // face settling out of the squash on its own as Draw
            // keeps using the frozen angle, and the laser spot
            // travels across a still disc. Idle spin resumes
            // when the job ends.
            if (!burning)
                _spinDeg = (_spinDeg + IdleSpinSpeed * dt) % 360;
            if (burning) _sheenDeg = (_sheenDeg + SheenSpeed * dt) % 360;
        }
    }

    public void Draw(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        bool burning = Store?.IsBurning ?? false;
        double spinDeg = ReduceMotion ? 0 : _spinDeg;
        double sheenDeg = ReduceMotion ? 0 : _sheenDeg;

        float w = (float)size.Width;
        // v39: the WHOLE artwork has to fit the stage, and it
        // is much taller than the disc: rim top at
        // cy - 0.94R - bob, shadow bottom at cy + 1.4535R —
        // a span of ~2.5 R. Sized from the pane's width alone
        // (R = 182) that span is ~455, taller than EVERY stage
        // height this app has shipped (440, 336, 384), so the
        // disc's bottom and shadow were clipped in all of
        // them and the status text below the stage clipped
        // into the disc (Lola, v36-v38, finally called in
        // v39). The radius is now capped at 160 and the center
        // is placed to center the whole span in the stage's
        // height: at R = 160 in the 416-tall stage the rim
        // clears the top by ~12 and the shadow completes ~12
        // above the bottom edge. Nothing paints outside.
        double r = Math.Min(w / 2 - 8, 160);
        if (r <= 10) return;
        double cx = w / 2;
        double cy = size.Height / 2 - 0.2304 * r;
        double c = Math.Cos(spinDeg * Math.PI / 180);
        double a = Math.Abs(c);
        bool back = c < 0;
        double bob = (!burning && !ReduceMotion)
            ? Math.Sin(_clock / 2.6 * 2 * Math.PI) * r * 0.0528
            : 0;

        // Ground shadow (idle hover only, as in the web): an
        // ellipse 0.791 R wide, 0.1055 R tall, centered 1.348 R
        // below the disc's center, narrowing with the spin
        // squash. Painted in its own transform so the radial
        // falloff stretches with it.
        if (!burning)
        {
            ds.Transform =
                Matrix3x2.CreateScale(
                    (float)(r * 0.791 * (0.35 + 0.65 * a)),
                    (float)(r * 0.1055)) *
                Matrix3x2.CreateTranslation((float)cx, (float)(cy + r * 1.348));
            var shadow = new CanvasRadialGradientBrush(ds, new[]
            {
                new CanvasGradientStop { Position = 0f, Color = Hex(0x000000, 0.55) },
                new CanvasGradientStop { Position = 0.7f, Color = Hex(0x000000, 0) },
                new CanvasGradientStop { Position = 1f, Color = Hex(0x000000, 0) },
            })
            { Center = Vector2.Zero, OriginOffset = Vector2.Zero, RadiusX = 1, RadiusY = 1 };
            ds.FillCircle(Vector2.Zero, 1f, shadow);
        }

        // The disc, in disc-local coordinates under the
        // spin/tilt squash — every layer below lives in this
        // one transform, exactly as the web canvas painted.
        ds.Transform =
            Matrix3x2.CreateScale((float)Math.Max(a, 0.02), (float)SquashY) *
            Matrix3x2.CreateTranslation((float)cx, (float)(cy + bob));

        // Base: the hub-dark center and silver band (front), or
        // the plain silver data side (back).
        var baseBrush = new CanvasRadialGradientBrush(
            ds, back ? BackStops : FrontStops)
        { Center = Vector2.Zero, OriginOffset = Vector2.Zero, RadiusX = (float)r, RadiusY = (float)r };
        ds.FillCircle(Vector2.Zero, (float)r, baseBrush);

        // Rainbow sheen (conic). The back's sweep starts at a
        // fixed 200 deg, as in the web.
        PaintSheen(ds, (float)r, back ? BackSheenStops : FrontSheenStops,
                   back ? 200.0 : sheenDeg);

        // Edge-on shading as the disc turns side-on.
        if (a < 0.999)
            ds.FillCircle(Vector2.Zero, (float)r,
                          Hex(0x000000, (1 - a) * 0.30));

        if (!back)
        {
            if (burning) DrawLaser(ds, r);
            DrawHubAndLabel(ds, r);
        }
        ds.Transform = Matrix3x2.Identity;
    }

    /// <summary>The laser spot, drawn under the hub as in the
    /// web: a radial falloff from a pure-red core, flickering,
    /// at the Bottom stop, its radius set by the area law.</summary>
    private void DrawLaser(CanvasDrawingSession ds, double r)
    {
        // The laser's fraction: the encode's REAL progress
        // when a feed exists (the store's EncodeProgress —
        // 0.85 × done/total while tracks encode, 1.0 while the
        // disc is authored), cosmetic pacing as the fallback
        // (an imported ISO's burn has no feed): a full outward
        // pass over 6 minutes. The Mac's DiscStageView splits
        // it the same way. Only the source of `frac` changed —
        // the area law below is the standing one.
        double frac = Store?.EncodeProgress
            ?? Math.Min(1, Math.Max(0, _burnElapsed / 360));
        double rIn = r * 31 / 111, rOut = r * 105 / 111;
        double rr = Math.Sqrt(rIn * rIn + frac * (rOut * rOut - rIn * rIn));
        double th = LaserAngleDeg * Math.PI / 180;
        float lx = (float)(Math.Cos(th) * rr), ly = (float)(Math.Sin(th) * rr);
        float lr = (float)(r * 0.055);
        // The web's random flicker, bucketed (~160 ms per re-roll).
        double h = Math.Sin((int)(_burnElapsed * 6) * 12.9898) * 43758.5453;
        double opacity = 0.88 + 0.12 * (h - Math.Floor(h));
        var stops = new CanvasGradientStop[LaserStops.Length];
        for (int i = 0; i < LaserStops.Length; i++)
        {
            var s = LaserStops[i];
            stops[i] = new CanvasGradientStop
            {
                Position = s.Position,
                Color = Color.FromArgb(
                    (byte)Math.Round(s.Color.A * opacity),
                    s.Color.R, s.Color.G, s.Color.B),
            };
        }
        var brush = new CanvasRadialGradientBrush(ds, stops)
        {
            Center = new Vector2(lx, ly),
            OriginOffset = Vector2.Zero,
            RadiusX = lr,
            RadiusY = lr,
        };
        ds.FillCircle(new Vector2(lx, ly), lr, brush);
    }

    /// <summary>The dark hub (radial gradient, offset
    /// highlight), its rim stroke, and the label: the disc's
    /// title wrapped to the hub width (max 3 lines, the web's
    /// algorithm) over the "ATRAC3+ · 64 kbps" sub-line, all in
    /// Comic Sans MS.</summary>
    private void DrawHubAndLabel(CanvasDrawingSession ds, double r)
    {
        float hr = (float)(r * 0.387);
        var hubBrush = new CanvasRadialGradientBrush(ds, new[]
        {
            new CanvasGradientStop { Position = 0f, Color = Hex(0x2c313b) },
            new CanvasGradientStop { Position = 0.7f, Color = Hex(0x191d23) },
            new CanvasGradientStop { Position = 1f, Color = Hex(0x191d23) },
        })
        {
            // Swift: gradient center offset (-0.3 hr, -0.4 hr),
            // end radius hr. (Its 0.1 hr start radius is a flat
            // #2c313b disc there; stop 0 being flat to 0.7
            // makes the difference invisible.)
            Center = new Vector2(-hr * 0.3f, -hr * 0.4f),
            OriginOffset = Vector2.Zero,
            RadiusX = hr,
            RadiusY = hr,
        };
        ds.FillCircle(Vector2.Zero, hr, hubBrush);
        ds.DrawCircle(Vector2.Zero, hr, Hex(0xffffff, 0.14),
                      Math.Max(1f, (float)(r * 0.0056)));

        float fs = (float)(r * 0.126);       // web: S * 0.062 of the 720 space
        float subFs = (float)(r * 0.0956);   // web: S * 0.047
        var bold = new CanvasTextFormat
        {
            FontFamily = "Comic Sans MS",
            FontSize = fs,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
        };
        // Word wrap to the hub width, as the web wraps it.
        float maxW = hr * 1.78f;
        var lines = new System.Collections.Generic.List<string>();
        string line = "";
        foreach (string word in DiscLabel.Split(' '))
        {
            string t = line.Length == 0 ? word : line + " " + word;
            if (Measure(ds, t, bold) > maxW && line.Length > 0)
            {
                lines.Add(line);
                line = word;
            }
            else line = t;
        }
        if (line.Length > 0) lines.Add(line);
        if (lines.Count > 3) lines.RemoveRange(3, lines.Count - 3);

        float lh = fs * 1.25f;
        // The sub-line gets a real gap below the title block
        // (the Mac v5 fix: the web's tighter spacing rendered
        // as a collision at native sizes). Title block first,
        // then the sub-line a clear subFs below its bottom edge.
        float totalH = lines.Count * lh + subFs * 1.9f;
        float ty = -totalH / 2 + lh / 2;
        foreach (string ln in lines)
        {
            DrawCenteredText(ds, ln, bold, Hex(0xeef1ff), maxW, ty);
            ty += lh;
        }
        var sub = new CanvasTextFormat
        {
            FontFamily = "Comic Sans MS",
            FontSize = subFs,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
        };
        DrawCenteredText(ds, "ATRAC3+ · 64 kbps", sub,
                         Hex(0xaab3d6), maxW, ty + subFs * 0.75f);
    }

    /// <summary>Draw one label line centered (both axes) on
    /// (0, cy) within a maxW-wide layout box — the counterpart
    /// of the Swift Canvas's anchor-center ResolvedText draw.</summary>
    private static void DrawCenteredText(CanvasDrawingSession ds, string text,
                                         CanvasTextFormat format, Color color,
                                         float maxW, float cy)
    {
        using var layout = new CanvasTextLayout(ds, text, format, maxW, 0);
        float hgt = (float)layout.LayoutBounds.Height;
        ds.DrawTextLayout(layout, new Vector2(-maxW / 2, cy - hgt / 2), color);
    }

    /// <summary>Width of a label line as the web's measureText
    /// reports it (metrics are unscaled; the squash applies at
    /// draw time).</summary>
    private static float Measure(CanvasDrawingSession ds, string text,
                                 CanvasTextFormat format)
    {
        using var layout = new CanvasTextLayout(ds, text, format, 0, 0);
        return (float)layout.LayoutBounds.Width;
    }

    // ---- the sheen (see the header note) ----

    private readonly struct SheenStop
    {
        public readonly double Loc;
        public readonly double R, G, B, A;
        public SheenStop(double loc, double r, double g, double b, double a)
        { Loc = loc; R = r; G = g; B = b; A = a; }
    }

    /// <summary>Paint the conic sheen as triangle-fan slices:
    /// the color at an absolute angle comes from the stop
    /// table at ((angle - start) mod 360) / 360, linearly
    /// interpolated — the same mapping createConicGradient
    /// uses in the web.</summary>
    private static void PaintSheen(CanvasDrawingSession ds, float r,
                                   SheenStop[] stops, double startDeg)
    {
        const int slices = 72;
        for (int i = 0; i < slices; i++)
        {
            double a0 = i * 360.0 / slices;
            double a1 = (i + 1) * 360.0 / slices;
            double frac = (a0 + a1) / 2 - startDeg;
            frac %= 360;
            if (frac < 0) frac += 360;
            frac /= 360;
            double t0 = a0 * Math.PI / 180, t1 = a1 * Math.PI / 180;
            using var builder = new CanvasPathBuilder(ds);
            builder.BeginFigure(Vector2.Zero);
            builder.AddLine(new Vector2(
                (float)(r * Math.Cos(t0)), (float)(r * Math.Sin(t0))));
            builder.AddLine(new Vector2(
                (float)(r * Math.Cos(t1)), (float)(r * Math.Sin(t1))));
            builder.EndFigure(CanvasFigureLoop.Closed);
            ds.FillGeometry(CanvasGeometry.CreatePath(builder),
                            SheenColor(stops, frac));
        }
    }

    /// <summary>Interpolate a sheen stop table at fraction t.</summary>
    private static Color SheenColor(SheenStop[] stops, double t)
    {
        if (stops.Length == 0) return Microsoft.UI.Colors.Transparent;
        var first = stops[0];
        if (t <= first.Loc) return Rgba(first);
        for (int i = 1; i < stops.Length; i++)
        {
            var s1 = stops[i];
            if (t <= s1.Loc)
            {
                var s0 = stops[i - 1];
                double span = s1.Loc - s0.Loc;
                double f = span > 0 ? (t - s0.Loc) / span : 0;
                return Color.FromArgb(
                    (byte)Math.Round((s0.A + (s1.A - s0.A) * f) * 255),
                    (byte)Math.Round(s0.R + (s1.R - s0.R) * f),
                    (byte)Math.Round(s0.G + (s1.G - s0.G) * f),
                    (byte)Math.Round(s0.B + (s1.B - s0.B) * f));
            }
        }
        return Rgba(stops[stops.Length - 1]);
    }

    private static Color Rgba(SheenStop s) => Color.FromArgb(
        (byte)Math.Round(s.A * 255),
        (byte)s.R, (byte)s.G, (byte)s.B);

    // ---- colors and stop tables (drawDisc, verbatim) ----

    private static Color Hex(uint rgb, double a = 1.0) => Color.FromArgb(
        (byte)Math.Round(a * 255),
        (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    private static Color Rgb(double r, double g, double b, double a) =>
        Color.FromArgb((byte)Math.Round(a * 255),
                       (byte)r, (byte)g, (byte)b);

    private static CanvasGradientStop Stop(double pos, Color color) =>
        new() { Position = (float)pos, Color = color };

    private static readonly CanvasGradientStop[] FrontStops =
    {
        Stop(0, Hex(0x20242b)), Stop(0.17, Hex(0x20242b)),
        Stop(0.175, Hex(0x2b3038)), Stop(0.21, Hex(0x2b3038)),
        Stop(0.225, Rgb(215, 222, 240, 0.20)),
        Stop(0.97, Rgb(215, 222, 240, 0.20)),
        Stop(0.98, Hex(0x3a4150)), Stop(1, Hex(0x3a4150)),
    };

    private static readonly CanvasGradientStop[] BackStops =
    {
        Stop(0, Hex(0x20242b)), Stop(0.07, Hex(0x20242b)),
        Stop(0.075, Hex(0x3a3f49)), Stop(0.12, Hex(0x3a3f49)),
        Stop(0.13, Hex(0xc8cedb)), Stop(0.55, Hex(0xdfe4ef)),
        Stop(0.92, Hex(0xb9c0cf)), Stop(1, Hex(0x454c5c)),
    };

    private static readonly CanvasGradientStop[] LaserStops =
    {
        Stop(0, Rgb(255, 0, 0, 0.95)), Stop(0.28, Rgb(255, 64, 64, 0.90)),
        Stop(0.47, Rgb(255, 110, 50, 0.70)), Stop(0.70, Rgb(255, 150, 110, 0.35)),
        Stop(1, Rgb(255, 150, 110, 0)),
    };

    private static readonly SheenStop[] FrontSheenStops =
    {
        new(0, 0, 0, 0, 0), new(0.07, 255, 90, 90, 0.20),
        new(0.15, 255, 200, 80, 0.20), new(0.24, 120, 255, 140, 0.18),
        new(0.33, 80, 180, 255, 0.22), new(0.43, 190, 120, 255, 0.20),
        new(0.53, 0, 0, 0, 0), new(0.65, 255, 255, 255, 0.10),
        new(0.76, 0, 0, 0, 0), new(0.89, 120, 220, 255, 0.14),
        new(1, 0, 0, 0, 0),
    };

    private static readonly SheenStop[] BackSheenStops =
    {
        new(0, 0, 0, 0, 0), new(0.11, 255, 120, 120, 0.13),
        new(0.31, 120, 255, 170, 0.11), new(0.53, 120, 170, 255, 0.13),
        new(0.72, 0, 0, 0, 0), new(0.89, 255, 255, 255, 0.10),
        new(1, 0, 0, 0, 0),
    };
}
