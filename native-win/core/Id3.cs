// Id3.cs — mirror of Id3.swift / id3.js (writer side): the
// 1,024-byte ID3v2.4 tag at the head of every .ATP. Frames
// TIT2, TPE1, TALB in order; text encoding 0x02 (UTF-16BE);
// clamped string + one NUL unit; syncsafe sizes; zero padding.
using System;
using System.Text;

namespace DiscWright.Core;

public static class Id3
{
    public const int TagLen = 1024;

    private static byte[] Syncsafe(int n)
        => new[]
        {
            (byte)((n >> 21) & 0x7f), (byte)((n >> 14) & 0x7f),
            (byte)((n >> 7) & 0x7f), (byte)(n & 0x7f),
        };

    private static byte[] Frame(string fid, string text)
    {
        byte[] textBytes = Text.Utf16BeClamped(text);
        var body = new byte[1 + textBytes.Length + 2];
        body[0] = 0x02;
        Array.Copy(textBytes, 0, body, 1, textBytes.Length);
        // (the final two bytes stay zero: the NUL terminator unit)
        var outp = new byte[10 + body.Length];
        byte[] fidBytes = Encoding.ASCII.GetBytes(fid);
        Array.Copy(fidBytes, 0, outp, 0, 4);
        Array.Copy(Syncsafe(body.Length), 0, outp, 4, 4);
        Array.Copy(body, 0, outp, 10, body.Length);
        return outp;
    }

    /// <summary>
    /// WriteTag(title, artist, album) -> 1024 bytes.
    /// (id3.js names the first parameter track; it is the title.)
    /// </summary>
    public static byte[] WriteTag(string title, string artist, string album)
    {
        byte[][] frames =
        {
            Frame("TIT2", title),
            Frame("TPE1", artist),
            Frame("TALB", album),
        };
        int total = 0;
        foreach (byte[] f in frames) total += f.Length;
        var tag = new byte[TagLen];
        Array.Copy(new byte[] { 0x49, 0x44, 0x33, 0x04, 0x00, 0x00 }, 0, tag, 0, 6); // "ID3" v2.4
        Array.Copy(Syncsafe(TagLen - 10), 0, tag, 6, 4);
        int off = 10;
        foreach (byte[] f in frames)
        {
            Array.Copy(f, 0, tag, off, f.Length);
            off += f.Length;
        }
        if (10 + total > TagLen)
            throw new DiscCoreException("tag overflow");
        return tag;
    }
}
