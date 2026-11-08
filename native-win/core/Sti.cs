// Sti.cs — mirror of Sti.swift / sti.js: TOC00000.STI ("TOC ")
// and TOC00001.STI ("PLF "). The TOC's two per-disc fields are
// the recipe values: disc_id_a carries the ICV, disc_id_b the
// DiscID.
using System;
using System.Collections.Generic;

namespace DiscWright.Core;

public static class Sti
{
    public const int TocHeaderLen = 0x900;
    public const int PlfSize = 2176;
    private static readonly byte[] FormatMagic = { 0x01, 0x00, 0x28, 0x2e };
    private const int SamplesPerFrame = 2048;
    private const int SampleRate = 44100;

    /// <summary>
    /// FramesToSeconds(frames): trunc(frames * 2048 / 44100).
    /// JS computes in double; for any frame count a disc can
    /// hold, the product is far below 2^53, so the 64-bit
    /// integer computation matches.
    /// </summary>
    public static int FramesToSeconds(int frames)
        => (int)((frames * (long)SamplesPerFrame) / SampleRate);

    /// <summary>
    /// WriteToc: frameCounts per track, groups as (First, Last)
    /// 1-based inclusive pairs, icv 8 bytes, discId 16 bytes.
    /// </summary>
    public static byte[] WriteToc(IReadOnlyList<int> frameCounts,
                                  IReadOnlyList<(int First, int Last)> groups,
                                  byte[] icv, byte[] discId)
    {
        int n = frameCounts.Count;
        int totalSeconds = 0;
        foreach (int fc in frameCounts) totalSeconds += FramesToSeconds(fc);
        var outp = new byte[TocHeaderLen + n * 16];
        Array.Copy(new byte[] { 0x54, 0x4f, 0x43, 0x20 }, 0, outp, 0, 4); // "TOC "
        outp[4] = 1; // u32 LE version = 1 (bytes 5..7 stay 0)
        outp[8] = 1;
        outp[9] = (byte)groups.Count;
        outp[10] = (byte)((n >> 8) & 0xff);
        outp[11] = (byte)(n & 0xff);
        uint ts = unchecked((uint)totalSeconds);
        outp[12] = (byte)((ts >> 24) & 0xff);
        outp[13] = (byte)((ts >> 16) & 0xff);
        outp[14] = (byte)((ts >> 8) & 0xff);
        outp[15] = (byte)(ts & 0xff);
        Array.Copy(icv, 0, outp, 0x10, icv.Length);
        Array.Copy(discId, 0, outp, 0x20, discId.Length);
        for (int gi = 0; gi < groups.Count; gi++)
        {
            var g = groups[gi];
            int k = gi + 1;
            int off = 0x100 + k * 8;
            outp[off] = (byte)((g.First >> 8) & 0xff);
            outp[off + 1] = (byte)(g.First & 0xff);
            outp[off + 2] = (byte)((g.Last >> 8) & 0xff);
            outp[off + 3] = (byte)(g.Last & 0xff);
            outp[off + 4] = (byte)((k >> 8) & 0xff);
            outp[off + 5] = (byte)(k & 0xff);
        }
        for (int i = 0; i < frameCounts.Count; i++)
        {
            int fc = frameCounts[i];
            int num = i + 1;
            int group = -1;
            for (int gi = 0; gi < groups.Count; gi++)
            {
                if (groups[gi].First <= num && num <= groups[gi].Last)
                {
                    group = gi;
                    break;
                }
            }
            group += 1; // JS findIndex -> -1 when uncovered; +1 makes it 0
            if (group == 0)
                throw new DiscCoreException($"track {num} is not covered by any group");
            int off = TocHeaderLen + i * 16;
            outp[off] = (byte)((num >> 8) & 0xff);
            outp[off + 1] = (byte)(num & 0xff);
            outp[off + 2] = (byte)((num >> 8) & 0xff);
            outp[off + 3] = (byte)(num & 0xff);
            outp[off + 4] = (byte)group;
            Array.Copy(FormatMagic, 0, outp, off + 8, 4);
            uint f = unchecked((uint)fc);
            outp[off + 12] = (byte)((f >> 24) & 0xff);
            outp[off + 13] = (byte)((f >> 16) & 0xff);
            outp[off + 14] = (byte)((f >> 8) & 0xff);
            outp[off + 15] = (byte)(f & 0xff);
        }
        return outp;
    }

    /// <summary>WritePlf() -> 2176 bytes, "PLF " + version 1, rest zero.</summary>
    public static byte[] WritePlf()
    {
        var outp = new byte[PlfSize];
        Array.Copy(new byte[] { 0x50, 0x4c, 0x46, 0x20, 0x01 }, 0, outp, 0, 5);
        return outp;
    }
}
