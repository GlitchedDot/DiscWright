// IsoRead.swift — mirror of isoread.js: reading an authored
// ATRAC CD ISO back. The layout facts are the mirror image of
// the writers, cloned from genuine SonicStage discs, so this
// reads app-authored and genuine discs alike.
import Foundation

private let READ_SECTOR = 2048

private func u16le(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
private func u32le(_ b: [UInt8], _ o: Int) -> Int {
  (Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24))
}
private func u16be(_ b: [UInt8], _ o: Int) -> Int { (Int(b[o]) << 8) | Int(b[o + 1]) }
private func u32be(_ b: [UInt8], _ o: Int) -> Int {
  ((Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8) | Int(b[o + 3]))
}

/// One file's location in the image (isoread.js's {extent, size}).
struct IsoFileRec {
  var extent: Int
  var size: Int
}

private struct DirRec {
  var name: String
  var extent: Int
  var size: Int
  var isDir: Bool
}

// One directory's records. Records never cross a sector
// boundary; a zero length byte is padding to the next sector.
private func readDir(_ bytes: [UInt8], _ extent: Int, _ size: Int) -> [DirRec] {
  var out: [DirRec] = []
  let start = extent * READ_SECTOR
  let end = start + size
  var p = start
  while p < end {
    let len = Int(bytes[p])
    if len == 0 {
      p = (p / READ_SECTOR + 1) * READ_SECTOR
      continue
    }
    if len < 34 { break }
    let nameLen = Int(bytes[p + 32])
    var name = ""
    for i in 0..<nameLen {
      // JS: String.fromCharCode(byte) — a Latin-1 unit per byte.
      name.append(Character(UnicodeScalar(bytes[p + 33 + i])))
    }
    out.append(DirRec(name: name,
                      extent: u32le(bytes, p + 2),
                      size: u32le(bytes, p + 10),
                      isDir: (bytes[p + 25] & 2) != 0))
    p += len
  }
  return out
}

private func walkIsoDir(_ bytes: [UInt8], _ extent: Int, _ size: Int,
                        _ prefix: String,
                        _ files: inout [String: IsoFileRec]) {
  for rec in readDir(bytes, extent, size) {
    if rec.name == "\u{00}" || rec.name == "\u{01}" { continue }
    var path = prefix + "/" + rec.name
    if path.hasSuffix(";1") { path = String(path.dropLast(2)) }
    if rec.isDir {
      walkIsoDir(bytes, rec.extent, rec.size, path, &files)
    } else {
      files[path.uppercased()] = IsoFileRec(extent: rec.extent, size: rec.size)
    }
  }
}

/// readIsoFiles(bytes): map of "/PATH/FILE" (upper case, ";1"
/// stripped) -> {extent, size}. Throws if not an ISO 9660 image.
func readIsoFiles(_ bytes: [UInt8]) throws -> [String: IsoFileRec] {
  let pvd = 16 * READ_SECTOR
  guard bytes.count >= pvd + READ_SECTOR, bytes[pvd] == 1,
        bytes[pvd + 1] == 0x43, bytes[pvd + 2] == 0x44, // "CD001"
        bytes[pvd + 3] == 0x30, bytes[pvd + 4] == 0x30,
        bytes[pvd + 5] == 0x31
  else {
    throw DiscCoreError.message("not an ISO 9660 image")
  }
  let rootRec = pvd + 156
  var files: [String: IsoFileRec] = [:]
  walkIsoDir(bytes, u32le(bytes, rootRec + 2), u32le(bytes, rootRec + 10),
             "", &files)
  return files
}

private func fileBytes(_ bytes: [UInt8], _ rec: IsoFileRec) -> [UInt8] {
  let start = rec.extent * READ_SECTOR
  return Array(bytes[start..<(start + rec.size)])
}

// The NDB name tables: 256-byte header, then 128-byte records of
// 02 00 + UTF-16BE text. One string per track (or per group).
// The JS collects UTF-16 units via String.fromCharCode and lets
// surrogate pairs re-form astral characters in the string; the
// Swift collects the same units and decodes them as UTF-16,
// which does the same (a lone surrogate decodes to U+FFFD where
// the JS would keep it in the string — see NOTES.md).
private func readNdb(_ bytes: [UInt8]?) -> [String] {
  guard let bytes = bytes, bytes.count >= NDB_HEADER_LEN else { return [] }
  let count = u16be(bytes, 6)
  var out: [String] = []
  for i in 0..<count {
    let off = NDB_HEADER_LEN + i * NDB_RECORD_LEN
    if off + NDB_RECORD_LEN > bytes.count { break }
    if bytes[off] != 0x02 { out.append(""); continue }
    var units: [UInt16] = []
    for j in 0..<30 {
      let u = u16be(bytes, off + 2 + j * 2)
      if u == 0 { break }
      units.append(UInt16(u))
    }
    out.append(String(decoding: units, as: UTF16.self))
  }
  return out
}

/// A track read back from a disc (isoread.js's track objects).
struct ParsedTrack {
  var title: String
  var artist: String
  var album: String
  var seconds: Int
  var size: Int
}

/// A group read back from a disc.
struct ParsedGroup {
  var name: String
  var tracks: [ParsedTrack]
}

/// parseAtracDisc's result.
struct ParsedDisc {
  var trackCount: Int
  var totalSeconds: Int
  var groups: [ParsedGroup]
}

private func atString(_ arr: [String], _ i: Int) -> String {
  i < arr.count ? arr[i] : ""
}

private func readerTrackFilename(_ num: Int) -> String {
  var h = String(num, radix: 16, uppercase: true)
  while h.count < 5 { h = "0" + h }
  return "/HIFI/TRK" + h + ".ATP"
}

/// parseAtracDisc(bytes): group ranges and per-track frame
/// counts from TOC00000.STI; names from the NDB tables; sizes
/// from the HIFI/ directory. Throws if not an ATRAC disc.
func parseAtracDisc(_ bytes: [UInt8]) throws -> ParsedDisc {
  let files = try readIsoFiles(bytes)
  guard let tocRec = files["/TOC00000.STI"] else {
    throw DiscCoreError.message("no TOC00000.STI — not an ATRAC CD image")
  }
  let toc = fileBytes(bytes, tocRec)
  let groupCount = Int(toc[9])
  let trackCount = u16be(toc, 10)
  var ranges: [(first: Int, last: Int)] = []
  if groupCount > 0 {
    for k in 1...groupCount {
      let off = 0x100 + k * 8
      ranges.append((first: u16be(toc, off), last: u16be(toc, off + 2)))
    }
  }
  func get(_ p: String) -> [UInt8]? {
    guard let r = files[p] else { return nil }
    return fileBytes(bytes, r)
  }
  let titles = readNdb(get("/TRACK.NDB"))
  let artists = readNdb(get("/ARTIST.NDB"))
  let albums = readNdb(get("/ALBUM.NDB"))
  let groupNames = readNdb(get("/GROUP.NDB"))
  var groups: [ParsedGroup] = ranges.enumerated().map { gi, _ in
    let name = atString(groupNames, gi)
    return ParsedGroup(name: name.isEmpty ? "Group \(gi + 1)" : name, tracks: [])
  }
  var totalSeconds = 0
  for i in 0..<trackCount {
    let off = 0x900 + i * 16
    let frames = u32be(toc, off + 12)
    let seconds = framesToSeconds(frames)
    totalSeconds += seconds
    let num = i + 1
    let rec = files[readerTrackFilename(num)]
    let t = ParsedTrack(title: atString(titles, i),
                        artist: atString(artists, i),
                        album: atString(albums, i),
                        seconds: seconds,
                        size: rec?.size ?? 0)
    if let gi = ranges.firstIndex(where: { $0.first <= num && num <= $0.last }) {
      groups[gi].tracks.append(t)
    }
  }
  return ParsedDisc(trackCount: trackCount, totalSeconds: totalSeconds,
                    groups: groups)
}
