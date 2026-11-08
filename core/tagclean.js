// The tag-cleaning step, built in (GlitchedDot, 2026-11-05).
//
// cleanMp3() takes an MP3's bytes and returns a copy whose ONLY
// tag is ID3v1.1: the ID3v2 tag is stripped whole -- every frame,
// the album art included -- any old ID3v1 trailer is dropped, and
// a fresh 128-byte ID3v1.1 tag is written from the given fields.
// The audio bytes between the tags are carried over untouched.

// Total byte length of the leading ID3v2 tag (0 when absent).
// Handles the v2.4 footer flag (a second 10-byte header after the
// tag body); the size field is syncsafe and already covers any
// extended header.
export function id3v2Length(bytes) {
  if (bytes.length < 10 ||
      bytes[0] !== 0x49 || bytes[1] !== 0x44 || bytes[2] !== 0x33)
    return 0;
  const size = ((bytes[6] & 0x7f) << 21) | ((bytes[7] & 0x7f) << 14) |
    ((bytes[8] & 0x7f) << 7) | (bytes[9] & 0x7f);
  let total = 10 + size;
  if (bytes[3] === 4 && (bytes[5] & 0x10)) total += 10; // v2.4 footer
  return Math.min(total, bytes.length);
}

function hasId3v1Trailer(bytes) {
  const n = bytes.length;
  return n >= 128 &&
    bytes[n - 128] === 0x54 && bytes[n - 127] === 0x41 && bytes[n - 126] === 0x47;
}

function containsAscii(bytes, text) {
  outer: for (let i = 0; i + text.length <= bytes.length; i++) {
    for (let j = 0; j < text.length; j++)
      if (bytes[i + j] !== text.charCodeAt(j)) continue outer;
    return true;
  }
  return false;
}

// ID3v1 text is single-byte: Latin-1 where a character maps,
// "?" where it cannot. Truncation is by byte, like the real tag.
function putField(tag, offset, len, str) {
  const s = String(str ?? "");
  let n = 0;
  for (const ch of s) {
    if (n >= len) break;
    const cp = ch.codePointAt(0);
    tag[offset + n] = cp <= 0xff ? cp : 0x3f;
    n++;
  }
}

// The 128-byte ID3v1.1 trailer: "TAG", 30/30/30 title/artist/
// album, 4 year (left blank), 28 comment (blank), zero byte,
// track number, genre 0xFF (none).
export function buildId3v1({ title, artist, album, track }) {
  const tag = new Uint8Array(128);
  tag[0] = 0x54; tag[1] = 0x41; tag[2] = 0x47; // "TAG"
  putField(tag, 3, 30, title);
  putField(tag, 33, 30, artist);
  putField(tag, 63, 30, album);
  const trk = Number(track) || 0;
  if (trk >= 1 && trk <= 255) {
    tag[125] = 0;
    tag[126] = trk;
  }
  tag[127] = 0xff;
  return tag;
}

export function cleanMp3(bytes, fields) {
  const v2len = id3v2Length(bytes);
  const hadArt = v2len > 0 && containsAscii(bytes.subarray(0, v2len), "APIC");
  let end = bytes.length;
  if (hasId3v1Trailer(bytes)) end -= 128;
  const audio = bytes.subarray(v2len, Math.max(end, v2len));
  const out = new Uint8Array(audio.length + 128);
  out.set(audio, 0);
  out.set(buildId3v1(fields), audio.length);
  return { data: out, stripped: v2len > 0, hadArt };
}
