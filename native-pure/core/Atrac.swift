// Atrac.swift — mirror of atrac.js: the hardware-proven recipe.
//   Payload: DES-CBC under d2[0:8], IV = header InitVector.
//   BlockSeed: 2-key triple-DES EDE under V of
//     (DiscID[0:8] ^ DiscID[8:16]) ^ BE64(bindIndex+1) ^ d2[0:8].
//   ICV: X = BE64(DiscID[0:8]); for each .ATP size s:
//     X = (X*s + B) mod 2^64, B = BE64(DiscID[8:16]); out BE64(X).
// The JS does the fold with BigInt + an explicit 2^64 mask; the
// Swift uses UInt64 wrapping arithmetic (&* then &+), which is
// the same operation modulo 2^64.
import Foundation

let D2: [UInt8] = bytesFromHex("3d14fb8d372a3b5b17010dbb4fd1b3fecf4a0570")
let V_KEY: [UInt8] = bytesFromHex("3c8e092d257ffa7d3a3986d75b1b4c2b")
let CONNUM: [UInt8] = [0x4f, 0x7e]
let TRACK_SLOT: [UInt8] = [0xb4, 0xf3, 0x7f, 0xbb]
let MGD: [UInt8] = bytesFromHex("2ad14387ddfb4b86")
let FRAME_SIZE = 376 // 64 kbps ATRAC3+ frame

private func xor8(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
  var out = [UInt8](repeating: 0, count: 8)
  for i in 0..<8 { out[i] = a[i] ^ b[i] }
  return out
}

/// Big-endian 64-bit encoding of a UInt64 (atrac.js `be64`).
func be64Bytes(_ n: UInt64) -> [UInt8] {
  var out = [UInt8](repeating: 0, count: 8)
  var x = n
  var i = 7
  while i >= 0 {
    out[i] = UInt8(x & 0xff)
    x >>= 8
    i -= 1
  }
  return out
}

/// Big-endian 64-bit decode of the first 8 bytes.
func readBE64(_ b: ArraySlice<UInt8>) -> UInt64 {
  var x: UInt64 = 0
  for i in 0..<8 { x = (x << 8) | UInt64(b[b.startIndex + i]) }
  return x
}

/// blockSeed(discId, bindIndex), bindIndex 0-based.
func blockSeed(discId: [UInt8], bindIndex: Int) throws -> [UInt8] {
  let fold = xor8(Array(discId[0..<8]), Array(discId[8..<16]))
  let p = xor8(xor8(fold, be64Bytes(UInt64(bindIndex + 1))),
               Array(D2[0..<8]))
  return try edeEncryptBlock(key16: V_KEY, block8: p)
}

/// icv(discId, sizes): the unkeyed fold over full .ATP sizes.
func icv(discId: [UInt8], sizes: [Int]) -> [UInt8] {
  let a = readBE64(discId[0..<8])
  let b = readBE64(discId[8..<16])
  var x = a
  for s in sizes {
    x = x &* UInt64(s) &+ b
  }
  return be64Bytes(x)
}

/// encryptPayload(frames, iv): DES-CBC under d2[0:8], one chain.
func encryptPayload(frames: [UInt8], iv: [UInt8]) throws -> [UInt8] {
  return try desCbcEncrypt(key8: Array(D2[0..<8]), iv8: iv, data: frames)
}
