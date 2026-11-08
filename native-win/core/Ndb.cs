// Ndb.cs — mirror of Ndb.swift / ndb.js (writer side).
// 256-byte header: "NDB " + 01 00 + BE u16 record count.
// 128-byte records: 02 00 + UTF-16BE string (max 30 units),
// zero padded. An empty string is an all-zero record.
using System;
using System.Collections.Generic;

namespace DiscWright.Core;

public static class Ndb
{
    public const int NdbHeaderLen = 256;
    public const int NdbRecordLen = 128;

    /// <summary>WriteNdb(strings) -> bytes.</summary>
    public static byte[] WriteNdb(IReadOnlyList<string> strings)
    {
        var outp = new byte[NdbHeaderLen + strings.Count * NdbRecordLen];
        Array.Copy(new byte[] { 0x4e, 0x44, 0x42, 0x20, 0x01, 0x00 }, 0, outp, 0, 6);
        outp[6] = (byte)((strings.Count >> 8) & 0xff);
        outp[7] = (byte)(strings.Count & 0xff);
        for (int i = 0; i < strings.Count; i++)
        {
            string s = strings[i];
            if (s == "") continue; // all-zero record
            int off = NdbHeaderLen + i * NdbRecordLen;
            outp[off] = 0x02;
            outp[off + 1] = 0x00;
            byte[] bytes = Text.Utf16BeClamped(s);
            Array.Copy(bytes, 0, outp, off + 2, bytes.Length);
        }
        return outp;
    }
}
