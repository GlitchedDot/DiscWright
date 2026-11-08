// Disc orchestration with the hardware-proven recipe built in:
// track list in -> complete file tree -> capacity-checked ISO out.
//
// buildDisc({
//   tracks: [{frames: Uint8Array, title, artist, album, frameSize?}],
//   groups: [{name, first, last}]  // 1-based inclusive; default one
//                                  // group "New Group" with all tracks
//   discId: Uint8Array(16),        // app-generated (crypto random)
//   ivs: [Uint8Array(8)],          // one per track, app-generated
//   capacitySectors: 360000,
//   timestamp: {ms, tzOffsetMinutes},
// }) -> {iso, files, stats}
//
// Every track's payload is DES-CBC encrypted under the genuine
// content key; every header carries its computed BlockSeed and the
// genuine registration papers; the TOC carries the folded ICV and
// the DiscID. Mirrors the Python author + the disc-11/12/13 build
// scripts, and is byte-verified against them.
import { writeNdb } from "./ndb.js";
import { writeTag } from "./id3.js";
import { headerToBytes } from "./header.js";
import { writeToc, writePlf } from "./sti.js";
import { STK_BYTES, STK_FILENAME } from "./stk.js";
import { writeIso } from "./iso.js";
import { checkCapacity } from "./capacity.js";
import { blockSeed, icv, encryptPayload, CONNUM, TRACK_SLOT, MGD, FRAME_SIZE } from "./atrac.js";

export const ATP_OVERHEAD = 1120; // 1024 ID3 + 96 secure header

export function trackFilename(number) {
  if (!(number >= 1 && number <= 0xfffff)) throw new Error("track number out of range");
  return "TRK" + number.toString(16).toUpperCase().padStart(5, "0") + ".ATP";
}

export function buildDisc(opts) {
  const tracks = opts.tracks;
  if (!tracks || tracks.length === 0) throw new Error("no tracks");
  const groups = opts.groups ?? [{ name: "New Group", first: 1, last: tracks.length }];
  const discId = opts.discId;
  const ivs = opts.ivs;
  if (!discId || discId.length !== 16) throw new Error("discId must be 16 bytes");
  if (!ivs || ivs.length !== tracks.length) throw new Error("one IV per track required");

  const files = new Map();
  const frameCounts = [];
  tracks.forEach((t, i) => {
    const frameSize = t.frameSize ?? FRAME_SIZE;
    if (t.frames.length % frameSize !== 0)
      throw new Error(`track ${i + 1}: payload is not a whole number of frames`);
    const frameCount = t.frames.length / frameSize;
    const header = headerToBytes({
      frameCount,
      blockSeed: blockSeed(discId, i),
      initVector: ivs[i],
      connum: CONNUM,
      trackSlot: TRACK_SLOT,
      mgd: MGD,
    });
    const atp = new Uint8Array(ATP_OVERHEAD + t.frames.length);
    atp.set(writeTag(t.title, t.artist, t.album), 0);
    atp.set(header, 1024);
    atp.set(encryptPayload(t.frames, ivs[i]), ATP_OVERHEAD);
    files.set("/HIFI/" + trackFilename(i + 1), atp);
    frameCounts.push(frameCount);
  });

  files.set("/TRACK.NDB", writeNdb(tracks.map((t) => t.title)));
  files.set("/ALBUM.NDB", writeNdb(tracks.map((t) => t.album)));
  files.set("/ARTIST.NDB", writeNdb(tracks.map((t) => t.artist)));
  files.set("/GROUP.NDB", writeNdb(groups.map((g) => g.name)));
  files.set("/PLLIST.NDB", writeNdb([]));

  const sizes = tracks.map((t) => ATP_OVERHEAD + t.frames.length);
  const toc = writeToc({
    frameCounts,
    groups: groups.map((g) => [g.first, g.last]),
    icv: icv(discId, sizes),
    discId,
  });
  files.set("/TOC00000.STI", toc);
  files.set("/TOC00001.STI", writePlf());
  files.set("/" + STK_FILENAME, STK_BYTES);

  const capacitySectors = opts.capacitySectors ?? 360000;
  const sizeMap = new Map([...files.entries()].map(([p, d]) => [p, d.length]));
  const estSectors = checkCapacity(sizeMap, capacitySectors);
  const iso = writeIso(files, { timestamp: opts.timestamp ?? null });
  const exactSectors = Math.ceil(iso.length / 2048);
  if (exactSectors + 11709 > capacitySectors)
    throw new Error("built ISO exceeds blank capacity");

  return {
    iso,
    files,
    stats: {
      isoBytes: iso.length,
      isoSectors: exactSectors,
      estimatedSectors: estSectors,
      capacitySectors,
      trackCount: tracks.length,
    },
  };
}
