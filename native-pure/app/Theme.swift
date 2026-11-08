// Theme.swift — DiscWright's palette, lifted faithfully from
// the web app's stylesheet (app/index.html :root + component
// rules) so the native app wears the same colors GlitchedDot
// art-directed there:
//   --ss-blue #1a1e6e, --ss-blue-2 #232a86, --ss-lav #c2c9f4,
//   --ss-lav-light #d6dbf8, --ss-pane #eceefc, --bad #c81e1e.
// Component colors come from the .pane / .group / #meter / #log
// / .modetabs rules; see APP-NOTES.md (Step 2.5) for the map.

import SwiftUI

extension Color {
  /// Color from a 0xRRGGBB hex literal, sRGB.
  init(hex: UInt32, alpha: Double = 1.0) {
    self.init(.sRGB,
              red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255,
              opacity: alpha)
  }

  /// Color from 0–255 components (for the disc painting's
  /// rgba() stops, which the web canvas wrote that way).
  static func rgb(_ r: Double, _ g: Double, _ b: Double,
                  _ a: Double = 1.0) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255,
          opacity: a)
  }
}

enum Theme {
  // ---- the :root palette ----
  static let ssBlue = Color(hex: 0x1a1e6e)
  static let ssBlue2 = Color(hex: 0x232a86)
  static let ssLav = Color(hex: 0xc2c9f4)
  static let ssLavLight = Color(hex: 0xd6dbf8)
  static let ssPane = Color(hex: 0xeceefc)
  static let ssGray = Color(hex: 0x8d8d8d)
  static let ssGrayDark = Color(hex: 0x5f5f5f)
  static let text = Color(hex: 0x14141c)
  static let bad = Color(hex: 0xc81e1e)

  // ---- component colors ----
  /// .pane / .group border and the modetabs ring: #0d0f45.
  static let deepBorder = Color(hex: 0x0d0f45)
  /// .subtitle / footer text on the indigo backdrop: #b9bef5.
  static let subtitleOnBlue = Color(hex: 0xb9bef5)
  /// #stageStatus text: #3c4170.
  static let stageStatus = Color(hex: 0x3c4170)
  /// #log border: #9aa1d6.
  static let logBorder = Color(hex: 0x9aa1d6)
  /// #meterWrap border: #6d6d6d.
  static let meterBorder = Color(hex: 0x6d6d6d)
  /// .group card border: #9db2c4.
  static let cardBorder = Color(hex: 0x9db2c4)
  /// .group h3 text: #17324e.
  static let cardHeaderText = Color(hex: 0x17324e)
  /// .group h3 bottom border: #b9cbd9.
  static let cardHeaderBorder = Color(hex: 0xb9cbd9)
  /// table row separator (td border): #e6edf3.
  static let rowSeparator = Color(hex: 0xe6edf3)
  /// .dur text: #333.
  static let durText = Color(hex: 0x333333)
  /// `small` text on a pane: #43435a.
  static let smallText = Color(hex: 0x43435a)
  /// The disc hub label: #eef1ff, sub-line #aab3d6.
  static let hubLabel = Color(hex: 0xeef1ff)
  static let hubSub = Color(hex: 0xaab3d6)
  /// The mini disc glyph's hub dot (.app-icon): #123a82.
  static let glyphHub = Color(hex: 0x123a82)
  /// .modetabs .on text: #191970.
  static let modeTabOnText = Color(hex: 0x191970)

  // ---- gradients (all 180deg / top-to-bottom in the CSS) ----
  /// .client backdrop: ss-blue-2 at the top settling to ss-blue.
  static let clientGradient = LinearGradient(
    colors: [ssBlue2, ssBlue], startPoint: .top, endPoint: .bottom)
  /// .modetabs bar: #4b34b8 -> #2a1a7e (the SonicStage purple) —
  /// used for the header band.
  static let headerGradient = LinearGradient(
    colors: [Color(hex: 0x4b34b8), Color(hex: 0x2a1a7e)],
    startPoint: .top, endPoint: .bottom)
  /// .modetabs .on pill: #e3e6ff -> #b9c0f2.
  static let modeTabOnGradient = LinearGradient(
    colors: [Color(hex: 0xe3e6ff), Color(hex: 0xb9c0f2)],
    startPoint: .top, endPoint: .bottom)
  /// #meter fill: #7d84e8 -> #3a2a9e.
  static let meterGradient = LinearGradient(
    colors: [Color(hex: 0x7d84e8), Color(hex: 0x3a2a9e)],
    startPoint: .top, endPoint: .bottom)
  /// #meter.full fill: #f08a8a -> #c81e1e.
  static let meterFullGradient = LinearGradient(
    colors: [Color(hex: 0xf08a8a), bad],
    startPoint: .top, endPoint: .bottom)
  /// .group h3 strip: #f7fafc -> #dde8f1.
  static let cardHeaderGradient = LinearGradient(
    colors: [Color(hex: 0xf7fafc), Color(hex: 0xdde8f1)],
    startPoint: .top, endPoint: .bottom)
  /// table header strip: #fbfdfe -> #e7eff6.
  static let tableHeaderGradient = LinearGradient(
    colors: [Color(hex: 0xfbfdfe), Color(hex: 0xe7eff6)],
    startPoint: .top, endPoint: .bottom)
}

/// An appearance's worth of the colors that sit on the panes.
/// Step 3: the app follows the SYSTEM appearance — GlitchedDot
/// likes dark mode at night — so both appearances are designed.
/// `.light` is exactly the approved Step 2.5 look (every value
/// is the corresponding Theme constant); `.dark` is the same
/// identity at night: deep indigo-navy glass, lavender-white
/// text. Appearance-neutral colors (header band, meter fill,
/// the disc painting, the laser) stay in Theme and are shared.
struct Palette {
  /// Pane background (.pane).
  let pane: Color
  /// Primary text on a pane.
  let paneText: Color
  /// Secondary text on a pane (pane-header trailing, captions).
  let secondaryText: Color
  /// .group h3 text.
  let cardHeaderText: Color
  /// .group h3 strip gradient.
  let cardHeaderGradient: LinearGradient
  /// .group h3 bottom rule.
  let cardHeaderBorder: Color
  /// Track row background.
  let rowBackground: Color
  /// Track row separator.
  let rowSeparator: Color
  /// Log pane background.
  let logBackground: Color
  /// Log text.
  let logText: Color
  /// Capacity meter track (behind the indigo fill).
  let meterTrack: Color
  /// #stageStatus text.
  let stageStatus: Color
  /// `small` caption text on a pane.
  let smallText: Color
  /// Row duration text.
  let durText: Color

  static let light = Palette(
    pane: Theme.ssPane,
    paneText: Theme.text,
    secondaryText: Theme.ssGrayDark,
    cardHeaderText: Theme.cardHeaderText,
    cardHeaderGradient: Theme.cardHeaderGradient,
    cardHeaderBorder: Theme.cardHeaderBorder,
    rowBackground: .white,
    rowSeparator: Theme.rowSeparator,
    logBackground: .white,
    logText: Theme.text,
    meterTrack: .white,
    stageStatus: Theme.stageStatus,
    smallText: Theme.smallText,
    durText: Theme.durText)

  static let dark = Palette(
    pane: Color(hex: 0x23265e),
    paneText: Color(hex: 0xe6e9ff),
    secondaryText: Color(hex: 0xaab0e8),
    cardHeaderText: Color(hex: 0xdfe4ff),
    cardHeaderGradient: LinearGradient(
      colors: [Color(hex: 0x2a2e63), Color(hex: 0x1e214e)],
      startPoint: .top, endPoint: .bottom),
    cardHeaderBorder: Color(hex: 0x3a3f7d),
    rowBackground: Color(hex: 0x262a66),
    rowSeparator: Color(hex: 0x343a75),
    logBackground: Color(hex: 0x14163a),
    logText: Color(hex: 0xd6dbf8),
    meterTrack: Color(hex: 0x14163a),
    stageStatus: Color(hex: 0xc9cdf5),
    smallText: Color(hex: 0xaab0e8),
    durText: Color(hex: 0xc9cdf5))

  /// The palette for a system color scheme.
  static func of(_ scheme: ColorScheme) -> Palette {
    scheme == .dark ? .dark : .light
  }
}
