// Store.swift — the app's state and every list operation,
// mirroring the web app's semantics (app.js):
//  - groups are named, removable (their tracks move to the
//    previous group, or the next one for the first group),
//  - tracks move up/down, between groups, and by drag (onMove),
//  - bare files land in the LAST group; a picked folder becomes
//    a group named after it (created or reused by name), walked
//    up to 2 folders deep, audio only, in path order,
//  - capacity = isoSectorCount(estimatedSizes) + the session
//    overhead, against the chosen blank,
//  - importing an ISO replaces the list with that disc's own
//    groups/tracks, read-only, and Burn Disc burns that file,
//  - Burn Disc on a NEW list (Step 3) encodes every track in
//    parallel (EncodeService, capped by the user's Encode
//    workers setting), authors the ISO with the core's
//    buildDisc, saves it to ~/Downloads, and offers the burn.

import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// An imported disc: what the capacity line and the burner need.
struct ImportedDisc {
  var name: String
  var size: Int
  var url: URL
}

@MainActor
final class DiscStore: ObservableObject {
  @Published var groups: [GroupItem] = [GroupItem(name: "Group 1")]
  @Published var imported: ImportedDisc? = nil
  /// Picker selection: a BLANKS sector count, or -1 for Custom.
  @Published var blankSelection: Int = 360000
  @Published var customBlankText: String = "360000"
  @Published var logLines: [String] = []
  /// True while drutil runs (the disc stage spins the laser
  /// and Burn Disc stays disabled meanwhile).
  @Published var isBurning: Bool = false
  /// The disc stage's status line — the web app's #stageStatus.
  /// The idle text is the web's exact idle line.
  @Published var stageStatus: String = "Please select a type of disc."
  /// Encode progress for the disc stage's laser: nil when no
  /// new-disc build is in flight; 0…0.85 while encoding
  /// (0.85 × tracks done), then 1.0 through authoring/burn.
  @Published var encodeProgress: Double? = nil
  /// True while a new-disc encode+author run is in flight.
  @Published var isEncoding: Bool = false
  /// The user's encode-parallelism choice (the brief's explicit
  /// requirement): how many tracks encode at once. Persisted
  /// in UserDefaults; clamped to 1…activeProcessorCount.
  @Published var encodeWorkers: Int = DiscStore.defaultWorkers {
    didSet {
      UserDefaults.standard.set(encodeWorkers, forKey: "encodeWorkers")
    }
  }
  /// The live encode run's cancellation handle, if any.
  private var encodeHandle: EncodeHandle? = nil

  /// This machine's thread count — the workers control's cap.
  static var maxWorkers: Int {
    max(1, ProcessInfo.processInfo.activeProcessorCount)
  }

  /// The web app's pool rule: cores − 1, at least 1, at most 8.
  static var defaultWorkers: Int {
    min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1), 8)
  }

  /// The blank picker's fixed entries, in the web app's order.
  static let blankOptions = [360000, 333000, 108000, 94500, 405000, 445500]
  static let audioExts: Set<String> =
    ["mp3", "m4a", "wav", "flac", "ogg", "aif", "aiff"]

  init() {
    // A previously chosen worker count wins over the default.
    let saved = UserDefaults.standard.integer(forKey: "encodeWorkers")
    if saved >= 1 {
      encodeWorkers = min(saved, Self.maxWorkers)
    }
    log("Ready.")
    if EncodeService.encoderURL() == nil {
      log("Warning: atracdenc is missing from the app bundle — " +
          "new discs cannot be encoded (Import ISO + burn still works).")
    }
  }

  // ---- log ----

  func log(_ line: String) {
    logLines.append(line)
    if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
  }

  // ---- derived state ----

  var allTracks: [TrackItem] { groups.flatMap { $0.tracks } }

  var blankSectors: Int {
    blankSelection == -1 ? (Int(customBlankText) ?? 360000) : blankSelection
  }

  /// The web app's estimatedSizes(): per-file byte sizes the ISO
  /// planner would see. Frames per track come from the duration
  /// estimate: floor(samples / 2048) + 1, 376 bytes each, + 1120.
  func estimatedSizes() -> [String: Int] {
    var sizes: [String: Int] = [:]
    let tracks = allTracks
    for (i, t) in tracks.enumerated() {
      let frames = t.samples != 0 ? t.samples / 2048 + 1 : 0
      sizes["/HIFI/TRK" + Self.hex5(i + 1) + ".ATP"] = frames * 376 + 1120
    }
    sizes["/TRACK.NDB"] = writeNdb(tracks.map { $0.title }).count
    sizes["/ALBUM.NDB"] = writeNdb(tracks.map { $0.album }).count
    sizes["/ARTIST.NDB"] = writeNdb(tracks.map { $0.artist }).count
    sizes["/GROUP.NDB"] =
      writeNdb(groups.filter { !$0.tracks.isEmpty }.map { $0.name }).count
    sizes["/PLLIST.NDB"] = 256
    sizes["/TOC00000.STI"] = 0x900 + 16 * tracks.count
    sizes["/TOC00001.STI"] = 2176
    sizes["/0001000E.STK"] = 172
    return sizes
  }

  var usedSectors: Int {
    isoSectorCount(estimatedSizes()) + SESSION_OVERHEAD_SECTORS
  }

  var capacityOver: Bool {
    imported == nil && usedSectors > blankSectors
  }

  var capacityFraction: Double {
    if let imp = imported {
      let capBytes = Double(blankSectors) * Double(SECTOR)
      return capBytes > 0 ? min(1, Double(imp.size) / capBytes) : 1
    }
    return blankSectors > 0
      ? min(1, Double(usedSectors) / Double(blankSectors)) : 1
  }

  var capacityText: String {
    if let imp = imported {
      let n = allTracks.count
      return "Imported disc “\(imp.name)” — \(n) track\(n == 1 ? "" : "s") · " +
        "\(mbString(imp.size)) MB (the ISO itself)"
    }
    let n = allTracks.count
    return "\(n) track\(n == 1 ? "" : "s") · " +
      "\(mbString(usedSectors * SECTOR)) MB of " +
      "\(mbString(blankSectors * SECTOR)) MB" +
      (capacityOver ? " — over capacity!" : "")
  }

  /// TRK + hex(5, uppercase), the web app's track file naming.
  private static func hex5(_ n: Int) -> String {
    var h = String(n, radix: 16, uppercase: true)
    while h.count < 5 { h = "0" + h }
    return h
  }

  // ---- group operations ----

  func addGroup() {
    guard imported == nil else { return }
    groups.append(GroupItem(name: "Group \(groups.count + 1)"))
  }

  /// Remove a group; its tracks move to the previous group (the
  /// next one when removing the first), as in the web app.
  func removeGroup(id: UUID) {
    guard groups.count > 1,
          let gi = groups.firstIndex(where: { $0.id == id })
    else { return }
    let dest = gi == 0 ? 1 : gi - 1
    let moved = groups[gi].tracks
    groups[dest].tracks.append(contentsOf: moved)
    groups.remove(at: gi)
  }

  // ---- track operations ----

  func removeTrack(groupID: UUID, trackID: UUID) {
    guard let gi = groups.firstIndex(where: { $0.id == groupID }),
          let ti = groups[gi].tracks.firstIndex(where: { $0.id == trackID })
    else { return }
    groups[gi].tracks.remove(at: ti)
  }

  func moveTrackUp(groupID: UUID, trackID: UUID) {
    moveTrack(groupID: groupID, trackID: trackID, by: -1)
  }

  func moveTrackDown(groupID: UUID, trackID: UUID) {
    moveTrack(groupID: groupID, trackID: trackID, by: 1)
  }

  private func moveTrack(groupID: UUID, trackID: UUID, by delta: Int) {
    guard let gi = groups.firstIndex(where: { $0.id == groupID }),
          let ti = groups[gi].tracks.firstIndex(where: { $0.id == trackID })
    else { return }
    let to = ti + delta
    guard to >= 0 && to < groups[gi].tracks.count else { return }
    groups[gi].tracks.swapAt(ti, to)
  }

  /// Move a track to the END of another group (the web app's
  /// move-to-group select does exactly this).
  func moveTrackToGroup(trackID: UUID, from groupID: UUID, to destID: UUID) {
    guard groupID != destID,
          let gi = groups.firstIndex(where: { $0.id == groupID }),
          let ti = groups[gi].tracks.firstIndex(where: { $0.id == trackID }),
          let di = groups.firstIndex(where: { $0.id == destID })
    else { return }
    let track = groups[gi].tracks.remove(at: ti)
    groups[di].tracks.append(track)
  }

  /// List onMove (drag reorder within a group), with the standard
  /// IndexSet semantics implemented by hand.
  func moveTracks(groupID: UUID, fromOffsets: IndexSet, toOffset: Int) {
    guard let gi = groups.firstIndex(where: { $0.id == groupID })
    else { return }
    var tracks = groups[gi].tracks
    let moving = fromOffsets.sorted().map { tracks[$0] }
    for i in fromOffsets.sorted().reversed() { tracks.remove(at: i) }
    let dest = toOffset - fromOffsets.filter { $0 < toOffset }.count
    tracks.insert(contentsOf: moving, at: dest)
    groups[gi].tracks = tracks
  }

  // ---- adding files ----

  func addFilesClicked() {
    guard imported == nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [UTType.audio]
    panel.message = "Choose audio files — they join the last group."
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    let target = groups.last?.id
    Task { await self.addFiles(urls, toGroupID: target) }
  }

  func addFolderClicked() {
    guard imported == nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a folder — it becomes a group named after it."
    guard panel.runModal() == .OK, let root = panel.url else { return }
    Task { await self.addFolder(root) }
  }

  func addFiles(_ urls: [URL], toGroupID: UUID?) async {
    for url in urls { await addFile(url, toGroupID: toGroupID) }
  }

  /// One file: tags first, then the duration estimate, then it
  /// joins the list (the web app's order, minus its placeholder
  /// row: results here appear once known).
  func addFile(_ url: URL, toGroupID: UUID?) async {
    let targetID = toGroupID ?? groups.last?.id
    guard let targetID,
          let gi = groups.firstIndex(where: { $0.id == targetID })
    else { return }
    var item = TrackItem(name: url.lastPathComponent, title: "",
                         artist: "", album: "", fileURL: url,
                         samples: 0, error: nil, imported: false, size: 0)
    do {
      let tags = try TagReader.tags(forFileAt: url)
      item.title = tags.title
      item.artist = tags.artist
      item.album = tags.album
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration)
      let secs = CMTimeGetSeconds(duration)
      if secs.isFinite && secs > 0 {
        // JS: Math.round(duration * 44100).
        item.samples = Int((secs * 44100).rounded())
      } else {
        item.error = "could not decode this file"
      }
    } catch {
      item.error = "could not decode this file"
    }
    groups[gi].tracks.append(item)
  }

  /// A picked folder: collect audio (≤ 2 folders deep, path
  /// order), then add it all to a group named after the folder —
  /// created on first sight, reused if the name already exists.
  func addFolder(_ root: URL) async {
    let (files, skipped) = Self.collectFolder(root)
    if !files.isEmpty || skipped > 0 {
      log("Folder scan: added \(files.count) audio " +
          "file\(files.count == 1 ? "" : "s")" +
          (skipped > 0
            ? ", skipped \(skipped) (not audio, or deeper than 2 folders)"
            : "") + ".")
    }
    guard !files.isEmpty else { return }
    let name = root.lastPathComponent
    let gi: Int
    if let existing = groups.firstIndex(where: { $0.name == name }) {
      gi = existing
    } else {
      groups.append(GroupItem(name: name))
      gi = groups.count - 1
    }
    let gid = groups[gi].id
    for f in files { await addFile(f, toGroupID: gid) }
    let count = groups[gi].tracks.count
    log("Folder “\(name)” became a group (\(count) track\(count == 1 ? "" : "s")).")
  }

  /// Enumerate a folder the way the web app's intake does:
  /// regular files only, hidden files skipped; a file counts as
  /// "deep" by the folders between the picked root and it (the
  /// root's own files are depth 0; depth ≤ 2 is collected).
  private static func collectFolder(_ root: URL)
    -> (files: [URL], skipped: Int) {
    var files: [URL] = []
    var skipped = 0
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                 options: [.skipsHiddenFiles])
    else { return ([], 0) }
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    for case let url as URL in en {
      let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
        .isRegularFile ?? false
      guard isFile else { continue }
      let rel = String(url.path.dropFirst(prefix.count))
      let depth = rel.split(separator: "/").count - 1
      if depth <= 2 && audioExts.contains(url.pathExtension.lowercased()) {
        files.append(url)
      } else {
        skipped += 1
      }
    }
    files.sort {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
    return (files, skipped)
  }

  // ---- import ISO ----

  func importIsoClicked() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let isoType = UTType(filenameExtension: "iso") {
      panel.allowedContentTypes = [isoType]
    }
    panel.message = "Choose an ATRAC CD ISO — WrightDisc's or SonicStage's."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let disc = try parseAtracDisc([UInt8](data))
      groups = disc.groups.map { g in
        GroupItem(name: g.name, imported: true, tracks: g.tracks.map { t in
          TrackItem(name: t.title.isEmpty ? "Track" : t.title,
                    title: t.title, artist: t.artist, album: t.album,
                    fileURL: nil, samples: t.seconds * 44100,
                    error: nil, imported: true, size: t.size)
        })
      }
      imported = ImportedDisc(name: url.lastPathComponent,
                              size: data.count, url: url)
      log("Imported “\(url.lastPathComponent)”: \(disc.trackCount) " +
          "track\(disc.trackCount == 1 ? "" : "s") in \(disc.groups.count) " +
          "group\(disc.groups.count == 1 ? "" : "s"), \(mbString(data.count)) MB.")
      log("This disc is already authored — its tracks are read-only. " +
          "Clear the imported disc to start a new one.")
    } catch {
      log("Import failed: \(error)")
    }
  }

  func clearImport() {
    imported = nil
    groups = [GroupItem(name: "Group 1")]
    stageStatus = "Please select a type of disc."
    log("Imported disc cleared.")
  }

  // ---- burn ----

  /// Enabled when there is something to burn — an imported ISO,
  /// or a new list with at least one track that fits the blank —
  /// and nothing is already burning or encoding.
  var burnEnabled: Bool {
    if isBurning || isEncoding { return false }
    if imported != nil { return true }
    return !allTracks.isEmpty && !capacityOver
  }

  func burnDiscClicked() {
    if let imp = imported {
      BurnService.offerBurn(iso: imp.url, source: "You imported this ISO.") {
        [weak self] state in
        guard let self else { return }
        switch state {
        case .started:
          self.isBurning = true
          self.stageStatus = "Writing — burning the disc…"
        case .finished(let success):
          self.isBurning = false
          self.stageStatus = success
            ? "Your disc is ready. 💿"
            : "Something went wrong — see the log below."
        }
      }
      return
    }
    startEncodeAndBuild()
  }

  /// Cancel the in-flight encode (the queue drops pending jobs,
  /// running atracdenc processes are terminated).
  func cancelEncode() {
    encodeHandle?.cancel()
  }

  /// NEW disc, end to end: encode every track (parallel, capped
  /// by encodeWorkers) -> buildDisc -> ~/Downloads/atrac-disc.iso
  /// -> offer the burn. Any track failure aborts the whole build:
  /// no ISO, and the log names the track and the reason.
  private func startEncodeAndBuild() {
    let tracks = allTracks
    guard !tracks.isEmpty, !capacityOver, !isBurning, !isEncoding
    else { return }
    if let bad = tracks.first(where: { $0.error != nil }) {
      log("Cannot build: “\(bad.name)” could not be read when it was added.")
      stageStatus = "Something went wrong — see the log below."
      return
    }
    if let missing = tracks.first(where: { $0.fileURL == nil }) {
      log("Cannot build: “\(missing.name)” has no source file.")
      stageStatus = "Something went wrong — see the log below."
      return
    }
    guard EncodeService.encoderURL() != nil else {
      log("Cannot build: atracdenc is missing from the app bundle.")
      stageStatus = "Something went wrong — see the log below."
      return
    }

    // Snapshot the playlist (order is sacred) and the groups as
    // 1-based inclusive ranges over it, skipping empty groups.
    var jobs: [EncodeJob] = []
    var meta: [(title: String, artist: String, album: String)] = []
    var discGroups: [DiscGroup] = []
    var cursor = 1
    for g in groups where !g.tracks.isEmpty {
      let first = cursor
      for t in g.tracks {
        jobs.append(EncodeJob(index: meta.count, title: t.title,
                              source: t.fileURL!))
        meta.append((title: t.title, artist: t.artist, album: t.album))
        cursor += 1
      }
      discGroups.append(DiscGroup(name: g.name, first: first,
                                  last: cursor - 1))
    }
    let total = jobs.count
    let capacity = blankSectors
    let workers = encodeWorkers
    let handle = EncodeHandle()
    encodeHandle = handle
    isEncoding = true
    isBurning = true // the stage spins + draws the laser throughout
    encodeProgress = 0
    stageStatus = "Writing — 0 of \(total) tracks encoded"
    log("Encoding \(total) track\(total == 1 ? "" : "s") " +
        "with \(workers) worker\(workers == 1 ? "" : "s")…")

    Task {
      do {
        let frames = try await EncodeService.encodeAll(
          jobs: jobs, workers: workers, handle: handle
        ) { done, totalCount, title in
          Task { @MainActor in
            guard self.encodeHandle === handle else { return }
            self.encodeProgress = 0.85 * Double(done) / Double(totalCount)
            self.stageStatus =
              "Writing — \(done) of \(totalCount) tracks encoded"
            self.log("Encoded \(done)/\(totalCount): \(title)")
          }
        }
        if handle.isCancelled { throw EncodeFailure.cancelled }

        // Author with the proven core: fresh random DiscID and
        // one IV per track, as the web app generates them.
        self.stageStatus = "Writing — authoring the disc…"
        let discTracks = (0..<total).map { i in
          DiscTrack(frames: frames[i], title: meta[i].title,
                    artist: meta[i].artist, album: meta[i].album)
        }
        let discId = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let ivs = (0..<total).map { _ in
          (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        let result = try buildDisc(tracks: discTracks,
                                   groups: discGroups,
                                   discId: discId, ivs: ivs,
                                   capacitySectors: capacity)
        let downloads = FileManager.default
          .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let isoURL = downloads.appendingPathComponent("atrac-disc.iso")
        try Data(result.iso).write(to: isoURL)
        self.log("Built \(isoURL.path) — \(result.stats.trackCount) tracks, " +
                 "\(mbString(result.iso.count)) MB, " +
                 "\(result.stats.isoSectors) sectors.")
        self.encodeProgress = 1.0
        self.isEncoding = false
        self.encodeHandle = nil
        self.stageStatus = "Your disc is ready. 💿"
        BurnService.offerBurn(
          iso: isoURL,
          source: "WrightDisc just built this ISO — " +
            "\(total) track\(total == 1 ? "" : "s")."
        ) { [weak self] state in
          guard let self else { return }
          switch state {
          case .started:
            self.isBurning = true
            self.stageStatus = "Writing — burning the disc…"
          case .finished(let success):
            self.isBurning = false
            self.encodeProgress = nil
            self.stageStatus = success
              ? "Your disc is ready. 💿"
              : "Something went wrong — see the log below."
          }
        } onDeclined: { [weak self] in
          guard let self else { return }
          self.isBurning = false
          self.encodeProgress = nil
          self.stageStatus = "Your disc is ready. 💿"
          self.log("ISO kept at \(isoURL.path) — burn it any time.")
        }
      } catch EncodeFailure.cancelled {
        self.isEncoding = false
        self.isBurning = false
        self.encodeProgress = nil
        self.encodeHandle = nil
        self.stageStatus = "Please select a type of disc."
        self.log("Encoding cancelled — no disc was built.")
      } catch {
        self.isEncoding = false
        self.isBurning = false
        self.encodeProgress = nil
        self.encodeHandle = nil
        self.stageStatus = "Something went wrong — see the log below."
        self.log("Build failed: \(error.localizedDescription)")
      }
    }
  }
}
