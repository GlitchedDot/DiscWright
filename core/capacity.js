// Capacity accountant, ported from the Python author: the ISO's
// exact sector total (from the writer's own planner) plus the
// burn's session overhead must fit the blank, or the build is
// refused.
import { isoSectorCount, SECTOR } from "./iso.js";

export { SECTOR };
export const SESSION_OVERHEAD_SECTORS = 150 + 2 + 11400 + 157; // 11,709

export const BLANKS = new Map([
  [360000, "12 cm 80 min"],
  [333000, "12 cm 74 min"],
  [108000, "8 cm pocket 24 min"],
  [94500, "8 cm pocket 21 min"],
  [405000, "12 cm 90 min (overburn)"],
  [445500, "12 cm 99 min (overburn)"],
]);

export class CapacityError extends Error {}

export function checkCapacity(fileSizes, capacitySectors) {
  const est = isoSectorCount(fileSizes);
  if (est + SESSION_OVERHEAD_SECTORS > capacitySectors) {
    throw new CapacityError(
      `ISO needs ${est} sectors + ${SESSION_OVERHEAD_SECTORS} session ` +
      `overhead = ${est + SESSION_OVERHEAD_SECTORS}, exceeds blank ` +
      `capacity ${capacitySectors} sectors (${BLANKS.get(capacitySectors) ?? "custom"})`
    );
  }
  return est;
}
