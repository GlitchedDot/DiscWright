// Author.swift — mirror of author.js: disc orchestration with
// the hardware-proven recipe built in. Track list in -> complete
// file tree -> capacity-checked ISO out.
import Foundation

let ATP_OVERHEAD = 1120 // 1024 ID3 + 96 secure header

/// A track to author (author.js's track objects).
struct DiscTrack {
  var frames: [UInt8]
  var title: String
  var artist: String
  var album: String
  var frameSize: Int? = nil // default FRAME_SIZE (376)
}

/// A group (author.js's groups): 1-based inclusive track range.
struct DiscGroup {
  var name: String
  var first: Int
  var last: Int
}

/// buildDisc's timestamp input: {ms, tzOffsetMinutes}.
struct DiscTimestamp {
  var ms: Int64
  var tzOffsetMinutes: Int
}

/// buildDisc's stats.
struct DiscStats {
  var isoBytes: Int
  var isoSectors: Int
  var estimatedSectors: Int
  var capacitySectors: Int
  var trackCount: Int
}

/// buildDisc's result: {iso, files, stats}.
struct BuildDiscResult {
  var iso: [UInt8]
  var files: [String: [UInt8]]
  var stats: DiscStats
}

/// trackFilename(number): "TRK" + hex(5, uppercase) + ".ATP".
func trackFilename(_ number: Int) throws -> String {
  if !(number >= 1 && number <= 0xfffff) {
    throw DiscCoreError.message("track number out of range")
  }
  var h = String(number, radix: 16, uppercase: true)
  while h.count < 5 { h = "0" + h }
  return "TRK" + h + ".ATP"
}

/// buildDisc: mirrors author.js's option handling one for one —
/// groups default to a single "New Group" over all tracks,
/// capacitySectors defaults to 360000, timestamp may be nil
/// (the ISO writer then stamps the current time, as in JS).
func buildDisc(tracks: [DiscTrack],
               groups: [DiscGroup]? = nil,
               discId: [UInt8],
               ivs: [[UInt8]],
               capacitySectors: Int = 360000,
               timestamp: DiscTimestamp? = nil) throws -> BuildDiscResult {
  if tracks.isEmpty {
    throw DiscCoreError.message("no tracks")
  }
  let groups = groups ?? [DiscGroup(name: "New Group", first: 1, last: tracks.count)]
  if discId.count != 16 {
    throw DiscCoreError.message("discId must be 16 bytes")
  }
  if ivs.count != tracks.count {
    throw DiscCoreError.message("one IV per track required")
  }

  var files: [String: [UInt8]] = [:]
  var frameCounts: [Int] = []
  for (i, t) in tracks.enumerated() {
    let frameSize = t.frameSize ?? FRAME_SIZE
    if t.frames.count % frameSize != 0 {
      throw DiscCoreError.message(
        "track \(i + 1): payload is not a whole number of frames")
    }
    let frameCount = t.frames.count / frameSize
    let header = headerToBytes(SecureHeaderFields(
      frameCount: frameCount,
      blockSeed: try blockSeed(discId: discId, bindIndex: i),
      initVector: ivs[i],
      connum: CONNUM,
      trackSlot: TRACK_SLOT,
      mgd: MGD))
    var atp = [UInt8](repeating: 0, count: ATP_OVERHEAD + t.frames.count)
    putBytes(&atp, try writeTag(title: t.title, artist: t.artist,
                                album: t.album), at: 0)
    putBytes(&atp, header, at: 1024)
    putBytes(&atp, try encryptPayload(frames: t.frames, iv: ivs[i]),
             at: ATP_OVERHEAD)
    files["/HIFI/" + (try trackFilename(i + 1))] = atp
    frameCounts.append(frameCount)
  }

  files["/TRACK.NDB"] = writeNdb(tracks.map { $0.title })
  files["/ALBUM.NDB"] = writeNdb(tracks.map { $0.album })
  files["/ARTIST.NDB"] = writeNdb(tracks.map { $0.artist })
  files["/GROUP.NDB"] = writeNdb(groups.map { $0.name })
  files["/PLLIST.NDB"] = writeNdb([])

  let sizes = tracks.map { ATP_OVERHEAD + $0.frames.count }
  let toc = try writeToc(
    frameCounts: frameCounts,
    groups: groups.map { (first: $0.first, last: $0.last) },
    icv: icv(discId: discId, sizes: sizes),
    discId: discId)
  files["/TOC00000.STI"] = toc
  files["/TOC00001.STI"] = writePlf()
  files["/" + STK_FILENAME] = STK_BYTES

  var sizeMap: [String: Int] = [:]
  for (p, d) in files { sizeMap[p] = d.count }
  let estSectors = try checkCapacity(sizeMap, capacitySectors)
  let isoTs = timestamp.map {
    IsoTimestampInput(ms: $0.ms, tzOffsetMinutes: $0.tzOffsetMinutes)
  }
  let iso = writeIso(files: files, timestamp: isoTs)
  let exactSectors = ceilDiv(iso.count, 2048)
  if exactSectors + 11709 > capacitySectors {
    throw DiscCoreError.message("built ISO exceeds blank capacity")
  }

  return BuildDiscResult(
    iso: iso,
    files: files,
    stats: DiscStats(isoBytes: iso.count,
                     isoSectors: exactSectors,
                     estimatedSectors: estSectors,
                     capacitySectors: capacitySectors,
                     trackCount: tracks.count))
}
