// Iso.swift — mirror of iso.js: the ISO 9660 writer.
// Layout matches the original burner: system area zeroed, blank
// volume ids, L path table then M path table, directories first
// in path-table order, files grouped by parent in directory-
// record order.
//
// Timestamps: the JS derives everything from {ms, tzOffsetMinutes}
// with Date's UTC getters — ms is an absolute epoch instant,
// "local" = UTC + tzOffsetMinutes. JavaScript Date is a pure
// proleptic-Gregorian UTC calendar, so the Swift computes the
// civil fields arithmetically (Howard Hinnant's algorithm) with
// no Foundation Calendar, which could be affected by the host's
// calendar settings. Math.floor semantics are kept where the JS
// uses Math.floor (Swift's / truncates toward zero).
import Foundation

let ISO_SECTOR = 2048

// ---- endian helpers (iso.js's le16/be16/both16/le32/be32/both32) ----
func le16(_ n: Int) -> [UInt8] { [UInt8(n & 0xff), UInt8((n >> 8) & 0xff)] }
func be16(_ n: Int) -> [UInt8] { [UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] }
func both16(_ n: Int) -> [UInt8] { le16(n) + be16(n) }
func le32(_ n: Int) -> [UInt8] {
  [UInt8(n & 0xff), UInt8((n >> 8) & 0xff),
   UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)]
}
func be32(_ n: Int) -> [UInt8] {
  [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
   UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
}
func both32(_ n: Int) -> [UInt8] { le32(n) + be32(n) }

func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }

/// Floor division (JS Math.floor(a / b)); Swift's / truncates.
func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
  var q = a / b
  if (a % b != 0) && ((a < 0) != (b < 0)) { q -= 1 }
  return q
}

func asciiBytes(_ s: String) -> [UInt8] { [UInt8](s.utf8) }

/// iso.js's cmpBytes: lexicographic byte compare.
func cmpBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
  let n = min(a.count, b.count)
  for i in 0..<n {
    if a[i] != b[i] { return Int(a[i]) - Int(b[i]) }
  }
  return a.count - b.count
}

func putBytes(_ img: inout [UInt8], _ data: [UInt8], at off: Int) {
  img.replaceSubrange(off..<(off + data.count), with: data)
}

// ---- timestamps ----
struct IsoTimestampInput {
  var ms: Int64
  var tzOffsetMinutes: Int
}

struct IsoTimestampOutput {
  var date7: [UInt8]
  var pvd17: [UInt8]
}

/// Civil fields of an epoch-ms instant, UTC (JS Date UTC getters).
func civilParts(_ ms: Int64) -> (year: Int, month: Int, day: Int,
                                 hour: Int, minute: Int, second: Int) {
  let days = floorDiv(ms, 86_400_000)
  var rem = ms - days * 86_400_000 // 0 ..< 86_400_000
  let hour = Int(rem / 3_600_000)
  rem -= Int64(hour) * 3_600_000
  let minute = Int(rem / 60_000)
  rem -= Int64(minute) * 60_000
  let second = Int(rem / 1_000)
  // civil_from_days (Howard Hinnant), days since 1970-01-01.
  let z = days + 719_468
  let era = floorDiv(z, 146_097)
  let doe = z - era * 146_097                                // 0..<146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // 0..<400
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)          // 0..<366
  let mp = (5 * doy + 2) / 153                               // 0..<12
  let d = doy - (153 * mp + 2) / 5 + 1                       // 1..<32
  let m = mp + (mp < 10 ? 3 : -9)                            // 1..<13
  if m <= 2 { y += 1 }
  return (Int(y), Int(m), Int(d), hour, minute, second)
}

/// iso.js's timestamps(ts): {date7, pvd17}.
func isoTimestamps(_ ts: IsoTimestampInput?) -> IsoTimestampOutput {
  let ms: Int64
  let tzMin: Int
  if let ts = ts {
    ms = ts.ms
    tzMin = ts.tzOffsetMinutes
  } else {
    // JS fallback: Date.now() and -new Date(ms).getTimezoneOffset().
    let now = Date()
    ms = Int64(now.timeIntervalSince1970 * 1000)
    tzMin = TimeZone.current.secondsFromGMT(for: now) / 60
  }
  let tz = Int(floorDiv(Int64(tzMin), 15))
  let local = civilParts(ms + Int64(tzMin) * 60_000)
  let utc = civilParts(ms)
  let date7: [UInt8] = [
    UInt8(truncatingIfNeeded: local.year - 1900),
    UInt8(truncatingIfNeeded: local.month),
    UInt8(truncatingIfNeeded: local.day),
    UInt8(truncatingIfNeeded: local.hour),
    UInt8(truncatingIfNeeded: local.minute),
    UInt8(truncatingIfNeeded: local.second),
    UInt8(truncatingIfNeeded: tz),
  ]
  func p2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
  var yearStr = "\(utc.year)"
  while yearStr.count < 4 { yearStr = "0" + yearStr }
  // JS: Math.floor((ms % 1000) / 10) — JS % keeps the dividend's
  // sign (as does Swift's), the division is floored.
  let hundredths = Int(floorDiv(ms % 1000, 10))
  let digits = yearStr + p2(utc.month) + p2(utc.day) + p2(utc.hour) +
    p2(utc.minute) + p2(utc.second) + p2(hundredths)
  var pvd17 = [UInt8](repeating: 0, count: 17)
  let digitBytes = asciiBytes(digits)
  for i in 0..<16 { pvd17[i] = digitBytes[i] }
  pvd17[16] = UInt8(truncatingIfNeeded: tz)
  return IsoTimestampOutput(date7: date7, pvd17: pvd17)
}

// ---- directory records ----
func dirRecord(extent: Int, size: Int, isDir: Bool,
               date7: [UInt8], name: [UInt8]) -> [UInt8] {
  let nlen = name.count
  var total = 33 + nlen
  if total % 2 == 1 { total += 1 }
  var rec = [UInt8](repeating: 0, count: total)
  rec[0] = UInt8(truncatingIfNeeded: total)
  putBytes(&rec, both32(extent), at: 2)
  putBytes(&rec, both32(size), at: 10)
  putBytes(&rec, date7, at: 18)
  rec[25] = isDir ? 2 : 0
  putBytes(&rec, both16(1), at: 28)
  rec[32] = UInt8(truncatingIfNeeded: nlen)
  putBytes(&rec, name, at: 33)
  return rec
}

// ---- the tree (iso.js's Dir / buildTree / dirOrder) ----
final class IsoDir {
  var path: String
  var name: [UInt8]
  var parent: IsoDir?
  var files: [(ident: [UInt8], path: String, size: Int)] = []
  var subdirs: [IsoDir] = []
  var extent = 0
  var size = 0
  var index = 0
  init(path: String, name: [UInt8], parent: IsoDir?) {
    self.path = path
    self.name = name
    self.parent = parent
  }
}

func buildTree(sizes: [String: Int]) -> IsoDir {
  let root = IsoDir(path: "", name: [0], parent: nil)
  var dirs: [String: IsoDir] = ["": root]
  // JS: [...sizes.keys()].sort() — default string sort.
  for path in sizes.keys.sorted() {
    let parts = path.split(separator: "/").map(String.init)
    var parent = root
    var cur = ""
    for part in parts.dropLast() {
      cur += "/" + part
      if dirs[cur] == nil {
        let d = IsoDir(path: cur, name: asciiBytes(part), parent: parent)
        dirs[cur] = d
        parent.subdirs.append(d)
      }
      parent = dirs[cur]!
    }
    let ident = asciiBytes(parts[parts.count - 1] + ";1")
    parent.files.append((ident: ident, path: path, size: sizes[path]!))
  }
  for d in dirs.values {
    d.files.sort { cmpBytes($0.ident, $1.ident) < 0 }
    d.subdirs.sort { cmpBytes($0.name, $1.name) < 0 }
  }
  return root
}

func dirOrder(_ root: IsoDir) -> [IsoDir] {
  var order = [root]
  var i = 0
  while i < order.count {
    let kids = order[i].subdirs.sorted { cmpBytes($0.name, $1.name) < 0 }
    order.append(contentsOf: kids)
    i += 1
  }
  for (n, d) in order.enumerated() { d.index = n + 1 }
  return order
}

func dirDataSize(_ d: IsoDir) -> Int {
  var idents: [[UInt8]] = [[0], [1]]
  for sd in d.subdirs { idents.append(sd.name) }
  for f in d.files { idents.append(f.ident) }
  idents.sort { cmpBytes($0, $1) < 0 }
  var pos = 0
  for ident in idents {
    var ln = 33 + ident.count
    if ln % 2 == 1 { ln += 1 }
    if (pos % ISO_SECTOR) + ln > ISO_SECTOR {
      pos += ISO_SECTOR - (pos % ISO_SECTOR)
    }
    pos += ln
  }
  return ceilDiv(pos, ISO_SECTOR) * ISO_SECTOR
}

func pathTables(_ order: [IsoDir]) -> (lt: [UInt8], mt: [UInt8]) {
  var lt: [UInt8] = []
  var mt: [UInt8] = []
  for d in order {
    let name: [UInt8] = d.parent == nil ? [0] : d.name
    let parentIdx = d.parent == nil ? d.index : d.parent!.index
    let pad: [UInt8] = name.count % 2 == 1 ? [0] : []
    lt.append(contentsOf: [UInt8(truncatingIfNeeded: name.count), 0])
    lt.append(contentsOf: le32(d.extent))
    lt.append(contentsOf: le16(parentIdx))
    lt.append(contentsOf: name)
    lt.append(contentsOf: pad)
    mt.append(contentsOf: [UInt8(truncatingIfNeeded: name.count), 0])
    mt.append(contentsOf: be32(d.extent))
    mt.append(contentsOf: be16(parentIdx))
    mt.append(contentsOf: name)
    mt.append(contentsOf: pad)
  }
  return (lt, mt)
}

// ---- the planner (iso.js's plan / isoSectorCount) ----
struct IsoPlan {
  var order: [IsoDir]
  var lt: [UInt8]
  var mt: [UInt8]
  var fileExtents: [String: Int]
  var total: Int
}

func planIso(_ sizes: [String: Int]) -> IsoPlan {
  let root = buildTree(sizes: sizes)
  let order = dirOrder(root)
  for d in order { d.size = dirDataSize(d) }
  var tables = pathTables(order) // extents 0; lengths final
  let ltSec = ceilDiv(tables.lt.count, ISO_SECTOR)
  let mtSec = ceilDiv(tables.mt.count, ISO_SECTOR)
  var nxt = 16 + 2 + ltSec + mtSec
  for d in order {
    d.extent = nxt
    nxt += d.size / ISO_SECTOR
  }
  var fileExtents: [String: Int] = [:]
  for d in order {
    for f in d.files {
      fileExtents[f.path] = nxt
      nxt += ceilDiv(f.size, ISO_SECTOR)
    }
  }
  tables = pathTables(order) // recomputed with real extents
  return IsoPlan(order: order, lt: tables.lt, mt: tables.mt,
                 fileExtents: fileExtents, total: nxt)
}

/// isoSectorCount(sizes) -> total sectors of the planned image.
func isoSectorCount(_ sizes: [String: Int]) -> Int {
  return planIso(sizes).total
}

func dirBytes(_ d: IsoDir, _ fileExtents: [String: Int],
              _ date7: [UInt8]) -> [UInt8] {
  let parent = d.parent ?? d
  var records: [(ident: [UInt8], ext: Int, size: Int, isDir: Bool)] = [
    (ident: [0], ext: d.extent, size: d.size, isDir: true),
    (ident: [1], ext: parent.extent, size: parent.size, isDir: true),
  ]
  var kids: [(ident: [UInt8], ext: Int, size: Int, isDir: Bool)] = []
  for sd in d.subdirs {
    kids.append((ident: sd.name, ext: sd.extent, size: sd.size, isDir: true))
  }
  for f in d.files {
    kids.append((ident: f.ident, ext: fileExtents[f.path]!,
                 size: f.size, isDir: false))
  }
  kids.sort { cmpBytes($0.ident, $1.ident) < 0 }
  records.append(contentsOf: kids)
  var out = [UInt8](repeating: 0, count: d.size)
  var len = 0
  for r in records {
    let rec = dirRecord(extent: r.ext, size: r.size, isDir: r.isDir,
                        date7: date7, name: r.ident)
    if (len % ISO_SECTOR) + rec.count > ISO_SECTOR {
      len += ISO_SECTOR - (len % ISO_SECTOR)
    }
    putBytes(&out, rec, at: len)
    len += rec.count
  }
  return out
}

// ---- the writer ----
/// writeIso(files, volIdent, timestamp) -> ISO bytes.
/// (iso.js signature: writeIso(files, {volIdent = "", timestamp}).)
func writeIso(files: [String: [UInt8]], volIdent: String = "",
              timestamp: IsoTimestampInput? = nil) -> [UInt8] {
  var sizes: [String: Int] = [:]
  for (p, data) in files { sizes[p] = data.count }
  let plan = planIso(sizes)
  let ts = isoTimestamps(timestamp)
  let root = plan.order[0]
  var img = [UInt8](repeating: 0, count: plan.total * ISO_SECTOR)

  var pvd = [UInt8](repeating: 0, count: ISO_SECTOR)
  pvd[0] = 1
  putBytes(&pvd, asciiBytes("CD001"), at: 1)
  pvd[6] = 1
  for i in 8..<40 { pvd[i] = 0x20 }
  let ident = Array(asciiBytes(volIdent).prefix(32))
  for i in 40..<72 { pvd[i] = 0x20 }
  putBytes(&pvd, ident, at: 40)
  putBytes(&pvd, both32(plan.total), at: 80)
  putBytes(&pvd, both16(1), at: 120)
  putBytes(&pvd, both16(1), at: 124)
  putBytes(&pvd, both16(ISO_SECTOR), at: 128)
  putBytes(&pvd, both32(plan.lt.count), at: 132)
  putBytes(&pvd, le32(18), at: 140)
  putBytes(&pvd, be32(18 + ceilDiv(plan.lt.count, ISO_SECTOR)), at: 148)
  putBytes(&pvd, dirRecord(extent: root.extent, size: root.size,
                           isDir: true, date7: ts.date7, name: [0]), at: 156)
  for off in [190, 318, 446, 574] {
    for i in off..<(off + 128) { pvd[i] = 0x20 }
  }
  for off in [702, 739, 776] {
    for i in off..<(off + 37) { pvd[i] = 0x20 }
  }
  for off in [813, 830, 847, 864] { putBytes(&pvd, ts.pvd17, at: off) }
  pvd[881] = 1
  putBytes(&img, pvd, at: 16 * ISO_SECTOR)

  var term = [UInt8](repeating: 0, count: ISO_SECTOR)
  term[0] = 255
  putBytes(&term, asciiBytes("CD001"), at: 1)
  term[6] = 1
  putBytes(&img, term, at: 17 * ISO_SECTOR)

  putBytes(&img, plan.lt, at: 18 * ISO_SECTOR)
  putBytes(&img, plan.mt,
           at: (18 + ceilDiv(plan.lt.count, ISO_SECTOR)) * ISO_SECTOR)

  for d in plan.order {
    putBytes(&img, dirBytes(d, plan.fileExtents, ts.date7),
             at: d.extent * ISO_SECTOR)
  }
  for (path, data) in files {
    putBytes(&img, data, at: plan.fileExtents[path]! * ISO_SECTOR)
  }
  return img
}
