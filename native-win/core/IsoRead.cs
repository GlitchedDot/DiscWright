// IsoRead.cs — mirror of IsoRead.swift / isoread.js: reading
// an authored ATRAC CD ISO back. The layout facts are the
// mirror image of the writers, cloned from genuine SonicStage
// discs, so this reads app-authored and genuine discs alike.
using System;
using System.Collections.Generic;
using System.Text;

namespace DiscWright.Core;

/// <summary>One file's location in the image (isoread.js's {extent, size}).</summary>
public sealed class IsoFileRec
{
    public int Extent;
    public int Size;
}

/// <summary>A track read back from a disc (isoread.js's track objects).</summary>
public sealed class ParsedTrack
{
    public string Title = "";
    public string Artist = "";
    public string Album = "";
    public int Seconds;
    public int Size;
}

/// <summary>A group read back from a disc.</summary>
public sealed class ParsedGroup
{
    public string Name = "";
    public List<ParsedTrack> Tracks = new();
}

/// <summary>ParseAtracDisc's result.</summary>
public sealed class ParsedDisc
{
    public int TrackCount;
    public int TotalSeconds;
    public List<ParsedGroup> Groups = new();
}

public static class IsoRead
{
    private const int ReadSector = 2048;

    private static int U16Le(byte[] b, int o) => b[o] | (b[o + 1] << 8);
    private static int U32Le(byte[] b, int o)
        => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
    private static int U16Be(byte[] b, int o) => (b[o] << 8) | b[o + 1];
    private static int U32Be(byte[] b, int o)
        => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

    private sealed class DirRec
    {
        public string Name = "";
        public int Extent;
        public int Size;
        public bool IsDir;
    }

    // One directory's records. Records never cross a sector
    // boundary; a zero length byte is padding to the next sector.
    private static List<DirRec> ReadDir(byte[] bytes, int extent, int size)
    {
        var outp = new List<DirRec>();
        int start = extent * ReadSector;
        int end = start + size;
        int p = start;
        while (p < end)
        {
            int len = bytes[p];
            if (len == 0)
            {
                p = (p / ReadSector + 1) * ReadSector;
                continue;
            }
            if (len < 34) break;
            int nameLen = bytes[p + 32];
            // JS: String.fromCharCode(byte) — a Latin-1 unit per
            // byte; Encoding.Latin1 is exactly that mapping.
            string name = Encoding.Latin1.GetString(bytes, p + 33, nameLen);
            outp.Add(new DirRec
            {
                Name = name,
                Extent = U32Le(bytes, p + 2),
                Size = U32Le(bytes, p + 10),
                IsDir = (bytes[p + 25] & 2) != 0,
            });
            p += len;
        }
        return outp;
    }

    private static void WalkIsoDir(byte[] bytes, int extent, int size,
                                   string prefix,
                                   Dictionary<string, IsoFileRec> files)
    {
        foreach (DirRec rec in ReadDir(bytes, extent, size))
        {
            if (rec.Name == "\u0000" || rec.Name == "\u0001") continue;
            string path = prefix + "/" + rec.Name;
            if (path.EndsWith(";1", StringComparison.Ordinal))
                path = path.Substring(0, path.Length - 2);
            if (rec.IsDir)
            {
                WalkIsoDir(bytes, rec.Extent, rec.Size, path, files);
            }
            else
            {
                files[path.ToUpperInvariant()] =
                    new IsoFileRec { Extent = rec.Extent, Size = rec.Size };
            }
        }
    }

    /// <summary>
    /// ReadIsoFiles(bytes): map of "/PATH/FILE" (upper case,
    /// ";1" stripped) -> {extent, size}. Throws if not an
    /// ISO 9660 image.
    /// </summary>
    public static Dictionary<string, IsoFileRec> ReadIsoFiles(byte[] bytes)
    {
        int pvd = 16 * ReadSector;
        if (!(bytes.Length >= pvd + ReadSector && bytes[pvd] == 1 &&
              bytes[pvd + 1] == 0x43 && bytes[pvd + 2] == 0x44 && // "CD001"
              bytes[pvd + 3] == 0x30 && bytes[pvd + 4] == 0x30 &&
              bytes[pvd + 5] == 0x31))
        {
            throw new DiscCoreException("not an ISO 9660 image");
        }
        int rootRec = pvd + 156;
        var files = new Dictionary<string, IsoFileRec>();
        WalkIsoDir(bytes, U32Le(bytes, rootRec + 2), U32Le(bytes, rootRec + 10),
                   "", files);
        return files;
    }

    private static byte[] FileBytes(byte[] bytes, IsoFileRec rec)
    {
        int start = rec.Extent * ReadSector;
        var outp = new byte[rec.Size];
        Array.Copy(bytes, start, outp, 0, rec.Size);
        return outp;
    }

    // The NDB name tables: 256-byte header, then 128-byte
    // records of 02 00 + UTF-16BE text. One string per track
    // (or per group). The JS collects UTF-16 units via
    // String.fromCharCode and lets surrogate pairs re-form
    // astral characters in the string; the C# collects the same
    // units as char[] — a C# char IS a UTF-16 code unit, so the
    // pair re-forms identically (and a lone surrogate stays a
    // lone surrogate, as in JS; see NOTES.md trap 8).
    private static List<string> ReadNdb(byte[]? bytes)
    {
        var outp = new List<string>();
        if (bytes == null || bytes.Length < Ndb.NdbHeaderLen) return outp;
        int count = U16Be(bytes, 6);
        for (int i = 0; i < count; i++)
        {
            int off = Ndb.NdbHeaderLen + i * Ndb.NdbRecordLen;
            if (off + Ndb.NdbRecordLen > bytes.Length) break;
            if (bytes[off] != 0x02) { outp.Add(""); continue; }
            var units = new List<char>();
            for (int j = 0; j < 30; j++)
            {
                int u = U16Be(bytes, off + 2 + j * 2);
                if (u == 0) break;
                units.Add((char)u);
            }
            outp.Add(new string(units.ToArray()));
        }
        return outp;
    }

    private static string AtString(List<string> arr, int i)
        => i < arr.Count ? arr[i] : "";

    private static string ReaderTrackFilename(int num)
    {
        string h = num.ToString("X");
        while (h.Length < 5) h = "0" + h;
        return "/HIFI/TRK" + h + ".ATP";
    }

    /// <summary>
    /// ParseAtracDisc(bytes): group ranges and per-track frame
    /// counts from TOC00000.STI; names from the NDB tables;
    /// sizes from the HIFI/ directory. Throws if not an ATRAC
    /// disc.
    /// </summary>
    public static ParsedDisc ParseAtracDisc(byte[] bytes)
    {
        Dictionary<string, IsoFileRec> files = ReadIsoFiles(bytes);
        if (!files.TryGetValue("/TOC00000.STI", out IsoFileRec? tocRec))
            throw new DiscCoreException("no TOC00000.STI — not an ATRAC CD image");
        byte[] toc = FileBytes(bytes, tocRec);
        int groupCount = toc[9];
        int trackCount = U16Be(toc, 10);
        var ranges = new List<(int First, int Last)>();
        if (groupCount > 0)
        {
            for (int k = 1; k <= groupCount; k++)
            {
                int off = 0x100 + k * 8;
                ranges.Add((U16Be(toc, off), U16Be(toc, off + 2)));
            }
        }
        byte[]? Get(string p)
            => files.TryGetValue(p, out IsoFileRec? r) ? FileBytes(bytes, r) : null;
        List<string> titles = ReadNdb(Get("/TRACK.NDB"));
        List<string> artists = ReadNdb(Get("/ARTIST.NDB"));
        List<string> albums = ReadNdb(Get("/ALBUM.NDB"));
        List<string> groupNames = ReadNdb(Get("/GROUP.NDB"));
        var groups = new List<ParsedGroup>();
        for (int gi = 0; gi < ranges.Count; gi++)
        {
            string name = AtString(groupNames, gi);
            groups.Add(new ParsedGroup
            {
                Name = name.Length == 0 ? $"Group {gi + 1}" : name,
            });
        }
        int totalSeconds = 0;
        for (int i = 0; i < trackCount; i++)
        {
            int off = 0x900 + i * 16;
            int frames = U32Be(toc, off + 12);
            int seconds = Sti.FramesToSeconds(frames);
            totalSeconds += seconds;
            int num = i + 1;
            files.TryGetValue(ReaderTrackFilename(num), out IsoFileRec? rec);
            var t = new ParsedTrack
            {
                Title = AtString(titles, i),
                Artist = AtString(artists, i),
                Album = AtString(albums, i),
                Seconds = seconds,
                Size = rec?.Size ?? 0,
            };
            for (int gi = 0; gi < ranges.Count; gi++)
            {
                if (ranges[gi].First <= num && num <= ranges[gi].Last)
                {
                    groups[gi].Tracks.Add(t);
                    break;
                }
            }
        }
        return new ParsedDisc
        {
            TrackCount = trackCount,
            TotalSeconds = totalSeconds,
            Groups = groups,
        };
    }
}
