// TrackRow.swift — one track in the list: editable
// Title/Artist/Album fields, the duration (or the ⚠ error), and
// the row buttons (up / down / move-to-group menu / remove).
// Imported tracks render the same fields disabled and no buttons
// at all — an authored disc is read-only.

import SwiftUI

struct TrackRow: View {
  @Binding var track: TrackItem
  let groupID: UUID
  let isFirst: Bool
  let isLast: Bool
  let groupCount: Int
  @EnvironmentObject var store: DiscStore
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 6) {
      TextField("Title", text: $track.title)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 150)
        .disabled(track.imported)
      TextField("Artist", text: $track.artist)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 110)
        .disabled(track.imported)
      TextField("Album", text: $track.album)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 110)
        .disabled(track.imported)

      if let error = track.error {
        Text("⚠ \(error)")
          .font(.caption)
          .foregroundColor(Theme.bad)
          .frame(minWidth: 54, alignment: .trailing)
      } else {
        Text(fmtDuration(samples: track.samples))
          .font(.system(.body, design: .monospaced))
          .foregroundColor(Palette.of(colorScheme).durText)
          .frame(width: 54, alignment: .trailing)
      }

      if !track.imported {
        HStack(spacing: 2) {
          Button("↑") {
            store.moveTrackUp(groupID: groupID, trackID: track.id)
          }
          .disabled(isFirst)
          .help("Move up")
          Button("↓") {
            store.moveTrackDown(groupID: groupID, trackID: track.id)
          }
          .disabled(isLast)
          .help("Move down")
          if groupCount > 1 {
            Menu("Move") {
              ForEach(store.groups.filter { $0.id != groupID }) { g in
                Button(g.name) {
                  store.moveTrackToGroup(trackID: track.id,
                                         from: groupID, to: g.id)
                }
              }
            }
            .help("Move to another group")
          }
          Button("✕") {
            store.removeTrack(groupID: groupID, trackID: track.id)
          }
          .help("Remove track")
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
    }
    .padding(.vertical, 1)
  }
}
