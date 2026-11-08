// Sti.swift — mirror of sti.js: TOC00000.STI ("TOC ") and
// TOC00001.STI ("PLF "). The TOC's two per-disc fields are the
// recipe values: disc_id_a carries the ICV, disc_id_b the DiscID.
import Foundation

let TOC_HEADER_LEN = 0x900
let PLF_SIZE = 2176
private let FORMAT_MAGIC: [UInt8] = [0x01, 0x00, 0x28, 0x2e]
private let SAMPLES_PER_FRAME = 2048
private let SAMPLE_RATE = 44100

/// framesToSeconds(frames): trunc(frames * 2048 / 44100).
/// JS computes in double; for any frame count a disc can hold,
/// the product is far below 2^53, so integer division matches.
func framesToSeconds(_ frames: Int) -> Int {
  return (frames * SAMPLES_PER_FRAME) / SAMPLE_RATE
}

/// writeToc: frameCounts per track, groups as [first, last]
/// 1-based inclusive pairs, icv 8 bytes, discId 16 bytes.
func writeToc(frameCounts: [Int], groups: [(first: Int, last: Int)],
              icv: [UInt8], discId: [UInt8]) throws -> [UInt8] {
  let n = frameCounts.count
  let totalSeconds = frameCounts.reduce(0) { $0 + framesToSeconds($1) }
  var out = [UInt8](repeating: 0, count: TOC_HEADER_LEN + n * 16)
  out.replaceSubrange(0..<4, with: [0x54, 0x4f, 0x43, 0x20]) // "TOC "
  out[4] = 1 // u32 LE version = 1 (bytes 5..7 stay 0)
  out[8] = 1
  out[9] = UInt8(truncatingIfNeeded: groups.count)
  out[10] = UInt8((n >> 8) & 0xff)
  out[11] = UInt8(n & 0xff)
  let ts = UInt32(truncatingIfNeeded: totalSeconds)
  out[12] = UInt8((ts >> 24) & 0xff)
  out[13] = UInt8((ts >> 16) & 0xff)
  out[14] = UInt8((ts >> 8) & 0xff)
  out[15] = UInt8(ts & 0xff)
  out.replaceSubrange(0x10..<(0x10 + icv.count), with: icv)
  out.replaceSubrange(0x20..<(0x20 + discId.count), with: discId)
  for (gi, g) in groups.enumerated() {
    let k = gi + 1
    let off = 0x100 + k * 8
    out[off] = UInt8((g.first >> 8) & 0xff)
    out[off + 1] = UInt8(g.first & 0xff)
    out[off + 2] = UInt8((g.last >> 8) & 0xff)
    out[off + 3] = UInt8(g.last & 0xff)
    out[off + 4] = UInt8((k >> 8) & 0xff)
    out[off + 5] = UInt8(k & 0xff)
  }
  for (i, fc) in frameCounts.enumerated() {
    let num = i + 1
    let group = (groups.firstIndex(where: { $0.first <= num && num <= $0.last }) ?? -1) + 1
    if group == 0 {
      throw DiscCoreError.message("track \(num) is not covered by any group")
    }
    let off = TOC_HEADER_LEN + i * 16
    out[off] = UInt8((num >> 8) & 0xff)
    out[off + 1] = UInt8(num & 0xff)
    out[off + 2] = UInt8((num >> 8) & 0xff)
    out[off + 3] = UInt8(num & 0xff)
    out[off + 4] = UInt8(truncatingIfNeeded: group)
    out.replaceSubrange((off + 8)..<(off + 12), with: FORMAT_MAGIC)
    let f = UInt32(truncatingIfNeeded: fc)
    out[off + 12] = UInt8((f >> 24) & 0xff)
    out[off + 13] = UInt8((f >> 16) & 0xff)
    out[off + 14] = UInt8((f >> 8) & 0xff)
    out[off + 15] = UInt8(f & 0xff)
  }
  return out
}

/// writePlf() -> 2176 bytes, "PLF " + version 1, rest zero.
func writePlf() -> [UInt8] {
  var out = [UInt8](repeating: 0, count: PLF_SIZE)
  out.replaceSubrange(0..<5, with: [0x50, 0x4c, 0x46, 0x20, 0x01])
  return out
}
