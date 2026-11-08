// Author.cs — mirror of Author.swift / author.js: disc
// orchestration with the hardware-proven recipe built in.
// Track list in -> complete file tree -> capacity-checked
// ISO out.
using System;
using System.Collections.Generic;

namespace DiscWright.Core;

/// <summary>A track to author (author.js's track objects).</summary>
public sealed class DiscTrack
{
    public byte[] Frames = Array.Empty<byte>();
    public string Title = "";
    public string Artist = "";
    public string Album = "";
    public int? FrameSize; // default Atrac.FrameSize (376)
}

/// <summary>A group (author.js's groups): 1-based inclusive track range.</summary>
public sealed class DiscGroup
{
    public string Name = "";
    public int First;
    public int Last;
}

/// <summary>BuildDisc's timestamp input: {ms, tzOffsetMinutes}.</summary>
public sealed class DiscTimestamp
{
    public long Ms;
    public int TzOffsetMinutes;
}

/// <summary>BuildDisc's stats.</summary>
public sealed class DiscStats
{
    public int IsoBytes;
    public int IsoSectors;
    public int EstimatedSectors;
    public int CapacitySectors;
    public int TrackCount;
}

/// <summary>BuildDisc's result: {iso, files, stats}.</summary>
public sealed class BuildDiscResult
{
    public byte[] Iso = Array.Empty<byte>();
    public Dictionary<string, byte[]> Files = new();
    public DiscStats Stats = new();
}

public static class DiscAuthor
{
    public const int AtpOverhead = 1120; // 1024 ID3 + 96 secure header

    /// <summary>TrackFilename(number): "TRK" + hex(5, uppercase) + ".ATP".</summary>
    public static string TrackFilename(int number)
    {
        if (!(number >= 1 && number <= 0xfffff))
            throw new DiscCoreException("track number out of range");
        string h = number.ToString("X");
        while (h.Length < 5) h = "0" + h;
        return "TRK" + h + ".ATP";
    }

    /// <summary>
    /// BuildDisc: mirrors author.js's option handling one for
    /// one — groups default to a single "New Group" over all
    /// tracks, capacitySectors defaults to 360000, timestamp may
    /// be null (the ISO writer then stamps the current time, as
    /// in JS).
    /// </summary>
    public static BuildDiscResult BuildDisc(
        IReadOnlyList<DiscTrack> tracks,
        IReadOnlyList<DiscGroup>? groups,
        byte[] discId,
        IReadOnlyList<byte[]> ivs,
        int capacitySectors = 360000,
        DiscTimestamp? timestamp = null)
    {
        if (tracks.Count == 0)
            throw new DiscCoreException("no tracks");
        groups ??= new[] { new DiscGroup { Name = "New Group", First = 1, Last = tracks.Count } };
        if (discId.Length != 16)
            throw new DiscCoreException("discId must be 16 bytes");
        if (ivs.Count != tracks.Count)
            throw new DiscCoreException("one IV per track required");

        var files = new Dictionary<string, byte[]>();
        var frameCounts = new List<int>();
        for (int i = 0; i < tracks.Count; i++)
        {
            DiscTrack t = tracks[i];
            int frameSize = t.FrameSize ?? Atrac.FrameSize;
            if (t.Frames.Length % frameSize != 0)
                throw new DiscCoreException(
                    $"track {i + 1}: payload is not a whole number of frames");
            int frameCount = t.Frames.Length / frameSize;
            byte[] header = Header.HeaderToBytes(new SecureHeaderFields
            {
                FrameCount = frameCount,
                BlockSeed = Atrac.BlockSeed(discId, i),
                InitVector = ivs[i],
                Connum = Atrac.Connum,
                TrackSlot = Atrac.TrackSlot,
                Mgd = Atrac.Mgd,
            });
            var atp = new byte[AtpOverhead + t.Frames.Length];
            Iso.PutBytes(atp, Id3.WriteTag(t.Title, t.Artist, t.Album), 0);
            Iso.PutBytes(atp, header, 1024);
            Iso.PutBytes(atp, Atrac.EncryptPayload(t.Frames, ivs[i]), AtpOverhead);
            files["/HIFI/" + TrackFilename(i + 1)] = atp;
            frameCounts.Add(frameCount);
        }

        var titles = new List<string>();
        var albums = new List<string>();
        var artists = new List<string>();
        foreach (DiscTrack t in tracks)
        {
            titles.Add(t.Title);
            albums.Add(t.Album);
            artists.Add(t.Artist);
        }
        files["/TRACK.NDB"] = Ndb.WriteNdb(titles);
        files["/ALBUM.NDB"] = Ndb.WriteNdb(albums);
        files["/ARTIST.NDB"] = Ndb.WriteNdb(artists);
        var groupNames = new List<string>();
        var groupRanges = new List<(int First, int Last)>();
        foreach (DiscGroup g in groups)
        {
            groupNames.Add(g.Name);
            groupRanges.Add((g.First, g.Last));
        }
        files["/GROUP.NDB"] = Ndb.WriteNdb(groupNames);
        files["/PLLIST.NDB"] = Ndb.WriteNdb(Array.Empty<string>());

        var sizes = new int[tracks.Count];
        for (int i = 0; i < tracks.Count; i++)
            sizes[i] = AtpOverhead + tracks[i].Frames.Length;
        byte[] toc = Sti.WriteToc(
            frameCounts,
            groupRanges,
            Atrac.Icv(discId, sizes),
            discId);
        files["/TOC00000.STI"] = toc;
        files["/TOC00001.STI"] = Sti.WritePlf();
        files["/" + Stk.StkFilename] = Stk.StkBytes;

        var sizeMap = new Dictionary<string, int>();
        foreach (var kv in files) sizeMap[kv.Key] = kv.Value.Length;
        int estSectors = Capacity.CheckCapacity(sizeMap, capacitySectors);
        IsoTimestampInput? isoTs = timestamp == null
            ? null
            : new IsoTimestampInput { Ms = timestamp.Ms, TzOffsetMinutes = timestamp.TzOffsetMinutes };
        byte[] iso = Iso.WriteIso(files, "", isoTs);
        int exactSectors = Iso.CeilDiv(iso.Length, 2048);
        if (exactSectors + 11709 > capacitySectors)
            throw new DiscCoreException("built ISO exceeds blank capacity");

        return new BuildDiscResult
        {
            Iso = iso,
            Files = files,
            Stats = new DiscStats
            {
                IsoBytes = iso.Length,
                IsoSectors = exactSectors,
                EstimatedSectors = estSectors,
                CapacitySectors = capacitySectors,
                TrackCount = tracks.Count,
            },
        };
    }
}
