// BurnService.swift — the burn, adapted from the superseded
// WebView shell's proven code (native-mac/src/main.swift): a
// confirmation alert, then /usr/bin/drutil (the DiscRecording
// engine under Burn.app, whose burns are the proven ones on the
// D-NE1), then a result alert carrying drutil's own output.

import Foundation
import AppKit

/// The burn's lifecycle, reported to the store: the stage
/// status line and the spinning laser key off it.
enum BurnState {
  case started
  case finished(success: Bool)
}

enum BurnService {

  /// offerBurn(iso, source): "Burn this disc now?" — the shell's
  /// wording, verbatim. onState reports .started while drutil
  /// runs and .finished with its outcome, so the UI can disable
  /// the button and drive the disc stage. onDeclined (Step 3)
  /// fires when the user picks "Not Now" — the new-disc flow
  /// needs it to stand the stage back down after an encode.
  static func offerBurn(iso: URL, source: String,
                        onState: @escaping (BurnState) -> Void,
                        onDeclined: (() -> Void)? = nil) {
    let alert = NSAlert()
    alert.messageText = "Burn this disc now?"
    alert.informativeText = "“\(iso.lastPathComponent)” — \(source) " +
      "Put a blank CD in the drive, then burn it."
    alert.addButton(withTitle: "Burn Disc")
    alert.addButton(withTitle: "Not Now")
    if alert.runModal() == .alertFirstButtonReturn {
      burn(iso, onState: onState)
    } else {
      onDeclined?()
    }
  }

  static func burn(_ iso: URL,
                   onState: @escaping (BurnState) -> Void) {
    // drutil drives the same DiscRecording engine as Burn.app,
    // whose burns are the proven ones on the D-NE1.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
    proc.arguments = ["burn", iso.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    proc.terminationHandler = { p in
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                       encoding: .utf8) ?? ""
      DispatchQueue.main.async {
        onState(.finished(success: p.terminationStatus == 0))
        let done = NSAlert()
        done.messageText = p.terminationStatus == 0 ? "Burn finished" : "Burn failed"
        done.informativeText = out.isEmpty
          ? "drutil reported nothing (exit \(p.terminationStatus))." : out
        done.addButton(withTitle: "OK")
        done.runModal()
      }
    }
    do {
      onState(.started)
      try proc.run()
    } catch {
      onState(.finished(success: false))
      let fail = NSAlert()
      fail.messageText = "Could not start the burn"
      fail.informativeText = "\(error)"
      fail.addButton(withTitle: "OK")
      fail.runModal()
    }
  }
}
