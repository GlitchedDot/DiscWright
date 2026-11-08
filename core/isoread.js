// Reading an authored ATRAC CD ISO back (GlitchedDot, 2026-11-05):
// Import ISO shows what is on an already-made disc -- its groups
// and tracks, titles included -- read-only. The layout facts are
// the mirror image of the writers (iso.js, sti.js, ndb.js), which
// were themselves cloned from genuine SonicStage discs, so this
// reads app-authored and genuine discs alike.
import { NDB_HEADER_LEN, NDB_RECORD_LEN } from "./ndb.js";

const SECTOR = 2048;

function u16le(b, o) { return b[o] | (b[o + 1] << 8); }
function u32le(b, o) {
  return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
}
function u16be(b, o) { return (b[o] << 8) | b[o + 1]; }
function u32be(b, o) {
  return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
}

// One directory's records: [{name, extent, size, isDir}].
// Records never cross a sector boundary; a zero length byte is
// padding to the next sector.
function readDir(bytes, extent, size) {
  const out = [];
  const start = extent * SECTOR;
  const end = start + size;
  let p = start;
  while (p < end) {
    const len = bytes[p];
    if (len === 0) {
      p = (Math.floor(p / SECTOR) + 1) * SECTOR;
      continue;
    }
    if (len < 34) break;
    const nameLen = bytes[p + 32];
    let name = "";
    for (let i = 0; i < nameLen; i++)
      name += String.fromCharCode(bytes[p + 33 + i]);
    out.push({
      name,
      extent: u32le(bytes, p + 2),
      size: u32le(bytes, p + 10),
      isDir: (bytes[p + 25] & 2) !== 0,
    });
    p += len;
  }
  return out;
}

// Map of "/PATH/FILE" (upper case, ";1" stripped) -> {extent, size}.
export function readIsoFiles(bytes) {
  const pvd = 16 * SECTOR;
  if (bytes.length < pvd + SECTOR || bytes[pvd] !== 1 ||
      String.fromCharCode(bytes[pvd + 1], bytes[pvd + 2], bytes[pvd + 3],
                          bytes[pvd + 4], bytes[pvd + 5]) !== "CD001")
    throw new Error("not an ISO 9660 image");
  const rootRec = pvd + 156;
  const files = new Map();
  const walk = (extent, size, prefix) => {
    for (const rec of readDir(bytes, extent, size)) {
      if (rec.name === "\x00" || rec.name === "\x01") continue;
      const path = prefix + "/" + rec.name.replace(/;1$/, "");
      if (rec.isDir) walk(rec.extent, rec.size, path);
      else files.set(path.toUpperCase(), { extent: rec.extent, size: rec.size });
    }
  };
  walk(u32le(bytes, rootRec + 2), u32le(bytes, rootRec + 10), "");
  return files;
}

function fileBytes(bytes, rec) {
  return bytes.subarray(rec.extent * SECTOR, rec.extent * SECTOR + rec.size);
}

// The NDB name tables: 256-byte header, then 128-byte records of
// 02 00 + UTF-16BE text. One string per track (or per group).
function readNdb(bytes) {
  if (!bytes || bytes.length < NDB_HEADER_LEN) return [];
  const count = u16be(bytes, 6);
  const out = [];
  for (let i = 0; i < count; i++) {
    const off = NDB_HEADER_LEN + i * NDB_RECORD_LEN;
    if (off + NDB_RECORD_LEN > bytes.length) break;
    if (bytes[off] !== 0x02) { out.push(""); continue; }
    let s = "";
    for (let j = 0; j < 30; j++) {
      const u = u16be(bytes, off + 2 + j * 2);
      if (u === 0) break;
      s += String.fromCharCode(u);
    }
    out.push(s);
  }
  return out;
}

// Parse an authored ATRAC disc image into
// { trackCount, totalSeconds,
//   groups: [{ name, tracks: [{title, artist, album, seconds, size}] }] }
// in disc order. Group ranges and per-track frame counts come
// from TOC00000.STI; the names from the NDB tables; sizes from
// the HIFI/ directory. Throws if the image is not an ATRAC disc.
export function parseAtracDisc(bytes) {
  const files = readIsoFiles(bytes);
  const tocRec = files.get("/TOC00000.STI");
  if (!tocRec) throw new Error("no TOC00000.STI — not an ATRAC CD image");
  const toc = fileBytes(bytes, tocRec);
  const groupCount = toc[9];
  const trackCount = u16be(toc, 10);
  const ranges = [];
  for (let k = 1; k <= groupCount; k++) {
    const off = 0x100 + k * 8;
    ranges.push({ first: u16be(toc, off), last: u16be(toc, off + 2) });
  }
  const get = (p) => {
    const r = files.get(p);
    return r ? fileBytes(bytes, r) : null;
  };
  const titles = readNdb(get("/TRACK.NDB"));
  const artists = readNdb(get("/ARTIST.NDB"));
  const albums = readNdb(get("/ALBUM.NDB"));
  const groupNames = readNdb(get("/GROUP.NDB"));
  const groups = ranges.map((r, gi) => ({
    name: groupNames[gi] || `Group ${gi + 1}`,
    tracks: [],
  }));
  let totalSeconds = 0;
  for (let i = 0; i < trackCount; i++) {
    const off = 0x900 + i * 16;
    const frames = u32be(toc, off + 12);
    const seconds = Math.trunc((frames * 2048) / 44100);
    totalSeconds += seconds;
    const num = i + 1;
    const fname = `/HIFI/TRK${num.toString(16).toUpperCase().padStart(5, "0")}.ATP`;
    const rec = files.get(fname);
    const t = {
      title: titles[i] || "",
      artist: artists[i] || "",
      album: albums[i] || "",
      seconds,
      size: rec ? rec.size : 0,
    };
    const gi = ranges.findIndex((r) => r.first <= num && num <= r.last);
    if (gi >= 0) groups[gi].tracks.push(t);
  }
  return { trackCount, totalSeconds, groups };
}
