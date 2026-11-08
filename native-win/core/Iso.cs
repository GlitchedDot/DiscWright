// Iso.cs — mirror of Iso.swift / iso.js: the ISO 9660 writer.
// Layout matches the original burner: system area zeroed, blank
// volume ids, L path table then M path table, directories first
// in path-table order, files grouped by parent in directory-
// record order.
//
// Timestamps: the JS derives everything from {ms,
// tzOffsetMinutes} with Date's UTC getters — ms is an absolute
// epoch instant, "local" = UTC + tzOffsetMinutes. JavaScript
// Date is a pure proleptic-Gregorian UTC calendar, so the C#
// computes the civil fields arithmetically (Howard Hinnant's
// algorithm) instead of using DateTime/TimeZoneInfo calendar
// math, which could be affected by the host's calendar
// settings. Math.floor semantics are kept where the JS uses
// Math.floor (C#'s / truncates toward zero).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace DiscWright.Core;

// ---- timestamps ----

public sealed class IsoTimestampInput
{
    public long Ms;
    public int TzOffsetMinutes;
}

public sealed class IsoTimestampOutput
{
    public byte[] Date7 = Array.Empty<byte>();
    public byte[] Pvd17 = Array.Empty<byte>();
}

// ---- the tree (iso.js's Dir / buildTree / dirOrder) ----

public sealed class IsoDir
{
    public string Path;
    public byte[] Name;
    public IsoDir? Parent;
    public readonly List<(byte[] Ident, string Path, int Size)> Files = new();
    public readonly List<IsoDir> Subdirs = new();
    public int Extent;
    public int Size;
    public int Index;

    public IsoDir(string path, byte[] name, IsoDir? parent)
    {
        Path = path;
        Name = name;
        Parent = parent;
    }
}

// ---- the planner (iso.js's plan / isoSectorCount) ----

public sealed class IsoPlan
{
    public List<IsoDir> Order = new();
    public byte[] Lt = Array.Empty<byte>();
    public byte[] Mt = Array.Empty<byte>();
    public Dictionary<string, int> FileExtents = new();
    public int Total;
}

public static class Iso
{
    public const int IsoSector = 2048;

    // ---- endian helpers (iso.js's le16/be16/both16/le32/be32/both32) ----
    public static byte[] Le16(int n) => new[] { (byte)(n & 0xff), (byte)((n >> 8) & 0xff) };
    public static byte[] Be16(int n) => new[] { (byte)((n >> 8) & 0xff), (byte)(n & 0xff) };
    public static byte[] Both16(int n)
    {
        var outp = new byte[4];
        Array.Copy(Le16(n), 0, outp, 0, 2);
        Array.Copy(Be16(n), 0, outp, 2, 2);
        return outp;
    }
    public static byte[] Le32(int n) => new[]
    {
        (byte)(n & 0xff), (byte)((n >> 8) & 0xff),
        (byte)((n >> 16) & 0xff), (byte)((n >> 24) & 0xff),
    };
    public static byte[] Be32(int n) => new[]
    {
        (byte)((n >> 24) & 0xff), (byte)((n >> 16) & 0xff),
        (byte)((n >> 8) & 0xff), (byte)(n & 0xff),
    };
    public static byte[] Both32(int n)
    {
        var outp = new byte[8];
        Array.Copy(Le32(n), 0, outp, 0, 4);
        Array.Copy(Be32(n), 0, outp, 4, 4);
        return outp;
    }

    public static int CeilDiv(int a, int b) => (a + b - 1) / b;

    /// <summary>Floor division (JS Math.floor(a / b)); C#'s / truncates.</summary>
    public static long FloorDiv(long a, long b)
    {
        long q = a / b;
        if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
        return q;
    }

    public static byte[] AsciiBytes(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>iso.js's cmpBytes: lexicographic byte compare.</summary>
    public static int CmpBytes(byte[] a, byte[] b)
    {
        int n = Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++)
        {
            if (a[i] != b[i]) return a[i] - b[i];
        }
        return a.Length - b.Length;
    }

    public static void PutBytes(byte[] img, byte[] data, int off)
        => Array.Copy(data, 0, img, off, data.Length);

    // ---- timestamps ----

    /// <summary>Civil fields of an epoch-ms instant, UTC (JS Date UTC getters).</summary>
    public static (int Year, int Month, int Day, int Hour, int Minute, int Second)
        CivilParts(long ms)
    {
        long days = FloorDiv(ms, 86_400_000);
        long rem = ms - days * 86_400_000; // 0 ..< 86_400_000
        int hour = (int)(rem / 3_600_000);
        rem -= hour * 3_600_000L;
        int minute = (int)(rem / 60_000);
        rem -= minute * 60_000L;
        int second = (int)(rem / 1_000);
        // civil_from_days (Howard Hinnant), days since 1970-01-01.
        long z = days + 719_468;
        long era = FloorDiv(z, 146_097);
        long doe = z - era * 146_097;                                     // 0..<146097
        long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // 0..<400
        long y = yoe + era * 400;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);               // 0..<366
        long mp = (5 * doy + 2) / 153;                                    // 0..<12
        long d = doy - (153 * mp + 2) / 5 + 1;                            // 1..<32
        long m = mp + (mp < 10 ? 3 : -9);                                 // 1..<13
        if (m <= 2) y += 1;
        return ((int)y, (int)m, (int)d, hour, minute, second);
    }

    /// <summary>iso.js's timestamps(ts): {date7, pvd17}.</summary>
    public static IsoTimestampOutput IsoTimestamps(IsoTimestampInput? ts)
    {
        long ms;
        int tzMin;
        if (ts != null)
        {
            ms = ts.Ms;
            tzMin = ts.TzOffsetMinutes;
        }
        else
        {
            // JS fallback: Date.now() and -new Date(ms).getTimezoneOffset().
            DateTimeOffset now = DateTimeOffset.UtcNow;
            ms = now.ToUnixTimeMilliseconds();
            tzMin = (int)TimeZoneInfo.Local.GetUtcOffset(now).TotalMinutes;
        }
        int tz = (int)FloorDiv(tzMin, 15);
        var local = CivilParts(ms + tzMin * 60_000L);
        var utc = CivilParts(ms);
        byte[] date7 =
        {
            (byte)(local.Year - 1900),
            (byte)local.Month,
            (byte)local.Day,
            (byte)local.Hour,
            (byte)local.Minute,
            (byte)local.Second,
            (byte)tz,
        };
        string P2(int v) => v < 10
            ? "0" + v.ToString(CultureInfo.InvariantCulture)
            : v.ToString(CultureInfo.InvariantCulture);
        string yearStr = utc.Year.ToString(CultureInfo.InvariantCulture);
        while (yearStr.Length < 4) yearStr = "0" + yearStr;
        // JS: Math.floor((ms % 1000) / 10) — JS % keeps the
        // dividend's sign (as does C#'s), the division is floored.
        int hundredths = (int)FloorDiv(ms % 1000, 10);
        string digits = yearStr + P2(utc.Month) + P2(utc.Day) + P2(utc.Hour) +
            P2(utc.Minute) + P2(utc.Second) + P2(hundredths);
        var pvd17 = new byte[17];
        byte[] digitBytes = AsciiBytes(digits);
        for (int i = 0; i < 16; i++) pvd17[i] = digitBytes[i];
        pvd17[16] = (byte)tz;
        return new IsoTimestampOutput { Date7 = date7, Pvd17 = pvd17 };
    }

    // ---- directory records ----

    public static byte[] DirRecord(int extent, int size, bool isDir,
                                   byte[] date7, byte[] name)
    {
        int nlen = name.Length;
        int total = 33 + nlen;
        if (total % 2 == 1) total += 1;
        var rec = new byte[total];
        rec[0] = (byte)total;
        PutBytes(rec, Both32(extent), 2);
        PutBytes(rec, Both32(size), 10);
        PutBytes(rec, date7, 18);
        rec[25] = isDir ? (byte)2 : (byte)0;
        PutBytes(rec, Both16(1), 28);
        rec[32] = (byte)nlen;
        PutBytes(rec, name, 33);
        return rec;
    }

    // ---- the tree ----

    public static IsoDir BuildTree(IReadOnlyDictionary<string, int> sizes)
    {
        var root = new IsoDir("", new byte[] { 0 }, null);
        var dirs = new Dictionary<string, IsoDir> { [""] = root };
        // JS: [...sizes.keys()].sort() — default string sort
        // (UTF-16 code-unit order) = StringComparer.Ordinal.
        var paths = new List<string>(sizes.Keys);
        paths.Sort(StringComparer.Ordinal);
        foreach (string path in paths)
        {
            string[] parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            IsoDir parent = root;
            string cur = "";
            for (int pi = 0; pi < parts.Length - 1; pi++)
            {
                string part = parts[pi];
                cur += "/" + part;
                if (!dirs.TryGetValue(cur, out IsoDir? d))
                {
                    d = new IsoDir(cur, AsciiBytes(part), parent);
                    dirs[cur] = d;
                    parent.Subdirs.Add(d);
                }
                parent = d;
            }
            byte[] ident = AsciiBytes(parts[parts.Length - 1] + ";1");
            parent.Files.Add((ident, path, sizes[path]));
        }
        foreach (IsoDir d in dirs.Values)
        {
            d.Files.Sort((a, b) => CmpBytes(a.Ident, b.Ident));
            d.Subdirs.Sort((a, b) => CmpBytes(a.Name, b.Name));
        }
        return root;
    }

    public static List<IsoDir> DirOrder(IsoDir root)
    {
        var order = new List<IsoDir> { root };
        int i = 0;
        while (i < order.Count)
        {
            var kids = new List<IsoDir>(order[i].Subdirs);
            kids.Sort((a, b) => CmpBytes(a.Name, b.Name));
            order.AddRange(kids);
            i += 1;
        }
        for (int n = 0; n < order.Count; n++) order[n].Index = n + 1;
        return order;
    }

    public static int DirDataSize(IsoDir d)
    {
        var idents = new List<byte[]> { new byte[] { 0 }, new byte[] { 1 } };
        foreach (IsoDir sd in d.Subdirs) idents.Add(sd.Name);
        foreach (var f in d.Files) idents.Add(f.Ident);
        idents.Sort(CmpBytes);
        int pos = 0;
        foreach (byte[] ident in idents)
        {
            int ln = 33 + ident.Length;
            if (ln % 2 == 1) ln += 1;
            if ((pos % IsoSector) + ln > IsoSector)
                pos += IsoSector - (pos % IsoSector);
            pos += ln;
        }
        return CeilDiv(pos, IsoSector) * IsoSector;
    }

    public static (byte[] Lt, byte[] Mt) PathTables(List<IsoDir> order)
    {
        var lt = new List<byte>();
        var mt = new List<byte>();
        foreach (IsoDir d in order)
        {
            byte[] name = d.Parent == null ? new byte[] { 0 } : d.Name;
            int parentIdx = d.Parent == null ? d.Index : d.Parent.Index;
            byte[] pad = name.Length % 2 == 1 ? new byte[] { 0 } : Array.Empty<byte>();
            lt.Add((byte)name.Length); lt.Add(0);
            lt.AddRange(Le32(d.Extent));
            lt.AddRange(Le16(parentIdx));
            lt.AddRange(name);
            lt.AddRange(pad);
            mt.Add((byte)name.Length); mt.Add(0);
            mt.AddRange(Be32(d.Extent));
            mt.AddRange(Be16(parentIdx));
            mt.AddRange(name);
            mt.AddRange(pad);
        }
        return (lt.ToArray(), mt.ToArray());
    }

    // ---- the planner ----

    public static IsoPlan PlanIso(IReadOnlyDictionary<string, int> sizes)
    {
        IsoDir root = BuildTree(sizes);
        List<IsoDir> order = DirOrder(root);
        foreach (IsoDir d in order) d.Size = DirDataSize(d);
        var tables = PathTables(order); // extents 0; lengths final
        int ltSec = CeilDiv(tables.Lt.Length, IsoSector);
        int mtSec = CeilDiv(tables.Mt.Length, IsoSector);
        int nxt = 16 + 2 + ltSec + mtSec;
        foreach (IsoDir d in order)
        {
            d.Extent = nxt;
            nxt += d.Size / IsoSector;
        }
        var fileExtents = new Dictionary<string, int>();
        foreach (IsoDir d in order)
        {
            foreach (var f in d.Files)
            {
                fileExtents[f.Path] = nxt;
                nxt += CeilDiv(f.Size, IsoSector);
            }
        }
        tables = PathTables(order); // recomputed with real extents
        return new IsoPlan
        {
            Order = order,
            Lt = tables.Lt,
            Mt = tables.Mt,
            FileExtents = fileExtents,
            Total = nxt,
        };
    }

    /// <summary>IsoSectorCount(sizes) -> total sectors of the planned image.</summary>
    public static int IsoSectorCount(IReadOnlyDictionary<string, int> sizes)
        => PlanIso(sizes).Total;

    public static byte[] DirBytes(IsoDir d, Dictionary<string, int> fileExtents,
                                  byte[] date7)
    {
        IsoDir parent = d.Parent ?? d;
        var records = new List<(byte[] Ident, int Ext, int Size, bool IsDir)>
        {
            (new byte[] { 0 }, d.Extent, d.Size, true),
            (new byte[] { 1 }, parent.Extent, parent.Size, true),
        };
        var kids = new List<(byte[] Ident, int Ext, int Size, bool IsDir)>();
        foreach (IsoDir sd in d.Subdirs)
            kids.Add((sd.Name, sd.Extent, sd.Size, true));
        foreach (var f in d.Files)
            kids.Add((f.Ident, fileExtents[f.Path], f.Size, false));
        kids.Sort((a, b) => CmpBytes(a.Ident, b.Ident));
        records.AddRange(kids);
        var outp = new byte[d.Size];
        int len = 0;
        foreach (var r in records)
        {
            byte[] rec = DirRecord(r.Ext, r.Size, r.IsDir, date7, r.Ident);
            if ((len % IsoSector) + rec.Length > IsoSector)
                len += IsoSector - (len % IsoSector);
            PutBytes(outp, rec, len);
            len += rec.Length;
        }
        return outp;
    }

    // ---- the writer ----

    /// <summary>
    /// WriteIso(files, volIdent, timestamp) -> ISO bytes.
    /// (iso.js signature: writeIso(files, {volIdent = "", timestamp}).)
    /// </summary>
    public static byte[] WriteIso(IReadOnlyDictionary<string, byte[]> files,
                                  string volIdent = "",
                                  IsoTimestampInput? timestamp = null)
    {
        var sizes = new Dictionary<string, int>();
        foreach (var kv in files) sizes[kv.Key] = kv.Value.Length;
        IsoPlan plan = PlanIso(sizes);
        IsoTimestampOutput ts = IsoTimestamps(timestamp);
        IsoDir root = plan.Order[0];
        var img = new byte[plan.Total * IsoSector];

        var pvd = new byte[IsoSector];
        pvd[0] = 1;
        PutBytes(pvd, AsciiBytes("CD001"), 1);
        pvd[6] = 1;
        for (int i = 8; i < 40; i++) pvd[i] = 0x20;
        byte[] volBytes = AsciiBytes(volIdent);
        var ident = new byte[Math.Min(volBytes.Length, 32)];
        Array.Copy(volBytes, 0, ident, 0, ident.Length);
        for (int i = 40; i < 72; i++) pvd[i] = 0x20;
        PutBytes(pvd, ident, 40);
        PutBytes(pvd, Both32(plan.Total), 80);
        PutBytes(pvd, Both16(1), 120);
        PutBytes(pvd, Both16(1), 124);
        PutBytes(pvd, Both16(IsoSector), 128);
        PutBytes(pvd, Both32(plan.Lt.Length), 132);
        PutBytes(pvd, Le32(18), 140);
        PutBytes(pvd, Be32(18 + CeilDiv(plan.Lt.Length, IsoSector)), 148);
        PutBytes(pvd, DirRecord(root.Extent, root.Size, true, ts.Date7,
                                new byte[] { 0 }), 156);
        foreach (int off in new[] { 190, 318, 446, 574 })
            for (int i = off; i < off + 128; i++) pvd[i] = 0x20;
        foreach (int off in new[] { 702, 739, 776 })
            for (int i = off; i < off + 37; i++) pvd[i] = 0x20;
        foreach (int off in new[] { 813, 830, 847, 864 })
            PutBytes(pvd, ts.Pvd17, off);
        pvd[881] = 1;
        PutBytes(img, pvd, 16 * IsoSector);

        var term = new byte[IsoSector];
        term[0] = 255;
        PutBytes(term, AsciiBytes("CD001"), 1);
        term[6] = 1;
        PutBytes(img, term, 17 * IsoSector);

        PutBytes(img, plan.Lt, 18 * IsoSector);
        PutBytes(img, plan.Mt, (18 + CeilDiv(plan.Lt.Length, IsoSector)) * IsoSector);

        foreach (IsoDir d in plan.Order)
            PutBytes(img, DirBytes(d, plan.FileExtents, ts.Date7),
                     d.Extent * IsoSector);
        foreach (var kv in files)
            PutBytes(img, kv.Value, plan.FileExtents[kv.Key] * IsoSector);
        return img;
    }
}
