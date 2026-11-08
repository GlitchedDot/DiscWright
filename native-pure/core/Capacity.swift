// Capacity.swift — mirror of capacity.js: the ISO's exact sector
// total (from the writer's own planner) plus the burn's session
// overhead must fit the blank, or the build is refused.
import Foundation

/// capacity.js re-exports iso.js's SECTOR.
let SECTOR = ISO_SECTOR
let SESSION_OVERHEAD_SECTORS = 150 + 2 + 11400 + 157 // 11,709

let BLANKS: [Int: String] = [
  360000: "12 cm 80 min",
  333000: "12 cm 74 min",
  108000: "8 cm pocket 24 min",
  94500: "8 cm pocket 21 min",
  405000: "12 cm 90 min (overburn)",
  445500: "12 cm 99 min (overburn)",
]

/// capacity.js's CapacityError (an Error subclass).
final class CapacityError: Error, CustomStringConvertible {
  let message: String
  init(_ message: String) { self.message = message }
  var description: String { message }
}

/// checkCapacity(fileSizes, capacitySectors) -> estimated sectors.
func checkCapacity(_ fileSizes: [String: Int],
                   _ capacitySectors: Int) throws -> Int {
  let est = isoSectorCount(fileSizes)
  if est + SESSION_OVERHEAD_SECTORS > capacitySectors {
    throw CapacityError(
      "ISO needs \(est) sectors + \(SESSION_OVERHEAD_SECTORS) session " +
      "overhead = \(est + SESSION_OVERHEAD_SECTORS), exceeds blank " +
      "capacity \(capacitySectors) sectors (\(BLANKS[capacitySectors] ?? "custom"))")
  }
  return est
}
