// ISO 9660 writer, a faithful port of the Python author's iso.py:
// the layout matches what the original burner (Primo, under
// SonicStage) writes — system area zeroed, blank volume ids,
// L path table then M path table, directories first in path-table
// order, files grouped by parent in directory-record order.
//
// Timestamps: pass {ms, tzOffsetMinutes}. Directory records carry
// the local fields; the PVD stamps carry UTC digits; both carry
// the local offset byte (in 15-minute units) — same as the
// original, and independent of the machine's own time zone.

export const SECTOR = 2048;

const le16 = (n) => [n & 0xff, (n >> 8) & 0xff];
const be16 = (n) => [(n >> 8) & 0xff, n & 0xff];
const both16 = (n) => [...le16(n), ...be16(n)];
const le32 = (n) => [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >>> 24) & 0xff];
const be32 = (n) => [(n >>> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
const both32 = (n) => [...le32(n), ...be32(n)];

function timestamps(ts) {
  const ms = ts ? ts.ms : Date.now();
  const tzMin = ts ? ts.tzOffsetMinutes : -new Date(ms).getTimezoneOffset();
  const tz = Math.floor(tzMin / 15);
  const local = new Date(ms + tzMin * 60000);
  const utc = new Date(ms);
  const date7 = Uint8Array.from([
    local.getUTCFullYear() - 1900, local.getUTCMonth() + 1, local.getUTCDate(),
    local.getUTCHours(), local.getUTCMinutes(), local.getUTCSeconds(),
    tz & 0xff,
  ]);
  const p2 = (v) => String(v).padStart(2, "0");
  const digits =
    String(utc.getUTCFullYear()).padStart(4, "0") +
    p2(utc.getUTCMonth() + 1) + p2(utc.getUTCDate()) +
    p2(utc.getUTCHours()) + p2(utc.getUTCMinutes()) + p2(utc.getUTCSeconds()) +
    p2(Math.floor((ms % 1000) / 10));
  const pvd17 = new Uint8Array(17);
  for (let i = 0; i < 16; i++) pvd17[i] = digits.charCodeAt(i);
  pvd17[16] = tz & 0xff;
  return { date7, pvd17 };
}

function dirRecord(extent, size, isDir, date7, name) {
  const nlen = name.length;
  let total = 33 + nlen;
  if (total % 2) total += 1;
  const rec = new Uint8Array(total);
  rec[0] = total;
  rec.set(both32(extent), 2);
  rec.set(both32(size), 10);
  rec.set(date7, 18);
  rec[25] = isDir ? 2 : 0;
  rec.set(both16(1), 28);
  rec[32] = nlen;
  rec.set(name, 33);
  return rec;
}

const cmpBytes = (a, b) => {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
};
const ascii = (s) => Uint8Array.from([...s].map((c) => c.charCodeAt(0)));

class Dir {
  constructor(path, name, parent) {
    this.path = path;
    this.name = name;
    this.parent = parent;
    this.files = []; // {ident, path, size}
    this.subdirs = [];
    this.extent = 0;
    this.size = 0;
    this.index = 0;
  }
}

function buildTree(sizes) {
  const root = new Dir("", Uint8Array.from([0]), null);
  const dirs = new Map([["", root]]);
  for (const path of [...sizes.keys()].sort()) {
    const parts = path.split("/").filter((p) => p);
    let parent = root;
    let cur = "";
    for (const part of parts.slice(0, -1)) {
      cur += "/" + part;
      if (!dirs.has(cur)) {
        const d = new Dir(cur, ascii(part), parent);
        dirs.set(cur, d);
        parent.subdirs.push(d);
      }
      parent = dirs.get(cur);
    }
    const ident = ascii(parts[parts.length - 1] + ";1");
    parent.files.push({ ident, path, size: sizes.get(path) });
  }
  for (const d of dirs.values()) {
    d.files.sort((a, b) => cmpBytes(a.ident, b.ident));
    d.subdirs.sort((a, b) => cmpBytes(a.name, b.name));
  }
  return root;
}

function dirOrder(root) {
  const order = [root];
  let i = 0;
  while (i < order.length) {
    order.push(...[...order[i].subdirs].sort((a, b) => cmpBytes(a.name, b.name)));
    i++;
  }
  order.forEach((d, n) => (d.index = n + 1));
  return order;
}

function dirDataSize(d) {
  const idents = [Uint8Array.from([0]), Uint8Array.from([1]),
    ...d.subdirs.map((sd) => sd.name), ...d.files.map((f) => f.ident)]
    .sort(cmpBytes);
  let pos = 0;
  for (const ident of idents) {
    let ln = 33 + ident.length;
    if (ln % 2) ln += 1;
    if ((pos % SECTOR) + ln > SECTOR) pos += SECTOR - (pos % SECTOR);
    pos += ln;
  }
  return Math.ceil(pos / SECTOR) * SECTOR;
}

function pathTables(order) {
  const lt = [];
  const mt = [];
  for (const d of order) {
    const name = d.parent === null ? Uint8Array.from([0]) : d.name;
    const parentIdx = d.parent === null ? d.index : d.parent.index;
    const pad = name.length % 2 ? [0] : [];
    lt.push(name.length, 0, ...le32(d.extent), ...le16(parentIdx), ...name, ...pad);
    mt.push(name.length, 0, ...be32(d.extent), ...be16(parentIdx), ...name, ...pad);
  }
  return [Uint8Array.from(lt), Uint8Array.from(mt)];
}

function plan(sizes) {
  const root = buildTree(sizes);
  const order = dirOrder(root);
  for (const d of order) d.size = dirDataSize(d);
  let [lt, mt] = pathTables(order); // extents 0; lengths final
  const ltSec = Math.ceil(lt.length / SECTOR);
  const mtSec = Math.ceil(mt.length / SECTOR);
  let nxt = 16 + 2 + ltSec + mtSec;
  for (const d of order) {
    d.extent = nxt;
    nxt += d.size / SECTOR;
  }
  const fileExtents = new Map();
  for (const d of order) {
    for (const f of d.files) {
      fileExtents.set(f.path, nxt);
      nxt += Math.ceil(f.size / SECTOR);
    }
  }
  [lt, mt] = pathTables(order);
  return { order, lt, mt, fileExtents, total: nxt };
}

export function isoSectorCount(sizes) {
  return plan(sizes).total;
}

function dirBytes(d, fileExtents, date7) {
  const parent = d.parent !== null ? d.parent : d;
  const records = [
    { ident: Uint8Array.from([0]), ext: d.extent, size: d.size, isDir: true },
    { ident: Uint8Array.from([1]), ext: parent.extent, size: parent.size, isDir: true },
  ];
  const kids = [
    ...d.subdirs.map((sd) => ({ ident: sd.name, ext: sd.extent, size: sd.size, isDir: true })),
    ...d.files.map((f) => ({ ident: f.ident, ext: fileExtents.get(f.path), size: f.size, isDir: false })),
  ].sort((a, b) => cmpBytes(a.ident, b.ident));
  records.push(...kids);
  const out = new Uint8Array(d.size);
  let len = 0;
  for (const r of records) {
    const rec = dirRecord(r.ext, r.size, r.isDir, date7, r.ident);
    if ((len % SECTOR) + rec.length > SECTOR) len += SECTOR - (len % SECTOR);
    out.set(rec, len);
    len += rec.length;
  }
  return out;
}

// files: Map<string path, Uint8Array>. Returns the ISO bytes.
export function writeIso(files, { volIdent = "", timestamp = null } = {}) {
  const sizes = new Map([...files.entries()].map(([p, d]) => [p, d.length]));
  const { order, lt, mt, fileExtents, total } = plan(sizes);
  const { date7, pvd17 } = timestamps(timestamp);
  const root = order[0];
  const img = new Uint8Array(total * SECTOR);

  const pvd = new Uint8Array(SECTOR);
  pvd[0] = 1;
  pvd.set(ascii("CD001"), 1);
  pvd[6] = 1;
  pvd.fill(0x20, 8, 40);
  const ident = ascii(volIdent).subarray(0, 32);
  pvd.fill(0x20, 40, 72);
  pvd.set(ident, 40);
  pvd.set(both32(total), 80);
  pvd.set(both16(1), 120);
  pvd.set(both16(1), 124);
  pvd.set(both16(SECTOR), 128);
  pvd.set(both32(lt.length), 132);
  pvd.set(le32(18), 140);
  pvd.set(be32(18 + Math.ceil(lt.length / SECTOR)), 148);
  pvd.set(dirRecord(root.extent, root.size, true, date7, Uint8Array.from([0])), 156);
  for (const off of [190, 318, 446, 574]) pvd.fill(0x20, off, off + 128);
  for (const off of [702, 739, 776]) pvd.fill(0x20, off, off + 37);
  for (const off of [813, 830, 847, 864]) pvd.set(pvd17, off);
  pvd[881] = 1;
  img.set(pvd, 16 * SECTOR);

  const term = new Uint8Array(SECTOR);
  term[0] = 255;
  term.set(ascii("CD001"), 1);
  term[6] = 1;
  img.set(term, 17 * SECTOR);

  img.set(lt, 18 * SECTOR);
  img.set(mt, (18 + Math.ceil(lt.length / SECTOR)) * SECTOR);

  for (const d of order) {
    img.set(dirBytes(d, fileExtents, date7), d.extent * SECTOR);
  }
  for (const [path, data] of files) {
    img.set(data, fileExtents.get(path) * SECTOR);
  }
  return img;
}
