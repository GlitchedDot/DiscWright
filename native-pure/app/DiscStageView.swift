// DiscStageView.swift — the ATRAC CD stage, natively: the
// spinning disc from the web app, repainted as ONE SwiftUI
// Canvas (the web version's black-bar lesson, honored in
// spirit: the whole disc — base, sheen, laser, hub, label,
// spin squash, tilt, bob, shading — is painted into a single
// flat Canvas; nothing is a layered/transformed view).
//
// The painting mirrors app.js drawDisc() number for number:
//   - globe spin on the VERTICAL axis: scaleX = |cos(angle)|,
//     the back face (plain silver) showing when cos < 0,
//   - tilt squashY = 0.94, hover bob (idle only) with a 2.6 s
//     period and 0.0528 R amplitude,
//   - ground shadow ellipse tracking the squash
//     (scaleX 0.35 + 0.65|cos|), hidden while burning, as the
//     web's shadow only shows in its idle state,
//   - rainbow conic sheen (rotates at 150 deg/s ONLY while
//     burning, exactly like the web's burnStep),
//   - the laser while burning: pure-red core with glow, at the
//     Bottom stop (90 deg, the user's saved default), radius by
//     the area law r = sqrt(rIn^2 + f*(rOut^2 - rIn^2)),
//     rIn/rOut = 31/111 and 105/111 of R, with the web's random
//     flicker (level 0.88–1.0, re-rolled in ~160 ms buckets),
//   - hub disc + "ATRAC CD" label in Comic Sans MS (the web
//     chips' face; it ships with macOS).
// Spin speeds: the web's approved idle is 80 deg/s; while
// burning the disc spins faster (200 deg/s) per the restyle
// brief ("idle spin is slower"). The laser's fraction f is REAL
// since Step 3: the store's encodeProgress (0.85 x tracks done
// while encoding, 1.0 through authoring/burn) drives it. Only a
// burn with no encode behind it (an imported ISO — drutil
// reports no progress) falls back to the old cosmetic pacing:
// a full outward pass over 6 minutes from burn start.

import SwiftUI
import AppKit // NSFont / NSString sizing for the hub label

struct DiscStageView: View {
  @EnvironmentObject var store: DiscStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  // Animation phase bookkeeping: angles integrate piecewise so
  // the speed can change when a burn starts/stops without the
  // disc jumping. phaseStart/spinBase/sheenBase are re-based in
  // onChange(of: isBurning).
  @State private var phaseStart = Date()
  @State private var spinBase: Double = 0
  @State private var sheenBase: Double = 0
  @State private var burnStart: Date? = nil

  private static let idleSpinSpeed = 80.0   // web SPIN_DEG_PER_SEC
  private static let burnSpinSpeed = 200.0
  private static let sheenSpeed = 150.0     // web burnStep sheen rate
  private static let squashY = 0.94         // web tilt squash target
  private static let laserAngleDeg = 90.0   // Bottom (saved default)
  private static let discLabel = "ATRAC CD"

  var body: some View {
    VStack(spacing: 4) {
      TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                              paused: reduceMotion)) { tl in
        Canvas { ctx, size in
          paint(ctx, size, date: tl.date)
        }
      }
      .aspectRatio(1.0 / 1.30, contentMode: .fit)

      Text(store.stageStatus)
        .font(.callout.bold())
        .foregroundColor(Palette.of(colorScheme).stageStatus)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    .onChange(of: store.isBurning) { nowBurning in
      // Freeze the angles accumulated under the OLD speed into
      // the bases, then restart the phase under the new one.
      let now = Date()
      let dt = now.timeIntervalSince(phaseStart)
      spinBase += dt * (nowBurning ? Self.idleSpinSpeed
                                   : Self.burnSpinSpeed)
      if !nowBurning { sheenBase += dt * Self.sheenSpeed }
      phaseStart = now
      burnStart = nowBurning ? now : nil
    }
  }

  // ---- the painting (app.js drawDisc, ported) ----

  private func paint(_ ctx: GraphicsContext, _ size: CGSize,
                     date: Date) {
    let burning = store.isBurning
    let dt = date.timeIntervalSince(phaseStart)
    var spinDeg = spinBase + dt * (burning ? Self.burnSpinSpeed
                                           : Self.idleSpinSpeed)
    var sheenDeg = sheenBase + (burning ? dt * Self.sheenSpeed : 0)
    if reduceMotion { spinDeg = 0; sheenDeg = 0 }

    let r = size.width / 2 - 8
    guard r > 10 else { return }
    let cx = size.width / 2
    let cy = r + 14
    let c = cos(spinDeg * .pi / 180)
    let a = abs(c)
    let back = c < 0
    let bob: CGFloat = (!burning && !reduceMotion)
      ? CGFloat(sin(date.timeIntervalSinceReferenceDate / 2.6
                      * 2 * .pi)) * r * 0.0528
      : 0

    // Ground shadow (idle hover only, as in the web): an ellipse
    // 0.791 R wide, 0.1055 R tall, centered 1.348 R below the
    // disc's center, narrowing with the spin squash. Painted in
    // its own transform so the radial falloff stretches with it.
    if !burning {
      var s = ctx
      s.translateBy(x: cx, y: cy + r * 1.348)
      s.scaleBy(x: r * 0.791 * CGFloat(0.35 + 0.65 * a),
                y: r * 0.1055)
      s.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
             with: .radialGradient(
               Gradient(stops: [
                 .init(color: .black.opacity(0.55), location: 0),
                 .init(color: .black.opacity(0), location: 0.7),
                 .init(color: .black.opacity(0), location: 1),
               ]),
               center: .zero, startRadius: 0, endRadius: 1))
    }

    // The disc, in disc-local coordinates under the spin/tilt
    // squash — every layer below lives in this one transform,
    // exactly as the web canvas painted under its scale().
    var d = ctx
    d.translateBy(x: cx, y: cy + bob)
    d.scaleBy(x: CGFloat(max(a, 0.02)), y: CGFloat(Self.squashY))
    let circle = Path(ellipseIn: CGRect(x: -r, y: -r,
                                        width: 2 * r, height: 2 * r))

    // Base: the hub-dark center and silver band (front), or the
    // plain silver data side (back).
    d.fill(circle, with: .radialGradient(
      Gradient(stops: back ? Self.backStops : Self.frontStops),
      center: .zero, startRadius: 0, endRadius: r))

    // Rainbow sheen (conic). The back's sweep starts at a fixed
    // 200 deg, as in the web. GraphicsContext.Shading has no
    // angularGradient on this SDK (first Mac build, 2026-11-05),
    // so the conic is painted as 72 triangle-fan slices colored
    // by interpolating the same stop tables — same colors, same
    // rotation, no gradient API.
    let sheenStart = back ? 200.0 : sheenDeg
    Self.paintSheen(&d, r: r,
                    stops: back ? Self.backSheenStops : Self.frontSheenStops,
                    startDeg: sheenStart)

    // Edge-on shading as the disc turns side-on.
    if a < 0.999 {
      d.fill(circle, with: .color(.black.opacity((1 - a) * 0.30)))
    }

    if !back {
      if burning { drawLaser(&d, r: r, date: date) }
      drawHubAndLabel(&d, r: r)
    }
  }

  /// The laser spot, drawn under the hub as in the web: a radial
  /// falloff from a pure-red core, flickering, at the Bottom
  /// stop, its radius set by the area law.
  private func drawLaser(_ d: inout GraphicsContext, r: CGFloat,
                         date: Date) {
    let elapsed = burnStart.map { date.timeIntervalSince($0) } ?? 0
    // Real progress when the store has it (Step 3 encodes);
    // the 6-minute cosmetic pass only for progress-less burns
    // (imported ISOs through drutil).
    let frac: Double
    if let p = store.encodeProgress {
      frac = min(1, max(0, p))
    } else {
      frac = min(1, max(0, elapsed / 360))
    }
    let rIn = r * 31 / 111, rOut = r * 105 / 111
    let rr = sqrt(rIn * rIn + CGFloat(frac) * (rOut * rOut - rIn * rIn))
    let th = Self.laserAngleDeg * .pi / 180
    let lx = CGFloat(cos(th)) * rr, ly = CGFloat(sin(th)) * rr
    let lr = r * 0.055
    // The web's random flicker, bucketed (~160 ms per re-roll).
    let h = sin(Double(Int(elapsed * 6)) * 12.9898) * 43758.5453
    var g = d
    g.opacity = 0.88 + 0.12 * (h - floor(h))
    g.fill(Path(ellipseIn: CGRect(x: lx - lr, y: ly - lr,
                                  width: 2 * lr, height: 2 * lr)),
           with: .radialGradient(
             Gradient(stops: [
               .init(color: .rgb(255, 0, 0, 0.95), location: 0),
               .init(color: .rgb(255, 64, 64, 0.90), location: 0.28),
               .init(color: .rgb(255, 110, 50, 0.70), location: 0.47),
               .init(color: .rgb(255, 150, 110, 0.35), location: 0.70),
               .init(color: .rgb(255, 150, 110, 0), location: 1),
             ]),
             center: CGPoint(x: lx, y: ly),
             startRadius: 0, endRadius: lr))
  }

  /// The dark hub (radial gradient, offset highlight), its rim
  /// stroke, and the label: the disc's title wrapped to the hub
  /// width (max 3 lines, the web's algorithm) over the
  /// "ATRAC3+ · 64 kbps" sub-line, all in Comic Sans MS.
  private func drawHubAndLabel(_ d: inout GraphicsContext, r: CGFloat) {
    let hr = r * 0.387
    let hub = Path(ellipseIn: CGRect(x: -hr, y: -hr,
                                     width: 2 * hr, height: 2 * hr))
    d.fill(hub, with: .radialGradient(
      Gradient(stops: [
        .init(color: Color(hex: 0x2c313b), location: 0),
        .init(color: Color(hex: 0x191d23), location: 0.7),
        .init(color: Color(hex: 0x191d23), location: 1),
      ]),
      center: CGPoint(x: -hr * 0.3, y: -hr * 0.4),
      startRadius: hr * 0.1, endRadius: hr))
    d.stroke(hub, with: .color(.white.opacity(0.14)),
             lineWidth: max(1, r * 0.0056))

    let fs = r * 0.126            // web: S * 0.062 of the 720 space
    let subFs = r * 0.0956        // web: S * 0.047
    let font = Font.custom("Comic Sans MS", size: fs)
    // Word wrap to the hub width, as the web wraps it.
    let maxW = hr * 1.78
    var lines: [String] = []
    var line = ""
    for w in Self.discLabel.split(separator: " ").map(String.init) {
      let t = line.isEmpty ? w : line + " " + w
      if Self.textWidth(t, size: fs) > maxW && !line.isEmpty {
        lines.append(line); line = w
      } else { line = t }
    }
    if !line.isEmpty { lines.append(line) }
    let shown = Array(lines.prefix(3))
    let lh = fs * 1.25
    // The sub-line gets a real gap below the title block: the
    // web's tighter spacing rendered as a collision at native
    // sizes (GlitchedDot's screenshot, 2026-11-05 — the sub-line
    // struck through the title). Title block first, then the
    // sub-line a clear subFs below its bottom edge.
    let totalH = CGFloat(shown.count) * lh + subFs * 1.9
    var ty = -totalH / 2 + lh / 2
    for ln in shown {
      d.draw(d.resolve(Text(ln).font(font).fontWeight(.bold)
                         .foregroundColor(Theme.hubLabel)),
             at: CGPoint(x: 0, y: ty), anchor: .center)
      ty += lh
    }
    d.draw(d.resolve(Text("ATRAC3+ · 64 kbps")
                       .font(.custom("Comic Sans MS", size: subFs))
                       .foregroundColor(Theme.hubSub)),
           at: CGPoint(x: 0, y: ty + subFs * 0.75), anchor: .center)
  }

  /// Width of a label line as the web's measureText reports it
  /// (metrics are unscaled; the squash applies at draw time).
  /// GraphicsContext.ResolvedText has no sizeThatFits on this
  /// SDK (first Mac build, 2026-11-05), so measure with
  /// AppKit's string sizing in the same face instead.
  private static func textWidth(_ s: String, size: CGFloat) -> CGFloat {
    let f = NSFont(name: "Comic Sans MS", size: size)
      ?? NSFont.systemFont(ofSize: size)
    return (s as NSString).size(withAttributes: [.font: f]).width
  }

  /// One sheen stop as raw RGBA (0–255, alpha 0–1), so the
  /// wedge painter can interpolate without a gradient API.
  private struct SheenStop {
    let loc: Double
    let r: Double, g: Double, b: Double, a: Double
  }

  /// Paint the conic sheen as triangle-fan slices: the color at
  /// an absolute angle comes from the stop table at
  /// ((angle - start) mod 360) / 360, linearly interpolated —
  /// the same mapping createConicGradient uses in the web.
  private static func paintSheen(_ d: inout GraphicsContext, r: CGFloat,
                                 stops: [SheenStop], startDeg: Double) {
    let slices = 72
    for i in 0..<slices {
      let a0 = Double(i) * 360 / Double(slices)
      let a1 = Double(i + 1) * 360 / Double(slices)
      var frac = (a0 + a1) / 2 - startDeg
      frac = frac.truncatingRemainder(dividingBy: 360)
      if frac < 0 { frac += 360 }
      frac /= 360
      let t0 = a0 * .pi / 180, t1 = a1 * .pi / 180
      var wedge = Path()
      wedge.move(to: .zero)
      wedge.addLine(to: CGPoint(x: Double(r) * cos(t0),
                                y: Double(r) * sin(t0)))
      wedge.addLine(to: CGPoint(x: Double(r) * cos(t1),
                                y: Double(r) * sin(t1)))
      wedge.closeSubpath()
      d.fill(wedge, with: .color(sheenColor(stops: stops, at: frac)))
    }
  }

  /// Interpolate a sheen stop table at fraction t.
  private static func sheenColor(stops: [SheenStop], at t: Double) -> Color {
    guard let first = stops.first else { return .clear }
    if t <= first.loc {
      return Color(.sRGB, red: first.r / 255, green: first.g / 255,
                   blue: first.b / 255, opacity: first.a)
    }
    for i in 1..<stops.count {
      let s1 = stops[i]
      if t <= s1.loc {
        let s0 = stops[i - 1]
        let span = s1.loc - s0.loc
        let f = span > 0 ? (t - s0.loc) / span : 0
        return Color(.sRGB,
                     red: (s0.r + (s1.r - s0.r) * f) / 255,
                     green: (s0.g + (s1.g - s0.g) * f) / 255,
                     blue: (s0.b + (s1.b - s0.b) * f) / 255,
                     opacity: s0.a + (s1.a - s0.a) * f)
      }
    }
    let last = stops[stops.count - 1]
    return Color(.sRGB, red: last.r / 255, green: last.g / 255,
                 blue: last.b / 255, opacity: last.a)
  }

  // ---- gradient stop tables (app.js drawDisc, verbatim) ----

  private static let frontStops: [Gradient.Stop] = [
    .init(color: Color(hex: 0x20242b), location: 0),
    .init(color: Color(hex: 0x20242b), location: 0.17),
    .init(color: Color(hex: 0x2b3038), location: 0.175),
    .init(color: Color(hex: 0x2b3038), location: 0.21),
    .init(color: .rgb(215, 222, 240, 0.20), location: 0.225),
    .init(color: .rgb(215, 222, 240, 0.20), location: 0.97),
    .init(color: Color(hex: 0x3a4150), location: 0.98),
    .init(color: Color(hex: 0x3a4150), location: 1),
  ]

  private static let backStops: [Gradient.Stop] = [
    .init(color: Color(hex: 0x20242b), location: 0),
    .init(color: Color(hex: 0x20242b), location: 0.07),
    .init(color: Color(hex: 0x3a3f49), location: 0.075),
    .init(color: Color(hex: 0x3a3f49), location: 0.12),
    .init(color: Color(hex: 0xc8cedb), location: 0.13),
    .init(color: Color(hex: 0xdfe4ef), location: 0.55),
    .init(color: Color(hex: 0xb9c0cf), location: 0.92),
    .init(color: Color(hex: 0x454c5c), location: 1),
  ]

  private static let frontSheenStops: [SheenStop] = [
    .init(loc: 0, r: 0, g: 0, b: 0, a: 0),
    .init(loc: 0.07, r: 255, g: 90, b: 90, a: 0.20),
    .init(loc: 0.15, r: 255, g: 200, b: 80, a: 0.20),
    .init(loc: 0.24, r: 120, g: 255, b: 140, a: 0.18),
    .init(loc: 0.33, r: 80, g: 180, b: 255, a: 0.22),
    .init(loc: 0.43, r: 190, g: 120, b: 255, a: 0.20),
    .init(loc: 0.53, r: 0, g: 0, b: 0, a: 0),
    .init(loc: 0.65, r: 255, g: 255, b: 255, a: 0.10),
    .init(loc: 0.76, r: 0, g: 0, b: 0, a: 0),
    .init(loc: 0.89, r: 120, g: 220, b: 255, a: 0.14),
    .init(loc: 1, r: 0, g: 0, b: 0, a: 0),
  ]

  private static let backSheenStops: [SheenStop] = [
    .init(loc: 0, r: 0, g: 0, b: 0, a: 0),
    .init(loc: 0.11, r: 255, g: 120, b: 120, a: 0.13),
    .init(loc: 0.31, r: 120, g: 255, b: 170, a: 0.11),
    .init(loc: 0.53, r: 120, g: 170, b: 255, a: 0.13),
    .init(loc: 0.72, r: 0, g: 0, b: 0, a: 0),
    .init(loc: 0.89, r: 255, g: 255, b: 255, a: 0.10),
    .init(loc: 1, r: 0, g: 0, b: 0, a: 0),
  ]
}
