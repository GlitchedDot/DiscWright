// String handling matching the Python author byte-for-byte:
// strings are clamped to 30 UTF-16 code units (astral characters
// count 2 and are kept or dropped whole; lone surrogates become
// U+FFFD) and encoded UTF-16BE.

export const MAX_STRING_UNITS = 30;

export function clampString(s) {
  let out = "";
  let units = 0;
  for (const ch of s) {
    let cp = ch.codePointAt(0);
    let c = ch;
    if (cp >= 0xd800 && cp <= 0xdfff) {
      c = "\ufffd";
      cp = 0xfffd;
    }
    const n = cp > 0xffff ? 2 : 1;
    if (units + n > MAX_STRING_UNITS) break;
    out += c;
    units += n;
  }
  return out;
}

export function utf16be(s) {
  const bytes = [];
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (cp > 0xffff) {
      const v = cp - 0x10000;
      const hi = 0xd800 + (v >> 10);
      const lo = 0xdc00 + (v & 0x3ff);
      bytes.push((hi >> 8) & 0xff, hi & 0xff, (lo >> 8) & 0xff, lo & 0xff);
    } else {
      bytes.push((cp >> 8) & 0xff, cp & 0xff);
    }
  }
  return Uint8Array.from(bytes);
}
