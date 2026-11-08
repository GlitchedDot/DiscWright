// Models.swift — the app's list models.
//
// Deliberately NOT the core's DiscTrack/DiscGroup (those are the
// authoring pipeline's input structs, built from encoded frames in
// Step 3). These are the UI's working copies: a track knows its
// source file and its estimated sample count (from the audio
// file's duration, exactly like the web app's tracks), and an
// imported track knows it is read-only.

import Foundation

struct TrackItem: Identifiable {
  let id = UUID()
  /// Display/file name (the web app's track.name).
  var name: String
  var title: String
  var artist: String
  var album: String
  /// Source audio file; nil for imported tracks.
  var fileURL: URL?
  /// Estimated samples at 44.1 kHz (duration * 44100), the web
  /// app's capacity basis. 0 = unknown yet / unreadable.
  var samples: Int
  /// Non-nil when the file could not be read/decoded (the web
  /// app shows "⚠ <error>" in the duration cell).
  var error: String?
  /// Imported tracks are read-only: no edits, no row buttons.
  var imported: Bool
  /// The .ATP size on the disc, for imported tracks.
  var size: Int
}

struct GroupItem: Identifiable {
  let id = UUID()
  var name: String
  var imported: Bool = false
  var tracks: [TrackItem] = []
}

/// Format a sample count the way the web app's fmtDur does:
/// "…" for 0, otherwise m:ss of round(samples / 44100).
func fmtDuration(samples: Int) -> String {
  if samples == 0 { return "…" }
  let s = Int((Double(samples) / 44100).rounded())
  return "\(s / 60):\(String(format: "%02d", s % 60))"
}

/// MB the way the web app prints it: (bytes / 1e6) rounded.
func mbString(_ bytes: Int) -> String {
  "\(Int((Double(bytes) / 1e6).rounded()))"
}
