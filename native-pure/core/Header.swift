// Header.swift — mirror of header.js: the 96-byte secure header
// at .ATP offset 1024.
import Foundation

let HEADER_LEN = 96
private let FORMAT_MAGIC: [UInt8] = [0x01, 0x00, 0x28, 0x2e]
private let BLOCK_PARAMS: [UInt8] = [0x01, 0x0f, 0x50, 0x00, 0x00, 0x04, 0x00, 0x00]
private let CONNUM_TAIL: [UInt8] = [0x16, 0x72, 0x5f, 0x9b, 0xe7]
private let EKB_VERSION: UInt32 = 0x0001000e

/// Fields for headerToBytes (header.js's `h` object).
struct SecureHeaderFields {
  var frameCount: Int
  var blockSeed: [UInt8]  // 8
  var initVector: [UInt8] // 8
  var connum: [UInt8]     // 2
  var trackSlot: [UInt8]  // 4
  var mgd: [UInt8]        // 8
}

/// headerToBytes(h) -> 96 bytes.
func headerToBytes(_ h: SecureHeaderFields) -> [UInt8] {
  var out = [UInt8](repeating: 0, count: HEADER_LEN)
  let fc = UInt32(truncatingIfNeeded: h.frameCount)
  out.replaceSubrange(0x00..<0x04, with: FORMAT_MAGIC)
  out[0x04] = UInt8((fc >> 24) & 0xff)
  out[0x05] = UInt8((fc >> 16) & 0xff)
  out[0x06] = UInt8((fc >> 8) & 0xff)
  out[0x07] = UInt8(fc & 0xff)
  out[0x10] = UInt8((EKB_VERSION >> 24) & 0xff)
  out[0x11] = UInt8((EKB_VERSION >> 16) & 0xff)
  out[0x12] = UInt8((EKB_VERSION >> 8) & 0xff)
  out[0x13] = UInt8(EKB_VERSION & 0xff)
  out.replaceSubrange(0x18..<(0x18 + h.blockSeed.count), with: h.blockSeed)
  out.replaceSubrange(0x20..<(0x20 + BLOCK_PARAMS.count), with: BLOCK_PARAMS)
  out[0x28] = 0
  out.replaceSubrange(0x29..<(0x29 + h.connum.count), with: h.connum)
  out.replaceSubrange(0x2b..<(0x2b + CONNUM_TAIL.count), with: CONNUM_TAIL)
  out.replaceSubrange(0x30..<(0x30 + h.trackSlot.count), with: h.trackSlot)
  out.replaceSubrange(0x40..<0x44, with: [0x41, 0x54, 0x58, 0x20]) // "ATX "
  out.replaceSubrange(0x50..<(0x50 + h.mgd.count), with: h.mgd)
  out.replaceSubrange(0x58..<(0x58 + h.initVector.count), with: h.initVector)
  return out
}
