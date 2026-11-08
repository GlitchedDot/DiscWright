// Atrac.cs — mirror of Atrac.swift / atrac.js: the
// hardware-proven recipe.
//   Payload: DES-CBC under d2[0:8], IV = header InitVector.
//   BlockSeed: 2-key triple-DES EDE under V of
//     (DiscID[0:8] ^ DiscID[8:16]) ^ BE64(bindIndex+1) ^ d2[0:8].
//   ICV: X = BE64(DiscID[0:8]); for each .ATP size s:
//     X = (X*s + B) mod 2^64, B = BE64(DiscID[8:16]); out BE64(X).
// The JS does the fold with BigInt + an explicit 2^64 mask; the
// C# uses ulong arithmetic inside unchecked, which is the same
// operation modulo 2^64.
using System;

namespace DiscWright.Core;

public static class Atrac
{
    public static readonly byte[] D2 = Text.BytesFromHex("3d14fb8d372a3b5b17010dbb4fd1b3fecf4a0570");
    public static readonly byte[] VKey = Text.BytesFromHex("3c8e092d257ffa7d3a3986d75b1b4c2b");
    public static readonly byte[] Connum = { 0x4f, 0x7e };
    public static readonly byte[] TrackSlot = { 0xb4, 0xf3, 0x7f, 0xbb };
    public static readonly byte[] Mgd = Text.BytesFromHex("2ad14387ddfb4b86");
    public const int FrameSize = 376; // 64 kbps ATRAC3+ frame

    private static byte[] Xor8(byte[] a, byte[] b)
    {
        var outp = new byte[8];
        for (int i = 0; i < 8; i++) outp[i] = (byte)(a[i] ^ b[i]);
        return outp;
    }

    /// <summary>Big-endian 64-bit encoding of a ulong (atrac.js be64).</summary>
    public static byte[] Be64Bytes(ulong n)
    {
        var outp = new byte[8];
        ulong x = n;
        for (int i = 7; i >= 0; i--)
        {
            outp[i] = (byte)(x & 0xff);
            x >>= 8;
        }
        return outp;
    }

    /// <summary>Big-endian 64-bit decode of 8 bytes at offset.</summary>
    public static ulong ReadBE64(byte[] b, int off)
    {
        ulong x = 0;
        for (int i = 0; i < 8; i++) x = (x << 8) | b[off + i];
        return x;
    }

    /// <summary>BlockSeed(discId, bindIndex), bindIndex 0-based.</summary>
    public static byte[] BlockSeed(byte[] discId, int bindIndex)
    {
        byte[] fold = Xor8(discId[0..8], discId[8..16]);
        byte[] p = Xor8(Xor8(fold, Be64Bytes((ulong)(bindIndex + 1))),
                        D2[0..8]);
        return Des.EdeEncryptBlock(VKey, p);
    }

    /// <summary>Icv(discId, sizes): the unkeyed fold over full .ATP sizes.</summary>
    public static byte[] Icv(byte[] discId, int[] sizes)
    {
        ulong a = ReadBE64(discId, 0);
        ulong b = ReadBE64(discId, 8);
        ulong x = a;
        foreach (int s in sizes)
        {
            unchecked { x = x * (ulong)s + b; }
        }
        return Be64Bytes(x);
    }

    /// <summary>EncryptPayload(frames, iv): DES-CBC under d2[0:8], one chain.</summary>
    public static byte[] EncryptPayload(byte[] frames, byte[] iv)
        => Des.DesCbcEncrypt(D2[0..8], iv, frames);
}
