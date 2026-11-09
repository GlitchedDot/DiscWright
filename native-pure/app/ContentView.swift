// ContentView.swift — the whole window, restyled (Step 2.5)
// in DiscWright's own palette: the indigo SonicStage backdrop
// with two lavender panes, as the web app's Create a CD lays
// them out — library on the left; on the right the disc stage
// over the blank/capacity controls and the action row (Burn
// Disc BESIDE Import ISO, per the user's explicit layout
// requirement); the log across the bottom. The window itself
// stays a real Mac window — only the colors and the stage are
// hers. All controls are the same native controls with the
// same bindings and behavior as Step 2.

import SwiftUI

struct ContentView: View {
  @StateObject private var store = DiscStore()
  /// Step 3: the app follows the SYSTEM appearance — both are
  /// designed (see Palette in Theme.swift). Light is the
  /// approved Step 2.5 look; dark is DiscWright at night.
  @Environment(\.colorScheme) private var colorScheme
  private var pal: Palette { Palette.of(colorScheme) }

  var body: some View {
    VStack(spacing: 10) {
      headerBand
      HStack(alignment: .top, spacing: 12) {
        libraryPane
        discPane
      }
      .frame(maxHeight: .infinity)
      logView
    }
    .padding(12)
    .frame(minWidth: 980, minHeight: 660)
    .background(backdrop)
    .environmentObject(store)
  }

  /// The indigo client area with two soft ribbon bands across
  /// it — a native echo of the ribbon wallpapers the web window
  /// floats over. Kept quiet: the panes sit on top.
  private var backdrop: some View {
    ZStack {
      Theme.clientGradient
      GeometryReader { geo in
        let w = geo.size.width
        ZStack {
          RoundedRectangle(cornerRadius: 90)
            .fill(Color.white.opacity(0.07))
            .frame(width: w * 1.25, height: 130)
            .rotationEffect(.degrees(-16))
            .offset(x: -w * 0.12, y: -40)
          RoundedRectangle(cornerRadius: 110)
            .fill(Theme.ssLav.opacity(0.13))
            .frame(width: w * 1.3, height: 170)
            .rotationEffect(.degrees(-16))
            .offset(x: w * 0.10, y: 150)
        }
      }
    }
  }

  // ---- header band: wordmark on the SonicStage purple ----

  private var headerBand: some View {
    HStack(spacing: 12) {
      discGlyph
      VStack(alignment: .leading, spacing: 1) {
        Text("WrightDisc")
          .font(.title2.bold())
          .foregroundColor(.white)
        Text("ATRAC3+ CD ISO maker")
          .font(.callout)
          .foregroundColor(Theme.subtitleOnBlue)
      }
      Spacer()
      // The web's one visible mode tab, as a pill.
      Text("Create a CD")
        .font(.callout.bold())
        .foregroundColor(Theme.modeTabOnText)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Theme.modeTabOnGradient)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.deepBorder, lineWidth: 2))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Theme.headerGradient)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6)
               .stroke(Theme.deepBorder, lineWidth: 1))
  }

  /// A tiny silver disc with a dark hub — the web titlebar's
  /// .app-icon (conic silver ring, #123a82 hub), as a view.
  private var discGlyph: some View {
    ZStack {
      Circle()
        .fill(AngularGradient(
          gradient: Gradient(colors: [Color(hex: 0xdcecff), .white,
                                      Color(hex: 0x8db6e8),
                                      Color(hex: 0xf0f7ff),
                                      Color(hex: 0xdcecff)]),
          center: .center,
          startAngle: .degrees(20), endAngle: .degrees(380)))
      Circle()
        .fill(Theme.glyphHub)
        .frame(width: 6, height: 6)
    }
    .frame(width: 30, height: 30)
    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
  }

  // ---- panes ----

  private func paneHeader(_ title: String, trailing: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.headline)
        .foregroundColor(pal.paneText)
      Spacer()
      Text(trailing)
        .font(.callout)
        .foregroundColor(pal.secondaryText)
    }
  }

  private var libraryPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      paneHeader("My Library", trailing: libInfoText)
      intakeBar
      trackList
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(pal.pane)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .overlay(RoundedRectangle(cornerRadius: 3)
               .stroke(Theme.deepBorder, lineWidth: 1))
    .shadow(color: .black.opacity(0.25), radius: 7, y: 2)
  }

  private var discPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      paneHeader("ATRAC CD", trailing: "Drive: ISO image")
      DiscStageView()
      Divider()
      blankRow
      capacityBar
      workersRow
      actionRow
    }
    .padding(10)
    .frame(width: 400)
    .frame(maxHeight: .infinity)
    .background(pal.pane)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .overlay(RoundedRectangle(cornerRadius: 3)
               .stroke(Theme.deepBorder, lineWidth: 1))
    .shadow(color: .black.opacity(0.25), radius: 7, y: 2)
  }

  private var libInfoText: String {
    let n = store.allTracks.count
    if n == 0 { return "" }
    let g = store.groups.filter { !$0.tracks.isEmpty }.count
    return "\(g) group\(g == 1 ? "" : "s")"
  }

  // ---- controls: intake (library side) ----

  private var intakeBar: some View {
    HStack(spacing: 8) {
      Button("Add Files…") { store.addFilesClicked() }
      Button("Add Folder…") { store.addFolderClicked() }
      Button("Add Group") { store.addGroup() }
      Spacer()
    }
    // While a disc is imported the list is that disc: no intake,
    // no group edits — the same lock the web app applies.
    .disabled(store.imported != nil)
  }

  // ---- blank picker (disc side, as in the web's controls) ----

  private var blankRow: some View {
    HStack(spacing: 8) {
      Text("Blank:")
        .foregroundColor(pal.paneText)
      Picker("Blank", selection: $store.blankSelection) {
        ForEach(DiscStore.blankOptions, id: \.self) { sectors in
          Text(BLANKS[sectors] ?? "\(sectors) sectors").tag(sectors)
        }
        Text("Custom…").tag(-1)
      }
      .labelsHidden()
      .frame(width: 200)
      if store.blankSelection == -1 {
        TextField("sectors", text: $store.customBlankText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 84)
        Text("sectors")
          .foregroundColor(pal.secondaryText)
      }
    }
    .disabled(store.imported != nil)
  }

  // ---- capacity: her indigo meter, red only when over ----

  private var capacityBar: some View {
    HStack(spacing: 8) {
      CapacityMeter(fraction: store.capacityFraction,
                    over: store.capacityOver,
                    track: pal.meterTrack)
        .frame(height: 14)
      Text(store.capacityText)
        .font(.callout)
        .foregroundColor(store.capacityOver ? Theme.bad : pal.paneText)
    }
  }

  // ---- encode workers: the user's own parallelism choice ----

  /// Step 3, at the user's explicit request: how many tracks
  /// encode at once, 1…this machine's thread count, remembered
  /// between launches (UserDefaults "encodeWorkers" — see
  /// DiscStore). Sits under the capacity bar, disc side.
  private var workersRow: some View {
    HStack(spacing: 8) {
      Text("Encode workers:")
        .foregroundColor(pal.paneText)
      Stepper(value: $store.encodeWorkers, in: 1...DiscStore.maxWorkers) {
        Text("\(store.encodeWorkers) of \(DiscStore.maxWorkers) threads")
          .foregroundColor(pal.secondaryText)
      }
      Spacer()
    }
    .disabled(store.isEncoding || store.imported != nil)
  }

  // ---- the list ----

  private var trackList: some View {
    List {
      ForEach($store.groups) { $group in
        Section {
          ForEach($group.tracks) { $track in
            TrackRow(track: $track,
                     groupID: $group.wrappedValue.id,
                     isFirst: $group.wrappedValue.tracks.first?.id
                       == $track.wrappedValue.id,
                     isLast: $group.wrappedValue.tracks.last?.id
                       == $track.wrappedValue.id,
                     groupCount: store.groups.count)
              .listRowBackground(pal.rowBackground)
              .listRowSeparatorTint(pal.rowSeparator)
          }
          .onMove(perform: $group.wrappedValue.imported ? nil
                    : { offsets, dest in
                        store.moveTracks(
                          groupID: $group.wrappedValue.id,
                          fromOffsets: offsets, toOffset: dest)
                      })
        } header: {
          HStack(spacing: 8) {
            Text("Group:")
              .font(.headline)
              .foregroundColor(pal.cardHeaderText)
            TextField("Group name", text: $group.name)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 320)
              .disabled($group.wrappedValue.imported)
            Spacer()
            if store.groups.count > 1 && !$group.wrappedValue.imported {
              Button("Remove group") {
                store.removeGroup(id: $group.wrappedValue.id)
              }
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
          .background(pal.cardHeaderGradient)
          .overlay(Rectangle().fill(pal.cardHeaderBorder)
                     .frame(height: 1), alignment: .bottom)
        }
      }
    }
    .listStyle(.inset(alternatesRowBackgrounds: true))
    .scrollContentBackground(.hidden)
  }

  // ---- actions: Burn Disc beside Import ISO ----

  private var actionRow: some View {
    HStack(spacing: 12) {
      Button(action: { store.burnDiscClicked() }) {
        Text("Burn Disc")
          .font(.title3.bold())
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
      }
      .buttonStyle(.borderedProminent)
      .tint(Theme.ssBlue2)
      .controlSize(.large)
      .disabled(!store.burnEnabled)
      Button("Import ISO…") { store.importIsoClicked() }
        .controlSize(.large)
      if store.imported != nil {
        Button("✕ Clear imported disc") { store.clearImport() }
      }
      if store.isEncoding {
        Button("Cancel") { store.cancelEncode() }
      }
      Spacer()
      if store.imported == nil && !store.isEncoding {
        Text("Burn Disc encodes the list, builds the ISO in " +
             "Downloads, then offers the burn.")
          .font(.caption)
          .foregroundColor(pal.smallText)
      }
    }
  }

  // ---- log: white pane, #9aa1d6 border, monospaced ----

  private var logView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(store.logLines.enumerated()), id: \.offset) { i, line in
            Text(line)
              .font(.system(size: 12, design: .monospaced))
              .foregroundColor(pal.logText)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(i)
          }
        }
        .padding(6)
      }
      .background(pal.logBackground)
      .clipShape(RoundedRectangle(cornerRadius: 2))
      .overlay(RoundedRectangle(cornerRadius: 2)
                 .stroke(Theme.logBorder, lineWidth: 1))
      .frame(height: 110)
      .onChange(of: store.logLines.count) { count in
        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
      }
    }
  }
}

/// The web's #meter: a white track with a grey border and the
/// indigo fill (#7d84e8 -> #3a2a9e), switching to the red
/// gradient only when the disc is over capacity. The track is
/// the palette's (white in light, deep navy at night); the fill
/// gradients are appearance-neutral and stay in Theme.
private struct CapacityMeter: View {
  let fraction: Double
  let over: Bool
  let track: Color

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Rectangle().fill(track)
        Rectangle()
          .fill(over ? Theme.meterFullGradient : Theme.meterGradient)
          .frame(width: CGFloat(max(0, min(1, fraction)))
                   * geo.size.width)
      }
      .overlay(Rectangle().stroke(Theme.meterBorder, lineWidth: 1))
    }
  }
}
