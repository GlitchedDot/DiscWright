// NDB databases (TRACK / ALBUM / ARTIST / GROUP / PLLIST).
// 256-byte header: "NDB " + 01 00 + BE u16 record count.
// 128-byte records: 02 00 + UTF-16BE string (max 30 units),
// zero padded. An empty string is an all-zero record.
import { clampString, utf16be } from "./text.js";

export const NDB_HEADER_LEN = 256;
export const NDB_RECORD_LEN = 128;

export function writeNdb(strings) {
  const out = new Uint8Array(NDB_HEADER_LEN + strings.length * NDB_RECORD_LEN);
  out.set([0x4e, 0x44, 0x42, 0x20, 0x01, 0x00], 0); // "NDB " + version
  out[6] = (strings.length >> 8) & 0xff;
  out[7] = strings.length & 0xff;
  strings.forEach((s, i) => {
    if (s === "") return; // all-zero record
    const off = NDB_HEADER_LEN + i * NDB_RECORD_LEN;
    out[off] = 0x02;
    out[off + 1] = 0x00;
    out.set(utf16be(clampString(s)), off + 2);
  });
  return out;
}
