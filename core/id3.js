// The 1,024-byte ID3v2.4 tag at the head of every .ATP:
// frames TIT2, TPE1, TALB in order; text encoding 0x02 (UTF-16BE),
// clamped string + one NUL unit; syncsafe sizes; zero padding.
import { clampString, utf16be } from "./text.js";

export const TAG_LEN = 1024;

function syncsafe(n) {
  return Uint8Array.from([(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f]);
}

function frame(fid, text) {
  const textBytes = utf16be(clampString(text));
  const body = new Uint8Array(1 + textBytes.length + 2);
  body[0] = 0x02;
  body.set(textBytes, 1);
  const head = new Uint8Array(10);
  for (let i = 0; i < 4; i++) head[i] = fid.charCodeAt(i);
  head.set(syncsafe(body.length), 4);
  const out = new Uint8Array(10 + body.length);
  out.set(head, 0);
  out.set(body, 10);
  return out;
}

export function writeTag(track, artist, album) {
  const frames = [
    frame("TIT2", track),
    frame("TPE1", artist),
    frame("TALB", album),
  ];
  const total = frames.reduce((a, f) => a + f.length, 0);
  const tag = new Uint8Array(TAG_LEN);
  tag.set([0x49, 0x44, 0x33, 0x04, 0x00, 0x00], 0); // "ID3" v2.4
  tag.set(syncsafe(TAG_LEN - 10), 6);
  let off = 10;
  for (const f of frames) {
    tag.set(f, off);
    off += f.length;
  }
  if (10 + total > TAG_LEN) throw new Error("tag overflow");
  return tag;
}
