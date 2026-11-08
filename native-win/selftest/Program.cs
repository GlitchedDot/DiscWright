// Program.cs — command-line parity check for the C# core.
//
//   selftest <path-to-reference-dir>
//
// Reads fixture.json + the track frames files from the reference
// directory, builds the disc with the C# core, and compares the
// result byte-for-byte with expected.iso. Prints the MD5s, the
// sector counts, and either BYTE-IDENTICAL or the number and
// first offsets of differing bytes. Exit 0 only if identical.
// (Mirror of native-pure/selftest.swift.)
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DiscWright.Core;

Console.OutputEncoding = Encoding.UTF8;

static void Fail(string msg)
{
    Console.Error.WriteLine("selftest: " + msg);
    Environment.Exit(1);
}

if (args.Length < 1)
    Fail("usage: selftest <reference-dir>");
string refDir = args[0];

string RefPath(string name) => Path.Combine(refDir, name);
byte[] RefData(string name)
{
    try
    {
        return File.ReadAllBytes(RefPath(name));
    }
    catch (Exception e)
    {
        Fail($"cannot read {name}: {e.Message}");
        throw; // unreachable; Fail exits
    }
}
static string Md5Hex(byte[] data)
    => Convert.ToHexString(MD5.HashData(data)).ToLowerInvariant();

try
{
    using JsonDocument fxDoc = JsonDocument.Parse(RefData("fixture.json"));
    JsonElement fx = fxDoc.RootElement;

    byte[] discId = Text.BytesFromHex(fx.GetProperty("discId").GetString() ?? "");
    var ivs = new List<byte[]>();
    foreach (JsonElement iv in fx.GetProperty("ivs").EnumerateArray())
        ivs.Add(Text.BytesFromHex(iv.GetString() ?? ""));

    var tracks = new List<DiscTrack>();
    foreach (JsonElement t in fx.GetProperty("tracks").EnumerateArray())
    {
        tracks.Add(new DiscTrack
        {
            Frames = RefData(t.GetProperty("framesFile").GetString() ?? ""),
            Title = t.GetProperty("title").GetString() ?? "",
            Artist = t.GetProperty("artist").GetString() ?? "",
            Album = t.GetProperty("album").GetString() ?? "",
        });
    }
    var groups = new List<DiscGroup>();
    foreach (JsonElement g in fx.GetProperty("groups").EnumerateArray())
    {
        groups.Add(new DiscGroup
        {
            Name = g.GetProperty("name").GetString() ?? "",
            First = g.GetProperty("first").GetInt32(),
            Last = g.GetProperty("last").GetInt32(),
        });
    }
    var timestamp = new DiscTimestamp
    {
        Ms = fx.GetProperty("timestampMs").GetInt64(),
        TzOffsetMinutes = fx.GetProperty("tzOffsetMinutes").GetInt32(),
    };

    // verify.mjs calls buildDisc without capacitySectors, so the
    // JS default (360000) applies — the C# default matches.
    BuildDiscResult result = DiscAuthor.BuildDisc(
        tracks, groups, discId, ivs, timestamp: timestamp);
    byte[] expected = RefData("expected.iso");
    string expectedMd5 = fx.GetProperty("expectedMd5").GetString() ?? "";
    int expectedSectors = fx.GetProperty("expectedSectors").GetInt32();

    Console.WriteLine($"C# ISO md5:   {Md5Hex(result.Iso)}");
    Console.WriteLine($"expected md5:    {expectedMd5}");
    Console.WriteLine($"sectors: {result.Stats.IsoSectors} expected: {expectedSectors}");
    Console.WriteLine($"bytes: {result.Iso.Length} expected: {expected.Length}");

    // Smoke-check the reader half too (does not affect the verdict).
    try
    {
        ParsedDisc parsed = IsoRead.ParseAtracDisc(result.Iso);
        Console.WriteLine($"reader: {parsed.TrackCount} tracks, " +
                          $"{parsed.Groups.Count} groups, {parsed.TotalSeconds}s total");
    }
    catch (Exception)
    {
        Console.WriteLine("reader: WARNING — ParseAtracDisc threw on the built ISO");
    }

    if (result.Iso.Length != expected.Length)
    {
        Console.WriteLine($"LENGTH MISMATCH: {result.Iso.Length} vs {expected.Length}");
        return 1;
    }
    int diffs = 0;
    for (int i = 0; i < result.Iso.Length; i++)
    {
        if (result.Iso[i] != expected[i])
        {
            if (diffs < 5)
                Console.WriteLine($"first diffs: offset {i}: {result.Iso[i]} vs {expected[i]}");
            diffs += 1;
        }
    }
    Console.WriteLine(diffs == 0 ? "BYTE-IDENTICAL ✓" : $"{diffs} differing bytes ✗");
    return diffs == 0 ? 0 : 1;
}
catch (Exception e)
{
    Fail(e.Message);
    return 1; // unreachable; Fail exits
}
