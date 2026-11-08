// Ndb.swift — mirror of ndb.js (writer side).
// 256-byte header: "NDB " + 01 00 + BE u16 record count.
// 128-byte records: 02 00 + UTF-16BE string (max 30 units),
// zero padded. An empty string is an all-zero record.
import Foundation

let NDB_HEADER_LEN = 256
let NDB_RECORD_LEN = 128

/// writeNdb(strings) -> bytes.
func writeNdb(_ strings: [String]) -> [UInt8] {
  var out = [UInt8](repeating: 0,
                     count: NDB_HEADER_LEN + strings.count * NDB_RECORD_LEN)
  out.replaceSubrange(0..<6, with: [0x4e, 0x44, 0x42, 0x20, 0x01, 0x00])
  out[6] = UInt8((strings.count >> 8) & 0xff)
  out[7] = UInt8(strings.count & 0xff)
  for (i, s) in strings.enumerated() {
    if s == "" { continue } // all-zero record
    let off = NDB_HEADER_LEN + i * NDB_RECORD_LEN
    out[off] = 0x02
    out[off + 1] = 0x00
    let bytes = utf16beClamped(s)
    out.replaceSubrange((off + 2)..<(off + 2 + bytes.count), with: bytes)
  }
  return out
}
