// Header.cs — mirror of Header.swift / header.js: the 96-byte
// secure header at .ATP offset 1024.
using System;

namespace DiscWright.Core;

/// <summary>Fields for HeaderToBytes (header.js's h object).</summary>
public sealed class SecureHeaderFields
{
    public int FrameCount;
    public byte[] BlockSeed = Array.Empty<byte>();  // 8
    public byte[] InitVector = Array.Empty<byte>(); // 8
    public byte[] Connum = Array.Empty<byte>();     // 2
    public byte[] TrackSlot = Array.Empty<byte>();  // 4
    public byte[] Mgd = Array.Empty<byte>();        // 8
}

public static class Header
{
    public const int HeaderLen = 96;
    private static readonly byte[] FormatMagic = { 0x01, 0x00, 0x28, 0x2e };
    private static readonly byte[] BlockParams = { 0x01, 0x0f, 0x50, 0x00, 0x00, 0x04, 0x00, 0x00 };
    private static readonly byte[] ConnumTail = { 0x16, 0x72, 0x5f, 0x9b, 0xe7 };
    private const uint EkbVersion = 0x0001000e;

    /// <summary>HeaderToBytes(h) -> 96 bytes.</summary>
    public static byte[] HeaderToBytes(SecureHeaderFields h)
    {
        var outp = new byte[HeaderLen];
        uint fc = unchecked((uint)h.FrameCount);
        Array.Copy(FormatMagic, 0, outp, 0x00, 4);
        outp[0x04] = (byte)((fc >> 24) & 0xff);
        outp[0x05] = (byte)((fc >> 16) & 0xff);
        outp[0x06] = (byte)((fc >> 8) & 0xff);
        outp[0x07] = (byte)(fc & 0xff);
        outp[0x10] = (byte)((EkbVersion >> 24) & 0xff);
        outp[0x11] = (byte)((EkbVersion >> 16) & 0xff);
        outp[0x12] = (byte)((EkbVersion >> 8) & 0xff);
        outp[0x13] = (byte)(EkbVersion & 0xff);
        Array.Copy(h.BlockSeed, 0, outp, 0x18, h.BlockSeed.Length);
        Array.Copy(BlockParams, 0, outp, 0x20, BlockParams.Length);
        outp[0x28] = 0;
        Array.Copy(h.Connum, 0, outp, 0x29, h.Connum.Length);
        Array.Copy(ConnumTail, 0, outp, 0x2b, ConnumTail.Length);
        Array.Copy(h.TrackSlot, 0, outp, 0x30, h.TrackSlot.Length);
        Array.Copy(new byte[] { 0x41, 0x54, 0x58, 0x20 }, 0, outp, 0x40, 4); // "ATX "
        Array.Copy(h.Mgd, 0, outp, 0x50, h.Mgd.Length);
        Array.Copy(h.InitVector, 0, outp, 0x58, h.InitVector.Length);
        return outp;
    }
}
