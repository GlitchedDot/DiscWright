// Id3.swift — mirror of id3.js (writer side): the 1,024-byte
// ID3v2.4 tag at the head of every .ATP. Frames TIT2, TPE1, TALB
// in order; text encoding 0x02 (UTF-16BE); clamped string + one
// NUL unit; syncsafe sizes; zero padding.
import Foundation

let TAG_LEN = 1024

private func syncsafe(_ n: Int) -> [UInt8] {
  return [UInt8((n >> 21) & 0x7f), UInt8((n >> 14) & 0x7f),
          UInt8((n >> 7) & 0x7f), UInt8(n & 0x7f)]
}

private func frame(_ fid: String, _ text: String) -> [UInt8] {
  let textBytes = utf16beClamped(text)
  var body = [UInt8](repeating: 0, count: 1 + textBytes.count + 2)
  body[0] = 0x02
  body.replaceSubrange(1..<(1 + textBytes.count), with: textBytes)
  // (the final two bytes stay zero: the NUL terminator unit)
  var out = [UInt8](repeating: 0, count: 10 + body.count)
  let fidBytes = [UInt8](fid.utf8)
  out.replaceSubrange(0..<4, with: fidBytes)
  out.replaceSubrange(4..<8, with: syncsafe(body.count))
  out.replaceSubrange(10..<(10 + body.count), with: body)
  return out
}

/// writeTag(title, artist, album) -> 1024 bytes.
/// (id3.js names the first parameter `track`; it is the title.)
func writeTag(title: String, artist: String, album: String) throws -> [UInt8] {
  let frames = [
    frame("TIT2", title),
    frame("TPE1", artist),
    frame("TALB", album),
  ]
  let total = frames.reduce(0) { $0 + $1.count }
  var tag = [UInt8](repeating: 0, count: TAG_LEN)
  tag.replaceSubrange(0..<6, with: [0x49, 0x44, 0x33, 0x04, 0x00, 0x00]) // "ID3" v2.4
  tag.replaceSubrange(6..<10, with: syncsafe(TAG_LEN - 10))
  var off = 10
  for f in frames {
    tag.replaceSubrange(off..<(off + f.count), with: f)
    off += f.count
  }
  if 10 + total > TAG_LEN {
    throw DiscCoreError.message("tag overflow")
  }
  return tag
}
