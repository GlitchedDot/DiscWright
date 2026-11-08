// Des.cs — mirror of Des.swift / des.js.
// DES via System.Security.Cryptography, one transform per
// CommonCrypto one-shot, no padding (all payloads are
// block-aligned, exactly as in the JS). The two-key triple-DES
// EDE composition replicates des.js's exact operation sequence
// out of single-DES transforms:
//   EdeEncryptBlock(k16, b) = E_K1(D_K2(E_K1(b)))
//   EdeDecryptBlock(k16, b) = D_K1(E_K2(D_K1(b)))
// Single-block calls use ECB mode explicitly; the CBC functions
// pass the IV (CBC is the other mode used). Deliberately NOT
// TripleDES: its keying semantics are not the JS's.
// Note: .NET DES rejects known weak keys on assignment; every
// key in this system is a held constant and none is weak, so
// the check can never trip here (see NOTES.md, trap 1).
using System;
using System.Security.Cryptography;

namespace DiscWright.Core;

/// <summary>Shared error type for the whole core (JS throw new Error).</summary>
public class DiscCoreException : Exception
{
    public DiscCoreException(string message) : base(message) { }
}

public static class Des
{
    private static byte[] DesCrypt(bool encrypt, byte[] key, byte[]? iv, byte[] data)
    {
        using DES des = DES.Create();
        des.Mode = iv == null ? CipherMode.ECB : CipherMode.CBC;
        des.Padding = PaddingMode.None;
        using ICryptoTransform tf = encrypt
            ? des.CreateEncryptor(key, iv)
            : des.CreateDecryptor(key, iv);
        return tf.TransformFinalBlock(data, 0, data.Length);
    }

    /// <summary>DesEncryptBlock(key8, block8) -> 8 bytes.</summary>
    public static byte[] DesEncryptBlock(byte[] key8, byte[] block8)
        => DesCrypt(true, key8, null, block8);

    /// <summary>DesDecryptBlock(key8, block8) -> 8 bytes.</summary>
    public static byte[] DesDecryptBlock(byte[] key8, byte[] block8)
        => DesCrypt(false, key8, null, block8);

    /// <summary>EdeEncryptBlock(key16, block8): E_K1 D_K2 E_K1, as in des.js.</summary>
    public static byte[] EdeEncryptBlock(byte[] key16, byte[] block8)
    {
        byte[] k1 = key16[0..8];
        byte[] k2 = key16[8..16];
        return DesEncryptBlock(k1,
            DesDecryptBlock(k2,
                DesEncryptBlock(k1, block8)));
    }

    /// <summary>EdeDecryptBlock(key16, block8): D_K1 E_K2 D_K1, as in des.js.</summary>
    public static byte[] EdeDecryptBlock(byte[] key16, byte[] block8)
    {
        byte[] k1 = key16[0..8];
        byte[] k2 = key16[8..16];
        return DesDecryptBlock(k1,
            DesEncryptBlock(k2,
                DesDecryptBlock(k1, block8)));
    }

    /// <summary>DesCbcEncrypt(key8, iv8, data); data length must be a multiple of 8.</summary>
    public static byte[] DesCbcEncrypt(byte[] key8, byte[] iv8, byte[] data)
    {
        if (data.Length % 8 != 0)
            throw new DiscCoreException("CBC data must be block-aligned");
        return DesCrypt(true, key8, iv8, data);
    }

    /// <summary>DesCbcDecrypt(key8, iv8, data); data length must be a multiple of 8.</summary>
    public static byte[] DesCbcDecrypt(byte[] key8, byte[] iv8, byte[] data)
    {
        if (data.Length % 8 != 0)
            throw new DiscCoreException("CBC data must be block-aligned");
        return DesCrypt(false, key8, iv8, data);
    }
}
