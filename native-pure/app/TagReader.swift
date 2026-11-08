// TagReader.swift — reading an audio file's tags, a port of the
// web app's tagsFor path (app.js): ID3v2 TIT2/TPE1/TALB first
// (v2.3 plain sizes, v2.4 syncsafe frame sizes; text encodings
// 0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8), then the
// ID3v1 trailer, then a filename fallback for the title
// (extension dropped, underscores become spaces).

import Foundation

struct AudioTags {
  var title: String = ""
  var artist: String = ""
  var album: String = ""
}

enum TagReader {

  /// Read a file's tags. Throws only when the file itself cannot
  /// be read (the web app's addFile catch sets the track error).
  static func tags(forFileAt url: URL) throws -> AudioTags {
    let data = try Data(contentsOf: url)
    return tags(bytes: [UInt8](data), fileName: url.lastPathComponent)
  }

  /// tagsFor(bytes, fileName), mirrored from app.js.
  static func tags(bytes: [UInt8], fileName: String) -> AudioTags {
    var tags = parseV2(bytes) ?? parseV1(bytes) ?? AudioTags()
    if tags.title.isEmpty {
      var base = fileName
      // JS: fileName.replace(/\.[^.]+$/, "")
      if let dot = base.lastIndex(of: "."),
         base.lastIndex(of: "/").map({ $0 < dot }) ?? true {
        base = String(base[..<dot])
      }
      tags.title = base.replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespaces)
    }
    return tags
  }

  // ---- ID3v1 ----

  private static func latin1(_ bytes: ArraySlice<UInt8>) -> String {
    // JS latin1(): one Latin-1 char per byte, trailing NUL/space
    // run stripped, then trim().
    let s = String(bytes: bytes, encoding: .isoLatin1) ?? ""
    var out = s
    while let last = out.last, last == "\0" || last == " " { out.removeLast() }
    return out.trimmingCharacters(in: .whitespaces)
  }

  static func parseV1(_ bytes: [UInt8]) -> AudioTags? {
    guard bytes.count >= 128 else { return nil }
    let t = Array(bytes[(bytes.count - 128)..<bytes.count])
    guard t[0] == 0x54, t[1] == 0x41, t[2] == 0x47 else { return nil } // "TAG"
    return AudioTags(title: latin1(t[3..<33]),
                     artist: latin1(t[33..<63]),
                     album: latin1(t[63..<93]))
  }

  // ---- ID3v2 ----

  private static func decodeText(enc: UInt8, body: [UInt8]) -> String {
    let s: String
    switch enc {
    case 0:
      s = String(bytes: body, encoding: .isoLatin1) ?? ""
    case 1:
      s = decodeUTF16WithBOM(body)
    case 2:
      s = decodeUTF16(body, bigEndian: true)
    default:
      s = String(decoding: body, as: UTF8.self)
    }
    // JS: replace(/\0+$/, "").trim()
    var out = s
    while out.last == "\0" { out.removeLast() }
    return out.trimmingCharacters(in: .whitespaces)
  }

  /// TextDecoder "utf-16": little-endian unless a BOM says
  /// otherwise; the BOM is consumed.
  private static func decodeUTF16WithBOM(_ body: [UInt8]) -> String {
    var b = body
    var bigEndian = false
    if b.count >= 2 && b[0] == 0xfe && b[1] == 0xff {
      bigEndian = true
      b = Array(b.dropFirst(2))
    } else if b.count >= 2 && b[0] == 0xff && b[1] == 0xfe {
      b = Array(b.dropFirst(2))
    }
    return decodeUTF16(b, bigEndian: bigEndian)
  }

  private static func decodeUTF16(_ body: [UInt8], bigEndian: Bool) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(body.count / 2)
    var i = 0
    while i + 1 < body.count {
      if bigEndian {
        units.append((UInt16(body[i]) << 8) | UInt16(body[i + 1]))
      } else {
        units.append(UInt16(body[i]) | (UInt16(body[i + 1]) << 8))
      }
      i += 2
    }
    return String(decoding: units, as: UTF16.self)
  }

  static func parseV2(_ bytes: [UInt8]) -> AudioTags? {
    guard bytes.count >= 10,
          bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 // "ID3"
    else { return nil }
    let ver = bytes[3]
    let size = (Int(bytes[6] & 0x7f) << 21) | (Int(bytes[7] & 0x7f) << 14) |
      (Int(bytes[8] & 0x7f) << 7) | Int(bytes[9] & 0x7f)
    var out = AudioTags()
    var hasTitle = false
    var pos = 10
    let end = min(bytes.count, 10 + size)
    while pos + 10 <= end {
      let idBytes = bytes[pos..<(pos + 4)]
      // JS: /^[A-Z0-9]{4}$/ or the frame walk stops.
      guard idBytes.allSatisfy({
        ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39)
      }) else { break }
      let id = String(decoding: idBytes, as: UTF8.self)
      let r0 = Int(bytes[pos + 4]), r1 = Int(bytes[pos + 5])
      let r2 = Int(bytes[pos + 6]), r3 = Int(bytes[pos + 7])
      let fsize = ver == 4
        ? ((r0 & 0x7f) << 21) | ((r1 & 0x7f) << 14) | ((r2 & 0x7f) << 7) | (r3 & 0x7f)
        : (r0 << 24) | (r1 << 16) | (r2 << 8) | r3
      let bodyStart = pos + 10
      let bodyEnd = min(bytes.count, bodyStart + max(0, fsize))
      let body = bodyStart < bodyEnd ? Array(bytes[bodyStart..<bodyEnd]) : []
      if body.count > 1 {
        switch id {
        case "TIT2":
          out.title = decodeText(enc: body[0], body: Array(body.dropFirst()))
          hasTitle = true
        case "TPE1":
          out.artist = decodeText(enc: body[0], body: Array(body.dropFirst()))
        case "TALB":
          out.album = decodeText(enc: body[0], body: Array(body.dropFirst()))
        default:
          break
        }
      }
      pos += 10 + fsize
    }
    // JS returns the object only if a TIT2 frame was present.
    return hasTitle ? out : nil
  }
}
