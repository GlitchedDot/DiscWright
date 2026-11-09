// DiscWrightApp.swift — the native app's entry point.
// Step 2: the SwiftUI face on the proven Swift core. No WebView,
// no bundled web UI — this is the pure app.

import SwiftUI

@main
struct DiscWrightApp: App {
  var body: some Scene {
    WindowGroup("WrightDisc — ATRAC3+ CD ISO maker") {
      ContentView()
    }
    .defaultSize(width: 1180, height: 820)
  }
}
