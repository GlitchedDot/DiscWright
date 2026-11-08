// Text.swift — mirror of text.js.
// Strings are clamped to 30 UTF-16 code units (astral characters
// count 2 and are kept or dropped whole; lone surrogates become
// U+FFFD) and encoded UTF-16BE.
//
// The JS iterates a string by code point (`for (const ch of s)`),
// where a lone surrogate surfaces as its own "character" with
// codePointAt() in 0xD800...0xDFFF. A Swift String can never hold
// an unpaired surrogate (it is repaired to U+FFFD at construction),
// so iterating `unicodeScalars` reproduces the JS for every string
// a Swift String can actually contain; the FFFD replacement below
// is then a no-op safety net kept for mechanical parity.
import Foundation

let MAX_STRING_UNITS = 30

/// Code points of the string, in iteration order (JS `for...of`).
func jsCodePoints(_ s: String) -> [UInt32] {
  return s.unicodeScalars.map { $0.value }
}

/// clampString(s): the clamped string as a list of code points.
func clampString(_ s: String) -> [UInt32] {
  var out: [UInt32] = []
  var units = 0
  for var cp in jsCodePoints(s) {
    if cp >= 0xd800 && cp <= 0xdfff { cp = 0xfffd }
    let n = cp > 0xffff ? 2 : 1
    if units + n > MAX_STRING_UNITS { break }
    out.append(cp)
    units += n
  }
  return out
}

/// utf16be(codePoints): UTF-16BE bytes, with surrogate pairs for
/// astral code points, exactly as text.js computes them.
func utf16be(_ codePoints: [UInt32]) -> [UInt8] {
  var bytes: [UInt8] = []
  for cp in codePoints {
    if cp > 0xffff {
      let v = cp - 0x10000
      let hi = 0xd800 + (v >> 10)
      let lo = 0xdc00 + (v & 0x3ff)
      bytes.append(UInt8((hi >> 8) & 0xff))
      bytes.append(UInt8(hi & 0xff))
      bytes.append(UInt8((lo >> 8) & 0xff))
      bytes.append(UInt8(lo & 0xff))
    } else {
      bytes.append(UInt8((cp >> 8) & 0xff))
      bytes.append(UInt8(cp & 0xff))
    }
  }
  return bytes
}

/// The pipeline the JS applies everywhere: utf16be(clampString(s)).
func utf16beClamped(_ s: String) -> [UInt8] {
  return utf16be(clampString(s))
}

/// Parse an even-length hex string into bytes (JS `.match(/../g)`
/// + parseInt(h, 16)); used for the core's held constants.
func bytesFromHex(_ hex: String) -> [UInt8] {
  let chars = Array(hex)
  var out: [UInt8] = []
  out.reserveCapacity(chars.count / 2)
  var i = 0
  while i + 1 < chars.count {
    let hi = UInt8(String(chars[i]), radix: 16) ?? 0
    let lo = UInt8(String(chars[i + 1]), radix: 16) ?? 0
    out.append((hi << 4) | lo)
    i += 2
  }
  return out
}
