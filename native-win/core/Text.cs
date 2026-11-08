// Text.cs — mirror of Text.swift / text.js.
// Strings are clamped to 30 UTF-16 code units (astral characters
// count 2 and are kept or dropped whole; lone surrogates become
// U+FFFD) and encoded UTF-16BE.
//
// The JS iterates a string by code point (for (const ch of s)),
// where a lone surrogate surfaces as its own "character" with
// codePointAt() in 0xD800...0xDFFF. A C# string CAN hold an
// unpaired surrogate, but string.EnumerateRunes() yields U+FFFD
// for invalid sequences — which is exactly the replacement the
// JS/Swift clamp applies to such code points — so enumerating
// Runes and clamping reproduces the JS for every input,
// including the (practically unreachable) lone-surrogate case.
using System;
using System.Collections.Generic;
using System.Text;

namespace DiscWright.Core;

public static class Text
{
    public const int MaxStringUnits = 30;

    /// <summary>Code points of the string, in iteration order (JS for...of).</summary>
    public static int[] JsCodePoints(string s)
    {
        var outp = new List<int>();
        foreach (Rune r in s.EnumerateRunes())
            outp.Add(r.Value);
        return outp.ToArray();
    }

    /// <summary>ClampString(s): the clamped string as a list of code points.</summary>
    public static int[] ClampString(string s)
    {
        var outp = new List<int>();
        int units = 0;
        foreach (int raw in JsCodePoints(s))
        {
            int cp = raw;
            if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
            int n = cp > 0xffff ? 2 : 1;
            if (units + n > MaxStringUnits) break;
            outp.Add(cp);
            units += n;
        }
        return outp.ToArray();
    }

    /// <summary>
    /// Utf16Be(codePoints): UTF-16BE bytes, with surrogate pairs
    /// for astral code points, exactly as text.js computes them.
    /// </summary>
    public static byte[] Utf16Be(int[] codePoints)
    {
        var bytes = new List<byte>();
        foreach (int cp in codePoints)
        {
            if (cp > 0xffff)
            {
                int v = cp - 0x10000;
                int hi = 0xd800 + (v >> 10);
                int lo = 0xdc00 + (v & 0x3ff);
                bytes.Add((byte)((hi >> 8) & 0xff));
                bytes.Add((byte)(hi & 0xff));
                bytes.Add((byte)((lo >> 8) & 0xff));
                bytes.Add((byte)(lo & 0xff));
            }
            else
            {
                bytes.Add((byte)((cp >> 8) & 0xff));
                bytes.Add((byte)(cp & 0xff));
            }
        }
        return bytes.ToArray();
    }

    /// <summary>The pipeline the JS applies everywhere: Utf16Be(ClampString(s)).</summary>
    public static byte[] Utf16BeClamped(string s) => Utf16Be(ClampString(s));

    /// <summary>
    /// Parse an even-length hex string into bytes (JS .match(/../g)
    /// + parseInt(h, 16), with a non-hex nibble reading as 0, as in
    /// the Swift port's ?? 0 fallback); used for the core's held
    /// constants.
    /// </summary>
    public static byte[] BytesFromHex(string hex)
    {
        var outp = new List<byte>(hex.Length / 2);
        for (int i = 0; i + 1 < hex.Length; i += 2)
            outp.Add((byte)((HexVal(hex[i]) << 4) | HexVal(hex[i + 1])));
        return outp.ToArray();
    }

    private static int HexVal(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    }
}
