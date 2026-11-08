// selftest.swift — command-line parity check for the Swift core.
//
//   ./selftest <path-to-reference-dir>
//
// Reads fixture.json + the track frames files from the reference
// directory, builds the disc with the Swift core, and compares
// the result byte-for-byte with expected.iso. Prints the MD5s,
// the sector counts, and either BYTE-IDENTICAL or the number and
// first offsets of differing bytes. Exit 0 only if identical.
//
// (Built via build-selftest.sh, which stages this file as
// main.swift — swiftc only allows top-level code in main.swift.)
import Foundation
import CryptoKit

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data(("selftest: " + msg + "\n").utf8))
  exit(1)
}

let args = CommandLine.arguments
if args.count < 2 {
  fail("usage: selftest <reference-dir>")
}
let refDir = args[1]

func refPath(_ name: String) -> String {
  (refDir as NSString).appendingPathComponent(name)
}
func refData(_ name: String) -> Data {
  do {
    return try Data(contentsOf: URL(fileURLWithPath: refPath(name)))
  } catch {
    fail("cannot read \(name): \(error)")
  }
}
func md5Hex(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

do {
  let fxData = refData("fixture.json")
  guard let fx = try JSONSerialization.jsonObject(with: fxData) as? [String: Any]
  else { fail("fixture.json is not a JSON object") }

  let discId = bytesFromHex(fx["discId"] as? String ?? "")
  let ivs = (fx["ivs"] as? [String] ?? []).map(bytesFromHex)

  var tracks: [DiscTrack] = []
  for t in fx["tracks"] as? [[String: Any]] ?? [] {
    tracks.append(DiscTrack(
      frames: [UInt8](refData(t["framesFile"] as? String ?? "")),
      title: t["title"] as? String ?? "",
      artist: t["artist"] as? String ?? "",
      album: t["album"] as? String ?? ""))
  }
  let groups = (fx["groups"] as? [[String: Any]] ?? []).map {
    DiscGroup(name: $0["name"] as? String ?? "",
              first: ($0["first"] as? NSNumber)?.intValue ?? 0,
              last: ($0["last"] as? NSNumber)?.intValue ?? 0)
  }
  let timestamp = DiscTimestamp(
    ms: (fx["timestampMs"] as? NSNumber)?.int64Value ?? 0,
    tzOffsetMinutes: (fx["tzOffsetMinutes"] as? NSNumber)?.intValue ?? 0)

  // verify.mjs calls buildDisc without capacitySectors, so the
  // JS default (360000) applies — the Swift default matches.
  let result = try buildDisc(tracks: tracks, groups: groups,
                             discId: discId, ivs: ivs,
                             timestamp: timestamp)
  let expected = [UInt8](refData("expected.iso"))
  let expectedMd5 = fx["expectedMd5"] as? String ?? ""
  let expectedSectors = (fx["expectedSectors"] as? NSNumber)?.intValue ?? -1

  print("Swift ISO md5:   \(md5Hex(Data(result.iso)))")
  print("expected md5:    \(expectedMd5)")
  print("sectors: \(result.stats.isoSectors) expected: \(expectedSectors)")
  print("bytes: \(result.iso.count) expected: \(expected.count)")

  // Smoke-check the reader half too (does not affect the verdict).
  if let parsed = try? parseAtracDisc(result.iso) {
    print("reader: \(parsed.trackCount) tracks, " +
          "\(parsed.groups.count) groups, \(parsed.totalSeconds)s total")
  } else {
    print("reader: WARNING — parseAtracDisc threw on the built ISO")
  }

  if result.iso.count != expected.count {
    print("LENGTH MISMATCH: \(result.iso.count) vs \(expected.count)")
    exit(1)
  }
  var diffs = 0
  for i in 0..<result.iso.count where result.iso[i] != expected[i] {
    if diffs < 5 {
      print("first diffs: offset \(i): \(result.iso[i]) vs \(expected[i])")
    }
    diffs += 1
  }
  print(diffs == 0 ? "BYTE-IDENTICAL ✓" : "\(diffs) differing bytes ✗")
  exit(diffs == 0 ? 0 : 1)
} catch {
  fail("\(error)")
}
