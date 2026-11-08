// TagReader.cs — reading an audio file's tags, a line-for-line
// port of TagReader.swift (itself a port of the web app's
// tagsFor path in app.js): ID3v2 TIT2/TPE1/TALB first (v2.3
// plain sizes, v2.4 syncsafe frame sizes; text encodings
// 0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8), then the
// ID3v1 trailer, then a filename fallback for the title
// (extension dropped, underscores become spaces).
//
// Pure C# over byte arrays: no WinUI/WinRT dependency, so this
// file is compile-checked with the core (see STEP2-NOTES.md).

using System;
using System.IO;
using System.Text;

namespace DiscWright;

public sealed class AudioTags
{
    public string Title = "";
    public string Artist = "";
    public string Album = "";
}

public static class TagReader
{
    /// <summary>Read a file's tags. Throws only when the file
    /// itself cannot be read (the web app's addFile catch sets
    /// the track error).</summary>
    public static AudioTags TagsForFile(string path)
    {
        byte[] data = File.ReadAllBytes(path);
        return Tags(data, Path.GetFileName(path));
    }

    /// <summary>tagsFor(bytes, fileName), mirrored from app.js.</summary>
    public static AudioTags Tags(byte[] bytes, string fileName)
    {
        AudioTags tags = ParseV2(bytes) ?? ParseV1(bytes) ?? new AudioTags();
        if (tags.Title.Length == 0)
        {
            string baseName = fileName;
            // JS: fileName.replace(/\.[^.]+$/, "") — the last
            // dot plus at least one non-dot char, to the end.
            int dot = baseName.LastIndexOf('.');
            if (dot >= 0 && dot < baseName.Length - 1)
                baseName = baseName.Substring(0, dot);
            tags.Title = baseName.Replace('_', ' ').Trim();
        }
        return tags;
    }

    // ---- ID3v1 ----

    private static string Latin1(byte[] bytes, int start, int length)
    {
        // JS latin1(): one Latin-1 char per byte, trailing
        // NUL/space run stripped, then trim().
        string s = Encoding.Latin1.GetString(bytes, start, length);
        int end = s.Length;
        while (end > 0 && (s[end - 1] == '\0' || s[end - 1] == ' ')) end--;
        return s.Substring(0, end).Trim();
    }

    public static AudioTags? ParseV1(byte[] bytes)
    {
        if (bytes.Length < 128) return null;
        int t = bytes.Length - 128;
        if (bytes[t] != 0x54 || bytes[t + 1] != 0x41 || bytes[t + 2] != 0x47)
            return null; // "TAG"
        return new AudioTags
        {
            Title = Latin1(bytes, t + 3, 30),
            Artist = Latin1(bytes, t + 33, 30),
            Album = Latin1(bytes, t + 63, 30),
        };
    }

    // ---- ID3v2 ----

    private static string DecodeText(byte enc, byte[] body, int start, int length)
    {
        string s;
        switch (enc)
        {
            case 0:
                s = Encoding.Latin1.GetString(body, start, length);
                break;
            case 1:
                s = DecodeUtf16WithBom(body, start, length);
                break;
            case 2:
                s = Encoding.BigEndianUnicode.GetString(body, start, length - (length % 2));
                break;
            default:
                s = Encoding.UTF8.GetString(body, start, length);
                break;
        }
        // JS: replace(/\0+$/, "").trim()
        int end = s.Length;
        while (end > 0 && s[end - 1] == '\0') end--;
        return s.Substring(0, end).Trim();
    }

    /// <summary>TextDecoder "utf-16": little-endian unless a
    /// BOM says otherwise; the BOM is consumed.</summary>
    private static string DecodeUtf16WithBom(byte[] body, int start, int length)
    {
        bool bigEndian = false;
        if (length >= 2 && body[start] == 0xFE && body[start + 1] == 0xFF)
        {
            bigEndian = true;
            start += 2; length -= 2;
        }
        else if (length >= 2 && body[start] == 0xFF && body[start + 1] == 0xFE)
        {
            start += 2; length -= 2;
        }
        length -= length % 2;
        return bigEndian
            ? Encoding.BigEndianUnicode.GetString(body, start, length)
            : Encoding.Unicode.GetString(body, start, length);
    }

    public static AudioTags? ParseV2(byte[] bytes)
    {
        if (bytes.Length < 10 ||
            bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) // "ID3"
            return null;
        int ver = bytes[3];
        int size = ((bytes[6] & 0x7f) << 21) | ((bytes[7] & 0x7f) << 14) |
                   ((bytes[8] & 0x7f) << 7) | (bytes[9] & 0x7f);
        var output = new AudioTags();
        bool hasTitle = false;
        int pos = 10;
        int end = Math.Min(bytes.Length, 10 + size);
        while (pos + 10 <= end)
        {
            // JS: /^[A-Z0-9]{4}$/ or the frame walk stops.
            bool idOk = true;
            for (int i = 0; i < 4; i++)
            {
                byte b = bytes[pos + i];
                if (!((b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)))
                {
                    idOk = false;
                    break;
                }
            }
            if (!idOk) break;
            string id = Encoding.ASCII.GetString(bytes, pos, 4);
            int r0 = bytes[pos + 4], r1 = bytes[pos + 5], r2 = bytes[pos + 6], r3 = bytes[pos + 7];
            int fsize = ver == 4
                ? ((r0 & 0x7f) << 21) | ((r1 & 0x7f) << 14) | ((r2 & 0x7f) << 7) | (r3 & 0x7f)
                : (r0 << 24) | (r1 << 16) | (r2 << 8) | r3;
            int bodyStart = pos + 10;
            int bodyEnd = Math.Min(bytes.Length, bodyStart + Math.Max(0, fsize));
            int bodyLength = Math.Max(0, bodyEnd - bodyStart);
            if (bodyLength > 1)
            {
                byte enc = bytes[bodyStart];
                // The frame body minus its encoding byte.
                int textStart = bodyStart + 1;
                int textLength = bodyLength - 1;
                switch (id)
                {
                    case "TIT2":
                        output.Title = DecodeText(enc, bytes, textStart, textLength);
                        hasTitle = true;
                        break;
                    case "TPE1":
                        output.Artist = DecodeText(enc, bytes, textStart, textLength);
                        break;
                    case "TALB":
                        output.Album = DecodeText(enc, bytes, textStart, textLength);
                        break;
                }
            }
            pos += 10 + fsize;
        }
        // JS returns the object only if a TIT2 frame was present.
        return hasTitle ? output : null;
    }
}
