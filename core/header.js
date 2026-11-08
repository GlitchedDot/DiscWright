// The 96-byte secure header at .ATP offset 1024.
// Layout per the Python author's measured map (see secure_header.py).
export const HEADER_LEN = 96;
const FORMAT_MAGIC = [0x01, 0x00, 0x28, 0x2e];
const BLOCK_PARAMS = [0x01, 0x0f, 0x50, 0x00, 0x00, 0x04, 0x00, 0x00];
const CONNUM_TAIL = [0x16, 0x72, 0x5f, 0x9b, 0xe7];
const EKB_VERSION = 0x0001000e;

// fields: {frameCount, blockSeed(8), initVector(8), connum(2),
//          trackSlot(4), mgd(8)}
export function headerToBytes(h) {
  const out = new Uint8Array(HEADER_LEN);
  out.set(FORMAT_MAGIC, 0x00);
  out[0x04] = (h.frameCount >>> 24) & 0xff;
  out[0x05] = (h.frameCount >>> 16) & 0xff;
  out[0x06] = (h.frameCount >>> 8) & 0xff;
  out[0x07] = h.frameCount & 0xff;
  out[0x10] = (EKB_VERSION >>> 24) & 0xff;
  out[0x11] = (EKB_VERSION >>> 16) & 0xff;
  out[0x12] = (EKB_VERSION >>> 8) & 0xff;
  out[0x13] = EKB_VERSION & 0xff;
  out.set(h.blockSeed, 0x18);
  out.set(BLOCK_PARAMS, 0x20);
  out[0x28] = 0;
  out.set(h.connum, 0x29);
  out.set(CONNUM_TAIL, 0x2b);
  out.set(h.trackSlot, 0x30);
  out.set([0x41, 0x54, 0x58, 0x20], 0x40); // "ATX "
  out.set(h.mgd, 0x50);
  out.set(h.initVector, 0x58);
  return out;
}
