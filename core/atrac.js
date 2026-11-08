// The ATRAC CD recipe, proven on D-NE1 hardware 2026-11-03
// (discs 11, 12, 13). All constants below are the held,
// hardware-validated values; see the repo's breakthrough note.
//
// - Payload: DES-CBC encrypt the ATRAC3+ frames under the content
//   key d2[0:8], IV = the track header's InitVector, one chain.
// - BlockSeed (per track): two-key triple-DES EDE under V of
//   (DiscID[0:8] ^ DiscID[8:16]) ^ BE64(bindIndex+1) ^ d2[0:8],
//   bindIndex = the track's 0-based position in bind order.
// - ICV (TOC field): A = BE64(DiscID[0:8]), B = BE64(DiscID[8:16]);
//   X = A; for each track's full .ATP size s in order:
//   X = (X*s + B) mod 2^64; ICV = BE64(X). Unkeyed.
// - Registration papers: the genuine install's connum / track
//   slot / mgd, carried in every header.
import { desCbcEncrypt, edeEncryptBlock } from "./des.js";

export const D2 = Uint8Array.from(
  "3d14fb8d372a3b5b17010dbb4fd1b3fecf4a0570".match(/../g).map((h) => parseInt(h, 16))
);
export const V = Uint8Array.from(
  "3c8e092d257ffa7d3a3986d75b1b4c2b".match(/../g).map((h) => parseInt(h, 16))
);
export const CONNUM = Uint8Array.from([0x4f, 0x7e]);
export const TRACK_SLOT = Uint8Array.from([0xb4, 0xf3, 0x7f, 0xbb]);
export const MGD = Uint8Array.from(
  "2ad14387ddfb4b86".match(/../g).map((h) => parseInt(h, 16))
);
export const FRAME_SIZE = 376; // 64 kbps ATRAC3+ frame

function xor8(a, b) {
  const out = new Uint8Array(8);
  for (let i = 0; i < 8; i++) out[i] = a[i] ^ b[i];
  return out;
}

function be64(n) {
  // n: BigInt or number
  let x = BigInt(n);
  const out = new Uint8Array(8);
  for (let i = 7; i >= 0; i--) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}

export function blockSeed(discId, bindIndex) {
  const fold = xor8(discId.subarray(0, 8), discId.subarray(8, 16));
  const p = xor8(xor8(fold, be64(bindIndex + 1)), D2.subarray(0, 8));
  return edeEncryptBlock(V, p);
}

export function icv(discId, sizes) {
  const a = BigInt("0x" + [...discId.subarray(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join(""));
  const b = BigInt("0x" + [...discId.subarray(8, 16)].map((x) => x.toString(16).padStart(2, "0")).join(""));
  let x = a;
  const mask = (1n << 64n) - 1n;
  for (const s of sizes) x = (x * BigInt(s) + b) & mask;
  return be64(x);
}

export function encryptPayload(frames, iv) {
  return desCbcEncrypt(D2.subarray(0, 8), iv, frames);
}
