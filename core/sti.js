// STI files: TOC00000.STI ("TOC ") and TOC00001.STI ("PLF ").
// In this implementation the TOC's two per-disc fields are the
// recipe values: disc_id_a carries the ICV, disc_id_b the DiscID.
export const TOC_HEADER_LEN = 0x900;
export const PLF_SIZE = 2176;
const FORMAT_MAGIC = [0x01, 0x00, 0x28, 0x2e];
const SAMPLES_PER_FRAME = 2048;
const SAMPLE_RATE = 44100;

export function framesToSeconds(frames) {
  return Math.trunc((frames * SAMPLES_PER_FRAME) / SAMPLE_RATE);
}

// spec: {frameCounts: number[], groups: [[first,last],...] (1-based
// inclusive), icv: Uint8Array(8), discId: Uint8Array(16)}
export function writeToc(spec) {
  const n = spec.frameCounts.length;
  const totalSeconds = spec.frameCounts.reduce((a, fc) => a + framesToSeconds(fc), 0);
  const out = new Uint8Array(TOC_HEADER_LEN + n * 16);
  out.set([0x54, 0x4f, 0x43, 0x20], 0); // "TOC "
  out[4] = 1; // u32 LE version = 1 (bytes 5..7 stay 0)
  out[8] = 1;
  out[9] = spec.groups.length;
  out[10] = (n >> 8) & 0xff;
  out[11] = n & 0xff;
  out[12] = (totalSeconds >>> 24) & 0xff;
  out[13] = (totalSeconds >>> 16) & 0xff;
  out[14] = (totalSeconds >>> 8) & 0xff;
  out[15] = totalSeconds & 0xff;
  out.set(spec.icv, 0x10);
  out.set(spec.discId, 0x20);
  spec.groups.forEach(([first, last], gi) => {
    const k = gi + 1;
    const off = 0x100 + k * 8;
    out[off] = (first >> 8) & 0xff;
    out[off + 1] = first & 0xff;
    out[off + 2] = (last >> 8) & 0xff;
    out[off + 3] = last & 0xff;
    out[off + 4] = (k >> 8) & 0xff;
    out[off + 5] = k & 0xff;
  });
  spec.frameCounts.forEach((fc, i) => {
    const num = i + 1;
    const group = spec.groups.findIndex(([a, b]) => a <= num && num <= b) + 1;
    if (group === 0) throw new Error(`track ${num} is not covered by any group`);
    const off = TOC_HEADER_LEN + i * 16;
    out[off] = (num >> 8) & 0xff;
    out[off + 1] = num & 0xff;
    out[off + 2] = (num >> 8) & 0xff;
    out[off + 3] = num & 0xff;
    out[off + 4] = group;
    out.set(FORMAT_MAGIC, off + 8);
    out[off + 12] = (fc >>> 24) & 0xff;
    out[off + 13] = (fc >>> 16) & 0xff;
    out[off + 14] = (fc >>> 8) & 0xff;
    out[off + 15] = fc & 0xff;
  });
  return out;
}

export function writePlf() {
  const out = new Uint8Array(PLF_SIZE);
  out.set([0x50, 0x4c, 0x46, 0x20, 0x01], 0); // "PLF " + version 1
  return out;
}
